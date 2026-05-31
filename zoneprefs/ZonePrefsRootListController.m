#import "ZonePrefsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <PhotosUI/PhotosUI.h> // 【新增】相册导入支持
#import <AVFoundation/AVFoundation.h> // 【新增】视频处理支持
#include <sys/stat.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// --------------------------------------------------------
// 工业级解压引擎：直接调用底层 posix_spawn，防卡顿防泄漏
// --------------------------------------------------------
static BOOL industrialUnzip(NSString *source, NSString *destination) {
    pid_t pid;
    int status;
    NSString *unzipBin = @"/usr/bin/unzip";
#if __has_include(<roothide.h>)
    unzipBin = jbroot(unzipBin);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/unzip"]) {
        unzipBin = @"/var/jb/usr/bin/unzip";
    }
#endif

    const char *argv[] = {"unzip", "-o", "-q", [source UTF8String], "-d", [destination UTF8String], NULL};
    
    if (posix_spawn(&pid, [unzipBin UTF8String], NULL, NULL, (char *const *)argv, environ) == 0) {
        if (waitpid(pid, &status, 0) != -1) {
            return WIFEXITED(status) && (WEXITSTATUS(status) == 0 || WEXITSTATUS(status) == 1);
        }
    }
    return NO;
}

// ========================================================
// 内存守护系统：目录测算与底层 ImageIO 智能图像降维 (防漏/防热)
// ========================================================
static unsigned long long getDirectorySize(NSString *folderPath) {
    unsigned long long fileSize = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:folderPath];
    for (NSString *subpath in enumerator) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:[folderPath stringByAppendingPathComponent:subpath] error:nil];
        fileSize += [attrs fileSize];
    }
    return fileSize;
}

static unsigned long long downsampleImage(NSString *path, CGFloat scaleFactor) {
    NSURL *imageURL = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)imageURL, NULL);
    if (!source) return 0;

    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    if (!properties) { CFRelease(source); return 0; }

    NSNumber *widthNum = (__bridge NSNumber *)CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
    NSNumber *heightNum = (__bridge NSNumber *)CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
    CFRelease(properties);

    CGFloat width = [widthNum doubleValue];
    CGFloat height = [heightNum doubleValue];
    CGFloat maxDimension = MAX(width, height) * scaleFactor;

    if (maxDimension < 500) {
        CFRelease(source);
        return 0; 
    }

    NSDictionary *downsampleOptions = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxDimension)
    };

    CGImageRef downsampledImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)downsampleOptions);
    CFRelease(source);
    if (!downsampledImage) return 0;

    BOOL isPNG = [[path lowercaseString] hasSuffix:@".png"];
    CFStringRef uti = isPNG ? (__bridge CFStringRef)@"public.png" : (__bridge CFStringRef)@"public.jpeg";
    
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)imageURL, uti, 1, NULL);
    if (!destination) {
        CGImageRelease(downsampledImage);
        return 0;
    }

    if (isPNG) {
        CGImageDestinationAddImage(destination, downsampledImage, NULL);
    } else {
        NSDictionary *destOptions = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.85};
        CGImageDestinationAddImage(destination, downsampledImage, (__bridge CFDictionaryRef)destOptions);
    }

    BOOL success = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(downsampledImage);

    if (success) {
        return [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
    }
    return 0;
}

static void optimizeZoneFolderIfNecessary(NSString *unzipDir) {
    unsigned long long targetLimit = 25ULL * 1024 * 1024; 
    unsigned long long currentTotalSize = getDirectorySize(unzipDir);
    
    if (currentTotalSize <= targetLimit) return;
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    for (int pass = 1; pass <= 3; pass++) {
        if (currentTotalSize <= targetLimit) break;
        
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:unzipDir];
        NSString *subpath;
        NSMutableArray *imageFiles = [NSMutableArray array];
        
        while ((subpath = [enumerator nextObject])) {
            NSString *ext = [[subpath pathExtension] lowercaseString];
            if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
                NSString *fullPath = [unzipDir stringByAppendingPathComponent:subpath];
                unsigned long long fSize = [[fm attributesOfItemAtPath:fullPath error:nil] fileSize];
                [imageFiles addObject:@{@"path": fullPath, @"size": @(fSize)}];
            }
        }
        
        [imageFiles sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
            return [obj2[@"size"] compare:obj1[@"size"]];
        }];
        
        for (NSDictionary *imgInfo in imageFiles) {
            @autoreleasepool { 
                NSString *path = imgInfo[@"path"];
                unsigned long long oldSize = [imgInfo[@"size"] unsignedLongLongValue];
                
                CGFloat scale = 1.0 - (pass * 0.2);
                if (scale < 0.5) scale = 0.5;
                
                unsigned long long newSize = downsampleImage(path, scale);
                
                if (newSize > 0 && newSize < oldSize) {
                    currentTotalSize -= oldSize;
                    currentTotalSize += newSize;
                }
                
                if (currentTotalSize <= targetLimit) {
                    return;
                }
            }
        }
    }
}

