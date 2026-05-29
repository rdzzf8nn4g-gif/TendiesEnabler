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
// 核心私有 API 声明
// ==========================================
@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
- (BOOL)setState:(NSString *)state animated:(BOOL)animated;
@end

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
- (void)updateWallpaperAnimationWithProgress:(double)progress;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
@property (readonly, nonatomic) long long backlightState;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setDismissed:(BOOL)dismissed;
@end

// iOS 16/17 锁屏背景原生控制器
@interface CSBackgroundContentViewController : UIViewController
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
// 核心渲染引擎 (解析 Plist + 完美跟随滑动)
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
@end

@implementation TendiesRenderEngineView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor]; 
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

// 🎯 核心修复：完美的手指跟随动画，呈现图层“分开”的视差互动！
- (void)onProgress:(NSNotification *)note {
    if (!g_enabled) return;
    double progress = [note.userInfo[@"progress"] doubleValue];
    
    if (progress > 0.0 && progress < 1.0) {
        // 正在滑动中：冻结时间轴，让壁纸图层跟随手指展开
        if (!self.isUnlocking) {
            self.isUnlocking = YES;
            self.bgView.layer.speed = 0.0;
            self.floatingView.layer.speed = 0.0;
            self.fgView.layer.speed = 0.0;
            [self transitionToState:@"Unlock" animated:YES];
            [CATransaction flush]; // 强制渲染挂载 CAAnimation
        }
        // 根据你提供的 main.caml，原动画持续时间为 0.8s
        CFTimeInterval offset = progress * 0.8;
        self.bgView.layer.timeOffset = offset;
        self.floatingView.layer.timeOffset = offset;
        self.fgView.layer.timeOffset = offset;
        
    } else if (progress >= 1.0) {
        // 滑动解锁完成：恢复时间，让动画继续播放（否则马里奥会定格）
        if (self.isUnlocking) {
            self.isUnlocking = NO;
            self.bgView.layer.speed = 1.0;
            self.floatingView.layer.speed = 1.0;
            self.fgView.layer.speed = 1.0;
            self.bgView.layer.timeOffset = 0.0;
            self.floatingView.layer.timeOffset = 0.0;
            self.fgView.layer.timeOffset = 0.0;
            [self transitionToState:@"Unlock" animated:NO];
        }
    } else if (progress <= 0.0) {
        // 滑动失败退回锁屏
        if (self.isUnlocking) {
            self.isUnlocking = NO;
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

// 🎯 核心修复：精准解析 Wallpaper.plist 挂载 3 个不同的 .ca 文件夹
- (void)parseWallpaperPlist {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plistPath = nil;
    
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
            // 兼容有些壁纸写成 FileNameKey，有些是 FileName
            NSString *floatName = defaultAssets[@"floatingAnimationFileNameKey"] ?: defaultAssets[@"floatingAnimationFileName"];
            NSString *fgName = defaultAssets[@"foregroundAnimationFileName"];
            
            if (bgName) self.cachedBgPath = [baseDir stringByAppendingPathComponent:bgName];
            if (floatName) self.cachedFloatPath = [baseDir stringByAppendingPathComponent:floatName];
            if (fgName) self.cachedFgPath = [baseDir stringByAppendingPathComponent:fgName];
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

            // 按照 Background -> Floating -> Foreground 的严格层级挂载！
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
// 🚨 挂载与拦截：彻底分离锁屏和桌面 🚨
// ==========================================

// 1. 锁屏的引擎挂载点：我们只挂载到锁屏背景视图里，绝对不动桌面！
static void EnsureLockScreenEngineMounted(CSCoverSheetViewController *coverSheetVC) {
    if (!g_enabled) return;
    UIViewController *bgVC = [coverSheetVC valueForKey:@"_backgroundContentViewController"];
    if (!bgVC || !bgVC.view) return;
    
    UIView *targetContainer = bgVC.view;
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(coverSheetVC, "TendiesEngine");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:targetContainer.bounds];
        objc_setAssociatedObject(coverSheetVC, "TendiesEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [targetContainer addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    if (engineView.superview != targetContainer) {
        [engineView removeFromSuperview];
        [targetContainer addSubview:engineView];
    }
    engineView.frame = targetContainer.bounds;
    [targetContainer bringSubviewToFront:engineView];
    
    // 🔥【关键防漏底】把锁屏原生的海报图层设为全透明，防止它在滑动时显露！
    for (UIView *subview in targetContainer.subviews) {
        if (subview != engineView) {
            subview.alpha = 0.0; 
        }
    }
}

%hook CSCoverSheetViewController
- (void)viewWillLayoutSubviews {
    %orig;
    EnsureLockScreenEngineMounted(self);
    
    if (g_enabled) {
        // 🔥【景深杀手】干掉时间上方的浮动遮挡层，确保 Foreground 图层完整显示
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


// 2. 进度监听与快照拦截
%hook SBWallpaperController
- (void)updateWallpaperAnimationWithProgress:(double)progress {
    %orig;
    if (g_enabled) {
        // 将滑动手指进度派发给 TendiesEngine，驱动壁纸分离动画
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
        });
    }
}

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
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:(g_isScreenOn ? @"TendiesEngineWake" : @"TendiesEngineSleep") object:nil];
            });
        }
    }
}

- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:(g_isScreenOn ? @"TendiesEngineWake" : @"TendiesEngineSleep") object:nil];
            });
        }
    }
}
%end

%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
