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
// 私有类与结构体声明
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
- (void)_ingestPrimaryWallpaperLayersSnapshotIOSurface:(id)arg1 floatingWallpaperLayerSnapshotIOSurface:(id)arg2 snapshotScale:(double)arg3 traitCollection:(id)arg4 withCompletion:(id /* block */)arg5;
- (void)updatePosterSwitcherSnapshots;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
@property (readonly, nonatomic) long long backlightState;
- (void)setBacklightState:(long long)state source:(long long)source;
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion;
@end

@interface SBWallpaperEffectView : UIView
@property (nonatomic) long long wallpaperStyle;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode;
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source;
- (void)setDismissed:(BOOL)dismissed;
- (void)_setDismissed:(BOOL)dismissed;
- (void)setCoverSheetIsVisible:(BOOL)visible;
- (void)setPartiallyOnScreen:(BOOL)screen;
- (void)setHidesDimmingLayer:(BOOL)layer;
- (void)_setHasContentAboveCoverSheet:(BOOL)sheet;
- (void)_setHasContentAboveCoverSheet:(BOOL)sheet isSignificantUserInteraction:(BOOL)interaction;
- (void)updateInterstitialPresentationWithProgress:(double)progress;
- (void)scrollPanGestureChanged:(id)changed;
- (void)scrollPanGestureDidUpdate:(id)update;
- (void)_scrollPanGestureBegan:(id)began;
- (void)_scrollPanGestureChanged:(id)changed;
- (void)_scrollPanGestureEnded:(id)ended;
- (void)_updateBackground;
- (void)_updateBackgroundContentView;
- (void)_updateWallpaperEffectView;
- (void)_updateWallpaper;
- (void)_updateWallpaperFloatingLayerContainerView;
- (void)_updateForegroundView;
- (void)_updateContent;
- (void)_updateDimmingLayer;
- (void)_updateFullBleedContent;
- (void)_updateComplicationSidebar;
- (void)_updateAppearanceForTransitionToOrientation:(long long)orientation;
- (void)updateAppearanceForController:(id)controller;
- (void)updateAppearanceForController:(id)controller withAnimationSettings:(id)settings completion:(id /* block */)completion;
- (void)updateBehaviorForController:(id)controller;
- (void)updateFloatingLayerOrdering;
- (void)updatePosterSwitcherPresentationWithProgress:(double)progress;
- (void)requestIdleTimerResetForPoster;
- (void)startObservingAmbientPresentationForController:(id)controller;
- (void)ambientPresentationController:(id)controller didUpdatePresented:(BOOL)presented;
- (void)ambientPresentationControllerCancelledPossiblePresentation:(id)presentation;
- (void)ambientPresentationControllerWillPossiblyPresent:(id)present;
- (void)overlayController:(id)controller didChangePresentationProgress:(double)progress newPresentationProgress:(double)newProgress fromLeading:(_Bool)leading;
- (void)viewDidMoveToWindow:(id)window shouldAppearOrDisappear:(BOOL)disappear;
- (void)viewWillLayoutSubviews;
- (void)viewDidLayoutSubviews;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (void)viewDidDisappear:(BOOL)animated;
- (void)viewDidLoad;
- (void)loadView;
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id)coordinator;
@end

// ==========================================
// 全局变量与配置
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
static double g_lockProgress = 0.0;

static void reloadPrefs(void) {
    CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
    CFPreferencesAppSynchronize(appID);

    Boolean valid = false;
    g_enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &valid) ? valid : NO;

    CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("TendiesPath"), appID);
    if (pathRef && CFGetTypeID(pathRef) == CFStringGetTypeID()) {
        g_tendiesPath = (__bridge_transfer NSString *)pathRef;
    } else {
        if (pathRef) CFRelease(pathRef);
        g_tendiesPath = [GetTendiesStorageDir() stringByAppendingPathComponent:@"ActiveTendies"];
    }
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

// ==========================================
// 前向声明
// ==========================================
@class TendiesRenderEngineView;
static void EnsureEngineViewIsMounted(void);

