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

// ==========================================
// 全局变量与配置管理
// ==========================================
static BOOL g_enabled = NO;
static NSString *g_zonePath = nil;
static BOOL g_isUnlocked = NO; 
static BOOL g_isScreenOn = YES;

static __weak _UIPortalView *g_portalView = nil;

static void reloadPrefs() {
    CFStringRef appID = CFSTR("com.iosdump.zoneprefs");
    CFPreferencesAppSynchronize(appID);
    Boolean valid;
    g_enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &valid) ? valid : NO;
    CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("ZonePath"), appID);
    if (pathRef && CFGetTypeID(pathRef) == CFStringGetTypeID()) {
        g_zonePath = [(__bridge NSString *)pathRef copy];
    } else {
        g_zonePath = nil; 
    }
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineInternalReload" object:nil];
}

// ==========================================
// 核心：CAML 逐帧解析器 (工业级容错升级版)
// ==========================================
@interface ZoneCAMLParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableDictionary *idToNameMap;
@property (nonatomic, strong) NSMutableDictionary *statesData;
@property (nonatomic, copy) NSString *currentParsingState;
@property (nonatomic, copy) NSString *currentParsingTargetId;
@property (nonatomic, copy) NSString *currentParsingKeyPath;
- (void)parseFile:(NSString *)path;
@end

@implementation ZoneCAMLParser
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
        NSString *rawStateName = attributeDict[@"name"];
        // 【核心修复1】模糊匹配状态：完美兼容带有 "PortraitUp Light" 等后缀的复杂命名壁纸 (如 BlackHole)
        if ([rawStateName localizedCaseInsensitiveContainsString:@"Lock"]) {
            self.currentParsingState = @"Locked";
        } else if ([rawStateName localizedCaseInsensitiveContainsString:@"Unlock"] || [rawStateName localizedCaseInsensitiveContainsString:@"Home"]) {
            self.currentParsingState = @"Unlock";
        } else if ([rawStateName localizedCaseInsensitiveContainsString:@"Sleep"]) {
            self.currentParsingState = @"Sleep";
        } else {
            self.currentParsingState = nil;
        }
    } else if ([elementName isEqualToString:@"LKStateSetValue"]) {
        self.currentParsingTargetId = attributeDict[@"targetId"];
        self.currentParsingKeyPath = attributeDict[@"keyPath"];
    } else if ([elementName isEqualToString:@"value"]) {
        if (self.currentParsingState && self.currentParsingTargetId && self.currentParsingKeyPath) {
            NSString *valStr = attributeDict[@"value"];
            NSString *typeStr = attributeDict[@"type"]; // 捕获数据类型
            if (valStr) {
                NSMutableDictionary *targetDict = self.statesData[self.currentParsingTargetId];
                if (!targetDict) { targetDict = [NSMutableDictionary dictionary]; self.statesData[self.currentParsingTargetId] = targetDict; }
                NSMutableDictionary *stateDict = targetDict[self.currentParsingState];
                if (!stateDict) { stateDict = [NSMutableDictionary dictionary]; targetDict[self.currentParsingState] = stateDict; }
                
                // 【核心修复2】多数据类型解析：支持 CGPoint 和 CGSize 提取，防止 Mario 壁纸静默崩溃
                if ([typeStr isEqualToString:@"CGPoint"] || [typeStr isEqualToString:@"CGSize"]) {
                    NSString *cleanVal = [valStr stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"{}()[] "]];
                    NSArray *comps = [cleanVal componentsSeparatedByString:@" "];
                    if (comps.count < 2 && [cleanVal containsString:@","]) {
                        comps = [cleanVal componentsSeparatedByString:@","];
                    }
                    if (comps.count >= 2) {
                        double x = [comps[0] doubleValue];
                        double y = [comps[1] doubleValue];
                        if ([typeStr isEqualToString:@"CGPoint"]) {
                            stateDict[self.currentParsingKeyPath] = [NSValue valueWithCGPoint:CGPointMake(x, y)];
                        } else {
                            stateDict[self.currentParsingKeyPath] = [NSValue valueWithCGSize:CGSizeMake(x, y)];
                        }
                    }
                } else {
                    // 默认作为标量处理
                    stateDict[self.currentParsingKeyPath] = @([valStr doubleValue]);
                }
            }
        }
    }
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"LKState"]) self.currentParsingState = nil;
    else if ([elementName isEqualToString:@"LKStateSetValue"]) { self.currentParsingTargetId = nil; self.currentParsingKeyPath = nil; }
}
@end