// --------------------------------------------------------
// 路径管理与辅助工具
// --------------------------------------------------------
static NSString * GetZoneStorageDir() {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.zone.media";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static NSString * GetWallpapersDir() { return [GetZoneStorageDir() stringByAppendingPathComponent:@"Wallpapers"]; }
static NSString * GetVideoWallpapersDir() { return [GetZoneStorageDir() stringByAppendingPathComponent:@"Videos"]; } // 【新增】视频壁纸专属目录
static NSString * GetPrefsPlistPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.zoneprefs.plist";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

// 注销设备功能
static void respringDevice() {
    pid_t pid;
    const char* args[] = {"killall", "SpringBoard", NULL};
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char* const*)args, NULL);
}

// =======================================
// 主面板控制器 (合二为一，同页面根级别切换)
// =======================================
@interface ZonePrefsRootListController () <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, assign) NSInteger importTaskState; // 0: 交互壁纸ZIP, 1: 锁屏视频MP4, 2: 桌面视频MP4
@end

@implementation ZonePrefsRootListController

// 【核心】：获取当前的壁纸模式
- (NSInteger)getCurrentWallpaperMode {
    CFPropertyListRef modeRef = CFPreferencesCopyAppValue(CFSTR("WallpaperMode"), CFSTR("com.iosdump.zoneprefs"));
    NSInteger mode = 0;
    if (modeRef) {
        if (CFGetTypeID(modeRef) == CFNumberGetTypeID()) mode = [(__bridge NSNumber *)modeRef integerValue];
        CFRelease(modeRef);
    }
    return mode;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 初始化视频存储目录
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:GetVideoWallpapersDir()]) {
        [fm createDirectoryAtPath:GetVideoWallpapersDir() withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionNone} error:nil];
    }
    
    [self setupNavigationMenu];
    [self rebuildHeaderView];
}

// 每次进入页面时更新标题和菜单，保持完美同步
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setupNavigationMenu];
    [self rebuildHeaderView];
}

// 动态重构顶部 UI，让用户清晰感知当前模式
- (void)rebuildHeaderView {
    NSInteger currentMode = [self getCurrentWallpaperMode];
    
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 160)];
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    UIImage *icon = [UIImage imageNamed:@"icon" inBundle:bundle compatibleWithTraitCollection:nil];
    if (!icon) icon = [UIImage imageNamed:@"icon@3x" inBundle:bundle compatibleWithTraitCollection:nil];
    iconView.image = icon;
    iconView.layer.cornerRadius = 14;
    iconView.layer.masksToBounds = YES;
    [iconView.widthAnchor constraintEqualToConstant:60].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:60].active = YES;
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentLeft; 
    
    NSString *modeTitle = (currentMode == 0) ? @"Zone (交互)" : @"Zone (视频)";
    NSMutableAttributedString *coloredTitle = [[NSMutableAttributedString alloc] initWithString:modeTitle];
    // 渐变着色逻辑
    [coloredTitle addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.40 green:0.80 blue:1.00 alpha:1.0] range:NSMakeRange(0, 1)];
    [coloredTitle addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.70 green:0.40 blue:0.90 alpha:1.0] range:NSMakeRange(1, 1)];
    [coloredTitle addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.50 green:0.90 blue:0.60 alpha:1.0] range:NSMakeRange(2, 1)];
    [coloredTitle addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:1.00 green:0.60 blue:0.80 alpha:1.0] range:NSMakeRange(3, 1)];
    titleLabel.attributedText = coloredTitle;
    
    UIStackView *topHorizontalStack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, titleLabel]];
    topHorizontalStack.axis = UILayoutConstraintAxisHorizontal;
    topHorizontalStack.alignment = UIStackViewAlignmentCenter;
    topHorizontalStack.spacing = 15; 
    
    UITextView *creditsView = [[UITextView alloc] init];
    creditsView.text = @"插件作者: iosdump\n作者频道: https://t.me/iosdumpzzz\n图标设计: https://t.me/RrrankkK";
    creditsView.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    creditsView.textColor = [UIColor secondaryLabelColor];
    creditsView.textAlignment = NSTextAlignmentLeft; 
    creditsView.editable = NO;
    creditsView.scrollEnabled = NO;
    creditsView.backgroundColor = [UIColor clearColor];
    creditsView.dataDetectorTypes = UIDataDetectorTypeLink; 
    
    UIStackView *mainVerticalStack = [[UIStackView alloc] initWithArrangedSubviews:@[topHorizontalStack, creditsView]];
    mainVerticalStack.axis = UILayoutConstraintAxisVertical;
    mainVerticalStack.alignment = UIStackViewAlignmentCenter; 
    mainVerticalStack.spacing = 10; 
    mainVerticalStack.translatesAutoresizingMaskIntoConstraints = NO;
    
    [headerView addSubview:mainVerticalStack];
    
    [NSLayoutConstraint activateConstraints:@[
        [mainVerticalStack.centerXAnchor constraintEqualToAnchor:headerView.centerXAnchor],
        [mainVerticalStack.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor]
    ]];
    
    if ([self respondsToSelector:@selector(table)]) {
        UITableView *tableView = [self performSelector:@selector(table)];
        [tableView setTableHeaderView:headerView];
    }
}

