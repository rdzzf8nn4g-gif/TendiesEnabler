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

// 【核心修复】：声明 SBFWallpaperView 继承自 UIView，让编译器识别 window 和 bounds 属性
@interface SBFWallpaperView : UIView
@end

// ==========================================
// 全局变量与工具函数
// ==========================================
static BOOL g_enabled = YES;
static NSString *g_tendiesPath = @"";
static NSHashTable *g_wallpaperViews = nil;

static NSString * GetPrefPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static void reloadPrefs() {
    CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
    CFPreferencesAppSynchronize(appID);
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefPath()];
    if (dict) {
        g_enabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : YES;
        g_tendiesPath = dict[@"TendiesPath"] ?: @"";
    } else {
        g_enabled = YES; 
        g_tendiesPath = @"";
    }
}

// 深度递归遍历，无视任何包装层级，暴力提取所有 .ca/main.caml
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

    // 强制排序：Background(底) -> Floating(中) -> Foreground(顶)
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
// 万能降维挂载逻辑：强行在原生壁纸顶层插入交互图层
// ==========================================
static void ApplyTendiesToView(UIView *wallpaperView) {
    if (!wallpaperView) return;
    
    // 1. 获取或创建我们的专属安全容器 (隔离 Apple 原生的 subviews)
    UIView *containerView = objc_getAssociatedObject(wallpaperView, @"TendiesContainerView");
    if (!containerView) {
        containerView = [[UIView alloc] initWithFrame:wallpaperView.bounds];
        containerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        containerView.userInteractionEnabled = NO; // 让触摸事件穿透
        [wallpaperView addSubview:containerView];
        objc_setAssociatedObject(wallpaperView, @"TendiesContainerView", containerView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // 强制把我们的容器放到最前面，遮盖原生的任何壁纸画面
    [wallpaperView bringSubviewToFront:containerView];
    
    // 2. 清理旧图层
    NSArray *oldLayers = objc_getAssociatedObject(wallpaperView, kCustomCAMLLayersKey);
    for (CALayer *layer in oldLayers) {
        [layer removeFromSuperlayer];
    }
    objc_setAssociatedObject(wallpaperView, kCustomCAMLLayersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(wallpaperView, kCustomStateControllersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 3. 判断是否启用
    if (!g_enabled || g_tendiesPath.length == 0) return;

    NSArray<NSURL *> *camlURLs = FindCAMLURLsInTendies(g_tendiesPath);
    if (camlURLs.count == 0) return;

    NSMutableArray *layersArray = [NSMutableArray array];
    NSMutableArray *controllersArray = [NSMutableArray array];

    // 4. 解析并渲染 CAML
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
            }
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
    }
}

// ==========================================
// 动态 Hook 注入区
// ==========================================
%group UniversalWallpaper

// 这里的 SBFWallpaperView 在注入时会根据系统版本，动态映射为 PBUIWallpaperView (iOS 16+)
%hook SBFWallpaperView
- (void)didMoveToWindow {
    %orig;
    if (!g_wallpaperViews) g_wallpaperViews = [NSHashTable weakObjectsHashTable];
    if (self.window) {
        [g_wallpaperViews addObject:self];
        ApplyTendiesToView(self);
    } else {
        [g_wallpaperViews removeObject:self];
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *containerView = objc_getAssociatedObject(self, @"TendiesContainerView");
    if (containerView) {
        [self bringSubviewToFront:containerView];
        containerView.frame = self.bounds;
        
        NSArray *layers = objc_getAssociatedObject(self, kCustomCAMLLayersKey);
        for (CALayer *lyr in layers) {
            lyr.frame = containerView.bounds;
        }
    }
}
%end

%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    for (UIView *view in g_wallpaperViews.allObjects) {
        UpdateTendiesState(view, @"Locked");
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    for (UIView *view in g_wallpaperViews.allObjects) {
        UpdateTendiesState(view, @"Unlock");
    }
}
%end
%end // UniversalWallpaper

// ==========================================
// 全局热重载监听器 (实现导入即刻生效)
// ==========================================
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *view in g_wallpaperViews.allObjects) {
            ApplyTendiesToView(view);
        }
    });
}

// ==========================================
// 构造函数
// ==========================================
%ctor {
    reloadPrefs();
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        
        // 关键修复：将动态类提取为变量，保证只调用一次 %init
        Class targetWallpaperClass = NSClassFromString(@"PBUIWallpaperView") ?: NSClassFromString(@"SBFWallpaperView");
        if (targetWallpaperClass) {
            %init(UniversalWallpaper, SBFWallpaperView = targetWallpaperClass);
        }
    }
}
