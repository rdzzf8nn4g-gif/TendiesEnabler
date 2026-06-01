#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h> 

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
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state;
- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)state newState:(void *)state oldEffectView:(id *)view newEffectView:(id *)view;
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
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setDismissed:(BOOL)dismissed;
@end

@interface SBWallpaperEffectView : UIView
@property (nonatomic) long long wallpaperStyle;
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
                float speed = animated ? 1.0f : 0.0f;
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
static NSString *g_zonePath = nil;
static BOOL g_isUnlocked = NO; 
static BOOL g_isScreenOn = YES;

static double g_resolutionFactor = 1.0;
static double g_lastTickProgress = -1; 
static BOOL old_hideTextShadow = NO; 

static BOOL g_isVideoMode = NO;
static NSString *g_lockVideoPath = nil;
static NSString *g_homeVideoPath = nil;

static __weak _UIPortalView *g_portalView = nil;

static void EnsureEngineViewIsMounted(); 

// 全局内联函数：精准判定是否处于【双端同素材完美同步模式】
static inline BOOL IsSingleVideoMode() {
    return (g_isVideoMode && g_lockVideoPath && g_homeVideoPath && [g_lockVideoPath isEqualToString:g_homeVideoPath]);
}

static void reloadPrefs() {
    CFStringRef appID = CFSTR("com.iosdump.zoneprefs");
    CFPreferencesAppSynchronize(appID);
    Boolean valid;
    
    g_enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &valid) ? valid : NO;
    g_enhanced_engine = CFPreferencesGetAppBooleanValue(CFSTR("EnhancedEngine"), appID, &valid) ? valid : NO;
    g_hideTextShadow = CFPreferencesGetAppBooleanValue(CFSTR("HideTextShadow"), appID, &valid) ? valid : NO;
    g_lowPowerPause = CFPreferencesGetAppBooleanValue(CFSTR("LowPowerPause"), appID, &valid) ? valid : NO;
    g_isVideoMode = CFPreferencesGetAppBooleanValue(CFSTR("VideoModeEnabled"), appID, &valid) ? valid : NO;
    
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
    } else {
        g_zonePath = nil; 
        g_resolutionFactor = 1.0;
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
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineWake" object:nil]; // 强制校验低电量
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
@property (nonatomic, assign) BOOL isManuallyPaused; // 用于区别系统强杀和主动暂停
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
            // 关闭精准时序，全面拥抱硬件解码提速
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
            AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
            
            // 【4K内存防护】：限制预读缓冲秒数，即使 2GB 的原画也能控制在最低内存
            if ([item respondsToSelector:@selector(setPreferredForwardBufferDuration:)]) {
                item.preferredForwardBufferDuration = 1.0;
            }
            
            self.player = [AVQueuePlayer queuePlayerWithItems:@[item]];
            self.player.muted = YES;
            self.player.allowsExternalPlayback = NO; // 切断投屏和外界干扰
            self.player.automaticallyWaitsToMinimizeStalling = NO; // 拒绝网络级防卡顿策略导致的假死
            self.player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
            
            if (@available(iOS 12.0, *)) {
                self.player.preventsDisplaySleepDuringVideoPlayback = NO;
            }
            
            self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
            
            self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
            self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            self.playerLayer.frame = self.bounds;
            [self.layer addSublayer:self.playerLayer];
            
            // 【系统级防死锁监听】
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playVideo) name:UIApplicationDidBecomeActiveNotification object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playVideo) name:AVPlayerItemPlaybackStalledNotification object:nil];
            
            // KVO 底层速率监控（幽灵唤醒）
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
    // 渲染管线刷新时激进校验播放状态
    if (g_isScreenOn && g_enabled && g_isVideoMode) {
        [self playVideo];
    }
}

// 核心 KVO 回调：只要不是我主动暂停的，谁敢停我视频我就秒开拉起
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"rate"]) {
        if (g_enabled && g_isVideoMode && g_isScreenOn && !self.isManuallyPaused) {
            if (self.player.rate == 0.0) {
                [self.player play];
            }
        }
    }
}

