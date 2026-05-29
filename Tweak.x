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
// 结构体与系统头文件声明
// ==========================================
typedef struct {
    long long x0;
    long long x1;
    double x2;
} PBUIWallpaperTransitionState;

@interface PBUIWallpaperViewController : UIViewController
@property (retain, nonatomic) UIView *homescreenWallpaperView;
@property (retain, nonatomic) UIView *lockscreenWallpaperView;
@end

@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
- (BOOL)setState:(NSString *)state animated:(BOOL)animated;
@end

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
- (void)updateWallpaperAnimationWithProgress:(double)progress;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setDismissed:(BOOL)dismissed;
@end

// ==========================================
// 全局变量与配置管理
// ==========================================
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
// 核心渲染引擎 (双引擎架构)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, assign) NSInteger engineType; // 0 = 锁屏引擎, 1 = 桌面引擎
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
@end

// 全局双引擎指针
static TendiesRenderEngineView *g_homeEngine = nil;
static TendiesRenderEngineView *g_lockEngine = nil;

@implementation TendiesRenderEngineView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor]; // 💡 纯黑背景，物理遮挡原生海报！
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.isPathCached = NO;
        self.isUnlocking = NO;
        self.currentState = @"Init";
        self.engineType = 0; // 默认锁屏
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWakeUp) name:@"TendiesEngineWake" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSleep) name:@"TendiesEngineSleep" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onProgress:) name:@"TendiesEngineProgress" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onStateChange:) name:@"TendiesEngineStateChange" object:nil];
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
    if (self.engineType == 1) return; // 💡 桌面引擎直接忽略亮屏事件
    
    self.isUnlocking = g_isUnlocked;
    [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
}

- (void)onSleep {
    if (!g_enabled) return;
    if (self.engineType == 1) return; // 💡 桌面引擎直接忽略灭屏事件
    
    self.isUnlocking = NO;
    [self transitionToState:@"Sleep" animated:NO];
}

- (void)onStateChange:(NSNotification *)note {
    if (!g_enabled) return;
    if (self.engineType == 1) return; // 💡 桌面引擎忽略状态广播
    
    NSString *state = note.userInfo[@"state"];
    self.isUnlocking = [state isEqualToString:@"Unlock"];
    [self transitionToState:state animated:YES];
}

- (void)onProgress:(NSNotification *)note {
    if (!g_enabled) return;
    if (self.engineType == 1) return; // 💡 桌面引擎直接忽略滑动阻尼
    
    double progress = [note.userInfo[@"progress"] doubleValue];
    
    if (progress > 0.05) {
        if (!self.isUnlocking) {
            self.isUnlocking = YES;
            [self transitionToState:@"Unlock" animated:YES];
        }
    } else {
        if (self.isUnlocking) {
            self.isUnlocking = NO;
            [self transitionToState:@"Locked" animated:YES];
        }
    }
}

// 🎯 终极修复：用 UIView Spring 弹簧动画强行接管一切！解决假渐变！
- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated {
    if (!g_enabled) return;
    
    // ⚠️ 桌面引擎永远锁死在 Unlock 状态，绝不变成锁屏样式！
    if (self.engineType == 1) {
        stateName = @"Unlock"; 
    }
    
    if ([self.currentState isEqualToString:stateName]) return;
    self.currentState = [stateName copy];
    
    if (animated) {
        // 强制使用 0.8s 时长的原生弹性阻尼动画包裹
        [UIView animateWithDuration:0.8 delay:0.0 usingSpringWithDamping:0.8 initialSpringVelocity:0.2 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction animations:^{
            
            // 传入 animated:YES，结合外层的 UIView 动画块，系统会自动计算所有位移和缩放！
            if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
                [self.bgView setState:stateName animated:YES];
                [self.floatingView setState:stateName animated:YES];
                [self.fgView setState:stateName animated:YES];
            } else {
                [self.bgView setState:stateName];
                [self.floatingView setState:stateName];
                [self.fgView setState:stateName];
            }
            [self layoutIfNeeded]; // 强制刷新渲染
            
        } completion:nil];
    } else {
        if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
            [self.bgView setState:stateName animated:NO];
            [self.floatingView setState:stateName animated:NO];
            [self.fgView setState:stateName animated:NO];
        } else {
            [self.bgView setState:stateName];
            [self.floatingView setState:stateName];
            [self.fgView setState:stateName];
        }
    }
}

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
    
    if (plistPath && [fm fileExistsAtPath:plistPath]) {
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
            if (!self.isPathCached) [self parseWallpaperPlist];
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
            
            // 💡 初始化时：桌面引擎强行设置为 Unlock，锁屏引擎根据当前状态设置
            self.currentState = @"Init";
            if (self.engineType == 1) {
                [self transitionToState:@"Unlock" animated:NO]; 
            } else {
                [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked" animated:NO];
            }
        });
    });
}
@end


