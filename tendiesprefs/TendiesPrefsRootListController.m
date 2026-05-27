#import "TendiesPrefsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface NSTask : NSObject
@property (copy) NSString *launchPath;
@property (copy) NSArray *arguments;
- (void)launch;
- (void)waitUntilExit;
- (int)terminationStatus;
@end

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

static NSString * GetTendiesStorageDir() {
    NSString *base = @"/var/mobile/Library/Preferences/TendiesEnabler";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

@implementation TendiesPrefsRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)importTendies:(PSSpecifier *)spec {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.0, *)) {
            UTType *itemType = [UTType typeWithIdentifier:@"public.item"];
            UTType *folderType = [UTType typeWithIdentifier:@"public.folder"];
            UTType *dataType = [UTType typeWithIdentifier:@"public.data"];
            
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[itemType, folderType, dataType]];
            picker.delegate = self;
            picker.allowsMultipleSelection = NO;
            
            UIViewController *topVC = self.view.window.rootViewController;
            if (!topVC) topVC = self;
            while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
            
            [topVC presentViewController:picker animated:YES completion:nil];
        }
    });
}

- (void)setPermissionsRecursive:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:path error:nil];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    NSString *subpath;
    while ((subpath = [enumerator nextObject])) {
        NSString *fullPath = [path stringByAppendingPathComponent:subpath];
        [fm setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:fullPath error:nil];
    }
}

- (NSString *)getPosterBoardDataStorePath {
    Class LSAppProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSAppProxy) {
        id proxy = [LSAppProxy performSelector:@selector(applicationProxyForIdentifier:) withObject:@"com.apple.PosterBoard"];
        if (proxy) {
            NSURL *dataURL = [proxy performSelector:@selector(dataContainerURL)];
            if (dataURL) {
                NSString *version = @"59";
                if (@available(iOS 17.0, *)) { version = @"61"; }
                NSString *targetPath = [dataURL.path stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Application Support/PRBPosterExtensionDataStore/%@/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors", version]];
                return targetPath;
            }
        }
    }
    return nil;
}

