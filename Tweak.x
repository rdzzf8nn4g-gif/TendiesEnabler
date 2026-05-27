#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 接口与继承声明 (解决编译指针报错)
// ==========================================
@interface CAPackage : NSObject
+ (id)packageWithContentsOfURL:(NSURL *)url type:(NSString *)type options:(NSDictionary *)options error:(NSError **)outError;
@end

@interface CAStateController : NSObject
@property (readonly) CALayer *layer;
- (id)initWithLayer:(id)layer;
- (void)setState:(id)state ofLayer:(id)layer;
@end

@interface CSCoverSheetViewController : UIViewController
@property (nonatomic, readonly) BOOL isTransitioning;
- (void)setInScreenOffMode:(BOOL)mode;
@end

// 明确继承关系，让编译器闭嘴
@interface CSCoverSheetView : UIView
@end
@interface SBFWallpaperView : UIView
@end
@interface PBUIWallpaperView : UIView
@end

// ==========================================
// 全局变量与路径
// ==========================================
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【替换真实 bundleID】
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static NSHashTable *g_allTendiesViews = nil;
static NSString *g_tendiesPath = @"";
static BOOL g_enabled = YES;

static NSArray<NSURL *> *FindCAPackageURLsInTendies(NSString *basePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
    NSString *file;
    NSMutableArray *caURLs = [NSMutableArray array];

    while ((file = [enumerator nextObject])) {
        if ([file containsString:@"__MACOSX"] || [file.lastPathComponent hasPrefix:@"."]) continue;
        if ([file hasSuffix:@".ca"]) {
            NSString *caPath = [basePath stringByAppendingPathComponent:file];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:caPath isDirectory:&isDir] && isDir) {
                [caURLs addObject:[NSURL fileURLWithPath:caPath]];
            }
        }
    }

    [caURLs sortUsingComparator:^NSComparisonResult(NSURL *u1, NSURL *u2) {
        int w1 = [u1.path.lowercaseString containsString:@"background"] ? 0 : ([u1.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        int w2 = [u2.path.lowercaseString containsString:@"background"] ? 0 : ([u2.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        return (w1 < w2) ? NSOrderedAscending : ((w1 > w2) ? NSOrderedDescending : NSOrderedSame);
    }];
    return caURLs;
}

// ==========================================
// 核心视图类 (彻底修复动画罢工)
// ==========================================
@interface TendiesView : UIView
@property (nonatomic, strong) NSMutableArray *camlLayers;
@property (nonatomic, strong) NSMutableArray *stateControllers;
@property (nonatomic, strong) NSString *currentState;
- (void)loadTendiesFromPath:(NSString *)path;
- (void)setState:(NSString *)state;
@end

@implementation TendiesView
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.camlLayers = [NSMutableArray array];
        self.stateControllers = [NSMutableArray array];
        self.userInteractionEnabled = NO; // 不阻挡底层触摸
        self.backgroundColor = [UIColor blackColor]; // 加黑底，防止系统壁纸透底
    }
    return self;
}

- (void)loadTendiesFromPath:(NSString *)path {
    for (CALayer *layer in self.camlLayers) {
        [layer removeFromSuperlayer];
    }
    [self.camlLayers removeAllObjects];
    [self.stateControllers removeAllObjects];

    if (!g_enabled || path.length == 0) return;

    NSArray *caURLs = FindCAPackageURLsInTendies(path);
    Class CAPackageClass = NSClassFromString(@"CAPackage");
    
    for (NSURL *url in caURLs) {
        if (CAPackageClass) {
            NSError *error = nil;
            id package = [CAPackageClass packageWithContentsOfURL:url type:@"com.apple.coreanimation-bundle" options:nil error:&error];
            if (package) {
                CALayer *layer = [package valueForKey:@"rootLayer"];
                if ([layer isKindOfClass:[CALayer class]]) {
                    layer.frame = self.bounds;
                    layer.masksToBounds = YES;
                    layer.allowsEdgeAntialiasing = YES;
                    
                    // 【核心修复1】防止系统省电机制休眠动画引擎
                    layer.speed = 1.0; 
                    
                    [self.layer addSublayer:layer];
                    [self.camlLayers addObject:layer];

                    CAStateController *sc = [[%c(CAStateController) alloc] initWithLayer:layer];
                    [self.stateControllers addObject:sc];
                    
                    if (self.currentState) {
                        [sc setState:self.currentState ofLayer:layer];
                    }
                }
            }
        }
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 【核心修复2】每次布局刷新时，强制唤醒动画层
    self.layer.speed = 1.0; 
    for (CALayer *layer in self.camlLayers) {
        layer.frame = self.bounds;
        layer.speed = 1.0; 
    }
}

- (void)setState:(NSString *)state {
    if (!state || [self.currentState isEqualToString:state]) return;
    self.currentState = state;
    for (int i = 0; i < self.camlLayers.count; i++) {
        CAStateController *sc = self.stateControllers[i];
        CALayer *layer = self.camlLayers[i];
        [sc setState:state ofLayer:layer];
    }
}
@end

static void reloadPrefsAndInject() {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
    g_enabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : YES;
    g_tendiesPath = dict[@"TendiesPath"] ?: @"";
    
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) {
            [tView loadTendiesFromPath:g_tendiesPath];
        }
    }
}

