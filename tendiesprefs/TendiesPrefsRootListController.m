#import "TendiesPrefsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// 声明 NSTask (规避私有 API 警告，用于调用 unzip 命令)
@interface NSTask : NSObject
@property (copy) NSString *launchPath;
@property (copy) NSArray *arguments;
- (void)launch;
- (void)waitUntilExit;
- (int)terminationStatus;
@end

// 终极环境适配
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

// 唤起文件选择器
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

// ==========================================
// 【大厂级解压引擎】：暴力解压，无视扩展名
// ==========================================
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;

    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在暴力解压...\n\n" message:nil preferredStyle:UIAlertControllerStyleAlert];
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
            
            // 清空旧壁纸
            [fm removeItemAtPath:unzipDir error:nil];
            [fm createDirectoryAtPath:unzipDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil];
            
            BOOL processSuccess = NO;
            BOOL isDirectory = NO;
            [fm fileExistsAtPath:sourceURL.path isDirectory:&isDirectory];
            
            if (isDirectory) {
                // 情况 1：系统已自动解压（识别为文件夹）
                NSArray *contents = [fm contentsOfDirectoryAtPath:sourceURL.path error:nil];
                processSuccess = YES;
                for (NSString *item in contents) {
                    NSString *srcPath = [sourceURL.path stringByAppendingPathComponent:item];
                    NSString *destPath = [unzipDir stringByAppendingPathComponent:item];
                    if (![fm copyItemAtPath:srcPath toPath:destPath error:nil]) {
                        processSuccess = NO;
                    }
                }
            } else {
                // 情况 2：这是一个压缩包，调用 /usr/bin/unzip 强制解压
                NSString *unzipBin = @"/usr/bin/unzip";
#if __has_include(<roothide.h>)
                unzipBin = jbroot(unzipBin);
#else
                if ([fm fileExistsAtPath:@"/var/jb/usr/bin/unzip"]) {
                    unzipBin = @"/var/jb/usr/bin/unzip";
                }
#endif
                Class NSTaskClass = NSClassFromString(@"NSTask");
                if (NSTaskClass && [fm fileExistsAtPath:unzipBin]) {
                    @try {
                        id task = [[NSTaskClass alloc] init];
                        [task setLaunchPath:unzipBin];
                        // -o 覆盖, -d 目标目录
                        [task setArguments:@[@"-o", sourceURL.path, @"-d", unzipDir]];
                        [task launch];
                        [task waitUntilExit];
                        processSuccess = ([task terminationStatus] == 0);
                    } @catch (NSException *e) {
                        processSuccess = NO;
                    }
                }
            }
            
            if (isAccessing) {
                [sourceURL stopAccessingSecurityScopedResource];
            }
            
            if (processSuccess) {
                // 赋予越狱最高权限，确保 SpringBoard 有权读取
                [self setPermissionsRecursive:unzipDir];
                
                CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
                CFPreferencesSetAppValue(CFSTR("TendiesPath"), (__bridge CFStringRef)unzipDir, appID);
                CFPreferencesAppSynchronize(appID);
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入并解压成功" message:@"壁纸已解压完毕并挂载！请锁屏查看交互动画。" preferredStyle:UIAlertControllerStyleAlert];
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
