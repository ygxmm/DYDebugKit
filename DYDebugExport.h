#import <Foundation/Foundation.h>

@class DYDebugSnapshot;

typedef NS_ENUM(NSInteger, DYDebugExportScope) {
    DYDebugExportScopeCurrentPage  = 0,
    DYDebugExportScopeCurrentApp   = 1,
    DYDebugExportScopeCurrentAudio = 2,
};

@interface DYDebugExport : NSObject

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 scope:(DYDebugExportScope)scope
                 error:(NSError **)error;

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 error:(NSError **)error;

@end