static CALayer *ZoneFindLayerByName(CALayer *layer, NSString *name) {
    if ([layer.name isEqualToString:name]) return layer;
    for (CALayer *sub in layer.sublayers) {
        CALayer *found = ZoneFindLayerByName(sub, name);
        if (found) return found;
    }
    return nil;
}

// ==========================================
// 核心渲染引擎视图 (附带工业级防漏抗压与自适应设计)
// ==========================================
@interface ZoneRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isUnlocking; 
@property (nonatomic, strong) NSString *currentState;

@property (nonatomic, assign) NSInteger reloadGeneration; 

@property (nonatomic, strong) ZoneCAMLParser *bgParser;
@property (nonatomic, strong) ZoneCAMLParser *floatParser;
@property (nonatomic, strong) ZoneCAMLParser *fgParser;
@property (nonatomic, strong) NSMutableDictionary *bgLayerMap;
@property (nonatomic, strong) NSMutableDictionary *floatLayerMap;
@property (nonatomic, strong) NSMutableDictionary *fgLayerMap;

- (void)reloadWallpaperViews;
@end

@implementation ZoneRenderEngineView
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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// 【核心修复3】高能效智能缩放与方向翻转算法：解决 BlackHole 显示不全与 Emoji 倒立问题
- (void)adjustPackageViewSmartly:(BSUICAPackageView *)pkgView {
    if (!pkgView || !pkgView.layer) return;
    CALayer *rootLayer = pkgView.layer.sublayers.firstObject;
    if (!rootLayer) {
        if (!CGRectEqualToRect(pkgView.frame, self.bounds)) pkgView.frame = self.bounds;
        return;
    }
    
    CGRect docBounds = rootLayer.bounds;
    if (CGRectIsEmpty(docBounds)) {
        if (!CGRectEqualToRect(pkgView.frame, self.bounds)) pkgView.frame = self.bounds;
        return;
    }
    
    // 强制 PackageView 边界匹配 CAML 设计文档边界
    if (!CGRectEqualToRect(pkgView.bounds, docBounds)) {
        pkgView.bounds = docBounds;
    }
    
    // 居中放置
    CGPoint newCenter = CGPointMake(self.bounds.size.width / 2.0, self.bounds.size.height / 2.0);
    if (!CGPointEqualToPoint(pkgView.center, newCenter)) {
        pkgView.center = newCenter;
    }
    
    // 执行原生 Aspect Fill 缩放
    CGFloat scaleX = self.bounds.size.width / docBounds.size.width;
    CGFloat scaleY = self.bounds.size.height / docBounds.size.height;
    CGFloat scale = MAX(scaleX, scaleY);
    
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    
    // 探测图层源标记：如果标记了 geometryFlipped，则执行 Y轴无损翻转
    if (rootLayer.geometryFlipped) {
        transform = CGAffineTransformScale(transform, 1.0, -1.0);
    }
    
    if (!CGAffineTransformEqualToTransform(pkgView.transform, transform)) {
        pkgView.transform = transform;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self adjustPackageViewSmartly:self.bgView];
    [self adjustPackageViewSmartly:self.floatingView];
    [self adjustPackageViewSmartly:self.fgView];
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

- (void)ensureLayerMap:(NSMutableDictionary *)layerMap parser:(ZoneCAMLParser *)parser packageView:(BSUICAPackageView *)pkgView {
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

// 【核心修复4】跟手进度计算引擎更新：原生支持坐标/尺寸对象的极速差值运算
- (void)applyProgress:(double)progress parser:(ZoneCAMLParser *)parser layerMap:(NSDictionary *)layerMap {
    if (layerMap.count == 0 || !parser) return;
    [CATransaction begin]; 
    [CATransaction setDisableActions:YES]; 
    for (NSString *targetId in parser.statesData) {
        CALayer *layer = layerMap[targetId]; if (!layer) continue;
        NSDictionary *states = parser.statesData[targetId];
        NSDictionary *lockedVals = states[@"Locked"]; NSDictionary *unlockVals = states[@"Unlock"];
        if (!lockedVals || !unlockVals) continue;
        for (NSString *keyPath in lockedVals) {
            id lockVal = lockedVals[keyPath]; 
            id unlockVal = unlockVals[keyPath];
            if (lockVal && unlockVal) {
                @try {
                    if ([lockVal isKindOfClass:[NSNumber class]]) {
                        double currentVal = [lockVal doubleValue] + ([unlockVal doubleValue] - [lockVal doubleValue]) * progress;
                        [layer setValue:@(currentVal) forKeyPath:keyPath];
                    } else if ([lockVal isKindOfClass:[NSValue class]]) {
                        if (strcmp([lockVal objCType], @encode(CGPoint)) == 0) {
                            CGPoint p1 = [lockVal CGPointValue];
                            CGPoint p2 = [unlockVal CGPointValue];
                            CGPoint cur = CGPointMake(p1.x + (p2.x - p1.x)*progress, p1.y + (p2.y - p1.y)*progress);
                            [layer setValue:[NSValue valueWithCGPoint:cur] forKeyPath:keyPath];
                        } else if (strcmp([lockVal objCType], @encode(CGSize)) == 0) {
                            CGSize s1 = [lockVal CGSizeValue];
                            CGSize s2 = [unlockVal CGSizeValue];
                            CGSize cur = CGSizeMake(s1.width + (s2.width - s1.width)*progress, s1.height + (s2.height - s1.height)*progress);
                            [layer setValue:[NSValue valueWithCGSize:cur] forKeyPath:keyPath];
                        }
                    }
                } @catch (NSException *e) {}
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

// 内存清理方法独立封装，必须在主线程被调用
- (void)clearCurrentViewsSafely {
    [self.bgView removeFromSuperview]; self.bgView = nil;
    [self.floatingView removeFromSuperview]; self.floatingView = nil;
    [self.fgView removeFromSuperview]; self.fgView = nil;
    
    [self.bgLayerMap removeAllObjects];
    [self.floatLayerMap removeAllObjects];
    [self.fgLayerMap removeAllObjects];
    
    self.bgParser = nil; 
    self.floatParser = nil; 
    self.fgParser = nil;
}

// 采用严苛的异步预处理 + 同步阻断丢弃方案防漏抗压
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
        __block NSString *foundBg = nil;
        __block NSString *foundFloat = nil;
        __block NSString *foundFg = nil;
        
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:g_zonePath];
        NSString *subPath;
        while ((subPath = [dirEnum nextObject])) {
            if ([subPath containsString:@"__MACOSX"]) {
                [dirEnum skipDescendants];
                continue;
            }
            
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
            
            void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
            if (!handle) return; 
            Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
            if (!PackageViewClass) return;
            
            @autoreleasepool {
                if (foundBg) {
                    self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:foundBg]];
                    if (self.bgView) {
                        [self addSubview:self.bgView];
                        self.bgParser = [ZoneCAMLParser new]; 
                        [self.bgParser parseFile:[foundBg stringByAppendingPathComponent:@"main.caml"]];
                    }
                }
                if (foundFloat) {
                    self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:foundFloat]];
                    if (self.floatingView) {
                        [self addSubview:self.floatingView];
                        self.floatParser = [ZoneCAMLParser new]; 
                        [self.floatParser parseFile:[foundFloat stringByAppendingPathComponent:@"main.caml"]];
                    }
                }
                if (foundFg) {
                    self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:foundFg]];
                    if (self.fgView) {
                        [self addSubview:self.fgView];
                        self.fgParser = [ZoneCAMLParser new]; 
                        [self.fgParser parseFile:[foundFg stringByAppendingPathComponent:@"main.caml"]];
                    }
                }
            }
            
            [self setNeedsLayout];
            [self layoutIfNeeded]; // 强制立即计算一次布局防闪烁
            self.currentState = @"Init";
            [CATransaction begin]; [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO]; [CATransaction commit]; [CATransaction flush];
        });
    });
}
@end

