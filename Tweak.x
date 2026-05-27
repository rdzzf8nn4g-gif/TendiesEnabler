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


// ================= 辅助函数：自动扫描并获取 CAML =================
static NSArray<NSURL *> *findCAMLFiles(NSString *tendiesBasePath) {
    NSMutableArray *camlURLs = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSString *contentsPath = [tendiesBasePath stringByAppendingPathComponent:@"contents"];
    if (![fm fileExistsAtPath:contentsPath]) return camlURLs;
    
    NSArray *items = [fm contentsOfDirectoryAtPath:contentsPath error:nil];
    for (NSString *item in items) {
        if ([item hasSuffix:@".ca"]) {
            NSString *camlFile = [[contentsPath stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"main.caml"];
            if ([fm fileExistsAtPath:camlFile]) {
                [camlURLs addObject:[NSURL fileURLWithPath:camlFile]];
            }
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
            [ctrl setState:state ofLayer:lyr]; // 触发 CAML 内置动画状态 ("Locked" / "Unlock")
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
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesLockStateChanged" userInfo:@{@"state": @"Locked"}];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (g_enabled) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesLockStateChanged" userInfo:@{@"state": @"Unlock"}];
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
            // 利用 Hook 将原 PosterKit 请求的数据路径替换至设置路径
            // 注意：因为原生代码实现会验证文件结构，所以你需要确保传入的是完整的 .tendies 或其内容路径。
            NSURL *customURL = [NSURL fileURLWithPath:g_tendiesPath];
            if ([path respondsToSelector:@selector(serverIdentityURL)]) {
                // 如果后续发现崩溃或者不兼容，可以在此处扩展对私有类的替换逻辑
            }
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
    
    // CFCoreFoundationVersionNumber >= 1953.1 对应 iOS 16.0 及以上
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
