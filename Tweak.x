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

@interface PBUIWallpaperView : UIView
- (UIView *)contentView; 
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
- (void)setDismissed:(BOOL)dismissed;
- (id)_backgroundContentViewController; 
@end

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end

// ==========================================
// 3. 动态配置全局变量与内存高能缓存
// ==========================================
static BOOL g_enabled = NO;
static NSString *g_tendiesPath = nil;

// 核心性能缓存：将扫描出来的物理路径直接锁在内存里，避免在布局周期重复IO文件系统
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
    
    // 开关或壁纸变更时，必须清空内存路径缓存
    cachedBgPath = nil; cachedFloatPath = nil; cachedFgPath = nil;
    isPathCached = NO;
    
    WriteLog(@"⚙️ 进程配置重载 -> 开关: %d, 路径: %@", g_enabled, g_tendiesPath);
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
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"TendiesEngineInternalReload" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleStateChange:) name:@"TendiesEngineStateChange" object:nil];
        
        [self reloadWallpaperViews];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    // 性能重构核心：彻底移出系统主线程，丢进并发队列进行异步文件资产暴力检索
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
        
        // 如果未命中内存缓存，则去遍历。后续刷新直接跳过此段耗时扫描
        if (!isPathCached) {
            NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
            for (NSURL *fileURL in dirEnum) {
                NSString *pathString = fileURL.path;
                if ([fileURL.lastPathComponent hasPrefix:@"."] || [pathString containsString:@"/__MACOSX"]) {
                    continue; 
                }
                if ([pathString hasSuffix:@"/"]) {
                    pathString = [pathString substringToIndex:pathString.length - 1];
                }
                if ([[[pathString pathExtension] lowercaseString] isEqualToString:@"ca"] || [pathString hasSuffix:@".ca"]) {
                    NSString *fileName = [pathString lastPathComponent];
                    if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) cachedBgPath = [pathString copy];
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) cachedFloatPath = [pathString copy];
                    else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) cachedFgPath = [pathString copy];
                }
            }
            isPathCached = YES;
        }

        // 瞬间回切主线程渲染挂载，实现0延迟响应，彻底消灭掉帧卡顿
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
            [self transitionToState:@"Locked"];
        });
    });
}

- (void)transitionToState:(NSString *)stateName {
    if (!g_enabled) return;
    [self.bgView setState:stateName];
    [self.floatingView setState:stateName];
    [self.fgView setState:stateName];
}
@end

// ==========================================
// 5. Hook 系统桌面壁纸层注入 (多环境高适配桌面图层)
// ==========================================
%hook PBUIWallpaperView
- (void)layoutSubviews {
    %orig; 
    if (!g_enabled) return;
    
    UIView *contentView = [self contentView];
    if (contentView) {
        TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesRenderEngineKey");
        if (!engineView) {
            engineView = [[TendiesRenderEngineView alloc] initWithFrame:contentView.bounds];
            objc_setAssociatedObject(self, "TendiesRenderEngineKey", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (engineView.superview != contentView) {
            [contentView insertSubview:engineView atIndex:0];
        }
        engineView.frame = contentView.bounds;
        [contentView sendSubviewToBack:engineView];
        [engineView setNeedsLayout]; // 强制唤醒桌面图层尺寸刷新
    }
}
%end

// ==========================================
// 6. Hook 锁屏控制器高级防遮挡注入
// ==========================================
%hook CSCoverSheetViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (!g_enabled) return;

    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngineKey");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.view.bounds];
        objc_setAssociatedObject(self, "TendiesEngineKey", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    UIView *targetWallpaperView = nil;
    for (UIView *subview in self.view.subviews) {
        NSString *className = NSStringFromClass([subview class]);
        if ([className containsString:@"Poster"] || [className containsString:@"Wallpaper"] || [className containsString:@"Background"]) {
            targetWallpaperView = subview;
        }
    }
    
    if (targetWallpaperView) {
        if (engineView.superview != self.view) {
            [self.view insertSubview:engineView aboveSubview:targetWallpaperView];
        }
    } else {
        if (engineView.superview != self.view) {
            [self.view insertSubview:engineView atIndex:0];
        }
    }
    engineView.frame = self.view.bounds;
    
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

// 状态拦截传递
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
