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

@interface UIViewController (Private)
- (UIView *)wallpaperContainerView;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
- (void)setDismissed:(BOOL)dismissed;
@end

// ==========================================
// 3. 动态配置全局变量与状态同步
// ==========================================
static BOOL g_enabled = NO;
static NSString *g_tendiesPath = nil;
// 核心状态锁：记录当前是否已解锁进入桌面
static BOOL g_isUnlocked = NO; 

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
// 4. 统一渲染引擎 (Unify Rendering Architecture)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
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

- (void)handleStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"];
    if (state) [self transitionToState:state];
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
                // 深度遍历，无视文件夹名称，直接捞出核心 .ca 文件！
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
            
            // 恢复之前记录的全局锁屏/解锁状态
            self.currentState = g_isUnlocked ? @"Unlock" : @"Locked";
            [self transitionToState:self.currentState];
        });
    });
}

- (void)transitionToState:(NSString *)stateName {
    if (!g_enabled) return;
    self.currentState = [stateName copy];
    
    // 强制调用带 animated 的方法，完美触发 main.caml 里的解锁互动形变！
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
// 5. 最高权柄 Hook：接管壁纸司令部 (支持 iOS 15 - 17)
// ==========================================
%hook PBUIWallpaperViewController

- (void)viewDidLoad {
    %orig;
    if (!g_enabled) return;
    
    // 我们在这里创建全系统唯一的一个 Tendies 视图！
    TendiesRenderEngineView *engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.view.bounds];
    objc_setAssociatedObject(self, "TendiesEngineRoot", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [self.view insertSubview:engineView atIndex:0];
    [engineView reloadWallpaperViews];
}

- (void)viewWillLayoutSubviews {
    %orig;
    if (!g_enabled) return;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineRoot");
    if (!engineView) return;
    
    // 🚀 核心 1：获取原生唤醒容器！把我们塞进系统专门管“渐亮/渐暗”的容器里，免去必须触摸才亮的 Bug！
    UIView *container = nil;
    if ([self respondsToSelector:@selector(wallpaperContainerView)]) {
        container = [self performSelector:@selector(wallpaperContainerView)];
    } else {
        container = [self valueForKey:@"_wallpaperContainerView"];
    }
    
    if (!container) container = self.view; // 降级备用
    
    engineView.frame = container.bounds;
    if (engineView.superview != container) {
        [engineView removeFromSuperview];
        [container addSubview:engineView];
    }
    
    // 强制提到最高层
    [container bringSubviewToFront:engineView];
    
    // 🚀 核心 2：精准灭杀原生 PosterBoard 图层，让 GPU 只渲染我们的壁纸！
    for (UIView *sub in container.subviews) {
        if (sub != engineView) {
            sub.hidden = YES;
            sub.alpha = 0.0;
        }
    }
}

%end

// 为了防一手 iOS 14 老架构，也加上这一个（Theos 会自动判断是否存在）
%hook SBWallpaperViewController

- (void)viewDidLoad {
    %orig;
    if (!g_enabled) return;
    TendiesRenderEngineView *engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.view.bounds];
    objc_setAssociatedObject(self, "TendiesEngineRoot", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.view insertSubview:engineView atIndex:0];
    [engineView reloadWallpaperViews];
}

- (void)viewWillLayoutSubviews {
    %orig;
    if (!g_enabled) return;
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineRoot");
    if (!engineView) return;
    
    UIView *container = [self valueForKey:@"_wallpaperContainerView"] ?: self.view;
    engineView.frame = container.bounds;
    if (engineView.superview != container) {
        [engineView removeFromSuperview];
        [container addSubview:engineView];
    }
    [container bringSubviewToFront:engineView];
    for (UIView *sub in container.subviews) {
        if (sub != engineView) { sub.hidden = YES; sub.alpha = 0.0; }
    }
}

%end

// ==========================================
// 6. 锁屏控制器：只负责下发状态机指令
// ==========================================
%hook CSCoverSheetViewController

// 当手机息屏或点亮但未解锁时：
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    if (g_enabled) {
        // mode=YES 息屏 -> Sleep
        // mode=NO 亮屏 -> 依据当前解锁状态判定是 Locked 还是 Unlock
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}

- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
    %orig;
    if (g_enabled) {
        NSString *state = mode ? @"Sleep" : (g_isUnlocked ? @"Unlock" : @"Locked");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}

// 当用户划开锁屏进入桌面（或下拉通知中心）时：
- (void)setDismissed:(BOOL)dismissed {
    %orig;
    g_isUnlocked = dismissed; // 记录全局解锁状态
    if (g_enabled) {
        // dismissed=YES 进桌面 -> Unlock，dismissed=NO 下拉通知中心 -> Locked
        NSString *state = dismissed ? @"Unlock" : @"Locked";
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
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
