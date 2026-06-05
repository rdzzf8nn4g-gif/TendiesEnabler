#import "ZoneCCModule.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#include <sys/stat.h>
#include <unistd.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

#define APP_ID CFSTR("com.iosdump.zoneprefs")
#define NOTIFY_KEY CFSTR("com.iosdump.zoneprefs/ReloadPrefs")

// ==================================================================
// 控制中心专属：强制声明 ControlCenterUIKit 私有 API 接口
// ==================================================================
@interface CCUIMenuModuleViewController : UIViewController
- (void)addActionWithTitle:(NSString *)title subtitle:(NSString *)subtitle glyph:(UIImage *)glyph handler:(void (^)(id action))handler;
- (void)removeAllActions;
@end

// ==================================================================
// 全局路径与偏好写入引擎
// ==================================================================
static inline NSString * GetRealPrefsPath() {
    NSString *basePath = @"/var/mobile/Library/Preferences/com.iosdump.zoneprefs.plist";
#if __has_include(<roothide.h>)
    return jbroot(basePath);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:basePath];
    }
    return basePath;
#endif
}

static inline NSString * GetZoneStorageDir() {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.zone.media";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static inline NSString * GetWallpapersDir() { return [GetZoneStorageDir() stringByAppendingPathComponent:@"Wallpapers"]; }
static inline NSString * GetVideoWallpapersLockDir() { return [GetZoneStorageDir() stringByAppendingPathComponent:@"VideoWallpapers/Lock"]; }
static inline NSString * GetVideoWallpapersHomeDir() { return [GetZoneStorageDir() stringByAppendingPathComponent:@"VideoWallpapers/Home"]; }

// 终极安全的偏好写入函数：同时同步 CFPreferences 与底层 Plist 文件
static void UpdateZonePreference(NSDictionary *updates) {
    NSString *plistPath = GetRealPrefsPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];

    for (NSString *key in updates.allKeys) {
        id value = updates[key];
        if ([value isKindOfClass:[NSNull class]]) {
            [prefs removeObjectForKey:key];
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, APP_ID);
        } else {
            prefs[key] = value;
            CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, APP_ID);
        }
    }

    [prefs writeToFile:plistPath atomically:YES];
    CFPreferencesAppSynchronize(APP_ID);

    // 提权修复，防止普通 App 修改后 SpringBoard 权限错乱
    chown(plistPath.UTF8String, 501, 501);
    chmod(plistPath.UTF8String, 0666);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), NOTIFY_KEY, NULL, NULL, YES);
}

// ==================================================================
// 核心：长按弹出的多态菜单视图控制器
// ==================================================================
@interface ZoneCCMenuViewController : CCUIMenuModuleViewController
@end

@implementation ZoneCCMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildDynamicMenu];
}

