#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ==========================================
// 声明与头文件
// ==========================================
@interface CAMLParser : NSObject
@property (retain) NSURL *baseURL;
@property (readonly) id result;
+ (id)parser;
- (BOOL)parseContentsOfURL:(id)url;
@end

@interface CAStateController : NSObject
@property (readonly) CALayer *layer;
- (id)initWithLayer:(id)layer;
- (void)setState:(id)state ofLayer:(id)layer;
@end

@interface CSCoverSheetViewController : UIViewController
// 避免引入繁杂头文件，直接声明返回 UIViewController
- (UIViewController *)dateViewController; 
- (UIViewController *)complicationContainerViewController; // iOS 16+ 小组件容器
@end

@interface SBWallpaperController : NSObject
- (UIWindow *)_window;
@end

// ==========================================
// 全局变量与工具函数
// ==========================================
static BOOL g_enabled = YES;
static NSString *g_tendiesPath = @"";

static void reloadPrefs() {
    // 【注意】请确保这个 bundleID 与你 Prefs.m 中保持一致！
    CFStringRef appID = CFSTR("com.yourname.tendiesprefs"); 
    CFPreferencesAppSynchronize(appID);
    
    Boolean validEnabled = NO;
    Boolean enabledVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &validEnabled);
    g_enabled = validEnabled ? enabledVal : YES;

    CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("TendiesPath"), appID);
    if (pathRef) {
        g_tendiesPath = (NSString *)CFBridgingRelease(pathRef);
    } else {
        g_tendiesPath = @"";
    }
}

