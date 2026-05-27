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

@interface SBFLockScreenDateViewController : UIViewController
@end

@interface CSCoverSheetViewController : UIViewController
- (SBFLockScreenDateViewController *)dateViewController;
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
    CFStringRef appID = CFSTR("com.yourname.tendiesprefs"); // 记得替换为你的 bundleID
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
        // 严格过滤解压附带的 MAC 垃圾文件，防止 CAML 解析器崩溃
        if ([file containsString:@"__MACOSX"] || [file hasPrefix:@"."]) continue;
        
        if ([file hasSuffix:@".ca"]) {
            NSString *camlPath = [[basePath stringByAppendingPathComponent:file] stringByAppendingPathComponent:@"main.caml"];
            if ([fm fileExistsAtPath:camlPath]) {
                [camlURLs addObject:[NSURL fileURLWithPath:camlPath]];
            }
        }
    }

    // 强制排序：背景(Background) -> 悬浮(Floating) -> 前景(Foreground)
    [camlURLs sortUsingComparator:^NSComparisonResult(NSURL *u1, NSURL *u2) {
        int w1 = [u1.path.lowercaseString containsString:@"background"] ? 0 : ([u1.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        int w2 = [u2.path.lowercaseString containsString:@"background"] ? 0 : ([u2.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        return (w1 < w2) ? NSOrderedAscending : ((w1 > w2) ? NSOrderedDescending : NSOrderedSame);
    }];
    return camlURLs;
}

// ==========================================
// 核心视图类：负责解析并承载 CAML 动画
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
        self.userInteractionEnabled = NO; // 禁止阻挡用户触摸
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
// 动态 Hook 注入区 (最重逻辑)
// ==========================================
%group UniversalWallpaper

// 1. 桌面级注入 (Home Screen)
%hook SBWallpaperController
- (void)_applicationDidFinishLaunching:(id)arg1 {
    %orig;
    UIView *container = MSHookIvar<UIView *>(self, "_wallpaperContainerView");
    if (!container) container = [self _window];

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

// 保证在任何壁纸刷新时，我们的容器都置于最顶层（覆盖原生壁纸）
- (void)updateWallpaperForLocations:(long long)arg1 withCompletion:(id)arg2 {
    %orig;
    UIView *container = MSHookIvar<UIView *>(self, "_wallpaperContainerView");
    if (!container) container = [self _window];
    if (container && g_hsTendiesView && g_hsTendiesView.superview == container) {
        [container bringSubviewToFront:g_hsTendiesView];
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

// 精准的层级夹击算法：将视图置于原生壁纸之上，时钟界面之下
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
            UIView *dateView = [[self dateViewController] view];
            if (dateView && [self.view.subviews containsObject:dateView]) {
                [self.view insertSubview:g_lsTendiesView belowSubview:dateView];
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
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        %init(UniversalWallpaper);
    }
}
