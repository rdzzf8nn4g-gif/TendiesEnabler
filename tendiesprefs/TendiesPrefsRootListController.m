#import "TendiesPrefsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/stat.h>
#include <unistd.h> // 确保 chown 和 chmod 函数的系统内联声明完整

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

// ==========================================
// 1. 全越狱环境黄金路径适配 (Rootful/Rootless/Roothide)
// ==========================================
static NSString * GetTendiesStorageDir() {
    NSString *base = @"/var/mobile/Documents/TendiesEnabler";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

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

// 确保 PosterBoard 和 SpringBoard 有权限读取解压文件
- (void)forceOwnershipToMobile:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    NSString *subpath;
    
    chown(path.UTF8String, 501, 501);
    chmod(path.UTF8String, 0777);
    
    while ((subpath = [enumerator nextObject])) {
        NSString *fullPath = [path stringByAppendingPathComponent:subpath];
        chown(fullPath.UTF8String, 501, 501);
        chmod(fullPath.UTF8String, 0777);
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;

    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在无缝注入...\n\n" message:nil preferredStyle:UIAlertControllerStyleAlert];
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
                [fm createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            [fm removeItemAtPath:unzipDir error:nil];
            [fm createDirectoryAtPath:unzipDir withIntermediateDirectories:YES attributes:nil error:nil];
            
            BOOL processSuccess = NO;
            BOOL isDirectory = NO;
            [fm fileExistsAtPath:sourceURL.path isDirectory:&isDirectory];
            
            // 自动判断如果是解压好的目录则直接拷贝，如果是文件则用系统内置 unzip 释放
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
                [self forceOwnershipToMobile:unzipDir];
                
                // =====================================================================
                // 核心修复位置 1：壁纸导入成功时，使用 CFPreferences 将数据同步到全局中央管理区
                // 穿透 iOS 16/17 严格的跨进程沙盒隔离，确保 Tweak 能够顺利读到路径
                // =====================================================================
                CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
                CFPreferencesSetAppValue(CFSTR("Enabled"), kCFBooleanTrue, appID);
                CFPreferencesSetAppValue(CFSTR("TendiesPath"), (__bridge CFStringRef)unzipDir, appID);
                CFPreferencesAppSynchronize(appID);
                
                // 本地 Plist 备份兼具 PreferenceLoader 界面回显
                NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
                prefs[@"Enabled"] = @YES;
                prefs[@"TendiesPath"] = unzipDir;
                
                NSString *plistPath = GetPrefsPlistPath();
                [prefs writeToFile:plistPath atomically:YES];
                [self forceOwnershipToMobile:plistPath]; 
                
                // 发出 Darwin 通知，触发 Tweak.x 的内部重载逻辑
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"挂载成功 🚀" message:@"已调用系统原生 API 无缝刷新！直接回到锁屏即可享受原生动态效果。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"太棒了" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"解压失败" message:@"无效的壁纸文件，或设备缺少 unzip 解压环境。" preferredStyle:UIAlertControllerStyleAlert];
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

// =====================================================================
// 核心修复位置 2：用户在开关切换操作时，同样进行 CFPreferences 中央同步区同步
// =====================================================================
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    
    CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
    if ([specifier.identifier isEqualToString:@"Enabled"]) {
        
        // 同步写入系统的全局偏好中央管理区（穿透沙盒）
        CFPreferencesSetAppValue(CFSTR("Enabled"), (__bridge CFPropertyListRef)value, appID);
        CFPreferencesAppSynchronize(appID);
        
        // 本地备份写入
        NSString *plistPath = GetPrefsPlistPath();
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
        prefs[@"Enabled"] = value;
        [prefs writeToFile:plistPath atomically:YES];
        [self forceOwnershipToMobile:plistPath];
        
        // 广播偏好重载 Darwin 通知
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
    }
}

@end
