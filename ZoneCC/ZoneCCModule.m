#import "ZoneCCModule.h"
#import <CoreFoundation/CoreFoundation.h>
#include <sys/stat.h>
#include <unistd.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

#define APP_ID CFSTR("com.iosdump.zoneprefs")
#define NOTIFY_KEY CFSTR("com.iosdump.zoneprefs/ReloadPrefs")

@implementation ZoneCCModule

// 动态获取真实 plist 路径
- (NSString *)getRealPrefsPath {
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

// 返回按钮当前的开关状态
- (BOOL)isSelected {
    Boolean valid;
    BOOL isVideoMode = CFPreferencesGetAppBooleanValue(CFSTR("VideoModeEnabled"), APP_ID, &valid);
    if (valid) {
        return isVideoMode;
    }
    
    // 降级方案：直接读文件
    NSString *actualPath = [self getRealPrefsPath];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:actualPath];
    if (prefs && prefs[@"VideoModeEnabled"]) {
        return [prefs[@"VideoModeEnabled"] boolValue];
    }
    return NO;
}

// 用户点击控制中心按钮时触发
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];

    // 1. 写入系统偏好
    CFPreferencesSetAppValue(CFSTR("VideoModeEnabled"), (__bridge CFNumberRef)@(selected), APP_ID);
    CFPreferencesAppSynchronize(APP_ID);
    
    // 2. 写入底层 Plist 保证数据一致性
    NSString *actualPath = [self getRealPrefsPath];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:actualPath] ?: [NSMutableDictionary dictionary];
    prefs[@"VideoModeEnabled"] = @(selected);
    [prefs writeToFile:actualPath atomically:YES];
    
    // 3. 修复权限，防止 SpringBoard 写入后普通权限应用无法读取
    chown(actualPath.UTF8String, 501, 501);
    chmod(actualPath.UTF8String, 0666);
    
    // 4. 广播通知，让 Tweak.x 接收并立刻切换引擎
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), NOTIFY_KEY, NULL, NULL, YES);
}

// ==================== 苹果原生图标完美排版区域 ====================

// 未选中状态下的图标 (锁屏交互模式：手指点击图标)
- (UIImage *)iconGlyph {
    // 26pt 大小，中等粗细，最匹配苹果原生 CC 模块的尺寸配置
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium];
    UIImage *image = [UIImage systemImageNamed:@"hand.tap" withConfiguration:config];
    // 强制渲染为模板，让控制中心自动居中并上色
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// 选中状态下的图标 (视频模式：已更换为质感更好的“电影胶片”图标)
- (UIImage *)selectedIconGlyph {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium];
    // 使用 film.fill，视觉上更清晰地代表视频/媒体模式
    UIImage *image = [UIImage systemImageNamed:@"film.fill" withConfiguration:config];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// 选中状态下的底色 (跟随系统原生蓝色)
- (UIColor *)selectedColor {
    return [UIColor systemBlueColor];
}

@end
