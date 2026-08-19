#import "DYDebugExport.h"
#import "DYDebugCapture.h"

@implementation DYDebugExport

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                  toURL:(NSURL *)directoryURL
                  error:(NSError **)error
{
    if (snapshot == nil || directoryURL == nil) {
        if (error) {
            *error = [NSError errorWithDomain:@"DYDebugKit"
                                          code:1
                                      userInfo:@{
                NSLocalizedDescriptionKey: @"Snapshot or destination directory is nil."
            }];
        }
        return NO;
    }

    NSString *root = directoryURL.path;

    if (root.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"DYDebugKit"
                                          code:2
                                      userInfo:@{
                NSLocalizedDescriptionKey: @"Destination directory is invalid."
            }];
        }
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];

    BOOL isDirectory = NO;
    BOOL exists = [fileManager fileExistsAtPath:root
                                    isDirectory:&isDirectory];

    if (!exists) {
        NSError *directoryError = nil;

        BOOL created = [fileManager createDirectoryAtPath:root
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&directoryError];

        if (!created) {
            if (error) {
                *error = directoryError;
            }
            return NO;
        }
    } else if (!isDirectory) {
        if (error) {
            *error = [NSError errorWithDomain:@"DYDebugKit"
                                          code:3
                                      userInfo:@{
                NSLocalizedDescriptionKey: @"Destination path is not a directory."
            }];
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

    BOOL treeOK =
        [viewTreeData writeToFile:viewTreePath atomically:YES];

    if (!treeOK) {
        if (error) {
            *error = [NSError errorWithDomain:@"DYDebugKit"
                                          code:4
                                      userInfo:@{
                NSLocalizedDescriptionKey:
                    @"Failed to write view-tree.txt."
            }];
        }
        return NO;
    }

    BOOL controllersOK =
        [viewControllersData writeToFile:viewControllersPath
                               atomically:YES];

    if (!controllersOK) {
        if (error) {
            *error = [NSError errorWithDomain:@"DYDebugKit"
                                          code:5
                                      userInfo:@{
                NSLocalizedDescriptionKey:
                    @"Failed to write view-controllers.txt."
            }];
        }
        return NO;
    }

    return YES;
}

@end