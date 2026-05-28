#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <sqlite3.h> // 使用原生数据库操作
#import <dlfcn.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

// ==========================================
// 动态调用的私有 API 声明
// ==========================================
@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
- (NSURL *)dataContainerURL;
@end

@interface PRSService : NSObject
- (void)createPosterConfigurationForProviderIdentifier:(id)provider posterDescriptorIdentifier:(id)descId role:(id)role completion:(void(^)(id config, NSError *err))completion;
- (void)updateToSelectedConfiguration:(id)config role:(id)role completion:(void(^)(BOOL, NSError *))completion;
- (void)createPosterConfigurationForProviderIdentifier:(id)provider posterDescriptorIdentifier:(id)descId completion:(void(^)(id config, NSError *err))completion;
- (void)updateToSelectedConfiguration:(id)config completion:(void(^)(BOOL, NSError *))completion;
@end

// ==========================================
// 路径与日志辅助函数
// ==========================================
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist"; // 【注意换成你的BundleID】
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

// 物理日志宏：直接写入文本，无视系统过滤
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
// 系统级操作：强杀守护进程
// ==========================================
static void ForceKillProcessByName(NSString *targetName) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return;
    
    struct kinfo_proc *processList = malloc(size);
    if (sysctl(mib, 4, processList, &size, NULL, 0) == 0) {
        int count = size / sizeof(struct kinfo_proc);
        for (int i = 0; i < count; i++) {
            struct kinfo_proc proc = processList[i];
            NSString *procName = [NSString stringWithCString:proc.kp_proc.p_comm encoding:NSUTF8StringEncoding];
            if ([procName isEqualToString:targetName]) {
                kill(proc.kp_proc.p_pid, SIGKILL);
                TENDIES_LOG(@"🔫 已静默强杀后台守护进程: %@", targetName);
            }
        }
    }
    free(processList);
}

