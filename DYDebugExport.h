#import <Foundation/Foundation.h>

@class DYDebugSnapshot;

typedef NS_ENUM(NSInteger, DYDebugExportScope) {
    DYDebugExportScopeCurrentPage  = 0,
    DYDebugExportScopeCurrentApp   = 1,
    DYDebugExportScopeCurrentAudio = 2,
};

/// 导出根目录。
/// 系统 App（bundleID 以 com.apple. 开头）→ /var/mobile/Documents/DYDebugKit
/// 普通 App → App 沙盒 Documents/DYDebugKit
static inline NSString *DYDebugExportBaseDirectory(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    NSString *base = nil;
    if ([bid hasPrefix:@"com.apple."]) {
        NSString *sys = @"/var/mobile/Documents/DYDebugKit";
        if ([[NSFileManager defaultManager] createDirectoryAtPath:sys
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]) {
            base = sys;
        }
    }
    if (!base) {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask,
                                                              YES) firstObject];
        if (docs.length == 0) docs = NSTemporaryDirectory();
        base = [docs stringByAppendingPathComponent:@"DYDebugKit"];
        [[NSFileManager defaultManager] createDirectoryAtPath:base
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    return base;
}

@interface DYDebugExport : NSObject

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 scope:(DYDebugExportScope)scope
                 error:(NSError **)error;

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 error:(NSError **)error;

@end
