#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 接口与继承声明
// ==========================================
@interface CAPackage : NSObject
+ (id)packageWithContentsOfURL:(NSURL *)url type:(NSString *)type options:(NSDictionary *)options error:(NSError **)outError;
@end

@interface CAStateController : NSObject
@property (readonly) CALayer *layer;
- (id)initWithLayer:(id)layer;
- (void)setState:(id)state ofLayer:(id)layer;
@end

@interface CSCoverSheetViewController : UIViewController
@property (nonatomic, readonly) BOOL isTransitioning;
- (void)setInScreenOffMode:(BOOL)mode;
@end

@interface SBFWallpaperView : UIView
@end
@interface PBUIWallpaperView : UIView
@end

// ==========================================
// 全局变量与路径
// ==========================================
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【务必替换真实 bundleID】
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static NSHashTable *g_allTendiesViews = nil;
static NSString *g_tendiesPath = @"";
static BOOL g_enabled = YES;

static NSArray<NSURL *> *FindCAPackageURLsInTendies(NSString *basePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
    NSString *file;
    NSMutableArray *caURLs = [NSMutableArray array];

    while ((file = [enumerator nextObject])) {
        if ([file containsString:@"__MACOSX"] || [file.lastPathComponent hasPrefix:@"."]) continue;
        if ([file hasSuffix:@".ca"]) {
            NSString *caPath = [basePath stringByAppendingPathComponent:file];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:caPath isDirectory:&isDir] && isDir) {
                [caURLs addObject:[NSURL fileURLWithPath:caPath]];
            }
        }
    }

    [caURLs sortUsingComparator:^NSComparisonResult(NSURL *u1, NSURL *u2) {
        int w1 = [u1.path.lowercaseString containsString:@"background"] ? 0 : ([u1.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        int w2 = [u2.path.lowercaseString containsString:@"background"] ? 0 : ([u2.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        return (w1 < w2) ? NSOrderedAscending : ((w1 > w2) ? NSOrderedDescending : NSOrderedSame);
    }];
    return caURLs;
}

// ==========================================
// 核心视图类 (彻底重构：支持手势搓碟与接管)
// ==========================================
@interface TendiesView : UIView
@property (nonatomic, strong) NSMutableArray *camlLayers;
@property (nonatomic, strong) NSMutableArray *stateControllers;
@property (nonatomic, strong) NSString *currentState;
- (void)loadTendiesFromPath:(NSString *)path;
- (void)setState:(NSString *)state;
- (void)setAnimationProgress:(CGFloat)progress; // 新增：跟手进度
@end

@implementation TendiesView
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.camlLayers = [NSMutableArray array];
        self.stateControllers = [NSMutableArray array];
        self.userInteractionEnabled = NO; // 不阻挡底层触摸
        self.backgroundColor = [UIColor blackColor]; // 防透底
    }
    return self;
}

- (void)loadTendiesFromPath:(NSString *)path {
    for (CALayer *layer in self.camlLayers) {
        [layer removeFromSuperlayer];
    }
    [self.camlLayers removeAllObjects];
    [self.stateControllers removeAllObjects];

    if (!g_enabled || path.length == 0) return;

    NSArray *caURLs = FindCAPackageURLsInTendies(path);
    Class CAPackageClass = NSClassFromString(@"CAPackage");
    
    for (NSURL *url in caURLs) {
        if (CAPackageClass) {
            NSError *error = nil;
            id package = [CAPackageClass packageWithContentsOfURL:url type:@"com.apple.coreanimation-bundle" options:nil error:&error];
            if (package) {
                CALayer *layer = [package valueForKey:@"rootLayer"];
                if ([layer isKindOfClass:[CALayer class]]) {
                    layer.frame = self.bounds;
                    layer.masksToBounds = YES;
                    layer.allowsEdgeAntialiasing = YES;
                    
                    // 默认开启引擎
                    layer.speed = 1.0; 
                    
                    [self.layer addSublayer:layer];
                    [self.camlLayers addObject:layer];

                    CAStateController *sc = [[%c(CAStateController) alloc] initWithLayer:layer];
                    [self.stateControllers addObject:sc];
                    
                    if (self.currentState) {
                        [sc setState:self.currentState ofLayer:layer];
                    }
                }
            }
        }
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 修复：不要在这里强制设置 layer.speed = 1.0，否则会打断手势滑动时的 Scrubbing！
    for (CALayer *layer in self.camlLayers) {
        layer.frame = self.bounds;
    }
}

- (void)setState:(NSString *)state {
    if (!state || [self.currentState isEqualToString:state]) return;
    self.currentState = state;
    for (int i = 0; i < self.camlLayers.count; i++) {
        CAStateController *sc = self.stateControllers[i];
        CALayer *layer = self.camlLayers[i];
        [sc setState:state ofLayer:layer];
    }
}

// 核心修复：手势驱动动画进度 (Scrubbing)
- (void)setAnimationProgress:(CGFloat)progress {
    progress = MAX(0.0, MIN(1.0, progress));
    for (CALayer *layer in self.camlLayers) {
        // 暂停自动播放，完全交由代码控制进度
        layer.speed = 0.0;
        
        // 大多数 Tendies 的 Unlock 动画时长为 0.8s，这里映射时间线
        CGFloat totalDuration = 0.8; 
        layer.timeOffset = progress * totalDuration;
    }
}
@end

static void reloadPrefsAndInject() {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
    g_enabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : YES;
    g_tendiesPath = dict[@"TendiesPath"] ?: @"";
    
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) {
            [tView loadTendiesFromPath:g_tendiesPath];
        }
    }
}

