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
// 引擎 1：微型工业级原生解压引擎 (纯手写、防泄漏、零内存激增)
// ========================================================
static BOOL microIndustrialUnzip(NSString *source, NSString *destination) {
    FILE *fp = fopen([source UTF8String], "rb");
    if (!fp) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil];

    unsigned char sig[4];
    while (fread(sig, 1, 4, fp) == 4) {
        if (sig[0] != 0x50 || sig[1] != 0x4B || sig[2] != 0x03 || sig[3] != 0x04) break; 

        unsigned char header[26];
        if (fread(header, 1, 26, fp) != 26) { fclose(fp); return NO; }

        uint16_t flags = header[2] | (header[3] << 8);
        uint16_t method = header[4] | (header[5] << 8);
        uint32_t compSize = header[14] | (header[15] << 8) | (header[16] << 16) | (header[17] << 24);
        uint16_t nameLen = header[22] | (header[23] << 8);
        uint16_t extraLen = header[24] | (header[25] << 8);

        if ((flags & 0x01) || (flags & 0x08) || compSize == 0xFFFFFFFF) {
            fclose(fp); return NO; 
        }

        char name[nameLen + 1];
        if (fread(name, 1, nameLen, fp) != nameLen) { fclose(fp); return NO; }
        name[nameLen] = '\0';

        if (extraLen > 0) fseek(fp, extraLen, SEEK_CUR);

        NSString *fileName = [NSString stringWithUTF8String:name];
        if (!fileName) { fclose(fp); return NO; }
        
        if ([fileName containsString:@"../"]) {
            fseek(fp, compSize, SEEK_CUR);
            continue;
        }

        NSString *outPath = [destination stringByAppendingPathComponent:fileName];

        if ([fileName hasSuffix:@"/"]) {
            [fm createDirectoryAtPath:outPath withIntermediateDirectories:YES attributes:nil error:nil];
        } else {
            [fm createDirectoryAtPath:[outPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];

            if (method == 0) {
                FILE *outFp = fopen([outPath UTF8String], "wb");
                if (!outFp) { fclose(fp); return NO; }
                char buf[32768];
                uint32_t left = compSize;
                while (left > 0) {
                    size_t toRead = left < sizeof(buf) ? left : sizeof(buf);
                    size_t r = fread(buf, 1, toRead, fp);
                    if (r == 0) break;
                    fwrite(buf, 1, r, outFp);
                    left -= r;
                }
                fclose(outFp);
            } else if (method == 8) {
                FILE *outFp = fopen([outPath UTF8String], "wb");
                if (!outFp) { fclose(fp); return NO; }

                z_stream strm;
                strm.zalloc = Z_NULL;
                strm.zfree = Z_NULL;
                strm.opaque = Z_NULL;
                strm.avail_in = 0;
                strm.next_in = Z_NULL;

                if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) {
                    fclose(outFp); fclose(fp); return NO;
                }

                unsigned char inBuf[32768];
                unsigned char outBuf[32768];
                uint32_t left = compSize;
                int ret = Z_OK;

                do {
                    size_t toRead = left < sizeof(inBuf) ? left : sizeof(inBuf);
                    if (toRead == 0) break;
                    size_t r = fread(inBuf, 1, toRead, fp);
                    if (r == 0) break;
                    strm.avail_in = (uInt)r;
                    strm.next_in = inBuf;
                    left -= r;

                    do {
                        strm.avail_out = sizeof(outBuf);
                        strm.next_out = outBuf;
                        ret = inflate(&strm, Z_NO_FLUSH);
                        if (ret == Z_STREAM_ERROR || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) {
                            inflateEnd(&strm); fclose(outFp); fclose(fp); return NO;
                        }
                        unsigned have = sizeof(outBuf) - strm.avail_out;
                        if (have > 0) fwrite(outBuf, 1, have, outFp);
                    } while (strm.avail_out == 0);
                } while (ret != Z_STREAM_END && left > 0);

                inflateEnd(&strm);
                fclose(outFp);
            } else {
                fclose(fp); return NO;
            }
        }
    }
    fclose(fp);
    return YES;
}

// ========================================================
// 引擎 2：原有兜底解压引擎 (posix_spawn 调用系统解压)
// ========================================================
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

// 【修改点：将清空壁纸功能移入右上角菜单】
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
        
        // 如果处于交互模式，则在注销按钮上方加入清空壁纸选项
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

// 【修改点：同步支持 iOS 14 以下的清空壁纸弹窗菜单】
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

// 新增：壁纸动画开关回调
- (void)setAnimEnableValue:(id)value specifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];
    // 强制重载 UI，让速度调节按钮平滑出现/消失
    [self reloadSpecifiers]; 
}

