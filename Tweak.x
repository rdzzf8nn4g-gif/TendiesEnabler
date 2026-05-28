#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 1. 物理日志系统 (越狱开发的救星)
// ==========================================
static NSString * GetLogFilePath() {
    NSString *base = @"/var/mobile/Library/Caches";
#if __has_include(<roothide.h>)
    base = jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        base = [@"/var/jb" stringByAppendingPathComponent:base];
    }
#endif
    return [base stringByAppendingPathComponent:@"TendiesEnabler.log"];
}

#define TENDIES_LOG(fmt, ...) do { \
    NSString *logMsg = [NSString stringWithFormat:@"[%@] " fmt @"\n", [NSDate date], ##__VA_ARGS__]; \
    NSString *logPath = GetLogFilePath(); \
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath]; \
    if (!fileHandle) { \
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil]; \
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath]; \
    } \
    [fileHandle seekToEndOfFile]; \
    [fileHandle writeData:[logMsg dataUsingEncoding:NSUTF8StringEncoding]]; \
    [fileHandle closeFile]; \
} while(0)

static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【务必确认这里是你的 Bundle ID】
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
// 2. 补全私有 API 声明 (完美修复编译报错)
// ==========================================
@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
@end

@interface PBUIWallpaperView : UIView
- (UIView *)contentView; // 修复 forward declaration 报错的核心
@end

@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode;
- (void)setDismissed:(BOOL)dismissed;
@end


// ==========================================
// 3. 多实例渲染引擎 (每个系统壁纸容器拥有一个)
// ==========================================
@interface TendiesRenderEngine : NSObject
@property (nonatomic, weak) UIView *containerView;
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isEnabled;

- (instancetype)initWithContainerView:(UIView *)containerView;
- (void)reloadWallpaper;
- (void)transitionToState:(NSString *)stateName;
@end

@implementation TendiesRenderEngine

- (instancetype)initWithContainerView:(UIView *)containerView {
    self = [super init];
    if (self) {
        self.containerView = containerView;
        
        // 监听设置 App 传来的重新加载通知
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaper) name:@"TendiesEngineInternalReload" object:nil];
        // 监听锁屏状态切换通知
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleStateChange:) name:@"TendiesEngineStateChange" object:nil];
        
        [self reloadWallpaper];
    }
    return self;
}

- (void)handleStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"];
    if (state) [self transitionToState:state];
}

- (void)reloadWallpaper {
    TENDIES_LOG(@"🔄 引擎开始在容器 <%p> 中重载壁纸...", self.containerView);
    
    // 清除旧的图层
    [self.bgView removeFromSuperview];
    [self.floatingView removeFromSuperview];
    [self.fgView removeFromSuperview];
    self.bgView = nil;
    self.floatingView = nil;
    self.fgView = nil;
    
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
    self.isEnabled = [prefs[@"Enabled"] boolValue];
    
    if (!self.isEnabled) {
        TENDIES_LOG(@"⚠️ 插件已关闭，清除图层。");
        return;
    }
    
    NSString *tendiesPath = prefs[@"TendiesPath"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!tendiesPath || ![fm fileExistsAtPath:tendiesPath]) {
        TENDIES_LOG(@"❌ 渲染失败：未找到壁纸路径 %@", tendiesPath);
        return;
    }
    
    // 强制加载 BaseBoardUI 框架
    dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
    Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
    if (!PackageViewClass) {
        TENDIES_LOG(@"❌ 致命错误：无法加载 BSUICAPackageView 类！");
        return;
    }

    NSString *bgPath = nil;
    NSString *floatPath = nil;
    NSString *fgPath = nil;

    // 强力递归搜索目录下的 .ca 文件夹
    NSDirectoryEnumerator *dirEnum = [fm enumeratorAtURL:[NSURL fileURLWithPath:tendiesPath]
                                 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                    options:0
                                               errorHandler:nil];
    for (NSURL *fileURL in dirEnum) {
        NSNumber *isDirectory;
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if ([isDirectory boolValue] && [fileURL.path hasSuffix:@".ca"]) {
            NSString *fileName = fileURL.lastPathComponent;
            if ([fileName containsString:@"Background"]) bgPath = fileURL.path;
            else if ([fileName containsString:@"Floating"]) floatPath = fileURL.path;
            else if ([fileName containsString:@"Foreground"]) fgPath = fileURL.path;
        }
    }

    // 实例化 CA 动画视图并添加到容器
    if (bgPath) {
        TENDIES_LOG(@"✅ 加载背景层: %@", bgPath.lastPathComponent);
        self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:bgPath]];
        self.bgView.frame = self.containerView.bounds;
        self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.bgView.layer.zPosition = -100;
        [self.containerView addSubview:self.bgView];
    }
    if (floatPath) {
        TENDIES_LOG(@"✅ 加载景深层: %@", floatPath.lastPathComponent);
        self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:floatPath]];
        self.floatingView.frame = self.containerView.bounds;
        self.floatingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.floatingView.layer.zPosition = 100;
        [self.containerView addSubview:self.floatingView];
    }
    if (fgPath) {
        TENDIES_LOG(@"✅ 加载前景层: %@", fgPath.lastPathComponent);
        self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:fgPath]];
        self.fgView.frame = self.containerView.bounds;
        self.fgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.fgView.layer.zPosition = 200;
        [self.containerView addSubview:self.fgView];
    }
    
    // 默认进入锁屏状态
    [self transitionToState:@"Locked"];
}