// ==========================================
// 稳定性保护
// ==========================================
static BOOL g_isHidingNativeChrome = NO;
static BOOL g_isMountingEngine = NO;

// ==========================================
// 工具函数
// ==========================================
static void TendiesHideLayerTree(CALayer *layer) {
    if (!layer) return;
    layer.hidden = YES;
    layer.opacity = 0.0;
    for (CALayer *sub in layer.sublayers) {
        TendiesHideLayerTree(sub);
    }
}

static void TendiesHideViewTree(UIView *view) {
    if (!view) return;
    view.hidden = YES;
    view.alpha = 0.0;
    view.layer.opacity = 0.0;
    TendiesHideLayerTree(view.layer);
    for (UIView *sub in view.subviews) {
        TendiesHideViewTree(sub);
    }
}

static id TendiesSafeValueForKey(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static CALayer *TendiesFindLayerByName(CALayer *layer, NSString *name) {
    if (!layer || !name.length) return nil;
    if ([layer.name isEqualToString:name]) return layer;
    for (CALayer *sub in layer.sublayers) {
        CALayer *found = TendiesFindLayerByName(sub, name);
        if (found) return found;
    }
    return nil;
}

static void TendiesHideCoverSheetChrome(CSCoverSheetViewController *vc) {
    if (!g_enabled || !vc) return;
    if (g_isHidingNativeChrome) return;

    g_isHidingNativeChrome = YES;
    @try {
        @try {
            id bgVC = TendiesSafeValueForKey(vc, @"_backgroundContentViewController");
            if (bgVC && [bgVC respondsToSelector:@selector(view)]) {
                UIView *view = [bgVC valueForKey:@"view"];
                TendiesHideViewTree(view);
            }
        } @catch (__unused NSException *e) {}

        @try {
            UIView *floatingLayer = TendiesSafeValueForKey(vc, @"_floatingLayerView");
            TendiesHideViewTree(floatingLayer);
        } @catch (__unused NSException *e) {}

        @try {
            UIView *dimmingView = TendiesSafeValueForKey(vc, @"_dimmingView");
            TendiesHideViewTree(dimmingView);
        } @catch (__unused NSException *e) {}

        @try {
            UIView *dimmingLayerView = TendiesSafeValueForKey(vc, @"_dimmingLayerView");
            TendiesHideViewTree(dimmingLayerView);
        } @catch (__unused NSException *e) {}

        @try {
            if ([vc respondsToSelector:@selector(setHidesDimmingLayer:)]) {
                [vc setHidesDimmingLayer:YES];
            } else {
                [vc setValue:@YES forKey:@"hidesDimmingLayer"];
            }
        } @catch (__unused NSException *e) {}

        @try {
            UIView *statusBarBg = TendiesSafeValueForKey(vc, @"_statusBarBackgroundView");
            if (statusBarBg) {
                statusBarBg.hidden = YES;
                statusBarBg.alpha = 0.0;
                statusBarBg.layer.opacity = 0.0;
            }
        } @catch (__unused NSException *e) {}
    } @finally {
        g_isHidingNativeChrome = NO;
    }
}

static void TendiesHidePBWallpaperViews(PBUIWallpaperViewController *vc) {
    if (!g_enabled || !vc) return;

    @try {
        UIView *homeView = [vc homescreenWallpaperView];
        TendiesHideViewTree(homeView);
    } @catch (__unused NSException *e) {}

    @try {
        UIView *lockView = [vc lockscreenWallpaperView];
        TendiesHideViewTree(lockView);
    } @catch (__unused NSException *e) {}
}

// ==========================================
// 核心：CAML 逐帧解析器
// ==========================================
@interface TendiesCAMLParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableDictionary *idToNameMap;
@property (nonatomic, strong) NSMutableDictionary *statesData;
@property (nonatomic, copy) NSString *currentParsingState;
@property (nonatomic, copy) NSString *currentParsingTargetId;
@property (nonatomic, copy) NSString *currentParsingKeyPath;
- (void)parseFile:(NSString *)path;
@end

@implementation TendiesCAMLParser

- (instancetype)init {
    if (self = [super init]) {
        _idToNameMap = [NSMutableDictionary new];
        _statesData = [NSMutableDictionary new];
    }
    return self;
}

- (void)parseFile:(NSString *)path {
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return;
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = self;
    [parser parse];
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"CALayer"]) {
        NSString *layerId = attributeDict[@"id"];
        NSString *layerName = attributeDict[@"name"];
        if (layerId.length && layerName.length) self.idToNameMap[layerId] = layerName;
    } else if ([elementName isEqualToString:@"LKState"]) {
        self.currentParsingState = attributeDict[@"name"];
    } else if ([elementName isEqualToString:@"LKStateSetValue"]) {
        self.currentParsingTargetId = attributeDict[@"targetId"];
        self.currentParsingKeyPath = attributeDict[@"keyPath"];
    } else if ([elementName isEqualToString:@"value"]) {
        if (self.currentParsingState && self.currentParsingTargetId && self.currentParsingKeyPath) {
            NSString *valStr = attributeDict[@"value"];
            if (valStr.length) {
                NSMutableDictionary *targetDict = self.statesData[self.currentParsingTargetId];
                if (!targetDict) {
                    targetDict = [NSMutableDictionary dictionary];
                    self.statesData[self.currentParsingTargetId] = targetDict;
                }
                NSMutableDictionary *stateDict = targetDict[self.currentParsingState];
                if (!stateDict) {
                    stateDict = [NSMutableDictionary dictionary];
                    targetDict[self.currentParsingState] = stateDict;
                }
                stateDict[self.currentParsingKeyPath] = @([valStr doubleValue]);
            }
        }
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"LKState"]) {
        self.currentParsingState = nil;
    } else if ([elementName isEqualToString:@"LKStateSetValue"]) {
        self.currentParsingTargetId = nil;
        self.currentParsingKeyPath = nil;
    }
}

