#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h> 
#import <stdarg.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ==========================================
// 结构体与系统头文件声明
// ==========================================
@interface SpringBoard : UIApplication
- (void)_simulateLockButtonPress;
@end
typedef struct {
    long long x0;
    long long x1;
    double x2;
} PBUIWallpaperTransitionState;

@interface PBUIWallpaperViewController : UIViewController
@property (retain, nonatomic) UIView *homescreenWallpaperView;
@property (retain, nonatomic) UIView *lockscreenWallpaperView;
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state;
- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)state newState:(void *)state oldEffectView:(id *)view newEffectView:(id *)view;
@end

@interface PBUIWallpaperView : UIView
- (BOOL)zone_isMainWallpaperContainer;
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
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setDismissed:(BOOL)dismissed;
@end

@interface CSCoverSheetViewController (Zone)
- (void)zone_tickProgress;
- (void)zone_screenSleep;
- (void)zone_screenWake;
@end

@interface SBWallpaperEffectView : UIView
@property (nonatomic) long long wallpaperStyle;
- (BOOL)zone_shouldHideEffect;
@end

@interface _UIPortalView : UIView
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, assign) BOOL hidesSourceView;
@property (nonatomic, assign) BOOL matchesAlpha;
@property (nonatomic, assign) BOOL matchesTransform;
@property (nonatomic, assign) BOOL matchesPosition;
@end

@interface CSBackgroundContentView : UIView
@end

@interface SBIconController : UIViewController
@end

// ---------- iOS 14-15 必备头文件 ----------
@interface SBLockScreenManager : NSObject
+ (id)sharedInstance;
- (void)lockUIFromSource:(int)source withOptions:(id)options;
- (void)unlockUIFromSource:(int)source withOptions:(id)options;
- (BOOL)isUILocked;
@end

@interface SBFWallpaperView : UIView
- (BOOL)zone_isMainWallpaperContainer;
@end

// =========================================================================
// 核心修复：纯血 CoreAnimation 底层解析器 (拯救 iOS14/15 崩溃)
// =========================================================================
@interface CAStateController : NSObject
- (instancetype)initWithLayer:(CALayer *)layer;
- (void)setState:(NSString *)state ofLayer:(CALayer *)layer transitionSpeed:(float)speed;
@end

@interface CAPackage : NSObject
+ (id)packageWithContentsOfURL:(NSURL *)url type:(NSString *)type options:(NSDictionary *)options error:(NSError **)error;
@property (readonly) CALayer *rootLayer;
@end

@interface _UICAPackageView : UIView
- (instancetype)initWithContentsOfURL:(NSURL *)url publishedObjectViewClassMap:(NSDictionary *)map;
- (BOOL)setState:(NSString *)state;
@end

@interface ZonePackageFallbackView : UIView
@property (nonatomic, strong) UIView *uiPackageView; 
@property (nonatomic, strong) id package;            
@property (nonatomic, strong) id stateController;    
- (instancetype)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
- (BOOL)setState:(NSString *)state animated:(BOOL)animated;
@end

static double g_animDuration; 

@implementation ZonePackageFallbackView
- (instancetype)initWithURL:(NSURL *)url {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        NSURL *dirURL = [url copy];
        Class UICPClass = NSClassFromString(@"_UICAPackageView");
        if (UICPClass && [UICPClass instancesRespondToSelector:@selector(initWithContentsOfURL:publishedObjectViewClassMap:)]) {
            @try {
                _uiPackageView = [[(id)UICPClass alloc] initWithContentsOfURL:dirURL publishedObjectViewClassMap:nil];
                if (_uiPackageView) {
                    _uiPackageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                    [self addSubview:_uiPackageView];
                    return self;
                }
            } @catch (NSException *e) {}
        }
        
        Class CAPackageClass = NSClassFromString(@"CAPackage");
        if (CAPackageClass) {
            NSError *err = nil;
            _package = [(id)CAPackageClass packageWithContentsOfURL:dirURL type:@"com.apple.coreanimation-package" options:nil error:&err];
            if (!_package) {
                NSURL *camlURL = [dirURL URLByAppendingPathComponent:@"main.caml"];
                _package = [(id)CAPackageClass packageWithContentsOfURL:camlURL type:@"com.apple.coreanimation-xml" options:nil error:&err];
            }
            if (_package) {
                CALayer *root = [_package valueForKey:@"rootLayer"];
                if (root) {
                    root.geometryFlipped = NO;
                    [self.layer addSublayer:root];
                    Class CAStateControllerClass = NSClassFromString(@"CAStateController");
                    if (CAStateControllerClass) {
                        _stateController = [[(id)CAStateControllerClass alloc] initWithLayer:root]; 
                    }
                }
            }
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_uiPackageView) {
        _uiPackageView.frame = self.bounds;
    }
}

- (BOOL)setState:(NSString *)state {
    return [self setState:state animated:NO];
}

- (BOOL)setState:(NSString *)state animated:(BOOL)animated {
    if (_uiPackageView && [_uiPackageView respondsToSelector:@selector(setState:)]) {
        if (!animated) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            BOOL result = (BOOL)[_uiPackageView performSelector:@selector(setState:) withObject:state];
            [CATransaction commit];
            return result;
        }
        return (BOOL)[_uiPackageView performSelector:@selector(setState:) withObject:state];
    }
    if (_stateController && _package) {
        CALayer *root = [_package valueForKey:@"rootLayer"];
        if (root) {
            NSMethodSignature *sig = [[_stateController class] instanceMethodSignatureForSelector:@selector(setState:ofLayer:transitionSpeed:)];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(setState:ofLayer:transitionSpeed:)];
                [inv setTarget:_stateController];
                [inv setArgument:&state atIndex:2];
                [inv setArgument:&root atIndex:3];
                float speed = animated ? (0.85f / (g_animDuration > 0 ? g_animDuration : 0.85f)) : 0.0f;
                [inv setArgument:&speed atIndex:4];
                [inv invoke];
                return YES;
            }
        }
    }
    return NO;
}
@end
// =========================================================================

static CALayer *ZoneFindLayerByName(CALayer *layer, NSString *name) {
    if ([layer.name isEqualToString:name]) return layer;
    for (CALayer *sub in layer.sublayers) {
        CALayer *found = ZoneFindLayerByName(sub, name);
        if (found) return found;
    }
    return nil;
}

// ==========================================
// 内存优化：递归暂停图层树，彻底冻结渲染与粒子
// ==========================================
static void ZoneFreezeLayerTree(CALayer *layer, BOOL freeze) {
    if (!layer) return;
    
    // 切断图层动画速度
    layer.speed = freeze ? 0.0 : 1.0;
    
    if ([layer isKindOfClass:[CAEmitterLayer class]]) {
        // 如果是粒子引擎，息屏时出生率设为 0，防止后台疯狂堆积内存
        CAEmitterLayer *emitter = (CAEmitterLayer *)layer;
        if (freeze) {
            objc_setAssociatedObject(emitter, "ZoneOrigBirthRate", @(emitter.birthRate), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            emitter.birthRate = 0.0;
        } else {
            NSNumber *orig = objc_getAssociatedObject(emitter, "ZoneOrigBirthRate");
            if (orig) emitter.birthRate = [orig floatValue];
        }
    }
    
    for (CALayer *sub in layer.sublayers) {
        ZoneFreezeLayerTree(sub, freeze);
    }
}

// ==========================================
// 绝对安全的底层变量获取函数 (防止 Safe Mode)
// ==========================================
static UIView* safelyGetIvarAsView(id object, const char* ivarName) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], ivarName);
    if (ivar) {
        id val = object_getIvar(object, ivar);
        if ([val isKindOfClass:[UIView class]]) {
            return (UIView *)val;
        }
    }
    return nil;
}

static UIViewController* safelyGetIvarAsViewController(id object, const char* ivarName) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], ivarName);
    if (ivar) {
        id val = object_getIvar(object, ivar);
        if ([val isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)val;
        }
    }
    return nil;
}

// ==========================================
// 全局变量与配置管理
// ==========================================
static BOOL g_enabled = NO;
static BOOL g_enhanced_engine = NO;
static BOOL g_hideTextShadow = NO;
static BOOL g_lowPowerPause = NO; 
static BOOL g_doubleTapLock = NO;
static NSString *g_zonePath = nil;

// 视觉状态标识
static BOOL g_isUnlocked = NO; 
static BOOL g_isScreenOn = YES;

static double g_resolutionFactor = 1.0;
static double g_lastTickProgress = -1; 
static BOOL old_hideTextShadow = NO; 

// 防御系统发假进度的滤网记录器
static double g_lastSystemProgress = 0.0; 

static BOOL g_enableAnimSpeed = YES; 

static BOOL g_isVideoMode = NO;
static NSString *g_lockVideoPath = nil;
static NSString *g_homeVideoPath = nil;

static __weak _UIPortalView *g_portalView = nil;

static void EnsureEngineViewIsMounted(); 

static inline BOOL IsSingleVideoMode() {
    return (g_isVideoMode && g_lockVideoPath && g_homeVideoPath && [g_lockVideoPath isEqualToString:g_homeVideoPath]);
}

static BOOL g_isAODInactive = NO;
static NSString *g_lastEmittedScreenState = nil;
static CFTimeInterval g_lastEmittedScreenStateTime = 0.0;
static NSString *g_lastEmittedWallpaperState = nil;
static CFTimeInterval g_lastEmittedWallpaperStateTime = 0.0;
static NSString *g_pendingAODWallpaperState = nil;
static BOOL g_pendingAODWallpaperAnimated = YES;
static BOOL g_hasPendingAODWallpaperState = NO;
static BOOL g_deferAODWakeWallpaperState = NO;
static BOOL g_forceAcceptNextSystemProgress = NO;

// 【新增】：获取系统真实 AOD 开关状态判断
static BOOL ZoneIsAODEnabledInSystem() {
    if (@available(iOS 16.0, *)) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.springboard"];
        if ([defaults objectForKey:@"AlwaysOnDisplayEnabled"]) {
            return [defaults boolValueForKey:@"AlwaysOnDisplayEnabled"];
        }
    }
    return NO;
}

// 【核心修复】：绕过生命周期，直接从底层 SBLockScreenManager 获取当前真实锁屏状态
static BOOL ZoneIsDeviceUnlocked() {
    Class lockManagerClass = NSClassFromString(@"SBLockScreenManager");
    if ([lockManagerClass respondsToSelector:@selector(sharedInstance)]) {
        id manager = [lockManagerClass sharedInstance];
        if ([manager respondsToSelector:@selector(isUILocked)]) {
            return !((BOOL)[manager performSelector:@selector(isUILocked)]);
        }
    }
    return g_isUnlocked;
}


static inline void ZoneEmitScreenAndWallpaperState(BOOL screenOn, NSString *state, BOOL animated);

static inline void ZoneSetAODScreenState(BOOL screenOn) {
    BOOL wasScreenOn = g_isScreenOn;
    BOOL wasAODInactive = g_isAODInactive;
    g_isScreenOn = screenOn;
    g_isAODInactive = !screenOn;
    g_lastTickProgress = -1;
    if (screenOn) {
        g_forceAcceptNextSystemProgress = YES;
        g_lastSystemProgress = -1.0;
        if (!wasScreenOn && wasAODInactive) {
            g_deferAODWakeWallpaperState = YES;
        }
    } else {
        g_forceAcceptNextSystemProgress = NO;
        g_lastSystemProgress = 0.0;
        g_deferAODWakeWallpaperState = NO;
    }
}

static inline void ZoneClearPendingAODWallpaperState(void) {
    g_hasPendingAODWallpaperState = NO;
    g_pendingAODWallpaperState = nil;
    g_pendingAODWallpaperAnimated = YES;
    g_deferAODWakeWallpaperState = NO;
}

static inline void ZoneQueuePendingAODWallpaperState(NSString *state, BOOL animated) {
    if (!state || [state isEqualToString:@"Sleep"]) {
        return;
    }
    g_hasPendingAODWallpaperState = YES;
    g_pendingAODWallpaperState = [state copy];
    g_pendingAODWallpaperAnimated = animated;
}

static inline void ZoneFlushPendingAODWallpaperState(void) {
    if (g_deferAODWakeWallpaperState) {
        return;
    }
    if (!g_hasPendingAODWallpaperState || !g_isScreenOn || g_isAODInactive) {
        return;
    }
    NSString *pendingState = [g_pendingAODWallpaperState copy];
    BOOL pendingAnimated = g_pendingAODWallpaperAnimated;
    ZoneClearPendingAODWallpaperState();
    if (pendingState) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange"
                                                            object:nil
                                                          userInfo:@{@"state": pendingState, @"animated": @(pendingAnimated)}];
    }
}

static inline void ZonePinPortalVisibleForAODSleep(void) {
    if (!g_portalView) return;
    [CATransaction begin];
    
    // 【AOD 状态与桌面防闪现核心判断】
    if (!ZoneIsAODEnabledInSystem() || g_isUnlocked) {
        // 如果系统未开 AOD，或者是从桌面直接息屏：
        // 开启 0.35 秒渐变，并将 Alpha 设为 0。彻底放权给系统原生黑屏过渡，防止生硬遮挡桌面
        [CATransaction setAnimationDuration:0.35];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
        g_portalView.hidden = NO;
        g_portalView.alpha = 0.0;
    } else {
        // 正常锁屏界面的 AOD 睡眠，瞬间接管曝光
        [CATransaction setDisableActions:YES];
        g_portalView.hidden = NO;
        g_portalView.alpha = 1.0;
    }
    
    [CATransaction commit];
}

static inline void ZoneCommitAODTransition(BOOL screenOn, NSString *state, BOOL animated) {
    ZoneSetAODScreenState(screenOn);
    if (!screenOn) {
        ZonePinPortalVisibleForAODSleep();
    }
    ZoneEmitScreenAndWallpaperState(screenOn, state, animated);
    if (screenOn) {
        ZoneFlushPendingAODWallpaperState();
    }
}

static inline BOOL ZoneIsDefinitiveBacklightState(long long state) {
    return (state == 0 || state == 1);
}

static inline BOOL ZoneShouldIgnoreAODBacklightWakeState(long long state) {
    return (g_isAODInactive && state == 1);
}

static inline void ZoneEmitScreenEvent(BOOL screenOn) {
    CFTimeInterval now = CACurrentMediaTime();
    if (g_lastEmittedScreenState && g_lastEmittedScreenStateTime > 0.0 &&
        [g_lastEmittedScreenState isEqualToString:(screenOn ? @"ON" : @"OFF")] &&
        (now - g_lastEmittedScreenStateTime) < 0.20) {
        return;
    }

    g_lastEmittedScreenState = [screenOn ? @"ON" : @"OFF" copy];
    g_lastEmittedScreenStateTime = now;

    [[NSNotificationCenter defaultCenter] postNotificationName:(screenOn ? @"ZoneEngineWake" : @"ZoneEngineSleep") object:nil];
}

static inline void ZoneEmitWallpaperState(BOOL screenOn, NSString *state, BOOL animated) {
    NSString *finalState = state;
    if (!finalState) {
        finalState = screenOn ? (g_isUnlocked ? @"Unlock" : @"Locked") : @"Sleep";
    }
    if (!screenOn) {
        finalState = @"Sleep";
    }

    if (g_deferAODWakeWallpaperState && screenOn && ![finalState isEqualToString:@"Sleep"]) {
        ZoneQueuePendingAODWallpaperState(finalState, animated);
        return;
    }

    if ((g_isAODInactive || !g_isScreenOn) && ![finalState isEqualToString:@"Sleep"]) {
        ZoneQueuePendingAODWallpaperState(finalState, animated);
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (g_lastEmittedWallpaperState && g_lastEmittedWallpaperStateTime > 0.0 &&
        [g_lastEmittedWallpaperState isEqualToString:finalState] &&
        (now - g_lastEmittedWallpaperStateTime) < 0.20) {
        return;
    }

    g_lastEmittedWallpaperState = [finalState copy];
    g_lastEmittedWallpaperStateTime = now;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange"
                                                        object:nil
                                                      userInfo:@{@"state": finalState, @"animated": @(animated)}];

    if (screenOn) {
        ZoneFlushPendingAODWallpaperState();
    }
}

