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
@end

@interface SBWallpaperController : NSObject
- (UIWindow *)_window;
// 隐藏的实例变量，iOS 16+ 用于包裹壁纸的容器
@end

// ==========================================
// 全局变量与工具函数
// ==========================================
static BOOL g_enabled = YES;
static NSString *g_tendiesPath = @"";
static NSHashTable *g_wallpaperViews = nil;

// 【修复】：从内存直读，无视磁盘 I/O 延迟
static void reloadPrefs() {
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
    NSLog(@"[TendiesTweak] 已重新加载配置: Enabled=%d, Path=%@", g_enabled, g_tendiesPath);
}

// 深度递归遍历
static NSArray<NSURL *> *FindCAMLURLsInTendies(NSString *basePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
    NSString *file;
    NSMutableArray *camlURLs = [NSMutableArray array];

    while ((file = [enumerator nextObject])) {
        if ([file hasSuffix:@".ca"]) {
            NSString *camlPath = [[basePath stringByAppendingPathComponent:file] stringByAppendingPathComponent:@"main.caml"];
            if ([fm fileExistsAtPath:camlPath]) {
                [camlURLs addObject:[NSURL fileURLWithPath:camlPath]];
            }
        }
    }

    [camlURLs sortUsingComparator:^NSComparisonResult(NSURL *u1, NSURL *u2) {
        int w1 = [u1.path.lowercaseString containsString:@"background"] ? 0 : ([u1.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        int w2 = [u2.path.lowercaseString containsString:@"background"] ? 0 : ([u2.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        return (w1 < w2) ? NSOrderedAscending : ((w1 > w2) ? NSOrderedDescending : NSOrderedSame);
    }];
    return camlURLs;
}

static const void *kCustomCAMLLayersKey = &kCustomCAMLLayersKey;
static const void *kCustomStateControllersKey = &kCustomStateControllersKey;

// ==========================================
// 降维挂载逻辑
// ==========================================
static void ApplyTendiesToView(UIView *wallpaperView) {
    if (!wallpaperView) {
        NSLog(@"[TendiesTweak] 错误：传入的 wallpaperView 为空");
        return;
    }
    
    NSLog(@"[TendiesTweak] 开始向视图注入 CAML 图层: %@", wallpaperView);
    
    UIView *containerView = objc_getAssociatedObject(wallpaperView, @"TendiesContainerView");
    if (!containerView) {
        containerView = [[UIView alloc] initWithFrame:wallpaperView.bounds];
        containerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        containerView.userInteractionEnabled = NO;
        [wallpaperView addSubview:containerView];
        objc_setAssociatedObject(wallpaperView, @"TendiesContainerView", containerView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[TendiesTweak] 创建了全新的壁纸安全容器");
    }
    
    [wallpaperView bringSubviewToFront:containerView];
    
    NSArray *oldLayers = objc_getAssociatedObject(wallpaperView, kCustomCAMLLayersKey);
    for (CALayer *layer in oldLayers) [layer removeFromSuperlayer];
    objc_setAssociatedObject(wallpaperView, kCustomCAMLLayersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(wallpaperView, kCustomStateControllersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!g_enabled || g_tendiesPath.length == 0) {
        NSLog(@"[TendiesTweak] 插件已禁用或路径为空，清理完成");
        return;
    }

    NSArray<NSURL *> *camlURLs = FindCAMLURLsInTendies(g_tendiesPath);
    NSLog(@"[TendiesTweak] 找到 %lu 个 CAML 动画文件", (unsigned long)camlURLs.count);
    if (camlURLs.count == 0) return;

    NSMutableArray *layersArray = [NSMutableArray array];
    NSMutableArray *controllersArray = [NSMutableArray array];

    for (NSURL *camlURL in camlURLs) {
        CAMLParser *parser = [[%c(CAMLParser) alloc] init];
        [parser setBaseURL:[camlURL URLByDeletingLastPathComponent]];
        if ([parser parseContentsOfURL:camlURL]) {
            CALayer *camlLayer = parser.result;
            if (camlLayer && [camlLayer isKindOfClass:[CALayer class]]) {
                camlLayer.frame = containerView.bounds;
                camlLayer.masksToBounds = YES;
                [containerView.layer addSublayer:camlLayer];
                
                CAStateController *sc = [[%c(CAStateController) alloc] initWithLayer:camlLayer];
                [layersArray addObject:camlLayer];
                [controllersArray addObject:sc];
                NSLog(@"[TendiesTweak] 成功注入图层: %@", camlURL.lastPathComponent);
            }
        } else {
            NSLog(@"[TendiesTweak] CAML 解析失败: %@", camlURL);
        }
    }

    if (layersArray.count > 0) {
        objc_setAssociatedObject(wallpaperView, kCustomCAMLLayersKey, layersArray, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(wallpaperView, kCustomStateControllersKey, controllersArray, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void UpdateTendiesState(UIView *view, NSString *state) {
    NSArray *controllers = objc_getAssociatedObject(view, kCustomStateControllersKey);
    NSArray *layers = objc_getAssociatedObject(view, kCustomCAMLLayersKey);
    if (controllers && layers && controllers.count == layers.count) {
        for (NSUInteger i = 0; i < controllers.count; i++) {
            [controllers[i] setState:state ofLayer:layers[i]]; 
        }
        NSLog(@"[TendiesTweak] 状态已更新为: %@", state);
    }
}

// ==========================================
// 动态 Hook 注入区
// ==========================================
%group UniversalWallpaper

// 【修复】：横跨 iOS 14-17，直接拦截壁纸控制器获取总容器
%hook SBWallpaperController
- (void)_applicationDidFinishLaunching:(id)arg1 {
    %orig;
    NSLog(@"[TendiesTweak] SBWallpaperController _applicationDidFinishLaunching 触发");
    
    // 优先拿 iOS 16-17 的 _wallpaperContainerView
    UIView *container = MSHookIvar<UIView *>(self, "_wallpaperContainerView");
    if (!container) {
        // 退而求其次拿 UIWindow
        container = [self _window];
    }
    
    if (container) {
        if (!g_wallpaperViews) g_wallpaperViews = [NSHashTable weakObjectsHashTable];
        [g_wallpaperViews addObject:container];
        ApplyTendiesToView(container);
        NSLog(@"[TendiesTweak] 已成功捕捉并挂载壁纸根容器");
    } else {
        NSLog(@"[TendiesTweak] 严重错误：未能找到壁纸根容器！");
    }
}
%end

%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NSLog(@"[TendiesTweak] 锁屏显示 (Locked)");
    for (UIView *view in g_wallpaperViews.allObjects) UpdateTendiesState(view, @"Locked");
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    NSLog(@"[TendiesTweak] 锁屏消失 (Unlock)");
    for (UIView *view in g_wallpaperViews.allObjects) UpdateTendiesState(view, @"Unlock");
}
%end
%end // UniversalWallpaper

// 热重载监听器
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSLog(@"[TendiesTweak] 收到 Preferences 更新通知，开始热重载");
    reloadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *view in g_wallpaperViews.allObjects) {
            ApplyTendiesToView(view);
        }
    });
}

%ctor {
    reloadPrefs();
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        NSLog(@"[TendiesTweak] 插件注入 SpringBoard 成功");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        %init(UniversalWallpaper);
    }
}
