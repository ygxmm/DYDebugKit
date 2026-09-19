#import "DYDebugExport.h"
#import "DYDebugCapture.h"
#import "DKClassDump.h"
#import "DKZipWriter.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

@implementation DYDebugExport

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot error:(NSError **)error {
    return [self exportSnapshot:snapshot scope:DYDebugExportScopeCurrentApp error:error];
}

#pragma mark - 按范围收集类

static void DYCollectViewClasses(UIView *view, NSMutableArray<Class> *result) {
    if (view == nil) return;
    @try {
        Class cls = view.class;
        if (cls && ![result containsObject:cls]) [result addObject:cls];
        for (UIView *sub in view.subviews) DYCollectViewClasses(sub, result);
    } @catch (__unused NSException *e) {}
}

static void DYCollectControllerClasses(UIViewController *vc,
                                       NSMutableArray<Class> *result,
                                       NSMutableSet<UIViewController *> *visited) {
    if (vc == nil || [visited containsObject:vc]) return;
    [visited addObject:vc];
    @try {
        Class cls = vc.class;
        if (cls && ![result containsObject:cls]) [result addObject:cls];
        for (UIViewController *child in vc.childViewControllers)
            DYCollectControllerClasses(child, result, visited);
        DYCollectControllerClasses(vc.presentedViewController, result, visited);
        DYCollectViewClasses(vc.view, result);
    } @catch (__unused NSException *e) {}
}

// 只拿"当前 App 主可执行文件"里的类，避免遍历上千系统类
static NSArray<Class> *DYCollectMainBundleClasses(void) {
    NSMutableArray<Class> *result = [NSMutableArray array];
    NSString *execPath = [NSBundle mainBundle].executablePath;
    if (execPath.length == 0) return result;

    // 遍历所有已加载 image，找到主可执行文件对应的
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (!path || ![path isEqualToString:execPath]) continue;

        // 找到主 image，拿它里面的类
        unsigned int count = 0;
        const char **names = objc_copyClassNamesForImage(name, &count);
        if (!names) continue;
        for (unsigned int j = 0; j < count; j++) {
            @try {
                const char *cn = names[j];
                if (!cn || cn[0] == '\0') continue;
                NSString *clsName = [NSString stringWithUTF8String:cn];
                if (clsName.length == 0) continue;
               ) Class cls = NSClassFromString(clsName);
                if (cls != Nil [result addObject:cls];
            } @catch (__unused NSException *e) {}
        }
        free(names);
        break;
    }
    return result;
}

static NSArray<Class> *DYCollectClassesForScope(DYDebugExportScope scope) {
    NSMutableArray<Class> *result = [NSMutableArray array];

    if (scope == DYDebugExportScopeCurrentApp) {
        // 只 dump 主可执行文件的类，安全
        [result addObjectsFromArray:DYCollectMainBundleClasses()];
        return result;
    }

    if (scope == DYDebugExportScopeCurrentPage) {
        UIWindow *window = DYDebugTargetWindow();
        if (window == nil) return result;
        NSMutableSet<UIViewController *> *visited = [NSMutableSet set];
        DYCollectControllerClasses(window.rootViewController, result, visited);
        DYCollectViewClasses(window, result);
        return result;
    }

    if (scope == DYDebugExportScopeCurrentAudio) {
        static NSString *const kKeywords[] = {
            @"Audio", @"AVPlayer", @"AVAudio", @"AVAsset",
            @"MPMusic", @"MPMedia", @"MPMovie", @"AVCapture",
            @"Sound", @"Player",
        };
        NSUInteger kwCount = sizeof(kKeywords) / sizeof(kKeywords[0]);

        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (classes) {
            for (unsigned int i = 0; i < count; i++) {
                @try {
                    Class cls = classes[i];
                    if (cls == Nil) continue;
                    const char *cn = class_getName(cls);
                    if (!cn || cn[0] == '\0') continue;
                    NSString *name = [NSString stringWithUTF8String:cn];
                    if (name.length == 0) continue;

                    BOOL matched = NO;
                    for (NSUInteger k = 0; k < kwCount; k++) {
                        if ([name containsString:kKeywords[k]]) { matched = YES; break; }
                    }
                    if (!matched && ([name hasPrefix:@"AV"] || [name hasPrefix:@"MP"]))
                        matched = YES;
                    if (matched) [result addObject:cls];
                } @catch (__unused NSException *e) {}
            }
            free(classes);
        }
        return result;
    }

    return result;
}

static NSString *DYScopeFolderName(DYDebugExportScope scope) {
    switch (scope) {
        case DYDebugExportScopeCurrentPage:  return @"DYDebugKit-page";
        case DYDebugExportScopeCurrentApp:   return @"DYDebugKit-app";
        case DYDebugExportScopeCurrentAudio: return @"DYDebugKit-audio";
    }
    return @"DYDebugKit";
}

static NSString *DYScopeZipName(DYDebugExportScope scope) {
    switch (scope) {
        case DYDebugExportScopeCurrentPage:  return @"DYDebugKit-page.zip";
        case DYDebugExportScopeCurrentApp:   return @"DYDebugKit-app.zip";
        case DYDebugExportScopeCurrentAudio: return @"DYDebugKit-audio.zip";
    }
    return @"DYDebugKit.zip";
}

