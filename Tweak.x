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
- (UIView *)contentView; 
- (long long)variant; // 0: 锁屏/下拉通知中心, 1: 桌面
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
- (void)setDismissed:(BOOL)dismissed;
@end

// ==========================================
// 3. 动态配置全局变量
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
// 4. 渲染引擎视图 (独立缓存 + 精准状态机)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) long long wallpaperVariant; 
@property (nonatomic, strong) NSString *currentState;     

@property (nonatomic, strong) NSString *cachedBgPath;
@property (nonatomic, strong) NSString *cachedFloatPath;
@property (nonatomic, strong) NSString *cachedFgPath;
@property (nonatomic, assign) BOOL isPathCached;

- (void)reloadWallpaperViews;
- (void)transitionToState:(NSString *)stateName;
@end

@implementation TendiesRenderEngineView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.wallpaperVariant = 0;
        self.currentState = @"Locked";
        self.isPathCached = NO;
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleStateChange:) name:@"TendiesEngineStateChange" object:nil];
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

// 🚀 核心修复 3：完美交互状态机
- (void)handleStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"];
    if (!state) return;

    if (self.wallpaperVariant == 0) {
        // 锁屏/下拉通知中心：响应所有状态 (Sleep 息屏, Locked 锁屏, Unlock 解锁过渡)
        [self transitionToState:state];
    } else if (self.wallpaperVariant == 1) {
        // 桌面主屏幕：绝不进入 Locked 状态。只响应 Sleep 息屏 和 Unlock 正常互动
        if ([state isEqualToString:@"Sleep"] || [state isEqualToString:@"Unlock"]) {
            [self transitionToState:state];
        }
    }
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
            [self transitionToState:self.currentState];
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
// 5. 核心画布注入 (修复多任务卡片与原生遮挡)
// ==========================================
%hook PBUIWallpaperView

- (void)layoutSubviews {
    %orig; 
    if (!g_enabled) return;

    // 🚀 核心修复 1：阻断应用后台多任务卡片的污染！
    UIWindow *window = self.window;
    if (window) {
        NSString *windowClass = NSStringFromClass([window class]);
        // 如果是系统用来做模糊快照或后台卡片的虚拟窗口，直接拦截，不予渲染我们的动画壁纸
        if ([windowClass containsString:@"Hosted"] || [windowClass containsString:@"Snapshot"]) {
            return;
        }
    }

    // 🚀 核心修复 2：获取系统的原生动画容器，实现“寄生”，完美继承不触摸就能自然亮屏的动画！
    UIView *cv = [self respondsToSelector:@selector(contentView)] ? [self contentView] : self;
    if (!cv) return;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesRenderEngineKey");
    long long currentVariant = [self respondsToSelector:@selector(variant)] ? [self variant] : 0;
    
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:cv.bounds];
        engineView.wallpaperVariant = currentVariant;
        engineView.currentState = (currentVariant == 1) ? @"Unlock" : @"Locked";
        
        objc_setAssociatedObject(self, "TendiesRenderEngineKey", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cv addSubview:engineView]; // 注入到原生唤醒容器内部
        [engineView reloadWallpaperViews];
    } else {
        // 🚀 核心修复 4：防止系统重用缓存导致锁屏变桌面！
        // 如果系统回收了这块视图并改变了它的用途，我们要立刻修正它的动画状态！
        if (engineView.wallpaperVariant != currentVariant) {
            engineView.wallpaperVariant = currentVariant;
            NSString *targetState = (currentVariant == 1) ? @"Unlock" : @"Locked";
            [engineView transitionToState:targetState];
        }
    }
    
    engineView.frame = cv.bounds;
    [cv bringSubviewToFront:engineView];
    
    // 隐藏 cv 内容器里系统原生的图片，但绝对不隐藏 cv 自己，以免破坏亮屏动画
    for (UIView *sub in cv.subviews) {
        if (sub != engineView && ![sub isKindOfClass:NSClassFromString(@"TendiesRenderEngineView")]) {
            sub.hidden = YES;
            sub.alpha = 0.0;
        }
    }
}
%end

// ==========================================
// 6. 锁屏控制器状态发射器
// ==========================================
%hook CSCoverSheetViewController

// 发射息屏/点亮指令
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled) {
        NSString *state = mode ? @"Sleep" : @"Locked";
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
    }
}

- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
    %orig;
    if (g_enabled) {
        NSString *state = mode ? @"Sleep" : @"Locked";
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
    }
}

// 发射解锁滑开进桌面的指令
- (void)setDismissed:(BOOL)dismissed {
    %orig;
    if (g_enabled) {
        NSString *state = dismissed ? @"Unlock" : @"Locked";
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
    }
}

%end

// ==========================================
// 7. 构造与偏好重载
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
