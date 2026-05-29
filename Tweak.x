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
// 核心私有 API 声明 & 结构体
// ==========================================
typedef struct {
    long long x0;
    long long x1;
    double x2;
} PBUIWallpaperTransitionState;

@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
- (BOOL)setState:(NSString *)state animated:(BOOL)animated;
@end

@interface PBUIWallpaperViewController : UIViewController
@property (retain, nonatomic) UIView *homescreenWallpaperView;
@property (retain, nonatomic) UIView *lockscreenWallpaperView;
@property (retain, nonatomic) UIView *sharedWallpaperView;
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state;
- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)state newState:(void *)state oldEffectView:(id *)view newEffectView:(id *)view;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
@property (readonly, nonatomic) long long backlightState;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setDismissed:(BOOL)dismissed;
@end

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
- (void)updateWallpaperAnimationWithProgress:(double)progress;
@end

// 声明背景控制器
@interface CSBackgroundContentViewController : UIViewController
@end

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
// 核心渲染引擎 (双轨制：桌面与锁屏相互独立)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) NSString *engineType; // "Lock" 或 "Home"
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isPathCached;
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
        self.backgroundColor = [UIColor clearColor]; // 必须透明
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.isPathCached = NO;
        self.currentState = @"Init";
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"TendiesEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"TendiesEngineSleep" object:nil];
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

// 🎯 双轨状态机：锁屏引擎永远展示 Locked，桌面引擎永远展示 Unlock。
// 依靠系统原生的上滑手势带动锁屏视图滑动，形成绝美的物理透视与分离交互！
- (void)onWakeUp {
    if (!g_enabled) return;
    [CATransaction begin];
    if ([self.engineType isEqualToString:@"Lock"]) {
        [self transitionToState:@"Locked" animated:YES];
    } else {
        [self transitionToState:@"Unlock" animated:YES];
    }
    [CATransaction commit];
    [CATransaction flush];
}

- (void)onSleep {
    if (!g_enabled) return;
    [self transitionToState:@"Sleep" animated:YES];
}

- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated {
    if (!g_enabled) return;
    if ([self.currentState isEqualToString:stateName]) return; 
    self.currentState = [stateName copy];
    
    if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
        [self.bgView setState:stateName animated:animated];
        [self.floatingView setState:stateName animated:animated];
        [self.fgView setState:stateName animated:animated];
    } else {
        [self.bgView setState:stateName];
        [self.floatingView setState:stateName];
        [self.fgView setState:stateName];
    }
}

// 🎯 严格按照壁纸包结构：深入解析 Wallpaper.plist 获取真实的文件名
- (void)parseWallpaperPlist {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plistPath = nil;
    
    // 递归寻找 Wallpaper.plist
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:g_tendiesPath];
    for (NSString *file in enumerator) {
        if ([file.lastPathComponent isEqualToString:@"Wallpaper.plist"]) {
            plistPath = [g_tendiesPath stringByAppendingPathComponent:file];
            break;
        }
    }
    
    if (plistPath) {
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
    
    // 如果没有找到 plist，兼容降级使用名称匹配
    enumerator = [fm enumeratorAtPath:g_tendiesPath];
    for (NSString *subpath in enumerator) {
        NSString *fileName = subpath.lastPathComponent;
        if ([[[subpath pathExtension] lowercaseString] isEqualToString:@"ca"] || [subpath hasSuffix:@".ca"]) {
            NSString *fullPath = [g_tendiesPath stringByAppendingPathComponent:subpath];
            if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) self.cachedBgPath = fullPath;
            else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) self.cachedFloatPath = fullPath;
            else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) self.cachedFgPath = fullPath;
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
            if (!self.isPathCached) {
                [self parseWallpaperPlist];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
            self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            
            void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
            if (!handle) return; 
            Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
            if (!PackageViewClass) return;

            if (self.cachedBgPath && [fm fileExistsAtPath:self.cachedBgPath]) {
                self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedBgPath]];
                [self addSubview:self.bgView];
            }
            if (self.cachedFloatPath && [fm fileExistsAtPath:self.cachedFloatPath]) {
                self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFloatPath]];
                [self addSubview:self.floatingView];
            }
            if (self.cachedFgPath && [fm fileExistsAtPath:self.cachedFgPath]) {
                self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFgPath]];
                [self addSubview:self.fgView];
            }
            [self setNeedsLayout];
            
            self.currentState = @"Init";
            [CATransaction begin];
            if ([self.engineType isEqualToString:@"Lock"]) {
                [self transitionToState:@"Locked" animated:NO];
            } else {
                [self transitionToState:@"Unlock" animated:NO];
            }
            [CATransaction commit];
            [CATransaction flush];
        });
    });
}
@end


