#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 1. 绝对可靠的物理日志系统 (写入 /tmp 目录)
// ==========================================
static void WriteLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSString *logMsg = [NSString stringWithFormat:@"[%@] 🚀 %@\n", [NSDate date], message];
    NSString *logPath = @"/tmp/tendies_sb.log"; // /tmp 目录对 SB 绝对可写
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fileHandle) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [fileHandle seekToEndOfFile];
    [fileHandle writeData:[logMsg dataUsingEncoding:NSUTF8StringEncoding]];
    [fileHandle closeFile];
}

// 统一偏好设置路径
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【确认这是你的 BundleID】
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
// 2. 补全系统私有 API 声明 (消除所有编译警告)
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
- (void)setDismissed:(BOOL)dismissed;
@end

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end


// ==========================================
// 3. 自定义渲染引擎：TendiesRenderEngine
// ==========================================
@interface TendiesRenderEngine : NSObject
@property (nonatomic, weak) UIView *containerView;
@property (nonatomic, strong) BSUICAPackageView *bgView;
@property (nonatomic, strong) BSUICAPackageView *floatingView;
@property (nonatomic, strong) BSUICAPackageView *fgView;
@property (nonatomic, assign) BOOL isEnabled;

- (instancetype)initWithContainerView:(UIView *)containerView;
- (void)reloadWallpaperViews;
- (void)transitionToState:(NSString *)stateName;
@end

@implementation TendiesRenderEngine

- (instancetype)initWithContainerView:(UIView *)containerView {
    self = [super init];
    if (self) {
        self.containerView = containerView;
        WriteLog(@"分配了新的渲染引擎，容器地址: <%p>", containerView);
        
        // 监听设置 App 传来的重新加载通知
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"TendiesEngineInternalReload" object:nil];
        // 监听锁屏状态切换通知
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleStateChange:) name:@"TendiesEngineStateChange" object:nil];
        
        [self reloadWallpaperViews];
    }
    return self;
}

- (void)handleStateChange:(NSNotification *)note {
    NSString *state = note.userInfo[@"state"];
    if (state) [self transitionToState:state];
}

- (void)reloadWallpaperViews {
    dispatch_async(dispatch_get_main_queue(), ^{
        WriteLog(@"开始重载壁纸图层...");
        
        // 1. 清理旧图层
        [self.bgView removeFromSuperview];
        [self.floatingView removeFromSuperview];
        [self.fgView removeFromSuperview];
        self.bgView = nil;
        self.floatingView = nil;
        self.fgView = nil;
        
        // 2. 读取配置
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
        self.isEnabled = [prefs[@"Enabled"] boolValue];
        
        if (!self.isEnabled) {
            WriteLog(@"插件已关闭，不渲染任何自定义图层。");
            return;
        }
        
        NSString *tendiesPath = prefs[@"TendiesPath"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!tendiesPath || ![fm fileExistsAtPath:tendiesPath]) {
            WriteLog(@"❌ 渲染失败：未找到解压的壁纸路径 %@", tendiesPath);
            return;
        }
        
        // 3. 强制加载 BSUICAPackageView 所在的框架
        void *handle = dlopen("/System/Library/PrivateFrameworks/BaseBoardUI.framework/BaseBoardUI", RTLD_LAZY);
        if (!handle) {
            WriteLog(@"❌ 无法加载 BaseBoardUI 框架！");
            return;
        }
        
        Class PackageViewClass = NSClassFromString(@"BSUICAPackageView");
        if (!PackageViewClass) {
            WriteLog(@"❌ 致命错误：找不到 BSUICAPackageView 类！");
            return;
        }

        // 4. 深度递归搜索 .ca 文件夹
        NSString *bgPath = nil;
        NSString *floatPath = nil;
        NSString *fgPath = nil;

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

        // 5. 实例化图层并添加到桌面/锁屏容器中
        if (bgPath) {
            WriteLog(@"✅ 加载背景层: %@", bgPath.lastPathComponent);
            self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:bgPath]];
            self.bgView.frame = self.containerView.bounds;
            self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.bgView.layer.zPosition = 1000; // 故意调高 Z 轴，确保能盖住系统默认壁纸
            [self.containerView addSubview:self.bgView];
        }
        if (floatPath) {
            WriteLog(@"✅ 加载景深层: %@", floatPath.lastPathComponent);
            self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:floatPath]];
            self.floatingView.frame = self.containerView.bounds;
            self.floatingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.floatingView.layer.zPosition = 1001;
            [self.containerView addSubview:self.floatingView];
        }
        if (fgPath) {
            WriteLog(@"✅ 加载前景层: %@", fgPath.lastPathComponent);
            self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:fgPath]];
            self.fgView.frame = self.containerView.bounds;
            self.fgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.fgView.layer.zPosition = 1002;
            [self.containerView addSubview:self.fgView];
        }
        
        WriteLog(@"✅ 渲染引擎图层挂载完毕！");
        // 初始化状态
        [self transitionToState:@"Locked"];
    });
}

- (void)transitionToState:(NSString *)stateName {
    if (!self.isEnabled) return;
    WriteLog(@"🎬 切换动画状态 -> %@", stateName);
    [self.bgView setState:stateName];
    [self.floatingView setState:stateName];
    [self.fgView setState:stateName];
}

@end


// ==========================================
// 4. Hook SpringBoard 挂载引擎
// ==========================================

%hook PBUIWallpaperView

// 每次系统布局壁纸时，确保我们的自定义图层贴在上面
- (void)layoutSubviews {
    %orig; 
    
    UIView *contentView = [self contentView];
    if (contentView) {
        TendiesRenderEngine *engine = objc_getAssociatedObject(self, "TendiesRenderEngineKey");
        if (!engine) {
            WriteLog(@"✨ 拦截到 PBUIWallpaperView，正在为其绑定渲染引擎...");
            engine = [[TendiesRenderEngine alloc] initWithContainerView:contentView];
            objc_setAssociatedObject(self, "TendiesRenderEngineKey", engine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        
        // 防御性编程：如果因为系统刷新导致我们的视图被移除了，重新加回来
        if (engine.isEnabled) {
            if (engine.bgView && engine.bgView.superview != contentView) [contentView addSubview:engine.bgView];
            if (engine.floatingView && engine.floatingView.superview != contentView) [contentView addSubview:engine.floatingView];
            if (engine.fgView && engine.fgView.superview != contentView) [contentView addSubview:engine.fgView];
        }
    }
}

%end

// ==========================================
// 5. Hook 锁屏控制器，触发交互动画
// ==========================================

%hook CSCoverSheetViewController

- (void)setInScreenOffMode:(BOOL)mode {
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

// ==========================================
// 6. 接收设置界面指令，并安全初始化
// ==========================================

static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    WriteLog(@"📥 收到来自设置 App 的 Darwin 通知，正在广播内部重载指令...");
    // 让所有的 TendiesRenderEngine 重新读取文件并挂载图层
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

%hook SpringBoard

// 确保在系统完全启动后再注册监听，防止 %ctor 阶段沙盒未就绪导致崩溃
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    WriteLog(@"✅ SpringBoard 启动完毕，TendiesEnabler 正在注册通知监听...");
    
    // 监听设置 App 发来的通知
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                    NULL, 
                                    PrefsNotificationCallback, 
                                    CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), // 必须和设置里发出的字符串一致
                                    NULL, 
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

%end
