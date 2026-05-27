#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

// ================= 终极环境适配 (Rootful/Rootless/Roothide) =================
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

// ================= 全局变量与配置读取 =================
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

// ================= 前置接口声明 (避免 Github Actions 编译报错) =================
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


// ================= 辅助函数：深度递归扫描解压后的 CAML 文件 =================
static NSArray<NSURL *> *findCAMLFiles(NSString *tendiesBasePath) {
    NSMutableArray *camlURLs = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 使用枚举器深度遍历解压后的文件夹，寻找所有以 .ca/main.caml 结尾的文件
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:tendiesBasePath];
    NSString *file;
    while (file = [enumerator nextObject]) {
        if ([file hasSuffix:@".ca/main.caml"]) {
            NSString *fullPath = [tendiesBasePath stringByAppendingPathComponent:file];
            [camlURLs addObject:[NSURL fileURLWithPath:fullPath]];
        }
    }
    return camlURLs;
}

static const void *kCustomCAMLLayersKey = &kCustomCAMLLayersKey;
static const void *kCustomStateControllersKey = &kCustomStateControllersKey;


// ==========================================
// 核心组 1: iOS 14 - 15 (SpringBoard 强行渲染层)
// ==========================================
%group iOS14_15_Support

%hook SBFWallpaperView

- (id)initWithFrame:(CGRect)frame configuration:(id)configuration variant:(long long)variant cacheGroup:(id)group delegate:(id)delegate options:(unsigned long long)options {
    SBFWallpaperView *orig = %orig;
    if (orig && g_enabled) {
        if (g_tendiesPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:g_tendiesPath]) {
            NSArray<NSURL *> *camlURLs = findCAMLFiles(g_tendiesPath);
            NSMutableArray *layersArray = [NSMutableArray array];
            NSMutableArray *controllersArray = [NSMutableArray array];
            
            // 遍历所有 .ca 文件夹加载层
            for (NSURL *camlURL in camlURLs) {
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
        // 【已修复】：补全了 object:nil 参数
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesLockStateChanged" object:nil userInfo:@{@"state": @"Locked"}];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (g_enabled) {
        // 【已修复】：补全了 object:nil 参数
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesLockStateChanged" object:nil userInfo:@{@"state": @"Unlock"}];
    }
}
%end

%end // iOS14_15_Support


// ==========================================
// 核心组 2: iOS 16 - 17 (PosterBoard 劫持)
// ==========================================
%group iOS16_17_Support

%hook PRPosterDescriptor

- (id)_initWithPath:(id)path {
    if (g_enabled && g_tendiesPath.length > 0) {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:g_tendiesPath]) {
            // 【已修复】：删除了未使用导致报错的 customURL 变量
            // 此处用于未来可能的 PosterKit Hook
        }
    }
    return %orig(path);
}

%end

%end // iOS16_17_Support


// ==========================================
// Tweak 入口
// ==========================================
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
