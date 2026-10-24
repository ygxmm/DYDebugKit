// 最小 stub：满足 DKDebugExport.m 的类型依赖
#import <Foundation/Foundation.h>

@interface DKAudioProbeCapture : NSObject
@property (nonatomic, copy) NSString *declaredState;
@property (nonatomic, copy) NSString *actualState;
@end

extern const NSInteger DKAudioProbeWarmupSeconds;
extern const NSInteger DKAudioProbeRecordSeconds;
extern const NSInteger DKAudioProbeTotalSeconds;

void DKWriteAudioFiles(id sink, DKAudioProbeCapture *capture, id progress);
