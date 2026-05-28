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
- (long long)variant; // 0: 锁屏壁纸, 1: 桌面壁纸
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
- (void)setDismissed:(BOOL)dismissed;
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
@property (nonatomic, assign) long long wallpaperVariant; // 记录自己服务于锁屏还是桌面
@property (nonatomic, strong) NSString *currentState;     // 锁定当前状态缓存

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
    // 只有锁屏视图(variant=0)才跟随系统状态通知改变。桌面视图(variant=1)常驻"Unlock"
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
            
            // 初始化视图时，刷新当前的渲染状态
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
// 5. Hook 唯一核心壁纸画布 (无缝支持锁屏与桌面)
// ==========================================
%hook PBUIWallpaperView

- (void)layoutSubviews {
    %orig; 
    if (!g_enabled) return;
    
    // 💡 彻底修复：消除锁屏控制器的重复创建，直接在这里通过 variant 自动分发锁屏与桌面
    long long currentVariant = 0;
    if ([self respondsToSelector:@selector(variant)]) {
        currentVariant = [self variant]; // 0 为锁屏壁纸，1 为桌面主屏幕壁纸
    }
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesRenderEngineKey");
    if (!engineView) {
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.bounds];
        engineView.wallpaperVariant = currentVariant;
        
        // 状态分水岭：桌面壁纸进场默认锁死在 "Unlock" 交互状态，锁屏则默认 "Locked"
        if (currentVariant == 1) {
            engineView.currentState = @"Unlock";
        } else {
            engineView.currentState = @"Locked";
        }
        
        objc_setAssociatedObject(self, "TendiesRenderEngineKey", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self addSubview:engineView];
        [engineView reloadWallpaperViews];
    }
    
    engineView.frame = self.bounds;
    
    // 💡 彻底修复：强行提振 Z轴 层级到最顶层，消灭任何原生静态图片、遮罩的遮挡
    [self bringSubviewToFront:engineView];
    
    // 💡 性能飙升核心：暴力隐藏系统自带的原图 contentView 与多余子层级，避免主线程渲染竞争，消灭掉帧卡顿
    UIView *sysContentView = [self respondsToSelector:@selector(contentView)] ? [self contentView] : nil;
    if (sysContentView && !sysContentView.hidden) {
        sysContentView.hidden = YES;
    }
    
    for (UIView *subview in self.subviews) {
        if (subview != engineView && subview != sysContentView) {
            if (!subview.hidden) subview.hidden = YES;
        }
    }
    
    [engineView setNeedsLayout]; 
}

%end

// ==========================================
// 6. Hook 锁屏控制器高级防遮挡注入 (纯状态拦截，0性能损耗)
// ==========================================
%hook CSCoverSheetViewController

// 💡 彻底修复：完全删除了原来在这个方法里疯狂运行的 for循环视图遍历与类名反射，彻底消灭锁屏卡顿
- (void)viewDidLayoutSubviews {
    %orig;
}

// 拦截锁屏黑屏/睡眠状态
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

// 拦截解锁滑出状态 -> 激活全系统的壁纸迈向 "Unlock" 交互动画
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