// 导航栏右上角菜单动态构建
- (void)setupNavigationMenu {
    if (@available(iOS 14.0, *)) {
        NSInteger currentMode = [self getCurrentWallpaperMode];
        
        NSString *toggleTitle = (currentMode == 0) ? @"切换为视频模式" : @"切换为交互模式";
        UIImage *toggleIcon = (currentMode == 0) ? [UIImage systemImageNamed:@"video"] : [UIImage systemImageNamed:@"wand.and.stars"];
        
        UIAction *toggleAction = [UIAction actionWithTitle:toggleTitle image:toggleIcon identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
            NSInteger newMode = (currentMode == 0) ? 1 : 0;
            [self switchWallpaperMode:newMode];
        }];
        
        UIAction *respringAction = [UIAction actionWithTitle:@"注销设备" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
            respringDevice();
        }];
        respringAction.attributes = UIMenuElementAttributesDestructive;
        
        UIMenu *menu = [UIMenu menuWithTitle:@"" children:@[toggleAction, respringAction]];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:menu];
    } else {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"注销" style:UIBarButtonItemStylePlain target:self action:@selector(fallbackRespring)];
    }
}

- (void)fallbackRespring { respringDevice(); }

// 核心：无感平滑切换页面结构
- (void)switchWallpaperMode:(NSInteger)mode {
    CFStringRef appID = CFSTR("com.iosdump.zoneprefs");
    CFPreferencesSetAppValue(CFSTR("WallpaperMode"), (__bridge CFNumberRef)@(mode), appID);
    CFPreferencesAppSynchronize(appID);
    
    NSString *plistPath = GetPrefsPlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    prefs[@"WallpaperMode"] = @(mode);
    [prefs writeToFile:plistPath atomically:YES];
    
    [self setupNavigationMenu];
    [self rebuildHeaderView];
    
    // 清除缓存的 specifiers 强行迫使列表重新加载全新的结构
    _specifiers = nil;
    [self reloadSpecifiers];
    
    // 广播重绘，通知底层引擎进行模式隔离
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
}

