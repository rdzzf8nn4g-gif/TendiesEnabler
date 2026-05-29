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
// 核心私有 API 声明
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
// 核心引擎 (双轨制：桌面永远 Unlock，锁屏智能响应)
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
        self.backgroundColor = [UIColor clearColor]; // 必须透明保证透视
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.isPathCached = NO;
        self.currentState = @"Init";
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"TendiesEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"TendiesEngineSleep" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onStateChange:) name:@"TendiesEngineStateChange" object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)forceReload {
    self.isPathCached = NO;
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
    if ([self.engineType isEqualToString:@"Home"]) {
        [self transitionToState:@"Unlock" animated:NO];
    } else {
        [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
    }
}

- (void)onSleep {
    if (!g_enabled) return;
    [self transitionToState:@"Sleep" animated:YES];
}

- (void)onStateChange:(NSNotification *)note {
    if (!g_enabled) return;
    NSString *newState = note.userInfo[@"state"];
    if (!newState) return;
    
    // 💡 桌面引擎永不变回 Locked，永远保持 Unlock，完美等待锁屏滑动露出来！
    if ([self.engineType isEqualToString:@"Home"]) {
        [self transitionToState:@"Unlock" animated:YES];
    } else {
        // 💡 锁屏引擎随解锁状态自动弹簧变化
        [self transitionToState:newState animated:YES];
    }
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

- (void)parseWallpaperPlist {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plistPath = [g_tendiesPath stringByAppendingPathComponent:@"Wallpaper.plist"];
    
    if ([fm fileExistsAtPath:plistPath]) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSDictionary *assets = dict[@"assets"];
        NSDictionary *targetAssets = assets[@"lockAndHome"][@"default"];
        if (!targetAssets) targetAssets = assets[@"lock"][@"default"];
        
        if (targetAssets) {
            NSString *bgName = targetAssets[@"backgroundAnimationFileName"];
            NSString *floatName = targetAssets[@"floatingAnimationFileNameKey"] ?: targetAssets[@"floatingAnimationFileName"];
            NSString *fgName = targetAssets[@"foregroundAnimationFileName"];
            
            if (bgName) self.cachedBgPath = [g_tendiesPath stringByAppendingPathComponent:bgName];
            if (floatName) self.cachedFloatPath = [g_tendiesPath stringByAppendingPathComponent:floatName];
            if (fgName) self.cachedFgPath = [g_tendiesPath stringByAppendingPathComponent:fgName];
            
            self.isPathCached = YES;
            return;
        }
    }
    
    // 容错匹配
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:g_tendiesPath];
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

            NSFileManager *fm = [NSFileManager defaultManager];
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
            if ([self.engineType isEqualToString:@"Home"]) {
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
// 💡 双轨挂载点工厂：让桌面与锁屏引擎独立工作！
// ==========================================
static void MountEngineToView(UIView *targetView, NSString *type) {
    if (!g_enabled || !targetView) return;
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(targetView, "TendiesEngine");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:targetView.bounds];
        engineView.engineType = type;
        objc_setAssociatedObject(targetView, "TendiesEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [targetView addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    if (engineView.superview != targetView) {
        [engineView removeFromSuperview];
        [targetView addSubview:engineView];
    }
    engineView.frame = targetView.bounds;
    
    // 把引擎置于原生子视图后面，但通过透明化系统原生视图，使引擎显露
    [targetView insertSubview:engineView atIndex:0]; 
}

// ------------------------------------------
// 1. 桌面底层：挂载 Home Engine
// ------------------------------------------
%hook PBUIWallpaperViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) {
        UIView *target = self.view;
        if (target) MountEngineToView(target, @"Home");
        
        // 让原生渲染层物理隐形
        if ([self respondsToSelector:@selector(homescreenWallpaperView)]) {
            UIView *hv = [self homescreenWallpaperView];
            if (hv) hv.alpha = 0.0;
        }
        if ([self respondsToSelector:@selector(lockscreenWallpaperView)]) {
            UIView *lv = [self lockscreenWallpaperView];
            if (lv) lv.alpha = 0.0;
        }
    }
}
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state {
    if (g_enabled) return nil;
    return %orig;
}
- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)oldState newState:(void *)newState oldEffectView:(id *)oldView newEffectView:(id *)newView {
    if (g_enabled) return NO;
    return %orig;
}
%end


// ------------------------------------------
// 2. 锁屏盖板：挂载 Lock Engine
// ------------------------------------------
%hook CSBackgroundContentViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) {
        UIView *target = ((UIViewController *)self).view;
        if (target) {
            MountEngineToView(target, @"Lock");
            // 将锁屏里的系统原生海报图层彻底隐身，防止露底！
            for (UIView *sub in target.subviews) {
                if (![sub isKindOfClass:[TendiesRenderEngineView class]]) {
                    sub.alpha = 0.0;
                }
            }
        }
    }
}
%end


%hook CSCoverSheetViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) {
        // 🚨 终极击杀：移除导致景深模糊/遮挡的 _floatingLayerView
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


// ==========================================
// 系统快照与背光拦截
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
