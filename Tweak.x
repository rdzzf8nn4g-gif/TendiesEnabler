#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ==========================================
// 结构体与系统头文件声明
// ==========================================
typedef struct {
    long long x0;
    long long x1;
    double x2;
} PBUIWallpaperTransitionState;

@interface PBUIWallpaperViewController : UIViewController
@property (retain, nonatomic) UIView *homescreenWallpaperView;
@property (retain, nonatomic) UIView *lockscreenWallpaperView;
- (void)tendies_mountHomeEngine;
- (void)tendies_mountLockEngineLegacy;
@end

@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
- (BOOL)setState:(NSString *)state animated:(BOOL)animated;
@end

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
- (void)updateWallpaperAnimationWithProgress:(double)progress;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)tendies_mountLockEngine; 
@end

// ==========================================
// 全局变量与配置管理
// ==========================================
static NSString * GetTendiesStorageDir() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesenabler.media";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

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
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

// ==========================================
// 核心渲染引擎 (双引擎架构)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, assign) NSInteger engineType; // 0 = 锁屏引擎, 1 = 桌面引擎
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isPathCached;
@property (nonatomic, assign) BOOL isUnlocking; 
@property (nonatomic, strong) NSString *cachedBgPath;
@property (nonatomic, strong) NSString *cachedFloatPath;
@property (nonatomic, strong) NSString *cachedFgPath;
@property (nonatomic, strong) NSString *currentState;

- (void)reloadWallpaperViews;
- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated;
@end

@implementation TendiesRenderEngineView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor]; 
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.isPathCached = NO;
        self.isUnlocking = NO;
        self.currentState = @"Init";
        self.engineType = 0; // 默认锁屏
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onProgress:) name:@"TendiesEngineProgress" object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)forceReload {
    self.isPathCached = NO;
    self.cachedBgPath = nil;
    self.cachedFloatPath = nil;
    self.cachedFgPath = nil;
    [self reloadWallpaperViews];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.bgView) self.bgView.frame = self.bounds;
    if (self.floatingView) self.floatingView.frame = self.bounds;
    if (self.fgView) self.fgView.frame = self.bounds;
}

// 🎯 仅锁屏引擎接收滑动进度，桌面引擎永远保持 Unlock
- (void)onProgress:(NSNotification *)note {
    if (!g_enabled) return;
    if (self.engineType == 1) return; // 💡 桌面引擎直接忽略滑动进度
    
    double progress = [note.userInfo[@"progress"] doubleValue];
    
    if (progress > 0.05) {
        if (!self.isUnlocking) {
            self.isUnlocking = YES;
            [self transitionToState:@"Unlock" animated:YES];
        }
    } else {
        if (self.isUnlocking) {
            self.isUnlocking = NO;
            [self transitionToState:@"Locked" animated:YES];
        }
    }
}

// 🎯 核心修复 1：彻底消灭“假渐变”，强行包裹位移与缩放动画
- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated {
    if (!g_enabled) return;
    if ([self.currentState isEqualToString:stateName]) return;
    self.currentState = [stateName copy];
    
    if (animated) {
        [CATransaction begin];
        // 强制设置 0.8 秒动画，匹配 CAML 的手感
        [CATransaction setAnimationDuration:0.8];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        
        // ⚠️ 传入 animated:NO，剥夺底层组件的控制权，让我们的 CATransaction 强制接管 position 和 bounds！
        if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
            [self.bgView setState:stateName animated:NO];
            [self.floatingView setState:stateName animated:NO];
            [self.fgView setState:stateName animated:NO];
        } else {
            [self.bgView setState:stateName];
            [self.floatingView setState:stateName];
            [self.fgView setState:stateName];
        }
        [CATransaction commit];
    } else {
        if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
            [self.bgView setState:stateName animated:NO];
            [self.floatingView setState:stateName animated:NO];
            [self.fgView setState:stateName animated:NO];
        } else {
            [self.bgView setState:stateName];
            [self.floatingView setState:stateName];
            [self.fgView setState:stateName];
        }
    }
}

