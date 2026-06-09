#import "ZonePrefsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <MobileCoreServices/MobileCoreServices.h> 
#import <ImageIO/ImageIO.h>
#include <sys/stat.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <zlib.h> 

extern char **environ;

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ========================================================
// 引擎 1：纯血 C 语言在轨解压引擎 (沙盒穿透 + 内存激增免疫版)
// ========================================================
static BOOL microIndustrialUnzip(NSString *source, NSString *destination) {
    FILE *fp = fopen([source UTF8String], "rb");
    if (!fp) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil];

    unsigned char sig[4];
    BOOL extractedAny = NO;

    while (fread(sig, 1, 4, fp) == 4) {
        if (sig[0] != 0x50 || sig[1] != 0x4B) {
            fseek(fp, -3, SEEK_CUR); 
            continue;
        }
        if (sig[2] == 0x01 && sig[3] == 0x02) break;
        if (sig[2] != 0x03 || sig[3] != 0x04) continue; 

        unsigned char header[26];
        if (fread(header, 1, 26, fp) != 26) { fclose(fp); return NO; }

        uint16_t flags = header[2] | (header[3] << 8);
        uint16_t method = header[4] | (header[5] << 8);
        uint32_t compSize = header[14] | (header[15] << 8) | (header[16] << 16) | (header[17] << 24);
        uint16_t nameLen = header[22] | (header[23] << 8);
        uint16_t extraLen = header[24] | (header[25] << 8);

        if ((flags & 0x01) || compSize == 0xFFFFFFFF) {
            fclose(fp); return NO; 
        }

        char name[nameLen + 1];
        if (fread(name, 1, nameLen, fp) != nameLen) { fclose(fp); return NO; }
        name[nameLen] = '\0';

        if (extraLen > 0) fseek(fp, extraLen, SEEK_CUR);

        // ==========================================
        // 【核心优化】：开启自动释放池，防止海量小文件导致字符串内存堆积
        // ==========================================
        @autoreleasepool {
            NSString *fileName = [NSString stringWithUTF8String:name];
            if (!fileName) fileName = @"unknown_file";
            
            BOOL isMacTrash = [fileName containsString:@"__MACOSX"] || [fileName hasSuffix:@".DS_Store"] || [fileName containsString:@"../"];
            NSString *outPath = [destination stringByAppendingPathComponent:fileName];

            if ([fileName hasSuffix:@"/"]) {
                if (!isMacTrash) {
                    [fm createDirectoryAtPath:outPath withIntermediateDirectories:YES attributes:nil error:nil];
                }
            } else {
                if (!isMacTrash) {
                    [fm createDirectoryAtPath:[outPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                }

                FILE *outFp = isMacTrash ? NULL : fopen([outPath UTF8String], "wb");
                
                if (method == 0) {
                    char buf[32768];
                    uint32_t left = compSize;
                    while (left > 0) {
                        size_t toRead = left < sizeof(buf) ? left : sizeof(buf);
                        size_t r = fread(buf, 1, toRead, fp);
                        if (r == 0) break;
                        if (outFp) fwrite(buf, 1, r, outFp);
                        left -= r;
                    }
                    if (outFp) { fclose(outFp); extractedAny = YES; }
                } else if (method == 8) {
                    z_stream strm;
                    strm.zalloc = Z_NULL;
                    strm.zfree = Z_NULL;
                    strm.opaque = Z_NULL;
                    strm.avail_in = 0;
                    strm.next_in = Z_NULL;

                    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) {
                        if (outFp) fclose(outFp);
                        fclose(fp); return NO;
                    }

                    unsigned char inBuf[32768];
                    unsigned char outBuf[32768];
                    int ret = Z_OK;
                    BOOL done = NO;
                    BOOL hasDataDescriptor = (flags & 0x08) != 0;
                    uint32_t left = compSize;

                    do {
                        size_t toRead = hasDataDescriptor ? sizeof(inBuf) : (left < sizeof(inBuf) ? left : sizeof(inBuf));
                        if (toRead == 0 && !hasDataDescriptor) break;
                        
                        size_t r = fread(inBuf, 1, toRead, fp);
                        if (r == 0) break;
                        
                        strm.avail_in = (uInt)r;
                        strm.next_in = inBuf;
                        if (!hasDataDescriptor) left -= r;

                        do {
                            strm.avail_out = sizeof(outBuf);
                            strm.next_out = outBuf;
                            ret = inflate(&strm, Z_NO_FLUSH);
                            
                            if (ret == Z_STREAM_ERROR || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) {
                                inflateEnd(&strm);
                                if (outFp) fclose(outFp);
                                fclose(fp); return NO;
                            }
                            
                            unsigned have = sizeof(outBuf) - strm.avail_out;
                            if (have > 0 && outFp) {
                                fwrite(outBuf, 1, have, outFp);
                            }
                            
                            if (ret == Z_STREAM_END) {
                                done = YES;
                                break;
                            }
                        } while (strm.avail_out == 0);
                        
                    } while (!done && (hasDataDescriptor || left > 0));

                    if (done && strm.avail_in > 0) {
                        fseek(fp, -(long)strm.avail_in, SEEK_CUR);
                    }

                    inflateEnd(&strm);
                    if (outFp) { fclose(outFp); extractedAny = YES; }
                } else {
                    if (outFp) fclose(outFp);
                    fclose(fp); return NO;
                }
            }
        } // 结束 @autoreleasepool，临时字符串在此被安全粉碎
    }
    fclose(fp);
    return extractedAny;
}

// ========================================================
// 引擎 2：高容错兜底解压引擎 (终极放水版)
// ========================================================
static BOOL industrialUnzip(NSString *source, NSString *destination) {
    pid_t pid;
    int status;
    
    // 1. 智能寻找 unzip 工具：优先越狱版，系统原生版兜底（防止越狱环境没装 unzip 导致直接罢工）
    NSString *unzipBin = @"/usr/bin/unzip"; 
#if __has_include(<roothide.h>)
    if ([[NSFileManager defaultManager] fileExistsAtPath:jbroot(@"/usr/bin/unzip")]) {
        unzipBin = jbroot(@"/usr/bin/unzip");
    }
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/unzip"]) {
        unzipBin = @"/var/jb/usr/bin/unzip";
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/local/bin/unzip"]) {
        unzipBin = @"/usr/local/bin/unzip";
    }
#endif

    // 2. 注入免疫参数：-o(强制覆盖) -q(静默) -x(强行排除 Mac 系统垃圾文件，防止引发解压中断)
    const char *argv[] = {
        "unzip", 
        "-o", 
        "-q", 
        [source UTF8String], 
        "-d", 
        [destination UTF8String], 
        "-x", 
        "__MACOSX/*", 
        "*/.DS_Store", 
        NULL
    };
    
    if (posix_spawn(&pid, [unzipBin UTF8String], NULL, NULL, (char *const *)argv, environ) == 0) {
        if (waitpid(pid, &status, 0) != -1) {
            if (WIFEXITED(status)) {
                int exitCode = WEXITSTATUS(status);
                // 3. 【核心放水区域】：大幅提高对不规范 ZIP 的容忍度
                // 0 = 完美解压
                // 1 = 有轻微警告但成功
                // 2 = ZIP 格式存在通用错误（比如被第三方工具暴力篡改过头文件），但实际上数据已经释出
                // 3 = 严重结构错误，但在很多情况下核心媒体文件依然能被强行抽出来
                return (exitCode <= 3); 
            }
        }
    }
    return NO;
}

// ========================================================
// 内存守护系统：目录测算与底层 ImageIO 智能图像降维 
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
// 路径管理与权限守护
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

static NSString * GetVideoWallpapersLockDir() {
    return [GetZoneStorageDir() stringByAppendingPathComponent:@"VideoWallpapers/Lock"];
}

static NSString * GetVideoWallpapersHomeDir() {
    return [GetZoneStorageDir() stringByAppendingPathComponent:@"VideoWallpapers/Home"];
}

static void EnsureVideoDirectoriesExist() {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *baseVideoDir = [GetZoneStorageDir() stringByAppendingPathComponent:@"VideoWallpapers"];
    NSString *lockDir = GetVideoWallpapersLockDir();
    NSString *homeDir = GetVideoWallpapersHomeDir();
    
    if (![fm fileExistsAtPath:lockDir]) {
        [fm createDirectoryAtPath:lockDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSArray *contents = [fm contentsOfDirectoryAtPath:baseVideoDir error:nil];
        for (NSString *item in contents) {
            if ([item isEqualToString:@"Lock"] || [item isEqualToString:@"Home"]) continue;
            NSString *oldPath = [baseVideoDir stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:oldPath isDirectory:&isDir] && !isDir) {
                [fm moveItemAtPath:oldPath toPath:[lockDir stringByAppendingPathComponent:item] error:nil];
            }
        }
    }
    if (![fm fileExistsAtPath:homeDir]) {
        [fm createDirectoryAtPath:homeDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
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

@interface ZonePrefsRootListController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, assign) BOOL isVideoMode;
@property (nonatomic, assign) NSInteger currentVideoTarget;

// === 新增：用于图片替换的上下文变量 ===
@property (nonatomic, assign) BOOL isPickingForReplacement;
@property (nonatomic, copy) NSString *replacingWallpaperName;
@property (nonatomic, copy) NSString *replacingImagePath;
@end

@implementation ZonePrefsRootListController

// =======================================
// UI 生命周期与右上角核弹菜单注入
// =======================================
- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *plistPath = GetPrefsPlistPath();
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        _isVideoMode = [prefs[@"VideoModeEnabled"] boolValue];
        EnsureVideoDirectoriesExist();
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self updateRightMenu];
    [self setupHeaderView];
}