static inline void ZoneEmitScreenAndWallpaperState(BOOL screenOn, NSString *state, BOOL animated) {
    ZoneEmitScreenEvent(screenOn);
    ZoneEmitWallpaperState(screenOn, state, animated);
}

static void reloadPrefs() {
    CFStringRef appID = CFSTR("com.iosdump.zoneprefs");
    CFPreferencesAppSynchronize(appID);
    Boolean valid;
    
    g_enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &valid) ? valid : NO;
    g_enhanced_engine = CFPreferencesGetAppBooleanValue(CFSTR("EnhancedEngine"), appID, &valid) ? valid : NO;
    g_hideTextShadow = CFPreferencesGetAppBooleanValue(CFSTR("HideTextShadow"), appID, &valid) ? valid : NO;
    g_lowPowerPause = CFPreferencesGetAppBooleanValue(CFSTR("LowPowerPause"), appID, &valid) ? valid : NO;
g_doubleTapLock = CFPreferencesGetAppBooleanValue(CFSTR("DoubleTapLock"), appID, &valid) ? valid : NO;
    g_isVideoMode = CFPreferencesGetAppBooleanValue(CFSTR("VideoModeEnabled"), appID, &valid) ? valid : NO;
    g_enableAnimSpeed = CFPreferencesGetAppBooleanValue(CFSTR("EnableAnimSpeed"), appID, &valid) ? valid : YES;
    
    CFPropertyListRef lockVidRef = CFPreferencesCopyAppValue(CFSTR("LockVideoPath"), appID);
    if (lockVidRef && CFGetTypeID(lockVidRef) == CFStringGetTypeID()) {
        g_lockVideoPath = [(__bridge NSString *)lockVidRef copy];
    } else {
        g_lockVideoPath = nil;
    }
    if (lockVidRef) CFRelease(lockVidRef);

    CFPropertyListRef homeVidRef = CFPreferencesCopyAppValue(CFSTR("HomeVideoPath"), appID);
    if (homeVidRef && CFGetTypeID(homeVidRef) == CFStringGetTypeID()) {
        g_homeVideoPath = [(__bridge NSString *)homeVidRef copy];
    } else {
        g_homeVideoPath = nil;
    }
    if (homeVidRef) CFRelease(homeVidRef);

    CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("ZonePath"), appID);
    if (pathRef && CFGetTypeID(pathRef) == CFStringGetTypeID()) {
        g_zonePath = [(__bridge NSString *)pathRef copy];
        
        NSString *wpName = [g_zonePath lastPathComponent];
        NSString *resKey = [NSString stringWithFormat:@"ResFactor_%@", wpName];
        CFPropertyListRef resRef = CFPreferencesCopyAppValue((__bridge CFStringRef)resKey, appID);
        if (resRef && CFGetTypeID(resRef) == CFNumberGetTypeID()) {
            g_resolutionFactor = [(__bridge NSNumber *)resRef doubleValue];
        } else {
            g_resolutionFactor = 1.0;
        }
        if (resRef) CFRelease(resRef);
        
        NSString *speedKey = [NSString stringWithFormat:@"AnimSpeed_%@", wpName];
        CFPropertyListRef speedRef = CFPreferencesCopyAppValue((__bridge CFStringRef)speedKey, appID);
        NSInteger speedLevel = 0;
        if (speedRef && CFGetTypeID(speedRef) == CFNumberGetTypeID()) {
            speedLevel = [(__bridge NSNumber *)speedRef integerValue];
        }
        if (speedRef) CFRelease(speedRef);
        
        if (g_enableAnimSpeed) {
            if (speedLevel == 1) g_animDuration = 0.60;
            else if (speedLevel == 2) g_animDuration = 0.40;
            else if (speedLevel == 3) g_animDuration = 0.20;
            else g_animDuration = 0.85;
        } else {
            g_animDuration = 0.0;
        }
        
    } else {
        g_zonePath = nil; 
        g_resolutionFactor = 1.0;
        g_animDuration = 0.85;
    }
    if (pathRef) CFRelease(pathRef);
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    
    if (old_hideTextShadow != g_hideTextShadow) {
        old_hideTextShadow = g_hideTextShadow;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneForceIconRefresh" object:nil];
        });
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        Class wc = NSClassFromString(@"SBWallpaperController");
        if ([wc respondsToSelector:@selector(sharedInstance)] && [wc sharedInstance]) {
            EnsureEngineViewIsMounted();
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneForceLayout" object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineWake" object:nil]; 
    });
}

// =========================================================================
// ==================== 【全新模块】: 极致工业级视频引擎 ===================
// =========================================================================
@interface ZoneVideoPlayerView : UIView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, assign) BOOL isManuallyPaused; 
- (instancetype)initWithFrame:(CGRect)frame videoPath:(NSString *)path;
- (void)playVideo;
- (void)pauseVideo;
- (void)cleanUpEngineSafely;
@end

@implementation ZoneVideoPlayerView
- (instancetype)initWithFrame:(CGRect)frame videoPath:(NSString *)path {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.currentPath = path;

        @try {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient 
                                             withOptions:AVAudioSessionCategoryOptionMixWithOthers 
                                                   error:nil];
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
        } @catch (NSException *e) {}

        if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSURL *url = [NSURL fileURLWithPath:path];
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
            AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
            
            if ([item respondsToSelector:@selector(setPreferredForwardBufferDuration:)]) {
                item.preferredForwardBufferDuration = 1.0;
            }
            
            self.player = [AVQueuePlayer queuePlayerWithItems:@[item]];
            self.player.muted = YES;
            self.player.allowsExternalPlayback = NO; 
            self.player.automaticallyWaitsToMinimizeStalling = NO; 
            self.player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
            
            if (@available(iOS 12.0, *)) {
                self.player.preventsDisplaySleepDuringVideoPlayback = NO;
            }
            
            self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
            
            self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
            self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            self.playerLayer.frame = self.bounds;
            [self.layer addSublayer:self.playerLayer];
            
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playVideo) name:UIApplicationDidBecomeActiveNotification object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playVideo) name:AVPlayerItemPlaybackStalledNotification object:nil];
            
            [self.player addObserver:self forKeyPath:@"rate" options:NSKeyValueObservingOptionNew context:nil];
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.playerLayer) {
        self.playerLayer.frame = self.bounds;
    }
    if (g_isScreenOn && g_enabled && g_isVideoMode && !self.isManuallyPaused) {
        [self playVideo];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"rate"]) {
        if (g_enabled && g_isVideoMode && g_isScreenOn && !self.isManuallyPaused) {
            if (self.player.rate == 0.0) {
                // 【核心防卡死修复：切断同步KVO死循环，零CPU占用】
                // 延迟 0.25 秒再发送 play 指令。这让系统有时间处理亮屏环境，并且直接规避了一秒上万次的无限报错死锁。
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (g_enabled && g_isVideoMode && g_isScreenOn && !self.isManuallyPaused && self.player.rate == 0.0) {
                        [self playVideo];
                    }
                });
            }
        }
    }
}

- (void)playVideo {
    if (!self.player) return;
    if (g_lowPowerPause && [[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        [self pauseVideo];
        return;
    }
    self.isManuallyPaused = NO;
    
    // 【防定格修复1：激活静默环境底层 AudioSession 权限】
    @try {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient 
                                         withOptions:AVAudioSessionCategoryOptionMixWithOthers 
                                               error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
    } @catch (NSException *e) {}

    // 【防定格修复2：重新牵手硬件解码器】
    // 息屏极易导致 AVPlayerLayer 脱落，这里做一次保底重新绑定
    if (self.playerLayer.player == nil) {
        self.playerLayer.player = self.player;
    }

    // 无视 status，暴力执行 play
    [self.player play];
}

- (void)pauseVideo {
    self.isManuallyPaused = YES;
    if (self.player) {
        [self.player pause];
    }
}

- (void)cleanUpEngineSafely {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    @try {
        [self.player removeObserver:self forKeyPath:@"rate"];
    } @catch (NSException *e) {}
    
    [self pauseVideo];
    
    // 【防内存泄漏修复：彻底断开并拔除所有指针】
    if (self.looper) {
        [self.looper disableLooping];
        self.looper = nil;
    }
    if (self.playerLayer) {
        self.playerLayer.player = nil; // 强行剥离图层对播放器的底层 CoreAnimation 引用
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
    }
    if (self.player) {
        [self.player removeAllItems];
        self.player = nil;
    }
}

- (void)dealloc {
    [self cleanUpEngineSafely];
}
@end


@interface ZoneVideoEngine : UIView
@property (nonatomic, strong) ZoneVideoPlayerView *lockVideoView;
@property (nonatomic, strong) ZoneVideoPlayerView *homeVideoView;
- (void)reloadWallpaperViews;
- (void)clearCurrentViewsSafely;
@end

@implementation ZoneVideoEngine
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"ZoneEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"ZoneEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"ZoneEngineSleep" object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(powerStateChanged) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { 
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self clearCurrentViewsSafely];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.lockVideoView) self.lockVideoView.frame = self.bounds;
    if (self.homeVideoView) self.homeVideoView.frame = self.bounds;
}

- (void)powerStateChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_enabled && g_isVideoMode && g_isScreenOn) {
            [self onWakeUp]; 
        }
    });
}

- (void)onWakeUp {
    if (!g_enabled || !g_isVideoMode) return;
    if (g_lowPowerPause && [[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        [self.lockVideoView pauseVideo];
        [self.homeVideoView pauseVideo];
        return;
    }
    
    if (IsSingleVideoMode()) {
        if (self.homeVideoView) [self.homeVideoView playVideo];
    } else {
        if (self.homeVideoView) [self.homeVideoView playVideo];
        if (self.lockVideoView) [self.lockVideoView playVideo];
    }
}

- (void)onSleep {
    if (!g_enabled || !g_isVideoMode) return;
    [self.lockVideoView pauseVideo];
    [self.homeVideoView pauseVideo];
}

- (void)clearCurrentViewsSafely {
    if (self.lockVideoView) {
        [self.lockVideoView cleanUpEngineSafely];
        [self.lockVideoView removeFromSuperview];
        self.lockVideoView = nil;
    }
    if (self.homeVideoView) {
        [self.homeVideoView cleanUpEngineSafely];
        [self.homeVideoView removeFromSuperview];
        self.homeVideoView = nil;
    }
}

- (void)reloadWallpaperViews {
    [self clearCurrentViewsSafely];
    if (!g_enabled || !g_isVideoMode) return;
    
    BOOL hasLock = (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);
    BOOL hasHome = (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath]);
    
    if (!hasLock && !hasHome) {
        self.backgroundColor = [UIColor clearColor];
        return;
    }
    
    self.backgroundColor = [UIColor clearColor];
    
    if (IsSingleVideoMode()) {
        self.homeVideoView = [[ZoneVideoPlayerView alloc] initWithFrame:self.bounds videoPath:g_homeVideoPath];
        if (self.homeVideoView) {
            self.homeVideoView.alpha = 1.0;
            [self addSubview:self.homeVideoView];
        }
        if (g_isScreenOn) [self onWakeUp];
    } else {
        if (hasLock) {
            self.lockVideoView = [[ZoneVideoPlayerView alloc] initWithFrame:self.bounds videoPath:g_lockVideoPath];
            if (self.lockVideoView) {
                self.lockVideoView.alpha = 0.0;
                [self addSubview:self.lockVideoView];
            }
        }
        if (hasHome) {
            self.homeVideoView = [[ZoneVideoPlayerView alloc] initWithFrame:self.bounds videoPath:g_homeVideoPath];
            if (self.homeVideoView) {
                self.homeVideoView.alpha = 1.0;
                [self addSubview:self.homeVideoView];
            }
        }
        if (g_isScreenOn) {
            [self onWakeUp];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneForceLayout" object:nil];
}
@end


// =========================================================================
// ==================== 【引擎 1】: 传统稳定引擎 (旧逻辑) ====================
// =========================================================================
@interface ZoneCAMLParserLegacy : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableDictionary *idToNameMap;
@property (nonatomic, strong) NSMutableDictionary *statesData;
@property (nonatomic, copy) NSString *currentParsingState;
@property (nonatomic, copy) NSString *currentParsingTargetId;
@property (nonatomic, copy) NSString *currentParsingKeyPath;
@property (nonatomic, assign) BOOL rootParsed;
@property (nonatomic, strong) UIColor *fallbackBackgroundColor;
@property (nonatomic, assign) BOOL isParsingBackgroundColor;
- (void)parseFile:(NSString *)path;
@end

@implementation ZoneCAMLParserLegacy
- (instancetype)init {
    if (self = [super init]) {
        _idToNameMap = [NSMutableDictionary new];
        _statesData = [NSMutableDictionary new];
    }
    return self;
}
- (void)parseFile:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = self;
    [parser parse];
}
- (UIColor *)parseColorString:(NSString *)val opacity:(NSString *)opacityStr {
    NSArray *comps = [val componentsSeparatedByString:@" "];
    if (comps.count >= 3) {
        CGFloat r = [comps[0] doubleValue];
        CGFloat g = [comps[1] doubleValue];
        CGFloat b = [comps[2] doubleValue];
        CGFloat a = opacityStr ? [opacityStr doubleValue] : (comps.count >= 4 ? [comps[3] doubleValue] : 1.0);
        return [UIColor colorWithRed:r green:g blue:b alpha:a];
    }
    return nil;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"CALayer"]) {
        if (!self.rootParsed) {
            self.rootParsed = YES;
        }
        if (attributeDict[@"backgroundColor"] && !self.fallbackBackgroundColor) {
            UIColor *c = [self parseColorString:attributeDict[@"backgroundColor"] opacity:attributeDict[@"opacity"]];
            if (c && CGColorGetAlpha(c.CGColor) > 0.05) {
                self.fallbackBackgroundColor = c;
            }
        }
        NSString *layerId = attributeDict[@"id"];
        NSString *layerName = attributeDict[@"name"];
        if (layerId && layerName) self.idToNameMap[layerId] = layerName;
    } else if ([elementName isEqualToString:@"backgroundColor"]) {
        self.isParsingBackgroundColor = YES;
        if (attributeDict[@"value"] && !self.fallbackBackgroundColor) {
            UIColor *c = [self parseColorString:attributeDict[@"value"] opacity:attributeDict[@"opacity"]];
            if (c && CGColorGetAlpha(c.CGColor) > 0.05) {
                self.fallbackBackgroundColor = c;
            }
        }
    } else if ([elementName isEqualToString:@"CGColor"]) {
        if (self.isParsingBackgroundColor && attributeDict[@"value"] && !self.fallbackBackgroundColor) {
            UIColor *c = [self parseColorString:attributeDict[@"value"] opacity:attributeDict[@"opacity"]];
            if (c && CGColorGetAlpha(c.CGColor) > 0.05) {
                self.fallbackBackgroundColor = c;
            }
        }
    } else if ([elementName isEqualToString:@"LKState"]) {
        self.currentParsingState = attributeDict[@"name"];
    } else if ([elementName isEqualToString:@"LKStateSetValue"]) {
        self.currentParsingTargetId = attributeDict[@"targetId"];
        self.currentParsingKeyPath = attributeDict[@"keyPath"];
    } else if ([elementName isEqualToString:@"value"]) {
        if (self.currentParsingState && self.currentParsingTargetId && self.currentParsingKeyPath) {
            NSString *valStr = attributeDict[@"value"];
            if (valStr) {
                NSMutableDictionary *targetDict = self.statesData[self.currentParsingTargetId];
                if (!targetDict) { targetDict = [NSMutableDictionary dictionary]; self.statesData[self.currentParsingTargetId] = targetDict; }
                NSMutableDictionary *stateDict = targetDict[self.currentParsingState];
                if (!stateDict) { stateDict = [NSMutableDictionary dictionary]; targetDict[self.currentParsingState] = stateDict; }
                stateDict[self.currentParsingKeyPath] = @([valStr doubleValue]);
            }
        }
    }
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"backgroundColor"]) {
        self.isParsingBackgroundColor = NO;
    } else if ([elementName isEqualToString:@"LKState"]) self.currentParsingState = nil;
    else if ([elementName isEqualToString:@"LKStateSetValue"]) { self.currentParsingTargetId = nil; self.currentParsingKeyPath = nil; }
}
@end