// ==========================================
// 智能挂载器：仅挂载桌面，隔离并清理毛玻璃
// ==========================================
static void injectTendiesSmart(UIView *container, BOOL isLockscreen) {
    if (!container || !container.window) return;
    
    // 【核心修复 1】彻底废弃锁屏注入！避免两层壁纸重叠与滑动分离
    // 只允许原生壁纸层 (SBFWallpaperView/PBUIWallpaperView) 的注入
    if (isLockscreen) return;
    
    // 白名单隔离：干掉后台卡片出现壁纸的 Bug
    NSString *winClass = NSStringFromClass([container.window class]);
    if (![winClass containsString:@"WallpaperWindow"] && 
        ![winClass containsString:@"SecureWindow"]) {
        return; 
    }
    
    TendiesView *tView = objc_getAssociatedObject(container, "TendiesView");
    if (!tView) {
        tView = [[TendiesView alloc] initWithFrame:container.bounds];
        tView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        
        // 桌面：直接铺在最底层
        [container insertSubview:tView atIndex:0];
        
        objc_setAssociatedObject(container, "TendiesView", tView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        @synchronized(g_allTendiesViews) {
            if (!g_allTendiesViews) g_allTendiesViews = [NSHashTable weakObjectsHashTable];
            [g_allTendiesViews addObject:tView];
        }
        
        [tView loadTendiesFromPath:g_tendiesPath];
    } else {
        tView.frame = container.bounds;
        [container sendSubviewToBack:tView];
    }
    
    // 【核心修复 2】暴力干掉 iOS 16/17 桌面原生的纯色背景、模糊层或原生壁纸层
    // 让 TendiesView 得以透过遮罩显现
    for (UIView *sub in container.subviews) {
        if (sub == tView) continue;
        
        NSString *subClassName = NSStringFromClass([sub class]);
        if ([subClassName containsString:@"Effect"] || 
            [subClassName containsString:@"Blur"] ||
            [subClassName containsString:@"Poster"] ||
            [subClassName containsString:@"Legibility"]) {
            sub.hidden = YES;
            sub.alpha = 0.0;
        }
    }
}

// ==========================================
// 动态 Hook 注入区
// ==========================================

%group UniversalWallpaper

// --- 桌面壁纸注入 (iOS 14-15) ---
%hook SBFWallpaperView
- (void)didMoveToWindow {
    %orig;
    injectTendiesSmart(self, NO);
}
- (void)layoutSubviews {
    %orig;
    injectTendiesSmart(self, NO);
}
%end

// === 交互手势驱动核心 ===
// 这里控制的直接是底层唯一挂载的 TendiesView，视觉绝对不会脱节
%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) {
            for (CALayer *layer in v.camlLayers) layer.speed = 1.0;
            [v setState:@"Locked"];
        }
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) {
            for (CALayer *layer in v.camlLayers) layer.speed = 1.0;
            [v setState:@"Unlock"];
        }
    }
}

// 拦截上滑手势开始：重置状态准备 Scrubbing
- (void)_scrollPanGestureBegan:(id)arg {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) {
            // 强行挂上 Unlock 状态准备控制进度
            [v setState:@"Unlock"];
            for (CALayer *layer in v.camlLayers) layer.speed = 0.0;
        }
    }
}

// 【核心修复 3】拦截上滑手势变动：实时推算手势进度进行跟手动画
- (void)_scrollPanGestureChanged:(id)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        UIPanGestureRecognizer *gesture = (UIPanGestureRecognizer *)arg;
        
        CGPoint translation = [gesture translationInView:gesture.view];
        CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
        
        // 越往上滑（y负得越多），进度越接近 1.0
        CGFloat progress = MAX(0.0, MIN(1.0, fabs(translation.y) / screenHeight));
        
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) {
                [v setState:@"Unlock"];
                [v setAnimationProgress:progress];
            }
        }
    }
}

// 手势结束：根据滑动动量与最终位置决定回弹还是继续播完
- (void)_scrollPanGestureEnded:(id)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        UIPanGestureRecognizer *gesture = (UIPanGestureRecognizer *)arg;
        CGPoint velocity = [gesture velocityInView:gesture.view];
        
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) {
                // 恢复原生时间流逝
                for (CALayer *layer in v.camlLayers) layer.speed = 1.0;
                
                // 【修复点】：显式转换为 CALayer，防止编译错误
                CGFloat currentOffset = 0.0;
                CALayer *firstLayer = (CALayer *)v.camlLayers.firstObject;
                if (firstLayer) {
                    currentOffset = firstLayer.timeOffset;
                }
                
                // 判断：如果滑动速度够快，或者已经滑过了屏幕 40%，则继续解开
                if (velocity.y < -500 || currentOffset > 0.4) {
                    [v setState:@"Unlock"];
                } else {
                    // 否则回弹至锁定状态
                    [v setState:@"Locked"];
                }
            }
        }
    }
}

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *newState = mode ? @"Sleep" : @"Locked";
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) {
            for (CALayer *layer in v.camlLayers) layer.speed = 1.0;
            [v setState:newState];
        }
    }
}
%end
%end // UniversalWallpaper


// --------------------------------------------------
// iOS 16+ 桌面特有注入
// --------------------------------------------------
%group iOS16Up

%hook PBUIWallpaperView
- (void)didMoveToWindow {
    %orig;
    injectTendiesSmart(self, NO);
}
- (void)layoutSubviews {
    %orig;
    injectTendiesSmart(self, NO);
}
%end

%end // iOS16Up

// ==========================================
// 热重载通知中枢
// ==========================================
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        reloadPrefsAndInject();
    });
}

%ctor {
    reloadPrefsAndInject();
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        
        %init(UniversalWallpaper);
        
        if (NSClassFromString(@"PBUIWallpaperView")) {
            %init(iOS16Up);
        }
    }
}
