#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h> 

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 辅助宏：强制主线程执行，防止底层动画队列崩溃 (SIGABRT)
// ==========================================
#define EXEC_ON_MAIN(block) \
    if ([NSThread isMainThread]) { \
        block(); \
    } else { \
        dispatch_async(dispatch_get_main_queue(), block); \
    }

// ==========================================
// 接口声明区
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
@property (retain, nonatomic) UIViewController *backgroundContentViewController; // iOS 16+ 原生海报容器
- (void)setInScreenOffMode:(BOOL)mode;
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source;
@end

@interface PBUIWallpaperView : UIView
@property (nonatomic, assign) NSInteger variant;
@end

@interface SBFWallpaperView : UIView
@property (nonatomic, assign) NSInteger variant;
@end

// ==========================================
// 全局变量与路径
// ==========================================
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【替换真实 bundleID】
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
// 核心视图类
// ==========================================
@interface TendiesView : UIView
@property (nonatomic, strong) NSMutableArray *camlLayers;
@property (nonatomic, strong) NSMutableArray *stateControllers;
@property (nonatomic, strong) NSString *currentState;
@property (nonatomic, assign) BOOL isScrubbing;

- (void)loadTendiesFromPath:(NSString *)path;
- (void)setState:(NSString *)state;
- (void)beginScrubbingUnlock;
- (void)updateScrubbingProgress:(CGFloat)progress;
- (void)endScrubbingWithVelocityY:(CGFloat)velocityY;
@end

@implementation TendiesView
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.camlLayers = [NSMutableArray array];
        self.stateControllers = [NSMutableArray array];
        self.userInteractionEnabled = NO; 
        self.backgroundColor = [UIColor blackColor]; 
        self.isScrubbing = NO;
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
    for (CALayer *layer in self.camlLayers) {
        layer.frame = self.bounds;
    }
}

- (void)setState:(NSString *)state {
    if (!state || [self.currentState isEqualToString:state]) return;
    self.currentState = state;
    
    self.layer.speed = 1.0;
    self.isScrubbing = NO;
    
    for (int i = 0; i < self.camlLayers.count; i++) {
        CAStateController *sc = self.stateControllers[i];
        CALayer *layer = self.camlLayers[i];
        [sc setState:state ofLayer:layer];
    }
}

// --- 物理级搓动核心逻辑 ---
- (void)beginScrubbingUnlock {
    if (self.isScrubbing) return; 
    self.isScrubbing = YES;
    
    self.layer.speed = 0.0;
    self.layer.timeOffset = 0.0;
    self.layer.beginTime = 0.0;
    
    [self setState:@"Unlock"];
    self.layer.speed = 0.0; 
    self.isScrubbing = YES; 
}

- (void)updateScrubbingProgress:(CGFloat)progress {
    self.layer.timeOffset = MAX(0.0, MIN(1.0, progress)) * 0.8;
}

- (void)endScrubbingWithVelocityY:(CGFloat)velocityY {
    if (!self.isScrubbing) return;
    self.isScrubbing = NO;
    
    // 松手时，让系统原生的 CoreAnimation 接管剩余的动画，完美自然！
    CFTimeInterval pausedTime = self.layer.timeOffset;
    self.layer.speed = 1.0;
    self.layer.timeOffset = 0.0;
    self.layer.beginTime = 0.0;
    CFTimeInterval timeSincePause = [self.layer convertTime:CACurrentMediaTime() fromLayer:nil] - pausedTime;
    self.layer.beginTime = timeSincePause;
    
    if (velocityY > 0) {
        [self setState:@"Locked"];
    }
}
@end

// ==========================================
// 注入逻辑：按容器智能挂载与防重入
// ==========================================
static BOOL isInjecting = NO;

static void injectTendiesSmart(UIView *container, BOOL isLockScreen) {
    if (!container || !container.window) return;
    if (isInjecting) return; 
    
    isInjecting = YES;
    
    TendiesView *tView = objc_getAssociatedObject(container, "TendiesView");
    if (!tView) {
        tView = [[TendiesView alloc] initWithFrame:container.bounds];
        tView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        
        [container addSubview:tView];
        
        objc_setAssociatedObject(container, "TendiesView", tView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        @synchronized(g_allTendiesViews) {
            if (!g_allTendiesViews) g_allTendiesViews = [NSHashTable weakObjectsHashTable];
            [g_allTendiesViews addObject:tView];
        }
        
        [tView loadTendiesFromPath:g_tendiesPath];
    } else {
        tView.frame = container.bounds;
    }
    
    if (tView.superview != container) {
        [container addSubview:tView];
    }
    
    if (isLockScreen) {
        // 如果是锁屏控制器，插入到最底层，充当背景
        [container insertSubview:tView atIndex:0];
    } else {
        // 如果是桌面 (PBUIWallpaperView)，提到最高层并遮挡原生
        [container bringSubviewToFront:tView]; 
        if ([container isKindOfClass:NSClassFromString(@"PBUIWallpaperView")]) {
            for (UIView *subview in container.subviews) {
                if (subview != tView && ![subview isKindOfClass:[TendiesView class]]) {
                    subview.hidden = YES;
                    subview.userInteractionEnabled = NO;
                }
            }
        }
    }
    
    isInjecting = NO;
}

static void reloadPrefsAndInject() {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
    g_enabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : YES;
    g_tendiesPath = dict[@"TendiesPath"] ?: @"";
    
    EXEC_ON_MAIN(^{
        @synchronized(g_allTendiesViews) {
            for (TendiesView *tView in g_allTendiesViews) {
                [tView loadTendiesFromPath:g_tendiesPath];
            }
        }
    });
}

// ==========================================
// 动态 Hook 注入区
// ==========================================
%group UniversalWallpaper

// --- iOS 14-15 底图挂载 ---
%hook SBFWallpaperView
- (void)didMoveToWindow {
    %orig;
    if ([self respondsToSelector:@selector(variant)] && self.variant == 0) {
        EXEC_ON_MAIN(^{ injectTendiesSmart(self, NO); });
    }
}
- (void)layoutSubviews {
    %orig;
    if ([self respondsToSelector:@selector(variant)] && self.variant == 0) {
        EXEC_ON_MAIN(^{ injectTendiesSmart(self, NO); });
    }
}
%end

// --- 锁屏状态追踪 (全版本通用) ---
%hook CSCoverSheetViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    EXEC_ON_MAIN(^{
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) [v setState:@"Locked"];
        }
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    EXEC_ON_MAIN(^{
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) [v setState:@"Unlock"];
        }
    });
}