- (void)playVideo {
    if (!self.player) return;
    
    // 【电量哨兵检测】
    if (g_lowPowerPause && [[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        [self pauseVideo];
        return;
    }
    
    self.isManuallyPaused = NO;
    if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying || self.player.rate == 0.0) {
        [self.player play];
    }
}

- (void)pauseVideo {
    self.isManuallyPaused = YES;
    if (self.player && self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
        [self.player pause];
    }
}

- (void)cleanUpEngineSafely {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    @try {
        [self.player removeObserver:self forKeyPath:@"rate"];
    } @catch (NSException *e) {}
    
    [self pauseVideo];
    if (self.looper) {
        [self.looper disableLooping];
        self.looper = nil;
    }
    if (self.player) {
        [self.player removeAllItems];
        self.player = nil;
    }
    if (self.playerLayer) {
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
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
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onProgress:) name:@"ZoneEngineProgress" object:nil];
        
        // 监听系统低电量状态突变
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
            [self onWakeUp]; // 复用校验逻辑秒关/秒开
        }
    });
}

- (void)onWakeUp {
    if (!g_enabled || !g_isVideoMode) return;
    
    // 【电量哨兵】低电量一键熔断
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

- (void)onProgress:(NSNotification *)note {
    // 物理层面上，Lock就是Lock，Home就是Home。滑动交由系统处理。
    if (!g_enabled || !g_isVideoMode) return;
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
    dispatch_async(dispatch_get_main_queue(), ^{
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
            // 【同素材极限优化：显存直降 50%】
            // 永远只实例化唯一的 homeVideoView 作为物理底板，锁屏那边靠 _UIPortalView 以纯显卡镜像拉出！
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
                    // 双视频模式：锁屏在这里隐身，只交给 CoverSheet 传送门显形
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
    });
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
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"CALayer"]) {
        NSString *layerId = attributeDict[@"id"];
        NSString *layerName = attributeDict[@"name"];
        if (layerId && layerName) self.idToNameMap[layerId] = layerName;
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
    if ([elementName isEqualToString:@"LKState"]) self.currentParsingState = nil;
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
- (void)reloadWallpaperViews;
- (void)clearCurrentViewsSafely;
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
        
        self.bgLayerMap = [NSMutableDictionary dictionary];
        self.floatLayerMap = [NSMutableDictionary dictionary];
        self.fgLayerMap = [NSMutableDictionary dictionary];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"ZoneEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"ZoneEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"ZoneEngineSleep" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onProgress:) name:@"ZoneEngineProgress" object:nil];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    
    if (self.bgView) self.bgView.frame = bounds;
    if (self.floatingView) self.floatingView.frame = bounds;
    if (self.fgView) self.fgView.frame = bounds;

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
    [CATransaction begin]; [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO]; [CATransaction commit]; [CATransaction flush];
}

- (void)onSleep {
    if (!g_enabled || !self.bgView) return;
    self.isUnlocking = NO;
    [self transitionToState:@"Sleep" animated:NO];
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
                @try { [layer setValue:@(currentVal) forKeyPath:keyPath]; } @catch (NSException *e) {}
            }
        }
    }
    [CATransaction commit];
}

- (void)onProgress:(NSNotification *)note {
    if (!g_enabled || !self.bgView) return;
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
    if ([self.currentState isEqualToString:stateName]) return;
    self.currentState = [stateName copy];
    
    if ([stateName isEqualToString:@"Unlock"]) {
        [self ensureAllLayerMaps]; [self applyProgress:1.0 parser:self.bgParser layerMap:self.bgLayerMap]; [self applyProgress:1.0 parser:self.floatParser layerMap:self.floatLayerMap]; [self applyProgress:1.0 parser:self.fgParser layerMap:self.fgLayerMap];
    } else if ([stateName isEqualToString:@"Locked"]) {
        [self ensureAllLayerMaps]; [self applyProgress:0.0 parser:self.bgParser layerMap:self.bgLayerMap]; [self applyProgress:0.0 parser:self.floatParser layerMap:self.floatLayerMap]; [self applyProgress:0.0 parser:self.fgParser layerMap:self.fgLayerMap];
    }
    
    if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
        [self.bgView setState:stateName animated:animated]; [self.floatingView setState:stateName animated:animated]; [self.fgView setState:stateName animated:animated];
    } else {
        [self.bgView setState:stateName]; [self.floatingView setState:stateName]; [self.fgView setState:stateName];
    }
}