- (void)setupHeaderView {
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 160)];
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    
    NSString *targetIconName = self.isVideoMode ? @"icon1" : @"icon";
    
    UIImage *icon = [UIImage imageNamed:targetIconName inBundle:bundle compatibleWithTraitCollection:nil];
    if (!icon) {
        icon = [UIImage imageNamed:[NSString stringWithFormat:@"%@@3x", targetIconName] inBundle:bundle compatibleWithTraitCollection:nil];
    }
    
    iconView.image = icon;
    iconView.layer.cornerRadius = 14;
    iconView.layer.masksToBounds = YES;
    [iconView.widthAnchor constraintEqualToConstant:60].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:60].active = YES;
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentLeft; 
    
    NSMutableAttributedString *coloredTitle = [[NSMutableAttributedString alloc] initWithString:@"Zone"];
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
    creditsView.editable = NO;
    creditsView.scrollEnabled = NO;
    creditsView.backgroundColor = [UIColor clearColor];
    creditsView.textAlignment = NSTextAlignmentCenter; 
    
    creditsView.linkTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor systemBlueColor]
    };

    NSString *baseText = @"插件作者: iosdump\n作者频道: @iosdumpzzz\n图标设计: @RrrankkK\n越狱源地址: iosdumpzzz.github.io";
    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] initWithString:baseText];
    
    NSRange fullRange = NSMakeRange(0, baseText.length);
    [attrStr addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium] range:fullRange];
    [attrStr addAttribute:NSForegroundColorAttributeName value:[UIColor secondaryLabelColor] range:fullRange];
    
    [attrStr addAttribute:NSLinkAttributeName value:@"https://t.me/iosdumpzzz" range:[baseText rangeOfString:@"@iosdumpzzz"]];
    [attrStr addAttribute:NSLinkAttributeName value:@"https://t.me/RrrankkK" range:[baseText rangeOfString:@"@RrrankkK"]];
    [attrStr addAttribute:NSLinkAttributeName value:@"https://iosdumpzzz.github.io/iosdump.repo/" range:[baseText rangeOfString:@"iosdumpzzz.github.io"]];
    
    creditsView.attributedText = attrStr;
    
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

- (void)updateRightMenu {
    if (@available(iOS 14.0, *)) {
        NSString *switchTitle = self.isVideoMode ? @"切换为交互模式" : @"切换为视频模式";
        UIAction *switchAction = [UIAction actionWithTitle:switchTitle 
                                                    image:[UIImage systemImageNamed:@"arrow.left.arrow.right"] 
                                               identifier:nil 
                                                  handler:^(__kindof UIAction * _Nonnull action) {
            [self executeSmoothModeTransition];
        }];
        
        UIAction *respringAction = [UIAction actionWithTitle:@"注销 (Respring)" 
                                                       image:[UIImage systemImageNamed:@"arrow.clockwise"] 
                                                  identifier:nil 
                                                     handler:^(__kindof UIAction * _Nonnull action) {
            [self respringDevice];
        }];
        respringAction.attributes = UIMenuElementAttributesDestructive;
        
        NSMutableArray *menuItems = [NSMutableArray arrayWithObject:switchAction];
        
        if (!self.isVideoMode) {
            UIAction *clearAction = [UIAction actionWithTitle:@"清空壁纸" 
                                                        image:[UIImage systemImageNamed:@"trash"] 
                                                   identifier:nil 
                                                      handler:^(__kindof UIAction * _Nonnull action) {
                [self promptClearWallpapers];
            }];
            clearAction.attributes = UIMenuElementAttributesDestructive;
            [menuItems addObject:clearAction];
        }
        
        [menuItems addObject:respringAction];
        
        UIMenu *menu = [UIMenu menuWithTitle:@"" children:menuItems];
        UIBarButtonItem *menuBtn = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:menu];
        self.navigationItem.rightBarButtonItem = menuBtn;
    } else {
        UIBarButtonItem *menuBtn = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showZoneMenuFallback)];
        self.navigationItem.rightBarButtonItem = menuBtn;
    }
}

- (void)showZoneMenuFallback {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Zone 引擎控制台" message:@"选择你需要操作的模式与功能" preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *switchTitle = self.isVideoMode ? @"切换为交互模式" : @"切换为视频模式";
    [menu addAction:[UIAlertAction actionWithTitle:switchTitle style:UIAlertActionStyleDefault handler:^(id action) {
        [self executeSmoothModeTransition];
    }]];
    
    if (!self.isVideoMode) {
        [menu addAction:[UIAlertAction actionWithTitle:@"清空壁纸" style:UIAlertActionStyleDestructive handler:^(id action) {
            [self promptClearWallpapers];
        }]];
    }
    
    [menu addAction:[UIAlertAction actionWithTitle:@"注销 (Respring)" style:UIAlertActionStyleDestructive handler:^(id action) {
        [self respringDevice];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (menu.popoverPresentationController) {
        menu.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)executeSmoothModeTransition {
    self.isVideoMode = !self.isVideoMode;
    
    NSString *plistPath = GetPrefsPlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    prefs[@"VideoModeEnabled"] = @(self.isVideoMode);
    [prefs writeToFile:plistPath atomically:YES];
    [self forceOwnershipToMobile:plistPath];
    
    CFPreferencesSetAppValue(CFSTR("VideoModeEnabled"), (__bridge CFNumberRef)@(self.isVideoMode), CFSTR("com.iosdump.zoneprefs"));
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
    
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    
    [self updateRightMenu];
    [self setupHeaderView]; 
    
    if ([self respondsToSelector:@selector(table)]) {
        UITableView *tableView = [self performSelector:@selector(table)];
        CATransition *transition = [CATransition animation];
        transition.type = kCATransitionPush;
        transition.subtype = self.isVideoMode ? kCATransitionFromRight : kCATransitionFromLeft; 
        transition.duration = 0.35;
        transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [tableView.layer addAnimation:transition forKey:@"switchModeAnimation"];
    }
    
    [self reloadSpecifiers];
}

- (void)respringDevice {
    pid_t pid;
    
    NSString *killallPath = @"/usr/bin/killall";
#if __has_include(<roothide.h>)
    killallPath = jbroot(killallPath);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/killall"]) {
        killallPath = @"/var/jb/usr/bin/killall";
    }
#endif

    const char *args[] = {"killall", "-9", "backboardd", NULL};
    if (posix_spawn(&pid, [killallPath UTF8String], NULL, NULL, (char *const *)args, environ) != 0) {
        
        NSString *sbreloadPath = @"/usr/bin/sbreload";
#if __has_include(<roothide.h>)
        sbreloadPath = jbroot(sbreloadPath);
#else
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/sbreload"]) {
            sbreloadPath = @"/var/jb/usr/bin/sbreload";
        }
#endif
        const char *args2[] = {"sbreload", NULL};
        posix_spawn(&pid, [sbreloadPath UTF8String], NULL, NULL, (char *const *)args2, environ);
    }
}

- (void)setAnimEnableValue:(id)value specifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];
    [self reloadSpecifiers]; 
}

- (void)setReplaceImageEnableValue:(id)value specifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];
    [self reloadSpecifiers]; 
}

