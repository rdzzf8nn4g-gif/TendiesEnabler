#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 路径与物理日志系统
// ==========================================
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【确认是你的 Bundle ID】
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

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

// 物理日志宏：直接写入文本，无视系统过滤，方便用 Filza 查看
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

// ==========================================
// 获取用户解压出来的真实资源路径
// ==========================================
static NSString * GetPrefsTendiesPath() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
    if (prefs && [prefs[@"Enabled"] boolValue]) {
        return prefs[@"TendiesPath"];
    }
    return nil;
}

// 递归寻找 .tendies 里包含 index.xml 和 main.caml 的那一层文件夹
static NSURL * GetTendiesAssetDirectory() {
    NSString *tendiesPath = GetPrefsTendiesPath();
    if (!tendiesPath) return nil;
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:tendiesPath]
                                 includingPropertiesForKeys:nil
                                                    options:NSDirectoryEnumerationSkipsHiddenFiles
                                               errorHandler:nil];
    for (NSURL *url in enumerator) {
        if ([url.lastPathComponent isEqualToString:@"index.xml"]) {
            return [url URLByDeletingLastPathComponent]; // 返回包含 index.xml 的目录
        }
    }
    return nil;
}

// ==========================================
// 核心劫持 1：拦截 SBWallpaperController
// ==========================================
%hook SBWallpaperController

// 当系统准备刷新桌面和锁屏壁纸时，这个方法会被调用
- (void)_updateForLockScreenPosterConfiguration:(id)lock homeScreenPosterConfiguration:(id)home {
    NSString *tendiesPath = GetPrefsTendiesPath();
    if (tendiesPath) {
        TENDIES_LOG(@"拦截到 SB 准备刷新壁纸。正在给当前配置打上劫持标记...");
        
        // 我们利用 runtime 动态给这些 Configuration 挂上一个布尔值标记，说明它们被劫持了
        if (lock) {
            objc_setAssociatedObject(lock, "isTendiesHijacked", @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id lockPath = [lock performSelector:@selector(_path)];
            if (lockPath) objc_setAssociatedObject(lockPath, "isTendiesHijacked", @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (home) {
            objc_setAssociatedObject(home, "isTendiesHijacked", @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id homePath = [home performSelector:@selector(_path)];
            if (homePath) objc_setAssociatedObject(homePath, "isTendiesHijacked", @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else {
        // 清除标记，恢复系统原状
        if (lock) {
            objc_setAssociatedObject(lock, "isTendiesHijacked", @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id lockPath = [lock performSelector:@selector(_path)];
            if (lockPath) objc_setAssociatedObject(lockPath, "isTendiesHijacked", @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (home) {
            objc_setAssociatedObject(home, "isTendiesHijacked", @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id homePath = [home performSelector:@selector(_path)];
            if (homePath) objc_setAssociatedObject(homePath, "isTendiesHijacked", @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    %orig(lock, home);
}

%end

// ==========================================
// 核心劫持 2：拦截 Configuration 的资源路径
// ==========================================
// SpringBoard 里的 PaperBoardUI 框架就是通过这个方法去读取壁纸文件的
%hook PRSPosterConfiguration

- (NSURL *)assetDirectory {
    NSNumber *isHijacked = objc_getAssociatedObject(self, "isTendiesHijacked");
    if (isHijacked && [isHijacked boolValue]) {
        NSURL *customAssetDir = GetTendiesAssetDirectory();
        if (customAssetDir) {
            TENDIES_LOG(@"🔥 成功将 assetDirectory 重定向至: %@", customAssetDir.path);
            return customAssetDir; // 偷天换日，返回我们沙盒里的目录！
        }
    }
    return %orig;
}

%end

// ==========================================
// 核心劫持 3：拦截 Path 的基础路径
// ==========================================
%hook PRSPosterPath

- (NSURL *)contentsURL {
    NSNumber *isHijacked = objc_getAssociatedObject(self, "isTendiesHijacked");
    if (isHijacked && [isHijacked boolValue]) {
        NSString *tendiesPath = GetPrefsTendiesPath();
        if (tendiesPath) return [NSURL fileURLWithPath:tendiesPath];
    }
    return %orig;
}

- (NSURL *)containerURL {
    NSNumber *isHijacked = objc_getAssociatedObject(self, "isTendiesHijacked");
    if (isHijacked && [isHijacked boolValue]) {
        NSString *tendiesPath = GetPrefsTendiesPath();
        if (tendiesPath) return [NSURL fileURLWithPath:tendiesPath];
    }
    return %orig;
}

%end

// ==========================================
// 手动触发刷新：接收设置界面的指令
// ==========================================
static void ForceRefreshWallpaper(void) {
    TENDIES_LOG(@"收到设置通知，正在强制触发 SBWallpaperController 刷新...");
    dispatch_async(dispatch_get_main_queue(), ^{
        Class sbWallpaperControllerClass = NSClassFromString(@"SBWallpaperController");
        if (!sbWallpaperControllerClass) return;
        
        id wc = [sbWallpaperControllerClass performSelector:@selector(sharedInstance)];
        if ([wc respondsToSelector:@selector(activeLockScreenPosterConfiguration)]) {
            id lock = [wc performSelector:@selector(activeLockScreenPosterConfiguration)];
            id home = [wc performSelector:@selector(activeHomeScreenPosterConfiguration)];
            
            // 重新投递当前配置，这会立刻触发我们上面的 hook 拦截，完成重定向并触发动画！
            if ([wc respondsToSelector:@selector(_updateForLockScreenPosterConfiguration:homeScreenPosterConfiguration:)]) {
                [wc performSelector:@selector(_updateForLockScreenPosterConfiguration:homeScreenPosterConfiguration:) withObject:lock withObject:home];
                TENDIES_LOG(@"✅ 强制更新调用已发送，请查看桌面效果。");
            }
        }
    });
}

static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ForceRefreshWallpaper();
}

%ctor {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
        TENDIES_LOG(@"🚀 TendiesEnabler 已成功注入 SpringBoard。");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                        NULL, 
                                        PrefsNotificationCallback, 
                                        CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), 
                                        NULL, 
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
