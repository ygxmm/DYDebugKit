#import "DKAudioProbe.h"

@implementation DKAudioProbeCapture
@end

const NSInteger DKAudioProbeWarmupSeconds = 2;
const NSInteger DKAudioProbeRecordSeconds = 5;
const NSInteger DKAudioProbeTotalSeconds = 7;

void DKWriteAudioFiles(id sink, DKAudioProbeCapture *capture, id progress) {
    // 音频导出禁用，空实现
}
