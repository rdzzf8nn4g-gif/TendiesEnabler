#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#include <sys/stat.h>

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

// ==========================================
// 全局变量与核心逻辑
// ==========================================
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist" // 请替换为你真实的 bundleID

static NSHashTable *g_allTendiesViews = nil;
static NSString *g_tendiesPath = @"";
static BOOL g_enabled = YES;

static NSArray<NSURL *> *FindCAMLURLsInTendies(NSString *basePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // enumeratorAtPath 是深度递归遍历，完美应对极深的描述文件结构
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
    NSString *file;
    NSMutableArray *camlURLs = [NSMutableArray array];

    while ((file = [enumerator nextObject])) {
        // 屏蔽隐藏文件与 macOS 缓存垃圾
        if ([file containsString:@"__MACOSX"] || [file.lastPathComponent hasPrefix:@"."]) continue;
        
        if ([file hasSuffix:@".ca"]) {
            NSString *camlPath = [[basePath stringByAppendingPathComponent:file] stringByAppendingPathComponent:@"main.caml"];
            if ([fm fileExistsAtPath:camlPath]) {
                [camlURLs addObject:[NSURL fileURLWithPath:camlPath]];
            }
        }
    }

    // 强制排序：背景(Background) -> 悬浮(Floating) -> 前景(Foreground)
    [camlURLs sortUsingComparator:^NSComparisonResult(NSURL *u1, NSURL *u2) {
        int w1 = [u1.path.lowercaseString containsString:@"background"] ? 0 : ([u1.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        int w2 = [u2.path.lowercaseString containsString:@"background"] ? 0 : ([u2.path.lowercaseString containsString:@"floating"] ? 1 : 2);
        return (w1 < w2) ? NSOrderedAscending : ((w1 > w2) ? NSOrderedDescending : NSOrderedSame);
    }];
    return camlURLs;
}

// ==========================================
// 核心视图类：在 SB 壁纸层上承载 CAML 动画
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
        self.userInteractionEnabled = NO; // 绝对不阻挡用户触摸
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

    NSArray *camlURLs = FindCAMLURLsInTendies(path);
    for (NSURL *url in camlURLs) {
        CAMLParser *parser = [[%c(CAMLParser) alloc] init];
        [parser setBaseURL:[url URLByDeletingLastPathComponent]];
        if ([parser parseContentsOfURL:url]) {
            CALayer *layer = parser.result;
            if ([layer isKindOfClass:[CALayer class]]) {
                layer.frame = self.bounds;
                layer.masksToBounds = YES;
                layer.allowsEdgeAntialiasing = YES;
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

- (void)layoutSubviews {
    [super layoutSubviews];
    for (CALayer *layer in self.camlLayers) {
        layer.frame = self.bounds;
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
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    g_enabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : YES;
    g_tendiesPath = dict[@"TendiesPath"] ?: @"";
    
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) {
            [tView loadTendiesFromPath:g_tendiesPath];
        }
    }
}

// 统一的壁纸底板挂载器
static void injectTendiesIntoWallpaperView(UIView *wallpaperView, long long variant) {
    if (!wallpaperView) return;
    
    TendiesView *tView = objc_getAssociatedObject(wallpaperView, "TendiesView");
    if (!tView) {
        tView = [[TendiesView alloc] initWithFrame:wallpaperView.bounds];
        tView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [wallpaperView addSubview:tView];
        objc_setAssociatedObject(wallpaperView, "TendiesView", tView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        @synchronized(g_allTendiesViews) {
            if (!g_allTendiesViews) g_allTendiesViews = [NSHashTable weakObjectsHashTable];
            [g_allTendiesViews addObject:tView];
        }
        
        [tView loadTendiesFromPath:g_tendiesPath];
    }
    
    [wallpaperView bringSubviewToFront:tView];
    [tView setState:(variant == 0 ? @"Locked" : @"Unlock")]; // 0=锁屏，1=桌面
}

// ==========================================
// 动态 Hook 注入区
// ==========================================
%group UniversalWallpaper

// 针对 iOS 14-15 的底板
%hook SBFWallpaperView
- (void)didMoveToWindow {
    %orig;
    if (self.window) injectTendiesIntoWallpaperView(self, (long long)[self performSelector:@selector(variant)]);
}
- (void)layoutSubviews {
    %orig;
    TendiesView *tView = objc_getAssociatedObject(self, "TendiesView");
    if (tView) [self bringSubviewToFront:tView];
}
%end

// 针对 iOS 16-17 的底板（最强突破，直接覆盖在原生海报系统之上）
%hook PBUIWallpaperView
- (void)didMoveToWindow {
    %orig;
    if (self.window) injectTendiesIntoWallpaperView(self, (long long)[self performSelector:@selector(variant)]);
}
- (void)layoutSubviews {
    %orig;
    TendiesView *tView = objc_getAssociatedObject(self, "TendiesView");
    if (tView) [self bringSubviewToFront:tView];
}
%end

// 监听锁屏状态切换，实时派发动画状态
%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:@"Locked"];
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    @synchronized(g_allTendiesViews) {
        for (TendiesView *tView in g_allTendiesViews) [tView setState:@"Unlock"];
    }
}
%end

%end // UniversalWallpaper

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
    }
}
