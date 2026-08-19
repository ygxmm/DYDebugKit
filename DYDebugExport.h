#import <Foundation/Foundation.h>

@class DYDebugSnapshot;

@interface DYDebugExport : NSObject

+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 error:(NSError **)error;

@end