// ========================================================
// 动态表单生成：根据模式彻底隔离开关与逻辑
// ========================================================
- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSInteger currentMode = [self getCurrentWallpaperMode];
        
        if (currentMode == 0) {
            // ==================================
            // 【模式 0】：加载原有的交互壁纸设置
            // ==================================
            NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
            
            PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"已导入的壁纸" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
            [group setProperty:@"点击切换壁纸，向左滑动可删除不需要的壁纸以及重命名。\n点击对应壁纸旁边的按钮可设置每帧重绘降采样的程度(原画/70%/50%/25%)，以节约电量以及降低占用。" forKey:@"footerText"];
            [specs addObject:group];
            
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *wpDir = GetWallpapersDir();
            if ([fm fileExistsAtPath:wpDir]) {
                NSArray *contents = [fm contentsOfDirectoryAtPath:wpDir error:nil];
                contents = [contents sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
                
                NSString *currentPath = nil;
                CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("ZonePath"), CFSTR("com.iosdump.zoneprefs"));
                if (pathRef && CFGetTypeID(pathRef) == CFStringGetTypeID()) {
                    currentPath = (__bridge NSString *)pathRef;
                    CFRelease(pathRef);
                }

                for (NSString *name in contents) {
                    if ([name hasPrefix:@"."]) continue; 
                    BOOL isDir;
                    if ([fm fileExistsAtPath:[wpDir stringByAppendingPathComponent:name] isDirectory:&isDir] && isDir) {
                        NSString *fullWpPath = [wpDir stringByAppendingPathComponent:name];
                        NSString *displayName = name;
                        
                        if ([currentPath isEqualToString:fullWpPath]) {
                            displayName = [NSString stringWithFormat:@"%@  ✓", name];
                        }
                        
                        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:displayName target:self set:nil get:@selector(getWallpaperSize:) detail:nil cell:PSTitleValueCell edit:nil];
                        spec->action = @selector(selectWallpaper:);
                        [spec setProperty:name forKey:@"WallpaperName"];
                        [spec setProperty:@YES forKey:@"IsWallpaperCell"]; 
                        [specs addObject:spec];
                    }
                }
            }
            _specifiers = specs;
            
        } else {
            // ==================================
            // 【模式 1】：加载全新的独立视频壁纸设置
            // ==================================
            NSMutableArray *specs = [NSMutableArray array];
            
            PSSpecifier *group1 = [PSSpecifier preferenceSpecifierNamed:@"全局控制 (视频模式)" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
            [group1 setProperty:@"您已进入视频壁纸模式，底层交互壁纸引擎已彻底休眠。这极大节省了资源并防止冲突。" forKey:@"footerText"];
            [specs addObject:group1];
            
            // 按照要求：视频模式只保留通用的“启用插件”按钮
            PSSpecifier *enableSpec = [PSSpecifier preferenceSpecifierNamed:@"启用插件" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
            [enableSpec setProperty:@"Enabled" forKey:@"key"];
            [enableSpec setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
            [specs addObject:enableSpec];
            
            // --- 锁屏区域 ---
            PSSpecifier *group2 = [PSSpecifier preferenceSpecifierNamed:@"锁屏视频设置" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
            [specs addObject:group2];
            
            PSSpecifier *lsAlbumSpec = [PSSpecifier preferenceSpecifierNamed:@"从相册导入" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
            lsAlbumSpec->action = @selector(importLSSFromAlbum:);
            [specs addObject:lsAlbumSpec];
            
            PSSpecifier *lsFileSpec = [PSSpecifier preferenceSpecifierNamed:@"从文件导入" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
            lsFileSpec->action = @selector(importLSSFromFile:);
            [specs addObject:lsFileSpec];

            PSSpecifier *lsCurrent = [PSSpecifier preferenceSpecifierNamed:@"当前使用" target:self set:nil get:@selector(getCurrentVideoName:) detail:nil cell:PSTitleValueCell edit:nil];
            [lsCurrent setProperty:@"LSVideoPath" forKey:@"VideoKey"];
            [specs addObject:lsCurrent];

            // --- 桌面区域 ---
            PSSpecifier *group3 = [PSSpecifier preferenceSpecifierNamed:@"桌面视频设置" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
            [specs addObject:group3];
            
            PSSpecifier *hsAlbumSpec = [PSSpecifier preferenceSpecifierNamed:@"从相册导入" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
            hsAlbumSpec->action = @selector(importHSSFromAlbum:);
            [specs addObject:hsAlbumSpec];
            
            PSSpecifier *hsFileSpec = [PSSpecifier preferenceSpecifierNamed:@"从文件导入" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
            hsFileSpec->action = @selector(importHSSFromFile:);
            [specs addObject:hsFileSpec];
            
            PSSpecifier *hsCurrent = [PSSpecifier preferenceSpecifierNamed:@"当前使用" target:self set:nil get:@selector(getCurrentVideoName:) detail:nil cell:PSTitleValueCell edit:nil];
            [hsCurrent setProperty:@"HSVideoPath" forKey:@"VideoKey"];
            [specs addObject:hsCurrent];
            
            // --- 高级区域 ---
            PSSpecifier *group4 = [PSSpecifier preferenceSpecifierNamed:@"高级" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
            [specs addObject:group4];

            PSSpecifier *openDirSpec = [PSSpecifier preferenceSpecifierNamed:@"打开视频存储目录" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
            openDirSpec->action = @selector(openVideoFilzaPath:);
            [specs addObject:openDirSpec];

            _specifiers = specs;
        }
    }
    return _specifiers;
}

// 视频模式：获取当前配置的视频文件名
- (id)getCurrentVideoName:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"VideoKey"];
    CFPropertyListRef pathRef = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.iosdump.zoneprefs"));
    if (pathRef) {
        NSString *path = (__bridge NSString *)pathRef;
        CFRelease(pathRef);
        return [path lastPathComponent] ?: @"未设置";
    }
    return @"未设置";
}

// ========================================================
// 交互壁纸逻辑保留
// ========================================================
- (void)showEnhancedEngineInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"开启增强复杂交互壁纸识别以及适配壁纸暗黑模式适配等。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showHideTextShadowInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"关闭文字阴影。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (id)getWallpaperSize:(PSSpecifier *)spec { return @""; }

- (void)cycleResolution:(UIButton *)sender {
    NSString *name = sender.accessibilityIdentifier;
    if (!name) return;
    
    NSString *key = [NSString stringWithFormat:@"ResFactor_%@", name];
    CFPropertyListRef resRef = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.iosdump.zoneprefs"));
    double currentFactor = 1.0;
    if (resRef) {
        if (CFGetTypeID(resRef) == CFNumberGetTypeID()) currentFactor = [(__bridge NSNumber *)resRef doubleValue];
        CFRelease(resRef);
    }
    
    double nextFactor = 1.0;
    if (currentFactor >= 0.99) nextFactor = 0.70;
    else if (currentFactor >= 0.69) nextFactor = 0.50;
    else if (currentFactor >= 0.49) nextFactor = 0.25;
    else nextFactor = 1.0;
    
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFNumberRef)@(nextFactor), CFSTR("com.iosdump.zoneprefs"));
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
    
    NSString *plistPath = GetPrefsPlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    prefs[key] = @(nextFactor);
    [prefs writeToFile:plistPath atomically:YES];
    [self forceOwnershipToMobile:plistPath];
    
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    
    if (nextFactor >= 0.99) [sender setTitle:@"原画" forState:UIControlStateNormal];
    else [sender setTitle:[NSString stringWithFormat:@"%.0f%%", nextFactor * 100] forState:UIControlStateNormal];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [(id)cell specifier];
    NSString *specKey = [spec propertyForKey:@"key"];
    
    if ([specKey isEqualToString:@"EnhancedEngine"]) {
        UIButton *existingBtn = [cell.contentView viewWithTag:881];
        if (!existingBtn) {
            UIButton *infoBtn = [UIButton buttonWithType:UIButtonTypeInfoLight];
            infoBtn.tag = 881;
            infoBtn.frame = CGRectMake(100, (cell.bounds.size.height - 22) / 2.0, 22, 22);
            infoBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;
            [infoBtn addTarget:self action:@selector(showEnhancedEngineInfo) forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:infoBtn];
        }
    }
    
    if ([specKey isEqualToString:@"HideTextShadow"]) {
        UIButton *existingBtn = [cell.contentView viewWithTag:882];
        if (!existingBtn) {
            UIButton *infoBtn = [UIButton buttonWithType:UIButtonTypeInfoLight];
            infoBtn.tag = 882;
            infoBtn.frame = CGRectMake(100, (cell.bounds.size.height - 22) / 2.0, 22, 22);
            infoBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;
            [infoBtn addTarget:self action:@selector(showHideTextShadowInfo) forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:infoBtn];
        }
    }
    
    if ([[spec propertyForKey:@"IsWallpaperCell"] boolValue]) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        NSString *name = [spec propertyForKey:@"WallpaperName"];
        
        UIView *accView = cell.accessoryView;
        UIButton *resBtn = nil;
        UILabel *sizeLabel = nil;
        
        if (!accView || accView.frame.size.width != 115) {
            accView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 115, 30)];
            sizeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 65, 30)];
            sizeLabel.font = [UIFont systemFontOfSize:14];
            sizeLabel.textColor = [UIColor secondaryLabelColor];
            sizeLabel.textAlignment = NSTextAlignmentRight;
            sizeLabel.tag = 888;
            [accView addSubview:sizeLabel];
            
            resBtn = [UIButton buttonWithType:UIButtonTypeCustom];
            resBtn.frame = CGRectMake(72, 1, 40, 28);
            resBtn.layer.cornerRadius = 14;
            resBtn.layer.borderWidth = 1;
            resBtn.layer.borderColor = [UIColor systemBlueColor].CGColor;
            resBtn.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
            [resBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
            [resBtn addTarget:self action:@selector(cycleResolution:) forControlEvents:UIControlEventTouchUpInside];
            resBtn.tag = 777;
            [accView addSubview:resBtn];
            
            cell.accessoryView = accView;
        } else {
            sizeLabel = [accView viewWithTag:888];
            resBtn = [accView viewWithTag:777];
        }
        
        NSString *fullWpPath = [GetWallpapersDir() stringByAppendingPathComponent:name];
        double sizeMB = getDirectorySize(fullWpPath) / (1024.0 * 1024.0);
        sizeLabel.text = [NSString stringWithFormat:@"%.1f MB", sizeMB];
        
        resBtn.accessibilityIdentifier = name;
        NSString *key = [NSString stringWithFormat:@"ResFactor_%@", name];
        CFPropertyListRef resRef = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.iosdump.zoneprefs"));
        double factor = 1.0;
        if (resRef) {
            if (CFGetTypeID(resRef) == CFNumberGetTypeID()) factor = [(__bridge NSNumber *)resRef doubleValue];
            CFRelease(resRef);
        }
        
        if (factor >= 0.99) [resBtn setTitle:@"原画" forState:UIControlStateNormal];
        else [resBtn setTitle:[NSString stringWithFormat:@"%.0f%%", factor * 100] forState:UIControlStateNormal];
        
        cell.detailTextLabel.hidden = YES;
        cell.detailTextLabel.text = @"";
    }
    
    return cell;
}

- (UITableViewStyle)tableViewStyle {
    if (@available(iOS 13.0, *)) { return UITableViewStyleInsetGrouped; }
    return UITableViewStyleGrouped;
}

// ========================================================
// 交互与视频模式分离的导入功能 (彻底修复导入失效 Bug)
// ========================================================
- (void)importZone:(PSSpecifier *)spec {
    self.importTaskState = 0; // 交互壁纸 ZIP 导入
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.0, *)) {
            UTType *itemType = [UTType typeWithIdentifier:@"public.item"];
            UTType *folderType = [UTType typeWithIdentifier:@"public.folder"];
            UTType *dataType = [UTType typeWithIdentifier:@"public.data"];
            
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[itemType, folderType, dataType]];
            picker.delegate = self;
            picker.allowsMultipleSelection = YES; 
            
            UIViewController *topVC = self.view.window.rootViewController;
            if (!topVC) topVC = self;
            while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
            [topVC presentViewController:picker animated:YES completion:nil];
        }
    });
}

