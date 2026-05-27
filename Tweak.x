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

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
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

@interface PRSPosterPath : NSObject
- (NSURL *)serverIdentityURL;
@end

// ==========================================
// 【深度递归搜索引擎】：无视多少层嵌套，直接找出所有 main.caml
// ==========================================
static NSArray<NSURL *> *findCAMLFiles(NSString *tendiesBasePath) {
    NSMutableArray *camlURLs = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:tendiesBasePath];
    NSString *filePath;
    
    while ((filePath = [enumerator nextObject])) {
        // iOS 壁纸的 CoreAnimation 引擎入口通常命名为 main.caml
        if ([filePath hasSuffix:@"main.caml"]) {
            NSString *fullPath = [tendiesBasePath stringByAppendingPathComponent:filePath];
            [camlURLs addObject:[NSURL fileURLWithPath:fullPath]];
        }
    }
    return camlURLs;
}

static const void *kCustomCAMLLayersKey = &kCustomCAMLLayersKey;
static const void *kCustomStateControllersKey = &kCustomStateControllersKey;


%group iOS14_15_Support

%hook SBFWallpaperView

- (id)initWithFrame:(CGRect)frame configuration:(id)configuration variant:(long long)variant cacheGroup:(id)group delegate:(id)delegate options:(unsigned long long)options {
    SBFWallpaperView *orig = %orig;
    if (orig && g_enabled) {
        if (g_tendiesPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:g_tendiesPath]) {
            
            // 自动递归搜索刚才解压好的文件夹中的 main.caml
            NSArray<NSURL *> *camlURLs = findCAMLFiles(g_tendiesPath);
            NSMutableArray *layersArray = [NSMutableArray array];
            NSMutableArray *controllersArray = [NSMutableArray array];
            
            for (NSURL *camlURL in camlURLs) {
                // 将上一级目录作为素材根目录
                NSURL *baseURL = [camlURL URLByDeletingLastPathComponent];
                
                CAMLParser *parser = [[%c(CAMLParser) alloc] init];
                [parser setBaseURL:baseURL];
                
                if ([parser parseContentsOfURL:camlURL]) {
                    CALayer *camlLayer = parser.result;
                    if (camlLayer && [camlLayer isKindOfClass:[CALayer class]]) {
                        camlLayer.frame = orig.bounds;
                        camlLayer.masksToBounds = YES;
                        [orig.layer addSublayer:camlLayer];
                        
                        CAStateController *stateController = [[%c(CAStateController) alloc] initWithLayer:camlLayer];
                        [layersArray addObject:camlLayer];
                        [controllersArray addObject:stateController];
                    }
                }
            }
            
            if (layersArray.count > 0) {
                objc_setAssociatedObject(orig, kCustomCAMLLayersKey, layersArray, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(orig, kCustomStateControllersKey, controllersArray, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                
                [[NSNotificationCenter defaultCenter] addObserver:orig selector:@selector(tendies_handleLockStateChange:) name:@"TendiesLockStateChanged" object:nil];
            }
        }
    }
    return orig;
}

%new
- (void)tendies_handleLockStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"]; 
    NSArray *controllers = objc_getAssociatedObject(self, kCustomStateControllersKey);
    NSArray *layers = objc_getAssociatedObject(self, kCustomCAMLLayersKey);
    
    if (controllers && layers && controllers.count == layers.count) {
        for (NSUInteger i = 0; i < controllers.count; i++) {
            CAStateController *ctrl = controllers[i];
            CALayer *lyr = layers[i];
            // 发送 Locked / Unlock 状态驱动底层动画
            [ctrl setState:state ofLayer:lyr]; 
        }
    }
}

- (void)layoutSubviews {
    %orig;
    NSArray *layers = objc_getAssociatedObject(self, kCustomCAMLLayersKey);
    if (layers) {
        for (CALayer *lyr in layers) {
            lyr.frame = self.bounds;
        }
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}
%end

%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (g_enabled) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesLockStateChanged" object:nil userInfo:@{@"state": @"Locked"}];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (g_enabled) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesLockStateChanged" object:nil userInfo:@{@"state": @"Unlock"}];
    }
}
%end

%end // iOS14_15_Support


%group iOS16_17_Support

%hook PRPosterDescriptor

- (id)_initWithPath:(id)path {
    // 留空拦截占位，保障 iOS16+ PosterKit Hook 的接入点
    return %orig(path);
}

%end

%end // iOS16_17_Support


%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    
    if (!g_enabled) return;
    
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    double version = kCFCoreFoundationVersionNumber;
    
    if (version < 1953.1) {
        if ([bundleId isEqualToString:@"com.apple.springboard"]) {
            %init(iOS14_15_Support);
        }
    } else {
        if ([bundleId isEqualToString:@"com.apple.PosterBoard"]) {
            %init(iOS16_17_Support);
        }
    }
}
