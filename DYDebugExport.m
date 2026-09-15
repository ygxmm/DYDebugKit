#import "DYDebugExport.h"
#import "DYDebugCapture.h"
#import <UIKit/UIKit.h>

@implementation DYDebugExport

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 error:(NSError **)error
{
    if (snapshot == nil) {
        if (error) {
            *error = [NSError errorWithDomain:@"DYDebugKit"
                                          code:1
                                      userInfo:@{
                NSLocalizedDescriptionKey : @"Snapshot is nil"
            }];
        }
        return NO;
    }

    NSString *root =
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"DYDebugKit"];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *mkdirError = nil;

    if (![fm createDirectoryAtPath:root
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&mkdirError]) {
        if (error) *error = mkdirError;
        return NO;
    }

    // 1. view-tree.txt
    NSString *viewTreePath = [root stringByAppendingPathComponent:@"view-tree.txt"];
    NSData *viewTreeData = [snapshot.viewTree dataUsingEncoding:NSUTF8StringEncoding];
    if (![viewTreeData writeToFile:viewTreePath options:NSDataWritingAtomic error:error]) {
        return NO;
    }

    // 2. view-controllers.txt
    NSString *viewControllersPath = [root stringByAppendingPathComponent:@"view-controllers.txt"];
    NSData *viewControllersData = [snapshot.viewControllers dataUsingEncoding:NSUTF8StringEncoding];
    if (![viewControllersData writeToFile:viewControllersPath options:NSDataWritingAtomic error:error]) {
        return NO;
    }

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
    if (metadataData == nil) {
        return NO;
    }
    NSString *metadataPath = [root stringByAppendingPathComponent:@"metadata.json"];
    if (![metadataData writeToFile:metadataPath options:NSDataWritingAtomic error:error]) {
        return NO;
    }

    // 4. screenshot.png —— 必须在主线程执行
    __block NSData *pngData = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
            if (keyWindow) break;
        }
        if (keyWindow == nil) {
            keyWindow = UIApplication.sharedApplication.windows.firstObject;
        }
        if (keyWindow == nil) return;

        UIGraphicsBeginImageContextWithOptions(keyWindow.bounds.size, NO, 0.0);
        [keyWindow drawViewHierarchyInRect:keyWindow.bounds afterScreenUpdates:YES];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        pngData = UIImagePNGRepresentation(image);
    });

    if (pngData != nil) {
        NSString *screenshotPath = [root stringByAppendingPathComponent:@"screenshot.png"];
        if (![pngData writeToFile:screenshotPath options:NSDataWritingAtomic error:error]) {
            return NO;
        }
    }

    return YES;
}

@end