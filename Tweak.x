#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// ==========================================
// 1. 头文件声明 (基于你的 dump)
// ==========================================

@interface CAMLParser : NSObject
@property (retain) NSURL *baseURL;
@property (readonly) id result; 
+ (id)parseContentsOfURL:(id)url;
@end

@interface CAStateController : NSObject
@property (readonly) CALayer *layer;
- (id)initWithLayer:(id)layer;
- (void)setState:(id)state ofLayer:(id)layer;
@end

@interface SBFWallpaperView : UIView
@property (nonatomic) long long variant; // 0 = LockScreen, 1 = HomeScreen
@end

@interface CSCoverSheetViewController : UIViewController
@end

@interface PRSPosterPath : NSObject
- (NSURL *)serverIdentityURL;
@end

// 动态绑定的 Key
static const void *kCustomCAMLLayerKey = &kCustomCAMLLayerKey;
static const void *kCustomStateControllerKey = &kCustomStateControllerKey;

// 读取偏好设置
static BOOL isTweakEnabled() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"];
    if (prefs[@"Enabled"]) {
        return [prefs[@"Enabled"] boolValue];
    }
    return YES;
}

static NSString *getTendiesPath() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"];
    NSString *path = prefs[@"TendiesPath"];
    if (path && path.length > 0) {
        return path;
    }
    // 默认测试路径，请确保该路径下有解压的 .tendies 内容 (包含 main.caml)
    return @"/var/mobile/Documents/KFC Bucket/TestWallpaper.tendies"; 
}

// ==========================================
// 2. iOS 14 - 15 (SpringBoard 渲染逻辑)
// ==========================================
%group iOS14_15_Support

%hook SBFWallpaperView

- (id)initWithFrame:(CGRect)frame configuration:(id)configuration variant:(long long)variant cacheGroup:(id)group delegate:(id)delegate options:(unsigned long long)options {
    SBFWallpaperView *orig = %orig;
    if (orig && isTweakEnabled()) {
        NSString *tendiesPath = getTendiesPath();
        
        // 我们需要找到 .ca 文件夹内的 main.caml
        // 假设结构为: tendiesPath/contents/xxxx.ca/main.caml (根据你的 Mario 源码分析)
        // 这里为了演示，直接写死寻找 main.caml 的逻辑，实际开发中建议写一个遍历文件夹找 .ca 的逻辑
        NSString *camlPath = [tendiesPath stringByAppendingPathComponent:@"contents/7400.WWDC_2022_Background-390w-844h@3x~iphone.ca/main.caml"];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:camlPath]) {
            NSURL *camlURL = [NSURL fileURLWithPath:camlPath];
            NSURL *baseURL = [camlURL URLByDeletingLastPathComponent]; // 设置 assets 相对路径基准
            
            CAMLParser *parser = [[%c(CAMLParser) alloc] init];
            [parser setBaseURL:baseURL];
            [parser parseContentsOfURL:camlURL];
            
            CALayer *camlLayer = parser.result;
            if (camlLayer && [camlLayer isKindOfClass:[CALayer class]]) {
                camlLayer.frame = orig.bounds;
                [orig.layer addSublayer:camlLayer];
                
                CAStateController *stateController = [[%c(CAStateController) alloc] initWithLayer:camlLayer];
                objc_setAssociatedObject(orig, kCustomCAMLLayerKey, camlLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(orig, kCustomStateControllerKey, stateController, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                
                // 监听锁屏状态广播
                [[NSNotificationCenter defaultCenter] addObserver:orig selector:@selector(tendies_handleLockStateChange:) name:@"TendiesLockStateChanged" object:nil];
            }
        }
    }
    return orig;
}

%new
- (void)tendies_handleLockStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"]; // "Locked" 或 "Unlock"
    CAStateController *controller = objc_getAssociatedObject(self, kCustomStateControllerKey);
    CALayer *camlLayer = objc_getAssociatedObject(self, kCustomCAMLLayerKey);
    
    if (controller && camlLayer) {
        [controller setState:state ofLayer:camlLayer];
    }
}

- (void)layoutSubviews {
    %orig;
    CALayer *camlLayer = objc_getAssociatedObject(self, kCustomCAMLLayerKey);
    if (camlLayer) {
        camlLayer.frame = self.bounds;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}
%end


%hook CSCoverSheetViewController

// 锁屏出现 -> 播放锁定动画
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (isTweakEnabled()) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesLockStateChanged" userInfo:@{@"state": @"Locked"}];
    }
}

// 锁屏消失 (解锁) -> 播放解锁动画
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (isTweakEnabled()) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesLockStateChanged" userInfo:@{@"state": @"Unlock"}];
    }
}

%end

%end // iOS14_15_Support


// ==========================================
// 3. iOS 16 - 17 (PosterBoard 注入逻辑)
// ==========================================
%group iOS16_17_Support

%hook PRPosterDescriptor

// 拦截原生壁纸的加载，替换为我们的 Tendies
- (id)_initWithPath:(PRSPosterPath *)path {
    if (isTweakEnabled()) {
        NSString *customTendiesPath = getTendiesPath();
        // 只有当用户在设置中开启且配置了路径时，强制替换当前加载的描述文件
        // ⚠️注意：在生产环境中，你应该通过判断特定的标识符来决定是否替换，防止覆盖所有系统壁纸
        if ([[NSFileManager defaultManager] fileExistsAtPath:customTendiesPath]) {
            // 通过 hook 强制改变加载路径
            // 由于系统安全机制，通常需要将 .tendies 放在 AppGroup 或沙盒中
            NSURL *customURL = [NSURL fileURLWithPath:customTendiesPath];
            // 这部分涉及私有类 PRSPosterPath 的重新初始化，此处为逻辑示例
            // 真实情况可以通过 method swizzling `serverIdentityURL` 方法返回我们的 URL
        }
    }
    return %orig(path);
}

%end

%end // iOS16_17_Support


// ==========================================
// 4. 构造函数 (入口)
// ==========================================
%ctor {
    if (!isTweakEnabled()) return;
    
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    double version = kCFCoreFoundationVersionNumber;
    
    // iOS 16.0 的 CFCoreFoundationVersionNumber 约等于 1953.1
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
