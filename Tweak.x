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
- (void)setBacklightState:(long long)state source:(long long)source;
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion;
@end

@interface CSBackgroundContentView : UIView
@property (readonly, nonatomic) UIView *presentationView;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode;
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source;
- (void)setDismissed:(BOOL)dismissed;
- (void)_setDismissed:(BOOL)dismissed;
@end

@interface SBCoverSheetSlidingViewController : UIViewController
- (id)contentViewController;
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
// 智能视图净化算法 (只杀图像，不杀模糊)
// ==========================================
static void KillOriginalWallpaper(UIView *view) {
    if (!view || !g_enabled) return;
    
    // 主线程保护防崩溃
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            KillOriginalWallpaper(view);
        });
        return;
    }

    NSString *className = NSStringFromClass([view class]);
    
    // 【核心精髓】：精准识别锁屏壁纸场景、主屏原壁纸层、系统手势快照层
    // 这些类是提供“画面”的元凶，我们强制让它们透明隐藏
    if ([className containsString:@"ScenePresentationView"] || 
        [className isEqualToString:@"PBUIWallpaperView"] || 
        [className containsString:@"Snapshot"]) {
        if (!view.hidden || view.alpha > 0.0) {
            view.hidden = YES;
            view.alpha = 0.0;
        }
        return; // 已经隐藏了该容器，无需继续遍历其子视图
    }
    
    // 如果不是黑名单目标，继续向下层遍历搜捕
    for (UIView *subview in view.subviews) {
        KillOriginalWallpaper(subview);
    }
}

// 隐藏锁屏上的深度效果浮层（不碰背景）
static void HideFloatingLayer(CSCoverSheetViewController *vc) {
    if (!g_enabled || !vc) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HideFloatingLayer(vc); });
        return;
    }
    @try {
        UIView *floatingLayer = [vc valueForKey:@"_floatingLayerView"];
        if (floatingLayer) {
            floatingLayer.hidden = YES;
            floatingLayer.alpha = 0.0;
        }
    } @catch (NSException *e) {}
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
        self.backgroundColor = [UIColor clearColor]; // 保持透明，绝不遮挡系统模糊效果
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
                CALayer *found = nil;
                for (CALayer *sub in pkgView.layer.sublayers) {
                    if ([sub.name isEqualToString:name]) { found = sub; break; }
                }
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
                @try { [layer setValue:@(currentVal) forKeyPath:keyPath]; } @catch (NSException *e) {}
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

    if (progress > 0.95) { self.currentState = @"Unlock"; self.isUnlocking = NO; }
    else if (progress < 0.05) { self.currentState = @"Locked"; self.isUnlocking = NO; }
    else { self.isUnlocking = YES; self.currentState = @"Scrubbing"; }
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
                [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
                self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            });
            return;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        if (!g_tendiesPath.length || ![fm fileExistsAtPath:g_tendiesPath]) return;

        @synchronized (self) {
            if (!self.isPathCached) {
                NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
                for (NSURL *fileURL in dirEnum) {
                    NSString *pathString = fileURL.path;
                    NSString *fileName = fileURL.lastPathComponent;
                    if ([[pathString pathExtension].lowercaseString isEqualToString:@"ca"] || [pathString hasSuffix:@".ca"]) {
                        if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) self.cachedBgPath = [pathString copy];
                        else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) self.cachedFloatPath = [pathString copy];
                        else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) self.cachedFgPath = [pathString copy];
                    }
                }
                self.isPathCached = YES;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
            self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            self.bgLayerMap = [NSMutableDictionary dictionary]; self.floatLayerMap = [NSMutableDictionary dictionary]; self.fgLayerMap = [NSMutableDictionary dictionary];
            self.bgParser = nil; self.floatParser = nil; self.fgParser = nil;

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
// 挂载引擎视图 (主线程绝对安全)
// ==========================================
static char kGlobalTendiesEngineKey;
static BOOL g_isMountingEngine = NO;

static void EnsureEngineViewIsMounted(void) {
    if (!g_enabled) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ EnsureEngineViewIsMounted(); });
        return;
    }
    
    if (g_isMountingEngine) return;
    g_isMountingEngine = YES;
    @try {
        id wallpaperController = [%c(SBWallpaperController) sharedInstance];
        if (!wallpaperController) return;

        UIView *targetContainer = nil;
        @try { targetContainer = [wallpaperController valueForKey:@"_wallpaperWindow"]; } @catch (NSException *e) {}
        if (!targetContainer) {
            @try { targetContainer = [wallpaperController valueForKey:@"_wallpaperContainerView"]; } @catch (NSException *e) {}
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
// 核心击杀钩子：拦截一切导致原壁纸闪现的方法
// ==========================================

%hook CSBackgroundContentView
- (void)layoutSubviews {
    %orig;
    if (g_enabled) {
        // 利用智能过滤，精确干掉视图中真正渲染壁纸的部分，而完全放过模糊特效
        KillOriginalWallpaper(self);
    }
}
%end

%hook PBUIWallpaperViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) KillOriginalWallpaper(self.view);
}
%end

%hook SBCoverSheetSlidingViewController
// 手势期间逐帧守护，彻底掐断系统用快照欺骗视觉的可能
- (CGRect)_updatePositionViewForProgress:(double)progress velocity:(double)velocity forPresentationValue:(BOOL)value {
    CGRect result = %orig;
    if (g_enabled) {
        EnsureEngineViewIsMounted();
        id coverSheetVC = [self contentViewController];
        if ([coverSheetVC respondsToSelector:@selector(view)]) {
            KillOriginalWallpaper([coverSheetVC view]);
        }
        KillOriginalWallpaper(self.view); // 击杀滑动手势自己产生的快照
    }
    return result;
}

- (CGRect)_updatePositionViewForProgress:(double)progress forPresentationValue:(BOOL)value {
    CGRect result = %orig;
    if (g_enabled) {
        EnsureEngineViewIsMounted();
        id coverSheetVC = [self contentViewController];
        if ([coverSheetVC respondsToSelector:@selector(view)]) {
            KillOriginalWallpaper([coverSheetVC view]);
        }
        KillOriginalWallpaper(self.view);
    }
    return result;
}
%end

// ==========================================
// 状态同步与挂载 Hook
// ==========================================

%hook CSCoverSheetViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) {
        KillOriginalWallpaper(self.view);
        HideFloatingLayer(self);
    }
}

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}

- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
    %orig;
    if (g_enabled) {
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

- (void)_setDismissed:(BOOL)dismissed {
    %orig;
    g_isUnlocked = dismissed;
}
%end


%hook SBWallpaperController
- (void)_ingestPrimaryWallpaperLayersSnapshotIOSurface:(id)arg1 floatingWallpaperLayerSnapshotIOSurface:(id)arg2 snapshotScale:(double)arg3 traitCollection:(id)arg4 withCompletion:(id /* block */)arg5 {
    if (g_enabled) {
        if (arg5) { void (^completionBlock)(void) = arg5; completionBlock(); }
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


%hook SBBacklightController
- (void)setBacklightState:(long long)state source:(long long)source {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:g_isScreenOn ? @"TendiesEngineWake" : @"TendiesEngineSleep" object:nil];
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
                [[NSNotificationCenter defaultCenter] postNotificationName:g_isScreenOn ? @"TendiesEngineWake" : @"TendiesEngineSleep" object:nil];
            });
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