- (void)cycleAnimSpeed:(UIButton *)sender {
    if (@available(iOS 16.0, *)) {
    } else {
        return;
    }
    NSString *name = sender.accessibilityIdentifier;
    if (!name) return;
    
    NSString *key = [NSString stringWithFormat:@"AnimSpeed_%@", name];
    CFPropertyListRef prefRef = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.iosdump.zoneprefs"));
    NSInteger currentSpeed = 0;
    if (prefRef) {
        if (CFGetTypeID(prefRef) == CFNumberGetTypeID()) currentSpeed = [(__bridge NSNumber *)prefRef integerValue];
        CFRelease(prefRef);
    }
    
    NSInteger nextSpeed = currentSpeed + 1;
    if (nextSpeed > 3) nextSpeed = 0; 
    
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFNumberRef)@(nextSpeed), CFSTR("com.iosdump.zoneprefs"));
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
    
    NSString *plistPath = GetPrefsPlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    prefs[key] = @(nextSpeed);
    [prefs writeToFile:plistPath atomically:YES];
    [self forceOwnershipToMobile:plistPath];
    
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    
    if (nextSpeed == 1) [sender setTitle:@"较快" forState:UIControlStateNormal];
    else if (nextSpeed == 2) [sender setTitle:@"极快" forState:UIControlStateNormal];
    else if (nextSpeed == 3) [sender setTitle:@"光速" forState:UIControlStateNormal];
    else [sender setTitle:@"默认" forState:UIControlStateNormal];
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [NSMutableArray new];
    } else {
        [_specifiers removeAllObjects];
    }
    
    if (self.isVideoMode) {
        PSSpecifier *g1 = [PSSpecifier emptyGroupSpecifier];
        [g1 setProperty:@"开启启用插件开关应用全局，视频模式下交互壁纸将自动休眠并彻底释放内存。\n开启锁屏桌面使用同素材时需在锁屏/壁纸素材内重新选择一个。" forKey:@"footerText"];
        [_specifiers addObject:g1];
        
        PSSpecifier *enableSpec = [PSSpecifier preferenceSpecifierNamed:@"启用插件" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
        [enableSpec setProperty:@"Enabled" forKey:@"key"];
        [enableSpec setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
        [enableSpec setProperty:@NO forKey:@"default"];
        enableSpec->action = @selector(setPreferenceValue:specifier:);
        [_specifiers addObject:enableSpec];

        PSSpecifier *doubleTapLockSpecVideo = [PSSpecifier preferenceSpecifierNamed:@"双击锁屏" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
        [doubleTapLockSpecVideo setProperty:@"DoubleTapLock" forKey:@"key"];
        [doubleTapLockSpecVideo setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
        [doubleTapLockSpecVideo setProperty:@NO forKey:@"default"];
        doubleTapLockSpecVideo->action = @selector(setPreferenceValue:specifier:);
        [_specifiers addObject:doubleTapLockSpecVideo];
        
        PSSpecifier *lowPowerSpec = [PSSpecifier preferenceSpecifierNamed:@"低电模式暂停" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
        [lowPowerSpec setProperty:@"LowPowerPause" forKey:@"key"];
        [lowPowerSpec setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
        lowPowerSpec->action = @selector(setPreferenceValue:specifier:);
        [_specifiers addObject:lowPowerSpec];
        
        PSSpecifier *sameMatSpec = [PSSpecifier preferenceSpecifierNamed:@"锁屏桌面使用同素材" target:self set:@selector(setSameMaterialValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
        [sameMatSpec setProperty:@"SameVideoMaterial" forKey:@"key"];
        [sameMatSpec setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
        sameMatSpec->action = @selector(setSameMaterialValue:specifier:); 
        [_specifiers addObject:sameMatSpec];
        
        NSFileManager *fm = [NSFileManager defaultManager];
        
        NSString *lockDir = GetVideoWallpapersLockDir();
        NSArray *lockContents = [fm fileExistsAtPath:lockDir] ? [fm contentsOfDirectoryAtPath:lockDir error:nil] : @[];
        lockContents = [lockContents sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        
        PSSpecifier *gLock = [PSSpecifier preferenceSpecifierNamed:@"锁屏壁纸" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [gLock setProperty:@"点击应用为锁屏壁纸，向左滑动可删除或重命名。" forKey:@"footerText"];
        [_specifiers addObject:gLock];
        
        PSSpecifier *btnLockImport = [PSSpecifier preferenceSpecifierNamed:@"导入锁屏素材" target:self set:nil get:@selector(getLockVideoStatus:) detail:nil cell:PSTitleValueCell edit:nil];
        btnLockImport->action = @selector(importLockMaterial);
        [_specifiers addObject:btnLockImport];
        
        for (NSString *name in lockContents) {
            if ([name hasPrefix:@"."]) continue;
            NSString *displayName = [name stringByDeletingPathExtension];
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:displayName target:self set:nil get:@selector(getDummyValue:) detail:nil cell:PSTitleValueCell edit:nil];
            spec->action = @selector(selectVideoWallpaper:);
            [spec setProperty:name forKey:@"VideoName"];
            [spec setProperty:@1 forKey:@"VideoTarget"]; 
            [spec setProperty:@YES forKey:@"IsVideoCell"]; 
            [_specifiers addObject:spec];
        }
        
        NSString *homeDir = GetVideoWallpapersHomeDir();
        NSArray *homeContents = [fm fileExistsAtPath:homeDir] ? [fm contentsOfDirectoryAtPath:homeDir error:nil] : @[];
        homeContents = [homeContents sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        
        PSSpecifier *gHome = [PSSpecifier preferenceSpecifierNamed:@"桌面壁纸" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [gHome setProperty:@"点击应用为桌面壁纸，向左滑动可删除或重命名。" forKey:@"footerText"];
        [_specifiers addObject:gHome];
        
        PSSpecifier *btnHomeImport = [PSSpecifier preferenceSpecifierNamed:@"导入桌面素材" target:self set:nil get:@selector(getHomeVideoStatus:) detail:nil cell:PSTitleValueCell edit:nil];
        btnHomeImport->action = @selector(importHomeMaterial);
        [_specifiers addObject:btnHomeImport];
        
        for (NSString *name in homeContents) {
            if ([name hasPrefix:@"."]) continue;
            NSString *displayName = [name stringByDeletingPathExtension];
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:displayName target:self set:nil get:@selector(getDummyValue:) detail:nil cell:PSTitleValueCell edit:nil];
            spec->action = @selector(selectVideoWallpaper:);
            [spec setProperty:name forKey:@"VideoName"];
            [spec setProperty:@2 forKey:@"VideoTarget"]; 
            [spec setProperty:@YES forKey:@"IsVideoCell"]; 
            [_specifiers addObject:spec];
        }
        
        PSSpecifier *gFilza = [PSSpecifier emptyGroupSpecifier];
        [_specifiers addObject:gFilza];
        
        PSSpecifier *btnFilza = [PSSpecifier preferenceSpecifierNamed:@"跳转 Filza 查看" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        btnFilza->action = @selector(openFilzaPath:);
        [_specifiers addObject:btnFilza];
        
    } else {
        NSArray *rootSpecs = [self loadSpecifiersFromPlistName:@"Root" target:self];
        
        NSUInteger baseInsertIndex = NSNotFound;
        for (NSUInteger i = 0; i < rootSpecs.count; i++) {
            PSSpecifier *spec = rootSpecs[i];
            if ([[spec propertyForKey:@"key"] isEqualToString:@"HideTextShadow"]) {
                baseInsertIndex = i + 1; 
                break;
            }
        }

        if (baseInsertIndex != NSNotFound) {
            NSMutableArray *mutRoot = [rootSpecs mutableCopy];

            PSSpecifier *doubleTapSpec = [PSSpecifier preferenceSpecifierNamed:@"双击锁屏" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
            [doubleTapSpec setProperty:@"DoubleTapLock" forKey:@"key"];
            [doubleTapSpec setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
            [doubleTapSpec setProperty:@NO forKey:@"default"];
            doubleTapSpec->action = @selector(setPreferenceValue:specifier:);
            [mutRoot insertObject:doubleTapSpec atIndex:baseInsertIndex];

            PSSpecifier *replaceImageSpec = [PSSpecifier preferenceSpecifierNamed:@"替换图片" target:self set:@selector(setReplaceImageEnableValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
            [replaceImageSpec setProperty:@"EnableReplaceImage" forKey:@"key"];
            [replaceImageSpec setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
            [replaceImageSpec setProperty:@NO forKey:@"default"];
            replaceImageSpec->action = @selector(setReplaceImageEnableValue:specifier:);
            [mutRoot insertObject:replaceImageSpec atIndex:baseInsertIndex + 1];

            if (@available(iOS 16.0, *)) {
                PSSpecifier *animSpec = [PSSpecifier preferenceSpecifierNamed:@"动画速度" target:self set:@selector(setAnimEnableValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
                [animSpec setProperty:@"EnableAnimSpeed" forKey:@"key"];
                [animSpec setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
                [animSpec setProperty:@YES forKey:@"default"];
                animSpec->action = @selector(setAnimEnableValue:specifier:);
                [mutRoot insertObject:animSpec atIndex:baseInsertIndex + 2]; 
            }

            rootSpecs = mutRoot;
        }

        [_specifiers addObjectsFromArray:rootSpecs];
        
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"已导入的壁纸(如果遇到设置壁纸不正常右上角注销尝试)" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"点击切换壁纸，向左滑动可删除不需要的壁纸以及重命名。\n点击对应壁纸旁边的按钮可设置每帧重绘降采样的程度(原画/70%/50%/25%)，以节约电量以及降低占用。" forKey:@"footerText"];
        [_specifiers addObject:group];
        
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *wpDir = GetWallpapersDir();
        if ([fm fileExistsAtPath:wpDir]) {
            NSArray *contents = [fm contentsOfDirectoryAtPath:wpDir error:nil];
            contents = [contents sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
            
            for (NSString *name in contents) {
                if ([name hasPrefix:@"."]) continue; 
                BOOL isDir;
                if ([fm fileExistsAtPath:[wpDir stringByAppendingPathComponent:name] isDirectory:&isDir] && isDir) {
                    
                    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil get:@selector(getWallpaperSize:) detail:nil cell:PSTitleValueCell edit:nil];
                    spec->action = @selector(selectWallpaper:);
                    [spec setProperty:name forKey:@"WallpaperName"];
                    [spec setProperty:@YES forKey:@"IsWallpaperCell"]; 
                    
                    [_specifiers addObject:spec];
                }
            }
        }
    }
    
    return _specifiers;
}

- (id)getLockVideoStatus:(PSSpecifier *)spec {
    NSString *plistPath = GetPrefsPlistPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *path = prefs[@"LockVideoPath"];
    if (path && path.length > 0) {
        NSString *cleanName = [[path lastPathComponent] stringByDeletingPathExtension];
        return [NSString stringWithFormat:@"已选中%@", cleanName];
    }
    return @"未选择";
}

- (id)getHomeVideoStatus:(PSSpecifier *)spec {
    NSString *plistPath = GetPrefsPlistPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *path = prefs[@"HomeVideoPath"];
    if (path && path.length > 0) {
        NSString *cleanName = [[path lastPathComponent] stringByDeletingPathExtension];
        return [NSString stringWithFormat:@"已选中%@", cleanName];
    }
    return @"未选择";
}

- (void)setSameMaterialValue:(id)value specifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];
    
    NSString *plistPath = GetPrefsPlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    
    [prefs removeObjectForKey:@"LockVideoPath"];
    [prefs removeObjectForKey:@"HomeVideoPath"];
    
    CFPreferencesSetAppValue(CFSTR("LockVideoPath"), NULL, CFSTR("com.iosdump.zoneprefs"));
    CFPreferencesSetAppValue(CFSTR("HomeVideoPath"), NULL, CFSTR("com.iosdump.zoneprefs"));
    
    [prefs writeToFile:plistPath atomically:YES];
    [self forceOwnershipToMobile:plistPath];
    
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    
    [self reloadSpecifiers];
}

- (void)importLockMaterial {
    self.currentVideoTarget = 1;
    [self showVideoImportMenu];
}

- (void)importHomeMaterial {
    self.currentVideoTarget = 2;
    [self showVideoImportMenu];
}

- (void)showVideoImportMenu {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"导入素材" message:@"请选择素材来源" preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"从相册导入" style:UIAlertActionStyleDefault handler:^(id action) {
        [self presentVideoPickerFromSource:UIImagePickerControllerSourceTypePhotoLibrary];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"从文件导入" style:UIAlertActionStyleDefault handler:^(id action) {
        [self presentDocumentPickerForVideo];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    UIViewController *topVC = self.view.window.rootViewController ?: self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    
    if (menu.popoverPresentationController) {
        menu.popoverPresentationController.sourceView = topVC.view;
        menu.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width/2, topVC.view.bounds.size.height, 0, 0);
    }
    [topVC presentViewController:menu animated:YES completion:nil];
}

- (void)presentVideoPickerFromSource:(UIImagePickerControllerSourceType)source {
    if (![UIImagePickerController isSourceTypeAvailable:source]) return;
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = source;
    picker.mediaTypes = @[@"public.movie", @"public.video", @"public.avi", @"public.mpeg-4"];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh; 
    
    UIViewController *topVC = self.view.window.rootViewController ?: self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    [topVC presentViewController:picker animated:YES completion:nil];
}

- (void)presentDocumentPickerForVideo {
    if (@available(iOS 14.0, *)) {
        UTType *movieType = [UTType typeWithIdentifier:@"public.movie"];
        UTType *videoType = [UTType typeWithIdentifier:@"public.video"];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[movieType, videoType]];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        
        UIViewController *topVC = self.view.window.rootViewController ?: self;
        while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
        [topVC presentViewController:picker animated:YES completion:nil];
    }
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (videoURL) [self processVideoURL:videoURL target:self.currentVideoTarget];
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)processVideoURL:(NSURL *)url target:(NSInteger)target {
    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在导入..." message:nil preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.center = CGPointMake(215.0, 31.0);
    [spinner startAnimating];
    [loadingAlert.view addSubview:spinner];
    
    UIViewController *topVC = self.view.window.rootViewController ?: self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    
    [topVC presentViewController:loadingAlert animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            BOOL isAccessing = [url startAccessingSecurityScopedResource];
            NSFileManager *fm = [NSFileManager defaultManager];
            
            NSString *videoDir = (target == 1) ? GetVideoWallpapersLockDir() : GetVideoWallpapersHomeDir();
            
            NSString *ext = [url pathExtension];
            if (ext.length == 0) ext = @"mp4";
            
            NSString *fileName = @"";
            int counter = 1;
            while (YES) {
                fileName = [NSString stringWithFormat:@"素材%d.%@", counter, ext];
                if (![fm fileExistsAtPath:[videoDir stringByAppendingPathComponent:fileName]]) {
                    break;
                }
                counter++;
            }
            
            NSString *destPath = [videoDir stringByAppendingPathComponent:fileName];
            
            NSError *err = nil;
            [fm copyItemAtPath:url.path toPath:destPath error:&err];
            
            if (isAccessing) [url stopAccessingSecurityScopedResource];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [loadingAlert dismissViewControllerAnimated:YES completion:^{
                    if (!err) {
                        [self forceOwnershipToMobile:videoDir];
                        [self applyVideoPath:destPath toTarget:target];
                    } else {
                        UIAlertController *failAlert = [UIAlertController alertControllerWithTitle:@"导入失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                        [failAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:failAlert animated:YES completion:nil];
                    }
                }];
            });
        });
    }];
}

- (void)selectVideoWallpaper:(PSSpecifier *)spec {
    NSString *name = [spec propertyForKey:@"VideoName"];
    NSInteger target = [[spec propertyForKey:@"VideoTarget"] integerValue]; 
    if (!name) return;
    
    NSString *videoDir = (target == 1) ? GetVideoWallpapersLockDir() : GetVideoWallpapersHomeDir();
    NSString *fullPath = [videoDir stringByAppendingPathComponent:name];
    [self applyVideoPath:fullPath toTarget:target];
}

- (void)applyVideoPath:(NSString *)path toTarget:(NSInteger)target {
    NSString *plistPath = GetPrefsPlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    
    BOOL isSameMaterialOn = [prefs[@"SameVideoMaterial"] boolValue];
    
    if (isSameMaterialOn) {
        prefs[@"LockVideoPath"] = path;
        prefs[@"HomeVideoPath"] = path;
        CFPreferencesSetAppValue(CFSTR("LockVideoPath"), (__bridge CFStringRef)path, CFSTR("com.iosdump.zoneprefs"));
        CFPreferencesSetAppValue(CFSTR("HomeVideoPath"), (__bridge CFStringRef)path, CFSTR("com.iosdump.zoneprefs"));
    } else {
        if (target == 1) {
            prefs[@"LockVideoPath"] = path;
            CFPreferencesSetAppValue(CFSTR("LockVideoPath"), (__bridge CFStringRef)path, CFSTR("com.iosdump.zoneprefs"));
        } else if (target == 2) {
            prefs[@"HomeVideoPath"] = path;
            CFPreferencesSetAppValue(CFSTR("HomeVideoPath"), (__bridge CFStringRef)path, CFSTR("com.iosdump.zoneprefs"));
        }
    }
    
    [prefs writeToFile:plistPath atomically:YES];
    [self forceOwnershipToMobile:plistPath];
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    [self reloadSpecifiers];
}

- (void)showEnhancedEngineInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"开启增强引擎将提升识别复杂交互壁纸能力以及适配壁纸暗黑模式等。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showHideTextShadowInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"关闭文字阴影。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAnimSpeedInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"开启后可在壁纸素材绿色按钮调节壁纸息屏跟关屏动画速度。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showDoubleTapLockInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"开启后手机桌面或锁屏息屏。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showReplaceImageInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"开启替换图片可在每个素材右边按钮点击替换按钮替换壁纸图片。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (id)getWallpaperSize:(PSSpecifier *)spec { return @""; }
- (id)getDummyValue:(PSSpecifier *)spec { return @""; }

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
    
    if (nextFactor >= 0.99) {
        [sender setTitle:@"原画" forState:UIControlStateNormal];
    } else {
        [sender setTitle:[NSString stringWithFormat:@"%.0f%%", nextFactor * 100] forState:UIControlStateNormal];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [(id)cell specifier];
    NSString *specKey = [spec propertyForKey:@"key"];
    NSString *labelString = [spec propertyForKey:@"label"];
    
    NSString *plistPath = GetPrefsPlistPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    
    if ([labelString isEqualToString:@"导入壁纸"]) {
        cell.textLabel.textAlignment = NSTextAlignmentLeft; 
        
        UIView *accView = cell.accessoryView;
        UILabel *countLabel = nil;
        if (![accView isKindOfClass:[UIView class]] || accView.tag != 444) {
            accView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 75, 28)];
            accView.tag = 444;
            
            countLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 75, 28)];
            countLabel.tag = 555;
            countLabel.layer.cornerRadius = 14;
            countLabel.layer.borderWidth = 1;
            countLabel.layer.borderColor = [UIColor systemBlueColor].CGColor;
            countLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
            countLabel.textColor = [UIColor systemBlueColor];
            countLabel.textAlignment = NSTextAlignmentCenter;
            
            [accView addSubview:countLabel];
            cell.accessoryView = accView;
        } else {
            countLabel = [accView viewWithTag:555];
        }
        
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *contents = [fm contentsOfDirectoryAtPath:GetWallpapersDir() error:nil];
        NSInteger count = 0;
        if (contents) {
            for (NSString *name in contents) {
                if (![name hasPrefix:@"."]) {
                    BOOL isDir;
                    if ([fm fileExistsAtPath:[GetWallpapersDir() stringByAppendingPathComponent:name] isDirectory:&isDir] && isDir) {
                        count++;
                    }
                }
            }
        }
        countLabel.text = [NSString stringWithFormat:@"已导入%ld张", (long)count];
        cell.detailTextLabel.hidden = YES;
        cell.detailTextLabel.text = @"";
        
        return cell;
    }
    
    if ([[spec propertyForKey:@"IsVideoCell"] boolValue]) {
        NSString *name = [spec propertyForKey:@"VideoName"];
        NSInteger target = [[spec propertyForKey:@"VideoTarget"] integerValue];
        NSString *fullPath = [(target == 1 ? GetVideoWallpapersLockDir() : GetVideoWallpapersHomeDir()) stringByAppendingPathComponent:name];

        NSString *currentLock = prefs[@"LockVideoPath"];
        NSString *currentHome = prefs[@"HomeVideoPath"];
        BOOL isSameMaterialOn = [prefs[@"SameVideoMaterial"] boolValue];

        BOOL isChecked = NO;
        if (isSameMaterialOn) {
            isChecked = [currentLock isEqualToString:fullPath] || [currentHome isEqualToString:fullPath];
        } else {
            if (target == 1) isChecked = [currentLock isEqualToString:fullPath];
            if (target == 2) isChecked = [currentHome isEqualToString:fullPath];
        }

        if (isChecked) {
            UIImageView *cm = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
            cm.tintColor = [UIColor systemBlueColor];
            [cm sizeToFit];
            cell.accessoryView = cm;
            cell.textLabel.textColor = [UIColor systemBlueColor];
        } else {
            cell.accessoryView = nil;
            cell.textLabel.textColor = [UIColor labelColor];
        }
        
        cell.detailTextLabel.hidden = YES;
        cell.detailTextLabel.text = @"";
        return cell;
    }
    
    if (self.isVideoMode) return cell; 
    
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
    
    if ([specKey isEqualToString:@"EnableAnimSpeed"]) {
        UIButton *existingBtn = [cell.contentView viewWithTag:883];
        if (!existingBtn) {
            UIButton *infoBtn = [UIButton buttonWithType:UIButtonTypeInfoLight];
            infoBtn.tag = 883;
            infoBtn.frame = CGRectMake(100, (cell.bounds.size.height - 22) / 2.0, 22, 22);
            infoBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;
            [infoBtn addTarget:self action:@selector(showAnimSpeedInfo) forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:infoBtn];
        }
    }

    if ([specKey isEqualToString:@"DoubleTapLock"]) {
        UIButton *existingBtn = [cell.contentView viewWithTag:884];
        if (!existingBtn) {
            UIButton *infoBtn = [UIButton buttonWithType:UIButtonTypeInfoLight];
            infoBtn.tag = 884;
            infoBtn.frame = CGRectMake(100, (cell.bounds.size.height - 22) / 2.0, 22, 22);
            infoBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;
            [infoBtn addTarget:self action:@selector(showDoubleTapLockInfo) forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:infoBtn];
        }
    }

    if ([specKey isEqualToString:@"EnableReplaceImage"]) {
        UIButton *existingBtn = [cell.contentView viewWithTag:885];
        if (!existingBtn) {
            UIButton *infoBtn = [UIButton buttonWithType:UIButtonTypeInfoLight];
            infoBtn.tag = 885;
            infoBtn.frame = CGRectMake(100, (cell.bounds.size.height - 22) / 2.0, 22, 22);
            infoBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;
            [infoBtn addTarget:self action:@selector(showReplaceImageInfo) forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:infoBtn];
        }
    }

    if ([[spec propertyForKey:@"IsWallpaperCell"] boolValue]) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        NSString *name = [spec propertyForKey:@"WallpaperName"];
        NSString *fullWpPath = [GetWallpapersDir() stringByAppendingPathComponent:name];
        
        NSString *currentPath = prefs[@"ZonePath"];
        BOOL isSelected = [currentPath isEqualToString:fullWpPath];
        
        if (isSelected) {
            cell.textLabel.textColor = [UIColor systemBlueColor];
        } else {
            cell.textLabel.textColor = [UIColor labelColor];
        }
        
        BOOL isAnimEnabled = NO;
        if (@available(iOS 16.0, *)) {
            isAnimEnabled = prefs[@"EnableAnimSpeed"] ? [prefs[@"EnableAnimSpeed"] boolValue] : YES;
        }
        BOOL isReplaceEnabled = prefs[@"EnableReplaceImage"] ? [prefs[@"EnableReplaceImage"] boolValue] : NO;
        
        CGFloat targetAccWidth = 140;
        if (isAnimEnabled) targetAccWidth += 50;
        if (isReplaceEnabled) targetAccWidth += 50; 
        
        UIView *accView = cell.accessoryView;
        UIButton *resBtn = nil;
        UIButton *speedBtn = nil;
        UIButton *replaceBtn = nil;
        UILabel *sizeLabel = nil;
        UIImageView *checkMark = nil;
        
        if (![accView isKindOfClass:[UIView class]] || accView.tag != 999 || accView.frame.size.width != targetAccWidth) {
            accView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, targetAccWidth, 30)];
            accView.tag = 999;
            
            sizeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 65, 30)];
            sizeLabel.font = [UIFont systemFontOfSize:14];
            sizeLabel.textColor = [UIColor secondaryLabelColor];
            sizeLabel.textAlignment = NSTextAlignmentRight;
            sizeLabel.tag = 888;
            [accView addSubview:sizeLabel];
            
            resBtn = [UIButton buttonWithType:UIButtonTypeCustom];
            resBtn.frame = CGRectMake(70, 1, 40, 28);
            resBtn.layer.cornerRadius = 14;
            resBtn.layer.borderWidth = 1;
            resBtn.layer.borderColor = [UIColor systemBlueColor].CGColor;
            resBtn.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
            [resBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
            [resBtn addTarget:self action:@selector(cycleResolution:) forControlEvents:UIControlEventTouchUpInside];
            resBtn.tag = 777;
            [accView addSubview:resBtn];
            
            CGFloat currentX = 115;
            
            if (isAnimEnabled) {
                speedBtn = [UIButton buttonWithType:UIButtonTypeCustom];
                speedBtn.frame = CGRectMake(currentX, 1, 45, 28);
                speedBtn.layer.cornerRadius = 14;
                speedBtn.layer.borderWidth = 1;
                speedBtn.layer.borderColor = [UIColor systemGreenColor].CGColor;
                speedBtn.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
                [speedBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
                [speedBtn addTarget:self action:@selector(cycleAnimSpeed:) forControlEvents:UIControlEventTouchUpInside];
                speedBtn.tag = 778;
                [accView addSubview:speedBtn];
                currentX += 50;
            }
            
            if (isReplaceEnabled) {
                replaceBtn = [UIButton buttonWithType:UIButtonTypeCustom];
                replaceBtn.frame = CGRectMake(currentX, 1, 45, 28);
                replaceBtn.layer.cornerRadius = 14;
                replaceBtn.layer.borderWidth = 1;
                replaceBtn.layer.borderColor = [UIColor systemOrangeColor].CGColor;
                replaceBtn.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
                [replaceBtn setTitle:@"替换" forState:UIControlStateNormal];
                [replaceBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
                [replaceBtn addTarget:self action:@selector(openReplaceImageController:) forControlEvents:UIControlEventTouchUpInside];
                replaceBtn.tag = 779;
                [accView addSubview:replaceBtn];
                currentX += 50;
            }
            
            checkMark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
            checkMark.frame = CGRectMake(currentX, 5, 20, 20);
            checkMark.tintColor = [UIColor systemBlueColor];
            checkMark.tag = 666;
            [accView addSubview:checkMark];
            
            cell.accessoryView = accView;
        } else {
            sizeLabel = [accView viewWithTag:888];
            resBtn = [accView viewWithTag:777];
            speedBtn = [accView viewWithTag:778];
            replaceBtn = [accView viewWithTag:779];
            checkMark = [accView viewWithTag:666];
        }
        
        if (replaceBtn) replaceBtn.accessibilityIdentifier = name;
        
        checkMark.hidden = !isSelected;
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
        
        if (isAnimEnabled && speedBtn) {
            speedBtn.accessibilityIdentifier = name;
            NSString *speedKey = [NSString stringWithFormat:@"AnimSpeed_%@", name];
            NSInteger speedLevel = [prefs[speedKey] integerValue];
            if (speedLevel == 1) [speedBtn setTitle:@"较快" forState:UIControlStateNormal];
            else if (speedLevel == 2) [speedBtn setTitle:@"极快" forState:UIControlStateNormal];
            else if (speedLevel == 3) [speedBtn setTitle:@"光速" forState:UIControlStateNormal];
            else [speedBtn setTitle:@"默认" forState:UIControlStateNormal];
        }
        
        cell.detailTextLabel.hidden = YES;
        cell.detailTextLabel.text = @"";
    }
    
    return cell;
}

- (UITableViewStyle)tableViewStyle {
    if (@available(iOS 13.0, *)) {
        return UITableViewStyleInsetGrouped;
    }
    return UITableViewStyleGrouped;
}

- (void)promptClearWallpapers {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空壁纸" message:@"确定要清空所有已导入的壁纸吗？此操作不可撤销。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self clearAllWallpapers];
    }]];
    
    UIViewController *topVC = self.view.window.rootViewController ?: self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    [topVC presentViewController:alert animated:YES completion:nil];
}

- (void)clearAllWallpapers {
    NSString *wpDir = GetWallpapersDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:wpDir error:nil];
    for (NSString *name in contents) {
        NSString *path = [wpDir stringByAppendingPathComponent:name];
        [fm removeItemAtPath:path error:nil];
        NSString *resKey = [NSString stringWithFormat:@"ResFactor_%@", name];
        CFPreferencesSetAppValue((__bridge CFStringRef)resKey, NULL, CFSTR("com.iosdump.zoneprefs"));
        
        NSString *animKey = [NSString stringWithFormat:@"AnimSpeed_%@", name];
        CFPreferencesSetAppValue((__bridge CFStringRef)animKey, NULL, CFSTR("com.iosdump.zoneprefs"));
    }
    
    CFPreferencesSetAppValue(CFSTR("ZonePath"), NULL, CFSTR("com.iosdump.zoneprefs"));
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
    
    NSString *plistPath = GetPrefsPlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    [prefs removeObjectForKey:@"ZonePath"];
    [prefs writeToFile:plistPath atomically:YES];
    
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    
    [self reloadSpecifiers];
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
            
            UIViewController *topVC = self.view.window.rootViewController ?: self;
            while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
            [topVC presentViewController:picker animated:YES completion:nil];
        }
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    if (self.isVideoMode) {
        [self processVideoURL:urls.firstObject target:self.currentVideoTarget];
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned long long totalSizeBytes = 0;
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL containsZip = NO;
        
        for (NSURL *url in urls) {
            [url startAccessingSecurityScopedResource];
            
            NSString *ext = [[url pathExtension] lowercaseString];
            if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"tendies"]) {
                containsZip = YES;
            } else {
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:url.path isDirectory:&isDir]) {
                    if (isDir) {
                        totalSizeBytes += getDirectorySize(url.path);
                    } else {
                        totalSizeBytes += [[fm attributesOfItemAtPath:url.path error:nil] fileSize];
                    }
                }
            }
        }

        double totalMB = totalSizeBytes / (1024.0 * 1024.0);
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!containsZip && totalMB > 40.0) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"检测到大文件" 
                                                                               message:[NSString stringWithFormat:@"检测导入的壁纸文件大于40MB (约 %.1f MB)。\n\n继续导入可能会导致设备在下滑锁屏时卡顿甚至卡死。\n是否继续导入？", totalMB] 
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){
                    for (NSURL *url in urls) { [url stopAccessingSecurityScopedResource]; }
                }]];
                [alert addAction:[UIAlertAction actionWithTitle:@"继续导入" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                    [self proceedWithImportingURLs:urls skipPostCheck:YES];
                }]];
                
                UIViewController *topVC = self.view.window.rootViewController ?: self;
                while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
                [topVC presentViewController:alert animated:YES completion:nil];
            } else {
                [self proceedWithImportingURLs:urls skipPostCheck:NO];
            }
        });
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

