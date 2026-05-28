#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 动态调用的私有 API 声明 (无需额外链接库)
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

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
// iOS 17
- (void)updatePosterConfigurationMatchingUUID:(id)uuid updates:(id)updates completion:(void(^)(void))completion;
- (void)_updateWallpaperForLocations:(long long)locations options:(unsigned long long)options withCompletion:(void(^)(void))completion;
// iOS 16 / 17 都有的后门强制刷新
- (void)_updateForLockScreenPosterConfiguration:(id)lock homeScreenPosterConfiguration:(id)home;
@end


// ==========================================
// 路径辅助函数
// ==========================================
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【注意: 换成你实际的 bundle id】
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

// 日志宏：带有明显的前缀，方便你在 Console 里搜索
#define TENDIES_LOG(fmt, ...) NSLog(@"[TendiesEnabler_DEBUG] 🚀 " fmt, ##__VA_ARGS__)

// ==========================================
// 核心逻辑：无缝注入与刷新
// ==========================================
static void ApplyTendiesWallpaper(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        TENDIES_LOG(@"收到导入通知，开始执行壁纸挂载流程...");

        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
        if (!prefs) {
            TENDIES_LOG(@"❌ 错误：无法读取偏好设置 Plist: %@", GetPrefsPlistPath());
            return;
        }
        
        if (![prefs[@"Enabled"] boolValue]) {
            TENDIES_LOG(@"⚠️ 插件开关处于关闭状态，退出执行。");
            return;
        }

        NSString *tendiesPath = prefs[@"TendiesPath"];
        if (!tendiesPath || ![[NSFileManager defaultManager] fileExistsAtPath:tendiesPath]) {
            TENDIES_LOG(@"❌ 错误：目标壁纸路径不存在或未设置: %@", tendiesPath);
            return;
        }
        TENDIES_LOG(@"✅ 成功获取待导入壁纸路径: %@", tendiesPath);

        NSFileManager *fm = [NSFileManager defaultManager];
        
        // 1. 获取 PosterBoard 真实沙盒数据目录
        Class LSAppProxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!LSAppProxyClass) {
            TENDIES_LOG(@"❌ 错误：当前环境中找不到 LSApplicationProxy 类");
            return;
        }
        
        id proxy = [LSAppProxyClass applicationProxyForIdentifier:@"com.apple.PosterBoard"];
        NSURL *dataContainerURL = [proxy dataContainerURL];
        if (!dataContainerURL) {
            TENDIES_LOG(@"❌ 错误：获取 PosterBoard 的沙盒 dataContainerURL 失败。");
            return;
        }
        TENDIES_LOG(@"✅ PosterBoard 沙盒路径: %@", dataContainerURL.path);

        // 2. 递归寻找被解压出来的真实描述符目录 (包含 identifier 文件的文件夹)
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
                    // 尝试推断所属的 Extension (如 com.apple.EmojiPoster.EmojiPosterExtension 等)
                    NSArray *components = [fileURL.path pathComponents];
                    if (components.count >= 3) {
                        NSString *possibleExt = components[components.count - 3];
                        if ([possibleExt hasPrefix:@"com.apple."]) {
                            foundExtId = possibleExt;
                        }
                    }
                    TENDIES_LOG(@"✅ 找到了有效的壁纸模板目录: %@", fileURL.path);
                    TENDIES_LOG(@"✅ 推断的 Extension 标识符: %@", foundExtId);
                    break;
                }
            }
        }

        if (!foundDescriptorURL) {
            TENDIES_LOG(@"❌ 错误：在解压目录中没有找到 'com.apple.posterkit.provider.descriptor.identifier' 文件，这不是一个合法的壁纸包！");
            return;
        }

        // 3. 构造目标路径
        NSString *version = @"59";
        if (@available(iOS 17.0, *)) {
            version = @"61";
            TENDIES_LOG(@"✅ 检测到 iOS 17+，使用 DataStore 版本号 61");
        } else {
            TENDIES_LOG(@"✅ 检测到 iOS 16，使用 DataStore 版本号 59");
        }

        NSString *newUUIDFolder = [[NSUUID UUID] UUIDString].uppercaseString;
        NSString *destExtDir = [NSString stringWithFormat:@"%@/Library/Application Support/PRBPosterExtensionDataStore/%@/Extensions/%@/descriptors", dataContainerURL.path, version, foundExtId];
        NSString *destPath = [destExtDir stringByAppendingPathComponent:newUUIDFolder];

        TENDIES_LOG(@"⏳ 准备拷贝壁纸数据到目标海报板库...");
        TENDIES_LOG(@"🎯 目标路径: %@", destPath);

        [fm createDirectoryAtPath:destExtDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *copyErr = nil;
        
        if ([fm copyItemAtPath:foundDescriptorURL.path toPath:destPath error:&copyErr]) {
            TENDIES_LOG(@"✅ 拷贝成功！新壁纸 UUID: %@", newUUIDFolder);
            
            // 4. 随机化 ID 防止覆盖系统已有壁纸
            int randomizedID = 10000 + arc4random_uniform(90000);
            NSString *randomStr = [NSString stringWithFormat:@"%d", randomizedID];
            TENDIES_LOG(@"⏳ 开始随机化内部 identifier 为: %@", randomStr);

            NSError *writeErr = nil;
            BOOL writeSuccess = [randomStr writeToFile:[destPath stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"] 
                                            atomically:YES 
                                              encoding:NSUTF8StringEncoding 
                                                 error:&writeErr];
            if (!writeSuccess) TENDIES_LOG(@"❌ 错误：写入 identifier 失败: %@", writeErr);
            
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
            TENDIES_LOG(@"✅ 随机化 ID 完成。");

            // 5. 实例化系统私有跨进程服务 (这是 SpringBoard 唯一可以安全操控 PosterBoard 的遥控器)
            Class PRSServiceClass = NSClassFromString(@"PRSService");
            if (!PRSServiceClass) {
                TENDIES_LOG(@"❌ 错误：当前环境中找不到 PRSService 类");
                return;
            }
            
            id posterService = [[PRSServiceClass alloc] init];
            TENDIES_LOG(@"✅ 成功获取 PRSService 跨进程服务实例: %@", posterService);

            // 6. 遥控海报板刷新缓存
            TENDIES_LOG(@"⏳ 正在通过 IPC 通知 PosterBoard 扫描新加入的壁纸...");
            [posterService refreshPosterDescriptorsForExtension:foundExtId sessionInfo:nil completion:^(BOOL refreshSuccess, NSError *refreshErr) {
                
                TENDIES_LOG(@"📥 收到扫描回调 - 结果: %d, 错误: %@", refreshSuccess, refreshErr);
                
                // 7. 实例化新壁纸的 Block
                void (^createCompletion)(id, NSError *) = ^(id newConfig, NSError *createError) {
                    if (newConfig) {
                        TENDIES_LOG(@"✅ 成功实例化壁纸配置对象: %@", newConfig);
                        
                        dispatch_async(dispatch_get_main_queue(), ^{
                            TENDIES_LOG(@"⏳ 准备将新壁纸设置为 Active (当前生效)...");
                            
                            // 8. 遥控系统激活壁纸
                            if ([posterService respondsToSelector:@selector(updateToSelectedConfiguration:role:completion:)]) {
                                // iOS 17+
                                [posterService updateToSelectedConfiguration:newConfig role:@"PRPosterRoleLockScreen" completion:^(BOOL activeSuccess, NSError *activeErr) {
                                    TENDIES_LOG(@"🚀 iOS 17 激活请求结束 - 成功: %d, 错误: %@", activeSuccess, activeErr);
                                    
                                    // 解决“桌面没反应”的问题，强制踢一下 SB 的图层控制器
                                    id sbController = [NSClassFromString(@"SBWallpaperController") sharedInstance];
                                    if ([sbController respondsToSelector:@selector(_updateForLockScreenPosterConfiguration:homeScreenPosterConfiguration:)]) {
                                        TENDIES_LOG(@"🔄 正在强制 SBWallpaperController 更新锁屏与主屏幕图层...");
                                        [sbController _updateForLockScreenPosterConfiguration:newConfig homeScreenPosterConfiguration:newConfig];
                                    }
                                }];
                            } else {
                                // iOS 16
                                [posterService updateToSelectedConfiguration:newConfig completion:^(BOOL activeSuccess, NSError *activeErr) {
                                    TENDIES_LOG(@"🚀 iOS 16 激活请求结束 - 成功: %d, 错误: %@", activeSuccess, activeErr);
                                    
                                    id sbController = [NSClassFromString(@"SBWallpaperController") sharedInstance];
                                    if ([sbController respondsToSelector:@selector(_updateForLockScreenPosterConfiguration:homeScreenPosterConfiguration:)]) {
                                        TENDIES_LOG(@"🔄 正在强制 SBWallpaperController 更新锁屏与主屏幕图层...");
                                        [sbController _updateForLockScreenPosterConfiguration:newConfig homeScreenPosterConfiguration:newConfig];
                                    }
                                }];
                            }
                        });
                    } else {
                        TENDIES_LOG(@"❌ 错误：实例化配置失败 (返回的 config 为空): %@", createError);
                    }
                };

                TENDIES_LOG(@"⏳ 正在基于刚导入的模板创建配置实例...");
                // 根据 iOS 版本执行不同参数的创建方法
                if ([posterService respondsToSelector:@selector(createPosterConfigurationForProviderIdentifier:posterDescriptorIdentifier:role:completion:)]) {
                    [posterService createPosterConfigurationForProviderIdentifier:foundExtId posterDescriptorIdentifier:newUUIDFolder role:@"PRPosterRoleLockScreen" completion:createCompletion];
                } else {
                    [posterService createPosterConfigurationForProviderIdentifier:foundExtId posterDescriptorIdentifier:newUUIDFolder completion:createCompletion];
                }
            }];
            
        } else {
            TENDIES_LOG(@"❌ 错误：拷贝文件失败: %@", copyErr);
        }
    });
}

// ==========================================
// 监听来自设置 App 的通知
// ==========================================
static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ApplyTendiesWallpaper();
}

%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    // 只在 SpringBoard 进程响应
    if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        // 使用底层的 Darwin Notify Center 监听设置面板发来的通知
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                        NULL, 
                                        PrefsNotificationCallback, 
                                        CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), 
                                        NULL, 
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
