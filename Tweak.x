#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 1. 物理日志系统 (方便排错)
// ==========================================
static NSString * GetLogFilePath() {
    NSString *base = @"/var/mobile/Library/Caches";
#if __has_include(<roothide.h>)
    base = jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        base = [@"/var/jb" stringByAppendingPathComponent:base];
    }
#endif
    return [base stringByAppendingPathComponent:@"TendiesEnabler.log"];
}

#define TENDIES_LOG(fmt, ...) do { \
    NSString *logMsg = [NSString stringWithFormat:@"[%@] " fmt @"\n", [NSDate date], ##__VA_ARGS__]; \
    NSString *logPath = GetLogFilePath(); \
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath]; \
    if (!fileHandle) { \
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil]; \
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath]; \
    } \
    [fileHandle seekToEndOfFile]; \
    [fileHandle writeData:[logMsg dataUsingEncoding:NSUTF8StringEncoding]]; \
    [fileHandle closeFile]; \
} while(0)

static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【替换为你真实的 BundleID】
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

// ==========================================
// 2. 动态调用的私有 API 接口声明
// ==========================================
// 专门用来播放 .ca (CAML) 动画包的私有视图
@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
@end

// ==========================================
// 3. 我们的核心渲染引擎管理器
// ==========================================
@interface TendiesRenderEngine : NSObject
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isEnabled;

+ (instancetype)sharedEngine;
- (void)reloadWallpaper;
- (void)attachToContainerView:(UIView *)containerView;
- (void)transitionToState:(NSString *)stateName;
@end

@implementation TendiesRenderEngine

+ (instancetype)sharedEngine {
    static TendiesRenderEngine *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)reloadWallpaper {
    TENDIES_LOG(@"🔄 渲染引擎开始重载壁纸...");
    
    // 清除旧的图层
    [self.bgView removeFromSuperview];
    [self.floatingView removeFromSuperview];
    [self.fgView removeFromSuperview];
    self.bgView = nil;
    self.floatingView = nil;
    self.fgView = nil;
    
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
    self.isEnabled = [prefs[@"Enabled"] boolValue];
    
    if (!self.isEnabled) {
        TENDIES_LOG(@"⚠️ 插件已关闭，不渲染任何图层。");
        return;
    }
    
    NSString *tendiesPath = prefs[@"TendiesPath"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!tendiesPath || ![fm fileExistsAtPath:tendiesPath]) {
        TENDIES_LOG(@"❌ 渲染失败：未找到壁纸路径 %@", tendiesPath);
        return;
    }
    
    // 强制加载 BaseBoardUI 框架 (BSUICAPackageView 所在框架)
    dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
    Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
    if (!PackageViewClass) {
        TENDIES_LOG(@"❌ 致命错误：无法加载系统 BSUICAPackageView 类！");
        return;
    }

    NSString *bgPath = nil;
    NSString *floatPath = nil;
    NSString *fgPath = nil;

    // 遍历查找 .ca 结尾的动画文件夹
    NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:tendiesPath];
    NSString *file;
    while ((file = [dirEnum nextObject])) {
        if ([file hasSuffix:@".ca"]) {
            NSString *fullPath = [tendiesPath stringByAppendingPathComponent:file];
            if ([file containsString:@"Background"]) bgPath = fullPath;
            else if ([file containsString:@"Floating"]) floatPath = fullPath;
            else if ([file containsString:@"Foreground"]) fgPath = fullPath;
        }
    }

    // 实例化 CA 动画视图
    if (bgPath) {
        TENDIES_LOG(@"✅ 加载背景层: %@", bgPath);
        self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:bgPath]];
        self.bgView.layer.zPosition = -100; // 最底层
    }
    if (floatPath) {
        TENDIES_LOG(@"✅ 加载景深层: %@", floatPath);
        self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:floatPath]];
        self.floatingView.layer.zPosition = 100; // 中间层
    }
    if (fgPath) {
        TENDIES_LOG(@"✅ 加载前景层: %@", fgPath);
        self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:fgPath]];
        self.fgView.layer.zPosition = 200; // 最上层
    }
    
    // 初始状态为锁屏
    [self transitionToState:@"Locked"];
}