- (void)checkPostImportSizeForPaths:(NSArray *)importedPaths {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSMutableArray *oversizedPaths = [NSMutableArray array];
        for (NSString *path in importedPaths) {
            double finalMB = getDirectorySize(path) / (1024.0 * 1024.0);
            if (finalMB > 40.0) {
                [oversizedPaths addObject:@{@"path": path, @"size": @(finalMB)}];
            }
        }
        
        if (oversizedPaths.count > 0) {
            NSDictionary *firstOversized = oversizedPaths.firstObject;
            NSString *path = firstOversized[@"path"];
            double finalMB = [firstOversized[@"size"] doubleValue];
            NSString *wpName = [path lastPathComponent];
            
            NSString *msg = [NSString stringWithFormat:@"壁纸「%@」大于40MB (约 %.1f MB)。\n导入后使用可能导致滑动卡顿或内存爆增卡死设备。\n删除该壁纸？", wpName, finalMB];
            
            if (oversizedPaths.count > 1) {
                msg = [NSString stringWithFormat:@"检测到 %lu 个壁纸解压后大于40MB (例如「%@」约 %.1f MB)。\n继续保留极大概率导致滑动卡顿或卡死。\n是否删除这些危险壁纸？", (unsigned long)oversizedPaths.count, wpName, finalMB];
            }
            
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"检测到大文件"
                                                                           message:msg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"不删除" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                for (NSDictionary *info in oversizedPaths) {
                    [[NSFileManager defaultManager] removeItemAtPath:info[@"path"] error:nil];
                }
                [self reloadSpecifiers];
            }]];
            
            UIViewController *topVC = self.view.window.rootViewController ?: self;
            while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
            [topVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

- (void)processImportedItemAtPath:(NSString *)path targetDir:(NSString *)wpDir newImportedPaths:(NSMutableArray *)newImportedPaths {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return;

    if (!isDir) {
        NSString *ext = [[path pathExtension] lowercaseString];
        if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"tendies"]) {
            NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
            
            NSString *finalDest = [wpDir stringByAppendingPathComponent:name];
            
            int counter = 1;
            NSString *baseDest = finalDest;
            while ([fm fileExistsAtPath:finalDest]) {
                finalDest = [NSString stringWithFormat:@"%@_%d", baseDest, counter++];
            }
            
            [fm createDirectoryAtPath:finalDest withIntermediateDirectories:YES attributes:nil error:nil];
            
            BOOL success = microIndustrialUnzip(path, finalDest);
            if (!success) success = industrialUnzip(path, finalDest);
            
            if (success) {
                [fm removeItemAtPath:path error:nil];
                
                NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:finalDest];
                NSString *subpath;
                NSMutableArray *nestedItems = [NSMutableArray array];
                
                while ((subpath = [enumerator nextObject])) {
                    if ([subpath hasPrefix:@"__MACOSX"] || [subpath containsString:@"/.DS_Store"]) continue;
                    
                    NSString *subExt = [[subpath pathExtension] lowercaseString];
                    if ([subExt isEqualToString:@"zip"] || [subExt isEqualToString:@"tendies"]) {
                        [nestedItems addObject:[finalDest stringByAppendingPathComponent:subpath]];
                    }
                }
                
                if (nestedItems.count > 0) {
                    for (NSString *nestedPath in nestedItems) {
                        [self processImportedItemAtPath:nestedPath targetDir:wpDir newImportedPaths:newImportedPaths];
                    }
                    [fm removeItemAtPath:finalDest error:nil];
                } else {
                    optimizeZoneFolderIfNecessary(finalDest);
                    [newImportedPaths addObject:finalDest];
                }
            } else {
                [fm removeItemAtPath:finalDest error:nil];
            }
        }
    } else {
        NSArray *contents = [fm contentsOfDirectoryAtPath:path error:nil];
        for (NSString *item in contents) {
            if ([item hasPrefix:@"."] || [item hasPrefix:@"__MACOSX"]) continue;
            NSString *subPath = [path stringByAppendingPathComponent:item];
            [self processImportedItemAtPath:subPath targetDir:wpDir newImportedPaths:newImportedPaths];
        }
        [fm removeItemAtPath:path error:nil];
    }
}

