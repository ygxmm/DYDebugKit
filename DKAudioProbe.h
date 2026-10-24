//
// DKAudioProbe.h  —— 最小 stub，满足 DKDebugExport.m 类型依赖
// 音频功能禁用，所有属性返回 nil/空，音频档导出时产出空 JSON
//
#import <Foundation/Foundation.h>

@interface DKAudioProbeCapture : NSObject
@property (nonatomic, copy) NSString *declaredState;
@property (nonatomic, copy) NSString *actualState;
@property (nonatomic, copy) NSString *summaryText;
@property (nonatomic, strong) NSDictionary *sessionJSON;
@property (nonatomic, strong) NSArray *backendsJSON;
@property (nonatomic, copy) NSString *timelineJSONL;
@property (nonatomic, copy) NSString *signalJSONL;
@property (nonatomic, strong) NSArray *mediaSnapshotsJSON;
@property (nonatomic, strong) NSDictionary *glassTargetJSON;
@property (nonatomic, strong) NSDictionary *diagnosticsJSON;
@property (nonatomic, strong) NSArray<NSDictionary *> *pcmFiles;
@end

extern const NSInteger DKAudioProbeWarmupSeconds;
extern const NSInteger DKAudioProbeRecordSeconds;
extern const NSInteger DKAudioProbeTotalSeconds;
