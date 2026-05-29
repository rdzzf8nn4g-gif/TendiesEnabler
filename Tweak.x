#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>

// ==========================================
// 1. 越狱环境适配
// ==========================================
#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

static NSString * GetTendiesStorageDir() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesenabler.media";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

// ==========================================
// 2. iOS 16/17+ 系统私有 API 声明
// ==========================================
@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
- (BOOL)setState:(NSString *)state animated:(BOOL)animated;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setDismissed:(BOOL)dismissed;
@end

@interface SBCoverSheetSlidingViewController : UIViewController
- (CGRect)_updatePositionViewForProgress:(double)progress velocity:(double)velocity forPresentationValue:(BOOL)value;
@end

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
@end

// ==========================================
// 3. 全局配置与状态同步
// ==========================================
static BOOL g_enabled = NO;
static NSString *g_tendiesPath = nil;
static BOOL g_isUnlocked = NO; 
static BOOL g_isScreenOn = YES;

static void reloadPrefs() {
    CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
    CFPreferencesAppSynchronize(appID);
    Boolean valid;
    g_enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &valid) ? valid : NO;
    CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("TendiesPath"), appID);
    if (pathRef && CFGetTypeID(pathRef) == CFStringGetTypeID()) {
        g_tendiesPath = [(__bridge NSString *)pathRef copy];
    } else {
        g_tendiesPath = [GetTendiesStorageDir() stringByAppendingPathComponent:@"ActiveTendies"];
    }
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

// ==========================================
// 4. 核心渲染引擎 (修复环境动画与指尖跟踪)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isPathCached;
@property (nonatomic, assign) BOOL isUnlocking; 
@property (nonatomic, strong) NSString *cachedBgPath;
@property (nonatomic, strong) NSString *cachedFloatPath;
@property (nonatomic, strong) NSString *cachedFgPath;
@property (nonatomic, strong) NSString *currentState;

- (void)reloadWallpaperViews;
- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated;
- (void)onWakeUp;
- (void)onSleep;
- (void)onSwipeProgress:(NSNotification *)note;
@end

@implementation TendiesRenderEngineView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 黑色底色：彻底阻断底层桌面透视
        self.backgroundColor = [UIColor blackColor]; 
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.isPathCached = NO;
        self.isUnlocking = NO;
        self.currentState = @"Init";
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"TendiesEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"TendiesEngineSleep" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSwipeProgress:) name:@"TendiesEngineSwipeProgress" object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)forceReload {
    self.isPathCached = NO;
    self.cachedBgPath = nil;
    self.cachedFloatPath = nil;
    self.cachedFgPath = nil;
    [self reloadWallpaperViews];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.bgView) self.bgView.frame = self.bounds;
    if (self.floatingView) self.floatingView.frame = self.bounds;
    if (self.fgView) self.fgView.frame = self.bounds;
}

- (void)onWakeUp {
    if (!g_enabled) return;
    self.isUnlocking = NO;
    
    // 强制恢复流速，抵抗系统息屏挂起
    self.layer.speed = 1.0;
    if (self.bgView) { self.bgView.layer.speed = 1.0; self.bgView.layer.timeOffset = 0.0; }
    if (self.floatingView) { self.floatingView.layer.speed = 1.0; self.floatingView.layer.timeOffset = 0.0; }
    if (self.fgView) { self.fgView.layer.speed = 1.0; self.fgView.layer.timeOffset = 0.0; }

    [CATransaction begin];
    [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
    [CATransaction commit];
    [CATransaction flush];
}

- (void)onSleep {
    if (!g_enabled) return;
    self.isUnlocking = NO;
    [self transitionToState:@"Sleep" animated:NO];
}

// 🎯 核心杀招：指尖阻尼动画！
- (void)onSwipeProgress:(NSNotification *)note {
    if (!g_enabled) return;
    double progress = [note.userInfo[@"progress"] doubleValue];
    
    // progress: 1.0 (完全锁住) -> 0.0 (解锁到桌面)
    if (progress < 0.99) {
        if (!self.isUnlocking) {
            self.isUnlocking = YES;
            // 冻结时间，准备手动拖拽动画
            self.bgView.layer.speed = 0.0;
            self.floatingView.layer.speed = 0.0;
            self.fgView.layer.speed = 0.0;
            [self transitionToState:@"Unlock" animated:YES];
        }
        // 映射百分比到 CAML 的动画时长 (CASpringAnimation 一般为 0.8s)
        // (1.0 - progress) 代表解锁的完成度：刚开始滑为 0.01，滑到底为 1.0
        CFTimeInterval offset = (1.0 - progress) * 0.8;
        if (self.bgView) self.bgView.layer.timeOffset = offset;
        if (self.floatingView) self.floatingView.layer.timeOffset = offset;
        if (self.fgView) self.fgView.layer.timeOffset = offset;
        
    } else {
        // 用户放弃滑动，回弹到原位
        if (self.isUnlocking) {
            self.isUnlocking = NO;
            // 恢复时间流动，让系统自己把动画播回去
            self.bgView.layer.speed = 1.0;
            self.floatingView.layer.speed = 1.0;
            self.fgView.layer.speed = 1.0;
            self.bgView.layer.timeOffset = 0.0;
            self.floatingView.layer.timeOffset = 0.0;
            self.fgView.layer.timeOffset = 0.0;
            [self transitionToState:@"Locked" animated:YES];
        }
    }
}

- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated {
    if (!g_enabled) return;
    
    // 防抖锁：阻止系统频繁重复下发导致动画闪烁
    if ([self.currentState isEqualToString:stateName]) return; 
    self.currentState = [stateName copy];
    
    if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
        [self.bgView setState:stateName animated:animated];
        [self.floatingView setState:stateName animated:animated];
        [self.fgView setState:stateName animated:animated];
    } else {
        [self.bgView setState:stateName];
        [self.floatingView setState:stateName];
        [self.fgView setState:stateName];
    }
}

