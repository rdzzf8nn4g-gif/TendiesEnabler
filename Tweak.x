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
- (void)tendies_forceHideNativeWallpaperLayers; 
@end

@interface SBWallpaperEffectView : UIView
@property (nonatomic) long long wallpaperStyle;
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
// 核心：CAML 逐帧解析器 (完美提取坐标，赋予单引擎物理互动)
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

static CALayer *TendiesFindLayerByName(CALayer *layer, NSString *name) {
    if ([layer.name isEqualToString:name]) return layer;
    for (CALayer *sub in layer.sublayers) {
        CALayer *found = TendiesFindLayerByName(sub, name);
        if (found) return found;
    }
    return nil;
}

// ==========================================
// 核心渲染引擎视图 (纯正单实例结构)
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
    self.isPathCached = NO; self.cachedBgPath = nil; self.cachedFloatPath = nil; self.cachedFgPath = nil;
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
    self.isUnlocking = NO;
    [CATransaction begin]; [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO]; [CATransaction commit]; [CATransaction flush];
}

- (void)onSleep {
    if (!g_enabled) return;
    self.isUnlocking = NO;
    [self transitionToState:@"Sleep" animated:NO];
}

- (void)ensureLayerMap:(NSMutableDictionary *)layerMap parser:(TendiesCAMLParser *)parser packageView:(BSUICAPackageView *)pkgView {
    if (!pkgView || !pkgView.layer || !parser) return;
    if (layerMap.count == 0 && parser.statesData.count > 0) {
        for (NSString *targetId in parser.statesData) {
            NSString *name = parser.idToNameMap[targetId];
            if (name) {
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

// 核心插值方法：彻底解决以前只显示过渡动画（假死/渐变）的问题
- (void)applyProgress:(double)progress parser:(TendiesCAMLParser *)parser layerMap:(NSDictionary *)layerMap {
    if (layerMap.count == 0 || !parser) return;
    [CATransaction begin]; 
    [CATransaction setDisableActions:YES]; // 禁用系统默认补间动画，强行注入计算坐标
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
    if (!g_enabled) return;
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
    if (!g_enabled) return;
    if ([self.currentState isEqualToString:stateName]) return;
    self.currentState = [stateName copy];
    
    if ([stateName isEqualToString:@"Unlock"]) {
        [self ensureAllLayerMaps]; [self applyProgress:1.0 parser:self.bgParser layerMap:self.bgLayerMap]; [self applyProgress:1.0 parser:self.floatParser layerMap:self.floatLayerMap]; [self applyProgress:1.0 parser:self.fgParser layerMap:self.fgLayerMap];
    } else if ([stateName isEqualToString:@"Locked"]) {
        [self ensureAllLayerMaps]; [self applyProgress:0.0 parser:self.bgParser layerMap:self.bgLayerMap]; [self applyProgress:0.0 parser:self.floatParser layerMap:self.floatLayerMap]; [self applyProgress:0.0 parser:self.fgParser layerMap:self.fgLayerMap];
    }
    
    // 继续交由系统接管透明度等遗留效果
    if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
        [self.bgView setState:stateName animated:animated]; [self.floatingView setState:stateName animated:animated]; [self.fgView setState:stateName animated:animated];
    } else {
        [self.bgView setState:stateName]; [self.floatingView setState:stateName]; [self.fgView setState:stateName];
    }
}

- (void)reloadWallpaperViews {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (!g_enabled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
                self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            }); return;
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!g_tendiesPath || ![fm fileExistsAtPath:g_tendiesPath]) return;
        @synchronized(self) {
            if (!self.isPathCached) {
                NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
                for (NSURL *fileURL in dirEnum) {
                    NSString *pathString = fileURL.path; NSString *fileName = fileURL.lastPathComponent;
                    if ([pathString hasSuffix:@"/"]) pathString = [pathString substringToIndex:pathString.length - 1];
                    if ([[[pathString pathExtension] lowercaseString] isEqualToString:@"ca"] || [pathString hasSuffix:@".ca"]) {
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
                self.bgParser = [TendiesCAMLParser new]; [self.bgParser parseFile:[self.cachedBgPath stringByAppendingPathComponent:@"main.caml"]];
            }
            if (self.cachedFloatPath) {
                self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFloatPath]];
                [self addSubview:self.floatingView];
                self.floatParser = [TendiesCAMLParser new]; [self.floatParser parseFile:[self.cachedFloatPath stringByAppendingPathComponent:@"main.caml"]];
            }
            if (self.cachedFgPath) {
                self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFgPath]];
                [self addSubview:self.fgView];
                self.fgParser = [TendiesCAMLParser new]; [self.fgParser parseFile:[self.cachedFgPath stringByAppendingPathComponent:@"main.caml"]];
            }
            [self setNeedsLayout];
            self.currentState = @"Init";
            [CATransaction begin]; [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO]; [CATransaction commit]; [CATransaction flush];
        });
    });
}
@end