// 新增：循环切换壁纸动画速度
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
    if (nextSpeed > 3) nextSpeed = 0; // 0, 1, 2, 3 循环
    
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFNumberRef)@(nextSpeed), CFSTR("com.iosdump.zoneprefs"));
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.zoneprefs"));
    
    NSString *plistPath = GetPrefsPlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    prefs[key] = @(nextSpeed);
    [prefs writeToFile:plistPath atomically:YES];
    [self forceOwnershipToMobile:plistPath];
    
    // 通知 SpringBoard 刷新引擎
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.zoneprefs/ReloadPrefs"), NULL, NULL, YES);
    
    if (nextSpeed == 1) [sender setTitle:@"较快" forState:UIControlStateNormal];
    else if (nextSpeed == 2) [sender setTitle:@"极快" forState:UIControlStateNormal];
    else if (nextSpeed == 3) [sender setTitle:@"光速" forState:UIControlStateNormal];
    else [sender setTitle:@"默认" forState:UIControlStateNormal];
}

// =======================================
// 动态双重 Specifiers 渲染核心 
// =======================================
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
        
        // ================= 锁屏视频区域 =================
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
            // UI 显示专用名称（去后缀），底层依然保存带后缀的 name
            NSString *displayName = [name stringByDeletingPathExtension];
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:displayName target:self set:nil get:@selector(getDummyValue:) detail:nil cell:PSTitleValueCell edit:nil];
            spec->action = @selector(selectVideoWallpaper:);
            [spec setProperty:name forKey:@"VideoName"];
            [spec setProperty:@1 forKey:@"VideoTarget"]; 
            [spec setProperty:@YES forKey:@"IsVideoCell"]; 
            [_specifiers addObject:spec];
        }
        
        // ================= 桌面视频区域 =================
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
            // UI 显示专用名称（去后缀）
            NSString *displayName = [name stringByDeletingPathExtension];
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:displayName target:self set:nil get:@selector(getDummyValue:) detail:nil cell:PSTitleValueCell edit:nil];
            spec->action = @selector(selectVideoWallpaper:);
            [spec setProperty:name forKey:@"VideoName"];
            [spec setProperty:@2 forKey:@"VideoTarget"]; 
            [spec setProperty:@YES forKey:@"IsVideoCell"]; 
            [_specifiers addObject:spec];
        }
        
        // ================= Filza 跳转区域 =================
        PSSpecifier *gFilza = [PSSpecifier emptyGroupSpecifier];
        [_specifiers addObject:gFilza];
        
        PSSpecifier *btnFilza = [PSSpecifier preferenceSpecifierNamed:@"跳转 Filza 查看" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        btnFilza->action = @selector(openFilzaPath:);
        [_specifiers addObject:btnFilza];
        
    } else {
        NSArray *rootSpecs = [self loadSpecifiersFromPlistName:@"Root" target:self];
        
        // ====== 动态注入“双击锁屏”与“壁纸动画”开关 ======
        NSUInteger baseInsertIndex = NSNotFound;
        for (NSUInteger i = 0; i < rootSpecs.count; i++) {
            PSSpecifier *spec = rootSpecs[i];
            if ([[spec propertyForKey:@"key"] isEqualToString:@"HideTextShadow"]) {
                baseInsertIndex = i + 1; // 记录文字阴影开关下方的核心位置
                break;
            }
        }

        if (baseInsertIndex != NSNotFound) {
            NSMutableArray *mutRoot = [rootSpecs mutableCopy];

            // 1. 注入“双击桌面锁屏”开关 (全版本适用)
            PSSpecifier *doubleTapSpec = [PSSpecifier preferenceSpecifierNamed:@"双击桌面锁屏" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
            [doubleTapSpec setProperty:@"DoubleTapLock" forKey:@"key"];
            [doubleTapSpec setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
            [doubleTapSpec setProperty:@NO forKey:@"default"];
            doubleTapSpec->action = @selector(setPreferenceValue:specifier:);
            [mutRoot insertObject:doubleTapSpec atIndex:baseInsertIndex];

            // 2. 注入“动画速度”开关 (仅 iOS 16+)
            if (@available(iOS 16.0, *)) {
                PSSpecifier *animSpec = [PSSpecifier preferenceSpecifierNamed:@"动画速度" target:self set:@selector(setAnimEnableValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
                [animSpec setProperty:@"EnableAnimSpeed" forKey:@"key"];
                [animSpec setProperty:@"com.iosdump.zoneprefs" forKey:@"defaults"];
                [animSpec setProperty:@YES forKey:@"default"];
                animSpec->action = @selector(setAnimEnableValue:specifier:);
                [mutRoot insertObject:animSpec atIndex:baseInsertIndex + 1]; // 顺延插入在双击锁屏下方
            }

            rootSpecs = mutRoot;
        }
        // ==========================================================

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

// =======================================================
// ==================== 视频壁纸专属逻辑 ====================
// =======================================================
- (id)getLockVideoStatus:(PSSpecifier *)spec {
    NSString *plistPath = GetPrefsPlistPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *path = prefs[@"LockVideoPath"];
    if (path && path.length > 0) {
        // [核心修改] 截取最后的文件名，并自动抹去 .mp4/.mov 后缀
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
        // [核心修改] 截取最后的文件名，并自动抹去 .mp4/.mov 后缀
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
            
            // 获取视频的原始后缀名，如果没有则兜底使用 mp4
            NSString *ext = [url pathExtension];
            if (ext.length == 0) ext = @"mp4";
            
            NSString *fileName = @"";
            int counter = 1;
            // 循环查找可用的名称：素材1, 素材2, 素材3...
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

// =======================================
// =============== 原版交互壁纸辅助保留逻辑 ===============
// =======================================
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

// 【修改点3】完全重构原生打勾为蓝色实心圆圈打勾视觉，并注入数量标识圈
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [(id)cell specifier];
    NSString *specKey = [spec propertyForKey:@"key"];
    NSString *labelString = [spec propertyForKey:@"label"];
    
    NSString *plistPath = GetPrefsPlistPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    
    // 【全新功能】：导入壁纸右侧添加“已导入 x 张”徽章圈
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
        
        // === 读取开关状态 ===
        BOOL isAnimEnabled = NO;
        if (@available(iOS 16.0, *)) {
            isAnimEnabled = prefs[@"EnableAnimSpeed"] ? [prefs[@"EnableAnimSpeed"] boolValue] : YES;
        }
        CGFloat targetAccWidth = isAnimEnabled ? 190 : 140; // 开启后动态加宽给速度按钮腾位置
        
        UIView *accView = cell.accessoryView;
        UIButton *resBtn = nil;
        UIButton *speedBtn = nil;
        UILabel *sizeLabel = nil;
        UIImageView *checkMark = nil;
        
        // 如果视图不存在，或者宽度不对（说明开关被切换了），就重建视图
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
            
            // ====== 核心：动态生成动画调速按钮 ======
            if (isAnimEnabled) {
                speedBtn = [UIButton buttonWithType:UIButtonTypeCustom];
                speedBtn.frame = CGRectMake(115, 1, 45, 28);
                speedBtn.layer.cornerRadius = 14;
                speedBtn.layer.borderWidth = 1;
                speedBtn.layer.borderColor = [UIColor systemGreenColor].CGColor;
                speedBtn.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
                [speedBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
                [speedBtn addTarget:self action:@selector(cycleAnimSpeed:) forControlEvents:UIControlEventTouchUpInside];
                speedBtn.tag = 778;
                [accView addSubview:speedBtn];
                
                checkMark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
                checkMark.frame = CGRectMake(165, 5, 20, 20); // 往后挪
            } else {
                checkMark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
                checkMark.frame = CGRectMake(115, 5, 20, 20); // 原来的位置
            }
            
            checkMark.tintColor = [UIColor systemBlueColor];
            checkMark.tag = 666;
            [accView addSubview:checkMark];
            
            cell.accessoryView = accView;
        } else {
            sizeLabel = [accView viewWithTag:888];
            resBtn = [accView viewWithTag:777];
            speedBtn = [accView viewWithTag:778];
            checkMark = [accView viewWithTag:666];
        }
        
        checkMark.hidden = !isSelected;
        double sizeMB = getDirectorySize(fullWpPath) / (1024.0 * 1024.0);
        sizeLabel.text = [NSString stringWithFormat:@"%.1f MB", sizeMB];
        
        // 绑定资源参数
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
        
        // ====== 绑定动画调速参数 ======
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

// ==========================================================
// 全新文档导入回调：包含 ZIP 绕过预检、批处理解压拆分、40MB延迟查杀
// ==========================================================
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
            NSString *ext = [[url pathExtension] lowercaseString];
            if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"tendies"]) {
                containsZip = YES;
            } else {
                BOOL isAccessing = [url startAccessingSecurityScopedResource];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:url.path isDirectory:&isDir]) {
                    if (isDir) {
                        totalSizeBytes += getDirectorySize(url.path);
                    } else {
                        totalSizeBytes += [[fm attributesOfItemAtPath:url.path error:nil] fileSize];
                    }
                }
                if (isAccessing) [url stopAccessingSecurityScopedResource];
            }
        }

        double totalMB = totalSizeBytes / (1024.0 * 1024.0);
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!containsZip && totalMB > 40.0) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"检测到大文件" 
                                                                               message:[NSString stringWithFormat:@"检测导入的壁纸文件大于40MB (约 %.1f MB)。\n\n继续导入可能会导致设备在下滑锁屏时、卡顿甚至卡死。\n是否继续导入？", totalMB] 
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
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

// ==========================================================
// 二级危险文件延迟检测模块：根据传回信号进行静默或彻底查杀
// ==========================================================
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

// 核心解压直接注入系统：不检测结构，绝对服从原始命名
- (void)processImportedItemAtPath:(NSString *)path targetDir:(NSString *)wpDir newImportedPaths:(NSMutableArray *)newImportedPaths {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return;

    if (!isDir) {
        NSString *ext = [[path pathExtension] lowercaseString];
        if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"tendies"]) {
            NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
            
            // 直接以压缩包/tendies的名字命名作为目标文件夹
            NSString *finalDest = [wpDir stringByAppendingPathComponent:name];
            
            int counter = 1;
            NSString *baseDest = finalDest;
            while ([fm fileExistsAtPath:finalDest]) {
                finalDest = [NSString stringWithFormat:@"%@_%d", baseDest, counter++];
            }
            
            [fm createDirectoryAtPath:finalDest withIntermediateDirectories:YES attributes:nil error:nil];
            
            // 直接解压，不做任何内部结构检测
            BOOL success = microIndustrialUnzip(path, finalDest);
            if (!success) success = industrialUnzip(path, finalDest);
            
            if (success) {
                [fm removeItemAtPath:path error:nil];
                
                // 【深度遍历修复】：解决压缩包内部带有文件夹包裹，导致里面的 .tendies 无法被识别解压的问题
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
                
                // 如果它是个包含多个 tendies/zip 的纯外壳（哪怕放在子文件夹里），深度抽走解压，并删掉外壳
                if (nestedItems.count > 0) {
                    for (NSString *nestedPath in nestedItems) {
                        [self processImportedItemAtPath:nestedPath targetDir:wpDir newImportedPaths:newImportedPaths];
                    }
                    [fm removeItemAtPath:finalDest error:nil];
                } else {
                    // 就是壁纸本体，正常优化并加入列表
                    optimizeZoneFolderIfNecessary(finalDest);
                    [newImportedPaths addObject:finalDest];
                }
            } else {
                [fm removeItemAtPath:finalDest error:nil];
            }
        }
    } else {
        // 如果遇到文件夹包裹，遍历进去处理里面的压缩包
        NSArray *contents = [fm contentsOfDirectoryAtPath:path error:nil];
        for (NSString *item in contents) {
            if ([item hasPrefix:@"."] || [item hasPrefix:@"__MACOSX"]) continue;
            NSString *subPath = [path stringByAppendingPathComponent:item];
            [self processImportedItemAtPath:subPath targetDir:wpDir newImportedPaths:newImportedPaths];
        }
        [fm removeItemAtPath:path error:nil];
    }
}