// 🎯 精准解析 Wallpaper.plist (支持多层联动)
- (void)parseWallpaperPlist {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plistPath = nil;
    
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:g_tendiesPath];
    for (NSString *file in enumerator) {
        if ([file.lastPathComponent isEqualToString:@"Wallpaper.plist"]) {
            plistPath = [g_tendiesPath stringByAppendingPathComponent:file];
            break;
        }
    }
    
    if (plistPath && [fm fileExistsAtPath:plistPath]) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSDictionary *defaultAssets = dict[@"assets"][@"lockAndHome"][@"default"];
        if (defaultAssets) {
            NSString *baseDir = [plistPath stringByDeletingLastPathComponent];
            NSString *bgName = defaultAssets[@"backgroundAnimationFileName"];
            NSString *floatName = defaultAssets[@"floatingAnimationFileNameKey"] ?: defaultAssets[@"floatingAnimationFileName"];
            NSString *fgName = defaultAssets[@"foregroundAnimationFileName"];
            
            if (bgName) self.cachedBgPath = [baseDir stringByAppendingPathComponent:bgName];
            if (floatName) self.cachedFloatPath = [baseDir stringByAppendingPathComponent:floatName];
            if (fgName) self.cachedFgPath = [baseDir stringByAppendingPathComponent:fgName];
            
            self.isPathCached = YES;
            return;
        }
    }
    
    // Fallback 方案
    NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *fileURL in dirEnum) {
        NSString *pathString = fileURL.path;
        NSString *fileName = fileURL.lastPathComponent;
        if ([pathString hasSuffix:@"/"]) pathString = [pathString substringToIndex:pathString.length - 1];
        if ([[[pathString pathExtension] lowercaseString] isEqualToString:@"ca"] || [pathString hasSuffix:@".ca"]) {
            if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) self.cachedBgPath = [pathString copy];
            else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) self.cachedFloatPath = [pathString copy];
            else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) self.cachedFgPath = [pathString copy];
        }
    }
    self.isPathCached = YES;
}

- (void)reloadWallpaperViews {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (!g_enabled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
                self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            });
            return;
        }
        
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!g_tendiesPath || ![fm fileExistsAtPath:g_tendiesPath]) return;
        
        @synchronized(self) {
            if (!self.isPathCached) [self parseWallpaperPlist];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
            self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
            if (!handle) return; 
            Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
            if (!PackageViewClass) return;

            if (self.cachedBgPath) {
                self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedBgPath]];
                [self addSubview:self.bgView];
            }
            if (self.cachedFloatPath) {
                self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFloatPath]];
                [self addSubview:self.floatingView];
            }
            if (self.cachedFgPath) {
                self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFgPath]];
                [self addSubview:self.fgView];
            }
            [self setNeedsLayout];
            
            // 💡 核心修复 2：桌面引擎直接暴力进入 Unlock 状态，永远不显示锁屏画面
            self.currentState = @"Init";
            [CATransaction begin];
            if (self.engineType == 1) {
                [self transitionToState:@"Unlock" animated:NO]; 
            } else {
                [self transitionToState:@"Locked" animated:NO];
            }
            [CATransaction commit];
            [CATransaction flush];
        });
    });
}
@end


// ==========================================
// 💡 终极修复 3：双引擎分离挂载，保留原生高斯模糊
// ==========================================

