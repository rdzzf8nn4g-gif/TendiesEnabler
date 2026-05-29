#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ==========================================
// 核心私有 API 声明 & 结构体
// ==========================================
typedef struct {
    long long x0;
    long long x1;
    double x2;
} PBUIWallpaperTransitionState;

@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
- (BOOL)setState:(NSString *)state animated:(BOOL)animated;
@end

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
- (void)updateWallpaperAnimationWithProgress:(double)progress;
@end

@interface PBUIWallpaperViewController : UIViewController
@property (retain, nonatomic) UIView *homescreenWallpaperView;
@property (retain, nonatomic) UIView *lockscreenWallpaperView;
@property (retain, nonatomic) UIView *sharedWallpaperView;
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state;
- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)state newState:(void *)state oldEffectView:(id *)view newEffectView:(id *)view;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
@property (readonly, nonatomic) long long backlightState;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setDismissed:(BOOL)dismissed;
@end

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
// 核心渲染引擎 (解析 Wallpaper.plist + 完美指尖追踪)
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

- (void)reloadWallpaperViews;
- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated;
- (void)onWakeUp;
- (void)onSleep;
- (void)onProgress:(NSNotification *)note;
@end

@implementation TendiesRenderEngineView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor]; // 必须透明
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.isPathCached = NO;
        self.isUnlocking = NO;
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"TendiesEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"TendiesEngineSleep" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onProgress:) name:@"TendiesEngineProgress" object:nil];
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
    self.layer.speed = 1.0;
    if (self.bgView) self.bgView.layer.speed = 1.0;
    if (self.floatingView) self.floatingView.layer.speed = 1.0;
    if (self.fgView) self.fgView.layer.speed = 1.0;
    self.isUnlocking = NO;
    
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

// 🎯 核心交互动画：通过时间轴精准搓擦 (Scrubbing)，实现多层跟随滑动！
- (void)onProgress:(NSNotification *)note {
    if (!g_enabled) return;
    double progress = [note.userInfo[@"progress"] doubleValue];
    
    if (progress > 0.01) {
        if (!self.isUnlocking) {
            self.isUnlocking = YES;
            
            // 1. 下发 Unlock 状态，令 CAML 内部挂载 CASpringAnimation
            [self transitionToState:@"Unlock" animated:YES];
            // 2. 必须强制渲染树更新
            [CATransaction flush];
            
            // 3. 冻结时间
            self.bgView.layer.speed = 0.0;
            self.floatingView.layer.speed = 0.0;
            self.fgView.layer.speed = 0.0;
            
            self.bgView.layer.beginTime = 0.0;
            self.floatingView.layer.beginTime = 0.0;
            self.fgView.layer.beginTime = 0.0;
        }
        
        // 💡 从你的 CAML 看出，苹果原生的弹簧动画持续时间刚好是 0.8s！
        CFTimeInterval offset = progress * 0.8;
        self.bgView.layer.timeOffset = offset;
        self.floatingView.layer.timeOffset = offset;
        self.fgView.layer.timeOffset = offset;
        
    } else {
        if (self.isUnlocking) {
            self.isUnlocking = NO;
            // 恢复时间流速，归位 Locked
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

// 🎯 解析 Wallpaper.plist 智能读取联动 .ca 包
- (void)parseWallpaperPlist {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plistPath = nil;
    
    // 递归寻找 Wallpaper.plist
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:g_tendiesPath];
    for (NSString *file in enumerator) {
        if ([file.lastPathComponent isEqualToString:@"Wallpaper.plist"]) {
            plistPath = [g_tendiesPath stringByAppendingPathComponent:file];
            break;
        }
    }
    
    if (plistPath) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSDictionary *defaultAssets = dict[@"assets"][@"lockAndHome"][@"default"];
        if (defaultAssets) {
            NSString *baseDir = [plistPath stringByDeletingLastPathComponent];
            NSString *bgName = defaultAssets[@"backgroundAnimationFileName"];
            NSString *floatName = defaultAssets[@"floatingAnimationFileNameKey"] ?: defaultAssets[@"floatingAnimationFileName"];
            NSString *fgName = defaultAssets[@"foregroundAnimationFileName"];
            
            if (bgName) self.cachedBgPath = [baseDir stringByAppendingPathComponent:bgName];
            if (floatName) self.cachedFloatPath = [baseDir stringByAppendingPathComponent:floatName];
            if (fgName) self.cachedFgPath = [baseDir stringByAppendingPathComponent:fgName];
            
            self.isPathCached = YES;
            return;
        }
    }
    
    // 如果没有 plist，使用名称模糊匹配
    enumerator = [fm enumeratorAtPath:g_tendiesPath];
    for (NSString *subpath in enumerator) {
        NSString *fileName = subpath.lastPathComponent;
        if ([[[subpath pathExtension] lowercaseString] isEqualToString:@"ca"] || [subpath hasSuffix:@".ca"]) {
            NSString *fullPath = [g_tendiesPath stringByAppendingPathComponent:subpath];
            if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) self.cachedBgPath = fullPath;
            else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) self.cachedFloatPath = fullPath;
            else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) self.cachedFgPath = fullPath;
        }
    }
    self.isPathCached = YES;
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
                [self parseWallpaperPlist];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
            self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
            if (!handle) return; 
            Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
            if (!PackageViewClass) return;

            if (self.cachedBgPath && [fm fileExistsAtPath:self.cachedBgPath]) {
                self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedBgPath]];
                [self addSubview:self.bgView];
            }
            if (self.cachedFloatPath && [fm fileExistsAtPath:self.cachedFloatPath]) {
                self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFloatPath]];
                [self addSubview:self.floatingView];
            }
            if (self.cachedFgPath && [fm fileExistsAtPath:self.cachedFgPath]) {
                self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFgPath]];
                [self addSubview:self.fgView];
            }
            [self setNeedsLayout];
            
            [CATransaction begin];
            [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
            [CATransaction commit];
            [CATransaction flush];
        });
    });
}
@end


