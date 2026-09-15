#import "DYDebugExport.h"
#import "DYDebugCapture.h"
#import "DKClassDump.h"
#import "DKZipWriter.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@implementation DYDebugExport

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 error:(NSError **)error {
    return [self exportSnapshot:snapshot
                          scope:DYDebugExportScopeCurrentApp
                          error:error];
}

#pragma mark - 按范围收集类

// 本页：从 rootVC 开始，收集 VC 链 + 视图树上所有类
static void DYCollectViewClasses(UIView *view,
                                 NSMutableArray<Class> *result) {
    if (view == nil) return;

    Class cls = view.class;
    if (cls && ![result containsObject:cls]) {
        [result addObject:cls];
    }

    for (UIView *sub in view.subviews) {
        DYCollectViewClasses(sub, result);
    }
}

static void DYCollectControllerClasses(UIViewController *vc,
                                       NSMutableArray<Class> *result,
                                       NSMutableSet<UIViewController *> *visited) {
    if (vc == nil) return;
    if ([visited containsObject:vc]) return;
    [visited addObject:vc];

    Class cls = vc.class;
    if (cls && ![result containsObject:cls]) {
        [result addObject:cls];
    }

    for (UIViewController *child in vc.childViewControllers) {
        DYCollectControllerClasses(child, result, visited);
    }

    DYCollectControllerClasses(vc.presentedViewController, result, visited);

    DYCollectViewClasses(vc.view, result);
}

static NSArray<Class> *DYCollectClassesForScope(DYDebugExportScope scope) {
    NSMutableArray<Class> *result = [NSMutableArray array];

    if (scope == DYDebugExportScopeCurrentApp) {
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (classes) {
            for (unsigned int i = 0; i < count; i++) {
                [result addObject:classes[i]];
            }
            free(classes);
        }
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
        // 全量类名过滤音频相关
        static NSString *const kKeywords[] = {
            @"Audio", @"AVPlayer", @"AVAudio", @"AVAsset",
            @"MPMusic", @"MPMedia", @"MPMovie", @"AVCapture",
            @"Sound", @"Player", @"AV", @"MP",
        };
        NSUInteger keywordCount = sizeof(kKeywords) / sizeof(kKeywords[0]);

        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (classes) {
            for (unsigned int i = 0; i < count; i++) {
                Class cls = classes[i];
                NSString *name = NSStringFromClass(cls);
                if (name.length == 0) continue;

                BOOL matched = NO;
                for (NSUInteger k = 0; k < keywordCount; k++) {
                    if ([name containsString:kKeywords[k]]) {
                        matched = YES;
                        break;
                    }
                }
                // AV / MP 前缀避免误伤（比如 AVFoundation 里没别的东西）
                if (!matched) {
                    if ([name hasPrefix:@"AV"] || [name hasPrefix:@"MP"]) {
                        matched = YES;
                    }
                }
                if (matched) [result addObject:cls];
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
        if (error) {
            *error = [NSError errorWithDomain:@"DYDebugKit"
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey : @"Snapshot is nil"}];
        }
        return NO;
    }

    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:DYScopeFolderName(scope)];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *mkdirError = nil;

    [fm removeItemAtPath:root error:nil];

    if (![fm createDirectoryAtPath:root
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&mkdirError]) {
        if (error) *error = mkdirError;
        return NO;
    }

    // 1. view-tree.txt
    NSString *viewTreePath = [root stringByAppendingPathComponent:@"view-tree.txt"];
    if (![[snapshot.viewTree dataUsingEncoding:NSUTF8StringEncoding]
          writeToFile:viewTreePath options:NSDataWritingAtomic error:error]) return NO;

    // 2. view-controllers.txt
    NSString *viewControllersPath = [root stringByAppendingPathComponent:@"view-controllers.txt"];
    if (![[snapshot.viewControllers dataUsingEncoding:NSUTF8StringEncoding]
          writeToFile:viewControllersPath options:NSDataWritingAtomic error:error]) return NO;

    // 3. metadata.json
    NSDictionary *metadata = @{
        @"exportTime" : [NSDate date].description ?: @"",
        @"bundleID"   : [NSBundle mainBundle].bundleIdentifier ?: @"",
        @"appName"    : [NSBundle mainBundle].infoDictionary[@"CFBundleName"] ?: @"",
        @"osVersion"  : [UIDevice currentDevice].systemVersion ?: @"",
        @"deviceModel": [UIDevice currentDevice].model ?: @"",
        @"scope"      : @(scope),
    };
    NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:error];
    if (!metadataData) return NO;
    NSString *metadataPath = [root stringByAppendingPathComponent:@"metadata.json"];
    if (![metadataData writeToFile:metadataPath options:NSDataWritingAtomic error:error]) return NO;

    // 4. screenshot.png
    __block NSData *pngData = nil;
    void (^captureBlock)(void) = ^{
        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
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
    };

    if ([NSThread isMainThread]) captureBlock();
    else dispatch_sync(dispatch_get_main_queue(), captureBlock);

    NSString *screenshotPath = nil;
    if (pngData != nil) {
        screenshotPath = [root stringByAppendingPathComponent:@"screenshot.png"];
        if (![pngData writeToFile:screenshotPath options:NSDataWritingAtomic error:error]) return NO;
    }

    // 5. headers/
    NSString *headersDir = [root stringByAppendingPathComponent:@"headers"];
    if (![fm createDirectoryAtPath:headersDir
       withIntermediateDirectories:YES attributes:nil error:nil]) {
        headersDir = nil;
    }

    NSMutableArray<NSString *> *headerFiles = [NSMutableArray array];
    if (headersDir) {
        NSArray<Class> *classes = DYCollectClassesForScope(scope);

        NSCharacterSet *invalid = [[NSCharacterSet
            characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"]
            invertedSet];

        NSMutableSet<NSString *> *seenNames = [NSMutableSet set];

        for (Class cls in classes) {
            @autoreleasepool {
                if (!DKClassIsSafe(cls)) continue;

                NSString *name = NSStringFromClass(cls);
                if (name.length == 0) continue;
                if (DKClassNameIsRuntimeGenerated(name)) continue;
                if ([seenNames containsObject:name]) continue;
                [seenNames addObject:name];

                if ([name rangeOfCharacterFromSet:invalid].location != NSNotFound) continue;

                NSString *header = DKClassDumpHeaderForClass(cls);
                if (header.length == 0) continue;

                NSString *path = [headersDir stringByAppendingPathComponent:
                                  [name stringByAppendingString:@".h"]];
                if ([header writeToFile:path atomically:YES
                               encoding:NSUTF8StringEncoding error:nil]) {
                    [headerFiles addObject:path];
                }
            }
        }
    }

    // 6. 打包 zip
    NSString *zipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:DYScopeZipName(scope)];
    NSMutableArray<NSString *> *allFiles = [NSMutableArray arrayWithObjects:
                                            metadataPath, viewTreePath, viewControllersPath, nil];
    if (screenshotPath) [allFiles addObject:screenshotPath];
    [allFiles addObjectsFromArray:headerFiles];

    if (![DKZipWriter createZipAtPath:zipPath
                              rootDir:root
                                files:allFiles
                             progress:nil
                                error:error]) {
        return NO;
    }

    NSLog(@"[DYDebugKit] Exported scope=%ld zip=%@ (%lu headers)",
          (long)scope, zipPath, (unsigned long)headerFiles.count);
    return YES;
}

@end