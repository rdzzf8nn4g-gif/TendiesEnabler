#import "TendiesPrefsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Foundation/Foundation.h>

// ==========================================
// 🍎 苹果底层核弹级解压框架 (Bom.framework) 接口声明
// ==========================================
// Bom (Bill Of Materials) 是苹果底层用于打包和解包的核心框架。
// App Store 安装 IPA 用的就是这个。速度极快，完全绕过 system() 调用的环境依赖。
OBJC_EXTERN void *BOMCopierNew(void);
OBJC_EXTERN void BOMCopierFree(void *copier);
OBJC_EXTERN int BOMCopierCopyWithOptions(void *copier, const char *src, const char *dest, void *options);

// ==========================================
// 终极环境适配 (Rootful/Rootless/Roothide)
// ==========================================
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

// ==========================================
// 唤起文件选择器 (修复 UTType 报错)
// ==========================================
- (void)importTendies:(PSSpecifier *)spec {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.0, *)) {
            // 修复：直接使用字符串类创建 UTType，避免某些 SDK 缺失 [UTType data] 方法
            UTType *itemType = [UTType typeWithIdentifier:@"public.item"];
            UTType *folderType = [UTType typeWithIdentifier:@"public.folder"];
            UTType *dataType = [UTType typeWithIdentifier:@"public.data"];
            
            NSArray *contentTypes = @[itemType, folderType, dataType];
            
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes];
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
// 【大厂级解压引擎】：底层原生解压，稳如老狗
// ==========================================
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;

    // 显示加载动画
    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在执行原生解压...\n\n" message:nil preferredStyle:UIAlertControllerStyleAlert];
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
            
            // 1. 准备目录
            NSString *targetDir = GetTendiesStorageDir();
            NSString *unzipDir = [targetDir stringByAppendingPathComponent:@"ActiveTendies"];
            
            if (![fm fileExistsAtPath:targetDir]) {
                [fm createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil];
            }
            
            // 每次导入前清空旧壁纸解压目录
            [fm removeItemAtPath:unzipDir error:nil];
            [fm createDirectoryAtPath:unzipDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil];
            
            // 2. 调用苹果底层 Bom 框架进行解压
            BOOL unzipSuccess = NO;
            NSString *sourcePath = sourceURL.path;
            
            if ([fm fileExistsAtPath:sourcePath]) {
                // 初始化底层 Copier
                void *copier = BOMCopierNew();
                if (copier) {
                    // 执行拷贝解压
                    int result = BOMCopierCopyWithOptions(copier, [sourcePath UTF8String], [unzipDir UTF8String], NULL);
                    if (result == 0) {
                        unzipSuccess = YES;
                        NSLog(@"[TendiesEnabler] BOMCopier 完美解压成功！");
                    } else {
                        NSLog(@"[TendiesEnabler] BOMCopier 解压失败，错误码: %d", result);
                    }
                    BOMCopierFree(copier);
                }
            }
            
            if (isAccessing) {
                [sourceURL stopAccessingSecurityScopedResource];
            }
            
            // 3. 处理结果
            if (unzipSuccess) {
                // 递归赋予最高权限，确保 SpringBoard (mobile权限) 有权读取
                [self setPermissionsRecursive:unzipDir];
                
                // 写入偏好设置 (直接写入解压后的文件夹路径)
                CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
                CFPreferencesSetAppValue(CFSTR("TendiesPath"), (__bridge CFStringRef)unzipDir, appID);
                CFPreferencesAppSynchronize(appID);
                
                // 通知 SpringBoard 重载
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入并解压成功" message:@"苹果底层引擎已将壁纸完美挂载！请锁屏查看交互动画。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"解压失败" message:@"原生底层引擎无法解析此文件。请确保它是标准的ZIP/Tendies压缩包。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }];
                });
            }
        });
    }];
}

// ==========================================
// 递归赋予 0777 权限
// ==========================================
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
// 在 Filza 打开
// ==========================================
- (void)openFilzaPath:(PSSpecifier *)spec {
    NSString *targetDir = GetTendiesStorageDir();
    NSString *filzaURLString = [NSString stringWithFormat:@"filza://%@", targetDir];
    NSURL *filzaURL = [NSURL URLWithString:[filzaURLString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    
    if ([[UIApplication sharedApplication] canOpenURL:filzaURL]) {
        [[UIApplication sharedApplication] openURL:filzaURL options:@{} completionHandler:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"请先安装 Filza 文件管理器。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

// ==========================================
// 保存开关配置时触发重载
// ==========================================
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if ([specifier.identifier isEqualToString:@"Enabled"]) {
        CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
        CFPreferencesAppSynchronize(appID);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
    }
}

@end