- (void)proceedWithImportingURLs:(NSArray<NSURL *> *)urls skipPostCheck:(BOOL)skipPostCheck {
    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在导入..." message:nil preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.center = CGPointMake(205.0, 31.0);
    [spinner startAnimating];
    [loadingAlert.view addSubview:spinner];
    
    UIViewController *topVC = self.view.window.rootViewController ?: self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    
    [topVC presentViewController:loadingAlert animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *wpDir = GetWallpapersDir();
            
            if (![fm fileExistsAtPath:wpDir]) {
                [fm createDirectoryAtPath:wpDir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionNone} error:nil];
            }
            
            NSString *tempWorkspace = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            [fm createDirectoryAtPath:tempWorkspace withIntermediateDirectories:YES attributes:nil error:nil];
            
            NSMutableArray *newImportedPaths = [NSMutableArray array];
            __block NSError *exactError = nil; 
            
            for (NSURL *sourceURL in urls) {
                NSString *fileName = [sourceURL lastPathComponent];
                NSString *tempDest = [tempWorkspace stringByAppendingPathComponent:fileName];
                
                NSError *readErr = nil;
                NSData *fileData = [NSData dataWithContentsOfURL:sourceURL options:NSDataReadingMappedIfSafe error:&readErr];
                
                if (fileData) {
                    BOOL wrote = [fileData writeToFile:tempDest atomically:YES];
                    if (wrote) {
                        [self processImportedItemAtPath:tempDest targetDir:wpDir newImportedPaths:newImportedPaths];
                    } else {
                        exactError = [NSError errorWithDomain:@"Zone" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法写入数据到临时缓存目录。"}];
                    }
                } else {
                    exactError = readErr; 
                }
                
                [sourceURL stopAccessingSecurityScopedResource];
            }
            
            [fm removeItemAtPath:tempWorkspace error:nil];
            
            BOOL anySuccess = (newImportedPaths.count > 0);
            
            if (anySuccess) {
                [self forceOwnershipToMobile:wpDir];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        [self reloadSpecifiers]; 
                        if (!skipPostCheck) {
                            [self checkPostImportSizeForPaths:newImportedPaths];
                        }
                    }];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        NSString *errMsg = exactError ? exactError.localizedDescription : @"无效的壁纸文件，或解压彻底失败。";
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入失败" message:errMsg preferredStyle:UIAlertControllerStyleAlert];
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

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (@available(iOS 11.0, *)) {
        PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
        BOOL isInteractive = [[spec propertyForKey:@"IsWallpaperCell"] boolValue];
        BOOL isVideo = [[spec propertyForKey:@"IsVideoCell"] boolValue];
        
        if (!isInteractive && !isVideo) return nil;

        NSString *name = isVideo ? [spec propertyForKey:@"VideoName"] : [spec propertyForKey:@"WallpaperName"];

        UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
            if (isVideo) [self deleteVideoWithSpecifier:spec];
            else [self deleteWallpaperWithSpecifier:spec];
            completionHandler(YES);
        }];

        UIContextualAction *renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"重命名" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
            if (isVideo) [self renameVideo:name specifier:spec];
            else [self renameWallpaper:name specifier:spec];
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
        
        NSString *animKey = [NSString stringWithFormat:@"AnimSpeed_%@", name];
        CFPreferencesSetAppValue((__bridge CFStringRef)animKey, NULL, CFSTR("com.iosdump.zoneprefs"));
        
        [self removeSpecifier:spec animated:YES];
    }
}

