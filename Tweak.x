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
- (void)tendies_applyHomescreenModifications;
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

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
@property (readonly, nonatomic) long long backlightState;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)tendies_applyLockscreenModifications;
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
static BOOL g_isUnlocked = NO; 
static BOOL g_isScreenOn = YES;

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
// 核心渲染引擎 (双引擎分离架构)
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
        self.engineType = 0; // 默认是锁屏
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"TendiesEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"TendiesEngineSleep" object:nil];
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

- (void)onWakeUp {
    if (!g_enabled) return;
    if (self.engineType == 1) return; // 💡 桌面引擎不参与亮屏动画，永远保持 Unlock
    
    self.isUnlocking = NO;
    [CATransaction begin];
    [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
    [CATransaction commit];
    [CATransaction flush];
}

- (void)onSleep {
    if (!g_enabled) return;
    if (self.engineType == 1) return; // 💡 桌面引擎不参与灭屏动画
    
    self.isUnlocking = NO;
    [self transitionToState:@"Sleep" animated:NO];
}

// 🎯 只允许锁屏引擎跟踪滑动阻尼
- (void)onProgress:(NSNotification *)note {
    if (!g_enabled) return;
    if (self.engineType == 1) return; // 💡 桌面引擎直接忽略一切锁屏滑动
    
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

// 🎯 核心修复：CATransaction 强制接管动画属性，彻底消灭“假渐变”
- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated {
    if (!g_enabled) return;
    if ([self.currentState isEqualToString:stateName]) return;
    self.currentState = [stateName copy];
    
    if (animated) {
        [CATransaction begin];
        // 设置 0.8s 匹配 WWDC 官方 CAML 的时长
        [CATransaction setAnimationDuration:0.8];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        
        // ⚠️ 传入 animated:NO 阻止包内部不完整的动画，让 CATransaction 强制动画所有属性(坐标、缩放等)
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

// 🎯 精确读取 Wallpaper.plist 实现多层 CA 完美挂载
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
    
    // Fallback 老旧壁纸
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
            
            // 💡 桌面引擎初始化后立刻暴力锁死为 Unlock，绝不参与锁屏逻辑
            self.currentState = @"Init";
            [CATransaction begin];
            if (self.engineType == 1) {
                [self transitionToState:@"Unlock" animated:NO]; 
            } else {
                [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
            }
            [CATransaction commit];
            [CATransaction flush];
        });
    });
}
@end


// ==========================================
// 💡 精准挂载架构：消除“完全不显示”与“下拉透明”Bug
// ==========================================

// 1. 桌面引擎：挂载在 SpringBoard 桌面控制器上
%hook PBUIWallpaperViewController
%new
- (void)tendies_applyHomescreenModifications {
    if (!g_enabled) return;
    UIView *homeView = [self respondsToSelector:@selector(homescreenWallpaperView)] ? [self homescreenWallpaperView] : nil;
    if (homeView) {
        TendiesRenderEngineView *homeEngine = objc_getAssociatedObject(self, "HomeEngine");
        if (!homeEngine) {
            homeEngine = [[TendiesRenderEngineView alloc] initWithFrame:homeView.bounds];
            homeEngine.engineType = 1; // 💡 设置为桌面引擎
            [homeEngine reloadWallpaperViews];
            objc_setAssociatedObject(self, "HomeEngine", homeEngine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (homeEngine.superview != homeView) {
            [homeEngine removeFromSuperview];
            [homeView addSubview:homeEngine];
        }
        homeEngine.frame = homeView.bounds;
    }
}

- (void)viewWillLayoutSubviews {
    %orig;
    [self tendies_applyHomescreenModifications];
}

// 阻止桌面刷新多余系统快照
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state {
    if (g_enabled) return nil;
    return %orig;
}
- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)oldState newState:(void *)newState oldEffectView:(id *)oldView newEffectView:(id *)newView {
    if (g_enabled) return NO;
    return %orig;
}
%end


// 2. 锁屏引擎：挂载在 CoverSheet 内部 (修复完全不显示)
%hook CSCoverSheetViewController
%new
- (void)tendies_applyLockscreenModifications {
    if (!g_enabled) return;

    UIViewController *bgVC = [self valueForKey:@"_backgroundContentViewController"];
    if (bgVC && bgVC.view) {
        // 隐藏自带的系统海报
        bgVC.view.alpha = 0.0;
        bgVC.view.hidden = YES;
        
        // ⚠️ 极其关键：我们的引擎必须挂载在原生海报的**父视图 (superview)** 上
        // 绝对不能挂载在 bgVC.view 里面，否则会被上面的代码连带隐藏！
        UIView *container = bgVC.view.superview;
        if (container) {
            TendiesRenderEngineView *lockEngine = objc_getAssociatedObject(self, "LockEngine");
            if (!lockEngine) {
                lockEngine = [[TendiesRenderEngineView alloc] initWithFrame:container.bounds];
                lockEngine.engineType = 0; // 💡 设置为锁屏引擎
                [lockEngine reloadWallpaperViews];
                objc_setAssociatedObject(self, "LockEngine", lockEngine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (lockEngine.superview != container) {
                [lockEngine removeFromSuperview];
                // 插入到底部，防止遮挡系统时间
                [container insertSubview:lockEngine atIndex:0];
            }
            lockEngine.frame = container.bounds;
        }
    }
    
    // 隐藏碍事的景深悬浮特效层
    UIView *floatingLayer = [self valueForKey:@"_floatingLayerView"];
    if (floatingLayer) {
        floatingLayer.alpha = 0.0;
        floatingLayer.hidden = YES;
    }
}

- (void)viewWillLayoutSubviews {
    %orig;
    [self tendies_applyLockscreenModifications];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [self tendies_applyLockscreenModifications];
}

// 暴力镇压系统每次滑动的自动复原
- (void)_updateBackgroundContentView {
    %orig;
    [self tendies_applyLockscreenModifications];
}
- (void)_updateWallpaperEffectView {
    %orig;
    [self tendies_applyLockscreenModifications];
}
- (void)_updateWallpaper {
    %orig;
    [self tendies_applyLockscreenModifications];
}
// 防止截取原生快照
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
// 亮灭屏与锁屏状态同步
// ==========================================
%hook SBBacklightController
- (void)setBacklightState:(long long)state source:(long long)source {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:(g_isScreenOn ? @"TendiesEngineWake" : @"TendiesEngineSleep") object:nil];
            });
        }
    }
}
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:(g_isScreenOn ? @"TendiesEngineWake" : @"TendiesEngineSleep") object:nil];
            });
        }
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
