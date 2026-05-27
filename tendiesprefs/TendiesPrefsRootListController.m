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

// 递归赋予权限
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

// 【iOS 16+ 核心】：寻找 PosterBoard 沙盒存储路径
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

// 【iOS 16+ 核心】：将描述符的 Identifier 随机化，骗过系统数据库校验
- (void)randomizeDescriptorIDAtPath:(NSString *)descriptorPath {
    int randID = arc4random_uniform(90000) + 10000;
    NSString *randStr = [NSString stringWithFormat:@"%d", randID];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:descriptorPath];
    NSString *file;
    while((file = [enumerator nextObject])) {
        NSString *full = [descriptorPath stringByAppendingPathComponent:file];
        if ([file.lastPathComponent isEqualToString:@"com.apple.posterkit.provider.contents.userInfo"] || [file.lastPathComponent isEqualToString:@"Wallpaper.plist"]) {
            NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:full];
            if (plist) {
                if ([file.lastPathComponent isEqualToString:@"Wallpaper.plist"]) {
                    plist[@"identifier"] = @(randID);
                } else {
                    plist[@"wallpaperRepresentingIdentifier"] = @(randID);
                }
                [plist writeToFile:full atomically:YES];
            }
        } else if ([file.lastPathComponent isEqualToString:@"com.apple.posterkit.provider.descriptor.identifier"]) {
            [randStr writeToFile:full atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
                    } @catch (NSException *e) { processSuccess = NO; }
                }
            }
            if (isAccessing) [sourceURL stopAccessingSecurityScopedResource];
            
            if (processSuccess) {
                [self setPermissionsRecursive:unzipDir];
                
                // === iOS 16-17 原生文件植入流 ===
                if (@available(iOS 16.0, *)) {
                    NSString *pbDataStore = [self getPosterBoardDataStorePath];
                    if (pbDataStore) {
                        if (![fm fileExistsAtPath:pbDataStore]) {
                            [fm createDirectoryAtPath:pbDataStore withIntermediateDirectories:YES attributes:nil error:nil];
                        }
                        
                        NSString *sourceDescriptors = [unzipDir stringByAppendingPathComponent:@"descriptors"];
                        if ([fm fileExistsAtPath:sourceDescriptors]) {
                            NSArray *items = [fm contentsOfDirectoryAtPath:sourceDescriptors error:nil];
                            for (NSString *item in items) {
                                if ([item hasPrefix:@"."]) continue; // 过滤隐藏文件
                                NSString *srcPath = [sourceDescriptors stringByAppendingPathComponent:item];
                                NSString *destPath = [pbDataStore stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                                
                                [fm copyItemAtPath:srcPath toPath:destPath error:nil];
                                [self randomizeDescriptorIDAtPath:destPath];
                                [self setPermissionsRecursive:destPath];
                            }
                            
                            // 利用 killall 命令直接结束 PosterBoard，让系统自动重启并加载新壁纸
                            Class NSTaskClass = NSClassFromString(@"NSTask");
                            if (NSTaskClass) {
                                @try {
                                    id task = [[NSTaskClass alloc] init];
                                    [task setLaunchPath:@"/usr/bin/killall"];
                                    [task setArguments:@[@"-9", @"PosterBoard"]];
                                    [task launch];
                                } @catch (NSException *e) {}
                            }
                            
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [loadingAlert dismissViewControllerAnimated:YES completion:^{
                                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功 🚀" message:@"壁纸已植入系统！\n\n请在锁屏界面长按，向右划到最后点击“+新增” -> “收藏”，即可找到该壁纸！" preferredStyle:UIAlertControllerStyleAlert];
                                    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                                    [topVC presentViewController:alert animated:YES completion:nil];
                                }];
                            });
                            return; // 结束流程
                        }
                    }
                }
                
                // === iOS 14-15 图层替换流 ===
                CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
                CFPreferencesSetAppValue(CFSTR("TendiesPath"), (__bridge CFStringRef)unzipDir, appID);
                CFPreferencesAppSynchronize(appID);
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功 🚀" message:@"壁纸已成功挂载！关闭控制面板即可在锁屏看到秒切效果。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"解压失败" message:@"无效的壁纸文件，或者环境缺少 unzip 依赖。" preferredStyle:UIAlertControllerStyleAlert];
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