// 视频：相册触发
- (void)importLSSFromAlbum:(PSSpecifier *)spec { self.importTaskState = 1; [self openVideoAlbumPicker]; }
- (void)importHSSFromAlbum:(PSSpecifier *)spec { self.importTaskState = 2; [self openVideoAlbumPicker]; }

// 视频：文件触发
- (void)importLSSFromFile:(PSSpecifier *)spec { self.importTaskState = 1; [self openVideoFilePicker]; }
- (void)importHSSFromFile:(PSSpecifier *)spec { self.importTaskState = 2; [self openVideoFilePicker]; }

- (void)openVideoAlbumPicker {
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = [PHPickerFilter videosFilter];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }
}

- (void)openVideoFilePicker {
    if (@available(iOS 14.0, *)) {
        UTType *videoType = [UTType typeWithIdentifier:@"public.movie"];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[videoType]];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }
}

// 【彻底修复】：相册视频回调，同步立刻执行底层拷贝防止文件句柄消失
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14)){
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    
    NSItemProvider *provider = results.firstObject.itemProvider;
    if ([provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
            if (url) {
                [self syncCopyImportedVideoFromURL:url];
            }
        }];
    }
}

// 文件选取的回调 (聚合处理 ZIP交互 和 MP4视频)
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    if (self.importTaskState == 0) {
        // --- 交互壁纸 ZIP 处理逻辑 ---
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            unsigned long long totalSizeBytes = 0;
            NSFileManager *fm = [NSFileManager defaultManager];
            for (NSURL *url in urls) {
                BOOL isAccessing = [url startAccessingSecurityScopedResource];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:url.path isDirectory:&isDir]) {
                    if (isDir) { totalSizeBytes += getDirectorySize(url.path); } 
                    else { totalSizeBytes += [[fm attributesOfItemAtPath:url.path error:nil] fileSize]; }
                }
                if (isAccessing) [url stopAccessingSecurityScopedResource];
            }

            double totalMB = totalSizeBytes / (1024.0 * 1024.0);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (totalMB > 40.0) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"检测到大文件" 
                                                                                   message:[NSString stringWithFormat:@"检测导入的壁纸文件大于40MB (约 %.1f MB)。\n\n继续导入可能会导致设备卡顿。\n是否继续？", totalMB] 
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                    [alert addAction:[UIAlertAction actionWithTitle:@"继续导入" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                        [self proceedWithImportingURLs:urls];
                    }]];
                    
                    UIViewController *topVC = self.view.window.rootViewController;
                    if (!topVC) topVC = self;
                    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
                    [topVC presentViewController:alert animated:YES completion:nil];
                } else {
                    [self proceedWithImportingURLs:urls];
                }
            });
        });
    } else {
        // --- 视频壁纸 MP4 处理逻辑 ---
        NSURL *videoURL = urls.firstObject;
        BOOL isAccessing = [videoURL startAccessingSecurityScopedResource];
        [self syncCopyImportedVideoFromURL:videoURL];
        if (isAccessing) [videoURL stopAccessingSecurityScopedResource];
    }
}

