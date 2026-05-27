#import "TendiesPrefsRootListController.h"
#import <Preferences/PSSpecifier.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

@implementation TendiesPrefsRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if ([specifier.identifier isEqualToString:@"Enabled"] || 
        [specifier.identifier isEqualToString:@"TendiesPath"]) {
        
        UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"保存中...\n\n" message:nil preferredStyle:UIAlertControllerStyleAlert];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        spinner.center = CGPointMake(135.0, 65.5);
        [spinner startAnimating];
        [loadingAlert.view addSubview:spinner];
        
        UIViewController *topVC = self.view.window.rootViewController;
        if (!topVC) topVC = self;
        while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
        
        [topVC presentViewController:loadingAlert animated:YES completion:^{
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [super setPreferenceValue:value specifier:specifier];
                });
                
                CFStringRef appID = CFSTR("com.yourname.tendiesprefs");
                CFPreferencesAppSynchronize(appID);
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.tendiesprefs/ReloadPrefs"), NULL, NULL, YES);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:nil];
                });
            });
        }];
    } else {
        [super setPreferenceValue:value specifier:specifier];
    }
}

// ========== 跳转 Filza 功能 ==========
- (void)openFilzaPath:(PSSpecifier *)spec {
    // 读取当前偏好设置的路径
    NSString *base = @"/var/mobile/Library/Preferences/com.yourname.tendiesprefs.plist";
    NSString *plistPath = base;
#if !__has_include(<roothide.h>)
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        plistPath = [@"/var/jb" stringByAppendingPathComponent:base];
    }
#else
    plistPath = jbroot(base);
#endif

    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *tendiesPath = dict[@"TendiesPath"] ?: @"/var/mobile/Documents/";
    
    NSString *filzaURLString = [NSString stringWithFormat:@"filza://%@", tendiesPath];
    NSURL *filzaURL = [NSURL URLWithString:[filzaURLString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    
    if ([[UIApplication sharedApplication] canOpenURL:filzaURL]) {
        [[UIApplication sharedApplication] openURL:filzaURL options:@{} completionHandler:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"未检测到 Filza 文件管理器，请先安装 Filza。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
