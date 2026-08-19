#import "DYDebugExport.h"
#import "DYDebugCapture.h"

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
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"DYDebugKit"];

    NSFileManager *fm = [NSFileManager defaultManager];

    NSError *mkdirError = nil;

    if (![fm createDirectoryAtPath:root
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&mkdirError]) {

        if (error) {
            *error = mkdirError;
        }

        return NO;
    }

    NSString *viewTreePath =
        [root stringByAppendingPathComponent:@"view-tree.txt"];

    NSString *viewControllersPath =
        [root stringByAppendingPathComponent:@"view-controllers.txt"];

    NSData *viewTreeData =
        [snapshot.viewTree dataUsingEncoding:NSUTF8StringEncoding];

    NSData *viewControllersData =
        [snapshot.viewControllers dataUsingEncoding:NSUTF8StringEncoding];

    if (![viewTreeData writeToFile:viewTreePath
                           options:NSDataWritingAtomic
                             error:error]) {
        return NO;
    }

    if (![viewControllersData writeToFile:viewControllersPath
                                  options:NSDataWritingAtomic
                                    error:error]) {
        return NO;
    }

    return YES;
}

@end