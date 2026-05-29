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
// 2. 补全系统私有 API 声明 (专攻 iOS 16/17+)
// ==========================================
@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
- (BOOL)setState:(NSString *)state animated:(BOOL)animated;
@end

@interface PBUIWallpaperView : UIView
@property (nonatomic, readonly) long long variant; // 0 = 锁屏, 1 = 桌面
@end

@interface SBWallpaperController : NSObject
- (void)updateWallpaperAnimationWithProgress:(double)progress;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
@property (readonly, nonatomic) long long backlightState;
@end

// ==========================================
// 3. 动态配置全局变量与状态同步
// ==========================================
static BOOL g_enabled = NO;
static NSString *g_tendiesPath = nil;

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
// 4. 统一渲染引擎 (支持滑动进度 & 暴力破除假死)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;

@property (nonatomic, assign) BOOL isPathCached;
@property (nonatomic, assign) BOOL isUnlocking; // 记录当前是否处于上滑解锁动画中
@property (nonatomic, strong) NSString *cachedBgPath;
@property (nonatomic, strong) NSString *cachedFloatPath;
@property (nonatomic, strong) NSString *cachedFgPath;

- (void)reloadWallpaperViews;
- (void)transitionToState:(NSString *)stateName animated:(BOOL)animated;

// 修复编译错误：确保接口名称与实现名称完全一致
- (void)onWakeUp;
- (void)onSleep;
- (void)onProgress:(NSNotification *)note;
@end

@implementation TendiesRenderEngineView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 保持透明，以免遮挡不该遮挡的东西，CA 文件如果不透明自然会覆盖底层
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

// --- 核心：状态机与生命周期控制 ---

// 1. 亮屏瞬间：粉碎假死限制
- (void)onWakeUp {
    if (!g_enabled) return;
    
    // 强制把自身和子视图的时间轴恢复为 1.0（对抗系统息屏降频）
    self.layer.speed = 1.0;
    self.bgView.layer.speed = 1.0;
    self.floatingView.layer.speed = 1.0;
    self.fgView.layer.speed = 1.0;

    self.isUnlocking = NO;
    
    // 不等触摸，强制用 CATransaction 推送 Lock 状态到 GPU！
    [CATransaction begin];
    [self transitionToState:@"Locked" animated:NO]; // 刚亮屏，直接切回锁定状态即可
    [CATransaction commit];
    [CATransaction flush];
}

// 2. 息屏瞬间
- (void)onSleep {
    if (!g_enabled) return;
    self.isUnlocking = NO;
    [self transitionToState:@"Sleep" animated:NO];
}

// 3. 完美还原上滑互动形变！
- (void)onProgress:(NSNotification *)note {
    if (!g_enabled) return;
    
    double progress = [note.userInfo[@"progress"] doubleValue];
    
    // 当手指开始上滑解锁 (progress > 0.05)，触发 Unlock 动画！
    if (progress > 0.05 && !self.isUnlocking) {
        self.isUnlocking = YES;
        [self transitionToState:@"Unlock" animated:YES]; // 触发 CAML 内的 CASpringAnimation
    } 
    // 当用户取消上滑，进度退回 (progress <= 0.05) 时，恢复 Locked 动画！
    else if (progress <= 0.05 && self.isUnlocking) {
        self.isUnlocking = NO;
        [self transitionToState:@"Locked" animated:YES];
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

// --- 核心：加载包 ---
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
            [self transitionToState:@"Locked" animated:NO];
            [CATransaction commit];
            [CATransaction flush];
        });
    });
}
@end


// ==========================================
// 5. 🎯 挂载机制 (绝对不隐藏原生视图，破除假死！)
// ==========================================
%hook PBUIWallpaperView

- (void)layoutSubviews {
    %orig;
    if (!g_enabled) return;
    
    // 关键修正：如果当前是桌面 (variant != 0)，直接放行，什么都不做！
    // 桌面原生逻辑（高斯模糊/纯色）完美保留，彻底解决后台卡片错乱 Bug。
    if ([self respondsToSelector:@selector(variant)] && [self variant] != 0) {
        return; 
    }
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineSubView");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.bounds];
        objc_setAssociatedObject(self, "TendiesEngineSubView", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    engineView.frame = self.bounds;
    
    // 坚决不使用 sub.hidden = YES！这会触发 iOS 16/17 的 Scene 挂起机制，导致“不触摸就不显示”。
    // 我们只需要把我们的 EngineView 提到所有原生图层的最前面即可！
    [self bringSubviewToFront:engineView];
}

%end


// ==========================================
// 6. 捕捉上滑交互进度 (找回交互动画)
// ==========================================
%hook SBWallpaperController

// 当你手指放在锁屏上滑时，系统每帧都会调用这个方法
- (void)updateWallpaperAnimationWithProgress:(double)progress {
    %orig;
    if (g_enabled) {
        // 利用 GCD 同步到主线程派发进度，驱动 TendiesEngine
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineProgress" object:nil userInfo:@{@"progress": @(progress)}];
        });
    }
}

%end


// ==========================================
// 7. 背光监听器 (破除亮屏不动的 Bug)
// ==========================================
%hook SBBacklightController

- (void)setBacklightState:(long long)state source:(long long)source {
    %orig;
    if (g_enabled) {
        if (state != 0) {
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

- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    %orig;
    if (g_enabled) {
        if (state != 0) {
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
