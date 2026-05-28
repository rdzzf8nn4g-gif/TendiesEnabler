#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ==========================================
// 私有 API 声明 (无需链接库，通过 NSClassFromString 动态调用)
// ==========================================
@interface PRSPosterPath : NSObject
@end

@interface PRPosterConfiguration : NSObject
- (PRSPosterPath *)_path;
@end

@interface PRSPosterConfiguration : NSObject
- (id)_initWithPath:(id)path;
@end

@interface PRSService : NSObject
- (void)updateToSelectedConfiguration:(id)arg1 role:(id)arg2 completion:(void (^)(BOOL, NSError *))arg3;
- (void)updateToSelectedConfiguration:(id)arg1 completion:(void (^)(BOOL, NSError *))arg2;
@end

@interface PBFPosterExtensionDataStore : NSObject
@property (readonly, nonatomic) NSURL *URL;
- (void)reloadPosterDescriptorsForExtensionBundleIdentifier:(id)identifier sessionInfo:(id)info completion:(void(^)(BOOL, NSError*))completion;
// iOS 17
- (void)createPosterConfigurationForProviderIdentifier:(id)provider posterDescriptorIdentifier:(id)descId role:(id)role completion:(void(^)(PRPosterConfiguration*, NSError*))completion;
// iOS 16
- (void)createPosterConfigurationForProviderIdentifier:(id)provider posterDescriptorIdentifier:(id)descId completion:(void(^)(PRPosterConfiguration*, NSError*))completion;
@end

// 窃取的全局 DataStore 单例
static PBFPosterExtensionDataStore *sharedDataStore = nil;

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

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
// 核心：无缝注入与刷新逻辑
// ==========================================
static void ApplyTendiesWallpaper(void) {
    if (!sharedDataStore) {
        NSLog(@"[TendiesEnabler] sharedDataStore 为空，可能 PosterBoard 尚未初始化完毕。");
        return;
    }

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
    if (!prefs || ![prefs[@"Enabled"] boolValue]) return;

    NSString *tendiesPath = prefs[@"TendiesPath"];
    if (!tendiesPath || ![[NSFileManager defaultManager] fileExistsAtPath:tendiesPath]) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 1. 递归寻找描述符目录 (包含 identifier 文件的文件夹)
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
                // 尝试从目录层级推断 extId
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

    // 2. 构造目标路径
    NSString *dataStoreBase = [sharedDataStore.URL path];
    NSString *version = (@available(iOS 17.0, *)) ? @"61" : @"59";
    NSString *newUUIDFolder = [[NSUUID UUID] UUIDString].uppercaseString; // 必须大写
    NSString *destExtDir = [NSString stringWithFormat:@"%@/%@/Extensions/%@/descriptors", dataStoreBase, version, foundExtId];
    NSString *destPath = [destExtDir stringByAppendingPathComponent:newUUIDFolder];

    [fm createDirectoryAtPath:destExtDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *copyErr;
    
    if ([fm copyItemAtPath:foundDescriptorURL.path toPath:destPath error:&copyErr]) {
        // 3. 完美复刻原项目的随机化逻辑：生成 5 位随机数字 ID，防止覆盖冲突
        int randomizedID = 10000 + arc4random_uniform(90000);
        NSString *randomStr = [NSString stringWithFormat:@"%d", randomizedID];

        // 覆盖 identifier 文本
        [randomStr writeToFile:[destPath stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"] atomically:YES encoding:NSUTF8String error:nil];
        
        // 覆盖 userInfo plist
        NSString *userInfoPath = [destPath stringByAppendingPathComponent:@"com.apple.posterkit.provider.contents.userInfo"];
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithContentsOfFile:userInfoPath];
        if (userInfo) {
            userInfo[@"wallpaperRepresentingIdentifier"] = @(randomizedID);
            [userInfo writeToFile:userInfoPath atomically:YES];
        }
        
        // 覆盖 Wallpaper.plist
        NSString *wpPlistPath = [destPath stringByAppendingPathComponent:@"Wallpaper.plist"];
        NSMutableDictionary *wpPlist = [NSMutableDictionary dictionaryWithContentsOfFile:wpPlistPath];
        if (wpPlist) {
            wpPlist[@"identifier"] = @(randomizedID);
            [wpPlist writeToFile:wpPlistPath atomically:YES];
        }

        // 4. 让海报板进行原生重载扫描！
        [sharedDataStore reloadPosterDescriptorsForExtensionBundleIdentifier:foundExtId sessionInfo:nil completion:^(BOOL success, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                
                // 完成创建的回调：激活它！
                void (^createCompletion)(PRPosterConfiguration *, NSError *) = ^(PRPosterConfiguration *newConfig, NSError *error) {
                    if (newConfig) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            // 5. 将返回的配置转换成服务层能识别的配置进行跨进程传输
                            id path = [newConfig performSelector:@selector(_path)];
                            id prsConfig = [[NSClassFromString(@"PRSPosterConfiguration") alloc] _initWithPath:path];

                            // 6. 终极调用：请求系统无缝切换！
                            id posterService = [[NSClassFromString(@"PRSService") alloc] init];
                            if ([posterService respondsToSelector:@selector(updateToSelectedConfiguration:role:completion:)]) {
                                // iOS 17+
                                [posterService updateToSelectedConfiguration:prsConfig role:@"PRPosterRoleLockScreen" completion:^(BOOL success, NSError *e) {
                                    NSLog(@"[TendiesEnabler] iOS 17+ 切换成功: %d", success);
                                }];
                            } else {
                                // iOS 16
                                [posterService updateToSelectedConfiguration:prsConfig completion:^(BOOL success, NSError *e) {
                                    NSLog(@"[TendiesEnabler] iOS 16 切换成功: %d", success);
                                }];
                            }
                        });
                    } else {
                        NSLog(@"[TendiesEnabler] 创建配置失败: %@", error);
                    }
                };

                // 根据 iOS 版本调用对应的实例化方法
                if ([sharedDataStore respondsToSelector:@selector(createPosterConfigurationForProviderIdentifier:posterDescriptorIdentifier:role:completion:)]) {
                    [sharedDataStore createPosterConfigurationForProviderIdentifier:foundExtId posterDescriptorIdentifier:newUUIDFolder role:@"PRPosterRoleLockScreen" completion:createCompletion];
                } else {
                    [sharedDataStore createPosterConfigurationForProviderIdentifier:foundExtId posterDescriptorIdentifier:newUUIDFolder completion:createCompletion];
                }
            });
        }];
    }
}

// 接收来自设置 App 的通知
static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ApplyTendiesWallpaper();
}

// ==========================================
// Hook 核心 DataStore
// ==========================================
%hook PBFPosterExtensionDataStore

// 兼容 iOS 17 的初始化
- (id)initWithURL:(id)url runtimeAssertionProvider:(id)provider extensionProvider:(id)extensionProvider observer:(id)observer wasMigrationJustPerformed:(BOOL)performed applicationStateMonitor:(id)monitor error:(out id *)error {
    sharedDataStore = %orig;
    return sharedDataStore;
}

// 兼容 iOS 16 的初始化
- (id)initWithURL:(id)url runtimeAssertionProvider:(id)provider observer:(id)observer wasMigrationJustPerformed:(BOOL)performed error:(out id *)error {
    sharedDataStore = %orig;
    return sharedDataStore;
}

%end

%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    // 仅在 PosterBoard 进程里注册通知以防重复调用
    if ([bundleId isEqualToString:@"com.apple.PosterBoard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PrefsNotificationCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