// ==========================================
// 回归初心：挂载到全局系统底层容器
// ==========================================
static void EnsureEngineViewIsMounted() {
    if (!g_enabled) return;
    id wallpaperController = [%c(SBWallpaperController) sharedInstance];
    if (!wallpaperController) return;
    
    // 💡 挂载在最深处的系统大容器中，保证桌面的完美展示！
    UIView *targetContainer = [wallpaperController valueForKey:@"_wallpaperOverlayContainerView"];
    if (!targetContainer) targetContainer = [wallpaperController valueForKey:@"_wallpaperContainerView"];
    if (!targetContainer) targetContainer = [wallpaperController valueForKey:@"_wallpaperWindow"];
    if (!targetContainer) return;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(wallpaperController, "GlobalTendiesEngine");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:targetContainer.bounds];
        objc_setAssociatedObject(wallpaperController, "GlobalTendiesEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [targetContainer addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    if (engineView.superview != targetContainer) {
        [engineView removeFromSuperview];
        [targetContainer addSubview:engineView];
    }
    engineView.frame = targetContainer.bounds;
    [targetContainer bringSubviewToFront:engineView];
}


// ==========================================
// 🚨 快照杀手 & 底层拦截 
// (根治锁屏原壁纸漏出、桌面原壁纸漏出、景深遮挡)
// ==========================================

%hook PBUIWallpaperViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (g_enabled) {
        // 隐藏桌面上层原生的 PosterKit 壁纸层，让我们的引擎显露出来
        if ([self respondsToSelector:@selector(homescreenWallpaperView)]) {
            UIView *homeView = [self homescreenWallpaperView];
            if (homeView) homeView.alpha = 0.0;
        }
        if ([self respondsToSelector:@selector(lockscreenWallpaperView)]) {
            UIView *lockView = [self lockscreenWallpaperView];
            if (lockView) lockView.alpha = 0.0;
        }
        if ([self respondsToSelector:@selector(sharedWallpaperView)]) {
            UIView *sharedView = [self sharedWallpaperView];
            if (sharedView) sharedView.alpha = 0.0;
        }
    }
}

// 拦截系统生成的临时模糊特效/过渡快照
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state {
    if (g_enabled) return nil;
    return %orig;
}

- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)oldState newState:(void *)newState oldEffectView:(id *)oldView newEffectView:(id *)newView {
    if (g_enabled) return NO;
    return %orig;
}
%end


%hook CSCoverSheetViewController
- (void)viewWillLayoutSubviews {
    %orig;
    EnsureEngineViewIsMounted();
    if (g_enabled) {
        // 🔥 必杀 1：彻底消灭导致滑动锁屏时看到旧壁纸的罪魁祸首！
        // 它是挂载在 CoverSheet 下方的海报背景，必须把它透明化！
        UIViewController *bgVC = [self valueForKey:@"_backgroundContentViewController"];
        if (bgVC && bgVC.view) {
            bgVC.view.alpha = 0.0; 
        }
        
        // 🔥 必杀 2：消灭景深效果 (Depth Effect) 时生成的时间遮挡图层！
        UIView *floatingLayer = [self valueForKey:@"_floatingLayerView"];
        if (floatingLayer) {
            floatingLayer.alpha = 0.0;
        }
    }
}

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


%hook SBWallpaperController
- (void)_ingestPrimaryWallpaperLayersSnapshotIOSurface:(id)arg1 floatingWallpaperLayerSnapshotIOSurface:(id)arg2 snapshotScale:(double)arg3 traitCollection:(id)arg4 withCompletion:(id /* block */)arg5 {
    if (g_enabled) {
        if (arg5) { void (^cb)(void) = arg5; cb(); }
        return; 
    }
    %orig;
}

- (void)_snapshotScene:(id)scene withOptions:(long long)options traitCollection:(id)collection completion:(id /* block */)completion {
    if (g_enabled) {
        if (completion) { void (^cb)(id) = completion; cb(nil); }
        return;
    }
    %orig;
}

- (void)updateWallpaperAnimationWithProgress:(double)progress {
    %orig;
    EnsureEngineViewIsMounted();
    if (g_enabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
        });
    }
}
%end


// ==========================================
// 亮灭屏状态同步
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

%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