#pragma mark - 导出主流程

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 scope:(DYDebugExportScope)scope
                 error:(NSError **)error
{
    if (snapshot == nil) {
        if (error) *error = [NSError errorWithDomain:@"DYDebugKit" code:1 userInfo:@{NSLocalizedDescriptionKey : @"Snapshot is nil"}];
        return NO;
    }

    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:DYScopeFolderName(scope)];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *mkdirError = nil;
    [fm removeItemAtPath:root error:nil];

    if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
        if (error) *error = mkdirError;
        return NO;
    }

    NSString *viewTreePath = [root stringByAppendingPathComponent:@"view-tree.txt"];
    if (![[snapshot.viewTree dataUsingEncoding:NSUTF8StringEncoding] writeToFile:viewTreePath options:NSDataWritingAtomic error:error]) return NO;

    NSString *viewControllersPath = [root stringByAppendingPathComponent:@"view-controllers.txt"];
    if (![[snapshot.viewControllers dataUsingEncoding:NSUTF8StringEncoding] writeToFile:viewControllersPath options:NSDataWritingAtomic error:error]) return NO;

    NSDictionary *metadata = @{
        @"exportTime" : [NSDate date].description ?: @"",
        @"bundleID"   : [NSBundle mainBundle].bundleIdentifier ?: @"",
        @"appName"    : [NSBundle mainBundle].infoDictionary[@"CFBundleName"] ?: @"",
        @"osVersion"  : [UIDevice currentDevice].systemVersion ?: @"",
        @"deviceModel": [UIDevice currentDevice].model ?: @"",
        @"scope"      : @(scope),
    };
    NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:error];
    if (!metadataData) return NO;
    NSString *metadataPath = [root stringByAppendingPathComponent:@"metadata.json"];
    if (![metadataData writeToFile:metadataPath options:NSDataWritingAtomic error:error]) return NO;

    // 截图
    __block NSData *pngData = nil;
    void (^captureBlock)(void) = ^{
        @try {
            UIWindow *keyWindow = nil;
            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if (![scene isKindOfClass:UIWindowScene.class]) continue;
                    UIWindowScene *ws = (UIWindowScene *)scene;
                    if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                    for (UIWindow *w in ws.windows) if (w.isKeyWindow) { keyWindow = w; break; }
                    if (keyWindow) break;
                }
            }
            if (keyWindow == nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                keyWindow = UIApplication.sharedApplication.windows.firstObject;
#pragma clang diagnostic pop
            }
            if (keyWindow == nil) return;
            UIGraphicsBeginImageContextWithOptions(keyWindow.bounds.size, NO, 0.0);
            [keyWindow drawViewHierarchyInRect:keyWindow.bounds afterScreenUpdates:NO];
            UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            pngData = UIImagePNGRepresentation(image);
        } @catch (__unused NSException *e) {}
    };
    if ([NSThread isMainThread]) captureBlock();
    else dispatch_sync(dispatch_get_main_queue(), captureBlock);

    NSString *screenshotPath = nil;
    if (pngData != nil) {
        screenshotPath = [root stringByAppendingPathComponent:@"screenshot.png"];
        if (![pngData writeToFile:screenshotPath options:NSDataWritingAtomic error:error]) return NO;
    }

    // 头文件
    NSString *headersDir = [root stringByAppendingPathComponent:@"headers"];
    if (![fm createDirectoryAtPath:headersDir withIntermediateDirectories:YES attributes:nil error:nil]) {
        headersDir = nil;
    }

    NSMutableArray<NSString *> *headerFiles = [NSMutableArray array];
    if (headersDir) {
        NSArray<Class> *classes = DYCollectClassesForScope(scope);
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];

        for (Class cls in classes) {
            @autoreleasepool {
                @try {
                    if (cls == Nil) continue;
                    if (!DKClassIsSafe(cls)) continue;
                    NSString *name = NSStringFromClass(cls);
                    if (name.length == 0) continue;
                    if (DKClassNameIsRuntimeGenerated(name)) continue;
                    if ([seen containsObject:name]) continue;
                    if ([name rangeOfCharacterFromSet:invalid].location != NSNotFound) continue;

                    NSString *header = DKClassDumpHeaderForClass(cls);
                    if (header.length == 0) continue;
                    [seen addObject:name];

                    NSString *path = [headersDir stringByAppendingPathComponent:
                                      [name stringByAppendingString:@".h"]];
                    if ([header writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
                        [headerFiles addObject:path];
                    }
                } @catch (__unused NSException *e) {}
            }
        }
    }

    // 打包
    NSString *zipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:DYScopeZipName(scope)];
    NSMutableArray<NSString *> *allFiles = [NSMutableArray arrayWithObjects:
                                            metadataPath, viewTreePath, viewControllersPath, nil];
    if (screenshotPath) [allFiles addObject:screenshotPath];
    [allFiles addObjectsFromArray:headerFiles];

    if (![DKZipWriter createZipAtPath:zipPath rootDir:root files:allFiles progress:nil error:error]) return NO;

    NSLog(@"[DYDebugKit] Exported scope=%ld zip=%@ (%lu headers)",
          (long)scope, zipPath, (unsigned long)headerFiles.count);
    return YES;
}

@end