// 【修复核心】：同步安全拷贝视频，避开多线程销毁陷阱
- (void)syncCopyImportedVideoFromURL:(NSURL *)url {
    NSString *fileName = [NSString stringWithFormat:@"%@_%ld.mp4", (self.importTaskState == 1 ? @"LS" : @"HS"), (long)[[NSDate date] timeIntervalSince1970]];
    NSString *destPath = [GetVideoWallpapersDir() stringByAppendingPathComponent:fileName];
    
    NSError *error = nil;
    if ([[NSFileManager defaultManager] copyItemAtPath:url.path toPath:destPath error:&error]) {
        chown(destPath.UTF8String, 501, 501);
        chmod(destPath.UTF8String, 0777);
        
        NSString *prefKey = self.importTaskState == 1 ? @"LSVideoPath" : @"HSVideoPath";
        CFStringRef appID = CFSTR("com.iosdump.zoneprefs");
        CFPreferencesSetAppValue((__bridge CFStringRef)prefKey, (__bridge CFStringRef)destPath, appID);
        CFPreferencesAppSynchronize(appID);
        
        NSString *plistPath = GetPrefsPlistPath();
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
        prefs[prefKey] = destPath;
        [prefs writeToFile:plistPath atomically:YES];
        chown(plistPath.UTF8String, 501, 501);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            _specifiers = nil;
            [self reloadSpecifiers];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
            
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功" message:@"视频壁纸已应用并实时生效。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            
            UIViewController *topVC = self.view.window.rootViewController;
            if (!topVC) topVC = self;
            while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
            [topVC presentViewController:alert animated:YES completion:nil];
        });
    }
}

