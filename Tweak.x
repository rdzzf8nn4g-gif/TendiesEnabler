#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ==========================================
// 1. 全越狱环境黄金路径适配 (对齐参考项目)
// ==========================================
#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// 彻底放弃沙盒敏感的 Documents，改用共享偏好媒体空间
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
// 3. 动态配置全局变量 (参考黄金方案穿盒读取)
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
    
    WriteLog(@"配置重载完成 - 开关: %d, 路径: %@", g_enabled, g_tendiesPath);
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPrefs();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

// ==========================================
// 4. 自定义渲染引擎视图
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.bgView removeFromSuperview];
        [self.floatingView removeFromSuperview];
        [self.fgView removeFromSuperview];
        self.bgView = nil; self.floatingView = nil; self.fgView = nil;
        
        if (!g_enabled) return;
        
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!g_tendiesPath || ![fm fileExistsAtPath:g_tendiesPath]) return;
        
        void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
        if (!handle) return; 
        
        Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
        if (!PackageViewClass) return;

        NSString *bgPath = nil; NSString *floatPath = nil; NSString *fgPath = nil;
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:g_tendiesPath] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
        
        for (NSURL *fileURL in dirEnum) {
            NSString *pathString = fileURL.path;
            if ([pathString hasSuffix:@"/"]) {
                pathString = [pathString substringToIndex:pathString.length - 1];
            }
            
            if ([pathString hasSuffix:@".ca"]) {
                NSString *fileName = [pathString lastPathComponent];
                if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) bgPath = pathString;
                else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) floatPath = pathString;
                else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) fgPath = pathString;
            }
        }

        if (bgPath) {
            self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:bgPath]];
            self.bgView.frame = self.bounds;
            self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self addSubview:self.bgView];
        }
        if (floatPath) {
            self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:floatPath]];
            self.floatingView.frame = self.bounds;
            self.floatingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self addSubview:self.floatingView];
        }
        if (fgPath) {
            self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:fgPath]];
            self.fgView.frame = self.bounds;
            self.fgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self addSubview:self.fgView];
        }
        
        WriteLog(@"✅ 动效视图成功挂载，初始化 Locked 状态");
        [self transitionToState:@"Locked"];
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
// 5. Hook 系统桌面壁纸层注入
// ==========================================
%hook PBUIWallpaperView
- (void)layoutSubviews {
    %orig; 
    UIView *contentView = [self contentView];
    if (contentView && g_enabled) {
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
        WriteLog(@"✨ 检测到锁屏创建，织入 Tendies 渲染引擎...");
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
            WriteLog(@"🎯 叠层成功：已将引擎置于系统壁纸层 [%@] 之上", NSStringFromClass([targetWallpaperView class]));
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