@end

// ==========================================
// 核心渲染引擎视图
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isPathCached;
@property (nonatomic, assign) BOOL isUnlocking;
@property (nonatomic, strong) NSString *cachedBgPath;
@property (nonatomic, strong) NSString *cachedFloatPath;
@property (nonatomic, strong) NSString *cachedFgPath;
@property (nonatomic, strong) NSString *currentState;

@property (nonatomic, strong) TendiesCAMLParser *bgParser;
@property (nonatomic, strong) TendiesCAMLParser *floatParser;
@property (nonatomic, strong) TendiesCAMLParser *fgParser;
@property (nonatomic, strong) NSMutableDictionary *bgLayerMap;
@property (nonatomic, strong) NSMutableDictionary *floatLayerMap;
@property (nonatomic, strong) NSMutableDictionary *fgLayerMap;

- (void)reloadWallpaperViews;
@end

@implementation TendiesRenderEngineView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.layer.zPosition = CGFLOAT_MAX;
        self.isPathCached = NO;
        self.isUnlocking = NO;
        self.currentState = @"Init";

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
    self.bgView.frame = self.bounds;
    self.floatingView.frame = self.bounds;
    self.fgView.frame = self.bounds;
}

- (void)onWakeUp {
    if (!g_enabled) return;
    self.isUnlocking = NO;
    g_lockProgress = g_isUnlocked ? 1.0 : 0.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
    [CATransaction commit];
    [CATransaction flush];
}

- (void)onSleep {
    if (!g_enabled) return;
    self.isUnlocking = NO;
    g_lockProgress = 0.0;
    [self transitionToState:@"Sleep" animated:NO];
}

