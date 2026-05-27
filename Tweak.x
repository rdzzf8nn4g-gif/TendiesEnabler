#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 完整接口声明（解决 forward declaration 报错）
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
- (void)setInScreenOffMode:(BOOL)mode;
@end

// iOS 16+ 专有的锁屏海报背景控制器
@interface CSBackgroundContentViewController : UIViewController
@end

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
- (UIView *)valueForKey:(NSString *)key;
@end

// ==========================================
// 全局变量与跨狱境路径适配
// ==========================================
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【务必替换为你真实的 bundleID】
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
- (void)loadTendiesFromPath:(NSString *)path;
- (void)setState:(NSString *)state;
@end

@implementation TendiesView
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.camlLayers = [NSMutableArray array];
        self.stateControllers = [NSMutableArray array];
        self.userInteractionEnabled = NO; // 必须为 NO，否则会阻断滑动解锁手势
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
    for (int i = 0; i < self.camlLayers.count; i++) {
        CAStateController *sc = self.stateControllers[i];
        CALayer *layer = self.camlLayers[i];
        [sc setState:state ofLayer:layer];
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

// 统一的最底层壁纸挂载器 (增加暴力隐藏原生壁纸逻辑)
static void injectTendiesIntoWallpaperContainer(UIView *container) {
    if (!container) return;
    
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
        [container bringSubviewToFront:tView];
        tView.frame = container.bounds;
    }
    
    // 【核心修复】强制隐藏同级的所有其他视图，彻底杜绝系统原生壁纸/海报在滑动过程中走光
    for (UIView *sub in container.subviews) {
        if (sub != tView && !sub.hidden) {
            sub.hidden = YES;
        }
    }
}

// ==========================================
// 动态 Hook 注入区
// ==========================================

%group UniversalWallpaper

// --------------------------------------------------
// 1. 桌面底层注入 (主要负责 iOS 14-15 全局，以及 16-17 桌面)
// --------------------------------------------------
%hook SBWallpaperController
- (void)_applicationDidFinishLaunching:(id)launching {
    %orig;
    UIView *container = [self valueForKey:@"_wallpaperContainerView"];
    injectTendiesIntoWallpaperContainer(container);
}
- (void)updateWallpaperForLocations:(long long)locations withCompletion:(id)completion {
    %orig;
    UIView *container = [self valueForKey:@"_wallpaperContainerView"];
    injectTendiesIntoWallpaperContainer(container);
}
- (void)setWallpaperHidden:(BOOL)hidden variant:(long long)variant reason:(id)reason {
    %orig;
    UIView *container = [self valueForKey:@"_wallpaperContainerView"];
    injectTendiesIntoWallpaperContainer(container);
}
- (void)activeInterfaceOrientationDidChangeToOrientation:(long long)orientation willAnimateWithDuration:(double)duration fromOrientation:(long long)orientation2 {
    %orig;
    UIView *container = [self valueForKey:@"_wallpaperContainerView"];
    if (container) {
        TendiesView *tView = objc_getAssociatedObject(container, "TendiesView");
        if (tView) tView.frame = container.bounds;
    }
}
%end

// --------------------------------------------------
// 2. 锁屏交互生命周期 (解决无跟手动画、缺少互动的问题)
// --------------------------------------------------
%hook CSCoverSheetViewController

// 下拉锁屏显示时 -> 锁定状态
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:@"Locked"];
    }
}

// 【核心修复】监听用户手指触摸并拖拽锁屏的**第一时刻**，立刻触发交互动画！
- (void)_scrollPanGestureBegan:(id)gesture {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:@"Unlock"];
    }
}

// 双保险：物理按键解锁或完成拖拽进入桌面的收尾动作
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:@"Unlock"];
    }
}

// 拦截息屏/亮屏状态 -> 触发闭眼动画 (Sleep)
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *newState = mode ? @"Sleep" : @"Locked";
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:newState];
    }
}
%end

%end // UniversalWallpaper


// --------------------------------------------------
// 3. 锁屏海报层独占注入 (仅在 iOS 16-17 执行，解决锁屏滑动露出原壁纸)
// --------------------------------------------------
%group iOS16Up

%hook CSBackgroundContentViewController
- (void)viewDidLoad {
    %orig;
    injectTendiesIntoWallpaperContainer(self.view);
}
- (void)viewDidLayoutSubviews {
    %orig;
    injectTendiesIntoWallpaperContainer(self.view);
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
        
        // 核心与 iOS 14-15 初始化
        %init(UniversalWallpaper);
        
        // 动态检测，只有存在 CSBackgroundContentViewController (即 iOS 16 及以上) 才初始化锁屏海报劫持逻辑
        if (NSClassFromString(@"CSBackgroundContentViewController")) {
            %init(iOS16Up);
        }
    }
}