- (void)deleteVideoWithSpecifier:(PSSpecifier *)spec {
    NSString *name = [spec propertyForKey:@"VideoName"];
    NSInteger target = [[spec propertyForKey:@"VideoTarget"] integerValue]; 
    if (name) {
        NSString *videoDir = (target == 1) ? GetVideoWallpapersLockDir() : GetVideoWallpapersHomeDir();
        NSString *path = [videoDir stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        
        NSString *plistPath = GetPrefsPlistPath();
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
        BOOL changed = NO;
        
        if ([prefs[@"LockVideoPath"] isEqualToString:path]) {
            [prefs removeObjectForKey:@"LockVideoPath"];
            CFPreferencesSetAppValue(CFSTR("LockVideoPath"), NULL, CFSTR("com.iosdump.zoneprefs"));
            changed = YES;
        }
        if ([prefs[@"HomeVideoPath"] isEqualToString:path]) {
            [prefs removeObjectForKey:@"HomeVideoPath"];
            CFPreferencesSetAppValue(CFSTR("HomeVideoPath"), NULL, CFSTR("com.iosdump.zoneprefs"));
            changed = YES;
        }
        
        if (changed) {
            [prefs writeToFile:plistPath atomically:YES];
            CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
        }
        
        [self reloadSpecifiers]; 
    }
}

- (void)renameWallpaper:(NSString *)oldName specifier:(PSSpecifier *)spec {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名" message:@"请输入新的壁纸名称" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.text = oldName;
    }];
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
                
                NSString *oldAnimKey = [NSString stringWithFormat:@"AnimSpeed_%@", oldName];
                NSString *newAnimKey = [NSString stringWithFormat:@"AnimSpeed_%@", newName];
                CFPropertyListRef animRef = CFPreferencesCopyAppValue((__bridge CFStringRef)oldAnimKey, CFSTR("com.iosdump.zoneprefs"));
                if (animRef) {
                    CFPreferencesSetAppValue((__bridge CFStringRef)newAnimKey, animRef, CFSTR("com.iosdump.zoneprefs"));
                    CFPreferencesSetAppValue((__bridge CFStringRef)oldAnimKey, NULL, CFSTR("com.iosdump.zoneprefs"));
                    CFRelease(animRef);
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
                [self reloadSpecifiers];
            }
        }
    }]];
    UIViewController *topVC = self.view.window.rootViewController ?: self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    [topVC presentViewController:alert animated:YES completion:nil];
}

