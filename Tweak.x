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

@interface SBFWallpaperView : UIView
@end

@interface CSCoverSheetViewController : UIViewController
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

// 【核心修复】：深度递归遍历，穿透 .wallpaper 文件夹寻找所有 .ca/main.caml 资源
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
// iOS 14-15: 动态图层挂载与热重载
// ==========================================
static void ApplyTendiesToView(UIView *view) {
    if (!view) return;
    
    NSString *appliedPath = objc_getAssociatedObject(view, @"AppliedTendiesPath");

    // 如果未启用或路径为空，清理所有自定义图层
    if (!g_enabled || g_tendiesPath.length == 0) {
        NSArray *oldLayers = objc_getAssociatedObject(view, kCustomCAMLLayersKey);
        for (CALayer *layer in oldLayers) [layer removeFromSuperlayer];
        objc_setAssociatedObject(view, kCustomCAMLLayersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kCustomStateControllersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, @"AppliedTendiesPath", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        if ([view respondsToSelector:@selector(contentView)]) {
            UIView *contentView = [view performSelector:@selector(contentView)];
            contentView.hidden = NO; // 恢复原生壁纸
        }
        return;
    }

    // 如果已经渲染过了，直接更新尺寸即可
    if ([appliedPath isEqualToString:g_tendiesPath] && objc_getAssociatedObject(view, kCustomCAMLLayersKey)) {
        NSArray *layers = objc_getAssociatedObject(view, kCustomCAMLLayersKey);
        for (CALayer *lyr in layers) lyr.frame = view.bounds;
        return;
    }

    // 移除旧图层
    NSArray *oldLayers = objc_getAssociatedObject(view, kCustomCAMLLayersKey);
    for (CALayer *layer in oldLayers) [layer removeFromSuperlayer];

    NSArray<NSURL *> *camlURLs = FindCAMLURLsInTendies(g_tendiesPath);
    if (camlURLs.count == 0) return;

    NSMutableArray *layersArray = [NSMutableArray array];
    NSMutableArray *controllersArray = [NSMutableArray array];

    for (NSURL *camlURL in camlURLs) {
        CAMLParser *parser = [[%c(CAMLParser) alloc] init];
        [parser setBaseURL:[camlURL URLByDeletingLastPathComponent]];
        if ([parser parseContentsOfURL:camlURL]) {
            CALayer *camlLayer = parser.result;
            if (camlLayer && [camlLayer isKindOfClass:[CALayer class]]) {
                camlLayer.frame = view.bounds;
                camlLayer.masksToBounds = YES;
                [view.layer addSublayer:camlLayer];
                
                CAStateController *sc = [[%c(CAStateController) alloc] initWithLayer:camlLayer];
                [layersArray addObject:camlLayer];
                [controllersArray addObject:sc];
            }
        }
    }

    if (layersArray.count > 0) {
        objc_setAssociatedObject(view, kCustomCAMLLayersKey, layersArray, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kCustomStateControllersKey, controllersArray, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, @"AppliedTendiesPath", g_tendiesPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // 隐藏底部的原生壁纸容器，防止相互干扰
        if ([view respondsToSelector:@selector(contentView)]) {
            UIView *contentView = [view performSelector:@selector(contentView)];
            contentView.hidden = YES;
        }
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

%group iOS14_15_Support
%hook SBFWallpaperView
- (id)initWithFrame:(CGRect)frame configuration:(id)configuration variant:(long long)variant cacheGroup:(id)group delegate:(id)delegate options:(unsigned long long)options {
    id orig = %orig;
    if (orig) {
        if (!g_wallpaperViews) g_wallpaperViews = [NSHashTable weakObjectsHashTable];
        [g_wallpaperViews addObject:orig];
        ApplyTendiesToView(orig);
    }
    return orig;
}
- (void)layoutSubviews {
    %orig;
    ApplyTendiesToView(self);
}
%end

%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    for (UIView *view in g_wallpaperViews) UpdateTendiesState(view, @"Locked");
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    for (UIView *view in g_wallpaperViews) UpdateTendiesState(view, @"Unlock");
}
%end
%end // iOS14_15_Support

// 全局热重载监听器 (接收偏好设置改动)
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        double version = kCFCoreFoundationVersionNumber;
        if (version < 1953.1) {
            for (UIView *view in g_wallpaperViews) {
                ApplyTendiesToView(view);
            }
        }
    });
}

%ctor {
    reloadPrefs();
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    double version = kCFCoreFoundationVersionNumber;
    
    // 我们只需要 Hook SpringBoard (iOS 14-15)。iOS 16+ 将由 Prefs 独立注入
    if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        if (version < 1953.1) {
            %init(iOS14_15_Support);
        }
    }
}
