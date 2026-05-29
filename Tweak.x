#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>

// ==========================================
// 1. 全越狱环境黄金路径适配
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
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
- (void)setDismissed:(BOOL)dismissed;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
@property (readonly, nonatomic) long long backlightState;
@end

// 核心：iOS 全局壁纸控制器
@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
@end

// ==========================================
// 3. 动态配置全局变量与状态同步
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
// 4. 统一渲染引擎 (加入强制 GPU 刷新破除假死)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, strong) NSString *currentState;     
@property (nonatomic, assign) BOOL isPathCached;
@property (nonatomic, strong) NSString *cachedBgPath;
@property (nonatomic, strong) NSString *cachedFloatPath;
@property (nonatomic, strong) NSString *cachedFgPath;

- (void)reloadWallpaperViews;
- (void)transitionToState:(NSString *)stateName;
- (void)wakeUpAnimations;
@end

@implementation TendiesRenderEngineView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor]; 
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.currentState = @"Locked";
        self.isPathCached = NO;
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleStateChange:) name:@"TendiesEngineStateChange" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(wakeUpAnimations) name:@"TendiesEngineWakeUp" object:nil];
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

- (void)handleStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"];
    if (state) [self transitionToState:state];
}

// 🚀 核心修复：强制打断系统休眠，重新派发 CA 动画，免触摸唤醒！
- (void)wakeUpAnimations {
    if (!g_enabled || !g_isScreenOn) return;
    
    // 强制时间轴恢复，粉碎系统的限制
    if (self.superview) self.superview.layer.speed = 1.0;
    self.layer.speed = 1.0;
    self.bgView.layer.speed = 1.0;
    self.floatingView.layer.speed = 1.0;
    self.fgView.layer.speed = 1.0;

    // 立刻执行状态转移，并通过 CATransaction flush 直接推送到底层渲染服务！
    [CATransaction begin];
    NSString *correctState = g_isUnlocked ? @"Unlock" : @"Locked";
    [self transitionToState:correctState];
    [CATransaction commit];
    [CATransaction flush]; // 不等触摸，强制刷新！
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.bgView) self.bgView.frame = self.bounds;
    if (self.floatingView) self.floatingView.frame = self.bounds;
    if (self.fgView) self.fgView.frame = self.bounds;
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
                self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self addSubview:self.bgView];
            }
            if (self.cachedFloatPath) {
                self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFloatPath]];
                self.floatingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self addSubview:self.floatingView];
            }
            if (self.cachedFgPath) {
                self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:self.cachedFgPath]];
                self.fgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self addSubview:self.fgView];
            }
            [self setNeedsLayout];
            
            [CATransaction begin];
            [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked"];
            [CATransaction commit];
            [CATransaction flush];
        });
    });
}

- (void)transitionToState:(NSString *)stateName {
    if (!g_enabled) return;
    self.currentState = [stateName copy];
    
    // 强制调用动画重置，让引擎内的组件根据主线状态重新排布
    if ([self.bgView respondsToSelector:@selector(setState:animated:)]) {
        [self.bgView setState:stateName animated:YES];
        [self.floatingView setState:stateName animated:YES];
        [self.fgView setState:stateName animated:YES];
    } else {
        [self.bgView setState:stateName];
        [self.floatingView setState:stateName];
        [self.fgView setState:stateName];
    }
}
@end


// ==========================================
// 5. 🎯 终极注入：劫持全局壁纸司令部 (直指 _wallpaperContainerView)
// ==========================================
%hook CSCoverSheetViewController

// CSCoverSheetViewController 的 layout 极其频繁且可靠
// 我们利用它来确保我们的引擎始终在 SpringBoard 全局壁纸容器的最顶层
- (void)viewWillLayoutSubviews {
    %orig;
    if (!g_enabled) return;
    
    // 1. 获取 SBWallpaperController 单例
    id wallpaperController = [%c(SBWallpaperController) sharedInstance];
    if (!wallpaperController) return;
    
    // 2. 利用 KVC 直接拿到包含所有海报和壁纸的真·终极根视图
    UIView *container = [wallpaperController valueForKey:@"_wallpaperContainerView"];
    if (!container) return;
    
    // 3. 将单例渲染引擎绑定到 WallpaperController 上
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(wallpaperController, "GlobalTendiesEngine");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:container.bounds];
        objc_setAssociatedObject(wallpaperController, "GlobalTendiesEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    // 4. 确保引擎还在容器里，并且在最顶层
    if (engineView.superview != container) {
        [engineView removeFromSuperview];
        [container addSubview:engineView];
    }
    engineView.frame = container.bounds;
    [container bringSubviewToFront:engineView];
    
    // 5. 将系统原生生成的海报（PosterBoard 场景）彻底隐藏！
    // 因为这已经是根容器了，我们隐藏它们不仅能节约性能，还不会影响任何前景图标
    for (UIView *sub in container.subviews) {
        if (sub != engineView) {
            sub.hidden = YES;
            sub.alpha = 0.0;
        }
    }
}

%end


// ==========================================
// 6. 背光监听器，精准发送唤醒信号
// ==========================================
%hook SBBacklightController

- (void)setBacklightState:(long long)state source:(long long)source {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0); // 0 = 息屏, 1 及以上 = 亮屏/渐暗
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            if (g_isScreenOn) {
                // 延迟极短时间发送，确保 UI 树已经在内存中就绪
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineWakeUp" object:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": @"Sleep"}];
                });
            }
        }
    }
}

// 兼容新版签名
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            if (g_isScreenOn) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineWakeUp" object:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": @"Sleep"}];
                });
            }
        }
    }
}

%end


// ==========================================
// 7. 锁屏状态控制器
// ==========================================
%hook CSCoverSheetViewController

- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled && g_isScreenOn) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}

- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
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
// 8. 构造与偏好重载
// ==========================================
%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                    NULL, 
                                    prefsChangedCallback, 
                                    CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), 
                                    NULL, 
                                    CFNotificationSuspensionBehaviorCoalesce);
}
