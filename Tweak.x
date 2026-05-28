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

static void WriteLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSString *logMsg = [NSString stringWithFormat:@"[%@] 🚀 [TendiesEngine] %@\n", [NSDate date], message];
    NSString *logPath = [GetTendiesStorageDir() stringByAppendingPathComponent:@"engine_debug.log"];
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fileHandle) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMsg dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }
}

// ==========================================
// 2. 补全系统私有 API 声明
// ==========================================
@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
- (void)setDismissed:(BOOL)dismissed;
- (id)_backgroundContentViewController;
@end

@interface SBIconController : UIViewController
+ (id)sharedInstance;
@end

// ==========================================
// 3. 动态配置全局变量与内存高能缓存
// ==========================================
static BOOL g_enabled = NO;
static NSString *g_tendiesPath = nil;

static NSString *cachedBgPath = nil;
static NSString *cachedFloatPath = nil;
static NSString *cachedFgPath = nil;
static BOOL isPathCached = NO;

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
    
    cachedBgPath = nil; cachedFloatPath = nil; cachedFgPath = nil;
    isPathCached = NO;
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

// ==========================================
// 4. 自定义高并发渲染引擎视图
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) long long wallpaperVariant; // 0: Lockscreen(锁屏), 1: Homescreen(桌面)
@property (nonatomic, strong) NSString *currentState;     

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
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleStateChange:) name:@"TendiesEngineStateChange" object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleStateChange:(NSNotification *)note {
    // 💡只允许锁屏(0)改变状态，桌面(1)必须死死锁在 Unlock 交互状态
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
        
        if (!isPathCached) {
            NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
            for (NSURL *fileURL in dirEnum) {
                NSString *pathString = fileURL.path;
                if ([fileURL.lastPathComponent hasPrefix:@"."] || [pathString containsString:@"/__MACOSX"]) continue; 
                if ([pathString hasSuffix:@"/"]) pathString = [pathString substringToIndex:pathString.length - 1];
                
                if ([[[pathString pathExtension] lowercaseString] isEqualToString:@"ca"] || [pathString hasSuffix:@".ca"]) {
                    NSString *fileName = [pathString lastPathComponent];
                    if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) cachedBgPath = [pathString copy];
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) cachedFloatPath = [pathString copy];
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) cachedFgPath = [pathString copy];
                }
            }
            isPathCached = YES;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.bgView removeFromSuperview]; [self.floatingView removeFromSuperview]; [self.fgView removeFromSuperview];
            self.bgView = nil; self.floatingView = nil; self.fgView = nil;
            
            void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
            if (!handle) return; 
            Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
            if (!PackageViewClass) return;

            if (cachedBgPath) {
                self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:cachedBgPath]];
                self.bgView.frame = self.bounds;
                self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self addSubview:self.bgView];
            }
            if (cachedFloatPath) {
                self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:cachedFloatPath]];
                self.floatingView.frame = self.bounds;
                self.floatingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self addSubview:self.floatingView];
            }
            if (cachedFgPath) {
                self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:cachedFgPath]];
                self.fgView.frame = self.bounds;
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
// 5. Hook 桌面控制器完美注入 (修复 iOS 16+ 桌面不显示)
// ==========================================
%hook SBIconController

// viewDidLoad 在 SpringBoard 启动只运行一次，绝对不卡
- (void)viewDidLoad {
    %orig;
    if (!g_enabled) return;

    TendiesRenderEngineView *engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.view.bounds];
    engineView.wallpaperVariant = 1; // 1代表桌面
    engineView.currentState = @"Unlock"; // 桌面强制保持 Unlock 状态
    objc_setAssociatedObject(self, "TendiesEngineKey_Home", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // 直接插在图标容器的最底层，完美当做壁纸显示
    [self.view insertSubview:engineView atIndex:0];
    [engineView reloadWallpaperViews];
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!g_enabled) return;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineKey_Home");
    if (engineView) {
        engineView.frame = self.view.bounds;
        // O(1) 极速排序：确保永远在图标下面
        if (engineView.superview != self.view) {
            [self.view insertSubview:engineView atIndex:0];
        } else if (self.view.subviews.count > 0 && self.view.subviews[0] != engineView) {
            [self.view sendSubviewToBack:engineView];
        }
    }
}

%end

// ==========================================
// 6. Hook 锁屏控制器高级防遮挡注入 (修复触摸时恢复壁纸)
// ==========================================
%hook CSCoverSheetViewController

// 同样只创建一次
- (void)viewDidLoad {
    %orig;
    if (!g_enabled) return;

    TendiesRenderEngineView *engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.view.bounds];
    engineView.wallpaperVariant = 0; // 0代表锁屏
    engineView.currentState = @"Locked";
    objc_setAssociatedObject(self, "TendiesEngineKey_Lock", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [self.view insertSubview:engineView atIndex:0];
    [engineView reloadWallpaperViews];
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!g_enabled) return;

    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineKey_Lock");
    if (!engineView) return;
    
    engineView.frame = self.view.bounds;
    
    // O(1) 极速把引擎压在锁屏最底下，没有任何 for 循环，绝对不卡
    if (engineView.superview != self.view) {
        [self.view insertSubview:engineView atIndex:0];
    } else if (self.view.subviews.count > 0 && self.view.subviews[0] != engineView) {
        [self.view sendSubviewToBack:engineView];
    }
    
    // 🚀 核心修复：无论系统手指滑动怎么刷新，一旦发现原生壁纸层敢冒头，瞬间把它压回隐藏状态！
    if ([self respondsToSelector:@selector(_backgroundContentViewController)]) {
        id bgVC = [self _backgroundContentViewController];
        if (bgVC && [bgVC respondsToSelector:@selector(view)]) {
            UIView *bgView = [bgVC view];
            if (bgView && (!bgView.hidden || bgView.alpha > 0)) {
                bgView.hidden = YES;
                bgView.alpha = 0.0;
            }
        }
    }
}

// 状态拦截传递 (控制由 Locked 变为 Unlock)
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *state = mode ? @"Sleep" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
    %orig;
    NSString *state = mode ? @"Sleep" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

- (void)setDismissed:(BOOL)dismissed {
    %orig;
    NSString *state = dismissed ? @"Unlock" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}
%end

%ctor {
    reloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                    NULL, 
                                    prefsChangedCallback, 
                                    CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), 
                                    NULL, 
                                    CFNotificationSuspensionBehaviorCoalesce);
}