- (void)ensureLayerMap:(NSMutableDictionary *)layerMap parser:(TendiesCAMLParser *)parser packageView:(BSUICAPackageView *)pkgView {
    if (!pkgView || !pkgView.layer || !parser) return;
    if (layerMap.count == 0 && parser.statesData.count > 0) {
        for (NSString *targetId in parser.statesData) {
            NSString *name = parser.idToNameMap[targetId];
            if (name.length) {
                CALayer *found = TendiesFindLayerByName(pkgView.layer, name);
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

- (void)applyProgress:(double)progress parser:(TendiesCAMLParser *)parser layerMap:(NSDictionary *)layerMap {
    if (layerMap.count == 0 || !parser) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (NSString *targetId in parser.statesData) {
        CALayer *layer = layerMap[targetId];
        if (!layer) continue;

        NSDictionary *states = parser.statesData[targetId];
        NSDictionary *lockedVals = states[@"Locked"];
        NSDictionary *unlockVals = states[@"Unlock"];
        if (!lockedVals || !unlockVals) continue;

        for (NSString *keyPath in lockedVals) {
            NSNumber *lockNum = lockedVals[keyPath];
            NSNumber *unlockNum = unlockVals[keyPath];
            if (lockNum && unlockNum) {
                double currentVal = [lockNum doubleValue] + ([unlockNum doubleValue] - [lockNum doubleValue]) * progress;
                @try {
                    [layer setValue:@(currentVal) forKeyPath:keyPath];
                } @catch (__unused NSException *e) {}
            }
        }
    }

    [CATransaction commit];
}

- (void)onProgress:(NSNotification *)note {
    if (!g_enabled) return;
    double progress = [note.userInfo[@"progress"] doubleValue];
    progress = MAX(0.0, MIN(1.0, progress));
    g_lockProgress = progress;

    [self ensureAllLayerMaps];
    [self applyProgress:progress parser:self.bgParser layerMap:self.bgLayerMap];
    [self applyProgress:progress parser:self.floatParser layerMap:self.floatLayerMap];
    [self applyProgress:progress parser:self.fgParser layerMap:self.fgLayerMap];

    if (progress > 0.95) {
        self.currentState = @"Unlock";
        self.isUnlocking = NO;
    } else if (progress < 0.05) {
        self.currentState = @"Locked";
        self.isUnlocking = NO;
    } else {
        self.isUnlocking = YES;
        self.currentState = @"Scrubbing";
    }
}

- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated {
    if (!g_enabled) return;
    if ([self.currentState isEqualToString:stateName]) return;
    self.currentState = [stateName copy];

    if ([stateName isEqualToString:@"Unlock"]) {
        g_lockProgress = 1.0;
        [self ensureAllLayerMaps];
        [self applyProgress:1.0 parser:self.bgParser layerMap:self.bgLayerMap];
        [self applyProgress:1.0 parser:self.floatParser layerMap:self.floatLayerMap];
        [self applyProgress:1.0 parser:self.fgParser layerMap:self.fgLayerMap];
    } else if ([stateName isEqualToString:@"Locked"]) {
        g_lockProgress = 0.0;
        [self ensureAllLayerMaps];
        [self applyProgress:0.0 parser:self.bgParser layerMap:self.bgLayerMap];
        [self applyProgress:0.0 parser:self.floatParser layerMap:self.floatLayerMap];
        [self applyProgress:0.0 parser:self.fgParser layerMap:self.fgLayerMap];
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
}

- (void)reloadWallpaperViews {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (!g_enabled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.bgView removeFromSuperview];
                [self.floatingView removeFromSuperview];
                [self.fgView removeFromSuperview];
                self.bgView = nil;
                self.floatingView = nil;
                self.fgView = nil;
            });
            return;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        if (!g_tendiesPath.length || ![fm fileExistsAtPath:g_tendiesPath]) return;

        @synchronized (self) {
            if (!self.isPathCached) {
                NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath]
                                          includingPropertiesForKeys:nil
                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        errorHandler:nil];
                for (NSURL *fileURL in dirEnum) {
                    NSString *pathString = fileURL.path;
                    NSString *fileName = fileURL.lastPathComponent;
                    if ([[pathString pathExtension].lowercaseString isEqualToString:@"ca"] || [pathString hasSuffix:@".ca"]) {
                        if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) {
                            self.cachedBgPath = [pathString copy];
                        } else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) {
                            self.cachedFloatPath = [pathString copy];
                        } else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) {
                            self.cachedFgPath = [pathString copy];
                        }
                    }
                }
                self.isPathCached = YES;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.bgView removeFromSuperview];
            [self.floatingView removeFromSuperview];
            [self.fgView removeFromSuperview];
            self.bgView = nil;
            self.floatingView = nil;
            self.fgView = nil;

            self.bgLayerMap = [NSMutableDictionary dictionary];
            self.floatLayerMap = [NSMutableDictionary dictionary];
            self.fgLayerMap = [NSMutableDictionary dictionary];
            self.bgParser = nil;
            self.floatParser = nil;
            self.fgParser = nil;

            void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
            if (!handle) return;

            Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
            if (!PackageViewClass) return;

            if (self.cachedBgPath) {
                self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedBgPath]];
                [self addSubview:self.bgView];
                self.bgParser = [TendiesCAMLParser new];
                [self.bgParser parseFile:[self.cachedBgPath stringByAppendingPathComponent:@"main.caml"]];
            }
            if (self.cachedFloatPath) {
                self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFloatPath]];
                [self addSubview:self.floatingView];
                self.floatParser = [TendiesCAMLParser new];
                [self.floatParser parseFile:[self.cachedFloatPath stringByAppendingPathComponent:@"main.caml"]];
            }
            if (self.cachedFgPath) {
                self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFgPath]];
                [self addSubview:self.fgView];
                self.fgParser = [TendiesCAMLParser new];
                [self.fgParser parseFile:[self.cachedFgPath stringByAppendingPathComponent:@"main.caml"]];
            }

            [self setNeedsLayout];
            self.currentState = @"Init";

            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
            [CATransaction commit];
            [CATransaction flush];
        });
    });
}