// ==========================================
// 🚀 终极精密挂载：防漏底、防透视、绝对显示！
// ==========================================

// 1. 桌面引擎：挂载在系统的 homescreenWallpaperView 上
%hook PBUIWallpaperViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (!g_enabled) return;
    
    UIView *homeView = [self respondsToSelector:@selector(homescreenWallpaperView)] ? [self homescreenWallpaperView] : nil;
    if (homeView) {
        if (!g_homeEngine) {
            g_homeEngine = [[TendiesRenderEngineView alloc] initWithFrame:homeView.bounds];
            g_homeEngine.engineType = 1; // 💡 身份：桌面引擎
            [g_homeEngine reloadWallpaperViews];
        }
        if (g_homeEngine.superview != homeView) {
            [homeView addSubview:g_homeEngine];
        }
        g_homeEngine.frame = homeView.bounds;
        [homeView bringSubviewToFront:g_homeEngine]; // 覆盖掉系统自带图片
    }
}
// 阻止过渡时的残影截屏
- (id)_newWallpaperEffectViewForVariant:(long long)variant transitionState:(PBUIWallpaperTransitionState)state {
    if (g_enabled) return nil;
    return %orig;
}
- (BOOL)_updateEffectViewForVariant:(long long)variant oldState:(void *)oldState newState:(void *)newState oldEffectView:(id *)oldView newEffectView:(id *)newView {
    if (g_enabled) return NO;
    return %orig;
}
%end


// 2. 锁屏引擎：挂载在 CoverSheet 内部的背景上 (物理遮挡法，最安全)
%hook CSCoverSheetViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (!g_enabled) return;

    UIViewController *bgVC = [self valueForKey:@"_backgroundContentViewController"];
    if (bgVC && bgVC.view) {
        if (!g_lockEngine) {
            g_lockEngine = [[TendiesRenderEngineView alloc] initWithFrame:bgVC.view.bounds];
            g_lockEngine.engineType = 0; // 💡 身份：锁屏引擎
            [g_lockEngine reloadWallpaperViews];
        }
        if (g_lockEngine.superview != bgVC.view) {
            [bgVC.view addSubview:g_lockEngine];
        }
        g_lockEngine.frame = bgVC.view.bounds;
        
        // 🎯 核心逻辑：直接把我们的黑底引擎推到最顶层，当做一块幕布
        // 物理遮挡住后面的系统原生海报，再也不用去修改系统容器的 alpha 导致崩溃！
        [bgVC.view bringSubviewToFront:g_lockEngine];
    }
    
    // 景深特效层会挡住我们，这个必须透明化
    UIView *floatingLayer = [self valueForKey:@"_floatingLayerView"];
    if (floatingLayer) {
        floatingLayer.alpha = 0.0;
    }
}

- (void)viewDidLayoutSubviews { %orig; [self viewWillLayoutSubviews]; }
- (void)_updateBackgroundContentView { %orig; [self viewWillLayoutSubviews]; }

// 防止截取原生快照闪烁
- (void)updatePosterSwitcherSnapshots {
    if (g_enabled) return;
    %orig;
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
    g_isUnlocked = dismissed; // 记录最新状态
    if (g_enabled && g_isScreenOn) {
        NSString *state = dismissed ? @"Unlock" : @"Locked";
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}
%end


// ==========================================
// 进度获取
// ==========================================
%hook SBWallpaperController
- (void)updateWallpaperAnimationWithProgress:(double)progress {
    %orig;
    if (g_enabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
        });
    }
}
%end


// ==========================================
// 亮灭屏与状态同步
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

// ==========================================
// 构造函数
// ==========================================
%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
