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
// 控制中心专属：私有 API 声明 (ControlCenterUIKit)
// ==================================================================
@interface CCUIMenuModuleItem : NSObject
@end

@interface CCUIMenuModuleViewController : UIViewController
- (void)addActionWithTitle:(NSString *)title glyph:(UIImage *)glyph handler:(void (^)(CCUIMenuModuleItem *action))handler;
- (void)addActionWithTitle:(NSString *)title subtitle:(NSString *)subtitle glyph:(UIImage *)glyph handler:(void (^)(CCUIMenuModuleItem *action))handler;
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
    [self removeAllActions]; // 清空旧菜单
    
    NSString *prefsPath = GetRealPrefsPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
    BOOL isVideoMode = [prefs[@"VideoModeEnabled"] boolValue];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. 【通用操作】：关闭引擎
    [self addActionWithTitle:@"关闭引擎" subtitle:@"停止渲染并释放内存" glyph:[UIImage systemImageNamed:@"power"] handler:^(CCUIMenuModuleItem *action) {
        UpdateZonePreference(@{@"Enabled": @NO});
    }];

    // 2. 【通用操作】：一键模式切换
    NSString *switchTitle = isVideoMode ? @"切换至: 交互壁纸模式" : @"切换至: 视频壁纸模式";
    UIImage *switchIcon = [UIImage systemImageNamed:@"arrow.left.arrow.right"];
    [self addActionWithTitle:switchTitle glyph:switchIcon handler:^(CCUIMenuModuleItem *action) {
        UpdateZonePreference(@{@"VideoModeEnabled": @(!isVideoMode)});
    }];

    // 3. 【多态素材列表】：根据模式渲染不同的壁纸选择器
    if (isVideoMode) {
        // --- 加载锁屏视频 ---
        NSArray *lockFiles = [fm contentsOfDirectoryAtPath:GetVideoWallpapersLockDir() error:nil];
        for (NSString *file in [lockFiles sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            if ([file hasPrefix:@"."]) continue;
            NSString *cleanName = [file stringByDeletingPathExtension];
            NSString *title = [NSString stringWithFormat:@"锁屏: %@", cleanName];
            
            [self addActionWithTitle:title glyph:[UIImage systemImageNamed:@"lock.fill"] handler:^(CCUIMenuModuleItem *action) {
                NSString *fullPath = [GetVideoWallpapersLockDir() stringByAppendingPathComponent:file];
                UpdateZonePreference(@{@"LockVideoPath": fullPath, @"Enabled": @YES});
            }];
        }
        
        // --- 加载桌面视频 ---
        NSArray *homeFiles = [fm contentsOfDirectoryAtPath:GetVideoWallpapersHomeDir() error:nil];
        for (NSString *file in [homeFiles sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            if ([file hasPrefix:@"."]) continue;
            NSString *cleanName = [file stringByDeletingPathExtension];
            NSString *title = [NSString stringWithFormat:@"桌面: %@", cleanName];
            
            [self addActionWithTitle:title glyph:[UIImage systemImageNamed:@"house.fill"] handler:^(CCUIMenuModuleItem *action) {
                NSString *fullPath = [GetVideoWallpapersHomeDir() stringByAppendingPathComponent:file];
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
                [self addActionWithTitle:file glyph:[UIImage systemImageNamed:@"livephoto.play"] handler:^(CCUIMenuModuleItem *action) {
                    UpdateZonePreference(@{@"ZonePath": fullPath, @"Enabled": @YES});
                }];
            }
        }
    }
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

// 返回按钮当前的全局开关状态
- (BOOL)isSelected {
    Boolean valid;
    BOOL isEnabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), APP_ID, &valid);
    if (valid) return isEnabled;
    
    NSString *actualPath = GetRealPrefsPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:actualPath];
    if (prefs && prefs[@"Enabled"]) {
        return [prefs[@"Enabled"] boolValue];
    }
    return NO;
}

// 用户单次点击控制中心按钮时触发 (总开关切换)
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    UpdateZonePreference(@{@"Enabled": @(selected)});
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

// 未选中状态下的图标 (手指点击)
- (UIImage *)iconGlyph {
    return [self centeredImageWithSymbolName:@"hand.tap"];
}

// 选中状态下的图标 (动态感知：如果是视频模式就换成胶片，交互模式换成星星)
- (UIImage *)selectedIconGlyph {
    NSString *actualPath = GetRealPrefsPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:actualPath];
    BOOL isVideoMode = [prefs[@"VideoModeEnabled"] boolValue];
    
    if (isVideoMode) {
        return [self centeredImageWithSymbolName:@"film.fill"];
    } else {
        return [self centeredImageWithSymbolName:@"sparkles"];
    }
}

// 选中状态下的底色
- (UIColor *)selectedColor {
    return [UIColor systemBlueColor];
}

@end
