#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 1. 物理日志系统 (越狱开发的救星，无视系统过滤)
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
// 2. 补全系统私有 API 声明 (消除所有编译报错)
// ==========================================
// 播放 CAML 动画包的核心视图
@interface BSUICAPackageView : UIView
- (id)initWithURL:(NSURL *)url;
- (BOOL)setState:(NSString *)state;
@end

// SpringBoard 壁纸容器视图
@interface PBUIWallpaperView : UIView
- (UIView *)contentView; // 显式声明，解决 forward declaration 报错
@end

// 锁屏控制器
@interface CSCoverSheetViewController : UIViewController
- (void)setInScreenOffMode:(BOOL)mode;
- (void)setDismissed:(BOOL)dismissed;
@end

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end


// ==========================================
// 3. 自定义渲染引擎视图 (继承自 UIView)
// ==========================================
// 我们把三个动画层打包成一个 View，方便直接塞进系统容器中
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
        self.userInteractionEnabled = NO; // 不拦截任何触摸事件
        
        WriteLog(@"✅ 分配了新的专属渲染引擎视图，地址: <%p>", self);
        
        // 监听设置 App 传来的重新加载通知
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadWallpaperViews) name:@"TendiesEngineInternalReload" object:nil];
        // 监听锁屏状态切换通知
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
            WriteLog(@"⚠️ 插件已关闭，清除自定义图层。");
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
            // 只要文件夹后缀是 .ca 就算
            if ([isDirectory boolValue] && [fileURL.path hasSuffix:@".ca"]) {
                NSString *fileName = fileURL.lastPathComponent;
                if ([fileName containsString:@"Background"]) bgPath = fileURL.path;
                else if ([fileName containsString:@"Floating"]) floatPath = fileURL.path;
                else if ([fileName containsString:@"Foreground"]) fgPath = fileURL.path;
            }
        }

        // 5. 实例化图层并加到自己身上
        if (bgPath) {
            WriteLog(@"✅ 加载背景层: %@", bgPath.lastPathComponent);
            self.bgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:bgPath]];
            self.bgView.frame = self.bounds;
            self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.bgView.layer.zPosition = 10;
            [self addSubview:self.bgView];
        }
        if (floatPath) {
            WriteLog(@"✅ 加载景深层: %@", floatPath.lastPathComponent);
            self.floatingView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:floatPath]];
            self.floatingView.frame = self.bounds;
            self.floatingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.floatingView.layer.zPosition = 20;
            [self addSubview:self.floatingView];
        }
        if (fgPath) {
            WriteLog(@"✅ 加载前景层: %@", fgPath.lastPathComponent);
            self.fgView = [[PackageViewClass alloc] initWithURL:[NSURL fileURLWithPath:fgPath]];
            self.fgView.frame = self.bounds;
            self.fgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.fgView.layer.zPosition = 30;
            [self addSubview:self.fgView];
        }
        
        WriteLog(@"✅ 引擎视图挂载完毕！");
        // 初始化动画状态
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
// 4. Hook 系统壁纸容器，强行贴膜
// ==========================================

%hook PBUIWallpaperView

- (void)layoutSubviews {
    %orig; 
    
    // 获取真正的壁纸装载 View
    UIView *contentView = [self contentView];
    if (contentView) {
        TendiesRenderEngineView *engineView = objc_getAssociatedObject(self, "TendiesRenderEngineKey");
        if (!engineView) {
            WriteLog(@"✨ 拦截到系统 PBUIWallpaperView，为其分配专属渲染图层...");
            engineView = [[TendiesRenderEngineView alloc] initWithFrame:contentView.bounds];
            objc_setAssociatedObject(self, "TendiesRenderEngineKey", engineView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        
        // 防御：如果系统把我们的 view 刷掉了，或者我们刚创建好，把它贴上去
        if (engineView.isEnabled && engineView.superview != contentView) {
            [contentView addSubview:engineView];
        } else if (!engineView.isEnabled && engineView.superview) {
            [engineView removeFromSuperview];
        }
    }
}

%end

// ==========================================
// 5. Hook 锁屏控制器，触发交互动画
// ==========================================

%hook CSCoverSheetViewController

// 息屏 / 亮屏
- (void)setInScreenOffMode:(BOOL)mode {
    %orig;
    NSString *state = mode ? @"Sleep" : @"Locked";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineStateChange" object:nil userInfo:@{@"state": state}];
}

// 解锁进入主屏幕
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
    WriteLog(@"📥 收到来自设置 App 的 Darwin 通知，广播内部重载指令...");
    // 触发所有实例化好的 TendiesRenderEngineView 重新读取文件
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TendiesEngineInternalReload" object:nil];
}

%hook SpringBoard

// 确保在系统完全启动后再注册监听，防止在 %ctor 早期阶段沙盒未就绪导致崩溃
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    WriteLog(@"✅ SpringBoard 启动完毕，TendiesEnabler 正在注册通知监听...");
    
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                    NULL, 
                                    PrefsNotificationCallback, 
                                    CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), // 必须和设置里发出的一致
                                    NULL, 
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

%end
