#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 完整接口声明
// ==========================================
@interface CAStateController : NSObject
@property (readonly) CALayer *layer;
- (id)initWithLayer:(id)layer;
- (void)setState:(id)state ofLayer:(id)layer;
@end

@interface CSCoverSheetViewController : UIViewController
- (UIViewController *)dateViewController; 
- (UIViewController *)complicationContainerViewController; 
@end

@interface SBFWallpaperView : UIView
- (long long)variant;
@end

@interface PBUIWallpaperView : UIView
- (long long)variant;
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

// 核心修改：寻找 .ca 文件夹本身，而不是其内部的 main.caml
static NSArray<NSURL *> *FindCAPackageURLsInTendies(NSString *basePath) {
    NSLog(@"[TendiesTweak] 正在目录中寻找 .ca 动画包: %@", basePath);
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
                NSLog(@"[TendiesTweak] 找到有效的动画包: %@", caPath);
                [caURLs addObject:[NSURL fileURLWithPath:caPath]];
            }
        }
    }

    // 强制排序：背景(Background) -> 悬浮(Floating) -> 前景(Foreground)
    [caURLs sortUsingComparator:^NSComparisonResult(NSURL *u1, NSURL *u2) {
        int w1 = [u1.path.lowercaseString containsString:@"background"] ? 0 : ([u1.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        int w2 = [u2.path.lowercaseString containsString:@"background"] ? 0 : ([u2.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        return (w1 < w2) ? NSOrderedAscending : ((w1 > w2) ? NSOrderedDescending : NSOrderedSame);
    }];
    
    NSLog(@"[TendiesTweak] 共排序并准备加载 %lu 个 CA 包", (unsigned long)caURLs.count);
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
        self.userInteractionEnabled = NO; // 不阻挡用户触摸
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

    NSArray *caURLs = FindCAPackageURLsInTendies(path);
    Class CAPackageClass = NSClassFromString(@"CAPackage");
    
    for (NSURL *url in caURLs) {
        NSLog(@"[TendiesTweak] 准备解析 CA 包: %@", url);
        
        if (CAPackageClass) {
            NSError *error = nil;
            // 核心修改：使用 CAPackage 和 com.apple.coreanimation-bundle 类型完美解析原生壁纸包
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
                    NSLog(@"[TendiesTweak] 成功挂载图层并绑定状态控制器。");
                    
                    if (self.currentState) {
                        [sc setState:self.currentState ofLayer:layer];
                    }
                }
            } else {
                NSLog(@"[TendiesTweak] CAPackage 解析失败！错误: %@", error);
            }
        } else {
            NSLog(@"[TendiesTweak] 当前系统无法获取 CAPackage 类。");
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
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
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

// iOS 14-15 底板
%hook SBFWallpaperView
- (void)didMoveToWindow {
    %orig;
    if (self.window) injectTendiesIntoWallpaperView(self, [self variant]);
}
- (void)layoutSubviews {
    %orig;
    TendiesView *tView = objc_getAssociatedObject(self, "TendiesView");
    if (tView) {
        [self bringSubviewToFront:tView];
        tView.frame = self.bounds;
    }
}
%end

// iOS 16-17 底板
%hook PBUIWallpaperView
- (void)didMoveToWindow {
    %orig;
    if (self.window) injectTendiesIntoWallpaperView(self, [self variant]);
}
- (void)layoutSubviews {
    %orig;
    TendiesView *tView = objc_getAssociatedObject(self, "TendiesView");
    if (tView) {
        [self bringSubviewToFront:tView];
        tView.frame = self.bounds;
    }
}
%end

// 监听锁屏状态切换，实时派发动画状态
%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:@"Locked"];
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:@"Unlock"];
    }
}

// 确保不遮挡时间小组件
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
        // 【务必确认此处的通知名称与 .m 文件中发送的完全一致】
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        %init(UniversalWallpaper);
    }
}
