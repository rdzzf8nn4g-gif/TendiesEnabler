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

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
- (void)_reloadWallpaperAndFlushCaches:(BOOL)caches completionHandler:(void(^)(void))handler;
@end

@interface PRPosterDescriptor : NSObject
@property (readonly, copy, nonatomic) NSURL *assetDirectory;
@end

// ==========================================
// 全局变量与工具函数
// ==========================================
static BOOL g_enabled = YES;
static NSString *g_tendiesPath = @"";
static NSHashTable *g_wallpaperViews = nil; // 追踪 iOS 14/15 视图用于热重载

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

// 在 Tendies 文件夹中寻找 iOS 16/17 标准的 contents 资源目录
static NSURL *FindContentsURLInTendies(NSString *basePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
    NSString *file;
    while ((file = [enumerator nextObject])) {
        if ([file.lastPathComponent.lowercaseString isEqualToString:@"contents"]) {
            BOOL isDir = NO;
            NSString *fullPath = [basePath stringByAppendingPathComponent:file];
            if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir) {
                return [NSURL fileURLWithPath:fullPath];
            }
        }
    }
    return nil;
}

static const void *kCustomCAMLLayersKey = &kCustomCAMLLayersKey;
static const void *kCustomStateControllersKey = &kCustomStateControllersKey;

// ==========================================
// iOS 14-15: 动态图层挂载与热重载
// ==========================================
static void ApplyTendiesToView(UIView *view) {
    if (!view) return;
    
    // 清理旧图层，实现秒切无缝替换
    NSArray *oldLayers = objc_getAssociatedObject(view, kCustomCAMLLayersKey);
    for (CALayer *layer in oldLayers) {
        [layer removeFromSuperlayer];
    }
    objc_setAssociatedObject(view, kCustomCAMLLayersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kCustomStateControllersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!g_enabled || g_tendiesPath.length == 0) return;

    NSURL *contentsURL = FindContentsURLInTendies(g_tendiesPath);
    if (!contentsURL) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *subItems = [fm contentsOfDirectoryAtPath:contentsURL.path error:nil];
    
    NSMutableArray *camlURLs = [NSMutableArray array];
    for (NSString *item in subItems) {
        if ([item hasSuffix:@".ca"]) {
            NSString *camlPath = [[contentsURL.path stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"main.caml"];
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
    NSArray *layers = objc_getAssociatedObject(self, kCustomCAMLLayersKey);
    for (CALayer *lyr in layers) lyr.frame = self.bounds;
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

// ==========================================
// iOS 16-17: PosterBoard 资源劫持 (无需改沙盒，直接替换渲染流)
// ==========================================
%group iOS16_17_PosterBoard
%hook PRPosterDescriptor
- (NSURL *)assetDirectory {
    if (g_enabled && g_tendiesPath.length > 0) {
        NSURL *customURL = FindContentsURLInTendies(g_tendiesPath);
        if (customURL) return customURL; // 强行将壁纸资源重定向为我们导入的目录
    }
    return %orig;
}
%end
%end // iOS16_17_PosterBoard

// ==========================================
// 全局热重载监听器 (实现导入即刻生效)
// ==========================================
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        double version = kCFCoreFoundationVersionNumber;
        if (version < 1953.1) {
            // iOS 14-15：立刻重新渲染 CAML
            for (UIView *view in g_wallpaperViews) {
                ApplyTendiesToView(view);
            }
        } else {
            // iOS 16-17：命令 SpringBoard 瞬间刷新壁纸缓存
            Class SBWC = NSClassFromString(@"SBWallpaperController");
            if (SBWC && [SBWC respondsToSelector:@selector(sharedInstance)]) {
                id wc = [SBWC sharedInstance];
                if ([wc respondsToSelector:@selector(_reloadWallpaperAndFlushCaches:completionHandler:)]) {
                    [wc _reloadWallpaperAndFlushCaches:YES completionHandler:nil];
                }
            }
        }
    });
}

%ctor {
    reloadPrefs();
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    double version = kCFCoreFoundationVersionNumber;
    
    // 根据进程分配任务
    if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        if (version < 1953.1) {
            %init(iOS14_15_Support);
        }
    } else if ([bundleId isEqualToString:@"com.apple.PosterBoard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        if (version >= 1953.1) {
            %init(iOS16_17_PosterBoard);
        }
    }
}
