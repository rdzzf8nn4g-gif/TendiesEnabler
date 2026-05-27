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

// 声明私有 API 用于获取 App 沙盒路径 (iOS 16+ 核心所在)
@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(NSString *)bundleIdentifier;
@property (nonatomic, readonly) NSURL *dataContainerURL;
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

// 递归赋予 0777 权限
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

// ==========================================
// 【iOS 16+ 原生 PosterBoard 注入引擎】
// ==========================================
- (void)injectIntoPosterBoard:(NSString *)unzipDir {
    Class LSAppProxy = NSClassFromString(@"LSApplicationProxy");
    if (!LSAppProxy) return;
    
    id proxy = [LSAppProxy performSelector:@selector(applicationProxyForIdentifier:) withObject:@"com.apple.PosterBoard"];
    NSURL *containerURL = [proxy performSelector:@selector(dataContainerURL)];
    if (!containerURL) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *baseStore = [containerURL.path stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore"];

    // 获取最高版本的扩展文件夹 (例如 iOS 16 是 59/60，iOS 17 是 61)
    NSArray *versions = [fm contentsOfDirectoryAtPath:baseStore error:nil];
    int maxVer = 0;
    for (NSString *v in versions) {
        if (v.intValue > maxVer) maxVer = v.intValue;
    }
    if (maxVer == 0) return; 

    NSString *destPath = [NSString stringWithFormat:@"%@/%d/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors", baseStore, maxVer];
    if (![fm fileExistsAtPath:destPath]) {
        [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // 定位解压包中的 descriptors 文件夹
    NSString *srcDescriptors = [unzipDir stringByAppendingPathComponent:@"descriptors"];
    if (![fm fileExistsAtPath:srcDescriptors]) {
        if ([fm fileExistsAtPath:[unzipDir stringByAppendingPathComponent:@"descriptor"]]) {
            srcDescriptors = [unzipDir stringByAppendingPathComponent:@"descriptor"];
        } else {
            srcDescriptors = unzipDir; // Fallback
        }
    }

    NSArray *descFolders = [fm contentsOfDirectoryAtPath:srcDescriptors error:nil];
    for (NSString *descName in descFolders) {
        if ([descName isEqualToString:@"__MACOSX"]) continue;
        
        NSString *fullDescPath = [srcDescriptors stringByAppendingPathComponent:descName];
        BOOL isDir;
        if ([fm fileExistsAtPath:fullDescPath isDirectory:&isDir] && isDir) {
            
            // 核心步骤：随机化 Identifier 避免系统冲突
            NSNumber *randomIDNum = @(arc4random_uniform(90000) + 10000);
            NSString *randomStr = [randomIDNum stringValue];
            
            // 遍历并修改配置
            NSDirectoryEnumerator *enumFiles = [fm enumeratorAtPath:fullDescPath];
            NSString *file;
            while ((file = [enumFiles nextObject])) {
                NSString *modPath = [fullDescPath stringByAppendingPathComponent:file];
                NSString *name = file.lastPathComponent;

                if ([name isEqualToString:@"com.apple.posterkit.provider.descriptor.identifier"]) {
                    [randomStr writeToFile:modPath atomically:YES encoding:NSUTF8String error:nil];
                } else if ([name isEqualToString:@"com.apple.posterkit.provider.contents.userInfo"]) {
                    NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:modPath];
                    if (plist) {
                        plist[@"wallpaperRepresentingIdentifier"] = randomIDNum;
                        [plist writeToFile:modPath atomically:YES];
                    }
                } else if ([name isEqualToString:@"Wallpaper.plist"]) {
                    NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:modPath];
                    if (plist) {
                        plist[@"identifier"] = randomIDNum;
                        [plist writeToFile:modPath atomically:YES];
                    }
                }
            }

            // 移动到系统 PosterBoard 目录
            NSString *finalTarget = [destPath stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
            [fm moveItemAtPath:fullDescPath toPath:finalTarget error:nil];
        }
    }

    // 杀掉 PosterBoard，强制系统重新加载我们的原生壁纸
    system("killall -9 PosterBoard");
}

// 大厂级解压引擎
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
                    } @catch (NSException *e) {
                        processSuccess = NO;
                    }
                }
            }
            if (isAccessing) [sourceURL stopAccessingSecurityScopedResource];
            
            if (processSuccess) {
                [self setPermissionsRecursive:unzipDir];
                
                // 【核心分发逻辑】
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        NSString *successMsg;
                        if (@available(iOS 16.0, *)) {
                            // iOS 16+：原生注入系统
                            [self injectIntoPosterBoard:unzipDir];
                            successMsg = @"壁纸已原生注入 iOS 16/17 系统！请锁屏并长按，在海报库中向右滑动找到并应用它。";
                        } else {
                            // iOS 14-15：写入配置文件由 .x 挂载
                            CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
                            CFPreferencesSetAppValue(CFSTR("TendiesPath"), (__bridge CFStringRef)unzipDir, appID);
                            CFPreferencesAppSynchronize(appID);
                            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
                            successMsg = @"壁纸已挂载！请回到锁屏查看交互动画。";
                        }
                        
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功 🚀" message:successMsg preferredStyle:UIAlertControllerStyleAlert];
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