// 包含了深层防御以及批处理递归拆解的终极导入总入口
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
            
            for (NSURL *sourceURL in urls) {
                BOOL isAccessing = [sourceURL startAccessingSecurityScopedResource];
                
                NSString *fileName = [sourceURL lastPathComponent];
                NSString *tempDest = [tempWorkspace stringByAppendingPathComponent:fileName];
                
                if ([fm copyItemAtPath:sourceURL.path toPath:tempDest error:nil]) {
                    // 进入究极形态的递归拆分与解压分流模块
                    [self processImportedItemAtPath:tempDest targetDir:wpDir newImportedPaths:newImportedPaths];
                }
                
                if (isAccessing) [sourceURL stopAccessingSecurityScopedResource];
            }
            
            // 清空打扫临时加工间
            [fm removeItemAtPath:tempWorkspace error:nil];
            
            BOOL anySuccess = (newImportedPaths.count > 0);
            
            if (anySuccess) {
                [self forceOwnershipToMobile:wpDir];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loadingAlert dismissViewControllerAnimated:YES completion:^{
                        [self reloadSpecifiers]; 
                        // 根据预检结果拦截决定是否执行延迟查杀
                        if (!skipPostCheck) {
                            [self checkPostImportSizeForPaths:newImportedPaths];
                        }
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
        // [修改核心 1]：在输入框中隐藏后缀名，只显示名字主体
        textField.text = [oldName stringByDeletingPathExtension];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *inputName = alert.textFields.firstObject.text;
        NSString *oldExt = [oldName pathExtension];
        
        // [修改核心 2]：自动把原来的后缀名拼回去
        NSString *newName = oldExt.length > 0 ? [inputName stringByAppendingPathExtension:oldExt] : inputName;
        
        // 校验：输入框不能为空，且拼接后缀后的新名字不能和原名相同
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
    if ([key isEqualToString:@"Enabled"] || [key isEqualToString:@"LowPowerPause"] || [key isEqualToString:@"SameVideoMaterial"] || [key isEqualToString:@"EnableAnimSpeed"] || [key isEqualToString:@"DoubleTapLock"]) {
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
@end