@end

// ==========================================
// 挂载引擎视图
// ==========================================
static char kGlobalTendiesEngineKey;

static void EnsureEngineViewIsMounted(void) {
    if (!g_enabled) return;
    if (g_isMountingEngine) return;

    g_isMountingEngine = YES;
    @try {
        id wallpaperController = [%c(SBWallpaperController) sharedInstance];
        if (!wallpaperController) return;

        UIView *targetContainer = nil;
        @try {
            targetContainer = [wallpaperController valueForKey:@"_wallpaperWindow"];
        } @catch (__unused NSException *e) {}
        if (!targetContainer) {
            @try {
                targetContainer = [wallpaperController valueForKey:@"_wallpaperContainerView"];
            } @catch (__unused NSException *e) {}
        }
        if (!targetContainer) return;

        TendiesRenderEngineView *engineView = objc_getAssociatedObject(wallpaperController, &kGlobalTendiesEngineKey);
        if (!engineView) {
            engineView = [[TendiesRenderEngineView alloc] initWithFrame:targetContainer.bounds];
            objc_setAssociatedObject(wallpaperController, &kGlobalTendiesEngineKey, engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [targetContainer addSubview:engineView];
            [engineView reloadWallpaperViews];
        }

        if (engineView.superview != targetContainer) {
            [engineView removeFromSuperview];
            [targetContainer addSubview:engineView];
        }

        engineView.frame = targetContainer.bounds;
        engineView.layer.zPosition = CGFLOAT_MAX;
        [targetContainer bringSubviewToFront:engineView];
    } @finally {
        g_isMountingEngine = NO;
    }
}

// ==========================================
// PBUIWallpaperViewController
// ==========================================
%hook PBUIWallpaperViewController

- (void)viewWillLayoutSubviews {
    %orig;
    TendiesHidePBWallpaperViews(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    TendiesHidePBWallpaperViews(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    TendiesHidePBWallpaperViews(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    TendiesHidePBWallpaperViews(self);
}

- (void)viewDidMoveToWindow:(id)window shouldAppearOrDisappear:(BOOL)disappear {
    %orig;
    TendiesHidePBWallpaperViews(self);
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

// ==========================================
// SBWallpaperEffectView
// ==========================================
%hook SBWallpaperEffectView

- (void)layoutSubviews {
    %orig;
}

- (void)setAlpha:(double)alpha {
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    %orig;
}

%end

// ==========================================
// CSCoverSheetViewController
// ==========================================
%hook CSCoverSheetViewController

- (void)loadView {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)viewDidLoad {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)viewWillLayoutSubviews {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)viewDidMoveToWindow:(id)window shouldAppearOrDisappear:(BOOL)disappear {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id)coordinator {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateBackgroundContentView {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateBackground {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateWallpaperEffectView {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateWallpaperFloatingLayerContainerView {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateForegroundView {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateContent {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateDimmingLayer {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateFullBleedContent {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateComplicationSidebar {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_updateAppearanceForTransitionToOrientation:(long long)orientation {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)updateAppearanceForController:(id)controller {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)updateAppearanceForController:(id)controller withAnimationSettings:(id)settings completion:(id /* block */)completion {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)updateBehaviorForController:(id)controller {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)updateFloatingLayerOrdering {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)updatePosterSwitcherPresentationWithProgress:(double)progress {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)updateInterstitialPresentationWithProgress:(double)progress {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)scrollPanGestureChanged:(id)changed {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)scrollPanGestureDidUpdate:(id)update {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_scrollPanGestureBegan:(id)began {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_scrollPanGestureChanged:(id)changed {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_scrollPanGestureEnded:(id)ended {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_setHasContentAboveCoverSheet:(BOOL)sheet {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)_setHasContentAboveCoverSheet:(BOOL)sheet isSignificantUserInteraction:(BOOL)interaction {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
    TendiesHideCoverSheetChrome(self);
}

- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
    %orig;
    if (g_enabled) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
    TendiesHideCoverSheetChrome(self);
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
    TendiesHideCoverSheetChrome(self);
}

- (void)_setDismissed:(BOOL)dismissed {
    %orig;
    g_isUnlocked = dismissed;
    TendiesHideCoverSheetChrome(self);
}

- (void)setCoverSheetIsVisible:(BOOL)visible {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)setPartiallyOnScreen:(BOOL)screen {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)setHidesDimmingLayer:(BOOL)layer {
    if (g_enabled) {
        %orig(YES);
    } else {
        %orig;
    }
    TendiesHideCoverSheetChrome(self);
}

- (void)requestIdleTimerResetForPoster {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)startObservingAmbientPresentationForController:(id)controller {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)ambientPresentationController:(id)controller didUpdatePresented:(BOOL)presented {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)ambientPresentationControllerCancelledPossiblePresentation:(id)presentation {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)ambientPresentationControllerWillPossiblyPresent:(id)present {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

- (void)overlayController:(id)controller didChangePresentationProgress:(double)progress newPresentationProgress:(double)newProgress fromLeading:(_Bool)leading {
    %orig;
    TendiesHideCoverSheetChrome(self);
}

%end

// ==========================================
// SBWallpaperController
// ==========================================
%hook SBWallpaperController

- (void)_ingestPrimaryWallpaperLayersSnapshotIOSurface:(id)arg1 floatingWallpaperLayerSnapshotIOSurface:(id)arg2 snapshotScale:(double)arg3 traitCollection:(id)arg4 withCompletion:(id /* block */)arg5 {
    if (g_enabled) {
        if (arg5) {
            void (^completionBlock)(void) = arg5;
            completionBlock();
        }
        EnsureEngineViewIsMounted();
        return;
    }
    %orig;
}

- (void)updatePosterSwitcherSnapshots {
    if (g_enabled) return;
    %orig;
}

- (void)updateWallpaperAnimationWithProgress:(double)progress {
    if (g_enabled) {
        EnsureEngineViewIsMounted();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
        });
        return;
    }

    %orig;
}

%end

// ==========================================
// SBBacklightController
// ==========================================
%hook SBBacklightController

- (void)setBacklightState:(long long)state source:(long long)source {
    %orig;

    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            if (g_isScreenOn) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineWake" object:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineSleep" object:nil];
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
            if (g_isScreenOn) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineWake" object:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineSleep" object:nil];
                });
            }
        }
    }
}

%end

%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    prefsChangedCallback,
                                    CFSTR("com.yourname.tendiesprefs/ReloadPrefs"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
}