- (void)renameVideo:(NSString *)oldName specifier:(PSSpecifier *)spec {
    NSInteger target = [[spec propertyForKey:@"VideoTarget"] integerValue]; 
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名" message:@"请输入新的视频名称" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.text = [oldName stringByDeletingPathExtension];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *inputName = alert.textFields.firstObject.text;
        NSString *oldExt = [oldName pathExtension];
        
        NSString *newName = oldExt.length > 0 ? [inputName stringByAppendingPathExtension:oldExt] : inputName;
        
        if (inputName.length > 0 && ![newName isEqualToString:oldName]) {
            NSString *videoDir = (target == 1) ? GetVideoWallpapersLockDir() : GetVideoWallpapersHomeDir();
            NSString *oldPath = [videoDir stringByAppendingPathComponent:oldName];
            NSString *newPath = [videoDir stringByAppendingPathComponent:newName];
            
            NSError *err = nil;
            [[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&err];
            if (!err) {
                NSString *plistPath = GetPrefsPlistPath();
                NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
                BOOL changed = NO;
                
                if ([prefs[@"LockVideoPath"] isEqualToString:oldPath]) {
                    prefs[@"LockVideoPath"] = newPath;
                    CFPreferencesSetAppValue(CFSTR("LockVideoPath"), (__bridge CFStringRef)newPath, CFSTR("com.iosdump.zoneprefs"));
                    changed = YES;
                }
                if ([prefs[@"HomeVideoPath"] isEqualToString:oldPath]) {
                    prefs[@"HomeVideoPath"] = newPath;
                    CFPreferencesSetAppValue(CFSTR("HomeVideoPath"), (__bridge CFStringRef)newPath, CFSTR("com.iosdump.zoneprefs"));
                    changed = YES;
                }
                
                if (changed) {
                    [prefs writeToFile:plistPath atomically:YES];
                    CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
                }
                [self reloadSpecifiers];
            }
        }
    }]];
    UIViewController *topVC = self.view.window.rootViewController ?: self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    [topVC presentViewController:alert animated:YES completion:nil];
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
    
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"Enabled"] || [key isEqualToString:@"LowPowerPause"] || [key isEqualToString:@"SameVideoMaterial"] || [key isEqualToString:@"EnableAnimSpeed"] || [key isEqualToString:@"DoubleTapLock"] || [key isEqualToString:@"EnableReplaceImage"]) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, appID);
        CFPreferencesAppSynchronize(appID);
        
        NSString *plistPath = GetPrefsPlistPath();
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
        prefs[key] = value;
        [prefs writeToFile:plistPath atomically:YES];
        [self forceOwnershipToMobile:plistPath];
        
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    }
}

- (void)openReplaceImageController:(UIButton *)sender {
    NSString *wpName = sender.accessibilityIdentifier;
    NSString *wpPath = [GetWallpapersDir() stringByAppendingPathComponent:wpName];
    
    // 【UI 现代化】：将子列表升级为 iOS 现代 InsetGrouped 卡片设计，保持和主设置页完美统一
    UITableViewStyle style = UITableViewStyleGrouped;
    if (@available(iOS 13.0, *)) {
        style = UITableViewStyleInsetGrouped;
    }
    
    UITableViewController *vc = [(UITableViewController *)[NSClassFromString(@"ZoneImageReplaceViewController") alloc] initWithStyle:style];
    [vc setValue:wpName forKey:@"wallpaperName"];
    [vc setValue:wpPath forKey:@"wallpaperPath"];
    [vc setValue:^{
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    } forKey:@"reloadCallback"];
    
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:nav animated:YES completion:nil];
    }
}
@end


// =======================================================
// ================= 独立子页面：大图预览引擎 =================
// =======================================================
@interface ZoneImagePreviewViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, copy) NSString *imagePath;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIImageView *imageView;
@end

@implementation ZoneImagePreviewViewController
- (BOOL)canBeShownFromSuspendedState { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = self.imagePath.lastPathComponent;
    
    // 【新增】：现代化的顶部导航栏按钮
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存相册" style:UIBarButtonItemStyleDone target:self action:@selector(saveImageToAlbum)];
    
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.delegate = self;
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];
    
    UIImage *img = [UIImage imageWithContentsOfFile:self.imagePath];
    self.imageView = [[UIImageView alloc] initWithImage:img];
    [self.scrollView addSubview:self.imageView];
    self.scrollView.contentSize = img.size;
    
    CGFloat scaleX = self.view.bounds.size.width / img.size.width;
    CGFloat scaleY = self.view.bounds.size.height / img.size.height;
    CGFloat minScale = MIN(scaleX, scaleY);
    
    self.scrollView.minimumZoomScale = minScale;
    self.scrollView.maximumZoomScale = minScale * 3.0;
    self.scrollView.zoomScale = minScale;
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { return self.imageView; }

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    CGFloat offsetX = MAX((scrollView.bounds.size.width - scrollView.contentSize.width) * 0.5, 0.0);
    CGFloat offsetY = MAX((scrollView.bounds.size.height - scrollView.contentSize.height) * 0.5, 0.0);
    self.imageView.center = CGPointMake(scrollView.contentSize.width * 0.5 + offsetX, 
                                        scrollView.contentSize.height * 0.5 + offsetY);
}

// 【新增】：保存图片到相册的逻辑
- (void)saveImageToAlbum {
    if (self.imageView.image) {
        UIImageWriteToSavedPhotosAlbum(self.imageView.image, self, @selector(image:didFinishSavingWithError:contextInfo:), nil);
    }
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:error ? @"保存失败" : @"保存成功" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end


// =======================================================
// ================= 独立子页面：自定义裁剪引擎 =================
// =======================================================
@interface ZoneImageCropViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImage *pickedImage;
@property (nonatomic, assign) CGSize targetSize;
@property (nonatomic, copy) void (^cropCompletion)(UIImage *croppedImage);

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIImageView *imageView;
@end

@implementation ZoneImageCropViewController
- (BOOL)canBeShownFromSuspendedState { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = @"裁剪图片";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(doneAction)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancelAction)];

    CGFloat screenW = self.view.bounds.size.width - 40;
    CGFloat screenH = self.view.bounds.size.height - 240; 
    
    CGFloat targetAspect = self.targetSize.width / self.targetSize.height;
    CGFloat cropW = screenW;
    CGFloat cropH = cropW / targetAspect;
    if (cropH > screenH) {
        cropH = screenH;
        cropW = cropH * targetAspect;
    }
    
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - cropW)/2, (self.view.bounds.size.height - cropH)/2 + 20, cropW, cropH)];
    self.scrollView.delegate = self;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.bounces = YES;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.alwaysBounceHorizontal = YES;
    self.scrollView.layer.borderColor = [UIColor whiteColor].CGColor;
    self.scrollView.layer.borderWidth = 2.0;
    self.scrollView.clipsToBounds = YES;
    [self.view addSubview:self.scrollView];
    
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    overlay.userInteractionEnabled = NO;
    [self.view addSubview:overlay];
    
    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, nil, overlay.bounds);
    CGPathAddRect(path, nil, self.scrollView.frame);
    maskLayer.path = path;
    maskLayer.fillRule = kCAFillRuleEvenOdd;
    overlay.layer.mask = maskLayer;
    CGPathRelease(path);
    
    self.imageView = [[UIImageView alloc] initWithImage:self.pickedImage];
    [self.scrollView addSubview:self.imageView];
    self.scrollView.contentSize = self.pickedImage.size;
    
    CGFloat minScaleX = cropW / self.pickedImage.size.width;
    CGFloat minScaleY = cropH / self.pickedImage.size.height;
    CGFloat minScale = MAX(minScaleX, minScaleY);
    
    self.scrollView.minimumZoomScale = minScale;
    self.scrollView.maximumZoomScale = minScale * 5.0;
    self.scrollView.zoomScale = minScale;
    
    CGFloat offsetX = (self.scrollView.contentSize.width - cropW) / 2.0;
    CGFloat offsetY = (self.scrollView.contentSize.height - cropH) / 2.0;
    self.scrollView.contentOffset = CGPointMake(MAX(0, offsetX), MAX(0, offsetY));
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView;
}

- (void)cancelAction {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)doneAction {
    CGFloat zoom = self.scrollView.zoomScale;
    CGPoint offset = self.scrollView.contentOffset;
    CGRect cropRect;
    cropRect.origin.x = offset.x / zoom;
    cropRect.origin.y = offset.y / zoom;
    cropRect.size.width = self.scrollView.bounds.size.width / zoom;
    cropRect.size.height = self.scrollView.bounds.size.height / zoom;
    
    UIGraphicsBeginImageContextWithOptions(self.targetSize, NO, 1.0);
    
    // 【核心修复】：支持透明图片无损转换！每次绘制前强制清空上下文，保证纯透明通道。
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextClearRect(context, CGRectMake(0, 0, self.targetSize.width, self.targetSize.height));
    
    CGFloat scaleX = self.targetSize.width / cropRect.size.width;
    CGFloat scaleY = self.targetSize.height / cropRect.size.height;
    CGRect drawRect = CGRectMake(-cropRect.origin.x * scaleX, 
                                 -cropRect.origin.y * scaleY, 
                                 self.pickedImage.size.width * scaleX, 
                                 self.pickedImage.size.height * scaleY);
    [self.pickedImage drawInRect:drawRect];
    UIImage *finalImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.cropCompletion) self.cropCompletion(finalImage);
    }];
}
@end