// ==========================================
// 🔥 挂载工厂：彻底分离锁屏层与桌面层
// ==========================================
static void MountEngineToView(UIView *targetView, NSString *type) {
    if (!g_enabled || !targetView) return;
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(targetView, "TendiesEngine");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:targetView.bounds];
        engineView.engineType = type; // 标记引擎身份
        objc_setAssociatedObject(targetView, "TendiesEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [targetView addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    if (engineView.superview != targetView) {
        [engineView removeFromSuperview];
        [targetView addSubview:engineView];
    }
    engineView.frame = targetView.bounds;
    [targetView bringSubviewToFront:engineView];
    
    // 🔥 将原生的壁纸层隐身！防漏底裤，防截图！
    for (UIView *sub in targetView.subviews) {
        if (sub != engineView && ![sub isKindOfClass:NSClassFromString(@"SBFLockScreenDateView")]) {
            sub.alpha = 0.0;
        }
    }
}

// 1. 桌面引擎挂载点：底层桌面，永远展示 Unlock
%hook PBUIWallpaperViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) {
        if ([self respondsToSelector:@selector(homescreenWallpaperView)]) {
            UIView *homeView = [self homescreenWallpaperView];
            if (homeView) {
                MountEngineToView(homeView, @"Home");
            }
        }
        if ([self respondsToSelector:@selector(sharedWallpaperView)]) {
            UIView *sharedView = [self sharedWallpaperView];
            if (sharedView) {
                // 如果开启了共享壁纸，也必须挂载引擎覆盖它
                MountEngineToView(sharedView, @"Home");
            }
        }
    }
}

// 击杀桌面的各种特效和过渡截图
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state {
    if (g_enabled) return nil;
    return %orig;
}

- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)oldState newState:(void *)newState oldEffectView:(id *)oldView newEffectView:(id *)newView {
    if (g_enabled) return NO;
    return %orig;
}
%end


// 2. 锁屏引擎挂载点：锁屏盖板，永远展示 Locked
%hook CSCoverSheetViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) {
        // iOS 16+ 的锁屏海报是挂在 CSCoverSheetViewController 下的 CSBackgroundContentViewController 里的
        UIViewController *bgVC = [self valueForKey:@"_backgroundContentViewController"];
        if (bgVC && bgVC.view) {
            MountEngineToView(bgVC.view, @"Lock");
        }
        
        // 🚨 终极击杀景深效果：景深会生成一个 _floatingLayerView 浮在时间上面挡住我们的图层
        UIView *floatingLayer = [self valueForKey:@"_floatingLayerView"];
        if (floatingLayer) {
            floatingLayer.alpha = 0.0;
        }
    }
}

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled && g_isScreenOn) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}

- (void)setDismissed:(BOOL)dismissed {
    %orig;
    g_isUnlocked = dismissed;
    if (g_enabled && g_isScreenOn) {
        NSString *state = dismissed ? @"Unlock" : @"Locked";
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}
%end

// 💡 修复Theos编译报错的关键点：强制转换成 UIViewController 去访问 .view 属性
%hook CSBackgroundContentViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (g_enabled) {
        // 保留视图用于挂载，但把自带的海报彻底隐身
        UIView *bgView = ((UIViewController *)self).view;
        for (UIView *sub in bgView.subviews) {
            if (![sub isKindOfClass:[TendiesRenderEngineView class]]) {
                sub.alpha = 0.0;
            }
        }
    }
}
%end


// ==========================================
// 拦截系统底层截图 (防露馅)
// ==========================================
%hook SBWallpaperController

- (void)_ingestPrimaryWallpaperLayersSnapshotIOSurface:(id)arg1 floatingWallpaperLayerSnapshotIOSurface:(id)arg2 snapshotScale:(double)arg3 traitCollection:(id)arg4 withCompletion:(id /* block */)arg5 {
    if (g_enabled) {
        if (arg5) { void (^cb)(void) = arg5; cb(); }
        return; 
    }
    %orig;
}

- (void)_snapshotScene:(id)scene withOptions:(long long)options traitCollection:(id)collection completion:(id /* block */)completion {
    if (g_enabled) {
        if (completion) { void (^cb)(id) = completion; cb(nil); }
        return;
    }
    %orig;
}

%end


// ==========================================
// 亮灭屏状态同步
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

%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
