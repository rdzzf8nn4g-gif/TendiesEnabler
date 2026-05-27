#import "TendiesPrefsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// 获取安全的存储路径
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
            // 允许选择任意文件/文件夹 (系统会将 .tendies 识别为 public.item 或 public.folder)
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.item"], [UTType typeWithIdentifier:@"public.folder"]]];
            picker.delegate = self;
            picker.allowsMultipleSelection = NO;
            
            UIViewController *topVC = self.view.window.rootViewController;
            if (!topVC) topVC = self;
            while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
            
            [topVC presentViewController:picker animated:YES completion:nil];
        }
    });
}

// 文件选择完成的回调
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;

    // 显示加载动画
    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在导入...\n\n" message:nil preferredStyle:UIAlertControllerStyleAlert];
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
            
            // 准备目标目录
            NSString *targetDir = GetTendiesStorageDir();
            if (![fm fileExistsAtPath:targetDir]) {
                [fm createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} error:nil];
            }
            
            NSString *targetPath = [targetDir stringByAppendingPathComponent:@"Active.tendies"];
            NSURL *targetURL = [NSURL fileURLWithPath:targetPath];
            
            // 移除旧壁纸
            [fm removeItemAtURL:targetURL error:nil];
            
            // 拷贝新壁纸
            NSError *copyError = nil;
            BOOL success = [fm copyItemAtURL:sourceURL toURL:targetURL error:&copyError];
            
            if (isAccessing) {
                [sourceURL stopAccessingSecurityScopedResource];
            }
            
            if (success) {
                // 赋予越狱环境下的最高读写权限，防止 SpringBoard 无法读取沙盒文件
                [fm setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:targetPath error:nil];
                
                // 写入偏好设置
                CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
                CFPreferencesSetAppValue(CFSTR("TendiesPath"), (__bridge CFStringRef)targetPath, appID);
                CFPreferencesAppSynchronize(appID);
                
                // 通知 SpringBoard 重载
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功" message:@"壁纸已成功挂载！请锁屏查看效果。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入失败" message:copyError.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }];
                });
            }
        });
    }];
}

// 在 Filza 打开功能
- (void)openFilzaPath:(PSSpecifier *)spec {
    NSString *targetDir = GetTendiesStorageDir();
    NSString *filzaURLString = [NSString stringWithFormat:@"filza://%@", targetDir];
    NSURL *filzaURL = [NSURL URLWithString:[filzaURLString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    
    if ([[UIApplication sharedApplication] canOpenURL:filzaURL]) {
        [[UIApplication sharedApplication] openURL:filzaURL options:@{} completionHandler:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"未检测到 Filza 文件管理器，请先安装 Filza。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

// 保存开关配置时触发重载
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if ([specifier.identifier isEqualToString:@"Enabled"]) {
        CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
        CFPreferencesAppSynchronize(appID);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
    }
}

@end
