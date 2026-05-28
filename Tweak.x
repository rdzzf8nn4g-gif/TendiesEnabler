#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h> // 必须引入，用于强制加载私有库

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 1. 物理文件日志系统 (越狱开发的救星)
// ==========================================
static NSString * GetLogFilePath() {
    NSString *base = @"/var/mobile/Documents/TendiesEnabler";
#if __has_include(<roothide.h>)
    base = jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        base = [@"/var/jb" stringByAppendingPathComponent:base];
    }
#endif
    // 确保文件夹存在
    if (![[NSFileManager defaultManager] fileExistsAtPath:base]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [base stringByAppendingPathComponent:@"tweak.log"];
}

// 超级日志宏：带时间戳，直接追加写入物理文件
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
// 2. 辅助函数
// ==========================================
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【确认是你的Bundle ID】
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
// 3. 动态调用的私有 API 声明
// ==========================================
@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
- (NSURL *)dataContainerURL;
@end

@interface PRSService : NSObject
- (void)refreshPosterDescriptorsForExtension:(id)ext sessionInfo:(id)info completion:(void(^)(BOOL, NSError *))completion;
- (void)createPosterConfigurationForProviderIdentifier:(id)provider posterDescriptorIdentifier:(id)descId role:(id)role completion:(void(^)(id config, NSError *err))completion;
- (void)updateToSelectedConfiguration:(id)config role:(id)role completion:(void(^)(BOOL, NSError *))completion;
- (void)createPosterConfigurationForProviderIdentifier:(id)provider posterDescriptorIdentifier:(id)descId completion:(void(^)(id config, NSError *err))completion;
- (void)updateToSelectedConfiguration:(id)config completion:(void(^)(BOOL, NSError *))completion;
@end

@interface SBWallpaperController : NSObject
+ (id)sharedInstance;
- (void)_updateForLockScreenPosterConfiguration:(id)lock homeScreenPosterConfiguration:(id)home;
@end

