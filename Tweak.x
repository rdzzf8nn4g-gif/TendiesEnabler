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
// 完整接口声明（解决 forward declaration 报错）
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
- (UIViewController *)dateViewController; 
- (UIViewController *)complicationContainerViewController; 
@end

// 明确继承自 UIView，让编译器知道有 self.window 和子视图管理方法
@interface SBFWallpaperView : UIView
- (long long)variant;
@end

@interface PBUIWallpaperView : UIView
- (long long)variant;
@end

// ==========================================
// 全局变量与核心逻辑
// ==========================================
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist" // 请替换为你真实的 bundleID

static NSHashTable *g_allTendiesViews = nil;
static NSString *g_tendiesPath = @"";
static BOOL g_enabled = YES;

static NSArray<NSURL *> *FindCAMLURLsInTendies(NSString *basePath) {
    NSLog(@"[TendiesTweak] 正在目录中寻找 CAML 文件: %@", basePath);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
    NSString *file;
    NSMutableArray *camlURLs = [NSMutableArray array];

    while ((file = [enumerator nextObject])) {
        if ([file containsString:@"__MACOSX"] || [file.lastPathComponent hasPrefix:@"."]) continue;
        
        if ([file hasSuffix:@".ca"]) {
            NSString *camlPath = [[basePath stringByAppendingPathComponent:file] stringByAppendingPathComponent:@"main.caml"];
            if ([fm fileExistsAtPath:camlPath]) {
                NSLog(@"[TendiesTweak] 找到有效的动画文件: %@", camlPath);
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
    
    NSLog(@"[TendiesTweak] 共排序并准备加载 %lu 个 CAML 文件", (unsigned long)camlURLs.count);
    return camlURLs;
}

// ==========================================
// 核心视图类：在 SB 壁纸层上承载 CAML 动画
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
        self.userInteractionEnabled = NO; // 绝对不阻挡用户触摸
        NSLog(@"[TendiesTweak] 初始化 TendiesView 容器，Frame: %@", NSStringFromCGRect(frame));
    }
    return self;
}

- (void)loadTendiesFromPath:(NSString *)path {
    NSLog(@"[TendiesTweak] 开始加载壁纸路径: %@", path);
    for (CALayer *layer in self.camlLayers) {
        [layer removeFromSuperlayer];
    }
    [self.camlLayers removeAllObjects];
    [self.stateControllers removeAllObjects];

    if (!g_enabled || path.length == 0) {
        NSLog(@"[TendiesTweak] 插件已禁用或路径为空，中止加载。");
        return;
    }

    NSArray *camlURLs = FindCAMLURLsInTendies(path);
    for (NSURL *url in camlURLs) {
        NSLog(@"[TendiesTweak] 准备解析: %@", url);
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
                NSLog(@"[TendiesTweak] 成功挂载图层并绑定状态控制器。");
                
                if (self.currentState) {
                    [sc setState:self.currentState ofLayer:layer];
                }
            } else {
                NSLog(@"[TendiesTweak] 解析结果不是 CALayer，跳过。");
            }
        } else {
            NSLog(@"[TendiesTweak] CAMLParser 解析失败！");
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
    NSLog(@"[TendiesTweak] 动画状态切换: %@ -> %@", self.currentState, state);
    self.currentState = state;
    for (int i = 0; i < self.camlLayers.count; i++) {
        CAStateController *sc = self.stateControllers[i];
        CALayer *layer = self.camlLayers[i];
        [sc setState:state ofLayer:layer];
    }
}
@end

static void reloadPrefsAndInject() {
    NSLog(@"[TendiesTweak] 执行配置热重载...");
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    g_enabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : YES;
    g_tendiesPath = dict[@"TendiesPath"] ?: @"";
    
    NSLog(@"[TendiesTweak] 当前配置 - Enabled: %d, Path: %@", g_enabled, g_tendiesPath);
    
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) {
            NSLog(@"[TendiesTweak] 正在为现有的 TendiesView 刷新动画图层...");
            [tView loadTendiesFromPath:g_tendiesPath];
        }
    }
}