- (void)clearCurrentViewsSafely {
    [self.bgView removeFromSuperview]; self.bgView = nil;
    [self.floatingView removeFromSuperview]; self.floatingView = nil;
    [self.fgView removeFromSuperview]; self.fgView = nil;
    [self.bgLayerMap removeAllObjects]; [self.floatLayerMap removeAllObjects]; [self.fgLayerMap removeAllObjects];
    self.bgParser = nil; self.floatParser = nil; self.fgParser = nil;
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
        
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:g_zonePath];
        NSString *subPath;
        while ((subPath = [dirEnum nextObject])) {
            if ([subPath containsString:@"__MACOSX"]) { [dirEnum skipDescendants]; continue; }
            NSString *fullPath = [g_zonePath stringByAppendingPathComponent:subPath];
            NSString *fileName = [subPath lastPathComponent];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir) {
                if ([[[fileName pathExtension] lowercaseString] isEqualToString:@"ca"]) {
                    if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) foundBg = fullPath;
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) foundFloat = fullPath;
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) foundFg = fullPath;
                    [dirEnum skipDescendants];
                }
            }
        }
        
        if (currentGen != self.reloadGeneration) return; 
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (currentGen != self.reloadGeneration) return; 
            [self clearCurrentViewsSafely]; 
            
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
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BOOL realUnlocked = g_isUnlocked;
                Class lsManager = NSClassFromString(@"SBLockScreenManager");
                if ([lsManager respondsToSelector:@selector(sharedInstance)]) {
                    id manager = [lsManager sharedInstance];
                    if ([manager respondsToSelector:@selector(isUILocked)]) {
                        realUnlocked = !((BOOL)[manager performSelector:@selector(isUILocked)]);
                    }
                }
                
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                
                double currentProgress = realUnlocked ? 1.0 : 0.0;
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(currentProgress)}];
                
                [self transitionToState:realUnlocked ? @"Unlock" : @"Locked" animated:NO];
                [CATransaction commit];
            });
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
@property (nonatomic, strong) UIColor *rootBackgroundColor;
@property (nonatomic, assign) BOOL isGeometryFlipped;
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
    } else if (comps.count == 1 || comps.count == 2) {
        // 核心修复：适配单灰度通道的色值定义，例如 <value type="CGColor" value="0"/>
        CGFloat w = [comps[0] doubleValue];
        CGFloat a = opacityStr ? [opacityStr doubleValue] : (comps.count >= 2 ? [comps[1] doubleValue] : 1.0);
        return [UIColor colorWithWhite:w alpha:a];
    }
    return nil;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"CALayer"]) {
        if (!self.rootParsed) {
            self.rootParsed = YES;
            if (attributeDict[@"backgroundColor"]) {
                self.rootBackgroundColor = [self parseColorString:attributeDict[@"backgroundColor"] opacity:attributeDict[@"opacity"]];
            }
            if ([attributeDict[@"geometryFlipped"] intValue] == 1) self.isGeometryFlipped = YES;
        }
        NSString *layerId = attributeDict[@"id"];
        NSString *layerName = attributeDict[@"name"];
        if (layerId && layerName) self.idToNameMap[layerId] = layerName;
    } else if ([elementName isEqualToString:@"backgroundColor"] && !self.rootBackgroundColor) {
        if (attributeDict[@"value"]) {
            self.rootBackgroundColor = [self parseColorString:attributeDict[@"value"] opacity:attributeDict[@"opacity"]];
        }
    } else if ([elementName isEqualToString:@"LKState"]) {
        self.currentParsingState = attributeDict[@"name"];
        if (self.currentParsingState) [self.availableStates addObject:self.currentParsingState];
    } else if ([elementName isEqualToString:@"LKStateSetValue"]) {
        self.currentParsingTargetId = attributeDict[@"targetId"];
        NSString *kp = attributeDict[@"keyPath"];
        // 核心升级：静默转换系统不支持的非标准 KVC 映射，如 transform.scale.xy
        if ([kp isEqualToString:@"transform.scale.xy"]) {
            kp = @"transform.scale";
        }
        self.currentParsingKeyPath = kp;
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
                } else if ([typeStr isEqualToString:@"CGColor"]) {
                    // 核心升级：深入支持 CGColor 解析，为后续色彩过渡平滑插值做准备
                    UIColor *color = [self parseColorString:valStr opacity:nil];
                    if (color) finalValue = color;
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
    if ([elementName isEqualToString:@"LKState"]) self.currentParsingState = nil;
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
- (void)reloadWallpaperViews;
- (void)clearCurrentViewsSafely;
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
        
        self.bgLayerMap = [NSMutableDictionary dictionary];
        self.floatLayerMap = [NSMutableDictionary dictionary];
        self.fgLayerMap = [NSMutableDictionary dictionary];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"ZoneEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"ZoneEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"ZoneEngineSleep" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onProgress:) name:@"ZoneEngineProgress" object:nil];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        if (self.currentState && ![self.currentState isEqualToString:@"Init"]) {
            NSString *savedState = [self.currentState copy];
            self.currentState = nil; 
            [self transitionToState:savedState animated:YES]; 
        }
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
    
    BSUICAPackageView *views[] = {self.bgView, self.floatingView, self.fgView};
    ZoneCAMLParserEnhanced *parsers[] = {self.bgParser, self.floatParser, self.fgParser};
    
    for (int i = 0; i < 3; i++) {
        BSUICAPackageView *v = views[i];
        ZoneCAMLParserEnhanced *p = parsers[i];
        if (!v) continue;
        
        v.frame = bounds;
        if (p && p.rootBackgroundColor) {
            v.backgroundColor = p.rootBackgroundColor;
        } else {
            v.backgroundColor = [UIColor clearColor];
        }
        
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
    [CATransaction begin]; [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO]; [CATransaction commit]; [CATransaction flush];
}

