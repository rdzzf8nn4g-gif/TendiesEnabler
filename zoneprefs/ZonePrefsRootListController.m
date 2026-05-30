#import "ZonePrefsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
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

    // 使用底层参数传递，-o: 覆盖, -q: 静默提速
    const char *argv[] = {"unzip", "-o", "-q", [source UTF8String], "-d", [destination UTF8String], NULL};
    
    // posix_spawn 是 iOS 底层最高效的进程拉起方式，完美规避 NSTask 的所有缺陷
    if (posix_spawn(&pid, [unzipBin UTF8String], NULL, NULL, (char *const *)argv, environ) == 0) {
        if (waitpid(pid, &status, 0) != -1) {
            // 返回 0 是成功，返回 1 通常是警告（比如内部有 macosx 缓存也会报 1，同样视为成功）
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

// 采用 ImageIO 硬件流降维，新增 jpegQuality 参数动态控制画质
static unsigned long long downsampleImage(NSString *path, CGFloat scaleFactor, CGFloat jpegQuality) {
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
    
    // 获取原文件大小，用于后续比对
    unsigned long long originalSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];

    // 计算缩放后的最大边长，并封顶 1500 像素 (防止 4K/8K 毒瘤素材)
    CGFloat maxDimension = MAX(width, height) * scaleFactor;
    maxDimension = MIN(maxDimension, 1500.0);

    // 防御性策略：如果是小于 500 像素的小图，且体积不到 1MB，放过它保清晰度
    if (maxDimension < 500.0 && originalSize < 1 * 1024 * 1024) {
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
    CFRelease(source); // 必须立即释放读取源，解除文件占用锁
    if (!downsampledImage) return 0;

    BOOL isPNG = [[path lowercaseString] hasSuffix:@"png"];
    CFStringRef uti = isPNG ? (__bridge CFStringRef)@"public.png" : (__bridge CFStringRef)@"public.jpeg";
    
    // 【核心修复】：绝对不原地覆写，使用 .tmp 临时文件，规避系统底层读写锁导致的静默失败
    NSString *tempPath = [path stringByAppendingPathExtension:@"tmp"];
    NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
    
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)tempURL, uti, 1, NULL);
    if (!destination) {
        CGImageRelease(downsampledImage);
        return 0;
    }

    if (isPNG) {
        // PNG 依旧无损保留 Alpha 通道 (透明度)
        CGImageDestinationAddImage(destination, downsampledImage, NULL);
    } else {
        // JPG 应用动态画质压缩
        NSDictionary *destOptions = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(jpegQuality)};
        CGImageDestinationAddImage(destination, downsampledImage, (__bridge CFDictionaryRef)destOptions);
    }

    BOOL success = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(downsampledImage);

    NSFileManager *fm = [NSFileManager defaultManager];
    if (success && [fm fileExistsAtPath:tempPath]) {
        unsigned long long tempSize = [[fm attributesOfItemAtPath:tempPath error:nil] fileSize];
        
        // 【关键防御】：只有当压缩后的临时文件真的比原文件小，才进行替换！
        if (tempSize < originalSize) {
            [fm removeItemAtPath:path error:nil]; // 销毁原图
            [fm moveItemAtPath:tempPath toPath:path error:nil]; // 临时图转正
            return tempSize;
        } else {
            // 如果压完反而变大了（遇到了被高度压缩过的JPG），扔掉临时文件，不改动原图
            [fm removeItemAtPath:tempPath error:nil];
            return 0;
        }
    }
    return 0;
}