@interface ZoneRenderEngineLegacy : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isUnlocking; 
@property (nonatomic, strong) NSString *currentState;
@property (nonatomic, assign) NSInteger reloadGeneration; 
@property (nonatomic, strong) ZoneCAMLParserLegacy *bgParser;
@property (nonatomic, strong) ZoneCAMLParserLegacy *floatParser;
@property (nonatomic, strong) ZoneCAMLParserLegacy *fgParser;
@property (nonatomic, strong) NSMutableDictionary *bgLayerMap;
@property (nonatomic, strong) NSMutableDictionary *floatLayerMap;
@property (nonatomic, strong) NSMutableDictionary *fgLayerMap;
@property (nonatomic, assign) BOOL isAnimatingState; 
@property (nonatomic, assign) NSInteger animationGeneration;
@property (nonatomic, strong) UIColor *plistBackgroundColor; 
@property (nonatomic, strong) UIColor *dynamicSolidColor; // 状态持久化底板颜色
- (void)reloadWallpaperViews;
- (void)clearCurrentViewsSafely;
- (void)lockSolidBackground;
@end

@implementation ZoneRenderEngineLegacy
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.isUnlocking = NO;
        self.currentState = @"Init";
        self.reloadGeneration = 0;
        self.isAnimatingState = NO;
        self.animationGeneration = 0;
        
        self.bgLayerMap = [NSMutableDictionary dictionary];
        self.floatLayerMap = [NSMutableDictionary dictionary];
        self.fgLayerMap = [NSMutableDictionary dictionary];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"ZoneEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"ZoneEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"ZoneEngineSleep" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onProgress:) name:@"ZoneEngineProgress" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onStateChange:) name:@"ZoneEngineStateChange" object:nil];
    }
    return self;
}

- (void)onStateChange:(NSNotification *)note {
    if (!g_enabled || !self.bgView) return;
    NSString *state = note.userInfo[@"state"];
    NSNumber *animNum = note.userInfo[@"animated"];
    BOOL animated = animNum ? [animNum boolValue] : YES;
    
    if (state) {
        [self transitionToState:state animated:animated];
    }
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    
    UIColor *finalBgColor = [UIColor clearColor];
    if (self.dynamicSolidColor) {
        finalBgColor = self.dynamicSolidColor;
    } else if (self.plistBackgroundColor) {
        finalBgColor = self.plistBackgroundColor;
    } else if (self.bgParser && self.bgParser.fallbackBackgroundColor) {
        finalBgColor = self.bgParser.fallbackBackgroundColor;
    }
    self.backgroundColor = finalBgColor;
    
    if (self.bgView) {
        self.bgView.frame = bounds;
        self.bgView.backgroundColor = finalBgColor;
    }
    if (self.floatingView) {
        self.floatingView.frame = bounds;
    }
    if (self.fgView) {
        self.fgView.frame = bounds;
    }

    if (@available(iOS 16.0, *)) {
    } else {
        BSUICAPackageView *views[] = {self.bgView, self.floatingView, self.fgView};
        for (int i = 0; i < 3; i++) {
            BSUICAPackageView *v = views[i];
            if (!v) continue;
            CALayer *rootLayer = [v.layer.sublayers firstObject];
            if (rootLayer) {
                BOOL camlFlipped = rootLayer.geometryFlipped; 
                v.layer.geometryFlipped = !camlFlipped;
                
                CGSize realSize = rootLayer.bounds.size;
                if (realSize.width > 0 && realSize.height > 0) {
                    CGFloat scaleX = bounds.size.width / realSize.width;
                    CGFloat scaleY = bounds.size.height / realSize.height;
                    CGFloat scale = MAX(scaleX, scaleY);
                    rootLayer.position = CGPointMake(bounds.size.width / 2.0, bounds.size.height / 2.0);
                    rootLayer.transform = CATransform3DMakeScale(scale, scale, 1.0);
                }
            }
        }
    }
}

- (void)onWakeUp {
    if (!g_enabled || !self.bgView) return;
    self.isUnlocking = NO;
    
    // 【内存优化】：解冻图层，恢复渲染与粒子
    ZoneFreezeLayerTree(self.bgView.layer, NO);
    ZoneFreezeLayerTree(self.floatingView.layer, NO);
    ZoneFreezeLayerTree(self.fgView.layer, NO);
    
    [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:YES];
}

- (void)onSleep {
    if (!g_enabled || !self.bgView) return;
    self.isUnlocking = NO;
    [self transitionToState:@"Sleep" animated:YES];
    
    // 【内存优化】：彻底冻结图层，释放 CPU 并阻止内存泄露
    ZoneFreezeLayerTree(self.bgView.layer, YES);
    ZoneFreezeLayerTree(self.floatingView.layer, YES);
    ZoneFreezeLayerTree(self.fgView.layer, YES);
}

- (void)ensureLayerMap:(NSMutableDictionary *)layerMap parser:(ZoneCAMLParserLegacy *)parser packageView:(BSUICAPackageView *)pkgView {
    if (!pkgView || !pkgView.layer || !parser) return;
    if (layerMap.count == 0 && parser.statesData.count > 0) {
        for (NSString *targetId in parser.statesData) {
            NSString *name = parser.idToNameMap[targetId];
            if (name) {
                CALayer *found = ZoneFindLayerByName(pkgView.layer, name);
                if (found) layerMap[targetId] = found;
            }
        }
    }
}

- (void)ensureAllLayerMaps {
    [self ensureLayerMap:self.bgLayerMap parser:self.bgParser packageView:self.bgView];
    [self ensureLayerMap:self.floatLayerMap parser:self.floatParser packageView:self.floatingView];
    [self ensureLayerMap:self.fgLayerMap parser:self.fgParser packageView:self.fgView];
}

- (void)applyProgress:(double)progress parser:(ZoneCAMLParserLegacy *)parser layerMap:(NSDictionary *)layerMap {
    if (layerMap.count == 0 || !parser) return;
    [CATransaction begin]; 
    [CATransaction setDisableActions:YES]; 
    for (NSString *targetId in parser.statesData) {
        CALayer *layer = layerMap[targetId]; if (!layer) continue;
        NSDictionary *states = parser.statesData[targetId];
        NSDictionary *lockedVals = states[@"Locked"]; NSDictionary *unlockVals = states[@"Unlock"];
        if (!lockedVals || !unlockVals) continue;
        for (NSString *keyPath in lockedVals) {
            NSNumber *lockNum = lockedVals[keyPath]; NSNumber *unlockNum = unlockVals[keyPath];
            if (lockNum && unlockNum) {
                double currentVal = [lockNum doubleValue] + ([unlockNum doubleValue] - [lockNum doubleValue]) * progress;
                [layer removeAnimationForKey:keyPath];
                @try { [layer setValue:@(currentVal) forKeyPath:keyPath]; } @catch (NSException *e) {}
            }
        }
    }
    [CATransaction commit];
}

- (void)applyExplicitState:(NSString *)stateName parser:(ZoneCAMLParserLegacy *)parser layerMap:(NSDictionary *)layerMap animated:(BOOL)animated {
    if (layerMap.count == 0 || !parser) return;
    
    [CATransaction begin]; 
    if (!animated) {
        [CATransaction setDisableActions:YES];
    } else {
        [CATransaction setAnimationDuration:g_animDuration]; 
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    }
    
    for (NSString *targetId in parser.statesData) {
        CALayer *layer = layerMap[targetId]; if (!layer) continue;
        NSDictionary *states = parser.statesData[targetId];
        NSDictionary *targetVals = states[stateName];
        if (!targetVals) continue;
        
        for (NSString *keyPath in targetVals) {
            NSNumber *targetVal = targetVals[keyPath];
            if (targetVal) {
                [layer removeAnimationForKey:keyPath];
                @try { [layer setValue:targetVal forKeyPath:keyPath]; } @catch(NSException *e) {}
            }
        }
    }
    [CATransaction commit];
}

- (void)onProgress:(NSNotification *)note {
    if (!g_enabled || !self.bgView) return;
    if (!g_isScreenOn || g_isAODInactive) return;
    if (self.isAnimatingState && [self.currentState isEqualToString:@"Sleep"]) return; 
    
    self.isAnimatingState = NO;
    self.animationGeneration++;
    
    double progress = [note.userInfo[@"progress"] doubleValue];
    progress = MAX(0.0, MIN(1.0, progress));
    
    [self ensureAllLayerMaps];
    [self applyProgress:progress parser:self.bgParser layerMap:self.bgLayerMap];
    [self applyProgress:progress parser:self.floatParser layerMap:self.floatLayerMap];
    [self applyProgress:progress parser:self.fgParser layerMap:self.fgLayerMap];
    
    if (progress > 0.95) { self.currentState = @"Unlock"; self.isUnlocking = NO; }
    else if (progress < 0.05) { self.currentState = @"Locked"; self.isUnlocking = NO; }
    else { self.isUnlocking = YES; self.currentState = @"Scrubbing"; }
}

- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated {
    if (!g_enabled || !self.bgView) return;
    if (!g_enableAnimSpeed) animated = NO; 
    if ([self.currentState isEqualToString:stateName]) return;
    
    //  【核心修复：桌面息屏去动画】 
    if ([stateName isEqualToString:@"Sleep"]) {
        // 如果当前是桌面状态，或者刚按下电源键导致正在向锁屏过渡，强行关掉动画
        if ([self.currentState isEqualToString:@"Unlock"] || 
            (self.isAnimatingState && [self.currentState isEqualToString:@"Locked"])) {
            animated = NO;
        }
    }
    //  核心修复结束 

    self.currentState = [stateName copy];
    
    if (animated) {
        self.animationGeneration++;
        NSInteger currentGen = self.animationGeneration;
        self.isAnimatingState = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(g_animDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.animationGeneration == currentGen) {
                self.isAnimatingState = NO;
            }
        });
    } else {
        [self ensureAllLayerMaps];
        if ([stateName isEqualToString:@"Unlock"]) {
            [self applyProgress:1.0 parser:self.bgParser layerMap:self.bgLayerMap]; 
            [self applyProgress:1.0 parser:self.floatParser layerMap:self.floatLayerMap]; 
            [self applyProgress:1.0 parser:self.fgParser layerMap:self.fgLayerMap];
        } else if ([stateName isEqualToString:@"Locked"]) {
            [self applyProgress:0.0 parser:self.bgParser layerMap:self.bgLayerMap]; 
            [self applyProgress:0.0 parser:self.floatParser layerMap:self.floatLayerMap]; 
            [self applyProgress:0.0 parser:self.fgParser layerMap:self.fgLayerMap];
        }
    }
    
    if ([stateName isEqualToString:@"Sleep"]) {
        [self applyExplicitState:@"Sleep" parser:self.bgParser layerMap:self.bgLayerMap animated:animated];
        [self applyExplicitState:@"Sleep" parser:self.floatParser layerMap:self.floatLayerMap animated:animated];
        [self applyExplicitState:@"Sleep" parser:self.fgParser layerMap:self.fgLayerMap animated:animated];
    }
    
    [CATransaction begin];
    if (!animated) {
        [CATransaction setDisableActions:YES];
    } else {
        [CATransaction setAnimationDuration:g_animDuration];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    }
    
    if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
        [self.bgView setState:stateName animated:animated]; 
        [self.floatingView setState:stateName animated:animated]; 
        [self.fgView setState:stateName animated:animated];
    } else {
        [self.bgView setState:stateName]; 
        [self.floatingView setState:stateName]; 
        [self.fgView setState:stateName];
    }
    [CATransaction commit];
}

- (void)clearCurrentViewsSafely {
    [self.bgView removeFromSuperview]; self.bgView = nil;
    [self.floatingView removeFromSuperview]; self.floatingView = nil;
    [self.fgView removeFromSuperview]; self.fgView = nil;
    [self.bgLayerMap removeAllObjects]; [self.floatLayerMap removeAllObjects]; [self.fgLayerMap removeAllObjects];
    self.bgParser = nil; self.floatParser = nil; self.fgParser = nil;
    self.dynamicSolidColor = nil;
}

- (void)lockSolidBackground {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.bgView) return;
        
        UIColor *targetColor = nil;
        if (self.plistBackgroundColor) {
            targetColor = self.plistBackgroundColor;
        } else if (self.bgParser && [self.bgParser respondsToSelector:@selector(fallbackBackgroundColor)] && [(id)self.bgParser fallbackBackgroundColor]) {
            targetColor = [(id)self.bgParser fallbackBackgroundColor];
        }
        
        if (!targetColor) {
            CALayer *rootLayer = [self.bgView.layer.sublayers firstObject];
            if (rootLayer) {
                NSMutableArray *queue = [NSMutableArray arrayWithObject:rootLayer];
                while (queue.count > 0) {
                    CALayer *layer = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    
                    if (layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) > 0.05) {
                        targetColor = [UIColor colorWithCGColor:layer.backgroundColor];
                        break;
                    }
                    if (layer.sublayers) {
                        [queue addObjectsFromArray:layer.sublayers];
                    }
                }
            }
        }
        
        if (targetColor) {
            self.dynamicSolidColor = targetColor;
            self.backgroundColor = targetColor;
            self.bgView.backgroundColor = targetColor;
        }
    });
}