- (void)onSleep {
    if (!g_enabled || !self.bgView) return;
    self.isUnlocking = NO;
    [self transitionToState:@"Sleep" animated:NO];
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
                @try {
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
                    else if ([lockVal isKindOfClass:[UIColor class]] && [unlockVal isKindOfClass:[UIColor class]]) {
                        // 核心升级：精确支持动态色彩插值（支持透明度变换）
                        UIColor *lockColor = (UIColor *)lockVal;
                        UIColor *unlockColor = (UIColor *)unlockVal;
                        CGFloat lr=0, lg=0, lb=0, la=0, ur=0, ug=0, ub=0, ua=0;
                        [lockColor getRed:&lr green:&lg blue:&lb alpha:&la];
                        [unlockColor getRed:&ur green:&ug blue:&ub alpha:&ua];
                        CGFloat r = lr + (ur - lr) * progress;
                        CGFloat g = lg + (ug - lg) * progress;
                        CGFloat b = lb + (ub - lb) * progress;
                        CGFloat a = la + (ua - la) * progress;
                        UIColor *currentCGColor = [UIColor colorWithRed:r green:g blue:b alpha:a];
                        [layer setValue:(id)currentCGColor.CGColor forKeyPath:keyPath];
                    }
                } @catch (NSException *e) {
                    // 核心防御：静默拦截 KVC 赋值失败
                    // 当遇到未初始化的滤镜或者被动态移出的图层时，防止异常抛出中断整个状态树的渲染逻辑
                }
            }
        }
    }
    [CATransaction commit];
}

- (void)onProgress:(NSNotification *)note {
    if (!g_enabled || !self.bgView) return;
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
    if ([self.currentState isEqualToString:stateName]) return;
    self.currentState = [stateName copy];
    
    if ([stateName isEqualToString:@"Unlock"]) {
        [self ensureAllLayerMaps]; 
        [self applyProgress:1.0 parser:self.bgParser layerMap:self.bgLayerMap]; 
        [self applyProgress:1.0 parser:self.floatParser layerMap:self.floatLayerMap]; 
        [self applyProgress:1.0 parser:self.fgParser layerMap:self.fgLayerMap];
    } else if ([stateName isEqualToString:@"Locked"]) {
        [self ensureAllLayerMaps]; 
        [self applyProgress:0.0 parser:self.bgParser layerMap:self.bgLayerMap]; 
        [self applyProgress:0.0 parser:self.floatParser layerMap:self.floatLayerMap]; 
        [self applyProgress:0.0 parser:self.fgParser layerMap:self.fgLayerMap];
    }
    
    BOOL isDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    
    NSString *realBgState = [self.bgParser resolveRealStateNameFor:stateName isDark:isDark] ?: stateName;
    NSString *realFloatState = [self.floatParser resolveRealStateNameFor:stateName isDark:isDark] ?: stateName;
    NSString *realFgState = [self.fgParser resolveRealStateNameFor:stateName isDark:isDark] ?: stateName;
    
    if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
        [self.bgView setState:realBgState animated:animated]; 
        [self.floatingView setState:realFloatState animated:animated]; 
        [self.fgView setState:realFgState animated:animated];
    } else {
        [self.bgView setState:realBgState]; 
        [self.floatingView setState:realFloatState]; 
        [self.fgView setState:realFgState];
    }
}

