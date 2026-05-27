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
- (void)setState:(id)state ofLayer:(id)layer transitionSpeed:(float)speed;
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

// 【核心新增】全局状态共享器。保证锁屏和桌面的壁纸动画永远在同一状态！
static NSString *g_currentGlobalState = @"Locked";

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
- (void)loadTendiesFromPath:(NSString *)path;
- (void)setState:(NSString *)state;
@end

@implementation TendiesView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.camlLayers = [NSMutableArray array];
        self.stateControllers = [NSMutableArray array];
        self.userInteractionEnabled = NO; 
        self.backgroundColor = [UIColor blackColor]; // 用纯黑背景物理遮盖原壁纸，防走光
    }
    return self;
}

// 【核心新增】递归解冻所有被系统或包打包器强行暂停的图层动画
- (void)unpauseAllAnimations:(CALayer *)layer {
    layer.speed = 1.0;
    layer.timeOffset = 0.0;
    layer.beginTime = 0.0;
    for (CALayer *sub in layer.sublayers) {
        [self unpauseAllAnimations:sub];
    }
}

- (void)loadTendiesFromPath:(NSString *)path {
    for (CALayer *layer in self.camlLayers) {
        [layer removeFromSuperlayer];
    }
    [self.camlLayers removeAllObjects];
    [self.stateControllers removeAllObjects];

    if (!g_enabled || path.length == 0) {
        self.hidden = YES;
        return;
    }
    self.hidden = NO;

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
                    
                    // 强制解冻该包下的所有动画图层
                    [self unpauseAllAnimations:layer];
                    
                    [self.layer addSublayer:layer];
                    [self.camlLayers addObject:layer];

                    CAStateController *sc = [[NSClassFromString(@"CAStateController") alloc] initWithLayer:layer];
                    [self.stateControllers addObject:sc];
                }
            }
        }
    }
    // 加载完成后立刻同步到全局状态
    [self setState:g_currentGlobalState];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (CALayer *layer in self.camlLayers) {
        layer.frame = self.bounds;
    }
}

// 【核心修复】引入 CATransaction 和 transitionSpeed，强制执行 CAML 交互动画
- (void)setState:(NSString *)state {
    if (!state || [self.currentState isEqualToString:state]) return;
    self.currentState = state;
    
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.8]; // 匹配 main.caml 中的默认回弹持续时间
    
    for (int i = 0; i < self.camlLayers.count; i++) {
        CAStateController *sc = self.stateControllers[i];
        CALayer *layer = self.camlLayers[i];
        
        // 再次确保运行速度为正常速度
        layer.speed = 1.0;
        
        if ([sc respondsToSelector:@selector(setState:ofLayer:transitionSpeed:)]) {
            [sc setState:state ofLayer:layer transitionSpeed:1.0];
        } else {
            [sc setState:state ofLayer:layer];
        }
    }
    
    [CATransaction commit];
}
@end

// ==========================================
// 注入与驱动逻辑
// ==========================================
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

// 【终极挂载策略】直接挂载到 SBWallpaperWindow，横扫一切 iOS 16/17 的模糊遮罩与 PosterKit 视图！
static void injectGlobalTendies(UIView *wallpaperView) {
    if (!wallpaperView || !wallpaperView.window) return;
    
    UIWindow *win = wallpaperView.window;
    
    TendiesView *tView = objc_getAssociatedObject(win, "GlobalTendiesView");
    if (!tView) {
        tView = [[TendiesView alloc] initWithFrame:win.bounds];
        tView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        
        // 关键点：99999 zPosition 强行置顶，完全覆盖原壁纸系统的所有作妖图层！
        tView.layer.zPosition = 99999; 
        
        // 直接添加到 Window 上，而不是 View 里，彻底免疫内部层级刷新
        [win addSubview:tView];
        objc_setAssociatedObject(win, "GlobalTendiesView", tView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        @synchronized(g_allTendiesViews) {
            if (!g_allTendiesViews) g_allTendiesViews = [NSHashTable weakObjectsHashTable];
            [g_allTendiesViews addObject:tView];
        }
        
        [tView loadTendiesFromPath:g_tendiesPath];
    }
    
    // 确保我们永远在最顶端
    [win bringSubviewToFront:tView];
    tView.frame = win.bounds;
    
    // 隐藏系统原有的壁纸渲染，防止透底和节省性能
    wallpaperView.alpha = 0.0;
    wallpaperView.hidden = YES;
}

// ==========================================
// 动态 Hook 注入区
// ==========================================

%group UniversalWallpaper

// --- 底层壁纸容器注入 (iOS 14-15) ---
%hook SBFWallpaperView
- (void)didMoveToWindow {
    %orig;
    injectGlobalTendies(self);
}
- (void)layoutSubviews {
    %orig;
    injectGlobalTendies(self);
}
%end

// --- 交互手势驱动区 ---
// 只负责向底层的 TendiesView 传递解锁状态，让它自己播放飞出动画！
%hook CSCoverSheetViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    g_currentGlobalState = @"Locked";
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) [v setState:g_currentGlobalState];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    g_currentGlobalState = @"Unlock";
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) [v setState:g_currentGlobalState];
    }
}

// 截取上滑手势，瞬间触发壁纸的互动动画（例如马里奥飞出）
- (void)_scrollPanGestureChanged:(id)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        UIPanGestureRecognizer *gesture = (UIPanGestureRecognizer *)arg;
        CGPoint translation = [gesture translationInView:gesture.view];
        
        // 监测到明显上滑（阈值-20），立刻触发 Unlock 动画，提供极致跟手的互动感
        if (translation.y < -20) { 
            if (![g_currentGlobalState isEqualToString:@"Unlock"]) {
                g_currentGlobalState = @"Unlock";
                @synchronized(g_allTendiesViews) {
                    for (TendiesView *v in g_allTendiesViews) [v setState:g_currentGlobalState];
                }
            }
        }
    }
}

// 防止手势取消（滑到一半松手），动画弹回锁屏状态
- (void)_scrollPanGestureEnded:(id)arg {
    %orig;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf && weakSelf.view.window && !weakSelf.isTransitioning) {
            g_currentGlobalState = @"Locked";
            @synchronized(g_allTendiesViews) {
                for (TendiesView *v in g_allTendiesViews) [v setState:g_currentGlobalState];
            }
        }
    });
}

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    g_currentGlobalState = mode ? @"Sleep" : @"Locked";
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) [v setState:g_currentGlobalState];
    }
}
%end
%end // UniversalWallpaper


// --------------------------------------------------
// iOS 16-17 桌面特有注入 (PosterKit 时代)
// --------------------------------------------------
%group iOS16Up

// --- 底层壁纸容器注入 (iOS 16-17) ---
%hook PBUIWallpaperView
- (void)didMoveToWindow {
    %orig;
    injectGlobalTendies(self);
}
- (void)layoutSubviews {
    %orig;
    injectGlobalTendies(self);
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