- (void)attachToContainerView:(UIView *)containerView {
    if (!self.isEnabled) return;
    
    // 把我们的动画图层塞进系统提供的容器里
    if (self.bgView && self.bgView.superview != containerView) {
        self.bgView.frame = containerView.bounds;
        self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [containerView addSubview:self.bgView];
    }
    if (self.floatingView && self.floatingView.superview != containerView) {
        self.floatingView.frame = containerView.bounds;
        self.floatingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [containerView addSubview:self.floatingView];
    }
    if (self.fgView && self.fgView.superview != containerView) {
        self.fgView.frame = containerView.bounds;
        self.fgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [containerView addSubview:self.fgView];
    }
}

- (void)transitionToState:(NSString *)stateName {
    TENDIES_LOG(@"🎬 切换动画状态: %@", stateName);
    [self.bgView setState:stateName];
    [self.floatingView setState:stateName];
    [self.fgView setState:stateName];
}

@end

// ==========================================
// 4. Hook SpringBoard 渲染容器
// ==========================================

// 拦截系统底层的壁纸容器，把我们的动画引擎挂载上去
%hook PBUIWallpaperView

- (void)layoutSubviews {
    %orig; // 保持系统原有布局
    
    UIView *contentView = [self performSelector:@selector(contentView)];
    if (contentView) {
        [[TendiesRenderEngine sharedEngine] attachToContainerView:contentView];
    }
}

%end

// ==========================================
// 5. Hook 锁屏控制器，触发动画状态
// ==========================================

// 拦截锁屏控制器，这样才能触发马里奥跳出来（Unlock）或者待机（Sleep）的交互动画
%hook CSCoverSheetViewController

// 当屏幕熄灭或亮起时
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (mode) {
        [[TendiesRenderEngine sharedEngine] transitionToState:@"Sleep"];
    } else {
        [[TendiesRenderEngine sharedEngine] transitionToState:@"Locked"];
    }
}

// 当锁屏被 Dismiss（即解锁进入主屏幕）时
- (void)setDismissed:(BOOL)dismissed {
    %orig;
    if (dismissed) {
        [[TendiesRenderEngine sharedEngine] transitionToState:@"Unlock"];
    } else {
        [[TendiesRenderEngine sharedEngine] transitionToState:@"Locked"];
    }
}

%end

// ==========================================
// 6. 接收设置更新通知
// ==========================================
static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    TENDIES_LOG(@"📥 收到设置界面的刷新通知，开始重载渲染引擎！");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TendiesRenderEngine sharedEngine] reloadWallpaper];
        
        // 强制刷新系统桌面以重绘 Layout
        Class sbWallpaperControllerClass = NSClassFromString(@"SBWallpaperController");
        if (sbWallpaperControllerClass) {
            id wc = [sbWallpaperControllerClass performSelector:@selector(sharedInstance)];
            if ([wc respondsToSelector:@selector(activeLockScreenPosterConfiguration)]) {
                id lock = [wc performSelector:@selector(activeLockScreenPosterConfiguration)];
                id home = [wc performSelector:@selector(activeHomeScreenPosterConfiguration)];
                if ([wc respondsToSelector:@selector(_updateForLockScreenPosterConfiguration:homeScreenPosterConfiguration:)]) {
                    [wc performSelector:@selector(_updateForLockScreenPosterConfiguration:homeScreenPosterConfiguration:) withObject:lock withObject:home];
                }
            }
        }
    });
}

%ctor {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
        TENDIES_LOG(@"🚀 TendiesEnabler 已成功注入 SpringBoard。开始初始化渲染引擎。");
        
        // 初始化时加载一次
        [[TendiesRenderEngine sharedEngine] reloadWallpaper];
        
        // 监听设置 App 的刷新通知
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                        NULL, 
                                        PrefsNotificationCallback, 
                                        CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), 
                                        NULL, 
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