// 解决“平时看不见”：iOS 16+ 隐藏原生海报背景，露出底层 Tendies
- (void)viewDidLayoutSubviews {
    %orig;
    EXEC_ON_MAIN(^{
        if ([self respondsToSelector:@selector(backgroundContentViewController)]) {
            UIViewController *bgVC = [self valueForKey:@"backgroundContentViewController"];
            if (bgVC && bgVC.view) {
                bgVC.view.hidden = YES;
                bgVC.view.alpha = 0.0;
            }
        }
        // 直接在锁屏主视图挂载，充当完美背景层
        injectTendiesSmart(self.view, YES);
    });
}

// [仅限 iOS 14-15] 拦截手势
- (void)_scrollPanGestureBegan:(UIPanGestureRecognizer *)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        EXEC_ON_MAIN(^{
            @synchronized(g_allTendiesViews) {
                for (TendiesView *v in g_allTendiesViews) [v beginScrubbingUnlock];
            }
        });
    }
}

- (void)_scrollPanGestureChanged:(UIPanGestureRecognizer *)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGFloat translationY = [arg translationInView:arg.view].y;
        CGFloat viewHeight = arg.view.bounds.size.height ?: 844.0;
        CGFloat progress = MAX(0.0, MIN(1.0, -translationY / viewHeight));
        EXEC_ON_MAIN(^{
            @synchronized(g_allTendiesViews) {
                for (TendiesView *v in g_allTendiesViews) [v updateScrubbingProgress:progress];
            }
        });
    }
}

- (void)_scrollPanGestureEnded:(UIPanGestureRecognizer *)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGFloat velocityY = [arg velocityInView:arg.view].y;
        EXEC_ON_MAIN(^{
            @synchronized(g_allTendiesViews) {
                for (TendiesView *v in g_allTendiesViews) [v endScrubbingWithVelocityY:velocityY];
            }
        });
    }
}

// 息屏/亮屏触发器
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *newState = mode ? @"Sleep" : @"Locked";
    EXEC_ON_MAIN(^{
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) [v setState:newState];
        }
    });
}

- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
    %orig;
    NSString *newState = mode ? @"Sleep" : @"Locked";
    EXEC_ON_MAIN(^{
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) [v setState:newState];
        }
    });
}
%end
%end // UniversalWallpaper


// --- iOS 16-17 核心逻辑 ---
%group iOS16Up

// 桌面背景 (Variant 1) 处理
%hook PBUIWallpaperView
- (void)didMoveToWindow {
    %orig;
    // 只有桌面底图才需要处理
    if (self.variant == 1) {
        EXEC_ON_MAIN(^{ injectTendiesSmart(self, NO); });
    }
}
- (void)layoutSubviews {
    %orig;
    if (self.variant == 1) {
        EXEC_ON_MAIN(^{ injectTendiesSmart(self, NO); });
    }
}
%end

// 解决“交互残缺/冻结”：拦截真正的原生理引擎手势进行映射
%hook SBCoverSheetSlidingViewController

- (void)_dismissGestureBeganWithGestureRecognizer:(UIPanGestureRecognizer *)recognizer {
    %orig;
    EXEC_ON_MAIN(^{
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) [v beginScrubbingUnlock];
        }
    });
}

- (void)_dismissGestureChangedWithGestureRecognizer:(UIPanGestureRecognizer *)recognizer {
    %orig;
    if ([recognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGFloat translationY = [recognizer translationInView:recognizer.view].y;
        CGFloat viewHeight = recognizer.view.bounds.size.height ?: 844.0;
        // iOS 16+ 向上滑动 translationY 为负
        CGFloat progress = MAX(0.0, MIN(1.0, -translationY / viewHeight));
        EXEC_ON_MAIN(^{
            @synchronized(g_allTendiesViews) {
                for (TendiesView *v in g_allTendiesViews) [v updateScrubbingProgress:progress];
            }
        });
    }
}

// 统一的松手结束回调：让动画引擎恢复 1.0 速度走完后续回弹
- (void)_presentOrDismissGestureEndedWithGestureRecognizer:(UIPanGestureRecognizer *)recognizer {
    %orig;
    if ([recognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGFloat velocityY = [recognizer velocityInView:recognizer.view].y;
        EXEC_ON_MAIN(^{
            @synchronized(g_allTendiesViews) {
                for (TendiesView *v in g_allTendiesViews) [v endScrubbingWithVelocityY:velocityY];
            }
        });
    }
}

%end
%end // iOS16Up

// ==========================================
// 初始化与热重载
// ==========================================
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefsAndInject();
}

%ctor {
    reloadPrefsAndInject();
    
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        
        dlopen("/System/Library/PrivateFrameworks/PaperBoardUI.framework/PaperBoardUI", RTLD_NOW);
        
        %init(UniversalWallpaper);
        
        if (NSClassFromString(@"PBUIWallpaperView")) {
            %init(iOS16Up);
        }
    }
}
