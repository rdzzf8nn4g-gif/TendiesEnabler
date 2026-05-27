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
- (void)loadTendiesFromPath:(NSString *)path;
- (void)setState:(NSString *)state;
@end

@implementation TendiesView
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.camlLayers = [NSMutableArray array];
        self.stateControllers = [NSMutableArray array];
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor blackColor]; 
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
    self.layer.speed = 1.0; 
    for (CALayer *layer in self.camlLayers) {
        layer.frame = self.bounds;
        layer.speed = 1.0; 
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
@end

// ==========================================
// 单例管理器 (彻底终结双壁纸割裂 Bug)
// ==========================================
@interface TendiesManager : NSObject
@property (nonatomic, strong) TendiesView *globalTendiesView;
+ (instancetype)shared;
- (void)injectIntoGlobalContainer:(UIView *)container;
- (void)setState:(NSString *)state;
- (void)reloadPath;
@end

@implementation TendiesManager
+ (instancetype)shared {
    static TendiesManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TendiesManager alloc] init];
    });
    return instance;
}

- (void)reloadPath {
    if (self.globalTendiesView) {
        [self.globalTendiesView loadTendiesFromPath:g_tendiesPath];
    }
}

- (void)setState:(NSString *)state {
    if (self.globalTendiesView) {
        [self.globalTendiesView setState:state];
    }
}

- (void)injectIntoGlobalContainer:(UIView *)container {
    if (!container) return;
    
    if (!self.globalTendiesView) {
        self.globalTendiesView = [[TendiesView alloc] initWithFrame:container.bounds];
        self.globalTendiesView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.globalTendiesView loadTendiesFromPath:g_tendiesPath];
    }
    
    if (self.globalTendiesView.superview != container) {
        [self.globalTendiesView removeFromSuperview];
        self.globalTendiesView.frame = container.bounds;
        // 强制插入最底层
        [container insertSubview:self.globalTendiesView atIndex:0];
    }
}
@end

static void reloadPrefsAndInject() {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
    g_enabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : YES;
    g_tendiesPath = dict[@"TendiesPath"] ?: @"";
    [[TendiesManager shared] reloadPath];
}

// ==========================================
// 动态 Hook 注入区
// ==========================================

%group UniversalHooks

// --- iOS 16/17: 全局壁纸母体控制器注入 ---
%hook PBUIWallpaperViewController
- (void)viewDidLayoutSubviews {
    %orig;
    [[TendiesManager shared] injectIntoGlobalContainer:self.view];
    
    // 优雅隐身：不干掉对象，仅让原生壁纸变透明，确保 TendiesView 露出，同时不破坏图标高斯模糊取样
    if ([self respondsToSelector:@selector(homescreenWallpaperView)]) {
        ((UIView *)self.homescreenWallpaperView).alpha = g_enabled ? 0.0 : 1.0;
    }
    if ([self respondsToSelector:@selector(lockscreenWallpaperView)]) {
        ((UIView *)self.lockscreenWallpaperView).alpha = g_enabled ? 0.0 : 1.0;
    }
    if ([self respondsToSelector:@selector(sharedWallpaperView)]) {
        ((UIView *)self.sharedWallpaperView).alpha = g_enabled ? 0.0 : 1.0;
    }
}
%end

// --- iOS 14/15: 经典壁纸母体注入 ---
%hook SBWallpaperController
- (void)_updateWallpaperForLocations:(long long)locations {
    %orig;
    UIView *container = [self valueForKey:@"_wallpaperContainerView"];
    if (container) {
        [[TendiesManager shared] injectIntoGlobalContainer:container];
        
        UIView *hs = [self valueForKey:@"_homescreenWallpaperView"];
        UIView *ls = [self valueForKey:@"_lockscreenWallpaperView"];
        UIView *sh = [self valueForKey:@"_sharedWallpaperView"];
        if (hs) hs.alpha = g_enabled ? 0.0 : 1.0;
        if (ls) ls.alpha = g_enabled ? 0.0 : 1.0;
        if (sh) sh.alpha = g_enabled ? 0.0 : 1.0;
    }
}
%end

// --- 交互手势驱动区 (重构物理触发时机) ---
%hook CSCoverSheetViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[TendiesManager shared] setState:@"Locked"];
}

// 移除原来的 _scrollPanGestureBegan 触发，避免没松手就飞天
- (void)_scrollPanGestureBegan:(id)arg {
    %orig;
}

// 完美物理交互核心：仅当手势结束且带有足够大的上滑速度时，才触发解锁物理弹簧动画
- (void)_scrollPanGestureEnded:(id)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        UIPanGestureRecognizer *gesture = (UIPanGestureRecognizer *)arg;
        CGPoint velocity = [gesture velocityInView:gesture.view];
        
        // velocity.y 为负数代表正在向上发力滑动解锁
        if (velocity.y < -200 || self.isTransitioning) { 
            [[TendiesManager shared] setState:@"Unlock"];
        } else {
            // 滑动取消（弹回锁屏）
            [[TendiesManager shared] setState:@"Locked"];
        }
    }
}

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (mode) {
        [[TendiesManager shared] setState:@"Sleep"];
    } else {
        [[TendiesManager shared] setState:@"Locked"];
    }
}
%end
%end // UniversalHooks

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
        %init(UniversalHooks);
    }
}
