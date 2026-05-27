#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h> // 用于动态加载 iOS 16 框架

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 接口声明区 (继承自 UIView，100% 消除属性报错)
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

// 必须继承 UIView，让编译器知道它们具备 frame/bounds/window 属性
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
// 核心视图类 (加入原生 Scrubbing 物理搓动机制)
// ==========================================
@interface TendiesView : UIView
@property (nonatomic, strong) NSMutableArray *camlLayers;
@property (nonatomic, strong) NSMutableArray *stateControllers;
@property (nonatomic, strong) NSString *currentState;
- (void)loadTendiesFromPath:(NSString *)path;
- (void)setState:(NSString *)state;

// 新增物理搓动接口
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
        self.backgroundColor = [UIColor blackColor]; // 用黑底彻底物理盖死原生壁纸
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
    
    // 恢复正常播放速度
    self.layer.speed = 1.0;
    
    for (int i = 0; i < self.camlLayers.count; i++) {
        CAStateController *sc = self.stateControllers[i];
        CALayer *layer = self.camlLayers[i];
        [sc setState:state ofLayer:layer];
    }
}

// --- 物理级搓动核心逻辑 ---
- (void)beginScrubbingUnlock {
    // 冻结时间轴
    self.layer.speed = 0.0;
    self.layer.timeOffset = 0.0;
    self.layer.beginTime = 0.0;
    // 触发解锁状态，此时动画停在第 0 帧
    [self setState:@"Unlock"];
    self.layer.speed = 0.0; // 再次强制冻结
}

- (void)updateScrubbingProgress:(CGFloat)progress {
    // CAML中的解锁动画通常为 0.8 秒，所以将进度映射到 0.0 ~ 0.8
    self.layer.timeOffset = progress * 0.8;
}

- (void)endScrubbingWithVelocityY:(CGFloat)velocityY {
    // 松手时，恢复时间轴让其继续播放完成
    CFTimeInterval pausedTime = self.layer.timeOffset;
    self.layer.speed = 1.0;
    self.layer.timeOffset = 0.0;
    self.layer.beginTime = 0.0;
    CFTimeInterval timeSincePause = [self.layer convertTime:CACurrentMediaTime() fromLayer:nil] - pausedTime;
    self.layer.beginTime = timeSincePause;
    
    // 如果是向下滑动(反悔操作)，让其弹回 Locked
    if (velocityY > 0) {
        [self setState:@"Locked"];
    }
}
@end

// ==========================================
// 注入逻辑：按容器分别挂载，拒绝撕裂
// ==========================================
static void injectTendiesSmart(UIView *container) {
    if (!container || !container.window) return;
    
    TendiesView *tView = objc_getAssociatedObject(container, "TendiesView");
    if (!tView) {
        tView = [[TendiesView alloc] initWithFrame:container.bounds];
        tView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        
        [container addSubview:tView];
        [container bringSubviewToFront:tView]; // 永远在原生背景前
        
        objc_setAssociatedObject(container, "TendiesView", tView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        @synchronized(g_allTendiesViews) {
            if (!g_allTendiesViews) g_allTendiesViews = [NSHashTable weakObjectsHashTable];
            [g_allTendiesViews addObject:tView];
        }
        
        [tView loadTendiesFromPath:g_tendiesPath];
    } else {
        tView.frame = container.bounds;
        [container bringSubviewToFront:tView];
    }
}

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
// 动态 Hook 注入区
// ==========================================
%group UniversalWallpaper

// --- iOS 14-15 底图挂载 ---
%hook SBFWallpaperView
- (void)didMoveToWindow {
    %orig;
    injectTendiesSmart((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    injectTendiesSmart((UIView *)self);
}
%end

// --- 锁屏互动追踪 (完美跟手) ---
%hook CSCoverSheetViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) [v setState:@"Locked"];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) [v setState:@"Unlock"];
    }
}

// 拦截手势：手指刚放上去，冻结时间准备搓动
- (void)_scrollPanGestureBegan:(UIPanGestureRecognizer *)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) [v beginScrubbingUnlock];
        }
    }
}

// 拦截手势：手指正在滑，实时映射物理进度
- (void)_scrollPanGestureChanged:(UIPanGestureRecognizer *)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGFloat translationY = [arg translationInView:arg.view].y;
        CGFloat viewHeight = arg.view.bounds.size.height ?: 844.0;
        
        // 向上滑动 translationY 为负数。将其映射为 0.0 ~ 1.0 的百分比进度
        CGFloat progress = MAX(0.0, MIN(1.0, -translationY / viewHeight));
        
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) [v updateScrubbingProgress:progress];
        }
    }
}

// 拦截手势：手指松开，恢复自然播放或弹回
- (void)_scrollPanGestureEnded:(UIPanGestureRecognizer *)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGFloat velocityY = [arg velocityInView:arg.view].y;
        @synchronized(g_allTendiesViews) {
            for (TendiesView *v in g_allTendiesViews) [v endScrubbingWithVelocityY:velocityY];
        }
    }
}

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *newState = mode ? @"Sleep" : @"Locked";
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) [v setState:newState];
    }
}
%end
%end // UniversalWallpaper


// --- iOS 16-17 底图挂载 ---
%group iOS16Up
%hook PBUIWallpaperView
- (void)didMoveToWindow {
    %orig;
    injectTendiesSmart((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    injectTendiesSmart((UIView *)self);
}
%end
%end // iOS16Up

// ==========================================
// 初始化与热重载
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
        
        // 【关键】iOS 16+ PaperBoardUI 是懒加载的，必须手动 dlopen 唤醒才能成功 Hook！
        dlopen("/System/Library/PrivateFrameworks/PaperBoardUI.framework/PaperBoardUI", RTLD_NOW);
        
        %init(UniversalWallpaper);
        
        if (NSClassFromString(@"PBUIWallpaperView")) {
            %init(iOS16Up);
        }
    }
}