// 负责桌面的原生控制器
%hook PBUIWallpaperViewController
%new
- (void)tendies_mountHomeEngine {
    UIView *homeView = [self respondsToSelector:@selector(homescreenWallpaperView)] ? [self homescreenWallpaperView] : nil;
    if (homeView) {
        // 隐藏自带壁纸元素
        for (UIView *sub in homeView.subviews) {
            if (![sub isKindOfClass:[TendiesRenderEngineView class]]) sub.hidden = YES;
        }
        TendiesRenderEngineView *homeEngine = objc_getAssociatedObject(self, "HomeEngine");
        if (!homeEngine) {
            homeEngine = [[TendiesRenderEngineView alloc] initWithFrame:homeView.bounds];
            homeEngine.engineType = 1; // 💡 标记为桌面引擎
            [homeEngine reloadWallpaperViews];
            objc_setAssociatedObject(self, "HomeEngine", homeEngine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [homeView addSubview:homeEngine];
        }
        if (homeEngine.superview != homeView) {
            [homeEngine removeFromSuperview]; [homeView addSubview:homeEngine];
        }
        homeEngine.frame = homeView.bounds;
        [homeView bringSubviewToFront:homeEngine];
    }
}

%new
- (void)tendies_mountLockEngineLegacy {
    UIView *lockView = [self respondsToSelector:@selector(lockscreenWallpaperView)] ? [self lockscreenWallpaperView] : nil;
    if (lockView) {
        for (UIView *sub in lockView.subviews) {
            if (![sub isKindOfClass:[TendiesRenderEngineView class]]) sub.hidden = YES;
        }
        TendiesRenderEngineView *lockEngine = objc_getAssociatedObject(self, "LockEngineLegacy");
        if (!lockEngine) {
            lockEngine = [[TendiesRenderEngineView alloc] initWithFrame:lockView.bounds];
            lockEngine.engineType = 0; // 💡 标记为锁屏引擎
            [lockEngine reloadWallpaperViews];
            objc_setAssociatedObject(self, "LockEngineLegacy", lockEngine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [lockView addSubview:lockEngine];
        }
        if (lockEngine.superview != lockView) {
            [lockEngine removeFromSuperview]; [lockView addSubview:lockEngine];
        }
        lockEngine.frame = lockView.bounds;
        [lockView bringSubviewToFront:lockEngine];
    }
}

- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) {
        [self tendies_mountHomeEngine];
        [self tendies_mountLockEngineLegacy];
    }
}
// 阻止过渡截屏生成假画面
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state {
    if (g_enabled) return nil;
    return %orig;
}
- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)oldState newState:(void *)newState oldEffectView:(id *)oldView newEffectView:(id *)newView {
    if (g_enabled) return NO;
    return %orig;
}
%end


// 负责锁屏与通知中心的控制器 (iOS 16+)
%hook CSCoverSheetViewController
%new
- (void)tendies_mountLockEngine {
    UIViewController *bgVC = [self valueForKey:@"_backgroundContentViewController"];
    if (bgVC && bgVC.view) {
        // 只隐藏原生的 Poster 图层，绝对不隐藏模糊层！
        for (UIView *sub in bgVC.view.subviews) {
            if (![sub isKindOfClass:[TendiesRenderEngineView class]]) sub.hidden = YES;
        }
        TendiesRenderEngineView *lockEngine = objc_getAssociatedObject(self, "LockEngine");
        if (!lockEngine) {
            lockEngine = [[TendiesRenderEngineView alloc] initWithFrame:bgVC.view.bounds];
            lockEngine.engineType = 0; // 💡 标记为锁屏引擎
            [lockEngine reloadWallpaperViews];
            objc_setAssociatedObject(self, "LockEngine", lockEngine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [bgVC.view addSubview:lockEngine];
        }
        if (lockEngine.superview != bgVC.view) {
            [lockEngine removeFromSuperview]; [bgVC.view addSubview:lockEngine];
        }
        lockEngine.frame = bgVC.view.bounds;
        [bgVC.view bringSubviewToFront:lockEngine];
    }
    
    // 隐藏景深遮挡特效
    UIView *floatingLayer = [self valueForKey:@"_floatingLayerView"];
    if (floatingLayer) floatingLayer.hidden = YES;
}

- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) [self tendies_mountLockEngine];
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (g_enabled) [self tendies_mountLockEngine];
}

- (void)_updateBackgroundContentView {
    %orig;
    if (g_enabled) [self tendies_mountLockEngine];
}

// 阻止海报更新快照
- (void)updatePosterSwitcherSnapshots {
    if (g_enabled) return;
    %orig;
}
%end

// ==========================================
// 进度获取
// ==========================================
%hook SBWallpaperController
- (void)updateWallpaperAnimationWithProgress:(double)progress {
    %orig;
    if (g_enabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
        });
    }
}
%end

// ==========================================
// 构造函数
// ==========================================
%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
