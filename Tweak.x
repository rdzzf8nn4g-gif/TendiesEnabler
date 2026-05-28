#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 私有 API 声明 (通过 NSClassFromString 动态调用)
// ==========================================
@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
- (NSURL *)dataContainerURL;
@end

@interface PRSService : NSObject
- (void)refreshPosterDescriptorsForExtension:(id)ext sessionInfo:(id)info completion:(void(^)(BOOL, NSError *))completion;
// iOS 17
- (void)createPosterConfigurationForProviderIdentifier:(id)provider posterDescriptorIdentifier:(id)descId role:(id)role completion:(void(^)(id config, NSError *err))completion;
- (void)updateToSelectedConfiguration:(id)config role:(id)role completion:(void(^)(BOOL, NSError *))completion;
// iOS 16
- (void)createPosterConfigurationForProviderIdentifier:(id)provider posterDescriptorIdentifier:(id)descId completion:(void(^)(id config, NSError *err))completion;
- (void)updateToSelectedConfiguration:(id)config completion:(void(^)(BOOL, NSError *))completion;
@end

// ==========================================
// 辅助函数
// ==========================================
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
// 核心：无缝注入与刷新逻辑 (运行在 SpringBoard 中)
// ==========================================
static void ApplyTendiesWallpaper(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
        if (!prefs || ![prefs[@"Enabled"] boolValue]) return;

        NSString *tendiesPath = prefs[@"TendiesPath"];
        if (!tendiesPath || ![[NSFileManager defaultManager] fileExistsAtPath:tendiesPath]) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        
        // 1. 获取 PosterBoard 的真实沙盒数据目录
        Class LSAppProxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!LSAppProxyClass) return;
        LSApplicationProxy *proxy = [LSAppProxyClass applicationProxyForIdentifier:@"com.apple.PosterBoard"];
        NSURL *dataContainerURL = [proxy dataContainerURL];
        if (!dataContainerURL) {
            NSLog(@"[TendiesEnabler] 无法获取 PosterBoard 数据目录");
            return;
        }

        // 2. 递归寻找描述符目录
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:tendiesPath]
                                     includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                   errorHandler:nil];

        NSURL *foundDescriptorURL = nil;
        NSString *foundExtId = @"com.apple.WallpaperKit.CollectionsPoster";

        for (NSURL *fileURL in enumerator) {
            NSNumber *isDirectory;
            [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
            if ([isDirectory boolValue]) {
                NSString *identifierPath = [fileURL.path stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"];
                if ([fm fileExistsAtPath:identifierPath]) {
                    foundDescriptorURL = fileURL;
                    NSArray *components = [fileURL.path pathComponents];
                    if (components.count >= 3) {
                        NSString *possibleExt = components[components.count - 3];
                        if ([possibleExt hasPrefix:@"com.apple."]) {
                            foundExtId = possibleExt;
                        }
                    }
                    break;
                }
            }
        }

        if (!foundDescriptorURL) return;

        // 3. 构造目标路径 (处理 @available 编译报错)
        NSString *version = @"59";
        if (@available(iOS 17.0, *)) {
            version = @"61";
        }

        NSString *newUUIDFolder = [[NSUUID UUID] UUIDString].uppercaseString;
        NSString *destExtDir = [NSString stringWithFormat:@"%@/Library/Application Support/PRBPosterExtensionDataStore/%@/Extensions/%@/descriptors", dataContainerURL.path, version, foundExtId];
        NSString *destPath = [destExtDir stringByAppendingPathComponent:newUUIDFolder];

        [fm createDirectoryAtPath:destExtDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *copyErr;
        
        if ([fm copyItemAtPath:foundDescriptorURL.path toPath:destPath error:&copyErr]) {
            // 4. 随机化 ID (修复 NSUTF8StringEncoding 报错)
            int randomizedID = 10000 + arc4random_uniform(90000);
            NSString *randomStr = [NSString stringWithFormat:@"%d", randomizedID];

            [randomStr writeToFile:[destPath stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            
            NSString *userInfoPath = [destPath stringByAppendingPathComponent:@"com.apple.posterkit.provider.contents.userInfo"];
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithContentsOfFile:userInfoPath];
            if (userInfo) {
                userInfo[@"wallpaperRepresentingIdentifier"] = @(randomizedID);
                [userInfo writeToFile:userInfoPath atomically:YES];
            }
            
            NSString *wpPlistPath = [destPath stringByAppendingPathComponent:@"Wallpaper.plist"];
            NSMutableDictionary *wpPlist = [NSMutableDictionary dictionaryWithContentsOfFile:wpPlistPath];
            if (wpPlist) {
                wpPlist[@"identifier"] = @(randomizedID);
                [wpPlist writeToFile:wpPlistPath atomically:YES];
            }

            // 5. 实例化系统私有跨进程服务
            PRSService *posterService = [[NSClassFromString(@"PRSService") alloc] init];
            if (!posterService) return;

            // 6. 遥控海报板刷新缓存
            [posterService refreshPosterDescriptorsForExtension:foundExtId sessionInfo:nil completion:^(BOOL success, NSError *err) {
                
                // 7. 遥控海报板基于我们丢进去的文件实例化一个新壁纸 Configuration
                void (^createCompletion)(id, NSError *) = ^(id newConfig, NSError *error) {
                    if (newConfig) {
                        // 8. 遥控系统将新 Configuration 设置为锁屏/桌面，完美触发无缝动画！
                        if ([posterService respondsToSelector:@selector(updateToSelectedConfiguration:role:completion:)]) {
                            // iOS 17+
                            [posterService updateToSelectedConfiguration:newConfig role:@"PRPosterRoleLockScreen" completion:^(BOOL success2, NSError *e) {
                                NSLog(@"[TendiesEnabler] iOS 17+ 切换成功: %d", success2);
                            }];
                        } else {
                            // iOS 16
                            [posterService updateToSelectedConfiguration:newConfig completion:^(BOOL success2, NSError *e) {
                                NSLog(@"[TendiesEnabler] iOS 16 切换成功: %d", success2);
                            }];
                        }
                    } else {
                        NSLog(@"[TendiesEnabler] 创建配置失败: %@", error);
                    }
                };

                if ([posterService respondsToSelector:@selector(createPosterConfigurationForProviderIdentifier:posterDescriptorIdentifier:role:completion:)]) {
                    [posterService createPosterConfigurationForProviderIdentifier:foundExtId posterDescriptorIdentifier:newUUIDFolder role:@"PRPosterRoleLockScreen" completion:createCompletion];
                } else {
                    [posterService createPosterConfigurationForProviderIdentifier:foundExtId posterDescriptorIdentifier:newUUIDFolder completion:createCompletion];
                }
            }];
        }
    });
}

// 接收来自设置 App 的通知
static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ApplyTendiesWallpaper();
}

%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    // 只在 SpringBoard 进程响应
    if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PrefsNotificationCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
