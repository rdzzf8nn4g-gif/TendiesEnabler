#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ==========================================
// 1. 终极路径与环境适配 (Rootful/Rootless/Roothide)
// ==========================================
#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// 统一媒体解压路径获取
static NSString * GetTendiesStorageDir() {
    NSString *base = @"/var/mobile/Documents/TendiesEnabler";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

// 物理日志系统（直接写到不归沙盒管的公共Documents，确保百分百能看到日志）
static void WriteLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSString *logMsg = [NSString stringWithFormat:@"[%@] 🚀 [TendiesEngine] %@\n", [NSDate date], message];
    NSString *logPath = [GetTendiesStorageDir() stringByAppendingPathComponent:@"engine_debug.log"];
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fileHandle) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMsg dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }
}

// ==========================================
// 2. 补全系统私有 API 声明
// ==========================================
@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
- (void)setDismissed:(BOOL)dismissed;
- (id)_backgroundContentViewController; // iOS 16/17 锁屏海报控制器
@end

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end

// ==========================================
// 3. 动态配置全局变量 (参考黄金方案)
// ==========================================
static BOOL g_enabled = NO;
static NSString *g_tendiesPath = nil;

static void reloadPrefs() {
    CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
    CFPreferencesAppSynchronize(appID);
    
    Boolean valid;
    // 核心修复：改用原生 CFPreferences 跨进程穿透读取开关
    g_enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &valid) ? valid : NO;
    
    CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("TendiesPath"), appID);
    if (pathRef && CFGetTypeID(pathRef) == CFStringGetTypeID()) {
        g_tendiesPath = [(__bridge NSString *)pathRef copy];
    } else {
        // 兜底路径
        g_tendiesPath = [GetTendiesStorageDir() stringByAppendingPathComponent:@"ActiveTendies"];
    }
    
    WriteLog(@"配置重载完成 - 开关: %d, 路径: %@", g_enabled, g_tendiesPath);
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    // 广播给所有渲染引擎实例进行重载
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

// ==========================================
// 4. 自定义渲染引擎视图
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;

- (void)reloadWallpaperViews;
- (void)transitionToState:(NSString *)stateName;
@end

@implementation TendiesRenderEngineView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleStateChange:) name:@"TendiesEngineStateChange" object:nil];
        
        [self reloadWallpaperViews];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"];
    if (state) [self transitionToState:state];
}

- (void)reloadWallpaperViews {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.bgView removeFromSuperview];
        [self.floatingView removeFromSuperview];
        [self.fgView removeFromSuperview];
        self.bgView = nil; self.floatingView = nil; self.fgView = nil;
        
        if (!g_enabled) {
            WriteLog(@"插件未开启，清理渲染层");
            return;
        }
        
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!g_tendiesPath || ![fm fileExistsAtPath:g_tendiesPath]) {
            WriteLog(@"❌ 引擎未找到资源路径: %@", g_tendiesPath);
            return;
        }
        
        void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
        if (!handle) return; 
        
        Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
        if (!PackageViewClass) return;

        NSString *bgPath = nil; NSString *floatPath = nil; NSString *fgPath = nil;
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
        
        for (NSURL *fileURL in dirEnum) {
            NSString *pathString = fileURL.path;
            // 清洗部分系统带来的末尾斜杠
            if ([pathString hasSuffix:@"/"]) {
                pathString = [pathString substringToIndex:pathString.length - 1];
            }
            
            if ([pathString hasSuffix:@".ca"]) {
                NSString *fileName = [pathString lastPathComponent];
                if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) bgPath = pathString;
                else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) floatPath = pathString;
                else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) fgPath = pathString;
            }
        }

        if (bgPath) {
            self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:bgPath]];
            self.bgView.frame = self.bounds;
            self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self addSubview:self.bgView];
        }
        if (floatPath) {
            self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:floatPath]];
            self.floatingView.frame = self.bounds;
            self.floatingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self addSubview:self.floatingView];
        }
        if (fgPath) {
            self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:fgPath]];
            self.fgView.frame = self.bounds;
            self.fgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self addSubview:self.fgView];
        }
        
        WriteLog(@"✅ 动效视图成功挂载，初始化 Locked 状态");
        [self transitionToState:@"Locked"];
    });
}

- (void)transitionToState:(NSString *)stateName {
    if (!g_enabled) return;
    [self.bgView setState:stateName];
    [self.floatingView setState:stateName];
    [self.fgView setState:stateName];
}
@end

// ==========================================
// 5. Hook 锁屏控制器高级防遮挡注入
// ==========================================
%hook CSCoverSheetViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (!g_enabled) return;

    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineKey");
    if (!engineView) {
        WriteLog(@"✨ 检测到锁屏创建，无缝织入 Tendies 渲染引擎...");
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.view.bounds];
        objc_setAssociatedObject(self, "TendiesEngineKey", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    if (engineView.superview != self.view) {
        [self.view insertSubview:engineView atIndex:0];
    }
    
    engineView.frame = self.view.bounds;
    engineView.layer.zPosition = -9999; // 强行沉底，防止硬阻断
    [self.view sendSubviewToBack:engineView];
    
    // 【核心抹杀】刺穿系统级 PosterKit 海报遮挡层
    if ([self respondsToSelector:@selector(_backgroundContentViewController)]) {
        id bgVC = [self _backgroundContentViewController];
        if (bgVC && [bgVC respondsToSelector:@selector(view)]) {
            UIView *bgView = [bgVC view];
            if (bgView && (!bgView.hidden || bgView.alpha > 0)) {
                WriteLog(@"🛡️ 成功拦截并隐藏系统海报背景层，强制腾出舞台");
                bgView.hidden = YES;
                bgView.alpha = 0.0;
                bgView.layer.opacity = 0.0;
            }
        }
    }
}

// 状态拦截传递
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *state = mode ? @"Sleep" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
    %orig;
    NSString *state = mode ? @"Sleep" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

- (void)setDismissed:(BOOL)dismissed {
    %orig;
    NSString *state = dismissed ? @"Unlock" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}
%end

// ==========================================
// 6. 构造初始化
// ==========================================
%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                    NULL, 
                                    prefsChangedCallback, 
                                    CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), 
                                    NULL, 
                                    CFNotificationSuspensionBehaviorCoalesce);
}