static void optimizeZoneFolderIfNecessary(NSString *unzipDir) {
    unsigned long long targetLimit = 25ULL * 1024 * 1024; // 25MB 红线
    unsigned long long currentTotalSize = getDirectorySize(unzipDir);
    
    if (currentTotalSize <= targetLimit) return; // 容量合格，直接放行
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 最多 3 趟循环，从轻微压缩到极限求生
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
        
        // 按文件大小降序排列，擒贼先擒王
        [imageFiles sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
            return [obj2[@"size"] compare:obj1[@"size"]];
        }];
        
        for (NSDictionary *imgInfo in imageFiles) {
            @autoreleasepool { // 绝对隔离：保证单张图片处理完立即释放图形上下文防漏
                NSString *path = imgInfo[@"path"];
                unsigned long long oldSize = [imgInfo[@"size"] unsignedLongLongValue];
                
                CGFloat scale = 1.0;
                CGFloat quality = 0.8;
                
                // 【动态打击策略】
                // 面对几百张图组成的 150MB，随着趟数增加，手段越来越狠
                if (pass == 1) { 
                    scale = 0.6; quality = 0.6;   // 第 1 趟：中度压缩
                } else if (pass == 2) { 
                    scale = 0.4; quality = 0.4;   // 第 2 趟：重度压缩
                } else if (pass == 3) { 
                    scale = 0.25; quality = 0.25; // 第 3 趟：不顾一切把体积压下来保命
                }
                
                unsigned long long newSize = downsampleImage(path, scale, quality);
                
                // 如果成功缩减了体积，更新总容量进度
                if (newSize > 0 && newSize < oldSize) {
                    currentTotalSize -= oldSize;
                    currentTotalSize += newSize;
                }
                
                // 只要总体积跌破 25MB，立刻停止，不再牺牲剩下的图片画质
                if (currentTotalSize <= targetLimit) {
                    return;
                }
            }
        }
    }
}

// --------------------------------------------------------
// 路径管理
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

static NSString * GetWallpapersDir() {
    return [GetZoneStorageDir() stringByAppendingPathComponent:@"Wallpapers"];
}

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


@implementation ZonePrefsRootListController

// =======================================
// 强制使用 iOS 13+ 的 InsetGrouped 样式，自动实现原生圆角分区和标准小标题
// =======================================
- (UITableViewStyle)tableViewStyle {
    if (@available(iOS 13.0, *)) {
        return UITableViewStyleInsetGrouped;
    }
    return UITableViewStyleGrouped;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // =======================================
    // 极致完美的排版布局 (图左名右居中，文字左对齐块居中，缩小下巴留白)
    // =======================================
    // 将高度从220缩小到160，从而让下面的 Cell 整体上移
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 160)];
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    // 1. 图标
    UIImageView *iconView = [[UIImageView alloc] init];
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    UIImage *icon = [UIImage imageNamed:@"icon" inBundle:bundle compatibleWithTraitCollection:nil];
    if (!icon) icon = [UIImage imageNamed:@"icon@3x" inBundle:bundle compatibleWithTraitCollection:nil];
    iconView.image = icon;
    iconView.layer.cornerRadius = 14;
    iconView.layer.masksToBounds = YES;
    [iconView.widthAnchor constraintEqualToConstant:60].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:60].active = YES;
    
    // 2. 标题 (彩色涂鸦效果)
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentLeft; // 配合横向Stack改为左对齐
    
    NSMutableAttributedString *coloredTitle = [[NSMutableAttributedString alloc] initWithString:@"Zone"];
    // 浅蓝
    [coloredTitle addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.40 green:0.80 blue:1.00 alpha:1.0] range:NSMakeRange(0, 1)];
    // 紫色
    [coloredTitle addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.70 green:0.40 blue:0.90 alpha:1.0] range:NSMakeRange(1, 1)];
    // 浅绿
    [coloredTitle addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.50 green:0.90 blue:0.60 alpha:1.0] range:NSMakeRange(2, 1)];
    // 浅粉
    [coloredTitle addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:1.00 green:0.60 blue:0.80 alpha:1.0] range:NSMakeRange(3, 1)];
    titleLabel.attributedText = coloredTitle;
    
    // 2.5 将图标和标题打包成一个水平的 StackView（图左、字右）
    UIStackView *topHorizontalStack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, titleLabel]];
    topHorizontalStack.axis = UILayoutConstraintAxisHorizontal;
    topHorizontalStack.alignment = UIStackViewAlignmentCenter;
    topHorizontalStack.spacing = 15; // 图标和文字的左右间距
    
    // 3. 作者信息及频道 (使用 UITextView 实现多行，内部左对齐，外部Stack保证整体居中)
    UITextView *creditsView = [[UITextView alloc] init];
    creditsView.text = @"插件作者: iosdump\n作者频道: https://t.me/iosdumpzzz\n图标设计: https://t.me/RrrankkK";
    creditsView.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    creditsView.textColor = [UIColor secondaryLabelColor];
    creditsView.textAlignment = NSTextAlignmentLeft; // 内部文字开头对齐（左对齐）
    creditsView.editable = NO;
    creditsView.scrollEnabled = NO;
    creditsView.backgroundColor = [UIColor clearColor];
    creditsView.dataDetectorTypes = UIDataDetectorTypeLink; // 开启自动识别超链接
    
    // 4. 打包进最终的主垂直弹性容器 (整体依然完美居中)
    UIStackView *mainVerticalStack = [[UIStackView alloc] initWithArrangedSubviews:@[topHorizontalStack, creditsView]];
    mainVerticalStack.axis = UILayoutConstraintAxisVertical;
    mainVerticalStack.alignment = UIStackViewAlignmentCenter; // 确保横向块和文字块作为一个整体居中
    mainVerticalStack.spacing = 10; // 上下区域的间距
    mainVerticalStack.translatesAutoresizingMaskIntoConstraints = NO;
    
    [headerView addSubview:mainVerticalStack];
    
    // 设置弹性容器在头部居中
    [NSLayoutConstraint activateConstraints:@[
        [mainVerticalStack.centerXAnchor constraintEqualToAnchor:headerView.centerXAnchor],
        [mainVerticalStack.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor]
    ]];
    
    if ([self respondsToSelector:@selector(table)]) {
        UITableView *tableView = [self performSelector:@selector(table)];
        [tableView setTableHeaderView:headerView];
    }
}

