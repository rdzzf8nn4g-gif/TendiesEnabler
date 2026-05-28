#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ==========================================
// 1. 终极环境路径适配 (Rootful/Rootless/Roothide)
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

// 物理调试日志系统
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

// 递归打印视图层级树的调试助手 (破除隐藏遮挡黑盒)
static void LogViewHierarchy(UIView *view, int depth) {
    if (!view) return;
    NSString *indent = [@"" stringByPaddingToLength:(depth * 4) withString:@" " startingAtIndex:0];
    WriteLog(@"%@-> Class: %@, Frame: %@, Hidden: %d, Alpha: %.2f", indent, NSStringFromClass([view class]), NSStringFromCGRect(view.frame), view.hidden, view.alpha);
    for (UIView *subview in view.subviews) {
        LogViewHierarchy(subview, depth + 1);
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
- (id)_backgroundContentViewController; 
@end

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end

// ==========================================
// 3. 动态配置全局变量
// ==========================================
static BOOL g_enabled = NO;
static NSString *g_tendiesPath = nil;

static void reloadPrefs() {
    CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
    CFPreferencesAppSynchronize(appID);
    
    Boolean valid;
    g_enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &valid) ? valid : NO;
    
    CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("TendiesPath"), appID);
    if (pathRef && CFGetTypeID(pathRef) == CFStringGetTypeID()) {
        g_tendiesPath = [(__bridge NSString *)pathRef copy];
    } else {
        g_tendiesPath = [GetTendiesStorageDir() stringByAppendingPathComponent:@"ActiveTendies"];
    }
    
    WriteLog(@"配置重载完成 - 开关: %d, 路径: %@", g_enabled, g_tendiesPath);
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
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

// 核心修复位置 1：强制在布局周期刷新子视动效宽高，对抗生命周期初始零尺寸塌陷
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.bgView) self.bgView.frame = self.bounds;
    if (self.floatingView) self.floatingView.frame = self.bounds;
    if (self.fgView) self.fgView.frame = self.bounds;
}

- (void)reloadWallpaperViews {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.bgView removeFromSuperview];
        [self.floatingView removeFromSuperview];
        [self.fgView removeFromSuperview];
        self.bgView = nil; self.floatingView = nil; self.fgView = nil;
        
        if (!g_enabled) return;
        
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!g_tendiesPath || ![fm fileExistsAtPath:g_tendiesPath]) return;
        
        void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
        if (!handle) return; 
        
        Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
        if (!PackageViewClass) return;

        NSString *bgPath = nil; NSString *floatPath = nil; NSString *fgPath = nil;
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
        
        for (NSURL *fileURL in dirEnum) {
            NSString *pathString = fileURL.path;
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
    
    // 核心修复位置 2：移除强行沉底的 zPosition = -9999 机制，改用高级自动化层级算法
    // 动态扫描锁屏下的子视图，寻找不透明的原生 Wallpaper 或是 Poster 视图
    UIView *targetWallpaperView = nil;
    for (UIView *subview in self.view.subviews) {
        NSString *className = NSStringFromClass([subview class]);
        if ([className containsString:@"Poster"] || [className containsString:@"Wallpaper"] || [className containsString:@"Background"] || [className containsString:@"Backdrop"]) {
            targetWallpaperView = subview;
        }
    }
    
    if (targetWallpaperView) {
        if (engineView.superview != self.view) {
            // 精准注入：将我们的引擎插入到原生不透明壁纸层的正上方！既不沉底被挡住，也不顶置盖死时钟 UI
            [self.view insertSubview:engineView aboveSubview:targetWallpaperView];
            WriteLog(@"🎯 智能层级匹配：已成功把引擎叠在系统层 [%@] 之上", NSStringFromClass([targetWallpaperView class]));
        }
    } else {
        if (engineView.superview != self.view) {
            [self.view insertSubview:engineView atIndex:0];
            WriteLog(@"⚠️ 未扫描到明确海报层，降级插入视图最底层");
        }
    }
    
    engineView.frame = self.view.bounds;
    
    // 核心修复位置 3：全自动化抓取锁屏的完整视图拓扑树，方便在日志文件中一目了然
    static BOOL hasLoggedHierarchy = NO;
    if (!hasLoggedHierarchy) {
        WriteLog(@"========== [调试] 开始打印锁屏视图层级全拓扑 ==========");
        LogViewHierarchy(self.view, 0);
        WriteLog(@"========== [调试] 锁屏视图层级全拓扑打印结束 ==========");
        hasLoggedHierarchy = YES;
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