// 智能挂载器：区分桌面与锁屏，隔离后台卡片
static void injectTendiesSmart(UIView *container, BOOL isLockscreen) {
    if (!container || !container.window) return;
    
    // 【核心修复3】白名单隔离：彻底干掉多任务后台卡片出现壁纸的 Bug
    NSString *winClass = NSStringFromClass([container.window class]);
    if (![winClass containsString:@"WallpaperWindow"] && 
        ![winClass containsString:@"CoverSheet"] && 
        ![winClass containsString:@"SecureWindow"]) {
        return; // 凡是后台卡片、文件夹背景的渲染，直接拒绝注入！
    }
    
    TendiesView *tView = objc_getAssociatedObject(container, "TendiesView");
    if (!tView) {
        tView = [[TendiesView alloc] initWithFrame:container.bounds];
        tView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        
        if (isLockscreen) {
            // 锁屏：垫在 CoverSheet 最底层，绝不能 hide 系统子视图（否则没时间/通知）
            [container insertSubview:tView atIndex:0];
        } else {
            // 桌面：直接铺满
            [container addSubview:tView];
        }
        
        objc_setAssociatedObject(container, "TendiesView", tView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        @synchronized(g_allTendiesViews) {
            if (!g_allTendiesViews) g_allTendiesViews = [NSHashTable weakObjectsHashTable];
            [g_allTendiesViews addObject:tView];
        }
        
        [tView loadTendiesFromPath:g_tendiesPath];
    } else {
        tView.frame = container.bounds;
        if (isLockscreen) {
            [container sendSubviewToBack:tView];
        } else {
            [container bringSubviewToFront:tView];
        }
    }
    
    // 【核心修复4】温和隐藏：仅对桌面执行隐藏操作，完美避开 iOS 16/17 触摸失效崩溃
    if (!isLockscreen) {
        for (UIView *sub in container.subviews) {
            if (sub != tView && !sub.hidden) {
                sub.hidden = YES;
            }
        }
    }
}

// ==========================================
// 动态 Hook 注入区
// ==========================================

%group UniversalWallpaper

// --- 桌面壁纸注入 (iOS 14-15 全局) ---
%hook SBFWallpaperView
- (void)didMoveToWindow {
    %orig;
    injectTendiesSmart((UIView *)self, NO);
}
- (void)layoutSubviews {
    %orig;
    injectTendiesSmart((UIView *)self, NO);
}
%end

// --- 锁屏壁纸注入 (iOS 14-17 通杀) ---
// 这招直接覆盖在原生锁屏海报系统上面，一劳永逸
%hook CSCoverSheetView
- (void)didMoveToWindow {
    %orig;
    injectTendiesSmart((UIView *)self, YES);
}
- (void)layoutSubviews {
    %orig;
    injectTendiesSmart((UIView *)self, YES);
}
%end

// --- 交互手势驱动区 ---
%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) [v setState:@"Locked"];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) [v setState:@"Unlock"];
    }
}

// 截取上滑手势，瞬间触发互动
- (void)_scrollPanGestureBegan:(id)arg {
    %orig;
    if ([arg isKindOfClass:[UIPanGestureRecognizer class]]) {
        UIPanGestureRecognizer *gesture = (UIPanGestureRecognizer *)arg;
        CGPoint velocity = [gesture velocityInView:gesture.view];
        if (velocity.y < 0) { 
            @synchronized(g_allTendiesViews) {
                for (TendiesView *v in g_allTendiesViews) [v setState:@"Unlock"];
            }
        }
    }
}

// 防止手势取消卡在半空
- (void)_scrollPanGestureEnded:(id)arg {
    %orig;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf && weakSelf.view.window && !weakSelf.isTransitioning) {
            @synchronized(g_allTendiesViews) {
                for (TendiesView *v in g_allTendiesViews) [v setState:@"Locked"];
            }
        }
    });
}

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *newState = mode ? @"Sleep" : @"Locked";
    @synchronized(g_allTendiesViews) {
        for (TendiesView *v in g_allTendiesViews) [v setState:newState];
    }
}
%end
%end // UniversalWallpaper


// --------------------------------------------------
// iOS 16+ 桌面特有注入
// --------------------------------------------------
%group iOS16Up

%hook PBUIWallpaperView
- (void)didMoveToWindow {
    %orig;
    injectTendiesSmart((UIView *)self, NO);
}
- (void)layoutSubviews {
    %orig;
    injectTendiesSmart((UIView *)self, NO);
}
%end

%end // iOS16Up

// ==========================================
// 热重载通知中枢
// ==========================================
static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        reloadPrefsAndInject();
    });
}

%ctor {
    reloadPrefsAndInject();
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        
        %init(UniversalWallpaper);
        
        if (NSClassFromString(@"PBUIWallpaperView")) {
            %init(iOS16Up);
        }
    }
}