// 动态追加列表
- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
        
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"已导入的壁纸" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"点击切换壁纸，实时生效。向左滑动可删除不再需要的壁纸。" forKey:@"footerText"];
        [specs addObject:group];
        
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *wpDir = GetWallpapersDir();
        if ([fm fileExistsAtPath:wpDir]) {
            NSArray *contents = [fm contentsOfDirectoryAtPath:wpDir error:nil];
            
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
                    
                    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
                    spec->action = @selector(selectWallpaper:);
                    [spec setProperty:name forKey:@"WallpaperName"];
                    [spec setProperty:@YES forKey:@"IsWallpaperCell"]; 
                    
                    NSString *fullWpPath = [wpDir stringByAppendingPathComponent:name];
                    if ([currentPath isEqualToString:fullWpPath]) {
                        spec.name = [NSString stringWithFormat:@"%@  ✓", name];
                    }
                    
                    [specs addObject:spec];
                }
            }
        }
        _specifiers = specs;
    }
    return _specifiers;
}

- (void)importZone:(PSSpecifier *)spec {
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
    if (urls.count == 0) return;

    // 添加几个空格留出右侧空间给菊花
    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在导入...      " message:nil preferredStyle:UIAlertControllerStyleAlert];
    // 改为 Medium 大小，使其与单行文字更加协调匹配
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    // X=205.0靠右，Y=31.0正好与系统 UIAlertController 的单行标题处于同一高度
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
                    // 调用强大的底层 C 语言原生解压引擎
                    processSuccess = industrialUnzip(sourceURL.path, unzipDir);
                }
                
                // ====== 注入策略 ======
                // 只有在复制或解压成功后，才对目录进行体积清洗
                if (processSuccess) {
                    optimizeZoneFolderIfNecessary(unzipDir);
                    anySuccess = YES;
                }
                
                if (isAccessing) [sourceURL stopAccessingSecurityScopedResource];
                // ====================
            }
            
            if (anySuccess) {
                [self forceOwnershipToMobile:wpDir];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
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
    
    [self reloadSpecifiers];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([[spec propertyForKey:@"IsWallpaperCell"] boolValue]) return YES;
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
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
            [self removeSpecifier:spec animated:YES];
        }
    }
}

- (void)openFilzaPath:(PSSpecifier *)spec {
    NSString *targetDir = GetZoneStorageDir();
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