// 统一的壁纸底板挂载器
static void injectTendiesIntoWallpaperView(UIView *wallpaperView, long long variant) {
    if (!wallpaperView) return;
    
    TendiesView *tView = objc_getAssociatedObject(wallpaperView, "TendiesView");
    if (!tView) {
        NSLog(@"[TendiesTweak] 在底板视图中未找到旧容器，新建并挂载...");
        tView = [[TendiesView alloc] initWithFrame:wallpaperView.bounds];
        tView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [wallpaperView addSubview:tView];
        objc_setAssociatedObject(wallpaperView, "TendiesView", tView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        @synchronized(g_allTendiesViews) {
            if (!g_allTendiesViews) g_allTendiesViews = [NSHashTable weakObjectsHashTable];
            [g_allTendiesViews addObject:tView];
        }
        
        [tView loadTendiesFromPath:g_tendiesPath];
    }
    
    [wallpaperView bringSubviewToFront:tView];
    NSString *newState = (variant == 0) ? @"Locked" : @"Unlock";
    NSLog(@"[TendiesTweak] 初始化底板状态 (Variant %lld) 为: %@", variant, newState);
    [tView setState:newState];
}

// ==========================================
// 动态 Hook 注入区
// ==========================================
%group UniversalWallpaper

// 针对 iOS 14-15 的底板
%hook SBFWallpaperView
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        NSLog(@"[TendiesTweak] 捕获到 iOS 14-15 底板: SBFWallpaperView");
        injectTendiesIntoWallpaperView(self, [self variant]);
    }
}
- (void)layoutSubviews {
    %orig;
    TendiesView *tView = objc_getAssociatedObject(self, "TendiesView");
    if (tView) [self bringSubviewToFront:tView];
}
%end

// 针对 iOS 16-17 的底板
%hook PBUIWallpaperView
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        NSLog(@"[TendiesTweak] 捕获到 iOS 16-17 底板: PBUIWallpaperView");
        injectTendiesIntoWallpaperView(self, [self variant]);
    }
}
- (void)layoutSubviews {
    %orig;
    TendiesView *tView = objc_getAssociatedObject(self, "TendiesView");
    if (tView) [self bringSubviewToFront:tView];
}
%end

// 监听锁屏状态切换，实时派发动画状态
%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NSLog(@"[TendiesTweak] 锁屏将要显示，准备切换状态为 Locked");
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:@"Locked"];
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    NSLog(@"[TendiesTweak] 锁屏已消失，准备切换状态为 Unlock");
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:@"Unlock"];
    }
}

// 确保我们不在最外层遮挡小组件，但依然位于壁纸层上方
- (void)viewWillLayoutSubviews {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) {
            if (tView.superview == self.view) {
                [self.view sendSubviewToBack:tView];
                if ([self respondsToSelector:@selector(dateViewController)]) {
                    UIViewController *dateVC = [self dateViewController];
                    if (dateVC && dateVC.view && [self.view.subviews containsObject:dateVC.view]) {
                        [self.view insertSubview:tView belowSubview:dateVC.view];
                    }
                }
            }
        }
    }
}
%end

%end // UniversalWallpaper

// ==========================================
// 热重载通知中枢
// ==========================================
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSLog(@"[TendiesTweak] 收到 Darwin 通知，正在刷新全局动画...");
    dispatch_async(dispatch_get_main_queue(), ^{
        reloadPrefsAndInject();
    });
}

%ctor {
    NSLog(@"[TendiesTweak] 插件初始化...");
    reloadPrefsAndInject();
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        NSLog(@"[TendiesTweak] 成功注入 SpringBoard，挂载通知监听。");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        %init(UniversalWallpaper);
    }
}