static void EnsureEngineViewIsMounted() {
    if (!g_enabled) return;
    id wallpaperController = [%c(SBWallpaperController) sharedInstance];
    if (!wallpaperController) return;
    
    UIView *targetContainer = [wallpaperController valueForKey:@"_wallpaperWindow"];
    if (!targetContainer) targetContainer = [wallpaperController valueForKey:@"_wallpaperContainerView"];
    if (!targetContainer) return;
    
    ZoneRenderEngineView *engineView = objc_getAssociatedObject(wallpaperController, "GlobalZoneEngine");
    if (!engineView) {
        engineView = [[ZoneRenderEngineView alloc] initWithFrame:targetContainer.bounds];
        objc_setAssociatedObject(wallpaperController, "GlobalZoneEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

- (void)_scrollPanGestureBegan:(id)arg1 {
    %orig;
    if (g_enabled) {
        [self viewWillLayoutSubviews];
    }
}

- (void)_scrollPanGestureChanged:(id)arg1 {
    %orig;
    if (g_enabled) {
        [self viewWillLayoutSubviews];
    }
}

- (void)_scrollPanGestureEnded:(id)arg1 {
    %orig;
    if (g_enabled) {
        [self viewWillLayoutSubviews];
    }
}

- (void)viewWillLayoutSubviews {
    %orig;
    EnsureEngineViewIsMounted(); 
    
    if (g_enabled) {
        UIViewController *bgVC = [self valueForKey:@"_backgroundContentViewController"];
        if (bgVC && bgVC.view) {
            bgVC.view.alpha = 1.0;
            bgVC.view.hidden = NO;
        }
        
        id wallpaperController = [%c(SBWallpaperController) sharedInstance];
        ZoneRenderEngineView *engineView = objc_getAssociatedObject(wallpaperController, "GlobalZoneEngine");
        
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
            
            @try {
                UIView *dimmingView = [self valueForKey:@"_dimmingView"];
                if (dimmingView) { dimmingView.alpha = 0.0; dimmingView.hidden = YES; }
                
                UIView *tintingView = [self valueForKey:@"_tintingView"];
                if (tintingView) { tintingView.alpha = 0.0; tintingView.hidden = YES; }
            } @catch(NSException* e) {}
        }
        
        UIView *floatingLayer = [self valueForKey:@"_floatingLayerView"];
        if (floatingLayer) { 
            floatingLayer.alpha = 0.0; 
            floatingLayer.hidden = YES; 
        }
    }
}

- (void)_updateWallpaperFloatingLayerContainerView {
    %orig;
    if (g_enabled) {
        UIView *floatingLayer = [self valueForKey:@"_floatingLayerView"];
        if (floatingLayer) {
            floatingLayer.hidden = YES;
            floatingLayer.alpha = 0.0;
        }
    }
}

- (void)_updateFloatingLayerOrdering {
    %orig;
    if (g_enabled) {
        UIView *floatingLayer = [self valueForKey:@"_floatingLayerView"];
        if (floatingLayer) {
            floatingLayer.hidden = YES;
            floatingLayer.alpha = 0.0;
        }
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (g_enabled) {
        [self viewWillLayoutSubviews];
    }
}

- (void)_updateBackgroundContentView { %orig; if (g_enabled) [self viewWillLayoutSubviews]; }
- (void)_updateWallpaperEffectView { %orig; if (g_enabled) [self viewWillLayoutSubviews]; }
- (void)_updateWallpaper { %orig; if (g_enabled) [self viewWillLayoutSubviews]; }
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

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled && g_isScreenOn) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZoneEngineStateChange" object:nil userInfo:@{@"state": state}];
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

%hook CSBackgroundContentView
- (void)layoutSubviews {
    %orig;
    if (g_enabled) {
        UIView *presentationView = [self valueForKey:@"presentationView"];
        if (presentationView) {
            presentationView.hidden = YES;
            presentationView.alpha = 0.0;
        }
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
}