- (void)clearCurrentViewsSafely {
    [self.bgView removeFromSuperview]; self.bgView = nil;
    [self.floatingView removeFromSuperview]; self.floatingView = nil;
    [self.fgView removeFromSuperview]; self.fgView = nil;
    [self.bgLayerMap removeAllObjects]; [self.floatLayerMap removeAllObjects]; [self.fgLayerMap removeAllObjects];
    self.bgParser = nil; self.floatParser = nil; self.fgParser = nil;
    self.logicalScreenSize = CGSizeZero;
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
        }
        
        if (currentGen != self.reloadGeneration) return; 
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (currentGen != self.reloadGeneration) return; 
            [self clearCurrentViewsSafely]; 
            self.logicalScreenSize = targetSize; 
            
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
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                
                BOOL realUnlocked = g_isUnlocked;
                Class lsManager = NSClassFromString(@"SBLockScreenManager");
                if ([lsManager respondsToSelector:@selector(sharedInstance)]) {
                    id manager = [lsManager sharedInstance];
                    if ([manager respondsToSelector:@selector(isUILocked)]) {
                        realUnlocked = !((BOOL)[manager performSelector:@selector(isUILocked)]);
                    }
                }
                
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                
                double currentProgress = realUnlocked ? 1.0 : 0.0;
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(currentProgress)}];
                
                [self transitionToState:realUnlocked ? @"Unlock" : @"Locked" animated:NO];
                [CATransaction commit];
            });
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

    // 【极速释放】：关闭开关直接摧毁，毫无残留
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
    
    // 【完美隔离：视频模式按需屏蔽原生，不设就露出系统自带！】
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
    // 【保留原生地毛玻璃模糊】单素材同源视频时必须放行
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
    
    if (engineView) {
        UIView *sourceForPortal = engineView;
        if (g_isVideoMode) {
            // 【同素材极简通道】：只拿 Home 进行渲染投射
            if (IsSingleVideoMode()) {
                if ([engineView respondsToSelector:@selector(homeVideoView)]) {
                    UIView *homeView = [engineView performSelector:@selector(homeVideoView)];
                    if (homeView) sourceForPortal = homeView;
                }
            } else {
                if ([engineView respondsToSelector:@selector(lockVideoView)]) {
                    UIView *lockView = [engineView performSelector:@selector(lockVideoView)];
                    if (lockView) sourceForPortal = lockView;
                    else sourceForPortal = nil; // 没设锁屏不搞传送门
                }
            }
        }
        
        if (!portalView) {
            portalView = [[NSClassFromString(@"_UIPortalView") alloc] initWithFrame:self.view.bounds];
            portalView.hidesSourceView = NO;
            portalView.matchesAlpha = NO; 
            portalView.alpha = g_isVideoMode ? 1.0 : 0.0; 
            // 同素材时必须绝对贴合底层坐标 (YES)
            portalView.matchesPosition = IsSingleVideoMode() ? YES : (g_isVideoMode ? NO : YES);
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

        // 【核心】：判断是否需要强制隐藏原生背景及其子视图
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
                        // 解锁原生地毛玻璃控制权限
                        sub.alpha = 1.0;
                        sub.hidden = NO;
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
        
        dispatch_async(dispatch_get_main_queue(), ^{
            id wallpaperController = [%c(SBWallpaperController) sharedInstance];
            if ([wallpaperController respondsToSelector:@selector(updateWallpaperAnimationWithProgress:)]) {
                [wallpaperController updateWallpaperAnimationWithProgress:0.0];
            }
        });
    }
}

- (void)_cleanupPosterSwitcherPresentationForCompleted:(BOOL)completed withActivatingTouches:(id)touches {
    %orig;
    if (g_enabled && g_portalView) {
        g_portalView.hidden = NO;
        [self viewWillLayoutSubviews];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            id wallpaperController = [%c(SBWallpaperController) sharedInstance];
            if ([wallpaperController respondsToSelector:@selector(updateWallpaperAnimationWithProgress:)]) {
                [wallpaperController updateWallpaperAnimationWithProgress:0.0];
            }
        });
    }
}