// ==========================================
// 完美回滚到你第一版发给我的纯净原始 Hook (保证壁纸绝对显示)
// ==========================================
static void EnsureEngineViewIsMounted() {
    if (!g_enabled) return;
    id wallpaperController = [%c(SBWallpaperController) sharedInstance];
    if (!wallpaperController) return;
    
    UIView *targetContainer = [wallpaperController valueForKey:@"_wallpaperWindow"];
    if (!targetContainer) targetContainer = [wallpaperController valueForKey:@"_wallpaperContainerView"];
    if (!targetContainer) return;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(wallpaperController, "GlobalTendiesEngine");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:targetContainer.bounds];
        objc_setAssociatedObject(wallpaperController, "GlobalTendiesEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [targetContainer addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    if (engineView.superview != targetContainer) {
        [engineView removeFromSuperview];
        [targetContainer addSubview:engineView];
    }
    engineView.frame = targetContainer.bounds;
    [targetContainer bringSubviewToFront:engineView];
}


// 1. 干掉 PaperBoardUI 负责的桌面系统壁纸和默认锁屏壁纸 (完全恢复你的初版)
%hook PBUIWallpaperViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) {
        if ([self respondsToSelector:@selector(homescreenWallpaperView)]) {
            UIView *homeView = [self homescreenWallpaperView];
            if (homeView) homeView.alpha = 0.0;
        }
        if ([self respondsToSelector:@selector(lockscreenWallpaperView)]) {
            UIView *lockView = [self lockscreenWallpaperView];
            if (lockView) lockView.alpha = 0.0;
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

// 2. 干掉滑动时的系统高斯模糊过渡层 (完全恢复你的初版)
%hook SBWallpaperEffectView
- (void)layoutSubviews {
    %orig;
    if (g_enabled) {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}
- (void)setAlpha:(double)alpha {
    if (g_enabled) {
        %orig(0.0);
    } else {
        %orig;
    }
}
- (void)setHidden:(BOOL)hidden {
    if (g_enabled) {
        %orig(YES);
    } else {
        %orig;
    }
}
%end

// 3. 暴力拦截 CoverSheet (锁屏) 的所有后台视图滚动刷新事件 (完全恢复你的初版)
%hook CSCoverSheetViewController
%new
- (void)tendies_forceHideNativeWallpaperLayers {
    UIViewController *bgVC = [self valueForKey:@"_backgroundContentViewController"];
    if (bgVC && bgVC.view) {
        bgVC.view.alpha = 0.0;
        bgVC.view.hidden = YES;
    }
    UIView *floatingLayer = [self valueForKey:@"_floatingLayerView"];
    if (floatingLayer) {
        floatingLayer.alpha = 0.0;
        floatingLayer.hidden = YES;
    }
    if ([self respondsToSelector:@selector(_updateDimmingLayer)]) {
        @try {
            UIView *dimmingLayer = [self valueForKey:@"_dimmingView"];
            if (dimmingLayer) {
                dimmingLayer.alpha = 0.0;
                dimmingLayer.hidden = YES;
            }
        } @catch (NSException *e) {}
    }
}

- (void)viewWillLayoutSubviews {
    %orig;
    EnsureEngineViewIsMounted();
    if (g_enabled) {
        [self tendies_forceHideNativeWallpaperLayers];
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (g_enabled) {
        [self tendies_forceHideNativeWallpaperLayers];
    }
}

- (void)_updateBackgroundContentView {
    %orig;
    if (g_enabled) [self tendies_forceHideNativeWallpaperLayers];
}
- (void)_updateWallpaperEffectView {
    %orig;
    if (g_enabled) [self tendies_forceHideNativeWallpaperLayers];
}
- (void)_updateWallpaper {
    %orig;
    if (g_enabled) [self tendies_forceHideNativeWallpaperLayers];
}
- (void)updatePosterSwitcherSnapshots {
    if (g_enabled) return;
    %orig;
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
// 动画进度获取及快照拦截 (完全恢复你的初版，仅仅通过通知抛给 Parser 运算)
// ==========================================
%hook SBWallpaperController
- (void)_ingestPrimaryWallpaperLayersSnapshotIOSurface:(id)arg1 floatingWallpaperLayerSnapshotIOSurface:(id)arg2 snapshotScale:(double)arg3 traitCollection:(id)arg4 withCompletion:(id /* block */)arg5 {
    if (g_enabled) {
        if (arg5) {
            void (^completionBlock)(void) = arg5;
            completionBlock();
        }
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
    EnsureEngineViewIsMounted();
    if (g_enabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
        });
    }
}
%end


// ==========================================
// 亮灭屏与锁屏状态同步 (未变动)
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
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
