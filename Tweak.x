#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 1. 物理日志系统 (修正无根沙盒写入权限)
// ==========================================
static void WriteLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSString *logMsg = [NSString stringWithFormat:@"[%@] 🚀 Tendies: %@\n", [NSDate date], message];
    // 写入 /var/mobile 目录下确保任何进程都有权限，避免 tmp 被沙盒拦截
    NSString *logPath = @"/var/mobile/Documents/tendies_debug.log"; 
    
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

// 核心修复：更正 Preferences 路径
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    // Rootless 环境下 preferences 依然处于真实系统的 /var/mobile 空间
    return base;
#endif
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
// iOS 16/17 背景壁纸控制器
- (id)_backgroundContentViewController; 
@end

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end

// ==========================================
// 3. 自定义渲染引擎视图
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isEnabled;

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
        
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
        self.isEnabled = [prefs[@"Enabled"] boolValue];
        
        WriteLog(@"读取配置，Enabled 状态: %d", self.isEnabled);
        if (!self.isEnabled) return;
        
        NSString *tendiesPath = prefs[@"TendiesPath"];
        NSFileManager *fm = [NSFileManager defaultManager];
        WriteLog(@"目标壁纸解压路径: %@", tendiesPath);
        if (!tendiesPath || ![fm fileExistsAtPath:tendiesPath]) {
            WriteLog(@"❌ 未找到解压目录");
            return;
        }
        
        void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
        if (!handle) {
            WriteLog(@"❌ 动态加载 BaseBoardUI 失败");
            return;
        }
        
        Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
        if (!PackageViewClass) return;

        NSString *bgPath = nil; NSString *floatPath = nil; NSString *fgPath = nil;
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:tendiesPath] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
        
        for (NSURL *fileURL in dirEnum) {
            NSNumber *isDirectory;
            [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
            if ([isDirectory boolValue]) {
                // 核心修复：改用 pathExtension 判断，防止因斜杠导致 hasSuffix 失效
                NSString *extension = [fileURL.lastPathComponent pathExtension];
                if ([extension iSEqualToString:@"ca"]) {
                    NSString *fileName = fileURL.lastPathComponent;
                    WriteLog(@"发现 Mica 包: %@", fileName);
                    if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) bgPath = fileURL.path;
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) floatPath = fileURL.path;
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) fgPath = fileURL.path;
                }
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
        WriteLog(@"✅ 壁纸图层挂载成功");
        [self transitionToState:@"Locked"];
    });
}

- (void)transitionToState:(NSString *)stateName {
    if (!self.isEnabled) return;
    [self.bgView setState:stateName];
    [self.floatingView setState:stateName];
    [self.fgView setState:stateName];
}
@end

// ==========================================
// 4. Hook 锁屏控制器高级防遮挡注入
// ==========================================
%hook CSCoverSheetViewController

// 核心修复位置：在布局子视图时动态计算层级，防范 PosterKit 强行置顶
- (void)viewDidLayoutSubviews {
    %orig;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngine");
    if (!engineView) {
        WriteLog(@"✨ 正在初始化交互渲染引擎并注入视图层...");
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.view.bounds];
        objc_setAssociatedObject(self, "TendiesEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.view addSubview:engineView];
    }
    
    // 动态置顶防遮挡策略：
    // 如果系统拥有壁纸背景层，我们强行把自己移到壁纸层的正上方，从而不遮挡时钟，但能覆盖壁纸
    if ([self respondsToSelector:@selector(_backgroundContentViewController)]) {
        id bgVC = [self _backgroundContentViewController];
        if (bgVC && [bgVC respondsToSelector:@selector(view)]) {
            UIView *bgView = [bgVC view];
            if (bgView && bgView.superview == self.view) {
                // 确保我们的引擎恰好在原生壁纸层的上面一层
                [self.view insertSubview:engineView aboveSubview:bgView];
                return;
            }
        }
    }
    
    // 备用兜底策略
    [self.view sendSubviewToBack:engineView];
}

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
// 5. 设置中心通知
// ==========================================
static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PrefsNotificationCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
%end