// ==========================================
// 核心数据库注入逻辑 (完美复刻系统机制)
// ==========================================
static NSString *FindDatabasePath(NSString *containerPath) {
    NSString *dataStoreURL = [containerPath stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore"];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:dataStoreURL];
    for (NSString *file in enumerator) {
        if ([file.lastPathComponent isEqualToString:@"PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"]) {
            return [dataStoreURL stringByAppendingPathComponent:file];
        }
    }
    return nil;
}

static void InjectIntoDatabase(NSString *dbPath, NSString *uuid, NSString *providerId) {
    sqlite3 *db;
    if (sqlite3_open([dbPath UTF8String], &db) == SQLITE_OK) {
        sqlite3_exec(db, "PRAGMA busy_timeout = 2000;", NULL, NULL, NULL);
        sqlite3_stmt *stmt;
        
        NSString *insertPoster = @"INSERT OR IGNORE INTO poster (UUID, providerId) VALUES (?, ?);";
        if (sqlite3_prepare_v2(db, [insertPoster UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [uuid UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, [providerId UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
        }
        sqlite3_finalize(stmt);
        
        NSString *insertRole = @"INSERT OR IGNORE INTO posterRoleMembership (posterUUID, roleId, roleSortKey) VALUES (?, 'PRPosterRoleLockScreen', 0);";
        if (sqlite3_prepare_v2(db, [insertRole UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [uuid UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
        }
        sqlite3_finalize(stmt);
        
        NSString *payload = [NSString stringWithFormat:@"{\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\",\"creationDate\":%f,\"lastModifiedDate\":%f}", [[NSDate date] timeIntervalSince1970], [[NSDate date] timeIntervalSince1970]];
        NSString *insertAttr = @"INSERT OR IGNORE INTO posterAttributes (posterUUID, roleId, attributeIdentifier, attributePayload) VALUES (?, 'PRPosterRoleLockScreen', 'PRPosterRoleAttributeTypeUsageMetadata', ?);";
        if (sqlite3_prepare_v2(db, [insertAttr UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [uuid UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, [payload UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
        }
        sqlite3_finalize(stmt);
        
        sqlite3_close(db);
        TENDIES_LOG(@"✅ iOS 17 SQLite 数据库注入成功！");
    } else {
        TENDIES_LOG(@"❌ 错误：无法打开 SQLite 数据库: %@", dbPath);
    }
}

static void InjectIntoPlist(NSString *plistPath, NSString *uuid) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (!dict) dict = [NSMutableDictionary dictionary];
    
    NSMutableArray *order = [dict[@"kProactiveDynamicPosterDescriptorOrdering"] mutableCopy];
    if (!order) order = [NSMutableArray array];
    
    if (![order containsObject:uuid]) {
        [order addObject:uuid];
        dict[@"kProactiveDynamicPosterDescriptorOrdering"] = order;
        [dict writeToFile:plistPath atomically:YES];
        TENDIES_LOG(@"✅ iOS 16 ProviderInfo.plist 注入成功！");
    }
}


// ==========================================
// 核心装载逻辑：文件写入 -> 写库 -> 杀后台 -> 跨进程激活
// ==========================================
static void ApplyTendiesWallpaper(void) {
    TENDIES_LOG(@"====== 🚀 接收到设置通知，开始执行挂载流程 ======");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_LAZY);
        
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:GetPrefsPlistPath()];
        if (!prefs || ![prefs[@"Enabled"] boolValue]) {
            TENDIES_LOG(@"⚠️ 插件开关未开启，退出。");
            return;
        }

        NSString *tendiesPath = prefs[@"TendiesPath"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!tendiesPath || ![fm fileExistsAtPath:tendiesPath]) {
            TENDIES_LOG(@"❌ 错误：壁纸路径不存在");
            return;
        }
        TENDIES_LOG(@"✅ 获取导入路径: %@", tendiesPath);

        // 1. 获取 PosterBoard 真实沙盒
        Class LSAppProxyClass = NSClassFromString(@"LSApplicationProxy");
        id proxy = [LSAppProxyClass applicationProxyForIdentifier:@"com.apple.PosterBoard"];
        NSURL *dataContainerURL = [proxy performSelector:@selector(dataContainerURL)];
        if (!dataContainerURL) {
            TENDIES_LOG(@"❌ 获取 PosterBoard 容器路径失败。");
            return;
        }

        // 2. 寻找模板描述符
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:tendiesPath] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];

        NSURL *foundDescriptorURL = nil;
        NSString *foundExtId = @"com.apple.WallpaperKit.CollectionsPoster";

        for (NSURL *fileURL in enumerator) {
            NSNumber *isDirectory;
            [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
            if ([isDirectory boolValue]) {
                if ([fm fileExistsAtPath:[fileURL.path stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]]) {
                    foundDescriptorURL = fileURL;
                    NSArray *comps = [fileURL.path pathComponents];
                    if (comps.count >= 3 && [comps[comps.count - 3] hasPrefix:@"com.apple."]) {
                        foundExtId = comps[comps.count - 3];
                    }
                    break;
                }
            }
        }

        if (!foundDescriptorURL) {
            TENDIES_LOG(@"❌ 未找到合法的壁纸模板！");
            return;
        }

        // 3. 构造路径与版本
        BOOL isIOS17 = NO;
        NSString *version = @"59";
        if (@available(iOS 17.0, *)) {
            version = @"61";
            isIOS17 = YES;
        }

        NSString *newUUIDFolder = [[NSUUID UUID] UUIDString].uppercaseString;
        NSString *destExtDir = [NSString stringWithFormat:@"%@/Library/Application Support/PRBPosterExtensionDataStore/%@/Extensions/%@/descriptors", dataContainerURL.path, version, foundExtId];
        NSString *destPath = [destExtDir stringByAppendingPathComponent:newUUIDFolder];

        [fm createDirectoryAtPath:destExtDir withIntermediateDirectories:YES attributes:nil error:nil];
        
        if ([fm copyItemAtPath:foundDescriptorURL.path toPath:destPath error:nil]) {
            TENDIES_LOG(@"✅ 壁纸文件已放入海报板: %@", newUUIDFolder);
            
            // 4. 随机化内部 ID
            int randomizedID = 10000 + arc4random_uniform(90000);
            [[NSString stringWithFormat:@"%d", randomizedID] writeToFile:[destPath stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            
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

            // 5. 暴力注入数据库/注册表 (解决 Error -2218 的核心)
            if (isIOS17) {
                NSString *dbPath = FindDatabasePath(dataContainerURL.path);
                if (dbPath) {
                    InjectIntoDatabase(dbPath, newUUIDFolder, foundExtId);
                } else {
                    TENDIES_LOG(@"❌ 找不到 SQLite 数据库！");
                }
            } else {
                NSString *plistPath = [NSString stringWithFormat:@"%@/Library/Application Support/PRBPosterExtensionDataStore/59/Extensions/%@/ProviderInfo.plist", dataContainerURL.path, foundExtId];
                InjectIntoPlist(plistPath, newUUIDFolder);
            }

            // 6. 静默杀掉海报板进程，让它重新读取数据库
            TENDIES_LOG(@"⏳ 正在静默重启海报板以装载新数据...");
            ForceKillProcessByName(@"PosterBoard");
            ForceKillProcessByName(@"wallpaperd");
            ForceKillProcessByName(@"CollectionsPoster");

            // 关闭开关防止重复运行
            prefs[@"Enabled"] = @NO;
            [prefs writeToFile:GetPrefsPlistPath() atomically:YES];

            // 7. 延迟 1.5 秒等后台 Daemon 重启后，发送指令应用壁纸！
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                Class PRSServiceClass = NSClassFromString(@"PRSService");
                id posterService = [[PRSServiceClass alloc] init];
                
                if (!posterService) {
                    TENDIES_LOG(@"❌ 无法加载 PRSService");
                    return;
                }

                void (^createCompletion)(id, NSError *) = ^(id newConfig, NSError *createError) {
                    if (newConfig) {
                        TENDIES_LOG(@"✅ 海报板返回了新壁纸实例，准备推送到桌面...");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if ([posterService respondsToSelector:@selector(updateToSelectedConfiguration:role:completion:)]) {
                                [posterService updateToSelectedConfiguration:newConfig role:@"PRPosterRoleLockScreen" completion:^(BOOL activeSuccess, NSError *activeErr) {
                                    TENDIES_LOG(@"🚀 iOS 17 切换指令发送完毕 - 成功: %d, 错误: %@", activeSuccess, activeErr);
                                }];
                            } else {
                                [posterService updateToSelectedConfiguration:newConfig completion:^(BOOL activeSuccess, NSError *activeErr) {
                                    TENDIES_LOG(@"🚀 iOS 16 切换指令发送完毕 - 成功: %d, 错误: %@", activeSuccess, activeErr);
                                }];
                            }
                        });
                    } else {
                        TENDIES_LOG(@"❌ 实例化失败: %@", createError);
                    }
                };

                TENDIES_LOG(@"⏳ 正在请求激活刚写入的新壁纸...");
                if ([posterService respondsToSelector:@selector(createPosterConfigurationForProviderIdentifier:posterDescriptorIdentifier:role:completion:)]) {
                    [posterService createPosterConfigurationForProviderIdentifier:foundExtId posterDescriptorIdentifier:newUUIDFolder role:@"PRPosterRoleLockScreen" completion:createCompletion];
                } else {
                    [posterService createPosterConfigurationForProviderIdentifier:foundExtId posterDescriptorIdentifier:newUUIDFolder completion:createCompletion];
                }
            });
            
        } else {
            TENDIES_LOG(@"❌ 拷贝失败！");
        }
    });
}

static void PrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ApplyTendiesWallpaper();
}

%ctor {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PrefsNotificationCallback, CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
