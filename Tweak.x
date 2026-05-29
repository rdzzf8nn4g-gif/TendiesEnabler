#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

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
// 2. 补全系统私有 API 声明
// ==========================================
@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
- (BOOL)setState:(NSString *)state animated:(BOOL)animated;
@end

@interface PBUIWallpaperView : UIView
@property (nonatomic, readonly) long long variant; // 0 = LockScreen, 1 = HomeScreen
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
- (void)setDismissed:(BOOL)dismissed;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
@property (readonly, nonatomic) long long backlightState; // 0 = Off, 1 = On/Dimmed
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
// 4. 统一渲染引擎 (优化版: 支持精准恢复 CA 动画)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, strong) NSString *currentState;     
@property (nonatomic, assign) long long variant; // 区分是锁屏还是桌面
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
        self.backgroundColor = [UIColor clearColor]; // 保持透明，以免遮挡不该遮挡的东西
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

// 核心修复 1：从系统假死状态中暴力唤醒图层！
- (void)wakeUpAnimations {
    if (!g_enabled || !g_isScreenOn) return;
    
    // 强制恢复图层时间轴
    self.layer.speed = 1.0;
    self.bgView.layer.speed = 1.0;
    self.floatingView.layer.speed = 1.0;
    self.fgView.layer.speed = 1.0;

    // 根据当前的解锁情况，重新派发一次动画状态，激活形变
    NSString *correctState = g_isUnlocked ? @"Unlock" : @"Locked";
    [self transitionToState:correctState];
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
            [self transitionToState:g_isUnlocked ? @"Unlock" : @"Locked"];
        });
    });
}

- (void)transitionToState:(NSString *)stateName {
    if (!g_enabled) return;
    self.currentState = [stateName copy];
    
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
// 5. 核心修复 2：准确挂载到 PBUIWallpaperView (支持快照与分离)
// ==========================================
%hook PBUIWallpaperView

- (void)layoutSubviews {
    %orig;
    if (!g_enabled) return;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineSubView");
    if (!engineView) {
        // 创建独立实例，彻底分离锁屏和桌面！完美解决后台卡片错乱 Bug！
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.bounds];
        
        // 判断当前这个视图是服务于锁屏(0)还是桌面(1)
        if ([self respondsToSelector:@selector(variant)]) {
            engineView.variant = [self variant];
        }
        
        objc_setAssociatedObject(self, "TendiesEngineSubView", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // 挂载到系统原生壁纸视图的最高层，坚决不隐藏原有视图
        [self addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    engineView.frame = self.bounds;
    [self bringSubviewToFront:engineView];
}

%end

// 兼容老版本 iOS 14 / 15
%hook SBFWallpaperView
- (void)layoutSubviews {
    %orig;
    if (!g_enabled) return;
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineSubView");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.bounds];
        if ([self respondsToSelector:@selector(variant)]) engineView.variant = [self variant];
        objc_setAssociatedObject(self, "TendiesEngineSubView", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    engineView.frame = self.bounds;
    [self bringSubviewToFront:engineView];
}
%end


// ==========================================
// 6. 核心修复 3：背光监听器，解决“必须触摸才亮”的 Bug
// ==========================================
%hook SBBacklightController

- (void)setBacklightState:(long long)state source:(long long)source {
    %orig;
    if (g_enabled) {
        // state 0 = 息屏, 1 及以上 = 亮屏/渐暗
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            if (g_isScreenOn) {
                // 屏幕点亮的瞬间，发布强力唤醒广播！
                dispatch_async(dispatch_get_main_queue(), ^{
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

// 适配新版 API 签名
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    %orig;
    if (g_enabled) {
        BOOL screenOn = (state != 0);
        if (screenOn != g_isScreenOn) {
            g_isScreenOn = screenOn;
            if (g_isScreenOn) {
                dispatch_async(dispatch_get_main_queue(), ^{
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
// 7. 锁屏控制器：只负责下发状态机指令
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