- (void)reloadWallpaperViews {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (!g_enabled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
                self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            });
            return;
        }
        
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!g_tendiesPath || ![fm fileExistsAtPath:g_tendiesPath]) return;
        
        @synchronized(self) {
            if (!self.isPathCached) {
                NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
                for (NSURL *fileURL in dirEnum) {
                    NSString *pathString = fileURL.path;
                    NSString *fileName = fileURL.lastPathComponent;
                    if ([pathString hasSuffix:@"/"]) pathString = [pathString substringToIndex:pathString.length - 1];
                    if ([[[pathString pathExtension] lowercaseString] isEqualToString:@"ca"] || [pathString hasSuffix:@".ca"]) {
                        if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) self.cachedBgPath = [pathString copy];
                        else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) self.cachedFloatPath = [pathString copy];
                        else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) self.cachedFgPath = [pathString copy];
                    }
                }
                self.isPathCached = YES;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
            self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
            if (!handle) return; 
            Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
            if (!PackageViewClass) return;

            if (self.cachedBgPath) {
                self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedBgPath]];
                [self addSubview:self.bgView];
            }
            if (self.cachedFloatPath) {
                self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFloatPath]];
                [self addSubview:self.floatingView];
            }
            if (self.cachedFgPath) {
                self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFgPath]];
                [self addSubview:self.fgView];
            }
            [self setNeedsLayout];
            
            self.currentState = @"Init";
            [CATransaction begin];
            [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
            [CATransaction commit];
            [CATransaction flush];
        });
    });
}
@end


// ==========================================
// 🚨 杀招 1：屏蔽原生系统快照 (击杀“假渐变过渡”)
// ==========================================
%hook SBWallpaperController

- (void)_ingestPrimaryWallpaperLayersSnapshotIOSurface:(id)arg1 floatingWallpaperLayerSnapshotIOSurface:(id)arg2 snapshotScale:(double)arg3 traitCollection:(id)arg4 withCompletion:(id /* block */)arg5 {
    if (g_enabled) {
        // 直接熔断系统的 IOSurface 覆盖请求！
        if (arg5) { void (^completionBlock)(void) = arg5; completionBlock(); }
        return; 
    }
    %orig;
}

- (void)updatePosterSwitcherSnapshots {
    if (!g_enabled) %orig;
}

%end


// ==========================================
// 🚨 杀招 2：绝对精准挂载与视差逆向抵消
// ==========================================
%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    if (!g_enabled) return;
    
    // 把引擎直接插在锁屏视图的最最最底层！
    TendiesRenderEngineView *engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.view.bounds];
    objc_setAssociatedObject(self, "TendiesLockScreenEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.view insertSubview:engineView atIndex:0];
    [engineView reloadWallpaperViews];
}

- (void)viewWillLayoutSubviews {
    %orig;
    if (!g_enabled) return;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesLockScreenEngine");
    if (!engineView) return;
    
    // 确保它永远在最底层
    if (engineView.superview != self.view) {
        [engineView removeFromSuperview];
        [self.view insertSubview:engineView atIndex:0];
    }
    
    // ⚔️ 绝对神技：逆向视差抵消！
    // 无论锁屏怎么往上滑，我们通过 convertRect 让它始终锁定在屏幕 (Window) 原本的位置
    // 这样马里奥才不会跟着遮罩一起飞上去，而是安静地执行它的跳跃动画。
    if (self.view.window) {
        CGRect screenFixedFrame = [self.view.window convertRect:self.view.window.bounds toView:self.view];
        engineView.frame = screenFixedFrame;
    } else {
        engineView.frame = self.view.bounds;
    }
    
    // 隐藏系统原生海报 (防崩溃版 KVC)
    @try {
        id bgVC = [self valueForKey:@"_backgroundContentViewController"];
        if (bgVC) {
            UIView *bgView = [bgVC valueForKey:@"view"];
            if (bgView) {
                bgView.hidden = YES;
                bgView.alpha = 0.0;
            }
        }
    } @catch (NSException *e) {}
}

// 生命周期联动
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled && g_isScreenOn) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}

- (void)setDismissed:(BOOL)dismissed {
    %orig;
    g_isUnlocked = dismissed;
    if (g_enabled && g_isScreenOn) {
        NSString *state = dismissed ? @"Unlock" : @"Locked";
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}
%end


// ==========================================
// 🚨 杀招 3：拦截顶级滑动手势进度
// ==========================================
%hook SBCoverSheetSlidingViewController

- (CGRect)_updatePositionViewForProgress:(double)progress velocity:(double)velocity forPresentationValue:(BOOL)value {
    CGRect ret = %orig;
    if (g_enabled) {
        // 将精准到 0.001 的滑动进度广播给我们的引擎！
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineSwipeProgress" object:nil userInfo:@{@"progress": @(progress)}];
        });
    }
    return ret;
}

%end


// ==========================================
// 亮灭屏同步
// ==========================================
%hook SBBacklightController

- (void)setBacklightState:(long long)state source:(long long)source {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            if (g_isScreenOn) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineWake" object:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineSleep" object:nil];
                });
            }
        }
    }
}

- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            if (g_isScreenOn) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineWake" object:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineSleep" object:nil];
                });
            }
        }
    }
}

%end

// ==========================================
// 构造与偏好重载
// ==========================================
%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