// ========================================================
// 交互壁纸原有的导入/删除逻辑完美保留
// ========================================================
- (void)proceedWithImportingURLs:(NSArray<NSURL *> *)urls {
    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在导入...      " message:nil preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.center = CGPointMake(205.0, 31.0);
    [spinner startAnimating];
    [loadingAlert.view addSubview:spinner];
    
    UIViewController *topVC = self.view.window.rootViewController;
    if (!topVC) topVC = self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    
    [topVC presentViewController:loadingAlert animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *wpDir = GetWallpapersDir();
            
            if (![fm fileExistsAtPath:wpDir]) {
                [fm createDirectoryAtPath:wpDir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionNone} error:nil];
            }
            
            BOOL anySuccess = NO;
            for (NSURL *sourceURL in urls) {
                BOOL isAccessing = [sourceURL startAccessingSecurityScopedResource];
                NSString *fileName = [[sourceURL lastPathComponent] stringByDeletingPathExtension];
                NSString *unzipDir = [wpDir stringByAppendingPathComponent:fileName];
                
                [fm removeItemAtPath:unzipDir error:nil];
                [fm createDirectoryAtPath:unzipDir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionNone} error:nil];
                
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
                    processSuccess = industrialUnzip(sourceURL.path, unzipDir);
                }
                
                if (processSuccess) {
                    optimizeZoneFolderIfNecessary(unzipDir);
                    anySuccess = YES;
                }
                
                if (isAccessing) [sourceURL stopAccessingSecurityScopedResource];
            }
            
            if (anySuccess) {
                [self forceOwnershipToMobile:wpDir];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        _specifiers = nil;
                        [self reloadSpecifiers]; 
                    }];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入失败" message:@"无效的壁纸文件或已损坏。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }];
                });
            }
        });
    }];
}

- (void)selectWallpaper:(PSSpecifier *)spec {
    NSString *name = [spec propertyForKey:@"WallpaperName"];
    if (!name) return;
    
    NSString *fullPath = [GetWallpapersDir() stringByAppendingPathComponent:name];
    
    CFStringRef appID = CFSTR("com.iosdump.zoneprefs");
    CFPreferencesSetAppValue(CFSTR("ZonePath"), (__bridge CFStringRef)fullPath, appID);
    CFPreferencesAppSynchronize(appID);
    
    NSString *plistPath = GetPrefsPlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    prefs[@"ZonePath"] = fullPath;
    [prefs writeToFile:plistPath atomically:YES];
    [self forceOwnershipToMobile:plistPath];
    
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    
    _specifiers = nil;
    [self reloadSpecifiers]; 
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (@available(iOS 11.0, *)) {
        PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
        if (![[spec propertyForKey:@"IsWallpaperCell"] boolValue]) return nil;

        NSString *name = [spec propertyForKey:@"WallpaperName"];

        UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
            [self deleteWallpaperWithSpecifier:spec];
            completionHandler(YES);
        }];

        UIContextualAction *renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"重命名" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
            [self renameWallpaper:name specifier:spec];
            completionHandler(YES);
        }];
        renameAction.backgroundColor = [UIColor systemOrangeColor];

        UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, renameAction]];
        config.performsFirstActionWithFullSwipe = NO; 
        return config;
    }
    return nil;
}