- (void)reloadWallpaperViews {
    self.reloadGeneration++;
    NSInteger currentGen = self.reloadGeneration;
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!g_enabled || !g_zonePath || ![[NSFileManager defaultManager] fileExistsAtPath:g_zonePath]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (currentGen != self.reloadGeneration) return;
                [self clearCurrentViewsSafely];
            });
            return;
        }
        
        NSFileManager *fm = [NSFileManager defaultManager];
        __block NSString *foundBg = nil; __block NSString *foundFloat = nil; __block NSString *foundFg = nil;
        __block NSString *foundPlist = nil;
        
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:g_zonePath];
        NSString *subPath;
        while ((subPath = [dirEnum nextObject])) {
            if ([subPath containsString:@"__MACOSX"]) { [dirEnum skipDescendants]; continue; }
            NSString *fullPath = [g_zonePath stringByAppendingPathComponent:subPath];
            NSString *fileName = [subPath lastPathComponent];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:fullPath isDirectory:&isDir]) {
                if (isDir && [[[fileName pathExtension] lowercaseString] isEqualToString:@"ca"]) {
                    if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) foundBg = fullPath;
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) foundFloat = fullPath;
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) foundFg = fullPath;
                    [dirEnum skipDescendants];
                } else if (!isDir && [fileName isEqualToString:@"Wallpaper.plist"]) {
                    foundPlist = fullPath;
                }
            }
        }
        
        __block UIColor *parsedBgColor = nil;
        if (foundPlist) {
            NSDictionary *plistData = [NSDictionary dictionaryWithContentsOfFile:foundPlist];
            NSArray *bgArray = plistData[@"backgroundColor"];
            if ([bgArray isKindOfClass:[NSArray class]] && bgArray.count >= 3) {
                CGFloat r = [bgArray[0] doubleValue];
                CGFloat g = [bgArray[1] doubleValue];
                CGFloat b = [bgArray[2] doubleValue];
                CGFloat a = (bgArray.count >= 4) ? [bgArray[3] doubleValue] : 1.0;
                parsedBgColor = [UIColor colorWithRed:r green:g blue:b alpha:a];
            }
        }
        
        if (currentGen != self.reloadGeneration) return; 
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (currentGen != self.reloadGeneration) return; 
            [self clearCurrentViewsSafely]; 
            self.plistBackgroundColor = parsedBgColor;
            
            dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
            Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
            
            if (!PackageViewClass || ![PackageViewClass instancesRespondToSelector:@selector(initWithURL:)]) {
                PackageViewClass = [ZonePackageFallbackView class];
            }
            if (!PackageViewClass) return;
            
            @autoreleasepool {
                if (foundBg) {
                    self.bgView = (BSUICAPackageView *)[[(id)PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:foundBg isDirectory:YES]];
                    if (self.bgView) {
                        [self addSubview:self.bgView];
                        self.bgParser = [ZoneCAMLParserLegacy new]; 
                        [self.bgParser parseFile:[foundBg stringByAppendingPathComponent:@"main.caml"]];
                    }
                }
                if (foundFloat) {
                    self.floatingView = (BSUICAPackageView *)[[(id)PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:foundFloat isDirectory:YES]];
                    if (self.floatingView) {
                        [self addSubview:self.floatingView];
                        self.floatParser = [ZoneCAMLParserLegacy new]; 
                        [self.floatParser parseFile:[foundFloat stringByAppendingPathComponent:@"main.caml"]];
                    }
                }
                if (foundFg) {
                    self.fgView = (BSUICAPackageView *)[[(id)PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:foundFg isDirectory:YES]];
                    if (self.fgView) {
                        [self addSubview:self.fgView];
                        self.fgParser = [ZoneCAMLParserLegacy new]; 
                        [self.fgParser parseFile:[foundFg stringByAppendingPathComponent:@"main.caml"]];
                    }
                }
                
                double factor = g_resolutionFactor;
                if (factor < 0.99) {
                    CGFloat scale = [UIScreen mainScreen].scale * factor;
                    if (self.bgView) { self.bgView.layer.shouldRasterize = YES; self.bgView.layer.rasterizationScale = scale; }
                    if (self.floatingView) { self.floatingView.layer.shouldRasterize = YES; self.floatingView.layer.rasterizationScale = scale; }
                    if (self.fgView) { self.fgView.layer.shouldRasterize = YES; self.fgView.layer.rasterizationScale = scale; }
                } else {
                    if (self.bgView) { self.bgView.layer.shouldRasterize = NO; }
                    if (self.floatingView) { self.floatingView.layer.shouldRasterize = NO; }
                    if (self.fgView) { self.fgView.layer.shouldRasterize = NO; }
                }
            }
            
            [self setNeedsLayout];
            [self layoutIfNeeded];

            self.currentState = @"Init";
            
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            
            BOOL realUnlocked = ZoneIsDeviceUnlocked();
            // 【竞态条件修复】：必须先执行 transitionToState 让 Package 接收真实状态，
            // 否则会被下方的 Progress 通知提前改掉 currentState 导致直接 return 罢工！
            [self transitionToState:realUnlocked ? @"Unlock" : @"Locked" animated:NO];
            
            double currentProgress = realUnlocked ? 1.0 : 0.0;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(currentProgress)}];
            
            [CATransaction commit];
            
            [self lockSolidBackground]; 
        });
    });
}
@end

// =========================================================================
// ==================== 【引擎 2】: 增强渲染引擎 (新逻辑) ====================
// =========================================================================
@interface ZoneCAMLParserEnhanced : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableDictionary *idToNameMap;
@property (nonatomic, strong) NSMutableDictionary *statesData;
@property (nonatomic, strong) NSMutableSet *availableStates;
@property (nonatomic, copy) NSString *currentParsingState;
@property (nonatomic, copy) NSString *currentParsingTargetId;
@property (nonatomic, copy) NSString *currentParsingKeyPath;
@property (nonatomic, assign) BOOL rootParsed;
@property (nonatomic, strong) UIColor *fallbackBackgroundColor;
@property (nonatomic, assign) BOOL isGeometryFlipped;
@property (nonatomic, assign) BOOL isParsingBackgroundColor;
- (void)parseFile:(NSString *)path;
- (NSString *)resolveRealStateNameFor:(NSString *)logicalState isDark:(BOOL)isDark;
@end

@implementation ZoneCAMLParserEnhanced
- (instancetype)init {
    if (self = [super init]) {
        _idToNameMap = [NSMutableDictionary new];
        _statesData = [NSMutableDictionary new];
        _availableStates = [NSMutableSet new];
    }
    return self;
}
- (void)parseFile:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = self;
    [parser parse];
}
- (UIColor *)parseColorString:(NSString *)val opacity:(NSString *)opacityStr {
    NSArray *comps = [val componentsSeparatedByString:@" "];
    if (comps.count >= 3) {
        CGFloat r = [comps[0] doubleValue];
        CGFloat g = [comps[1] doubleValue];
        CGFloat b = [comps[2] doubleValue];
        CGFloat a = opacityStr ? [opacityStr doubleValue] : (comps.count >= 4 ? [comps[3] doubleValue] : 1.0);
        return [UIColor colorWithRed:r green:g blue:b alpha:a];
    }
    return nil;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    // 【修复】：同时识别普通图层和粒子发射器
    if ([elementName isEqualToString:@"CALayer"] || [elementName isEqualToString:@"CAEmitterLayer"]) {
        if (!self.rootParsed) {
            self.rootParsed = YES;
            if ([attributeDict[@"geometryFlipped"] intValue] == 1) self.isGeometryFlipped = YES;
        }
        if (attributeDict[@"backgroundColor"] && !self.fallbackBackgroundColor) {
            UIColor *c = [self parseColorString:attributeDict[@"backgroundColor"] opacity:attributeDict[@"opacity"]];
            if (c && CGColorGetAlpha(c.CGColor) > 0.05) {
                self.fallbackBackgroundColor = c;
            }
        }
        NSString *layerId = attributeDict[@"id"];
        NSString *layerName = attributeDict[@"name"];
        if (layerId && layerName) self.idToNameMap[layerId] = layerName;
    } else if ([elementName isEqualToString:@"backgroundColor"]) {
        self.isParsingBackgroundColor = YES;
        if (attributeDict[@"value"] && !self.fallbackBackgroundColor) {
            UIColor *c = [self parseColorString:attributeDict[@"value"] opacity:attributeDict[@"opacity"]];
            if (c && CGColorGetAlpha(c.CGColor) > 0.05) {
                self.fallbackBackgroundColor = c;
            }
        }
    } else if ([elementName isEqualToString:@"CGColor"]) {
        if (self.isParsingBackgroundColor && attributeDict[@"value"] && !self.fallbackBackgroundColor) {
            UIColor *c = [self parseColorString:attributeDict[@"value"] opacity:attributeDict[@"opacity"]];
            if (c && CGColorGetAlpha(c.CGColor) > 0.05) {
                self.fallbackBackgroundColor = c;
            }
        }
    } else if ([elementName isEqualToString:@"LKState"]) {
        self.currentParsingState = attributeDict[@"name"];
        if (self.currentParsingState) [self.availableStates addObject:self.currentParsingState];
    } else if ([elementName isEqualToString:@"LKStateSetValue"]) {
        self.currentParsingTargetId = attributeDict[@"targetId"];
        self.currentParsingKeyPath = attributeDict[@"keyPath"];
    } else if ([elementName isEqualToString:@"value"]) {
        if (self.currentParsingState && self.currentParsingTargetId && self.currentParsingKeyPath) {
            NSString *valStr = attributeDict[@"value"];
            NSString *typeStr = attributeDict[@"type"];
            if (valStr) {
                id finalValue = nil;
                if ([typeStr isEqualToString:@"CGPoint"]) {
                    NSArray *comps = [valStr componentsSeparatedByString:@" "];
                    if (comps.count == 2) {
                        finalValue = [NSValue valueWithCGPoint:CGPointMake([comps[0] doubleValue], [comps[1] doubleValue])];
                    }
                } else {
                    finalValue = @([valStr doubleValue]);
                }
                if (finalValue) {
                    NSMutableDictionary *targetDict = self.statesData[self.currentParsingTargetId];
                    if (!targetDict) { targetDict = [NSMutableDictionary dictionary]; self.statesData[self.currentParsingTargetId] = targetDict; }
                    NSMutableDictionary *stateDict = targetDict[self.currentParsingState];
                    if (!stateDict) { stateDict = [NSMutableDictionary dictionary]; targetDict[self.currentParsingState] = stateDict; }
                    stateDict[self.currentParsingKeyPath] = finalValue;
                }
            }
        }
    }
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"backgroundColor"]) {
        self.isParsingBackgroundColor = NO;
    } else if ([elementName isEqualToString:@"LKState"]) self.currentParsingState = nil;
    else if ([elementName isEqualToString:@"LKStateSetValue"]) { self.currentParsingTargetId = nil; self.currentParsingKeyPath = nil; }
}
- (NSString *)resolveRealStateNameFor:(NSString *)logicalState isDark:(BOOL)isDark {
    if ([self.availableStates containsObject:logicalState]) return logicalState;
    NSString *keyword = logicalState;
    if ([logicalState isEqualToString:@"Unlock"]) keyword = @"Home"; 
    if ([logicalState isEqualToString:@"Locked"]) keyword = @"Lock";
    
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *state in self.availableStates) {
        NSString *lowerState = [state lowercaseString];
        NSString *lowerLogic = [logicalState lowercaseString];
        NSString *lowerKey = [keyword lowercaseString];
        if ([lowerLogic isEqualToString:@"locked"]) {
            if ([lowerState containsString:@"unlock"] || [lowerState containsString:@"home"]) {
                continue; 
            }
        }
        if ([lowerState containsString:lowerLogic] || [lowerState containsString:lowerKey]) {
            [candidates addObject:state];
        }
    }
    if (candidates.count == 0) return logicalState;
    
    NSString *styleKey = isDark ? @"Dark" : @"Light";
    for (NSString *s in candidates) { if ([s containsString:@"PortraitUp"] && [s localizedCaseInsensitiveContainsString:styleKey]) return s; }
    for (NSString *s in candidates) { if ([s localizedCaseInsensitiveContainsString:styleKey]) return s; }
    for (NSString *s in candidates) { if ([s containsString:@"PortraitUp"]) return s; }
    return candidates.firstObject; 
}
@end


@interface ZoneRenderEngineEnhanced : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isUnlocking; 
@property (nonatomic, strong) NSString *currentState;
@property (nonatomic, assign) NSInteger reloadGeneration; 
@property (nonatomic, assign) CGSize logicalScreenSize; 
@property (nonatomic, strong) ZoneCAMLParserEnhanced *bgParser;
@property (nonatomic, strong) ZoneCAMLParserEnhanced *floatParser;
@property (nonatomic, strong) ZoneCAMLParserEnhanced *fgParser;
@property (nonatomic, strong) NSMutableDictionary *bgLayerMap;
@property (nonatomic, strong) NSMutableDictionary *floatLayerMap;
@property (nonatomic, strong) NSMutableDictionary *fgLayerMap;
@property (nonatomic, assign) BOOL isAnimatingState; 
@property (nonatomic, assign) NSInteger animationGeneration;
@property (nonatomic, strong) UIColor *plistBackgroundColor; 
@property (nonatomic, strong) UIColor *dynamicSolidColor; // 状态持久化底板颜色

// 【新增】：AOD 防强杀 CADisplayLink 核心驱动器属性 
@property (nonatomic, strong) CADisplayLink *manualAnimLink;
@property (nonatomic, assign) double manualAnimStartTime;
@property (nonatomic, strong) NSMutableArray *manualAnimTasks;
@property (nonatomic, copy) NSString *manualTargetState;
@property (nonatomic, assign) BOOL manualIsDark;
//  新增结束 

- (void)reloadWallpaperViews;
- (void)clearCurrentViewsSafely;
- (void)lockSolidBackground;
@end

@implementation ZoneRenderEngineEnhanced
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.isUnlocking = NO;
        self.currentState = @"Init";
        self.reloadGeneration = 0;
        self.logicalScreenSize = CGSizeZero;
        self.isAnimatingState = NO;
        self.animationGeneration = 0;
        
        self.bgLayerMap = [NSMutableDictionary dictionary];
        self.floatLayerMap = [NSMutableDictionary dictionary];
        self.fgLayerMap = [NSMutableDictionary dictionary];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"ZoneEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"ZoneEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"ZoneEngineSleep" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onProgress:) name:@"ZoneEngineProgress" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onStateChange:) name:@"ZoneEngineStateChange" object:nil];
[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMemoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)onStateChange:(NSNotification *)note {
    if (!g_enabled || !self.bgView) return;
    NSString *state = note.userInfo[@"state"];
    NSNumber *animNum = note.userInfo[@"animated"];
    BOOL animated = animNum ? [animNum boolValue] : YES;
    
    if (state) {
        [self transitionToState:state animated:animated];
    }
}

- (void)dealloc { 
    [[NSNotificationCenter defaultCenter] removeObserver:self]; 
    if (_manualAnimLink) { [_manualAnimLink invalidate]; _manualAnimLink = nil; }
}

// 【内存优化】：监听系统内存警告，主动清空不可见的离屏渲染缓存
- (void)handleMemoryWarning {
    if (!g_isScreenOn || [self.currentState isEqualToString:@"Sleep"]) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        
        // 收到内存警告且屏幕未在使用壁纸时，强制刷掉光栅化缓存
        if (self.bgView && self.bgView.layer.shouldRasterize) self.bgView.layer.shouldRasterize = NO;
        if (self.floatingView && self.floatingView.layer.shouldRasterize) self.floatingView.layer.shouldRasterize = NO;
        if (self.fgView && self.fgView.layer.shouldRasterize) self.fgView.layer.shouldRasterize = NO;
        
        [CATransaction commit];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    if (bounds.size.width > screenSize.width + 5) {
        bounds.size = screenSize;
        bounds.origin = CGPointZero;
    }
    
    UIColor *finalBgColor = [UIColor clearColor];
    if (self.dynamicSolidColor) {
        finalBgColor = self.dynamicSolidColor;
    } else if (self.plistBackgroundColor) {
        finalBgColor = self.plistBackgroundColor;
    } else if (self.bgParser && self.bgParser.fallbackBackgroundColor) {
        finalBgColor = self.bgParser.fallbackBackgroundColor;
    }
    self.backgroundColor = finalBgColor;
    
    if (self.bgView) {
        self.bgView.frame = bounds;
        self.bgView.backgroundColor = finalBgColor;
    }
    if (self.floatingView) {
        self.floatingView.frame = bounds;
    }
    if (self.fgView) {
        self.fgView.frame = bounds;
    }
    
    BSUICAPackageView *views[] = {self.bgView, self.floatingView, self.fgView};
    ZoneCAMLParserEnhanced *parsers[] = {self.bgParser, self.floatParser, self.fgParser};
    
    for (int i = 0; i < 3; i++) {
        BSUICAPackageView *v = views[i];
        ZoneCAMLParserEnhanced *p = parsers[i];
        if (!v) continue;
        
        CALayer *rootLayer = [v.layer.sublayers firstObject];
        if (rootLayer) {
            if (@available(iOS 16.0, *)) {
                CGSize targetSize = self.logicalScreenSize;
                if (targetSize.width <= 0 || targetSize.height <= 0) targetSize = bounds.size;
                CGFloat scaleX = bounds.size.width / targetSize.width;
                CGFloat scaleY = bounds.size.height / targetSize.height;
                CGFloat scale = MAX(scaleX, scaleY);
                
                v.layer.geometryFlipped = p ? p.isGeometryFlipped : NO;
                rootLayer.position = CGPointMake(bounds.size.width / 2.0, bounds.size.height / 2.0);
                rootLayer.transform = CATransform3DMakeScale(scale, scale, 1.0);
            } else {
                BOOL camlFlipped = p ? p.isGeometryFlipped : rootLayer.geometryFlipped;
                v.layer.geometryFlipped = !camlFlipped;
                
                CGSize realSize = rootLayer.bounds.size;
                if (realSize.width > 0 && realSize.height > 0) {
                    CGFloat realScaleX = bounds.size.width / realSize.width;
                    CGFloat realScaleY = bounds.size.height / realSize.height;
                    CGFloat realScale = MAX(realScaleX, realScaleY); 
                    
                    rootLayer.position = CGPointMake(bounds.size.width / 2.0, bounds.size.height / 2.0);
                    rootLayer.transform = CATransform3DMakeScale(realScale, realScale, 1.0);
                } else {
                    rootLayer.frame = bounds;
                }
            }
        }
    }
}