static NSArray<NSURL *> *FindCAMLURLsInTendies(NSString *basePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
    NSString *file;
    NSMutableArray *camlURLs = [NSMutableArray array];

    while ((file = [enumerator nextObject])) {
        // 严格过滤垃圾文件和隐藏文件，防止崩溃
        if ([file containsString:@"__MACOSX"] || [file.lastPathComponent hasPrefix:@"."]) continue;
        
        if ([file hasSuffix:@".ca"]) {
            NSString *camlPath = [[basePath stringByAppendingPathComponent:file] stringByAppendingPathComponent:@"main.caml"];
            if ([fm fileExistsAtPath:camlPath]) {
                [camlURLs addObject:[NSURL fileURLWithPath:camlPath]];
            }
        }
    }

    // 层级强制排序：背景(Background) -> 悬浮(Floating) -> 前景(Foreground)
    [camlURLs sortUsingComparator:^NSComparisonResult(NSURL *u1, NSURL *u2) {
        int w1 = [u1.path.lowercaseString containsString:@"background"] ? 0 : ([u1.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        int w2 = [u2.path.lowercaseString containsString:@"background"] ? 0 : ([u2.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        return (w1 < w2) ? NSOrderedAscending : ((w1 > w2) ? NSOrderedDescending : NSOrderedSame);
    }];
    return camlURLs;
}

// ==========================================
// 核心视图类：在 SpringBoard 中承载 CAML 动画
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
        self.userInteractionEnabled = NO; // 禁止阻挡用户手势
    }
    return self;
}

- (void)loadTendiesFromPath:(NSString *)path {
    // 每次加载前清理旧的动画图层
    for (CALayer *layer in self.camlLayers) {
        [layer removeFromSuperlayer];
    }
    [self.camlLayers removeAllObjects];
    [self.stateControllers removeAllObjects];

    if (!g_enabled || path.length == 0) return;

    NSArray *camlURLs = FindCAMLURLsInTendies(path);
    for (NSURL *url in camlURLs) {
        CAMLParser *parser = [[%c(CAMLParser) alloc] init];
        [parser setBaseURL:[url URLByDeletingLastPathComponent]];
        if ([parser parseContentsOfURL:url]) {
            CALayer *layer = parser.result;
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

- (void)layoutSubviews {
    [super layoutSubviews];
    for (CALayer *layer in self.camlLayers) {
        layer.frame = self.bounds;
    }
}

- (void)setState:(NSString *)state {
    self.currentState = state;
    for (int i = 0; i < self.camlLayers.count; i++) {
        CAStateController *sc = self.stateControllers[i];
        CALayer *layer = self.camlLayers[i];
        [sc setState:state ofLayer:layer];
    }
}
@end

static TendiesView *g_lsTendiesView = nil; // 锁屏层
static TendiesView *g_hsTendiesView = nil; // 桌面层

// ==========================================
// 动态 Hook 注入区 
// ==========================================
%group UniversalWallpaper

// 1. 桌面级注入 (Home Screen)
%hook SBWallpaperController
- (void)_applicationDidFinishLaunching:(id)arg1 {
    %orig;
    
    // 【修复】：不使用 MSHookIvar 宏，改用原生的 Runtime API，100% 解决编译错误且安全
    UIView *container = nil;
    Ivar containerIvar = class_getInstanceVariable([self class], "_wallpaperContainerView");
    if (containerIvar) {
        container = object_getIvar(self, containerIvar);
    }
    
    if (!container) container = [self _window]; // 兜底获取 UIWindow

    if (container) {
        if (!g_hsTendiesView) {
            g_hsTendiesView = [[TendiesView alloc] initWithFrame:container.bounds];
            g_hsTendiesView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [g_hsTendiesView loadTendiesFromPath:g_tendiesPath];
            [g_hsTendiesView setState:@"Unlock"]; // 桌面默认解锁状态
        }
        [container addSubview:g_hsTendiesView];
    }
}
%end

// 2. 锁屏级注入 (Lock Screen)
%hook CSCoverSheetViewController
- (void)viewDidLoad {
    %orig;
    if (!g_lsTendiesView) {
        g_lsTendiesView = [[TendiesView alloc] initWithFrame:self.view.bounds];
        g_lsTendiesView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [g_lsTendiesView loadTendiesFromPath:g_tendiesPath];
        [g_lsTendiesView setState:@"Locked"];
    }
    [self.view insertSubview:g_lsTendiesView atIndex:0];
}

// 【关键算法】：动态图层计算，确保壁纸遮盖原生海报，但绝对不遮挡时钟和小组件
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_lsTendiesView && g_lsTendiesView.superview == self.view) {
        [self.view sendSubviewToBack:g_lsTendiesView];
        
        // 尝试跨过 PosterBoard 的原生宿主视图
        for (UIView *subview in self.view.subviews) {
            NSString *className = NSStringFromClass([subview class]);
            if ([className containsString:@"Poster"] || [className containsString:@"Wallpaper"] || [className containsString:@"Host"]) {
                [self.view insertSubview:g_lsTendiesView aboveSubview:subview];
            }
        }
        
        // 绝对不能遮挡时钟
        if ([self respondsToSelector:@selector(dateViewController)]) {
            UIViewController *dateVC = [self dateViewController];
            if (dateVC && dateVC.view && [self.view.subviews containsObject:dateVC.view]) {
                [self.view insertSubview:g_lsTendiesView belowSubview:dateVC.view];
            }
        }
        
        // iOS 16+ 绝对不能遮挡小组件
        if ([self respondsToSelector:@selector(complicationContainerViewController)]) {
            UIViewController *compVC = [self complicationContainerViewController];
            if (compVC && compVC.view && [self.view.subviews containsObject:compVC.view]) {
                [self.view insertSubview:g_lsTendiesView belowSubview:compVC.view];
            }
        }
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [g_lsTendiesView setState:@"Locked"];
    [g_hsTendiesView setState:@"Locked"];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [g_lsTendiesView setState:@"Unlock"];
    [g_hsTendiesView setState:@"Unlock"];
}
%end
%end // UniversalWallpaper

// ==========================================
// 热重载通知中枢
// ==========================================
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_lsTendiesView loadTendiesFromPath:g_tendiesPath];
        [g_hsTendiesView loadTendiesFromPath:g_tendiesPath];
    });
}

%ctor {
    reloadPrefs();
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        // 监听设置 App 发来的通知
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        %init(UniversalWallpaper);
    }
}