- (void)transitionToState:(NSString *)stateName {
    if (!self.isEnabled) return;
    TENDIES_LOG(@"🎬 图层状态切换至: %@", stateName);
    [self.bgView setState:stateName];
    [self.floatingView setState:stateName];
    [self.fgView setState:stateName];
}

@end


// ==========================================
// 4. Hook SpringBoard 渲染容器
// ==========================================
%hook PBUIWallpaperView

- (void)layoutSubviews {
    %orig; // 保持系统原有布局
    
    UIView *contentView = [self contentView]; // 编译不再报错！
    if (contentView) {
        // 利用 associated object 给每个系统的 PBUIWallpaperView 绑定一个自己的专属引擎
        TendiesRenderEngine *engine = objc_getAssociatedObject(self, "TendiesRenderEngineKey");
        if (!engine) {
            TENDIES_LOG(@"✨ 发现新的系统壁纸容器，为其分配专属渲染引擎！");
            engine = [[TendiesRenderEngine alloc] initWithContainerView:contentView];
            objc_setAssociatedObject(self, "TendiesRenderEngineKey", engine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // 如果视图因为系统原因被移除了，引擎会重新把它加回去
        if (engine.isEnabled && engine.bgView && engine.bgView.superview != contentView) {
            [contentView addSubview:engine.bgView];
            if (engine.floatingView) [contentView addSubview:engine.floatingView];
            if (engine.fgView) [contentView addSubview:engine.fgView];
        }
    }
}

%end

// ==========================================
// 5. Hook 锁屏控制器，触发动画状态
// ==========================================
%hook CSCoverSheetViewController

// 当屏幕熄灭或亮起时
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *state = mode ? @"Sleep" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

// 当锁屏被 Dismiss（即解锁进入主屏幕）时
- (void)setDismissed:(BOOL)dismissed {
    %orig;
    NSString *state = dismissed ? @"Unlock" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

%end

// ==========================================
// 6. 接收设置更新通知 (Darwin 进程间通信)
// ==========================================
static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    TENDIES_LOG(@"📥 收到设置界面的 Darwin 通知，正在广播内部重载指令...");
    // 收到设置通知后，把它转换成 SB 进程内部的通知，通知所有的引擎重新加载壁纸
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

%ctor {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
        TENDIES_LOG(@"🚀 TendiesEnabler 成功注入 SpringBoard！开始监听设置.");
        
        // 监听设置 App 发来的 Darwin 跨进程通知
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                        NULL, 
                                        PrefsNotificationCallback, 
                                        CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), // 【确认这里和设置代码里抛出的字符串完全一致】
                                        NULL, 
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