- (void)onWakeUp {
    if (!g_enabled || !self.bgView) return;
    self.isUnlocking = NO;
    [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:YES];
}

- (void)onSleep {
    if (!g_enabled || !self.bgView) return;
    self.isUnlocking = NO;
    [self transitionToState:@"Sleep" animated:YES];
}

- (void)ensureLayerMap:(NSMutableDictionary *)layerMap parser:(ZoneCAMLParserEnhanced *)parser packageView:(BSUICAPackageView *)pkgView {
    if (!pkgView || !pkgView.layer || !parser) return;
    if (layerMap.count == 0 && parser.statesData.count > 0) {
        for (NSString *targetId in parser.statesData) {
            NSString *name = parser.idToNameMap[targetId];
            if (name) {
                CALayer *found = ZoneFindLayerByName(pkgView.layer, name);
                if (found) layerMap[targetId] = found;
            }
        }
    }
}

- (void)ensureAllLayerMaps {
    [self ensureLayerMap:self.bgLayerMap parser:self.bgParser packageView:self.bgView];
    [self ensureLayerMap:self.floatLayerMap parser:self.floatParser packageView:self.floatingView];
    [self ensureLayerMap:self.fgLayerMap parser:self.fgParser packageView:self.fgView];
}

- (void)applyProgress:(double)progress parser:(ZoneCAMLParserEnhanced *)parser layerMap:(NSDictionary *)layerMap {
    if (layerMap.count == 0 || !parser) return;
    
    BOOL isDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NSString *realLockedState = [parser resolveRealStateNameFor:@"Locked" isDark:isDark];
    NSString *realUnlockState = [parser resolveRealStateNameFor:@"Unlock" isDark:isDark];
    
    [CATransaction begin]; 
    [CATransaction setDisableActions:YES]; 
    for (NSString *targetId in parser.statesData) {
        CALayer *layer = layerMap[targetId]; if (!layer) continue;
        NSDictionary *states = parser.statesData[targetId];
        
        NSDictionary *lockedVals = states[realLockedState]; 
        NSDictionary *unlockVals = states[realUnlockState];
        if (!lockedVals || !unlockVals) continue;
        
        for (NSString *keyPath in lockedVals) {
            id lockVal = lockedVals[keyPath]; 
            id unlockVal = unlockVals[keyPath];
            
            if (lockVal && unlockVal) {
                [layer removeAnimationForKey:keyPath];
                if ([lockVal isKindOfClass:[NSNumber class]] && [unlockVal isKindOfClass:[NSNumber class]]) {
                    double currentVal = [lockVal doubleValue] + ([unlockVal doubleValue] - [lockVal doubleValue]) * progress;
                    [layer setValue:@(currentVal) forKeyPath:keyPath];
                } 
                else if ([lockVal isKindOfClass:[NSValue class]] && [unlockVal isKindOfClass:[NSValue class]]) {
                    CGPoint lockPt = [lockVal CGPointValue];
                    CGPoint unlockPt = [unlockVal CGPointValue];
                    CGPoint currentPt = CGPointMake(lockPt.x + (unlockPt.x - lockPt.x) * progress,
                                                    lockPt.y + (unlockPt.y - lockPt.y) * progress);
                    [layer setValue:[NSValue valueWithCGPoint:currentPt] forKeyPath:keyPath];
                }
            }
        }
    }
    [CATransaction commit];
}

- (void)applyExplicitState:(NSString *)stateName parser:(ZoneCAMLParserEnhanced *)parser layerMap:(NSDictionary *)layerMap animated:(BOOL)animated {
    if (layerMap.count == 0 || !parser) return;
    BOOL isDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NSString *realState = [parser resolveRealStateNameFor:stateName isDark:isDark];
    
    [CATransaction begin];
    if (!animated) {
        [CATransaction setDisableActions:YES];
    } else {
        [CATransaction setAnimationDuration:g_animDuration]; 
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    }
    
    for (NSString *targetId in parser.statesData) {
        CALayer *layer = layerMap[targetId]; if (!layer) continue;
        NSDictionary *states = parser.statesData[targetId];
        NSDictionary *targetVals = states[realState];
        if (!targetVals) continue;
        
        for (NSString *keyPath in targetVals) {
            id targetVal = targetVals[keyPath];
            if (targetVal) {
                [layer removeAnimationForKey:keyPath];
                @try { [layer setValue:targetVal forKeyPath:keyPath]; } @catch(NSException *e) {}
            }
        }
    }
    [CATransaction commit];
}

// ========================================================
// 【全天候终极修复】：完全脱离 CAAnimation 的纯手写逐帧插值引擎
// ========================================================
- (void)startManualDisplayLinkTransitionToState:(NSString *)stateName isDark:(BOOL)isDark {
    if (self.manualAnimLink) { [self.manualAnimLink invalidate]; self.manualAnimLink = nil; }
    self.manualAnimTasks = [NSMutableArray array];
    self.manualTargetState = stateName;
    self.manualIsDark = isDark;
    
    NSString *realBgState = [self.bgParser resolveRealStateNameFor:stateName isDark:isDark] ?: stateName;
    NSString *realFloatState = [self.floatParser resolveRealStateNameFor:stateName isDark:isDark] ?: stateName;
    NSString *realFgState = [self.fgParser resolveRealStateNameFor:stateName isDark:isDark] ?: stateName;
    
    void (^buildTasks)(ZoneCAMLParserEnhanced *, NSDictionary *, NSString *) = ^(ZoneCAMLParserEnhanced *parser, NSDictionary *layerMap, NSString *realState) {
        if (!parser || layerMap.count == 0) return;
        for (NSString *targetId in parser.statesData) {
            CALayer *layer = layerMap[targetId]; if (!layer) continue;
            NSDictionary *targetVals = parser.statesData[targetId][realState];
            if (!targetVals) continue;
            
            for (NSString *keyPath in targetVals) {
                id endVal = targetVals[keyPath];
                // 抓取动画开始时的当前真实呈现值(Presentation Layer)，解决半路打断反弹问题
                id startVal = [[layer presentationLayer] ?: layer valueForKeyPath:keyPath] ?: [layer valueForKeyPath:keyPath];
                
                if (startVal && endVal) {
                    [layer removeAnimationForKey:keyPath]; // 瞬间杀掉系统原生 CAAnimation
                    [self.manualAnimTasks addObject:@{ @"layer": layer, @"keyPath": keyPath, @"start": startVal, @"end": endVal }];
                }
            }
        }
    };
    
    buildTasks(self.bgParser, self.bgLayerMap, realBgState);
    buildTasks(self.floatParser, self.floatLayerMap, realFloatState);
    buildTasks(self.fgParser, self.fgLayerMap, realFgState);
    
    if (self.manualAnimTasks.count > 0) {
        self.manualAnimStartTime = CACurrentMediaTime();
        self.manualAnimLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(manualTick:)];
        [self.manualAnimLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else {
        [self completeManualTransition];
    }
}

- (void)manualTick:(CADisplayLink *)link {
    double duration = (g_animDuration > 0) ? g_animDuration : 0.85;
    double progress = (CACurrentMediaTime() - self.manualAnimStartTime) / duration;
    if (progress >= 1.0) progress = 1.0;
    
    // 模拟苹果原生的 EaseInOut 缓动曲线
    double easedProgress = progress * progress * (3.0 - 2.0 * progress);
    
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSDictionary *task in self.manualAnimTasks) {
        CALayer *layer = task[@"layer"];
        NSString *keyPath = task[@"keyPath"];
        id startVal = task[@"start"];
        id endVal = task[@"end"];
        
        @try {
            if ([startVal isKindOfClass:[NSNumber class]] && [endVal isKindOfClass:[NSNumber class]]) {
                double s = [startVal doubleValue];
                double e = [endVal doubleValue];
                [layer setValue:@(s + (e - s) * easedProgress) forKeyPath:keyPath];
            } else if ([startVal isKindOfClass:[NSValue class]] && [endVal isKindOfClass:[NSValue class]]) {
                CGPoint s = [startVal CGPointValue];
                CGPoint e = [endVal CGPointValue];
                [layer setValue:[NSValue valueWithCGPoint:CGPointMake(s.x + (e.x - s.x) * easedProgress, s.y + (e.y - s.y) * easedProgress)] forKeyPath:keyPath];
            }
        } @catch (NSException *e) {}
    }
    [CATransaction commit];
    
    if (progress >= 1.0) [self completeManualTransition];
}

- (void)completeManualTransition {
    if (self.manualAnimLink) { [self.manualAnimLink invalidate]; self.manualAnimLink = nil; }

    NSArray *finishedTasks = [self.manualAnimTasks copy];
    self.manualAnimTasks = nil;
    self.isAnimatingState = NO;

    if (finishedTasks.count > 0) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (NSDictionary *task in finishedTasks) {
            CALayer *layer = task[@"layer"];
            NSString *keyPath = task[@"keyPath"];
            id endVal = task[@"end"];
            if (layer && keyPath && endVal) {
                [layer removeAnimationForKey:keyPath];
                @try { [layer setValue:endVal forKeyPath:keyPath]; } @catch (NSException *e) {}
            }
        }
        [CATransaction commit];
    }
}

- (void)onProgress:(NSNotification *)note {
    if (!g_enabled || !self.bgView) return;
    if (!g_isScreenOn || g_isAODInactive) {
        return;
    }
    
    double progress = [note.userInfo[@"progress"] doubleValue];
    progress = MAX(0.0, MIN(1.0, progress));
    
    // 【核心修复 2 完善】：解决亮屏秒滑桌面变锁屏的百年Bug
    if (self.isAnimatingState) {
        if (progress > 0.01 && progress < 0.99) {
            // 1. 手指正在滑动：终止强制动画，把控制权交回给进度条
            [self completeManualTransition];
        } else if (progress >= 0.99 && ZoneIsDeviceUnlocked()) {
            // 2. 已经秒解锁进入桌面：终止残余亮屏动画，瞬间到位
            
            // 【AOD 防闪烁终极修复】：如果是 AOD 免密宽限期内直接亮屏
            // 引擎的目标本身就是展现桌面 (Unlock)，此时绝不能强杀动画！
            // 让它把 0.85 秒的亮屏渐变优雅地播完，无视系统的 1.0 催促指令。
            if ([self.manualTargetState isEqualToString:@"Unlock"]) {
                return; 
            }
            
            [self completeManualTransition];
        } else {
            // 3. 亮息屏瞬间的 0.0/1.0 假进度：坚决拦截防闪烁
            return;
        }
    }

    self.animationGeneration++;
    
    [self ensureAllLayerMaps];
    [self applyProgress:progress parser:self.bgParser layerMap:self.bgLayerMap];
    [self applyProgress:progress parser:self.floatParser layerMap:self.floatLayerMap];
    [self applyProgress:progress parser:self.fgParser layerMap:self.fgLayerMap];
    if (progress > 0.95) { self.currentState = @"Unlock"; self.isUnlocking = NO; }
    else if (progress < 0.05) { self.currentState = @"Locked"; self.isUnlocking = NO; }
    else { self.isUnlocking = YES; self.currentState = @"Scrubbing"; }
}

- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated {
    if (!g_enabled || !self.bgView) return;
    if (!g_enableAnimSpeed) animated = NO; 
    if ([self.currentState isEqualToString:stateName]) return;
    
    //  【核心修复：桌面息屏去动画】 
    if ([stateName isEqualToString:@"Sleep"]) {
        // 如果当前是桌面状态，或者刚按下电源键导致正在向锁屏过渡，强行关掉动画
        if ([self.currentState isEqualToString:@"Unlock"] || 
            (self.isAnimatingState && [self.currentState isEqualToString:@"Locked"])) {
            animated = NO;
            [self completeManualTransition]; // 瞬间干掉正在播放的残余手写动画
        }
    }
    //  核心修复结束 
    self.currentState = [stateName copy];

    BOOL isDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NSString *realBgState = [self.bgParser resolveRealStateNameFor:stateName isDark:isDark] ?: stateName;
    NSString *realFloatState = [self.floatParser resolveRealStateNameFor:stateName isDark:isDark] ?: stateName;
    NSString *realFgState = [self.fgParser resolveRealStateNameFor:stateName isDark:isDark] ?: stateName;
    
    [self ensureAllLayerMaps];
    
    if (animated) {
        self.animationGeneration++;
        self.isAnimatingState = YES;
        // 【核心劫持】：一旦需要动画，启动纯手写逐帧渲染
        // 全天候 AOD 再也杀不掉你的动画了！它和正常开息屏视觉效果一模一样！
        [self startManualDisplayLinkTransitionToState:stateName isDark:isDark];
    } else {
        if ([stateName isEqualToString:@"Unlock"]) {
            [self applyProgress:1.0 parser:self.bgParser layerMap:self.bgLayerMap]; 
            [self applyProgress:1.0 parser:self.floatParser layerMap:self.floatLayerMap]; 
            [self applyProgress:1.0 parser:self.fgParser layerMap:self.fgLayerMap];
        } else if ([stateName isEqualToString:@"Locked"]) {
            [self applyProgress:0.0 parser:self.bgParser layerMap:self.bgLayerMap]; 
            [self applyProgress:0.0 parser:self.floatParser layerMap:self.floatLayerMap];
            [self applyProgress:0.0 parser:self.fgParser layerMap:self.fgLayerMap];
        }
        
        if ([stateName isEqualToString:@"Sleep"]) {
            [self applyExplicitState:@"Sleep" parser:self.bgParser layerMap:self.bgLayerMap animated:NO];
            [self applyExplicitState:@"Sleep" parser:self.floatParser layerMap:self.floatLayerMap animated:NO];
            [self applyExplicitState:@"Sleep" parser:self.fgParser layerMap:self.fgLayerMap animated:NO];
        }
    } // 【修复】：在这里提前闭合 else 分支，让下方的原生指令作为全天候兜底强制执行
    
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
        [self.bgView setState:realBgState animated:NO]; 
        [self.floatingView setState:realFloatState animated:NO]; 
        [self.fgView setState:realFgState animated:NO];
    } else {
        [self.bgView setState:realBgState]; 
        [self.floatingView setState:realFloatState]; 
        [self.fgView setState:realFgState];
    }
    [CATransaction commit];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        if (g_isScreenOn && self.currentState && ![self.currentState isEqualToString:@"Init"] && ![self.currentState isEqualToString:@"Sleep"]) {
            NSString *savedState = [self.currentState copy];
            self.currentState = nil;
            [self transitionToState:savedState animated:YES];
        }
    }
}

- (void)clearCurrentViewsSafely {
    if (self.manualAnimLink) { [self.manualAnimLink invalidate]; self.manualAnimLink = nil; }
    self.manualAnimTasks = nil;
    
    [self.bgView removeFromSuperview]; self.bgView = nil;
    [self.floatingView removeFromSuperview]; self.floatingView = nil;
    [self.fgView removeFromSuperview]; self.fgView = nil;
    [self.bgLayerMap removeAllObjects]; [self.floatLayerMap removeAllObjects]; [self.fgLayerMap removeAllObjects];
    self.bgParser = nil; self.floatParser = nil; self.fgParser = nil;
    self.dynamicSolidColor = nil;
    self.logicalScreenSize = CGSizeZero;
}