// =======================================================
// ================= 独立子页面：替换图片引擎 =================
// =======================================================
@interface ZoneImageReplaceViewController : UITableViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *wallpaperName;
@property (nonatomic, copy) NSString *wallpaperPath;
@property (nonatomic, strong) NSArray *imageFiles;
@property (nonatomic, copy) NSString *replacingImagePath;
@property (nonatomic, copy) void (^reloadCallback)(void);
@property (nonatomic, strong) NSCache *thumbCache;
@end

@implementation ZoneImageReplaceViewController
- (BOOL)canBeShownFromSuspendedState { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.thumbCache = [[NSCache alloc] init];
    self.title = self.wallpaperName;
    self.tableView.rowHeight = 80;
    
    UIBarButtonItem *restoreAllBtn = [[UIBarButtonItem alloc] initWithTitle:@"全部恢复" style:UIBarButtonItemStylePlain target:self action:@selector(restoreAllImages)];
    restoreAllBtn.tintColor = [UIColor systemRedColor];
    self.navigationItem.rightBarButtonItem = restoreAllBtn;
    
    [self loadImages];
}

- (void)loadImages {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:self.wallpaperPath];
    NSMutableArray *images = [NSMutableArray array];
    NSString *sub;
    while ((sub = [enumerator nextObject])) {
        if ([sub hasPrefix:@"__MACOSX"] || [sub containsString:@".DS_Store"]) continue;
        NSString *ext = sub.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
            if (![sub hasPrefix:@"."] && ![sub hasSuffix:@".bak"]) {
                [images addObject:sub];
            }
        }
    }
    self.imageFiles = [images sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.imageFiles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"ZoneImageCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 8;
        cell.imageView.layer.borderWidth = 0.5;
        cell.imageView.layer.borderColor = [UIColor separatorColor].CGColor;
    }
    
    NSString *imgSubPath = self.imageFiles[indexPath.row];
    NSString *fullPath = [self.wallpaperPath stringByAppendingPathComponent:imgSubPath];
    BOOL hasBackup = [[NSFileManager defaultManager] fileExistsAtPath:[fullPath stringByAppendingString:@".bak"]];
    
    // 获取图片真实物理尺寸 (极速读取文件头，不加载整图，无惧内存堆积与卡顿)
    CGSize imgSize = CGSizeZero;
    NSURL *imgURL = [NSURL fileURLWithPath:fullPath];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)imgURL, NULL);
    if (source) {
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
        if (props) {
            NSNumber *w = (__bridge NSNumber *)CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
            NSNumber *h = (__bridge NSNumber *)CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
            imgSize = CGSizeMake(w.doubleValue, h.doubleValue);
            CFRelease(props);
        }
        CFRelease(source);
    }
    NSString *sizeStr = [NSString stringWithFormat:@"[%.0fx%.0f]", imgSize.width, imgSize.height];
    
    cell.textLabel.text = imgSubPath.lastPathComponent;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = hasBackup ? [NSString stringWithFormat:@"已替换(点击修改/恢复) %@", sizeStr] : [NSString stringWithFormat:@"点击替换壁纸图片%@", sizeStr];
    cell.detailTextLabel.textColor = hasBackup ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
    
    cell.imageView.userInteractionEnabled = YES;
    if (cell.imageView.gestureRecognizers.count == 0) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarTapped:)];
        [cell.imageView addGestureRecognizer:tap];
    }
    
    UIImage *cachedThumb = [self.thumbCache objectForKey:imgSubPath];
    if (cachedThumb) {
        cell.imageView.image = cachedThumb;
    } else {
        cell.imageView.image = nil;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @autoreleasepool {
                // 用 NSData 读取彻底破除强缓存
                NSData *imgData = [NSData dataWithContentsOfFile:fullPath];
                UIImage *img = [UIImage imageWithData:imgData];
                if (img) {
                    CGSize targetSize = CGSizeMake(60, 60);
                    UIGraphicsBeginImageContextWithOptions(targetSize, NO, [UIScreen mainScreen].scale);
                    [img drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
                    UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (thumb) [self.thumbCache setObject:thumb forKey:imgSubPath];
                        UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                        if (updateCell) {
                            updateCell.imageView.image = thumb;
                            [updateCell setNeedsLayout];
                        }
                    });
                }
            }
        });
    }
    
    return cell;
}

- (void)avatarTapped:(UITapGestureRecognizer *)gesture {
    CGPoint p = [gesture.view convertPoint:CGPointZero toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:p];
    if (indexPath) {
        NSString *imgSubPath = self.imageFiles[indexPath.row];
        NSString *fullPath = [self.wallpaperPath stringByAppendingPathComponent:imgSubPath];
        
        // 【新增】：带导航栏的预览页，支持保存
        ZoneImagePreviewViewController *vc = [[ZoneImagePreviewViewController alloc] init];
        vc.imagePath = fullPath;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSString *imgSubPath = self.imageFiles[indexPath.row];
    NSString *fullPath = [self.wallpaperPath stringByAppendingPathComponent:imgSubPath];
    BOOL hasBackup = [[NSFileManager defaultManager] fileExistsAtPath:[fullPath stringByAppendingString:@".bak"]];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"图片操作" message:imgSubPath.lastPathComponent preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"选图替换此层 (相册)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.replacingImagePath = fullPath;
        [self showPickerWithSourceType:UIImagePickerControllerSourceTypePhotoLibrary];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"选图替换此层 (文件)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.replacingImagePath = fullPath;
        [self showDocumentPicker];
    }]];

    if (hasBackup) {
        [alert addAction:[UIAlertAction actionWithTitle:@"撤销替换 (恢复原图)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:fullPath error:nil];
            [fm moveItemAtPath:[fullPath stringByAppendingString:@".bak"] toPath:fullPath error:nil];
            [self.thumbCache removeObjectForKey:imgSubPath];
            // 【修复杂闪】：采用平滑的 Fade 动画单行刷新
            [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
            if (self.reloadCallback) self.reloadCallback();
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showPickerWithSourceType:(UIImagePickerControllerSourceType)type {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = type;
    picker.mediaTypes = @[@"public.image"];
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)showDocumentPicker {
    if (@available(iOS 14.0, *)) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.image"]]];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{
        [self presentCropViewControllerWithImage:img];
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *url = urls.firstObject;
    [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    UIImage *img = [UIImage imageWithData:data];
    [url stopAccessingSecurityScopedResource];
    [self presentCropViewControllerWithImage:img];
}

- (void)presentCropViewControllerWithImage:(UIImage *)img {
    if (!img || !self.replacingImagePath) return;
    
    // 【核心修复】：直接读取底层图像物理分辨率，无视苹果的 2x/3x 缩放点数机制
    NSData *origData = [NSData dataWithContentsOfFile:self.replacingImagePath];
    UIImage *orig = [UIImage imageWithData:origData];
    if (!orig) return;
    CGSize pixelSize = CGSizeMake(CGImageGetWidth(orig.CGImage), CGImageGetHeight(orig.CGImage));
    
    ZoneImageCropViewController *cropVC = [[ZoneImageCropViewController alloc] init];
    cropVC.pickedImage = img;
    cropVC.targetSize = pixelSize;
    
    __weak typeof(self) weakSelf = self;
    cropVC.cropCompletion = ^(UIImage *croppedImage) {
        [weakSelf saveCroppedImage:croppedImage];
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:cropVC];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)saveCroppedImage:(UIImage *)croppedImage {
    NSString *backupPath = [self.replacingImagePath stringByAppendingString:@".bak"];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:backupPath]) {
        [fm copyItemAtPath:self.replacingImagePath toPath:backupPath error:nil];
    }
    
    NSString *ext = self.replacingImagePath.pathExtension.lowercaseString;
    NSData *data = ([ext isEqualToString:@"png"]) ? UIImagePNGRepresentation(croppedImage) : UIImageJPEGRepresentation(croppedImage, 1.0);
    
    if (data) {
        [data writeToFile:self.replacingImagePath atomically:YES];
        chown(self.replacingImagePath.UTF8String, 501, 501);
        chmod(self.replacingImagePath.UTF8String, 0777);
    }
    
    NSString *fileName = self.replacingImagePath.lastPathComponent;
    
    CGSize targetSize = CGSizeMake(60, 60);
    UIGraphicsBeginImageContextWithOptions(targetSize, NO, [UIScreen mainScreen].scale);
    [croppedImage drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    UIImage *newThumb = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    if (newThumb) {
        [self.thumbCache setObject:newThumb forKey:fileName];
    }
    
    // 【终极修复】：放入主线程异步队列，等弹窗动画彻底结束后调用 loadImages，让它强制触发全局刷新！
    dispatch_async(dispatch_get_main_queue(), ^{
        [self loadImages];
        if (self.reloadCallback) self.reloadCallback();
        self.replacingImagePath = nil;
    });
}

- (void)restoreAllImages {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:self.wallpaperPath];
    NSString *sub;
    BOOL didRestore = NO;
    
    while ((sub = [enumerator nextObject])) {
        if ([sub hasSuffix:@".bak"]) {
            NSString *backupFullPath = [self.wallpaperPath stringByAppendingPathComponent:sub];
            NSString *originalFullPath = [backupFullPath substringToIndex:backupFullPath.length - 4];
            [fm removeItemAtPath:originalFullPath error:nil];
            [fm moveItemAtPath:backupFullPath toPath:originalFullPath error:nil];
            didRestore = YES;
        }
    }
    
    if (didRestore) {
        [self.thumbCache removeAllObjects];
        // 【防闪烁修复】：列表恢复图片时用优雅的交叉溶解动画代替瞬间白屏
        [UIView transitionWithView:self.tableView duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            [self loadImages];
        } completion:^(BOOL finished) {
            if (self.reloadCallback) self.reloadCallback();
        }];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"该壁纸文件没有被替换过任何图片。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
@end