- (void)setDismissed:(BOOL)dismissed {
    %orig;
    g_isUnlocked = dismissed;
    if (g_enabled && g_isScreenOn) {
        NSString *state = dismissed ? @"Unlock" : @"Locked";
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}
%end

%hook SBWallpaperController
- (void)_ingestPrimaryWallpaperLayersSnapshotIOSurface:(id)arg1 floatingWallpaperLayerSnapshotIOSurface:(id)arg2 snapshotScale:(double)arg3 traitCollection:(id)arg4 withCompletion:(id /* block */)arg5 {
    if (g_enabled) {
        if (arg5) { void (^completionBlock)(void) = arg5; completionBlock(); }
        return; 
    }
    %orig;
}

- (void)updatePosterSwitcherSnapshots {
    if (g_enabled) return;
    %orig;
}

- (void)updateWallpaperAnimationWithProgress:(double)progress {
    %orig;
    if (!g_enabled) return; 
    EnsureEngineViewIsMounted();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
        
        if (g_portalView) {
            // 【物理斩断】：视频模式完全不吃透明度，恒为 1.0，完全依靠原生拖拽动画遮盖与系统模糊
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
    });
}
%end
%end // 结束 iOS16Plus


// =========================================================================
// ==================== 【iOS 14-15 专属 Hook 区域】 ========================
// =========================================================================
%group iOS14_15

%hook SBFWallpaperView
- (void)layoutSubviews {
    %orig;
    if (!g_enabled) {
        self.hidden = NO;
        self.alpha = 1.0;
        return;
    }
    if (g_isVideoMode) {
        // 放行同素材模式时的底板显示
        if (IsSingleVideoMode()) {
            self.hidden = NO;
            self.alpha = 1.0;
            return;
        }
        long long variant = 0;
        if ([self respondsToSelector:@selector(variant)]) variant = (long long)[self performSelector:@selector(variant)];
        BOOL hide = NO;
        if (variant == 0) hide = (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath]);
        else if (variant == 1) hide = (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath]);
        self.hidden = hide;
        self.alpha = hide ? 0.0 : 1.0;
    } else {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}
- (void)setAlpha:(double)alpha {
    if (g_enabled) {
        if (!g_isVideoMode) { %orig(0.0); return; }
        if (IsSingleVideoMode()) { %orig(1.0); return; }
        long long variant = 0;
        if ([self respondsToSelector:@selector(variant)]) variant = (long long)[self performSelector:@selector(variant)];
        if (variant == 0 && (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath])) { %orig(0.0); return; }
        if (variant == 1 && (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath])) { %orig(0.0); return; }
    }
    %orig;
}
- (void)setHidden:(BOOL)hidden {
    if (g_enabled) {
        if (!g_isVideoMode) { %orig(YES); return; }
        if (IsSingleVideoMode()) { %orig(NO); return; }
        long long variant = 0;
        if ([self respondsToSelector:@selector(variant)]) variant = (long long)[self performSelector:@selector(variant)];
        if (variant == 0 && (g_lockVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_lockVideoPath])) { %orig(YES); return; }
        if (variant == 1 && (g_homeVideoPath && [[NSFileManager defaultManager] fileExistsAtPath:g_homeVideoPath])) { %orig(YES); return; }
    }
    %orig;
}
%end

@interface CSCoverSheetViewController (Zone)
- (void)zone_tickProgress;
- (void)zone_screenSleep;
- (void)zone_screenWake;
@end

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
            portalView.matchesPosition = IsSingleVideoMode() ? YES : (g_isVideoMode ? NO : YES);
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
    if (g_enabled) {
        g_isUnlocked = NO;
        g_lastTickProgress = -1; 
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": @"Locked"}];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(0.0)}];
        });
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (g_enabled) {
        g_isUnlocked = YES;
        g_lastTickProgress = -1; 
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": @"Unlock"}];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(1.0)}];
        });
    }
}
%end

%hook SBLockScreenManager
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    g_isUnlocked = NO;
    g_lastTickProgress = -1; 
    if (g_enabled && g_isScreenOn) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": @"Locked"}];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(0.0)}];
        });
    }
}
- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    g_isUnlocked = YES;
    g_lastTickProgress = -1; 
    if (g_enabled && g_isScreenOn) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": @"Unlock"}];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(1.0)}];
        });
    }
}
%end

%end // 结束 iOS14_15


// =========================================================================
// ==================== 【全版本通用 Hook 区域】 ============================
// =========================================================================