- (void)lockSolidBackground {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.bgView) return;
        
        UIColor *targetColor = nil;
        if (self.plistBackgroundColor) {
            targetColor = self.plistBackgroundColor;
        } else if (self.bgParser && [self.bgParser respondsToSelector:@selector(fallbackBackgroundColor)] && [(id)self.bgParser fallbackBackgroundColor]) {
            targetColor = [(id)self.bgParser fallbackBackgroundColor];
        }
        
        if (!targetColor) {
            CALayer *rootLayer = [self.bgView.layer.sublayers firstObject];
            if (rootLayer) {
                NSMutableArray *queue = [NSMutableArray arrayWithObject:rootLayer];
                while (queue.count > 0) {
                    CALayer *layer = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    
                    if (layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) > 0.05) {
                        targetColor = [UIColor colorWithCGColor:layer.backgroundColor];
                        break;
                    }
                    if (layer.sublayers) {
                        [queue addObjectsFromArray:layer.sublayers];
                    }
                }
            }
        }
        
        if (targetColor) {
            self.dynamicSolidColor = targetColor;
            self.backgroundColor = targetColor;
            self.bgView.backgroundColor = targetColor;
        }
    });
}

- (void)reloadWallpaperViews {
    self.reloadGeneration++;
    NSInteger currentGen = self.reloadGeneration;
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!g_enabled || !g_zonePath || ![[NSFileManager defaultManager] fileExistsAtPath:g_zonePath]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (currentGen != self.reloadGeneration) return;
                [self clearCurrentViewsSafely];
            });
            return;
        }
        
        NSFileManager *fm = [NSFileManager defaultManager];
        __block NSString *foundBg = nil; __block NSString *foundFloat = nil; __block NSString *foundFg = nil;
        __block NSString *foundPlist = nil;
        
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:g_zonePath];
        NSString *subPath;
        while ((subPath = [dirEnum nextObject])) {
            if ([subPath containsString:@"__MACOSX"]) { [dirEnum skipDescendants]; continue; }
            NSString *fullPath = [g_zonePath stringByAppendingPathComponent:subPath];
            NSString *fileName = [subPath lastPathComponent];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:fullPath isDirectory:&isDir]) {
                if (isDir && [[[fileName pathExtension] lowercaseString] isEqualToString:@"ca"]) {
                    if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) foundBg = fullPath;
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) foundFloat = fullPath;
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) foundFg = fullPath;
                    [dirEnum skipDescendants];
                } else if (!isDir && [fileName isEqualToString:@"Wallpaper.plist"]) {
                    foundPlist = fullPath;
                }
            }
        }
        
        __block CGSize targetSize = CGSizeZero;
        __block UIColor *parsedBgColor = nil;
        
        if (foundPlist) {
            NSDictionary *plistData = [NSDictionary dictionaryWithContentsOfFile:foundPlist];
            NSString *logicalClassStr = plistData[@"logicalScreenClass"];
            if (logicalClassStr) {
                NSRange wRange = [logicalClassStr rangeOfString:@"w-"];
                NSRange hRange = [logicalClassStr rangeOfString:@"h@"];
                if (wRange.location != NSNotFound && hRange.location != NSNotFound) {
                    NSString *wStr = [logicalClassStr substringToIndex:wRange.location];
                    NSString *hStr = [logicalClassStr substringWithRange:NSMakeRange(NSMaxRange(wRange), hRange.location - NSMaxRange(wRange))];
                    if ([wStr doubleValue] > 0 && [hStr doubleValue] > 0) {
                        targetSize = CGSizeMake([wStr doubleValue], [hStr doubleValue]);
                    }
                }
            }
            
            NSArray *bgArray = plistData[@"backgroundColor"];
            if ([bgArray isKindOfClass:[NSArray class]] && bgArray.count >= 3) {
                CGFloat r = [bgArray[0] doubleValue];
                CGFloat g = [bgArray[1] doubleValue];
                CGFloat b = [bgArray[2] doubleValue];
                CGFloat a = (bgArray.count >= 4) ? [bgArray[3] doubleValue] : 1.0;
                parsedBgColor = [UIColor colorWithRed:r green:g blue:b alpha:a];
            }
        }
        
        if (currentGen != self.reloadGeneration) return; 
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (currentGen != self.reloadGeneration) return; 
            [self clearCurrentViewsSafely]; 
            self.logicalScreenSize = targetSize; 
            self.plistBackgroundColor = parsedBgColor;
            
            dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
            Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
            
            if (!PackageViewClass || ![PackageViewClass instancesRespondToSelector:@selector(initWithURL:)]) {
                PackageViewClass = [ZonePackageFallbackView class];
            }
            if (!PackageViewClass) return;
            
            @autoreleasepool {
                if (foundBg) {
                    self.bgView = (BSUICAPackageView *)[[(id)PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:foundBg isDirectory:YES]];
                    if (self.bgView) {
                        [self addSubview:self.bgView];
                        self.bgParser = [ZoneCAMLParserEnhanced new]; 
                        [self.bgParser parseFile:[foundBg stringByAppendingPathComponent:@"main.caml"]];
                    }
                }
                if (foundFloat) {
                    self.floatingView = (BSUICAPackageView *)[[(id)PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:foundFloat isDirectory:YES]];
                    if (self.floatingView) {
                        [self addSubview:self.floatingView];
                        self.floatParser = [ZoneCAMLParserEnhanced new]; 
                        [self.floatParser parseFile:[foundFloat stringByAppendingPathComponent:@"main.caml"]];
                    }
                }
                if (foundFg) {
                    self.fgView = (BSUICAPackageView *)[[(id)PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:foundFg isDirectory:YES]];
                    if (self.fgView) {
                        [self addSubview:self.fgView];
                        self.fgParser = [ZoneCAMLParserEnhanced new]; 
                        [self.fgParser parseFile:[foundFg stringByAppendingPathComponent:@"main.caml"]];
                    }
                }
                
                double factor = g_resolutionFactor;
                // 【内存优化】：改良光栅化与异步绘制策略，防止内存雪崩
                if (factor < 0.99) {
                    CGFloat scale = [UIScreen mainScreen].scale * factor;
                    if (self.bgView) { 
                        self.bgView.layer.shouldRasterize = YES; 
                        self.bgView.layer.rasterizationScale = scale; 
                        self.bgView.layer.opaque = NO; 
                        self.bgView.layer.drawsAsynchronously = YES; 
                    }
                    if (self.floatingView) { 
                        self.floatingView.layer.shouldRasterize = YES; 
                        self.floatingView.layer.rasterizationScale = scale; 
                        self.floatingView.layer.opaque = NO; 
                        self.floatingView.layer.drawsAsynchronously = YES; 
                    }
                    if (self.fgView) { 
                        self.fgView.layer.shouldRasterize = YES; 
                        self.fgView.layer.rasterizationScale = scale; 
                        self.fgView.layer.opaque = NO; 
                        self.fgView.layer.drawsAsynchronously = YES; 
                    }
                } else {
                    if (self.bgView) { self.bgView.layer.shouldRasterize = NO; self.bgView.layer.drawsAsynchronously = YES; }
                    if (self.floatingView) { self.floatingView.layer.shouldRasterize = NO; self.floatingView.layer.drawsAsynchronously = YES; }
                    if (self.fgView) { self.fgView.layer.shouldRasterize = NO; self.fgView.layer.drawsAsynchronously = YES; }
                }
            }
            
            [self setNeedsLayout];
            [self layoutIfNeeded];

            self.currentState = @"Init";
            
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            
            BOOL realUnlocked = ZoneIsDeviceUnlocked();
            // 【竞态条件修复】：必须先执行 transitionToState 让 Package 接收真实状态，
            // 否则会被下方的 Progress 通知提前改掉 currentState 导致直接 return 罢工！
            [self transitionToState:realUnlocked ? @"Unlock" : @"Locked" animated:NO];
            
            double currentProgress = realUnlocked ? 1.0 : 0.0;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(currentProgress)}];
            
            [CATransaction commit];
            
            [self lockSolidBackground]; 
        });
    });
}
@end

// =========================================================================
// ==================== 智能防漏动态热切换调度核心 =========================
// =========================================================================

static void EnsureEngineViewIsMounted() {
    id wallpaperController = [%c(SBWallpaperController) sharedInstance];
    if (!wallpaperController) return;
    
    UIView *targetContainer = safelyGetIvarAsView(wallpaperController, "_wallpaperWindow");
    if (!targetContainer) {
        targetContainer = safelyGetIvarAsView(wallpaperController, "_wallpaperContainerView");
    }
    if (!targetContainer) return;
    
    UIView *existingEngine = objc_getAssociatedObject(wallpaperController, "GlobalZoneEngine");

    if (!g_enabled) {
        if (existingEngine) {
            if ([existingEngine respondsToSelector:@selector(clearCurrentViewsSafely)]) {
                [existingEngine performSelector:@selector(clearCurrentViewsSafely)];
            }
            [existingEngine removeFromSuperview];
            objc_setAssociatedObject(wallpaperController, "GlobalZoneEngine", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    
    BOOL isEnhancedClass = [existingEngine isKindOfClass:NSClassFromString(@"ZoneRenderEngineEnhanced")];
    BOOL isLegacyClass = [existingEngine isKindOfClass:NSClassFromString(@"ZoneRenderEngineLegacy")];
    BOOL isVideoClass = [existingEngine isKindOfClass:NSClassFromString(@"ZoneVideoEngine")];
    
    if (existingEngine) {
        BOOL shouldDestroy = NO;
        if (g_isVideoMode && !isVideoClass) shouldDestroy = YES;
        if (!g_isVideoMode && isVideoClass) shouldDestroy = YES;
        if (!g_isVideoMode && g_enhanced_engine && !isEnhancedClass) shouldDestroy = YES;
        if (!g_isVideoMode && !g_enhanced_engine && !isLegacyClass) shouldDestroy = YES;
        
        if (shouldDestroy) {
            if ([existingEngine respondsToSelector:@selector(clearCurrentViewsSafely)]) {
                [existingEngine performSelector:@selector(clearCurrentViewsSafely)];
            }
            [existingEngine removeFromSuperview];
            existingEngine = nil;
            objc_setAssociatedObject(wallpaperController, "GlobalZoneEngine", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    
    if (!existingEngine) {
        if (g_isVideoMode) {
            existingEngine = [[ZoneVideoEngine alloc] initWithFrame:targetContainer.bounds];
        } else if (g_enhanced_engine) {
            existingEngine = [[ZoneRenderEngineEnhanced alloc] initWithFrame:targetContainer.bounds];
        } else {
            existingEngine = [[ZoneRenderEngineLegacy alloc] initWithFrame:targetContainer.bounds];
        }
        objc_setAssociatedObject(wallpaperController, "GlobalZoneEngine", existingEngine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [targetContainer addSubview:existingEngine];
        
        if ([existingEngine respondsToSelector:@selector(reloadWallpaperViews)]) {
            [existingEngine performSelector:@selector(reloadWallpaperViews)];
        }
    }
    
    if (existingEngine.superview != targetContainer) {
        [existingEngine removeFromSuperview];
        [targetContainer addSubview:existingEngine];
    }
    
    existingEngine.frame = targetContainer.bounds;
    [targetContainer bringSubviewToFront:existingEngine];
}

// =========================================================================
// ==================== 【iOS 16+ 专属 Hook 区域】===========================
// =========================================================================
%group iOS16Plus

%hook PBUIWallpaperView

%new
- (BOOL)zone_isMainWallpaperContainer {
    UIView *view = self;
    BOOL isMain = NO;
    while (view) {
        NSString *className = NSStringFromClass([view class]);
        
        if ([className containsString:@"SceneView"] || 
            [className containsString:@"AppContainer"] ||
            [className containsString:@"Folder"] || 
            [className containsString:@"Dock"] ||
            [className containsString:@"Reachability"]) {
            return NO; 
        }
        
        if ([className containsString:@"CoverSheet"] || 
            [className containsString:@"WallpaperWindow"] || 
            [className containsString:@"WallpaperViewController"] || 
            [className containsString:@"Switcher"]) {
            isMain = YES;
        }
        view = view.superview;
    }
    return isMain;
}

- (void)layoutSubviews {
    %orig;
    if (!g_enabled) {
        self.hidden = NO;
        self.alpha = 1.0;
        self.layer.opacity = 1.0;
        return;
    }

    if (![self zone_isMainWallpaperContainer]) return;

    if (g_isVideoMode) {
        BOOL hasLock = (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);
        BOOL hasHome = (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath]);
        BOOL hide = NO;
        
        if (IsSingleVideoMode() || (hasLock && hasHome)) {
            hide = YES;
        } else {
            long long variant = 1; 
            if ([self respondsToSelector:@selector(variant)]) {
                variant = (long long)[self performSelector:@selector(variant)];
            }
            if (variant == 0) {
                hide = hasLock;
            } else {
                hide = hasHome;
            }
        }
        self.hidden = hide;
        self.alpha = hide ? 0.0 : 1.0;
        self.layer.opacity = hide ? 0.0 : 1.0; // 【核心修复 4】：暴力绑定底层图层不透明度
    } else {
        self.hidden = YES;
        self.alpha = 0.0;
        self.layer.opacity = 0.0;
    }
}

- (void)setAlpha:(double)alpha {
    if (g_enabled && [self respondsToSelector:@selector(zone_isMainWallpaperContainer)] && [self zone_isMainWallpaperContainer]) {
        if (!g_isVideoMode) { %orig(0.0); self.layer.opacity = 0.0; return; }
        
        BOOL hasLock = (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);
        BOOL hasHome = (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath]);
        if (IsSingleVideoMode() || (hasLock && hasHome)) { %orig(0.0); self.layer.opacity = 0.0; return; }
        
        long long variant = 1;
        if ([self respondsToSelector:@selector(variant)]) variant = (long long)[self performSelector:@selector(variant)];
        
        if (variant == 0 && hasLock) { %orig(0.0); self.layer.opacity = 0.0; return; }
        if (variant != 0 && hasHome) { %orig(0.0); self.layer.opacity = 0.0; return; }
    }
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    if (g_enabled && [self respondsToSelector:@selector(zone_isMainWallpaperContainer)] && [self zone_isMainWallpaperContainer]) {
        if (!g_isVideoMode) { %orig(YES); self.layer.opacity = 0.0; return; }
        
        BOOL hasLock = (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);
        BOOL hasHome = (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath]);
        if (IsSingleVideoMode() || (hasLock && hasHome)) { %orig(YES); self.layer.opacity = 0.0; return; }
        
        long long variant = 1;
        if ([self respondsToSelector:@selector(variant)]) variant = (long long)[self performSelector:@selector(variant)];
        
        if (variant == 0 && hasLock) { %orig(YES); self.layer.opacity = 0.0; return; }
        if (variant != 0 && hasHome) { %orig(YES); self.layer.opacity = 0.0; return; }
    }
    %orig;
}
%end

%hook PBUIWallpaperViewController
- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewWillLayoutSubviews) name:@"ZoneForceLayout" object:nil];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ZoneForceLayout" object:nil];
    %orig;
}

- (void)viewWillLayoutSubviews {
    %orig;
    
    if (!g_enabled) {
        if ([self respondsToSelector:@selector(homescreenWallpaperView)]) {
            UIView *homeView = [self homescreenWallpaperView];
            if (homeView) homeView.alpha = 1.0;
        }
        if ([self respondsToSelector:@selector(lockscreenWallpaperView)]) {
            UIView *lockView = [self lockscreenWallpaperView];
            if (lockView) lockView.alpha = 1.0;
        }
        return;
    }
    
    BOOL hideHome = !g_isVideoMode || (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath]);
    BOOL hideLock = !g_isVideoMode || (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);

    if ([self respondsToSelector:@selector(homescreenWallpaperView)]) {
        UIView *homeView = [self homescreenWallpaperView];
        if (homeView) homeView.alpha = hideHome ? 0.0 : 1.0;
    }
    if ([self respondsToSelector:@selector(lockscreenWallpaperView)]) {
        UIView *lockView = [self lockscreenWallpaperView];
        if (lockView) lockView.alpha = hideLock ? 0.0 : 1.0;
    }
}
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state {
    if (g_enabled && !g_isVideoMode) return nil;
    if (g_enabled && g_isVideoMode && IsSingleVideoMode()) return %orig;
    if (g_enabled && g_isVideoMode) return nil;
    return %orig;
}
- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)oldState newState:(void *)newState oldEffectView:(id *)oldView newEffectView:(id *)newView {
    if (g_enabled && !g_isVideoMode) return NO;
    if (g_enabled && g_isVideoMode && IsSingleVideoMode()) return %orig;
    if (g_enabled && g_isVideoMode) return NO;
    return %orig;
}
%end

