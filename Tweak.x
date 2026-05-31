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
                    [self.layer addSublayer:root];
                    Class CAStateControllerClass = NSClassFromString(@"CAStateController");
                    if (CAStateControllerClass) {
                        _stateController = [[(id)CAStateControllerClass alloc] initWithLayer:self.layer];
                    }
                }
            }
        }
    }
    return self;
}

// 【终极排版拦截器】：无论走哪个底层类，强制进行坐标系翻转与居中缩放铺满
- (void)layoutSubviews {
    [super layoutSubviews];
    
    if (_uiPackageView) {
        _uiPackageView.frame = self.bounds;
    }
    
    CALayer *targetRoot = nil;
    CALayer *hostLayer = nil;
    
    // 取出真正渲染内容的包裹层与宿主层
    if (_uiPackageView) {
        targetRoot = [_uiPackageView.layer.sublayers firstObject];
        hostLayer = _uiPackageView.layer;
    } else if (_package) {
        targetRoot = [_package valueForKey:@"rootLayer"];
        hostLayer = self.layer;
    }
    
    if (targetRoot && hostLayer) {
        // 1. 同步坐标系：完美解决“底部元素跑天上”与“动画倒转视觉错觉”
        hostLayer.geometryFlipped = targetRoot.geometryFlipped;
        
        // 2. 居中与缩放：为 iOS 14-15 提供类似 iOS 16 BSUICAPackageView 的自适应全屏能力
        CGSize originalSize = targetRoot.bounds.size;
        if (originalSize.width > 0 && originalSize.height > 0) {
            CGFloat scaleX = self.bounds.size.width / originalSize.width;
            CGFloat scaleY = self.bounds.size.height / originalSize.height;
            CGFloat scale = MAX(scaleX, scaleY); // 等比缩放，铺满屏幕
            
            targetRoot.position = CGPointMake(self.bounds.size.width / 2.0, self.bounds.size.height / 2.0);
            targetRoot.transform = CATransform3DMakeScale(scale, scale, 1.0);
        } else {
            targetRoot.frame = self.bounds;
        }
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
static NSString *g_zonePath = nil;
static BOOL g_isUnlocked = NO; 
static BOOL g_isScreenOn = YES;

static __weak _UIPortalView *g_portalView = nil;

static void EnsureEngineViewIsMounted(); 

static void reloadPrefs() {
    CFStringRef appID = CFSTR("com.iosdump.zoneprefs");
    CFPreferencesAppSynchronize(appID);
    Boolean valid;
    
    g_enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &valid) ? valid : NO;
    g_enhanced_engine = CFPreferencesGetAppBooleanValue(CFSTR("EnhancedEngine"), appID, &valid) ? valid : NO;
    
    CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("ZonePath"), appID);
    if (pathRef && CFGetTypeID(pathRef) == CFStringGetTypeID()) {
        g_zonePath = [(__bridge NSString *)pathRef copy];
    } else {
        g_zonePath = nil; 
    }
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        Class wc = NSClassFromString(@"SBWallpaperController");
        if ([wc respondsToSelector:@selector(sharedInstance)] && [wc sharedInstance]) {
            EnsureEngineViewIsMounted();
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineInternalReload" object:nil];
    });
}

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
    if (self.bgView) self.bgView.frame = self.bounds;
    if (self.floatingView) self.floatingView.frame = self.bounds;
    if (self.fgView) self.fgView.frame = self.bounds;
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
- (NSString *)resolveRealStateNameFor:(NSString *)logicalState;
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
    if ([elementName isEqualToString:@"LKState"]) self.currentParsingState = nil;
    else if ([elementName isEqualToString:@"LKStateSetValue"]) { self.currentParsingTargetId = nil; self.currentParsingKeyPath = nil; }
}
- (NSString *)resolveRealStateNameFor:(NSString *)logicalState {
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
    for (NSString *s in candidates) { if ([s containsString:@"PortraitUp"] && [s containsString:@"Light"]) return s; }
    for (NSString *s in candidates) { if ([s containsString:@"Light"]) return s; }
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

// 【一字未改】完全保留你 iOS16-17 的原生布局代码
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    
    // 【强制拦截系统干扰】若 iOS14-15 的父层容器比屏幕大（塞入了 Padding），主动切除多余部分以防止画面异常变大
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    if (bounds.size.width > screenSize.width + 5) {
        bounds.size = screenSize;
        bounds.origin = CGPointZero;
    }
    
    CGSize targetSize = self.logicalScreenSize;
    if (targetSize.width <= 0 || targetSize.height <= 0) targetSize = bounds.size;
    
    CGFloat scaleX = bounds.size.width / targetSize.width;
    CGFloat scaleY = bounds.size.height / targetSize.height;
    CGFloat scale = MAX(scaleX, scaleY);
    
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
            v.layer.geometryFlipped = p ? p.isGeometryFlipped : NO;
            rootLayer.position = CGPointMake(bounds.size.width / 2.0, bounds.size.height / 2.0);
            rootLayer.transform = CATransform3DMakeScale(scale, scale, 1.0);
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

// 【修复核心 CPU 消耗】
- (void)applyProgress:(double)progress parser:(ZoneCAMLParserEnhanced *)parser layerMap:(NSDictionary *)layerMap {
    if (layerMap.count == 0 || !parser) return;
    
    NSString *realLockedState = [parser resolveRealStateNameFor:@"Locked"];
    NSString *realUnlockState = [parser resolveRealStateNameFor:@"Unlock"];
    
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
                // 替换 @try-catch 为安全判断，大幅减轻 iOS14-15 中的发热与卡顿现象
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
    
    NSString *realBgState = [self.bgParser resolveRealStateNameFor:stateName] ?: stateName;
    NSString *realFloatState = [self.floatParser resolveRealStateNameFor:stateName] ?: stateName;
    NSString *realFgState = [self.fgParser resolveRealStateNameFor:stateName] ?: stateName;
    
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
        
        // 【核心漏洞修复】：全局深度搜索 Wallpaper.plist，解决“部分大，部分小”的解析失败问题！
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
    if (!g_enabled) return;
    id wallpaperController = [%c(SBWallpaperController) sharedInstance];
    if (!wallpaperController) return;
    
    UIView *targetContainer = safelyGetIvarAsView(wallpaperController, "_wallpaperWindow");
    if (!targetContainer) {
        targetContainer = safelyGetIvarAsView(wallpaperController, "_wallpaperContainerView");
    }
    
    if (!targetContainer) return;
    
    UIView *existingEngine = objc_getAssociatedObject(wallpaperController, "GlobalZoneEngine");
    
    BOOL isEnhancedClass = [existingEngine isKindOfClass:NSClassFromString(@"ZoneRenderEngineEnhanced")];
    
    if (existingEngine) {
        if ((g_enhanced_engine && !isEnhancedClass) || (!g_enhanced_engine && isEnhancedClass)) {
            if ([existingEngine respondsToSelector:@selector(clearCurrentViewsSafely)]) {
                [existingEngine performSelector:@selector(clearCurrentViewsSafely)];
            }
            [existingEngine removeFromSuperview];
            existingEngine = nil;
            objc_setAssociatedObject(wallpaperController, "GlobalZoneEngine", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    
    if (!existingEngine) {
        if (g_enhanced_engine) {
            existingEngine = [[ZoneRenderEngineEnhanced alloc] initWithFrame:targetContainer.bounds];
        } else {
            existingEngine = [[ZoneRenderEngineLegacy alloc] initWithFrame:targetContainer.bounds];
        }
        objc_setAssociatedObject(wallpaperController, "GlobalZoneEngine", existingEngine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [targetContainer addSubview:existingEngine];
        [existingEngine performSelector:@selector(reloadWallpaperViews)];
    }
    
    if (existingEngine.superview != targetContainer) {
        [existingEngine removeFromSuperview];
        [targetContainer addSubview:existingEngine];
    }
    
    existingEngine.frame = targetContainer.bounds;
    [targetContainer bringSubviewToFront:existingEngine];
}

// =========================================================================
// ==================== 【iOS 16+ 专属 Hook 区域 (严禁修改)】==================
// =========================================================================
%group iOS16Plus

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

%hook CSCoverSheetViewController
- (void)viewWillLayoutSubviews {
    %orig;
    EnsureEngineViewIsMounted(); 
    
    if (g_enabled) {
        UIViewController *bgVC = safelyGetIvarAsViewController(self, "_backgroundContentViewController");
        if (bgVC && bgVC.view) {
            bgVC.view.alpha = 1.0;
            bgVC.view.hidden = NO;
        }
        
        id wallpaperController = [%c(SBWallpaperController) sharedInstance];
        UIView *engineView = objc_getAssociatedObject(wallpaperController, "GlobalZoneEngine");
        
        if (engineView) {
            _UIPortalView *portalView = objc_getAssociatedObject(self, "CoverSheetZonePortal");
            if (!portalView) {
                portalView = [[NSClassFromString(@"_UIPortalView") alloc] initWithFrame:self.view.bounds];
                portalView.sourceView = engineView;
                portalView.hidesSourceView = NO;
                portalView.matchesAlpha = NO; 
                portalView.alpha = 0.0; 
                portalView.matchesPosition = YES;
                portalView.matchesTransform = YES;
                portalView.userInteractionEnabled = NO;
                objc_setAssociatedObject(self, "CoverSheetZonePortal", portalView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                g_portalView = portalView;
            }
            
            if (portalView.sourceView != engineView) {
                portalView.sourceView = engineView; 
            }

            if (bgVC && bgVC.view) {
                if (portalView.superview != bgVC.view) {
                    [portalView removeFromSuperview];
                    [bgVC.view addSubview:portalView];
                }
                portalView.frame = bgVC.view.bounds;
                
                for (UIView *sub in bgVC.view.subviews) {
                    if (sub != portalView) {
                        sub.alpha = 0.0;
                        sub.hidden = YES;
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
            if (dimmingView) { dimmingView.alpha = 0.0; dimmingView.hidden = YES; }
            
            UIView *tintingView = safelyGetIvarAsView(self, "_tintingView");
            if (tintingView) { tintingView.alpha = 0.0; tintingView.hidden = YES; }
        }
        
        UIView *floatingLayer = safelyGetIvarAsView(self, "_floatingLayerView");
        if (floatingLayer) { 
            floatingLayer.alpha = 0.0; 
            floatingLayer.hidden = YES; 
        }
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
    EnsureEngineViewIsMounted();
    if (g_enabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
            
            if (g_portalView) {
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
        });
    }
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
    if (g_enabled) {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}
- (void)setAlpha:(double)alpha {
    if (g_enabled) { %orig(0.0); return; }
    %orig;
}
- (void)setHidden:(BOOL)hidden {
    if (g_enabled) { %orig(YES); return; }
    %orig;
}
%end

// 为了避免编译器警告，声明扩展方法
@interface CSCoverSheetViewController (Zone)
- (void)zone_tickProgress;
@end

%hook CSCoverSheetViewController

// 【无敌的核心物理雷达】：使用 CADisplayLink 挂载最高优先级的渲染帧侦听
- (void)viewDidLoad {
    %orig;
    if (g_enabled) {
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(zone_tickProgress)];
        // 绑定到通用线程，哪怕系统在疯狂执行手势弹簧动画，照样捕获不误
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, "ZoneTicker", link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// 【物理位置提取引擎】：真正捕获到了导致弹跳的根源！
%new
- (void)zone_tickProgress {
    if (!g_enabled) return;
    
    // CoreAnimation 底层 presentationLayer：包含系统正处于运动回弹状态的每一帧
    CALayer *presLayer = self.view.layer.presentationLayer ?: self.view.layer;
    
    // 【核弹级突破】：不要读自己的坐标！在 iOS 14 中滑动的是它的老祖宗（系统盖板），
    // 必须直接利用 `convertRect:toLayer:nil` 打穿组件树，获取在全屏幕上绝对的、包含物理减速的最终弹簧坐标！
    CGRect absoluteRect = [presLayer.superlayer convertRect:presLayer.frame toLayer:nil];
    
    double yOffset = absoluteRect.origin.y;
    double screenHeight = [UIScreen mainScreen].bounds.size.height;
    
    // ==========================================
    // 【iOS 14-15 严谨版】：负号锁定真正的解锁进程
    // 下滑 (扯皮筋) 产生正向位移，用负号拦截使其变为 0，防止假解锁
    // ==========================================
    double engineProgress = -yOffset / screenHeight;
    engineProgress = MAX(0.0, MIN(1.0, engineProgress));
    
    static double lastProgress = -1;
    // 极小精度的变动检测 (0.0001)，完美把系统的阻尼弹跳势能，一丝不苟地传导给壁纸
    if (ABS(engineProgress - lastProgress) > 0.0001) {
        lastProgress = engineProgress;
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineProgress" object:nil userInfo:@{@"progress": @(engineProgress)}];
        
        // Portal 透视渐变跟随同步
        if (g_portalView) {
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

- (void)viewWillLayoutSubviews {
    %orig;
    EnsureEngineViewIsMounted(); 
    
    if (g_enabled) {
        id wallpaperController = [%c(SBWallpaperController) sharedInstance];
        UIView *engineView = objc_getAssociatedObject(wallpaperController, "GlobalZoneEngine");
        
        if (engineView) {
            _UIPortalView *portalView = objc_getAssociatedObject(self, "CoverSheetZonePortal");
            if (!portalView) {
                portalView = [[NSClassFromString(@"_UIPortalView") alloc] initWithFrame:self.view.bounds];
                portalView.sourceView = engineView;
                portalView.hidesSourceView = NO;
                portalView.matchesAlpha = NO; 
                portalView.alpha = 1.0; 
                portalView.matchesPosition = YES;
                portalView.matchesTransform = YES;
                portalView.userInteractionEnabled = NO;
                objc_setAssociatedObject(self, "CoverSheetZonePortal", portalView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                g_portalView = portalView;
            }
            
            if (portalView.sourceView != engineView) {
                portalView.sourceView = engineView; 
            }

            if (portalView.superview != self.view) {
                [self.view insertSubview:portalView atIndex:0];
            } else {
                NSInteger index = [self.view.subviews indexOfObject:portalView];
                if (index != 0) {
                    [self.view sendSubviewToBack:portalView];
                }
            }
            
            portalView.frame = self.view.bounds;
            
            UIView *dimmingView = safelyGetIvarAsView(self, "_dimmingView");
            if (dimmingView) { dimmingView.alpha = 0.0; dimmingView.hidden = YES; }
            
            UIView *tintingView = safelyGetIvarAsView(self, "_tintingView");
            if (tintingView) { tintingView.alpha = 0.0; tintingView.hidden = YES; }
        }
        
        UIView *floatingLayer = safelyGetIvarAsView(self, "_floatingLayerView");
        if (floatingLayer) { 
            floatingLayer.alpha = 0.0; 
            floatingLayer.hidden = YES; 
        }
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (g_enabled) {
        g_isUnlocked = NO;
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
    if (g_enabled && self.superview) {
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
    if (g_enabled) {
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
    if (g_enabled) {
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
    if (g_enabled) {
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

// 手势系统重绘：全部静默剔除，将发热源头彻底拔除，运算权让给刚刚配置好的专属 CADisplayLink
- (void)_scrollPanGestureBegan:(id)arg1 { %orig; }
- (void)_scrollPanGestureChanged:(id)arg1 { %orig; }
- (void)_scrollPanGestureEnded:(id)arg1 { %orig; }

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
    if (g_enabled) {
        UIView *presentationView = safelyGetIvarAsView(self, "presentationView"); 
        if (!presentationView && [self respondsToSelector:@selector(presentationView)]) {
            presentationView = [self performSelector:@selector(presentationView)];
        }
        if (presentationView && [presentationView isKindOfClass:[UIView class]]) {
            presentationView.hidden = YES;
            presentationView.alpha = 0.0;
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

%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    
    if (NSClassFromString(@"PBUIWallpaperViewController") != Nil) {
        %init(iOS16Plus);
    } else {
        %init(iOS14_15);
    }
    
    %init;
}
