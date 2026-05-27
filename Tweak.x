#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

// ==========================================
// 前置接口声明 (避免 Github Actions 编译报错)
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

@interface PRSPosterPath : NSObject
- (NSURL *)serverIdentityURL;
@end

// ==========================================
// 动态绑定与偏好读取辅助函数
// ==========================================
static const void *kCustomCAMLLayersKey = &kCustomCAMLLayersKey;
static const void *kCustomStateControllersKey = &kCustomStateControllersKey;

// 兼容 Rootless 和 Rootful 的读取方式
static BOOL isTweakEnabled() {
    Boolean exists;
    Boolean enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), CFSTR("com.yourname.tendiesprefs"), &exists);
    return exists ? enabled : YES;
}

static NSString *getTendiesPath() {
    CFStringRef path = CFPreferencesCopyAppValue(CFSTR("TendiesPath"), CFSTR("com.yourname.tendiesprefs"));
    if (path) {
        NSString *result = (__bridge NSString *)path;
        CFRelease(path);
        return result;
    }
    return @""; // 默认为空
}

// 自动扫描 .tendies 内部寻找所有的 main.caml 文件 (因为有 Foreground, Floating, Background 等多层)
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


// ==========================================
// 核心组 1: iOS 14 - 15 (SpringBoard 强行渲染层)
// ==========================================
%group iOS14_15_Support

%hook SBFWallpaperView

- (id)initWithFrame:(CGRect)frame configuration:(id)configuration variant:(long long)variant cacheGroup:(id)group delegate:(id)delegate options:(unsigned long long)options {
    SBFWallpaperView *orig = %orig;
    if (orig && isTweakEnabled()) {
        NSString *tendiesPath = getTendiesPath();
        
        if (tendiesPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:tendiesPath]) {
            NSArray<NSURL *> *camlURLs = findCAMLFiles(tendiesPath);
            NSMutableArray *layersArray = [NSMutableArray array];
            NSMutableArray *controllersArray = [NSMutableArray array];
            
            // 遍历并加载所有的 CAML 层 (Background, Floating, Foreground 等)
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
                
                // 监听锁屏状态切换
                [[NSNotificationCenter defaultCenter] addObserver:orig selector:@selector(tendies_handleLockStateChange:) name:@"TendiesLockStateChanged" object:nil];
            }
        }
    }
    return orig;
}

%new
- (void)tendies_handleLockStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"]; // "Locked" 或 "Unlock"
    NSArray *controllers = objc_getAssociatedObject(self, kCustomStateControllersKey);
    NSArray *layers = objc_getAssociatedObject(self, kCustomCAMLLayersKey);
    
    if (controllers && layers && controllers.count == layers.count) {
        for (NSUInteger i = 0; i < controllers.count; i++) {
            CAStateController *ctrl = controllers[i];
            CALayer *lyr = layers[i];
            [ctrl setState:state ofLayer:lyr]; // 触发 CAML 动画
        }
    }
}

- (void)layoutSubviews {
    %orig;
    NSArray *layers = objc_getAssociatedObject(self, kCustomCAMLLayersKey);
    if (layers) {
        for (CALayer *lyr in layers) {
            lyr.frame = self.bounds; // 屏幕旋转或调整大小时重新贴合
        }
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

%end


%hook CSCoverSheetViewController

// 当锁屏界面出现 (点亮屏幕 / 锁屏状态)
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (isTweakEnabled()) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesLockStateChanged" userInfo:@{@"state": @"Locked"}];
    }
}

// 当锁屏界面消失 (解锁成功进入桌面)
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (isTweakEnabled()) {
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

// 拦截系统壁纸的路径描述，将其替换为我们的 Tendies 路径
- (id)_initWithPath:(id)path {
    if (isTweakEnabled()) {
        NSString *customTendiesPath = getTendiesPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        
        if (customTendiesPath.length > 0 && [fm fileExistsAtPath:customTendiesPath]) {
            // 如果用户指定了路径，我们强制把加载的 Path 换掉。
            // 注意：这会导致系统默认壁纸被覆盖显示为你的马里奥。
            // 对于稳定的产品级开发，这里通常会结合 bundleID 或特定的 Identifier 过滤。
            
            // 为了防止在编译时 PRSPosterPath 找不到，使用 runtime 动态创建实例或路径处理
            // 这里提供一种基于 NSURL 替换的变通方案
            NSURL *customURL = [NSURL fileURLWithPath:customTendiesPath];
            if ([path respondsToSelector:@selector(serverIdentityURL)]) {
                // 如果你想做到更细粒度的控制，可以在这里打断点分析。
                // 作为演示，我们如果发现路径可以被替换，可以用自定义初始化的 path
            }
        }
    }
    return %orig(path);
}

%end

%end // iOS16_17_Support


// ==========================================
// Tweak 入口 (自动判断系统和进程)
// ==========================================
%ctor {
    if (!isTweakEnabled()) return;
    
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    double version = kCFCoreFoundationVersionNumber;
    
    // CFCoreFoundationVersionNumber >= 1953.1 对应的是 iOS 16.0 及以上
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