// ==========================================
// 4. 核心逻辑：无缝注入与刷新 (运行在 SB 中)
// ==========================================
static void ApplyTendiesWallpaper(void) {
    TENDIES_LOG(@"====== 🚀 接收到设置通知，开始执行挂载流程 ======");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        // 强制加载核心私有框架，防止 NSClassFromString 失败
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_LAZY);
        
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
        if (!prefs) {
            TENDIES_LOG(@"❌ 错误：无法读取偏好设置 Plist。路径: %@", GetPrefsPlistPath());
            return;
        }
        
        if (![prefs[@"Enabled"] boolValue]) {
            TENDIES_LOG(@"⚠️ 插件开关处于关闭状态，退出。");
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
            TENDIES_LOG(@"❌ 错误：环境中找不到 LSApplicationProxy 类");
            return;
        }
        
        id proxy = [LSAppProxyClass applicationProxyForIdentifier:@"com.apple.PosterBoard"];
        NSURL *dataContainerURL = [proxy performSelector:@selector(dataContainerURL)];
        if (!dataContainerURL) {
            TENDIES_LOG(@"❌ 错误：获取 PosterBoard 的沙盒 dataContainerURL 失败。");
            return;
        }
        TENDIES_LOG(@"✅ PosterBoard 沙盒路径: %@", dataContainerURL.path);

        // 2. 寻找模板描述符目录
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
                    TENDIES_LOG(@"✅ 找到了壁纸模板目录: %@", fileURL.path);
                    TENDIES_LOG(@"✅ 推断的 Extension: %@", foundExtId);
                    break;
                }
            }
        }

        if (!foundDescriptorURL) {
            TENDIES_LOG(@"❌ 错误：在解压目录中没有找到 descriptor.identifier 文件，格式不正确！");
            return;
        }

        // 3. 构造目标路径
        NSString *version = @"59";
        if (@available(iOS 17.0, *)) {
            version = @"61";
            TENDIES_LOG(@"✅ 检测到 iOS 17+，使用版本 61");
        } else {
            TENDIES_LOG(@"✅ 检测到 iOS 16，使用版本 59");
        }

        NSString *newUUIDFolder = [[NSUUID UUID] UUIDString].uppercaseString;
        NSString *destExtDir = [NSString stringWithFormat:@"%@/Library/Application Support/PRBPosterExtensionDataStore/%@/Extensions/%@/descriptors", dataContainerURL.path, version, foundExtId];
        NSString *destPath = [destExtDir stringByAppendingPathComponent:newUUIDFolder];

        TENDIES_LOG(@"⏳ 准备拷贝至目标路径: %@", destPath);

        [fm createDirectoryAtPath:destExtDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *copyErr = nil;
        
        if ([fm copyItemAtPath:foundDescriptorURL.path toPath:destPath error:&copyErr]) {
            TENDIES_LOG(@"✅ 拷贝成功！新壁纸 UUID: %@", newUUIDFolder);
            
            // 4. 随机化 ID
            int randomizedID = 10000 + arc4random_uniform(90000);
            NSString *randomStr = [NSString stringWithFormat:@"%d", randomizedID];
            
            [randomStr writeToFile:[destPath stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"] 
                        atomically:YES 
                          encoding:NSUTF8StringEncoding 
                             error:nil];
            
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
            TENDIES_LOG(@"✅ 随机化 ID (%d) 完成。", randomizedID);

            // 5. 实例化系统私有跨进程服务
            Class PRSServiceClass = NSClassFromString(@"PRSService");
            if (!PRSServiceClass) {
                TENDIES_LOG(@"❌ 错误：找不到 PRSService 类。即使 dlopen 了也不行？");
                return;
            }
            
            id posterService = [[PRSServiceClass alloc] init];
            TENDIES_LOG(@"✅ 获取 PRSService 实例: %@", posterService);

            // 6. 遥控海报板刷新缓存
            TENDIES_LOG(@"⏳ 通知 PosterBoard 扫描新壁纸...");
            [posterService refreshPosterDescriptorsForExtension:foundExtId sessionInfo:nil completion:^(BOOL refreshSuccess, NSError *refreshErr) {
                
                TENDIES_LOG(@"📥 扫描回调 - 结果: %d, 错误: %@", refreshSuccess, refreshErr);
                
                void (^createCompletion)(id, NSError *) = ^(id newConfig, NSError *createError) {
                    if (newConfig) {
                        TENDIES_LOG(@"✅ 成功实例化壁纸配置: %@", newConfig);
                        
                        dispatch_async(dispatch_get_main_queue(), ^{
                            TENDIES_LOG(@"⏳ 准备将新壁纸设置为 Active...");
                            
                            if ([posterService respondsToSelector:@selector(updateToSelectedConfiguration:role:completion:)]) {
                                [posterService updateToSelectedConfiguration:newConfig role:@"PRPosterRoleLockScreen" completion:^(BOOL activeSuccess, NSError *activeErr) {
                                    TENDIES_LOG(@"🚀 iOS 17 激活请求结束 - 成功: %d, 错误: %@", activeSuccess, activeErr);
                                    
                                    id sbController = [NSClassFromString(@"SBWallpaperController") sharedInstance];
                                    TENDIES_LOG(@"🔄 强制 SBWallpaperController 刷新图层...");
                                    [sbController _updateForLockScreenPosterConfiguration:newConfig homeScreenPosterConfiguration:newConfig];
                                }];
                            } else {
                                [posterService updateToSelectedConfiguration:newConfig completion:^(BOOL activeSuccess, NSError *activeErr) {
                                    TENDIES_LOG(@"🚀 iOS 16 激活请求结束 - 成功: %d, 错误: %@", activeSuccess, activeErr);
                                    
                                    id sbController = [NSClassFromString(@"SBWallpaperController") sharedInstance];
                                    TENDIES_LOG(@"🔄 强制 SBWallpaperController 刷新图层...");
                                    [sbController _updateForLockScreenPosterConfiguration:newConfig homeScreenPosterConfiguration:newConfig];
                                }];
                            }
                        });
                    } else {
                        TENDIES_LOG(@"❌ 错误：实例化配置失败: %@", createError);
                    }
                };

                TENDIES_LOG(@"⏳ 基于模板创建 Configuration...");
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

// 接收来自设置 App 的通知
static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ApplyTendiesWallpaper();
}

%ctor {
    // 全局只注册一次通知。因为你在 plist 限制了 Bundle，这里肯定是 SpringBoard。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), 
                                    NULL, 
                                    PrefsNotificationCallback, 
                                    CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), 
                                    NULL, 
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
