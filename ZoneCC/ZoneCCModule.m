#import "ZoneCCModule.h"
#import <CoreFoundation/CoreFoundation.h>

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

// 未选中状态下的图标 (锁屏交互模式：手指点击图标)
- (UIImage *)iconImage {
    return [UIImage systemImageNamed:@"hand.tap"];
}

// 选中状态下的图标 (视频模式：播放矩形图标)
- (UIImage *)selectedIconImage {
    return [UIImage systemImageNamed:@"play.rectangle.fill"];
}

// 选中状态下的主题色 (跟随系统蓝色)
- (UIColor *)selectedColor {
    return [UIColor systemBlueColor];
}

@end
