#import "DYDebugExport.h"
#import "DYDebugCapture.h"
#import "DKClassDump.h"
#import "DKZipWriter.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@implementation DYDebugExport

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
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

    // 统一使用 NSTemporaryDirectory()，便于分享后清理
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DYDebugKit"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *mkdirError = nil;

    // 先清掉旧目录，避免残留
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
    };
    NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:error];
    if (!metadataData) return NO;
    NSString *metadataPath = [root stringByAppendingPathComponent:@"metadata.json"];
    if (![metadataData writeToFile:metadataPath options:NSDataWritingAtomic error:error]) return NO;

    // 4. screenshot.png —— 避免 dispatch_sync 死锁
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

    if ([NSThread isMainThread]) {
        captureBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), captureBlock);
    }

    NSString *screenshotPath = nil;
    if (pngData != nil) {
        screenshotPath = [root stringByAppendingPathComponent:@"screenshot.png"];
        if (![pngData writeToFile:screenshotPath options:NSDataWritingAtomic error:error]) return NO;
    }

    // 5. headers/ —— class-dump 所有已加载的类
    NSString *headersDir = [root stringByAppendingPathComponent:@"headers"];
    if (![fm createDirectoryAtPath:headersDir
       withIntermediateDirectories:YES attributes:nil error:nil]) {
        headersDir = nil;
    }

    NSMutableArray<NSString *> *headerFiles = [NSMutableArray array];
    if (headersDir) {
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        if (classes) {
            for (unsigned int i = 0; i < classCount; i++) {
                @autoreleasepool {
                    Class cls = classes[i];
                    if (!DKClassIsSafe(cls)) continue;

                    NSString *name = NSStringFromClass(cls);
                    if (name.length == 0) continue;
                    if (DKClassNameIsRuntimeGenerated(name)) continue;

                    // 只保留合法文件名
                    NSCharacterSet *invalid = [[NSCharacterSet
                        characterSetWithCharactersInString:
                        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"]
                        invertedSet];
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
            free(classes);
        }
    }

    // 6. 打包成 DYDebugKit.zip
    NSString *zipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DYDebugKit.zip"];
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

    NSLog(@"[DYDebugKit] Exported zip: %@ (%lu headers)",
          zipPath, (unsigned long)headerFiles.count);
    return YES;
}

@end