// 【修复】：以二进制 Plist 格式保存，避免系统检验报错
- (void)randomizeDescriptorIDAtPath:(NSString *)descriptorPath {
    int randID = arc4random_uniform(90000) + 10000;
    NSString *randStr = [NSString stringWithFormat:@"%d", randID];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:descriptorPath];
    NSString *file;
    while((file = [enumerator nextObject])) {
        NSString *full = [descriptorPath stringByAppendingPathComponent:file];
        if ([file.lastPathComponent isEqualToString:@"com.apple.posterkit.provider.contents.userInfo"] || [file.lastPathComponent isEqualToString:@"Wallpaper.plist"]) {
            
            NSData *plistData = [NSData dataWithContentsOfFile:full];
            if (plistData) {
                NSMutableDictionary *plist = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListMutableContainersAndLeaves format:nil error:nil];
                if (plist) {
                    if ([file.lastPathComponent isEqualToString:@"Wallpaper.plist"]) {
                        plist[@"identifier"] = @(randID);
                    } else {
                        plist[@"wallpaperRepresentingIdentifier"] = @(randID);
                    }
                    // 强制 Binary 写回
                    NSData *outData = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
                    if (outData) [outData writeToFile:full atomically:YES];
                }
            }
        } else if ([file.lastPathComponent isEqualToString:@"com.apple.posterkit.provider.descriptor.identifier"]) {
            [[randStr dataUsingEncoding:NSUTF8StringEncoding] writeToFile:full atomically:YES];
        }
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;

    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在解析与挂载...\n\n" message:nil preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.center = CGPointMake(135.0, 65.5);
    [spinner startAnimating];
    [loadingAlert.view addSubview:spinner];
    
    UIViewController *topVC = self.view.window.rootViewController;
    if (!topVC) topVC = self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    
    [topVC presentViewController:loadingAlert animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            
            NSLog(@"[TendiesPrefs] 开始解压任务...");
            BOOL isAccessing = [sourceURL startAccessingSecurityScopedResource];
            NSFileManager *fm = [NSFileManager defaultManager];
            
            NSString *targetDir = GetTendiesStorageDir();
            NSString *unzipDir = [targetDir stringByAppendingPathComponent:@"ActiveTendies"];
            
            if (![fm fileExistsAtPath:targetDir]) {
                [fm createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil];
            }
            [fm removeItemAtPath:unzipDir error:nil];
            [fm createDirectoryAtPath:unzipDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil];
            
            BOOL processSuccess = NO;
            BOOL isDirectory = NO;
            [fm fileExistsAtPath:sourceURL.path isDirectory:&isDirectory];
            
            if (isDirectory) {
                NSArray *contents = [fm contentsOfDirectoryAtPath:sourceURL.path error:nil];
                processSuccess = YES;
                for (NSString *item in contents) {
                    NSString *srcPath = [sourceURL.path stringByAppendingPathComponent:item];
                    NSString *destPath = [unzipDir stringByAppendingPathComponent:item];
                    if (![fm copyItemAtPath:srcPath toPath:destPath error:nil]) processSuccess = NO;
                }
            } else {
                NSString *unzipBin = @"/usr/bin/unzip";
#if __has_include(<roothide.h>)
                unzipBin = jbroot(unzipBin);
#else
                if ([fm fileExistsAtPath:@"/var/jb/usr/bin/unzip"]) unzipBin = @"/var/jb/usr/bin/unzip";
#endif
                Class NSTaskClass = NSClassFromString(@"NSTask");
                if (NSTaskClass && [fm fileExistsAtPath:unzipBin]) {
                    @try {
                        id task = [[NSTaskClass alloc] init];
                        [task setLaunchPath:unzipBin];
                        [task setArguments:@[@"-o", sourceURL.path, @"-d", unzipDir]];
                        [task launch];
                        [task waitUntilExit];
                        processSuccess = ([task terminationStatus] == 0);
                        NSLog(@"[TendiesPrefs] Unzip 状态码: %d", [task terminationStatus]);
                    } @catch (NSException *e) { 
                        NSLog(@"[TendiesPrefs] Unzip 抛出异常: %@", e);
                        processSuccess = NO; 
                    }
                }
            }
            if (isAccessing) [sourceURL stopAccessingSecurityScopedResource];
            
            if (processSuccess) {
                NSLog(@"[TendiesPrefs] 解压成功，开始注入路径...");
                [self setPermissionsRecursive:unzipDir];
                
                // === 通用 Hook 触发流（核心） ===
                CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
                CFPreferencesSetAppValue(CFSTR("TendiesPath"), (__bridge CFStringRef)unzipDir, appID);
                CFPreferencesAppSynchronize(appID);
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
                
                // === iOS 16-17 原生文件植入流（后备方案，修复文件夹嵌套） ===
                if (@available(iOS 16.0, *)) {
                    NSString *pbDataStore = [self getPosterBoardDataStorePath];
                    if (pbDataStore) {
                        if (![fm fileExistsAtPath:pbDataStore]) {
                            [fm createDirectoryAtPath:pbDataStore withIntermediateDirectories:YES attributes:nil error:nil];
                        }
                        
                        NSString *sourceDescriptors = [unzipDir stringByAppendingPathComponent:@"descriptors"];
                        if (![fm fileExistsAtPath:sourceDescriptors]) {
                            NSArray *contents = [fm contentsOfDirectoryAtPath:unzipDir error:nil];
                            for (NSString *sub in contents) {
                                NSString *potential = [[unzipDir stringByAppendingPathComponent:sub] stringByAppendingPathComponent:@"descriptors"];
                                if ([fm fileExistsAtPath:potential]) { sourceDescriptors = potential; break; }
                            }
                        }
                        
                        if ([fm fileExistsAtPath:sourceDescriptors]) {
                            NSLog(@"[TendiesPrefs] 定位到 descriptors: %@", sourceDescriptors);
                            NSArray *items = [fm contentsOfDirectoryAtPath:sourceDescriptors error:nil];
                            for (NSString *item in items) {
                                if ([item hasPrefix:@"."]) continue;
                                NSString *srcPath = [sourceDescriptors stringByAppendingPathComponent:item];
                                NSString *destPath = [pbDataStore stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                                
                                [fm copyItemAtPath:srcPath toPath:destPath error:nil];
                                [self randomizeDescriptorIDAtPath:destPath];
                                [self setPermissionsRecursive:destPath];
                            }
                            
                            NSString *killallBin = @"/usr/bin/killall";
#if __has_include(<roothide.h>)
                            killallBin = jbroot(killallBin);
#else
                            if ([fm fileExistsAtPath:@"/var/jb/usr/bin/killall"]) killallBin = @"/var/jb/usr/bin/killall";
#endif
                            Class NSTaskClass = NSClassFromString(@"NSTask");
                            if (NSTaskClass && [fm fileExistsAtPath:killallBin]) {
                                @try {
                                    id task = [[NSTaskClass alloc] init];
                                    [task setLaunchPath:killallBin];
                                    [task setArguments:@[@"-9", @"PosterBoard"]];
                                    [task launch];
                                    NSLog(@"[TendiesPrefs] 成功重启 PosterBoard 进程");
                                } @catch (NSException *e) {}
                            }
                        }
                    }
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"挂载完成 🚀" message:@"若 Hook 生效：锁屏壁纸将自动转变。\n\n若在 iOS 16+ 想应用原版 Poster：长按锁屏 -> 新增 -> 收藏 即可找到。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }];
                });
            } else {
                NSLog(@"[TendiesPrefs] 解压进程彻底失败。");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"解压失败" message:@"无效的壁纸文件，或缺少 unzip 环境权限。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }];
                });
            }
        });
    }];
}

- (void)openFilzaPath:(PSSpecifier *)spec {
    NSString *targetDir = GetTendiesStorageDir();
    NSString *filzaURLString = [NSString stringWithFormat:@"filza://%@", targetDir];
    NSURL *filzaURL = [NSURL URLWithString:[filzaURLString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    
    if ([[UIApplication sharedApplication] canOpenURL:filzaURL]) {
        [[UIApplication sharedApplication] openURL:filzaURL options:@{} completionHandler:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"请先安装 Filza。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if ([specifier.identifier isEqualToString:@"Enabled"]) {
        CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
        CFPreferencesAppSynchronize(appID);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
    }
}
@end