%hook CSCoverSheetViewController
- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewWillLayoutSubviews) name:@"ZoneForceLayout" object:nil];
    
    // 【新增】：锁屏双击手势注入
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zone_handleLockScreenDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.cancelsTouchesInView = NO; // 极其重要：设为 NO 才能保证不影响原生的向上滑动解锁、右滑相机等手势！
    doubleTap.delaysTouchesBegan = NO;
    [self.view addGestureRecognizer:doubleTap];
}

%new
- (void)zone_handleLockScreenDoubleTap:(UITapGestureRecognizer *)gesture {
    if (g_enabled && g_doubleTapLock) {
        [(SpringBoard *)[%c(SpringBoard) sharedApplication] _simulateLockButtonPress];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ZoneForceLayout" object:nil];
    %orig;
}

- (void)viewWillLayoutSubviews {
    %orig;
    _UIPortalView *portalView = objc_getAssociatedObject(self, "CoverSheetZonePortal");

    if (!g_enabled) {
        if (portalView) portalView.hidden = YES;
        UIViewController *bgVC = safelyGetIvarAsViewController(self, "_backgroundContentViewController");
        if (bgVC && bgVC.view) {
            for (UIView *sub in bgVC.view.subviews) {
                sub.alpha = 1.0;
                sub.hidden = NO;
            }
        }
        return;
    }

    EnsureEngineViewIsMounted(); 

    UIViewController *bgVC = safelyGetIvarAsViewController(self, "_backgroundContentViewController");
    if (bgVC && bgVC.view) {
        bgVC.view.alpha = 1.0;
        bgVC.view.hidden = NO;
    }

    id wallpaperController = [%c(SBWallpaperController) sharedInstance];
    UIView *engineView = objc_getAssociatedObject(wallpaperController, "GlobalZoneEngine");
    BOOL freezeAODLayout = (g_isAODInactive && !g_isScreenOn);

    if (engineView) {
        UIView *sourceForPortal = engineView;
        if (g_isVideoMode) {
            if (IsSingleVideoMode()) {
                if ([engineView respondsToSelector:@selector(homeVideoView)]) {
                    UIView *homeView = [engineView performSelector:@selector(homeVideoView)];
                    if (homeView) sourceForPortal = homeView;
                }
            } else {
                if ([engineView respondsToSelector:@selector(lockVideoView)]) {
                    UIView *lockView = [engineView performSelector:@selector(lockVideoView)];
                    if (lockView) sourceForPortal = lockView;
                    else sourceForPortal = nil; 
                }
            }
        }

        if (!portalView) {
            portalView = [[NSClassFromString(@"_UIPortalView") alloc] initWithFrame:self.view.bounds];
            portalView.hidesSourceView = NO;
            portalView.matchesAlpha = NO; 
            portalView.alpha = g_isVideoMode ? 1.0 : 0.0; 
            portalView.matchesPosition = freezeAODLayout ? NO : (IsSingleVideoMode() ? YES : (g_isVideoMode ? NO : YES));
            portalView.matchesTransform = YES;
            portalView.clipsToBounds = YES; 
            portalView.userInteractionEnabled = NO;
            objc_setAssociatedObject(self, "CoverSheetZonePortal", portalView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            g_portalView = portalView;
        }

        if (sourceForPortal && portalView.sourceView != sourceForPortal && !freezeAODLayout) {
            portalView.sourceView = sourceForPortal; 
        } else if (sourceForPortal && !portalView.sourceView) {
            portalView.sourceView = sourceForPortal;
        }

        if (freezeAODLayout) {
        portalView.hidden = NO;
        if (portalView.alpha != 1.0) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            portalView.alpha = 1.0;
            [CATransaction commit];
        }
    } else if (sourceForPortal) {
            portalView.hidden = NO;
            if (IsSingleVideoMode()) {
                if (portalView.matchesPosition != YES) portalView.matchesPosition = YES;
                portalView.alpha = 1.0;
            } else if (g_isVideoMode && portalView.matchesPosition != NO) {
                portalView.matchesPosition = NO;
                portalView.alpha = 1.0;
            } else if (!g_isVideoMode && portalView.matchesPosition != YES) {
                portalView.matchesPosition = YES;
            }
        } else {
            portalView.hidden = YES;
        }

        BOOL hideNativeBlurs = !g_isVideoMode || (!IsSingleVideoMode() && g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);

        if (bgVC && bgVC.view) {
            if (portalView.superview != bgVC.view) {
                [portalView removeFromSuperview];
                [bgVC.view addSubview:portalView];
            }
            portalView.frame = bgVC.view.bounds;
            bgVC.view.clipsToBounds = YES;

            if (!freezeAODLayout) {
                for (UIView *sub in bgVC.view.subviews) {
                    if (sub != portalView) {
                        if (hideNativeBlurs) {
                            sub.alpha = 0.0;
                            sub.hidden = YES;
                        } else {
                            sub.alpha = 1.0;
                            sub.hidden = NO;
                        }
                    }
                }
            }
        } else {
            if (portalView.superview != self.view) {
                [self.view insertSubview:portalView atIndex:0];
            }
            portalView.frame = self.view.bounds;
            [self.view sendSubviewToBack:portalView];
        }

        if (!freezeAODLayout) {
            UIView *dimmingView = safelyGetIvarAsView(self, "_dimmingView");
            if (dimmingView && hideNativeBlurs) { dimmingView.alpha = 0.0; dimmingView.hidden = YES; }

            UIView *tintingView = safelyGetIvarAsView(self, "_tintingView");
            if (tintingView && hideNativeBlurs) { tintingView.alpha = 0.0; tintingView.hidden = YES; }
        }
    }

    UIView *floatingLayer = safelyGetIvarAsView(self, "_floatingLayerView");
    if (floatingLayer) { 
        floatingLayer.alpha = 0.0; 
        floatingLayer.hidden = YES; 
    }
}

- (void)updatePosterSwitcherSnapshots { if (g_enabled) return; %orig; }

- (void)_prepareForPosterSwitcherPresentation {
    %orig;
    if (g_enabled && g_portalView) {
        g_portalView.hidden = YES;
        g_portalView.alpha = 0.0;
    }
}

- (void)_dismissPosterSwitcherViewController {
    %orig;
    if (g_enabled && g_portalView) {
        g_portalView.hidden = NO;
        [self viewWillLayoutSubviews];
    }
}

- (void)_cleanupPosterSwitcherPresentationForCompleted:(BOOL)completed withActivatingTouches:(id)touches {
    %orig;
    if (g_enabled && g_portalView) {
        g_portalView.hidden = NO;
        [self viewWillLayoutSubviews];
    }
}

// 以锁屏UI的真实视觉状态为基准，但 AOD 期间不允许反向改写壁纸态
- (void)setDismissed:(BOOL)dismissed {
    %orig;
    g_isUnlocked = dismissed;
    if (g_enabled && g_isScreenOn && !g_isAODInactive) {
        NSString *state = dismissed ? @"Unlock" : @"Locked";
        ZoneEmitWallpaperState(YES, state, YES);
    }
}

- (void)setInScreenOffMode:(BOOL)mode {
    if (g_enabled) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        ZoneCommitAODTransition(!mode, state, YES);
    }
    %orig;
}

- (void)_startFadeInAnimationForSource:(int)source {
    if (g_enabled) {
        NSString *state = g_isUnlocked ? @"Unlock" : @"Locked";
        ZoneCommitAODTransition(YES, state, YES);
    }
    %orig;
}

- (void)_updateAppearanceForAODTransitionToInactive:(BOOL)inactive {
    if (g_enabled) {
        NSString *state = inactive ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        ZoneCommitAODTransition(!inactive, state, YES);
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (g_enabled) {
        g_lastTickProgress = -1;
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (g_enabled) {
        g_lastTickProgress = -1;
    }
}
%end

%hook SBWallpaperController

- (void)updatePosterSwitcherSnapshots {
    if (g_enabled) return;
    %orig;
}

- (void)updateWallpaperAnimationWithProgress:(double)progress {
    %orig;
    if (!g_enabled) return;

    // 【核心修复 3】: 无论是否在 AOD 状态，必须第一时间先更新 portalView 的透明度！
    // 这样在桌面触发息屏时，引擎画面才能瞬间接管锁屏，防止出现黑屏断层空窗期！
    if (g_portalView && g_isScreenOn && !g_isAODInactive) {
        if (g_isVideoMode) {
            if (g_portalView.alpha != 1.0) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                g_portalView.alpha = 1.0;
                [CATransaction commit];
            }
        } else {
            double alpha = 0.0;
            if (progress > 0.7) {
                alpha = (1.0 - progress) * (0.05 / 0.3);
            } else if (progress > 0.6) {
                alpha = 0.05 + (0.7 - progress) * 1.0; 
            } else {
                alpha = 0.15 + ((0.6 - progress) / 0.6) * 0.85;
            }
            alpha = MAX(0.0, MIN(1.0, alpha));
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            g_portalView.alpha = alpha;
            [CATransaction commit];
        }
    }

    if (g_deferAODWakeWallpaperState && g_isScreenOn && !g_isAODInactive) {
        g_deferAODWakeWallpaperState = NO;
        ZoneFlushPendingAODWallpaperState();
    }

    // 只有拦截 ZoneEngineProgress 才需要 return，保留上面的 portal 透明度过渡
    if (!g_isScreenOn || g_isAODInactive) {
        ZonePinPortalVisibleForAODSleep();
        g_lastSystemProgress = progress;
        return;
    }

    if (g_forceAcceptNextSystemProgress) {
        g_forceAcceptNextSystemProgress = NO;
        g_lastSystemProgress = progress;
    } else {
        double delta = progress - g_lastSystemProgress;
        g_lastSystemProgress = progress;

        if (ABS(delta) > 0.15) {
            return;
        }
    }

    EnsureEngineViewIsMounted();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
}
%end

%hook SBBacklightController
- (void)backlightHost:(id)host willTransitionToState:(long long)state forEvent:(id)event {
    %orig;
    if (g_enabled && !g_isVideoMode) {
        if (!ZoneIsDefinitiveBacklightState(state)) {
            return;
        }
        if (ZoneShouldIgnoreAODBacklightWakeState(state)) {
            return;
        }
        BOOL screenOn = (state == 1);
        if (screenOn != g_isScreenOn) {
            NSString *zoneState = screenOn ? (g_isUnlocked ? @"Unlock" : @"Locked") : @"Sleep";
            ZoneCommitAODTransition(screenOn, zoneState, YES);
        }
    }
}

- (void)backlight:(id)backlight didCompleteUpdateToState:(long long)state forEvent:(id)event {
    %orig;
    if (g_enabled && !g_isVideoMode) {
        if (!ZoneIsDefinitiveBacklightState(state)) {
            return;
        }
        if (ZoneShouldIgnoreAODBacklightWakeState(state)) {
            return;
        }
        BOOL screenOn = (state == 1);
        if (screenOn != g_isScreenOn) {
            NSString *zoneState = screenOn ? (g_isUnlocked ? @"Unlock" : @"Locked") : @"Sleep";
            ZoneCommitAODTransition(screenOn, zoneState, YES);
        }
    }
}
%end

%end // 结束 iOS16Plus


// =========================================================================
// ==================== 【iOS 14-15 专属 Hook 区域】 ========================
// =========================================================================
%group iOS14_15

%hook SBFWallpaperView

%new
- (BOOL)zone_isMainWallpaperContainer {
    UIView *view = self;
    BOOL isMain = NO;
    while (view) {
        NSString *className = NSStringFromClass([view class]);
        
        // 把 Reachability 调入黑名单，拦截插件隐藏逻辑
        if ([className containsString:@"SceneView"] || 
            [className containsString:@"AppContainer"] ||
            [className containsString:@"Folder"] || 
            [className containsString:@"Dock"] ||
            [className containsString:@"Reachability"]) {
            return NO; 
        }
        
        if ([className containsString:@"CoverSheet"] || 
            [className containsString:@"WallpaperWindow"] || 
            [className containsString:@"WallpaperViewController"] || 
            [className containsString:@"Switcher"]) {
            isMain = YES;
        }
        view = view.superview;
    }
    return isMain;
}

- (void)layoutSubviews {
    %orig;
    if (!g_enabled) {
        self.hidden = NO;
        self.alpha = 1.0;
        return;
    }
    
    if (![self zone_isMainWallpaperContainer]) return;

    if (g_isVideoMode) {
        BOOL hasLock = (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);
        BOOL hasHome = (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath]);
        BOOL hide = NO;
        
        if (IsSingleVideoMode() || (hasLock && hasHome)) {
            hide = YES;
        } else {
            long long variant = 1; 
            if ([self respondsToSelector:@selector(variant)]) {
                variant = (long long)[self performSelector:@selector(variant)];
            }
            if (variant == 0) {
                hide = hasLock;
            } else {
                hide = hasHome;
            }
        }
        self.hidden = hide;
        self.alpha = hide ? 0.0 : 1.0;
    } else {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}

- (void)setAlpha:(double)alpha {
    if (g_enabled && [self respondsToSelector:@selector(zone_isMainWallpaperContainer)] && [self zone_isMainWallpaperContainer]) {
        if (!g_isVideoMode) { %orig(0.0); return; }
        
        BOOL hasLock = (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);
        BOOL hasHome = (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath]);
        if (IsSingleVideoMode() || (hasLock && hasHome)) { %orig(0.0); return; }
        
        long long variant = 1;
        if ([self respondsToSelector:@selector(variant)]) variant = (long long)[self performSelector:@selector(variant)];
        
        if (variant == 0 && hasLock) { %orig(0.0); return; }
        if (variant != 0 && hasHome) { %orig(0.0); return; }
    }
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    if (g_enabled && [self respondsToSelector:@selector(zone_isMainWallpaperContainer)] && [self zone_isMainWallpaperContainer]) {
        if (!g_isVideoMode) { %orig(YES); return; }
        
        BOOL hasLock = (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);
        BOOL hasHome = (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath]);
        if (IsSingleVideoMode() || (hasLock && hasHome)) { %orig(YES); return; }
        
        long long variant = 1;
        if ([self respondsToSelector:@selector(variant)]) variant = (long long)[self performSelector:@selector(variant)];
        
        if (variant == 0 && hasLock) { %orig(YES); return; }
        if (variant != 0 && hasHome) { %orig(YES); return; }
    }
    %orig;
}
%end

%hook CSCoverSheetViewController
- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewWillLayoutSubviews) name:@"ZoneForceLayout" object:nil];
    if (g_enabled) {
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(zone_tickProgress)];
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, "ZoneTicker", link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(zone_screenSleep) name:@"ZoneEngineSleep" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(zone_screenWake) name:@"ZoneEngineWake" object:nil];
    }
    
    // 【新增】：锁屏双击手势注入
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zone_handleLockScreenDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.cancelsTouchesInView = NO; // 极其重要：设为 NO 才能保证不影响原生的向上滑动解锁、右滑相机等手势！
    doubleTap.delaysTouchesBegan = NO;
    [self.view addGestureRecognizer:doubleTap];
}

