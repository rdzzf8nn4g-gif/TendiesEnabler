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
@end

@interface PBUIWallpaperView : UIView
- (UIView *)contentView; 
- (long long)variant; // 0: 锁屏, 1: 桌面
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
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
// 4. 自定义高并发渲染引擎视图 (智能隔离架构)
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) long long wallpaperVariant; // 0=锁屏, 1=桌面
@property (nonatomic, strong) NSString *currentState;     

// 将缓存设为实例独占，彻底阻断锁屏与桌面的文件交叉污染
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

- (void)handleStateChange:(NSNotification *)note {
    // 桌面永远常驻 Unlock 状态；仅允许锁屏响应状态切换
    if (self.wallpaperVariant == 0) {
        NSString *state = note.userInfo[@"state"];
        if (state) [self transitionToState:state];
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
                NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:nil options:0 errorHandler:nil];
                
                for (NSURL *fileURL in dirEnum) {
                    NSString *pathString = fileURL.path;
                    NSString *fileName = fileURL.lastPathComponent;
                    
                    if ([fileName hasPrefix:@"."] || [pathString containsString:@"/__MACOSX"]) continue;
                    
                    // 🚀 核心逻辑：智能隔离。锁屏无视 HomeScreen 文件夹，桌面无视 LockScreen 文件夹！
                    if (self.wallpaperVariant == 0 && [pathString containsString:@"/HomeScreen"]) continue;
                    if (self.wallpaperVariant == 1 && [pathString containsString:@"/LockScreen"]) continue;
                    
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
    [self.bgView setState:stateName];
    [self.floatingView setState:stateName];
    [self.fgView setState:stateName];
}
@end

// ==========================================
// 5. 桌面壁纸注入：安全且不会死锁的拦截
// ==========================================
%hook PBUIWallpaperView

- (void)layoutSubviews {
    %orig; 
    if (!g_enabled) return;
    
    long long currentVariant = 0;
    if ([self respondsToSelector:@selector(variant)]) {
        currentVariant = [self variant]; 
    }
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesRenderEngineKey");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.bounds];
        engineView.wallpaperVariant = currentVariant;
        // 桌面赋予 Unlock 交互状态，锁屏赋予 Locked
        engineView.currentState = (currentVariant == 1) ? @"Unlock" : @"Locked";
        
        objc_setAssociatedObject(self, "TendiesRenderEngineKey", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    engineView.frame = self.bounds;
    [self bringSubviewToFront:engineView];
    
    // 隐藏系统自带的图层，防止干扰和遮挡
    UIView *cv = [self respondsToSelector:@selector(contentView)] ? [self contentView] : nil;
    if (cv && !cv.hidden) {
        cv.hidden = YES;
        cv.alpha = 0.0;
    }
    
    for (UIView *sub in self.subviews) {
        if (sub != engineView && sub != cv) {
            sub.hidden = YES;
            sub.alpha = 0.0;
        }
    }
}
%end

// ==========================================
// 6. 锁屏壁纸注入：完美继承原生亮屏唤醒动画 (修复无需触摸即可显示)
// ==========================================
%hook CSCoverSheetViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (!g_enabled) return;
    
    // 🚀 核心修复：精准找到负责屏幕点亮唤醒动画的 _backgroundContentViewController
    UIViewController *bgVC = nil;
    if ([self respondsToSelector:@selector(_backgroundContentViewController)]) {
        bgVC = [self performSelector:@selector(_backgroundContentViewController)];
    }
    
    UIView *targetContainer = bgVC ? bgVC.view : self.view;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineKey_Lock");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:targetContainer.bounds];
        engineView.wallpaperVariant = 0; // 锁屏
        engineView.currentState = @"Locked";
        
        objc_setAssociatedObject(self, "TendiesEngineKey_Lock", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [targetContainer addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    engineView.frame = targetContainer.bounds;
    [targetContainer bringSubviewToFront:engineView];
    
    // 镇压原生的锁屏海报，让我们的引擎成为唯一可见物
    for (UIView *sub in targetContainer.subviews) {
        if (sub != engineView) {
            sub.hidden = YES;
            sub.alpha = 0.0;
        }
    }
}

// 状态追踪
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
