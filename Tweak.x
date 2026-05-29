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
- (long long)variant; // 0: 锁屏/通知中心, 1: 桌面主屏幕
@end

@interface CSCoverSheetViewController : UIViewController
@property (nonatomic) double backlightLevel; // 捕获原生息屏/亮屏的渐变等级
- (void)setBacklightLevel:(double)level;
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
// 4. 渲染引擎视图 (防透视与背光映射)
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
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO; 
        self.wallpaperVariant = 0;
        self.currentState = @"Locked";
        self.isPathCached = NO;
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceReload) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleStateChange:) name:@"TendiesEngineStateChange" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleBacklightChange:) name:@"TendiesBacklightChange" object:nil];
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

// 🚀 修复 1：背光映射。完美解决“触摸才亮”和“看到桌面透视”的问题！
- (void)handleBacklightChange:(NSNotification *)note {
    if (self.wallpaperVariant == 0) { // 只有锁屏跟随背光渐亮
        NSNumber *levelNum = note.userInfo[@"level"];
        if (levelNum) {
            CGFloat level = [levelNum doubleValue];
            // 只渐变图层，引擎本身保持黑色底色阻挡桌面透视！
            self.bgView.alpha = level;
            self.floatingView.alpha = level;
            self.fgView.alpha = level;
        }
    }
}

// 🚀 修复 2：状态机校准。确保桌面和锁屏的状态动画完全分离
- (void)handleStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"];
    if (!state) return;

    if (self.wallpaperVariant == 0) {
        [self transitionToState:state];
    } else if (self.wallpaperVariant == 1) {
        if ([state isEqualToString:@"Sleep"]) {
            [self transitionToState:@"Sleep"];
        } else {
            // 只要屏幕点亮或解锁，桌面永远保持 Unlock 动画状态
            [self transitionToState:@"Unlock"];
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
                self.backgroundColor = [UIColor clearColor];
            });
            return;
        }
        
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!g_tendiesPath || ![fm fileExistsAtPath:g_tendiesPath]) return;
        
        @synchronized(self) {
            if (!self.isPathCached) {
                // 深度遍历：无视层级嵌套，直接捞出 .ca 文件（解决单一结构问题）
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
            
            // 锁屏防透视：给锁屏变体加上纯黑底色，防止渐亮时看到背后的桌面
            if (self.wallpaperVariant == 0) {
                self.backgroundColor = [UIColor blackColor];
            } else {
                self.backgroundColor = [UIColor clearColor];
            }
            
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

    // 🚀 修复 3：强力拦截后台卡片污染！
    UIWindow *window = self.window;
    if (window) {
        NSString *wClass = NSStringFromClass([window class]);
        if ([wClass containsString:@"Hosted"] || 
            [wClass containsString:@"Snapshot"] || 
            [wClass containsString:@"Switcher"] || 
            [wClass containsString:@"SecureApp"]) {
            return; // 发现多任务卡片/快照，立刻退出！
        }
    }
    // 尺寸异常也视为预览快照
    if (self.bounds.size.width < 200) return; 

    long long currentVariant = [self respondsToSelector:@selector(variant)] ? [self variant] : 0;
    
    UIView *cv = [self respondsToSelector:@selector(contentView)] ? [self contentView] : self;
    if (!cv) cv = self;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesRenderEngineKey");
    
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:cv.bounds];
        engineView.wallpaperVariant = currentVariant;
        engineView.currentState = (currentVariant == 1) ? @"Unlock" : @"Locked";
        
        objc_setAssociatedObject(self, "TendiesRenderEngineKey", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cv addSubview:engineView];
        [engineView reloadWallpaperViews];
    } else {
        // 防止系统回收复用视图导致锁屏变成桌面
        if (engineView.wallpaperVariant != currentVariant) {
            engineView.wallpaperVariant = currentVariant;
            NSString *targetState = (currentVariant == 1) ? @"Unlock" : @"Locked";
            [engineView transitionToState:targetState];
        }
    }
    
    engineView.frame = cv.bounds;
    engineView.hidden = NO;
    [cv bringSubviewToFront:engineView];
    
    // 🚀 修复 4：只打击静态图和远端海报，保留原生容器。确保桌面完美显示！
    for (UIView *sub in cv.subviews) {
        if (sub == engineView) continue;
        
        NSString *cName = NSStringFromClass([sub class]);
        if ([cName containsString:@"Scene"] || 
            [cName containsString:@"UIImageView"] || 
            [cName containsString:@"Video"] || 
            [cName containsString:@"Poster"]) {
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

// 拦截原生唤醒的硬件级 Alpha 过渡
- (void)setBacklightLevel:(double)level {
    %orig;
    if (g_enabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesBacklightChange" object:nil userInfo:@{@"level": @(level)}];
        });
    }
}

// 拦截息屏/锁屏状态
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

// 拦截滑开进桌面的解锁状态
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