%hook SBWallpaperEffectView
- (void)didMoveToSuperview {
    %orig;
    if (g_enabled && !g_isVideoMode && self.superview) {
        UIView *view = self;
        BOOL isCoverSheetRelated = NO;
        while (view) {
            NSString *name = NSStringFromClass([view class]);
            if ([name containsString:@"Wallpaper"] || 
                [name containsString:@"CoverSheet"] || 
                [name containsString:@"CS"]) {
                isCoverSheetRelated = YES;
                break;
            }
            view = view.superview;
        }
        if (isCoverSheetRelated) {
            self.hidden = YES;
            self.alpha = 0.0;
        }
    }
}

- (void)layoutSubviews {
    %orig;
    if (g_enabled && !g_isVideoMode) {
        NSString *superviewName = NSStringFromClass([self.superview class]);
        if ([superviewName containsString:@"Wallpaper"] || 
            [superviewName containsString:@"CoverSheet"] ||
            [superviewName containsString:@"CS"]) {
            self.hidden = YES;
            self.alpha = 0.0;
        }
    }
}
- (void)setAlpha:(double)alpha {
    if (g_enabled && !g_isVideoMode) {
        NSString *superviewName = NSStringFromClass([self.superview class]);
        if ([superviewName containsString:@"Wallpaper"] || 
            [superviewName containsString:@"CoverSheet"] ||
            [superviewName containsString:@"CS"]) {
            %orig(0.0);
            return;
        }
    }
    %orig;
}
- (void)setHidden:(BOOL)hidden {
    if (g_enabled && !g_isVideoMode) {
        NSString *superviewName = NSStringFromClass([self.superview class]);
        if ([superviewName containsString:@"Wallpaper"] || 
            [superviewName containsString:@"CoverSheet"] ||
            [superviewName containsString:@"CS"]) {
            %orig(YES);
            return;
        }
    }
    %orig;
}
%end

%hook CSCoverSheetViewController
- (void)_scrollPanGestureBegan:(id)arg1 { %orig; }
- (void)_scrollPanGestureChanged:(id)arg1 { %orig; }
- (void)_scrollPanGestureEnded:(id)arg1 { %orig; }

- (void)_updateWallpaperFloatingLayerContainerView {
    %orig;
    if (g_enabled && !g_isVideoMode) {
        UIView *floatingLayer = safelyGetIvarAsView(self, "_floatingLayerView");
        if (floatingLayer) {
            floatingLayer.hidden = YES;
            floatingLayer.alpha = 0.0;
        }
    }
}

- (void)_updateFloatingLayerOrdering {
    %orig;
    if (g_enabled && !g_isVideoMode) {
        UIView *floatingLayer = safelyGetIvarAsView(self, "_floatingLayerView");
        if (floatingLayer) {
            floatingLayer.hidden = YES;
            floatingLayer.alpha = 0.0;
        }
    }
}

- (void)viewDidLayoutSubviews { %orig; if (g_enabled) [self viewWillLayoutSubviews]; }
- (void)_updateBackgroundContentView { %orig; if (g_enabled) EnsureEngineViewIsMounted(); }
- (void)_updateWallpaperEffectView { %orig; if (g_enabled) EnsureEngineViewIsMounted(); }
- (void)_updateWallpaper { %orig; if (g_enabled) EnsureEngineViewIsMounted(); }

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled && g_isScreenOn) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}
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

%hook SBBacklightController
- (void)setBacklightState:(long long)state source:(long long)source {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            g_lastTickProgress = -1; 
            if (g_isScreenOn) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineWake" object:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineSleep" object:nil];
                });
            }
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
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineWake" object:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineSleep" object:nil];
                });
            }
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
    // 【核心修复】：进程隔离保护
    // 获取当前运行的进程名称
    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    
    // 如果当前进程不是 SpringBoard，直接退出，不执行任何 Hook！
    // 这样就能完美屏蔽 Safari (com.apple.mobilesafari) 和 电话 (com.apple.InCallService) 等应用
    if (![processName isEqualToString:@"SpringBoard"] && ![bundleId isEqualToString:@"com.apple.springboard"]) {
        return; 
    }

    // 只有在 SpringBoard 进程中才会执行以下的加载和 Hook 逻辑
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    
    if (NSClassFromString(@"PBUIWallpaperViewController") != Nil) {
        %init(iOS16Plus);
    } else {
        %init(iOS14_15);
    }
    
    %init;
}
