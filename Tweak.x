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

// 🚀 核心状态机：拒绝状态错乱
- (void)handleStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"];
    if (!state) return;

    if (self.wallpaperVariant == 0) {
        // 锁屏：响应 Sleep(息屏), Locked(亮屏锁定), Unlock(解锁滑开过渡)
        [self transitionToState:state];
    } else if (self.wallpaperVariant == 1) {
        // 桌面：绝不进入 Locked 状态。只响应 Sleep(息屏) 和 Unlock(正常互动)
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
                    
                    // 智能排除不属于当前变体的专属文件夹（如果没有专属文件夹则共用）
                    if (self.wallpaperVariant == 0 && [pathString containsString:@"/HomeScreen"]) continue;
                    if (self.wallpaperVariant == 1 && [pathString containsString:@"/LockScreen"]) continue;
                    
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
    
    // 强制激流动效过渡
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
// 5. 核心画布注入 (防卡片污染 + 精准隐藏)
// ==========================================
%hook PBUIWallpaperView

- (void)layoutSubviews {
    %orig; 
    if (!g_enabled) return;

    // 🚀 终极修复 1：拦截多任务后台卡片/快照，防止壁纸卡在卡片上！
    UIWindow *window = self.window;
    if (window) {
        NSString *wClass = NSStringFromClass([window class]);
        if ([wClass containsString:@"Hosted"] || 
            [wClass containsString:@"Snapshot"] || 
            [wClass containsString:@"Switcher"]) {
            return; // 是后台卡片，直接退出，不渲染！
        }
    }
    // 防止被缩小的假视图污染
    if (self.bounds.size.width < 200) return; 

    long long currentVariant = [self respondsToSelector:@selector(variant)] ? [self variant] : 0;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesRenderEngineKey");
    
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.bounds];
        engineView.wallpaperVariant = currentVariant;
        engineView.currentState = (currentVariant == 1) ? @"Unlock" : @"Locked";
        
        objc_setAssociatedObject(self, "TendiesRenderEngineKey", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self addSubview:engineView];
        [engineView reloadWallpaperViews];
    } else {
        // 🚀 终极修复 2：防止系统回收利用视图导致锁屏变成桌面壁纸！
        if (engineView.wallpaperVariant != currentVariant) {
            engineView.wallpaperVariant = currentVariant;
            NSString *targetState = (currentVariant == 1) ? @"Unlock" : @"Locked";
            [engineView transitionToState:targetState];
        }
    }
    
    engineView.frame = self.bounds;
    engineView.hidden = NO;
    engineView.alpha = 1.0;
    [self bringSubviewToFront:engineView];
    
    // 🚀 终极修复 3：精准打击！只隐藏原生图片和海报，绝不隐藏毛玻璃，保证桌面显示并继承亮屏动画
    for (UIView *sub in self.subviews) {
        if (sub == engineView) continue;
        
        NSString *cName = NSStringFromClass([sub class]);
        // 专门干掉 PosterBoard 的海报层和静态图
        if ([cName containsString:@"ScenePresentation"] || 
            [cName containsString:@"UIImageView"] || 
            [cName containsString:@"Video"]) {
            sub.alpha = 0.0;
            sub.hidden = YES;
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
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}

- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
    %orig;
    if (g_enabled) {
        NSString *state = mode ? @"Sleep" : @"Locked";
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
        });
    }
}

// 发射解锁滑开进桌面的指令
- (void)setDismissed:(BOOL)dismissed {
    %orig;
    if (g_enabled) {
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
