#import <Foundation/Foundation.h>

@class DYDebugSnapshot;

typedef NS_ENUM(NSInteger, DYDebugExportScope) {
    DYDebugExportScopeCurrentPage  = 0,   // 本页：当前 VC 链 + 视图树
    DYDebugExportScopeCurrentApp   = 1,   // 当前 App：进程里全部类
    DYDebugExportScopeCurrentAudio = 2,   // 音频：与音频相关的类
};

@interface DYDebugExport : NSObject

/// 按指定范围导出。
+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 scope:(DYDebugExportScope)scope
                 error:(NSError **)error;

/// 保留旧接口，等价于 DYDebugExportScopeCurrentApp。
+ (BOOL)exportSnapshot:(DYDebugSnapshot *)snapshot
                 error:(NSError **)error;

@end