// 每次呼出菜单时动态构建内容
- (void)buildDynamicMenu {
    NSString *prefsPath = GetRealPrefsPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
    BOOL isVideoMode = [prefs[@"VideoModeEnabled"] boolValue];
    BOOL isEnabled = [prefs[@"Enabled"] boolValue];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. 【通用操作】：插件总开关 (开启/关闭引擎)
    NSString *toggleTitle = isEnabled ? @"关闭插件引擎" : @"开启插件引擎";
    NSString *toggleSubtitle = isEnabled ? @"当前状态: 运行中" : @"当前状态: 已休眠";
    UIImage *toggleIcon = [UIImage systemImageNamed:isEnabled ? @"power.circle.fill" : @"power.circle"];
    
    [self addActionWithTitle:toggleTitle subtitle:toggleSubtitle glyph:toggleIcon handler:^(id action) {
        UpdateZonePreference(@{@"Enabled": @(!isEnabled)});
    }];

    // 2. 【多态素材列表】：根据当前模式渲染不同的壁纸选择器
    if (isVideoMode) {
        // --- 加载锁屏视频 ---
        NSArray *lockFiles = [fm contentsOfDirectoryAtPath:GetVideoWallpapersLockDir() error:nil];
        for (NSString *file in [lockFiles sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            if ([file hasPrefix:@"."]) continue;
            NSString *cleanName = [file stringByDeletingPathExtension];
            NSString *title = [NSString stringWithFormat:@"锁屏: %@", cleanName];
            
            [self addActionWithTitle:title subtitle:nil glyph:[UIImage systemImageNamed:@"lock.fill"] handler:^(id action) {
                NSString *fullPath = [GetVideoWallpapersLockDir() stringByAppendingPathComponent:file];
                // 切换壁纸时，强制把插件总开关打开，让用户立刻看到效果
                UpdateZonePreference(@{@"LockVideoPath": fullPath, @"Enabled": @YES});
            }];
        }
        
        // --- 加载桌面视频 ---
        NSArray *homeFiles = [fm contentsOfDirectoryAtPath:GetVideoWallpapersHomeDir() error:nil];
        for (NSString *file in [homeFiles sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            if ([file hasPrefix:@"."]) continue;
            NSString *cleanName = [file stringByDeletingPathExtension];
            NSString *title = [NSString stringWithFormat:@"桌面: %@", cleanName];
            
            [self addActionWithTitle:title subtitle:nil glyph:[UIImage systemImageNamed:@"house.fill"] handler:^(id action) {
                NSString *fullPath = [GetVideoWallpapersHomeDir() stringByAppendingPathComponent:file];
                // 切换壁纸时，强制把插件总开关打开
                UpdateZonePreference(@{@"HomeVideoPath": fullPath, @"Enabled": @YES});
            }];
        }
        
    } else {
        // --- 加载交互壁纸 ---
        NSArray *wpFiles = [fm contentsOfDirectoryAtPath:GetWallpapersDir() error:nil];
        for (NSString *file in [wpFiles sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            if ([file hasPrefix:@"."]) continue;
            NSString *fullPath = [GetWallpapersDir() stringByAppendingPathComponent:file];
            
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir) {
                [self addActionWithTitle:file subtitle:nil glyph:[UIImage systemImageNamed:@"livephoto.play"] handler:^(id action) {
                    // 切换壁纸时，强制把插件总开关打开
                    UpdateZonePreference(@{@"ZonePath": fullPath, @"Enabled": @YES});
                }];
            }
        }
    }
}

// 保证在锁屏界面的控制中心也能呼出菜单
- (BOOL)_canShowWhileLocked {
    return YES;
}
@end


// ==================================================================
// 控制中心模块主干
// ==================================================================
@implementation ZoneCCModule

// 拦截长按/重按事件，注入我们上面写的动态菜单！
- (UIViewController *)contentViewControllerForExpandedState {
    return [[ZoneCCMenuViewController alloc] init];
}

// 单击时按钮的高亮状态：代表当前是否处于【视频模式】
- (BOOL)isSelected {
    Boolean valid;
    BOOL isVideoMode = CFPreferencesGetAppBooleanValue(CFSTR("VideoModeEnabled"), APP_ID, &valid);
    if (valid) return isVideoMode;
    
    NSString *actualPath = GetRealPrefsPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:actualPath];
    if (prefs && prefs[@"VideoModeEnabled"]) {
        return [prefs[@"VideoModeEnabled"] boolValue];
    }
    return NO;
}

// 【单击事件】：在交互模式与视频模式之间无缝切换
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    UpdateZonePreference(@{@"VideoModeEnabled": @(selected)});
}

// ==================== 终极图标绝对居中渲染模块 ====================
- (UIImage *)centeredImageWithSymbolName:(NSString *)name {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium];
    UIImage *sysImage = [UIImage systemImageNamed:name withConfiguration:config];
    if (!sysImage) return nil;
    
    CGSize canvasSize = CGSizeMake(50.0, 50.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize];
    
    UIImage *centeredImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        CGSize imgSize = sysImage.size;
        CGRect rect = CGRectMake((canvasSize.width - imgSize.width) / 2.0,
                                 (canvasSize.height - imgSize.height) / 2.0,
                                 imgSize.width,
                                 imgSize.height);
        [sysImage drawInRect:rect];
    }];
    return [centeredImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// 【单击未高亮图标】：交互模式（星星）
- (UIImage *)iconGlyph {
    return [self centeredImageWithSymbolName:@"sparkles"];
}

// 【单击高亮图标】：视频模式（胶片）
- (UIImage *)selectedIconGlyph {
    return [self centeredImageWithSymbolName:@"film.fill"];
}

// 高亮时的底色：原生蓝
- (UIColor *)selectedColor {
    return [UIColor systemBlueColor];
}

@end
