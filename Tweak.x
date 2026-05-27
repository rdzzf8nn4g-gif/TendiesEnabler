#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

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

static BOOL g_enabled = YES;
static NSString *g_tendiesPath = @"";

// 全局追踪当前活跃的视图，用于实现“秒切”
static NSHashTable *g_wallpaperViews = nil;
static NSHashTable *g_coverSheetVCs = nil;

static void ApplyTendiesToView(UIView *view, id owner);

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

// 收到导入成功通知，立即热重载图层！
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *view in g_wallpaperViews) {
            ApplyTendiesToView(view, view);
        }
        for (UIViewController *vc in g_coverSheetVCs) {
            ApplyTendiesToView(vc.view, vc);
        }
    });
}

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

// 深度递归搜索并执行景深 Z-Index 排序
static NSArray<NSURL *> *findCAMLFiles(NSString *tendiesBasePath) {
    NSMutableArray *camlURLs = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:tendiesBasePath];
    NSString *filePath;
    
    while ((filePath = [enumerator nextObject])) {
        if ([filePath hasSuffix:@"main.caml"]) {
            NSString *fullPath = [tendiesBasePath stringByAppendingPathComponent:filePath];
            [camlURLs addObject:[NSURL fileURLWithPath:fullPath]];
        }
    }
    
    // 强制排序：Background(底) -> Floating(中) -> Foreground(顶)
    [camlURLs sortUsingComparator:^NSComparisonResult(NSURL *url1, NSURL *url2) {
        NSString *p1 = url1.path.lowercaseString;
        NSString *p2 = url2.path.lowercaseString;
        int weight1 = [p1 containsString:@"background"] ? 0 : ([p1 containsString:@"floating"] ? 1 : 2);
        int weight2 = [p2 containsString:@"background"] ? 0 : ([p2 containsString:@"floating"] ? 1 : 2);
        if (weight1 < weight2) return NSOrderedAscending;
        if (weight1 > weight2) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return camlURLs;
}

static const void *kCustomCAMLLayersKey = &kCustomCAMLLayersKey;
static const void *kCustomStateControllersKey = &kCustomStateControllersKey;

// 热重载引擎核心
static void ApplyTendiesToView(UIView *view, id owner) {
    if (!view || !owner) return;

    // 清理旧图层，实现无缝替换
    NSArray *oldLayers = objc_getAssociatedObject(owner, kCustomCAMLLayersKey);
    for (CALayer *layer in oldLayers) {
        [layer removeFromSuperlayer];
    }
    objc_setAssociatedObject(owner, kCustomCAMLLayersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(owner, kCustomStateControllersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!g_enabled || g_tendiesPath.length == 0) return;

    NSArray<NSURL *> *camlURLs = findCAMLFiles(g_tendiesPath);
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

                // 景深插入逻辑
                NSString *pathLower = camlURL.path.lowercaseString;
                if ([pathLower containsString:@"background"]) {
                    [view.layer insertSublayer:camlLayer atIndex:0]; // 插入最底层
                } else if ([pathLower containsString:@"foreground"]) {
                    [view.layer addSublayer:camlLayer]; // 覆盖在最顶层
                } else {
                    [view.layer insertSublayer:camlLayer atIndex:(unsigned)view.layer.sublayers.count / 2];
                }

                CAStateController *sc = [[%c(CAStateController) alloc] initWithLayer:camlLayer];
                [layersArray addObject:camlLayer];
                [controllersArray addObject:sc];
            }
        }
    }

    if (layersArray.count > 0) {
        objc_setAssociatedObject(owner, kCustomCAMLLayersKey, layersArray, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(owner, kCustomStateControllersKey, controllersArray, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// 统一状态控制
static void UpdateTendiesState(id owner, NSString *state) {
    NSArray *controllers = objc_getAssociatedObject(owner, kCustomStateControllersKey);
    NSArray *layers = objc_getAssociatedObject(owner, kCustomCAMLLayersKey);
    if (controllers && layers && controllers.count == layers.count) {
        for (NSUInteger i = 0; i < controllers.count; i++) {
            CAStateController *ctrl = controllers[i];
            CALayer *lyr = layers[i];
            [ctrl setState:state ofLayer:lyr]; 
        }
    }
}

%group Universal_Support

// 兼容 iOS 14-15
%hook SBFWallpaperView
- (id)initWithFrame:(CGRect)frame configuration:(id)configuration variant:(long long)variant cacheGroup:(id)group delegate:(id)delegate options:(unsigned long long)options {
    id orig = %orig;
    if (orig) {
        if (!g_wallpaperViews) g_wallpaperViews = [NSHashTable weakObjectsHashTable];
        [g_wallpaperViews addObject:orig];
        ApplyTendiesToView(orig, orig);
    }
    return orig;
}
- (void)layoutSubviews {
    %orig;
    NSArray *layers = objc_getAssociatedObject(self, kCustomCAMLLayersKey);
    for (CALayer *lyr in layers) lyr.frame = self.bounds;
}
%end

// 兼容 iOS 16-17 锁屏控制器
%hook CSCoverSheetViewController
- (void)viewDidLoad {
    %orig;
    if (!g_coverSheetVCs) g_coverSheetVCs = [NSHashTable weakObjectsHashTable];
    [g_coverSheetVCs addObject:self];
    ApplyTendiesToView(self.view, self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    NSArray *layers = objc_getAssociatedObject(self, kCustomCAMLLayersKey);
    for (CALayer *lyr in layers) lyr.frame = self.view.bounds;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UpdateTendiesState(self, @"Locked");
    for (UIView *view in g_wallpaperViews) UpdateTendiesState(view, @"Locked");
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    UpdateTendiesState(self, @"Unlock");
    for (UIView *view in g_wallpaperViews) UpdateTendiesState(view, @"Unlock");
}
%end

%end // Universal_Support

%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(Universal_Support);
    }
}