- (void)deleteWallpaperWithSpecifier:(PSSpecifier *)spec {
    NSString *name = [spec propertyForKey:@"WallpaperName"];
    if (name) {
        NSString *path = [GetWallpapersDir() stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        
        CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("ZonePath"), CFSTR("com.iosdump.zoneprefs"));
        if (pathRef) {
            NSString *currentPath = (__bridge NSString *)pathRef;
            if ([currentPath isEqualToString:path]) {
                CFPreferencesSetAppValue(CFSTR("ZonePath"), NULL, CFSTR("com.iosdump.zoneprefs"));
                CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
            }
            CFRelease(pathRef);
        }
        
        NSString *resKey = [NSString stringWithFormat:@"ResFactor_%@", name];
        CFPreferencesSetAppValue((__bridge CFStringRef)resKey, NULL, CFSTR("com.iosdump.zoneprefs"));
        
        [self removeSpecifier:spec animated:YES];
    }
}

- (void)renameWallpaper:(NSString *)oldName specifier:(PSSpecifier *)spec {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名" message:@"请输入新的壁纸名称" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) { textField.text = oldName; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newName = alert.textFields.firstObject.text;
        if (newName.length > 0 && ![newName isEqualToString:oldName]) {
            NSString *oldPath = [GetWallpapersDir() stringByAppendingPathComponent:oldName];
            NSString *newPath = [GetWallpapersDir() stringByAppendingPathComponent:newName];
            
            NSError *err = nil;
            [[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&err];
            if (!err) {
                NSString *oldResKey = [NSString stringWithFormat:@"ResFactor_%@", oldName];
                NSString *newResKey = [NSString stringWithFormat:@"ResFactor_%@", newName];
                CFPropertyListRef resRef = CFPreferencesCopyAppValue((__bridge CFStringRef)oldResKey, CFSTR("com.iosdump.zoneprefs"));
                if (resRef) {
                    CFPreferencesSetAppValue((__bridge CFStringRef)newResKey, resRef, CFSTR("com.iosdump.zoneprefs"));
                    CFPreferencesSetAppValue((__bridge CFStringRef)oldResKey, NULL, CFSTR("com.iosdump.zoneprefs"));
                    CFRelease(resRef);
                }
                
                CFPropertyListRef pathRef = CFPreferencesCopyAppValue(CFSTR("ZonePath"), CFSTR("com.iosdump.zoneprefs"));
                if (pathRef) {
                    NSString *currentPath = (__bridge NSString *)pathRef;
                    if ([currentPath isEqualToString:oldPath]) {
                        CFPreferencesSetAppValue(CFSTR("ZonePath"), (__bridge CFStringRef)newPath, CFSTR("com.iosdump.zoneprefs"));
                        CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
                        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
                    }
                    CFRelease(pathRef);
                }
                _specifiers = nil;
                [self reloadSpecifiers];
            }
        }
    }]];
    UIViewController *topVC = self.view.window.rootViewController;
    if (!topVC) topVC = self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    [topVC presentViewController:alert animated:YES completion:nil];
}

// 视频模式专属高级目录打开
- (void)openVideoFilzaPath:(PSSpecifier *)spec {
    [self doOpenFilzaPath:GetVideoWallpapersDir()];
}
// 原交互模式目录打开
- (void)openFilzaPath:(PSSpecifier *)spec {
    [self doOpenFilzaPath:GetZoneStorageDir()];
}

- (void)doOpenFilzaPath:(NSString *)targetDir {
    NSString *filzaURLString = [NSString stringWithFormat:@"filza://%@", targetDir];
    NSURL *filzaURL = [NSURL URLWithString:[filzaURLString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    if ([[UIApplication sharedApplication] canOpenURL:filzaURL]) {
        [[UIApplication sharedApplication] openURL:filzaURL options:@{} completionHandler:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"设备未安装 Filza。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

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

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    CFStringRef appID = CFSTR("com.iosdump.zoneprefs");
    if ([specifier.identifier isEqualToString:@"Enabled"]) {
        CFPreferencesSetAppValue(CFSTR("Enabled"), (__bridge CFPropertyListRef)value, appID);
        CFPreferencesAppSynchronize(appID);
        
        NSString *plistPath = GetPrefsPlistPath();
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
        prefs[@"Enabled"] = value;
        [prefs writeToFile:plistPath atomically:YES];
        [self forceOwnershipToMobile:plistPath];
        
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    }
}
@end
