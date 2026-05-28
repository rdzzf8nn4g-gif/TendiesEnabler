#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 1. 物理日志系统
// ==========================================
static void WriteLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSString *logMsg = [NSString stringWithFormat:@"[%@] 🚀 %@\n", [NSDate date], message];
    NSString *logPath = @"/tmp/tendies_sb.log"; 
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fileHandle) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [fileHandle seekToEndOfFile];
    [fileHandle writeData:[logMsg dataUsingEncoding:NSUTF8StringEncoding]];
    [fileHandle closeFile];
}

static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist";
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

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode; 
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source; 
- (void)setDismissed:(BOOL)dismissed;
@end

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end

// ==========================================
// 3. 自定义渲染引擎视图
// ==========================================
@interface TendiesRenderEngineView : UIView
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isEnabled;

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

- (void)reloadWallpaperViews {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.bgView removeFromSuperview];
        [self.floatingView removeFromSuperview];
        [self.fgView removeFromSuperview];
        self.bgView = nil; self.floatingView = nil; self.fgView = nil;
        
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
        self.isEnabled = [prefs[@"Enabled"] boolValue];
        if (!self.isEnabled) return;
        
        NSString *tendiesPath = prefs[@"TendiesPath"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!tendiesPath || ![fm fileExistsAtPath:tendiesPath]) return;
        
        // 核心修复位置：通过校验 handle 是否为空，既使用了变量消除编译报错，又增加了安全性
        void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
        if (!handle) {
            WriteLog(@"❌ 无法动态加载 BaseBoardUI 框架！");
            return;
        }
        
        Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
        if (!PackageViewClass) {
            WriteLog(@"❌ 找不到 BSUICAPackageView 类！");
            return;
        }

        NSString *bgPath = nil; NSString *floatPath = nil; NSString *fgPath = nil;
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:tendiesPath] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
        
        for (NSURL *fileURL in dirEnum) {
            NSNumber *isDirectory;
            [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
            if ([isDirectory boolValue] && [fileURL.path hasSuffix:@".ca"]) {
                NSString *fileName = fileURL.lastPathComponent;
                if ([fileName localizedCaseInsensitiveContainsString:@"Background"]) bgPath = fileURL.path;
                else if ([fileName localizedCaseInsensitiveContainsString:@"Floating"]) floatPath = fileURL.path;
                else if ([fileName localizedCaseInsensitiveContainsString:@"Foreground"]) fgPath = fileURL.path;
            }
        }

        if (bgPath) {
            self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:bgPath]];
            self.bgView.frame = self.bounds;
            self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.bgView.layer.zPosition = 10;
            [self addSubview:self.bgView];
        }
        if (floatPath) {
            self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:floatPath]];
            self.floatingView.frame = self.bounds;
            self.floatingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.floatingView.layer.zPosition = 20; 
            [self addSubview:self.floatingView];
        }
        if (fgPath) {
            self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:fgPath]];
            self.fgView.frame = self.bounds;
            self.fgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.fgView.layer.zPosition = 30;
            [self addSubview:self.fgView];
        }
        [self transitionToState:@"Locked"];
    });
}

- (void)transitionToState:(NSString *)stateName {
    if (!self.isEnabled) return;
    WriteLog(@"🎬 状态切换: %@", stateName);
    [self.bgView setState:stateName];
    [self.floatingView setState:stateName];
    [self.fgView setState:stateName];
}
@end

// ==========================================
// 4. Hook 锁屏控制器直接注入 (兼容 iOS 14-17)
// ==========================================
%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    
    TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesEngine");
    if (!engineView) {
        WriteLog(@"✨ 为 CSCoverSheetViewController 注入渲染引擎层...");
        engineView = [[TendiesRenderEngineView alloc] initWithFrame:self.view.bounds];
        objc_setAssociatedObject(self, "TendiesEngine", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // 插入到最底层（index 0），在锁屏 UI 之下，但在壁纸之上
        [self.view insertSubview:engineView atIndex:0]; 
    }
}

// 适配 iOS 14-15 状态变更
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *state = mode ? @"Sleep" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

// 适配 iOS 16-17 全新 API 状态变更
- (void)setInScreenOffMode:(BOOL)mode forAutoUnlock:(BOOL)unlock fromUnlockSource:(int)source {
    %orig;
    NSString *state = mode ? @"Sleep" : @"Locked";
    WriteLog(@"📸 iOS 16+ 屏幕息亮状态改变 -> %@", state);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

- (void)setDismissed:(BOOL)dismissed {
    %orig;
    NSString *state = dismissed ? @"Unlock" : @"Locked";
    WriteLog(@"🔓 锁屏解锁状态改变 -> %@", state);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

%end

// ==========================================
// 5. 设置中心 Darwin 通知监听
// ==========================================
static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PrefsNotificationCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
%end