%new
- (void)zone_handleLockScreenDoubleTap:(UITapGestureRecognizer *)gesture {
    if (g_enabled && g_doubleTapLock) {
        [(SpringBoard *)[%c(SpringBoard) sharedApplication] _simulateLockButtonPress];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ZoneForceLayout" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ZoneEngineSleep" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ZoneEngineWake" object:nil];
    CADisplayLink *link = objc_getAssociatedObject(self, "ZoneTicker");
    if (link) [link invalidate];
    %orig;
}

%new
- (void)zone_tickProgress {
    if (!g_enabled || !g_isScreenOn) return;
    CALayer *presLayer = self.view.layer.presentationLayer ?: self.view.layer;
    CGRect absoluteRect = [presLayer.superlayer convertRect:presLayer.frame toLayer:nil];
    double yOffset = absoluteRect.origin.y;
    double screenHeight = [UIScreen mainScreen].bounds.size.height;
    double engineProgress = -yOffset / screenHeight;
    engineProgress = MAX(0.0, MIN(1.0, engineProgress));
    
    if (ABS(engineProgress - g_lastTickProgress) > 0.0001) {
        g_lastTickProgress = engineProgress;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(engineProgress)}];
        
        if (g_portalView) {
            if (g_isVideoMode) {
                if (g_portalView.alpha != 1.0) {
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    g_portalView.alpha = 1.0;
                    [CATransaction commit];
                }
            } else {
                double alpha = 0.0;
                if (engineProgress > 0.7) {
                    alpha = (1.0 - engineProgress) * (0.05 / 0.3);
                } else if (engineProgress > 0.6) {
                    alpha = 0.05 + (0.7 - engineProgress) * 1.0; 
                } else {
                    alpha = 0.15 + ((0.6 - engineProgress) / 0.6) * 0.85;
                }
                alpha = MAX(0.0, MIN(1.0, alpha));
                
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                g_portalView.alpha = alpha;
                [CATransaction commit];
            }
        }
    }
}

%new
- (void)zone_screenSleep {
    CADisplayLink *link = objc_getAssociatedObject(self, "ZoneTicker");
    if (link) link.paused = YES;
}

%new
- (void)zone_screenWake {
    CADisplayLink *link = objc_getAssociatedObject(self, "ZoneTicker");
    if (link) link.paused = NO;
}

- (void)viewWillLayoutSubviews {
    %orig;
    _UIPortalView *portalView = objc_getAssociatedObject(self, "CoverSheetZonePortal");
    if (!g_enabled) {
        if (portalView) portalView.hidden = YES;
        UIViewController *bgVC = safelyGetIvarAsViewController(self, "_backgroundContentViewController");
        if (bgVC && bgVC.view) {
            for (UIView *sub in bgVC.view.subviews) {
                sub.alpha = 1.0;
                sub.hidden = NO;
            }
        }
        return;
    }
    
    EnsureEngineViewIsMounted(); 
    
    UIViewController *bgVC = safelyGetIvarAsViewController(self, "_backgroundContentViewController");
    if (bgVC && bgVC.view) {
        bgVC.view.alpha = 1.0;
        bgVC.view.hidden = NO;
    }

    id wallpaperController = [%c(SBWallpaperController) sharedInstance];
    UIView *engineView = objc_getAssociatedObject(wallpaperController, "GlobalZoneEngine");
    
    if (engineView) {
        UIView *sourceForPortal = engineView;
        if (g_isVideoMode) {
            if (IsSingleVideoMode()) {
                if ([engineView respondsToSelector:@selector(homeVideoView)]) {
                    UIView *homeView = [engineView performSelector:@selector(homeVideoView)];
                    if (homeView) sourceForPortal = homeView;
                }
            } else {
                if ([engineView respondsToSelector:@selector(lockVideoView)]) {
                    UIView *lockView = [engineView performSelector:@selector(lockVideoView)];
                    if (lockView) sourceForPortal = lockView;
                    else sourceForPortal = nil;
                }
            }
        }

        if (!portalView) {
            portalView = [[NSClassFromString(@"_UIPortalView") alloc] initWithFrame:self.view.bounds];
            portalView.hidesSourceView = NO;
            portalView.matchesAlpha = NO; 
            portalView.alpha = g_isVideoMode ? 1.0 : 0.0; 
            BOOL freezeAODLayout = (g_isAODInactive && !g_isScreenOn);
            portalView.matchesPosition = freezeAODLayout ? NO : (IsSingleVideoMode() ? YES : (g_isVideoMode ? NO : YES));
            portalView.matchesTransform = YES;
            portalView.clipsToBounds = YES; 
            portalView.userInteractionEnabled = NO;
            objc_setAssociatedObject(self, "CoverSheetZonePortal", portalView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            g_portalView = portalView;
        }
        
        if (sourceForPortal) {
            portalView.hidden = NO;
            if (portalView.sourceView != sourceForPortal) {
                portalView.sourceView = sourceForPortal; 
            }
            BOOL freezeAODLayout = (g_isAODInactive && !g_isScreenOn);
            if (IsSingleVideoMode()) {
                if (!freezeAODLayout && portalView.matchesPosition != YES) portalView.matchesPosition = YES;
                if (!freezeAODLayout) portalView.alpha = 1.0;
            } else if (g_isVideoMode && portalView.matchesPosition != NO) {
                if (!freezeAODLayout) {
                    portalView.matchesPosition = NO;
                    portalView.alpha = 1.0;
                }
            } else if (!g_isVideoMode && !freezeAODLayout && portalView.matchesPosition != YES) {
                portalView.matchesPosition = YES;
            }
        } else {
            portalView.hidden = YES;
        }

        BOOL hideNativeBlurs = !g_isVideoMode || (!IsSingleVideoMode() && g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);

        if (bgVC && bgVC.view) {
            if (portalView.superview != bgVC.view) {
                [portalView removeFromSuperview];
                [bgVC.view addSubview:portalView];
            }
            portalView.frame = bgVC.view.bounds;
            bgVC.view.clipsToBounds = YES;
            
            for (UIView *sub in bgVC.view.subviews) {
                if (sub != portalView) {
                    if (hideNativeBlurs) {
                        sub.alpha = 0.0;
                        sub.hidden = YES;
                    } else {
                        sub.alpha = 1.0;
                        sub.hidden = NO;
                    }
                }
            }
        } else {
            if (portalView.superview != self.view) {
                [self.view insertSubview:portalView atIndex:0];
            } else {
                NSInteger index = [self.view.subviews indexOfObject:portalView];
                if (index != 0) {
                    [self.view sendSubviewToBack:portalView];
                }
            }
            portalView.frame = self.view.bounds;
        }
        
        UIView *dimmingView = safelyGetIvarAsView(self, "_dimmingView");
        if (dimmingView && hideNativeBlurs) { dimmingView.alpha = 0.0; dimmingView.hidden = YES; }
        
        UIView *tintingView = safelyGetIvarAsView(self, "_tintingView");
        if (tintingView && hideNativeBlurs) { tintingView.alpha = 0.0; tintingView.hidden = YES; }
    }
    
    UIView *floatingLayer = safelyGetIvarAsView(self, "_floatingLayerView");
    if (floatingLayer) { 
        floatingLayer.alpha = 0.0; 
        floatingLayer.hidden = YES; 
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (g_enabled && g_isScreenOn && !g_isAODInactive) {
        g_isUnlocked = NO;
        g_lastTickProgress = -1; 
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (g_enabled && g_isScreenOn && !g_isAODInactive) {
        g_isUnlocked = YES;
        g_lastTickProgress = -1; 
    }
}

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled) {
        g_isScreenOn = !mode;
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": state, @"animated": @YES}];
    }
}
%end

%hook SBBacklightController
- (void)setBacklightState:(long long)state source:(long long)source {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            g_lastTickProgress = -1; 
            
            if (g_isScreenOn) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineWake" object:nil];
            } else {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineSleep" object:nil];
            }
            
            NSString *zoneState = screenOn ? (g_isUnlocked ? @"Unlock" : @"Locked") : @"Sleep";
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": zoneState, @"animated": @YES}];
        }
    }
}
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            g_lastTickProgress = -1; 
            
            if (g_isScreenOn) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineWake" object:nil];
            } else {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineSleep" object:nil];
            }
            
            NSString *zoneState = screenOn ? (g_isUnlocked ? @"Unlock" : @"Locked") : @"Sleep";
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": zoneState, @"animated": @YES}];
        }
    }
}
%end

%end // 结束 iOS14_15


// =========================================================================
// ==================== 【全版本通用 Hook 区域】 ============================
// =========================================================================

%hook SBIconListView
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    // 判断：插件开启、双击锁屏开启，并且确实是双击事件
    if (g_enabled && g_doubleTapLock && [[touches anyObject] tapCount] == 2) {
        [(SpringBoard *)[%c(SpringBoard) sharedApplication] _simulateLockButtonPress];
    } else {
        %orig;
    }
}
%end

%hook SBFLegacyWallpaperWakeAnimator
- (void)updateWakeEffectsForWake:(BOOL)wake animated:(BOOL)animated completion:(id)completion {
    %orig;
    if (g_enabled) {
        NSString *state = wake ? (g_isUnlocked ? @"Unlock" : @"Locked") : @"Sleep";
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": state, @"animated": @(animated)}];
    }
}
%end

%hook SBWallpaperEffectView

// 新增辅助方法：排除来电与 Safari 误伤，精准定位系统封面/壁纸
%new
- (BOOL)zone_shouldHideEffect {
    UIView *view = self;
    BOOL shouldHide = NO;
    while (view) {
        NSString *className = NSStringFromClass([view class]);
        
        // 1. 绝对黑名单：增加 Reachability。这样降半屏时上半部分的系统高斯模糊也能被完美保留
        if ([className containsString:@"SceneView"] || 
            [className containsString:@"AppContainer"] || 
            [className containsString:@"Folder"] || 
            [className containsString:@"Dock"] ||
            [className containsString:@"Reachability"]) {
            return NO;
        }
        
        // 2. 核心白名单：不再包含 Reachability
        if ([className containsString:@"CoverSheet"] || 
            [className containsString:@"WallpaperWindow"] || 
            [className containsString:@"WallpaperViewController"] || 
            [className containsString:@"Switcher"]) {
            shouldHide = YES;
        }
        
        view = view.superview;
    }
    return shouldHide;
}

- (void)didMoveToSuperview {
    %orig;
    if (g_enabled && self.superview) {
        if ([self respondsToSelector:@selector(zone_shouldHideEffect)] && [self zone_shouldHideEffect]) {
            self.hidden = YES;
            self.alpha = 0.0;
        }
    }
}

- (void)layoutSubviews {
    %orig;
    if (g_enabled) {
        if ([self respondsToSelector:@selector(zone_shouldHideEffect)] && [self zone_shouldHideEffect]) {
            self.hidden = YES;
            self.alpha = 0.0;
        }
    }
}

- (void)setAlpha:(double)alpha {
    if (g_enabled) {
        if ([self respondsToSelector:@selector(zone_shouldHideEffect)] && [self zone_shouldHideEffect]) {
            %orig(0.0);
            return;
        }
    }
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    if (g_enabled) {
        if ([self respondsToSelector:@selector(zone_shouldHideEffect)] && [self zone_shouldHideEffect]) {
            %orig(YES);
            return;
        }
    }
    %orig;
}
%end

%hook CSCoverSheetViewController
- (void)_updateWallpaperFloatingLayerContainerView {
    %orig;
    if (g_enabled) {
        UIView *floatingLayer = safelyGetIvarAsView(self, "_floatingLayerView");
        if (floatingLayer) {
            floatingLayer.hidden = YES;
            floatingLayer.alpha = 0.0;
        }
    }
}

- (void)_updateFloatingLayerOrdering {
    %orig;
    if (g_enabled) {
        UIView *floatingLayer = safelyGetIvarAsView(self, "_floatingLayerView");
        if (floatingLayer) {
            floatingLayer.hidden = YES;
            floatingLayer.alpha = 0.0;
        }
    }
}

- (void)viewDidLayoutSubviews { %orig; if (g_enabled && (!g_isAODInactive || g_isScreenOn)) [self viewWillLayoutSubviews]; }

- (void)_updateBackgroundContentView { %orig; }
- (void)_updateWallpaperEffectView { %orig; }
- (void)_updateWallpaper { %orig; }
%end

%hook CSBackgroundContentView
- (void)layoutSubviews {
    %orig;
    UIView *presentationView = safelyGetIvarAsView(self, "presentationView"); 
    if (!presentationView && [self respondsToSelector:@selector(presentationView)]) {
        presentationView = [self performSelector:@selector(presentationView)];
    }
    if (presentationView && [presentationView isKindOfClass:[UIView class]]) {
        if (g_enabled && !g_isVideoMode) {
            presentationView.hidden = YES;
            presentationView.alpha = 0.0;
        } else if (g_enabled && g_isVideoMode) {
            BOOL hasLockVid = (!IsSingleVideoMode() && g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);
            presentationView.hidden = hasLockVid;
            presentationView.alpha = hasLockVid ? 0.0 : 1.0;
        } else {
            presentationView.hidden = NO;
            presentationView.alpha = 1.0;
        }
    }
}
%end

%hook SBIconLegibilityLabelView
- (void)updateIconLabelWithSettings:(id)settings imageParameters:(id)params {
    if (g_enabled && g_hideTextShadow && settings) {
        @try {
            [settings setValue:@(0.0) forKey:@"shadowAlpha"];
            [settings setValue:@(0.0) forKey:@"shadowRadius"];
            [settings setValue:[UIColor clearColor] forKey:@"shadowColor"];
        } @catch (NSException *e) {}
    }
    %orig(settings, params);
}
%end

%hook SBIconController
- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(zone_forceIconRefresh) name:@"ZoneForceIconRefresh" object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ZoneForceIconRefresh" object:nil];
    %orig;
}

%new
- (void)zone_forceIconRefresh {
    id iconManager = nil;
    if ([self respondsToSelector:@selector(iconManager)]) {
        iconManager = [self performSelector:@selector(iconManager)];
    }
    
    if (iconManager && [iconManager respondsToSelector:@selector(legibilitySettingsDidChange:)]) {
        Class wcClass = NSClassFromString(@"SBWallpaperController");
        if ([wcClass respondsToSelector:@selector(sharedInstance)]) {
            id wc = [wcClass sharedInstance];
            if ([wc respondsToSelector:@selector(legibilitySettingsForVariant:)]) {
                id settings = [wc performSelector:@selector(legibilitySettingsForVariant:) withObject:@(1)]; 
                if (settings) {
                    id dummySettings = [[NSClassFromString(@"_UIMutableLegibilitySettings") alloc] initWithStyle:1];
                    if (!dummySettings) dummySettings = [settings copy]; 
                    
                    [iconManager performSelector:@selector(legibilitySettingsDidChange:) withObject:dummySettings];
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [iconManager performSelector:@selector(legibilitySettingsDidChange:) withObject:settings];
                    });
                    return;
                }
            }
        }
    }
    
    if ([self respondsToSelector:@selector(_legibilitySettingsChanged)]) {
        [self performSelector:@selector(_legibilitySettingsChanged)];
    } else if ([self respondsToSelector:@selector(updateLegibility)]) {
        [self performSelector:@selector(updateLegibility)];
    }
}
%end

%ctor {
    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    
    if (![processName isEqualToString:@"SpringBoard"] && ![bundleId isEqualToString:@"com.apple.springboard"]) {
        return; 
    }

    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    
    if (NSClassFromString(@"PBUIWallpaperViewController") != Nil) {
        %init(iOS16Plus);
    } else {
        %init(iOS14_15);
    }
    
    %init;
}
