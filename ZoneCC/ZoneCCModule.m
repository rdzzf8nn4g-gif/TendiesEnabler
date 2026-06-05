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

// ==================== 终极图标绝对居中渲染模块 ====================

// 核心辅助方法：把任意尺寸的 SF Symbol 画死在一个 50x50 的绝对正方形画布正中心
- (UIImage *)centeredImageWithSymbolName:(NSString *)name {
    // 1. 获取系统图标
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium];
    UIImage *sysImage = [UIImage systemImageNamed:name withConfiguration:config];
    
    if (!sysImage) return nil;
    
    // 2. 设定一个绝对正方形画布 (50x50 是控制中心内部最稳的比例)
    CGSize canvasSize = CGSizeMake(50.0, 50.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize];
    
    // 3. 将图标画在画布正中心
    UIImage *centeredImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        CGSize imgSize = sysImage.size;
        // 计算绝对居中的 CGRect
        CGRect rect = CGRectMake((canvasSize.width - imgSize.width) / 2.0,
                                 (canvasSize.height - imgSize.height) / 2.0,
                                 imgSize.width,
                                 imgSize.height);
        
        // 保证绘制时带有原本的透明度特征
        [sysImage drawInRect:rect];
    }];
    
    // 4. 返回纯模板模式，让控制中心自动接管上色 (白/黑/蓝)
    return [centeredImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// 未选中状态下的图标 (锁屏交互模式：手指点击图标)
- (UIImage *)iconGlyph {
    return [self centeredImageWithSymbolName:@"hand.tap"];
}

// 选中状态下的图标 (视频模式：电影胶片图标)
- (UIImage *)selectedIconGlyph {
    return [self centeredImageWithSymbolName:@"film.fill"];
}

// 选中状态下的底色 (跟随系统原生蓝色)
- (UIColor *)selectedColor {
    return [UIColor systemBlueColor];
}

@end
