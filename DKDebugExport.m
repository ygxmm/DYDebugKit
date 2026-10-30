//
//  DKDebugExport.m
//  DYKiller
//
//  只处理不可变采集结果的序列化、类元数据导出与 ZIP 打包。
//
//  两条硬规矩：
//  · 收集到的文件数有上限，超了就截断并在 manifest 标记，不把失败留给打包那一步。
//  · 打包失败时保留工作目录并把路径回传，错误信息里带上 underlying —— 唯一能
//    解释失败原因的东西不能跟着失败一起消失。
//

#ifndef DK_VERSION
#define DK_VERSION @"1.0.0"
#endif

#import "DKDebugExport.h"
#import "DKDebugCapture.h"
#import <mach-o/dyld.h>
#import "DKStaticClassDump.h"
#import "DKAudioProbe.h"
#import "DKClassDump.h"
#import "DKZipWriter.h"

NSString *const DKDebugExportWorkingDirectoryKey = @"DKDebugExportWorkingDirectory";

static NSString *const DKExportErrorDomain = @"com.dykiller.debug-export";

// 单个导出包的文件数上限。页面导出约 200 个、音频导出约 15 个，
// 这道闸门只用来防止将来某处再写出失控的循环。
static const NSUInteger kDKMaxExportFiles = 500000;

@implementation DKDebugExportResult
@end

#pragma mark - 写入汇集器

// 把「文件清单 + 错误清单 + 关键失败标记 + 截断计数」收在一起，
// 免得每个写入函数都拖着四个 out 参数。
@interface DKExportSink : NSObject
@property (nonatomic, copy) NSString *rootDir;
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *errors;
@property (nonatomic, assign) BOOL criticalFailed;
@property (nonatomic, assign) NSUInteger droppedFiles;
@end

@implementation DKExportSink

- (instancetype)initWithRootDir:(NSString *)rootDir {
    if ((self = [super init])) {
        _rootDir = [rootDir copy];
        _files = [NSMutableArray array];
        _errors = [NSMutableArray array];
    }
    return self;
}

@end

#pragma mark - 文件工具

static NSError *DKMakeExportError(NSInteger code, NSString *message, NSError *underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message ?: @"导出失败"
                                                                   forKey:NSLocalizedDescriptionKey];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:DKExportErrorDomain code:code userInfo:info];
}

static NSString *DKSafeFileName(NSString *name) {
    if (!name.length) return @"Unknown";
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:"];
    NSString *safe = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    return safe.length ? safe : @"Unknown";
}

static NSString *DKImageNameForClass(Class cls) {
    if (!cls) return @"Unknown";
    const char *img = class_getImageName(cls);
    if (!img) return @"Unknown";
    NSString *path = [NSString stringWithUTF8String:img];
    if (!path.length) return @"Unknown";
    // App-only filter: skip system frameworks/dylibs
    BOOL isAppImage = [path containsString:@"/containers/Bundle/Application/"]
                   || [path containsString:@"/.jbroot-"]
                   || [path containsString:@"/TweakInject/"];
    if (!isAppImage) return @"";   // system image -> empty -> caller skips
    NSString *last = path.lastPathComponent;
    if ([last hasSuffix:@".dylib"]) last = [last stringByDeletingPathExtension];
    if (last.length == 0) return @"Unknown";
    return DKSafeFileName(last);
}

static NSString *DKUniqueFileStem(NSString *name) {
    NSString *safe = DKSafeFileName(name);
    if (safe.length > 160) {
        NSRange range = [safe rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 160)];
        safe = [safe substringWithRange:range];
    }
    NSData *utf8 = [(name ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
    uint64_t hash = 1469598103934665603ULL;
    const uint8_t *bytes = utf8.bytes;
    for (NSUInteger i = 0; i < utf8.length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%@-%08llx", safe, (unsigned long long)(hash & 0xffffffffULL)];
}

static void DKRecordError(DKExportSink *sink,
                          NSString *relativePath,
                          NSString *stage,
                          NSError *error,
                          BOOL critical) {
    [sink.errors addObject:@{
        @"path": relativePath ?: @"",
        @"stage": stage ?: @"write",
        @"critical": @(critical),
        @"domain": error.domain ?: @"",
        @"code": @(error.code),
        @"message": error.localizedDescription ?: @"unknown error",
    }];
}

static BOOL DKWriteData(DKExportSink *sink, NSString *relativePath, NSData *data, BOOL critical) {
    if (sink.files.count >= kDKMaxExportFiles) {
        sink.droppedFiles++;
        return NO;
    }

    NSString *path = [sink.rootDir stringByAppendingPathComponent:relativePath];
    NSError *writeError = nil;
    NSString *directory = path.stringByDeletingLastPathComponent;
    BOOL ok = data && [NSFileManager.defaultManager createDirectoryAtPath:directory
                                              withIntermediateDirectories:YES
                                                               attributes:nil
                                                                    error:&writeError];
    if (ok) ok = [data writeToFile:path options:NSDataWritingAtomic error:&writeError];
    if (ok) {
        [sink.files addObject:path];
        return YES;
    }
    if (!writeError) writeError = DKMakeExportError(10, @"没有可写入的数据", nil);
    DKRecordError(sink, relativePath, @"write", writeError, critical);
    if (critical) sink.criticalFailed = YES;
    return NO;
}

static BOOL DKWriteString(DKExportSink *sink, NSString *relativePath, NSString *string, BOOL critical) {
    return DKWriteData(sink, relativePath, [(string ?: @"") dataUsingEncoding:NSUTF8StringEncoding], critical);
}

static BOOL DKWriteJSON(DKExportSink *sink, NSString *relativePath, id object, BOOL critical) {
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{}
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (!data) {
        DKRecordError(sink, relativePath, @"json",
                      jsonError ?: DKMakeExportError(11, @"JSON 序列化失败", nil), critical);
        if (critical) sink.criticalFailed = YES;
        return NO;
    }
    return DKWriteData(sink, relativePath, data, critical);
}

static NSString *DKModeName(DKDebugExportMode mode) {
    if (mode == DKDebugExportModeAudio) return @"audio";
    if (mode == DKDebugExportModeAllClasses) return @"all-classes";
    return @"page";
}

#pragma mark - README

static NSString *DKReadme(DKDebugExportContext *context, DKDebugExportMode mode) {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"DYKiller Debug Export\n"];
    [text appendFormat:@"Generated: %@\n", context.metadata[@"generatedAt"] ?: @""];
    [text appendFormat:@"tzyhb: %@\n", DK_VERSION];
    [text appendFormat:@"Bundle: %@\n", context.metadata[@"bundleIdentifier"] ?: @""];
    [text appendFormat:@"App: %@ %@ (%@)\n",
     context.metadata[@"bundleName"] ?: @"", context.metadata[@"appVersion"] ?: @"",
     context.metadata[@"buildVersion"] ?: @""];
    [text appendFormat:@"System: %@ %@\n", context.metadata[@"systemName"] ?: @"",
     context.metadata[@"systemVersion"] ?: @""];
    [text appendFormat:@"Mode: %@\n\n", DKModeName(mode)];

    if (mode == DKDebugExportModeAllClasses) {
        [text appendString:@"Contents:\n"];
        [text appendString:@"- classes/          全部 ObjC 类头文件（按所属二进制分目录）\n"];
        [text appendString:@"- page/             本页 UI 主线程快照与本页类\n"];
        [text appendString:@"- probe/tabbar.txt  底栏现场\n"];
        [text appendString:@"- ui/screenshot.png 目标窗口截图\n"];
    } else if (mode == DKDebugExportModeAudio) {
        DKAudioProbeCapture *capture = context.audioCapture;
        [text appendString:@"Contents:\n"];
        [text appendString:@"- audio/session.json        采样前后的 AVAudioSession 快照\n"];
        [text appendString:@"- audio/backends.json       输出单元/队列登记表与只读旁路状态\n"];
        [text appendString:@"- audio/timeline.jsonl      实时层与 AVFoundation 事件时间线\n"];
        [text appendString:@"- audio/signal.jsonl        30 Hz 的 RMS/峰值/频谱带时间序列\n"];
        [text appendString:@"- audio/media-snapshots.json 0/2.5/5 秒的播放状态\n"];
        [text appendString:@"- audio/glass-target.json   玻璃底栏几何\n"];
        [text appendString:@"- audio/diagnostics.json    符号覆盖、丢帧与自检结果\n"];
        [text appendString:@"- audio/pcm/                单声道 Float32 WAV 与各自的格式统计\n"];
        [text appendString:@"- probe/tabbar.txt          底栏现场\n- ui/screenshot.png\n\n"];
        [text appendFormat:@"采样阶段固定为 %ld 秒稳定、%ld 秒 PCM、%ld 秒收尾。探针不会改变播放状态。\n",
         (long)DKAudioProbeWarmupSeconds, (long)DKAudioProbeRecordSeconds,
         (long)(DKAudioProbeTotalSeconds - DKAudioProbeWarmupSeconds - DKAudioProbeRecordSeconds)];
        [text appendFormat:@"用户标记: %@\n实际推断: %@\n", capture.declaredState ?: @"unknown",
         capture.actualState ?: @"unknown"];
    } else {
        [text appendString:@"Contents:\n- page/: UI 主线程快照与本页类\n"];
        [text appendString:@"- probe/tabbar.txt: 占位（tabbar 采集已回滚，见 README 第六节）\n- ui/: 目标窗口截图\n"];
    }
        // DK_README_DETAIL: 每次导出自动附带的文件级说明
    [text appendString:
        @"\n"
        "============================================================\n"
        "以下为文件级说明（给 AI / 人直接读取，以 page 模式为主）\n"
        "============================================================\n"
        "\n"
        "一、目录结构\n"
        "------------\n"
        "manifest.json              采集元数据 + 完整性自检\n"
        "page/\n"
        "  classes/*.h              运行时按需 dump 的头文件，一个类一个文件\n"
        "  view-controllers.txt     VC 树文本\n"
        "  view-tree.json           视图树 JSON\n"
        "  interactives.txt         可点击元素：UIControl / 手势 view，含 target-action\n"
        "  texts.txt                所有文字：UILabel/YYLabel/DUXBaseLabel/UIButton title 等\n"
        "  images.txt               所有 UIImageView：尺寸/帧数/scale/identifier\n"
        "  responders.txt           可交互元素的响应链：view > cell > VC > window\n"
        "probe/\n"
        "  tabbar.txt               tabbar 现场（当前为兜底占位，见第六节）\n"
        "  audio-summary.txt        音频摘要\n"
        "ui/\n"
        "  screenshot.png           目标窗口截图\n"
        "\n"
        "二、manifest.json 关键字段\n"
        "--------------------------\n"
        "device.appVersion / buildVersion   抖音 App Store 版本\n"
        "device.generatedAt                 采集时间\n"
        "device.deviceModel / systemVersion 设备与系统\n"
        "device.screenBounds                屏幕尺寸\n"
        "device.targetWindow                目标窗口：class/frame/level/keyWindow/rootVC\n"
        "device.tapPointInTargetWindow      触发探针的点击点\n"
        "integrity.complete                 1=完整，0=有缺\n"
        "integrity.truncated                是否被截断\n"
        "integrity.droppedFiles             丢弃文件数\n"
        "integrity.errorCount / errors      错误列表\n"
        "integrity.fileCount / fileLimit    文件数 / 上限\n"
        "mode                               \"page\" / \"all-classes\" / \"audio\"\n"
        "schemaVersion                      \"dykiller.debug.v2\"\n"
        "\n"
        "注意：\n"
        "- targetWindow 若是 DYKillerOverlayWindow，说明采集时拿的是自己的浮层，\n"
        "  不是抖音 keyWindow，tabbar/截图可能不准。\n"
        "- tapPointInTargetWindow 为 {0,0} 说明没有有效点击目标。\n"
        "\n"
        "三之补、page/*.txt 各文件说明（DK_README_NEW_FILES）\n"
        "----------------------------------------------------\n"
        "interactives.txt：每个可点击元素一行，格式\n"
        "  Class frame=... hidden=N enabled=Y/N id=... label=... title=... targets=Target:selector gestures=Gesture{Target:selector}\n"
        "  只看 targets 列就能找到按钮点击后调哪个方法\n"
        "\n"
        "texts.txt：每个带文字的 view 一行，格式\n"
        "  Class frame=... text=...\n"
        "  覆盖原生 UILabel 和自定义 Label（YYLabel/DUXBaseLabel/AWEUserNameLabel/TTTAttributedLabel 等）\n"
        "  长文本截断到 200 字符，换行转义为 \\n\n"
        "images.txt：每个 UIImageView 一行，格式\n"
        "  Class frame=... hidden=N image={W,H} frames=N scale=N id=... label=...\n"
        "  frames=0 表示静态图，frames>1 表示 GIF/序列帧动画\n"
        "\n"
        "responders.txt：每个可交互元素一行，格式\n"
        "  Class frame=... chain=View > Superview > ... > VC > Window\n"
        "  看 chain 列就能知道按钮点击后事件传到哪个 VC\n"
        "\n"
        "所有 page/*.txt 缩进最大 8 层（16 空格），层深超过 8 的不再缩进\n"
        "\n"
        "三、page/classes/*.h\n"
        "--------------------\n"
        "运行时按需 dump 的头文件，只含当前页面链路出现过的类，不在链路就没有。\n"
        "文件头三行：\n"
        "  // Dumped by DYKiller DKClassDump\n"
        "  // Bundle: com.ss.iphone.ugc.Aweme\n"
        "  // Image: AwemeCore\n"
        "结构：@interface 类名 : 父类 <协议列表> { ivar } 属性 方法 @end，\n"
        "可能内联 @protocol（会多出多个 @end，正常）。\n"
        "\n"
        "类型保真度（AI 必读）：\n"
        "  保留：属性名、读写性、内存修饰、多数具体类名、\n"
        "        UIView<Protocol> / UITableViewCell<Protocol> 的协议、\n"
        "        id<Protocol> 的协议（已修，DK_PROTO_FALLBACK）\n"
        "  退化：方法返回/参数类型多为 id（runtime 限制，classdump 一样）\n"
        "        block 属性为 id /* block */（@? 已识别；@?<...> 可还原 ret (^)(args)）\n"
        "        @class / @protocol 前向声明已生成（自 a11a145 起）\n"
        "        NSObject 属性混入子类（hash/superclass/description/debugDescription）\n"
        "  使用：\n"
        "    查方法名 → 可信\n"
        "    查参数具体类型 → 不可信，去 classdump1 或 runtime 查\n"
        "    #import 整份 → 大部分已可，极少数系统框架类仍缺，缺了补 #import\n"
        "    hook → NSClassFromString + class_getInstanceMethod，不依赖头文件\n"
        "\n"
        "四、page/view-controllers.txt\n"
        "-----------------------------\n"
        "每行一个 VC：缩进 类名 指针 viewLoaded=YES/NO view=视图类 指针 frame=...\n"
        "子行 nav.top= / nav.visible= / tab.selected= / presented:\n"
        "用途：看页面层级、前台 VC、frame 是否正常（0/NaN 说明布局没完成）。\n"
        "\n"
        "五、page/view-tree.json\n"
        "-----------------------\n"
        "视图树 JSON，节点含 class/frame/子节点。用途：精确查某 view 的类名/层级/frame。\n"
        "\n"
        "六、probe/tabbar.txt（当前状态：兜底占位）\n"
        "------------------------------------------\n"
        "内容为 \"tabbar not captured: probeText is empty\"。\n"
        "原因：采集端从未给 probeText 赋值（声明了但无实现）。\n"
        "含义：不是写入失败，是采集逻辑缺失。\n"
        "与头部 Contents 里 \"液态玻璃底栏现场\" 的描述不符，以本节为准。\n"
        "真采集需改 DKDebugCapture.m 遍历 tabbar 并赋值。\n"
        "\n"
        "七、probe/audio-summary.txt\n"
        "---------------------------\n"
        "音频摘要（capture.summaryText）。用途：看当前音频/播放状态摘要。\n"
        "\n"
        "八、ui/screenshot.png\n"
        "---------------------\n"
        "目标窗口截图，按 windowLevel 从低到高合成，尽量等于用户所见。\n"
        "若 targetWindow 是 DYKillerOverlayWindow，截图可能含浮层或不是抖音画面。\n"
        "\n"
        "九、AI 使用顺序\n"
        "---------------\n"
        "1. manifest.json → 确认版本、时间、完整性、targetWindow 是否正常\n"
        "2. page/view-controllers.txt → 找目标 VC 及 frame\n"
        "3. page/classes/<目标类>.h → 看属性/方法名\n"
        "4. page/view-tree.json → 定位具体子视图\n"
        "5. 查参数具体类型 → runtime 和 classdump 都只能给 id，需看源码或 dSYM\n"
        "6. 查某个类在不在二进制里（不运行 App 时）→ classdump1/AwemeCore/*.h\n"
        "6. probe/tabbar.txt 是占位，不要当真实数据\n"
        "\n"
        "十、常见坑\n"
        "----------\n"
        "- 目标类不在 page/classes/ → 本次链路没出现，重进对应页面再导\n"
        "- 属性是裸 id → 可能是 block，或源码真裸 id，不是协议丢失\n"
        "- 文件里多个 @end → 内联 @protocol，正常\n"
        "- 协议列表有重复 → 二进制真实状态，探针与 classdump 都这样\n"
        "- #import 整份 .h 报错 → 前向声明已生成，若仍报错则是缺系统框架，补 #import 即可\n"
    ];
return text;
}

#pragma mark - 页面内容

static void DKWritePageClasses(DKExportSink *sink, NSArray<NSString *> *classNames) {
    for (NSString *name in [classNames sortedArrayUsingSelector:@selector(compare:)]) {
        @autoreleasepool {
            @try {
                Class cls = NSClassFromString(name);
                NSString *header = cls ? DKClassDumpHeaderForClass(cls) : nil;
                if (!header.length) continue;
                NSString *relative = [@"page/classes" stringByAppendingPathComponent:
                                      [DKSafeFileName(name) stringByAppendingString:@".h"]];
                DKWriteString(sink, relative, header, NO);
            } @catch (NSException *exception) {
                DKRecordError(sink, name, @"page-class",
                              DKMakeExportError(20, exception.reason ?: @"类头文件导出异常", nil), NO);
            }
        }
    }
}

static void DKWritePageFiles(DKExportSink *sink,
                             DKDebugExportContext *context,
                             void (^progress)(NSString *text)) {
    if (progress) progress(@"写入页面结构...");
    DKWriteJSON(sink, @"page/windows.json", context.windowsJSON ?: @[], NO);
        NSArray *swiftArr = DKGetCapturedPageSwiftClasses();
    if (swiftArr.count > 0) {
        swiftArr = [swiftArr sortedArrayUsingSelector:@selector(compare:)];
        NSString *swiftStr = [swiftArr componentsJoinedByString:@"\n"];
        DKWriteString(sink, @"page/swift_classes.txt", swiftStr, NO);
    } else {
        DKWriteString(sink, @"page/swift_classes.txt", @"(当前页面未抓取到 Swift 类)", NO);
    }
    
DKWriteString(sink, @"page/view-tree.txt", context.viewTreeText, NO);
    DKWriteJSON(sink, @"page/view-tree.json", context.viewTreeJSON ?: @[], NO);
    DKWriteJSON(sink, @"page/selected-view.json", context.selectedViewJSON ?: @{}, NO);
    DKWriteString(sink, @"page/view-controllers.txt", context.viewControllersText, NO);
    DKWriteJSON(sink, @"page/layers.json", context.layersJSON ?: @[], NO);
    DKWriteString(sink, @"page/interactives.txt", context.interactivesText ?: @"(empty)\n", NO); // DK_FEATURE_EXPORT
    DKWriteString(sink, @"page/texts.txt", context.textsText ?: @"(empty)\n", NO);
    DKWriteString(sink, @"page/images.txt", context.imagesText ?: @"(empty)\n", NO); // DK_FEATURE_IMAGES
    DKWriteString(sink, @"page/responders.txt", context.respondersText ?: @"(empty)\n", NO); // DK_FEATURE_RESPONDERS
    if (progress) progress(@"导出本页类头文件...");
    DKWritePageClasses(sink, context.pageClassNames ?: @[]);
}

#pragma mark - 全部类导出

static void DKWriteAllClasses(DKExportSink *sink, void (^progress)(NSString *text)) {
    if (progress) progress(@"读取运行时类列表...");
    int count = objc_getClassList(NULL, 0);
    if (progress) progress([NSString stringWithFormat:@"运行时共 %d 个类，开始写入...", count]);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return;
    int actual = objc_getClassList(classes, count);
    if (actual < count) count = actual;

    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:(NSUInteger)count];
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; i++) {
        @autoreleasepool {
            Class cls = classes[i];
            NSString *name = NSStringFromClass(cls);
            if (!name.length) continue;
            if ([seen containsObject:name]) continue;
            [seen addObject:name];
            [names addObject:name];
        }
    }
    free(classes);

    // iOS 16+ future class 兜底：
    //   objc_getClassList 只返回已注册的类。iOS 16 引入 objc_setFutureClass 机制，
    //   二进制里定义的类在首次使用前不会注册，抖音等巨型 App 会丢 40%+ 的类。
    //   objc_copyClassNamesForImage 直接读 image 的 __objc_classlist 段，能看到全部类名。
    if (progress) progress(@"补全 future class（iOS 16+）...");
    {
        uint32_t imgCount = _dyld_image_count();
        NSUInteger futureAdded = 0;
        for (uint32_t img = 0; img < imgCount; img++) {
            @autoreleasepool {
                const char *imgName = _dyld_get_image_name(img);
                if (!imgName) continue;
                unsigned int classCount = 0;
                const char **classNames = objc_copyClassNamesForImage(imgName, &classCount);
                if (!classNames) continue;
                for (unsigned int i = 0; i < classCount; i++) {
                    const char *cName = classNames[i];
                    if (!cName) continue;
                    NSString *name = [NSString stringWithUTF8String:cName];
                    if (!name.length) continue;
                    if ([seen containsObject:name]) continue;
                    [seen addObject:name];
                    [names addObject:name];
                    futureAdded++;
                }
                free(classNames);
            }
        }
        if (progress) progress([NSString stringWithFormat:@"future class 补全 %lu 个，总计 %lu 个",
                                (unsigned long)futureAdded, (unsigned long)names.count]);
    }

    if (progress) progress([NSString stringWithFormat:@"写入全部类头文件（%lu 个）...", (unsigned long)names.count]);
    NSArray<NSString *> *sorted = [names sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger written = 0;
    for (NSString *name in sorted) {
        @autoreleasepool {
            @try {
                Class cls = NSClassFromString(name);
                NSString *header = cls ? DKClassDumpHeaderForClass(cls) : nil;
                if (!header.length) continue;
                NSString *imageName = DKImageNameForClass(cls);
                if (!imageName.length) continue;
                if ([imageName isEqualToString:@"tzyhb"]) continue;
                NSString *relative = [@"classes" stringByAppendingPathComponent:
                                      [imageName stringByAppendingPathComponent:
                                       [DKSafeFileName(name) stringByAppendingString:@".h"]]];
                DKWriteString(sink, relative, header, NO);

                // 追加 category 头文件（边遍历边写，不累积）

                written++;
                if (progress && (written % 200) == 0) {
                    double pct = names.count > 0 ? (written * 100.0 / (double)names.count) : 0.0;
                    progress([NSString stringWithFormat:@"已导出 %lu / %lu（%.1f%%）",
                              (unsigned long)written, (unsigned long)names.count, pct]);
                }
            } @catch (NSException *exception) {
                DKRecordError(sink, name, @"all-class",
                              DKMakeExportError(20, exception.reason ?: @"类头文件导出异常", nil), NO);
            }
        }
    }
    if (progress) progress([NSString stringWithFormat:@"全部类导出完成：%lu 个", (unsigned long)written]);

    // ===== 静态解析 category（补充运行时拿不到的信息） =====
    if (progress) progress(@"静态解析 category...");
    NSString *binaryPath = NSBundle.mainBundle.executablePath;
    if (binaryPath.length > 0) {
        __block NSUInteger catCount = 0;
        DKStaticDumpCategories(binaryPath, ^(NSString *className, NSString *categoryName, NSString *text) {
            if (!className || !categoryName || !text) return;
            NSString *safeClass = DKSafeFileName(className);
            NSString *safeCat = DKSafeFileName(categoryName);
            NSString *relative = [NSString stringWithFormat:@"classes/categories/%@+%@.h", safeClass, safeCat];
            DKWriteString(sink, relative, text, NO);
            catCount++;
            if (progress && (catCount % 100) == 0) {
                progress([NSString stringWithFormat:@"已解析 %lu 个 category...", (unsigned long)catCount]);
            }
        });
        if (progress) progress([NSString stringWithFormat:@"category 解析完成：%lu 个", (unsigned long)catCount]);
    }
}

#pragma mark - 音频内容

static void DKWriteAudioFiles(DKExportSink *sink,
                              DKAudioProbeCapture *capture,
                              void (^progress)(NSString *text)) {
    if (progress) progress(@"写入音频采集结果...");
    // 这九项是音频导出的全部意义所在，任何一项写不出去都该让导出失败，
    // 而不是交出一个看起来成功、其实缺内容的包。
    DKWriteString(sink, @"probe/audio-summary.txt", capture.summaryText, YES);
    DKWriteJSON(sink, @"audio/session.json", capture.sessionJSON ?: @{}, YES);
    DKWriteJSON(sink, @"audio/backends.json", capture.backendsJSON ?: @[], YES);
    DKWriteString(sink, @"audio/timeline.jsonl", capture.timelineJSONL, YES);
    DKWriteString(sink, @"audio/signal.jsonl", capture.signalJSONL, YES);
    DKWriteJSON(sink, @"audio/media-snapshots.json", capture.mediaSnapshotsJSON ?: @[], YES);
    DKWriteJSON(sink, @"audio/glass-target.json", capture.glassTargetJSON ?: @{}, YES);
    DKWriteJSON(sink, @"audio/diagnostics.json", capture.diagnosticsJSON ?: @{}, YES);

    for (NSDictionary *pcm in capture.pcmFiles ?: @[]) {
        NSString *fileName = DKSafeFileName([pcm[@"fileName"] description]);
        NSData *data = [pcm[@"data"] isKindOfClass:NSData.class] ? pcm[@"data"] : nil;
        NSDictionary *metadata = [pcm[@"metadata"] isKindOfClass:NSDictionary.class] ? pcm[@"metadata"] : @{};
        DKWriteData(sink, [@"audio/pcm" stringByAppendingPathComponent:fileName], data, NO);
        NSString *jsonName = [[fileName stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
        DKWriteJSON(sink, [@"audio/pcm" stringByAppendingPathComponent:jsonName], metadata, NO);
    }
}

#pragma mark - 导出入口

DKDebugExportResult *DKDebugCreateExport(DKDebugExportContext *context,
                                         DKDebugExportMode mode,
                                         void (^progress)(NSString *text),
                                         NSError **error) {
    if (!context || (mode == DKDebugExportModeAudio && !context.audioCapture)) {
        if (error) *error = DKMakeExportError(1, @"导出上下文不完整", nil);
        return nil;
    }

    NSString *state = mode == DKDebugExportModeAudio ? (context.audioCapture.declaredState ?: @"unknown") : @"";
    NSString *suffix = state.length ? [NSString stringWithFormat:@"-%@", DKSafeFileName(state)] : @"";
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"Unknown";
    NSString *rootName = [NSString stringWithFormat:@"DYKiller-Debug-%@%@-%lld",
                          DKModeName(mode), suffix,
                          (long long)NSDate.date.timeIntervalSince1970];
    NSString *cacheRoot = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (cacheRoot.length == 0) cacheRoot = NSTemporaryDirectory();
    NSString *appDir = [[cacheRoot stringByAppendingPathComponent:@"DYKiller"] stringByAppendingPathComponent:DKSafeFileName(bid)];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:appDir withIntermediateDirectories:YES attributes:nil error:nil];

    // 自动清理：每个 app 目录只保留最近 3 份导出，避免垃圾累积
    NSArray<NSString *> *existingNames = [fm contentsOfDirectoryAtPath:appDir error:nil];
    NSMutableArray<NSString *> *oldDirs = [NSMutableArray array];
    for (NSString *n in existingNames) {
        NSString *p = [appDir stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) [oldDirs addObject:p];
    }
    [oldDirs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a];
    }];
    for (NSUInteger i = 3; i < oldDirs.count; i++) {
        [fm removeItemAtPath:oldDirs[i] error:nil];
    }

    NSString *rootDir = [appDir stringByAppendingPathComponent:rootName];
    NSString *zipPath = [appDir stringByAppendingPathComponent:[rootName stringByAppendingString:@".zip"]];
    [fm removeItemAtPath:rootDir error:nil];
    [fm removeItemAtPath:zipPath error:nil];

    NSError *directoryError = nil;
    if (![fm createDirectoryAtPath:rootDir withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        if (error) *error = DKMakeExportError(2, @"无法创建导出目录", directoryError);
        return nil;
    }

    DKExportSink *sink = [[DKExportSink alloc] initWithRootDir:rootDir];
    DKWriteString(sink, @"README.txt", DKReadme(context, mode), mode == DKDebugExportModeAudio);
    DKWriteData(sink, @"ui/screenshot.png", context.screenshotPNG, NO);
    NSString *tabbarText = context.probeText.length ? context.probeText : @"tabbar not captured: probeText is empty\n"; // DK_TABBAR_FALLBACK
    DKWriteString(sink, @"probe/tabbar.txt", tabbarText, NO);

    if (mode == DKDebugExportModeAudio) {
        DKWriteAudioFiles(sink, context.audioCapture, progress);
    } else if (mode == DKDebugExportModeAllClasses) {
        DKWriteAllClasses(sink, progress);
        DKWritePageFiles(sink, context, progress);
    } else {
        DKWritePageFiles(sink, context, progress);
    }

    NSDictionary *manifest = @{
        @"schemaVersion": mode == DKDebugExportModeAudio ? @"dykiller.audio-probe.v2" : @"dykiller.debug.v2",
        @"mode": DKModeName(mode),
        @"dykillerVersion": DK_VERSION,
        @"device": context.metadata ?: @{},
        @"declaredState": context.audioCapture.declaredState ?: @"not-applicable",
        @"actualState": context.audioCapture.actualState ?: @"not-applicable",
        @"sampling": mode == DKDebugExportModeAudio ? @{
            @"totalSeconds": @(DKAudioProbeTotalSeconds),
            @"warmupSeconds": @(DKAudioProbeWarmupSeconds),
            @"recordSeconds": @(DKAudioProbeRecordSeconds),
            @"snapshotsAtSeconds": @[ @0, @2.5, @5 ],
        } : @{},
        @"integrity": @{
            @"complete": @(!sink.criticalFailed && sink.droppedFiles == 0),
            @"status": sink.criticalFailed ? @"critical-failure"
                     : (sink.droppedFiles ? @"truncated"
                     : (sink.errors.count ? @"complete-with-recoverable-errors" : @"complete")),
            @"fileCount": @(sink.files.count),
            @"fileLimit": @(kDKMaxExportFiles),
            @"truncated": @(sink.droppedFiles > 0),
            @"droppedFiles": @(sink.droppedFiles),
            @"errorCount": @(sink.errors.count),
            @"errors": sink.errors,
        },
    };
    DKWriteJSON(sink, @"manifest.json", manifest, mode == DKDebugExportModeAudio);

    if (sink.criticalFailed) {
        if (error) {
            *error = [NSError errorWithDomain:DKExportErrorDomain code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"关键文件写入失败，工作目录已保留",
                DKDebugExportWorkingDirectoryKey: rootDir,
            }];
        }
        return nil;
    }

    if (progress) progress(@"压缩 zip...");
    NSError *zipError = nil;
    BOOL zipped = sink.files.count > 0 && [DKZipWriter createZipAtPath:zipPath
                                                              rootDir:rootDir
                                                                files:sink.files
                                                             progress:nil
                                                                error:&zipError];
    NSError *attributeError = nil;
    NSDictionary *attributes = zipped ? [fm attributesOfItemAtPath:zipPath error:&attributeError] : nil;
    NSNumber *zipSize = attributes[NSFileSize];
    if (!zipped || zipError || attributeError || zipSize.unsignedLongLongValue <= 22) {
        NSError *underlying = zipError ?: attributeError;
        NSString *message = underlying
            ? [NSString stringWithFormat:@"ZIP 生成失败（%lu 个待打包文件）：%@",
               (unsigned long)sink.files.count, underlying.localizedDescription]
            : [NSString stringWithFormat:@"ZIP 未生成或内容为空（%lu 个待打包文件）",
               (unsigned long)sink.files.count];
        [fm removeItemAtPath:zipPath error:nil];
        // 工作目录留着：它是唯一能解释这次失败的现场。
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:@{
            NSLocalizedDescriptionKey: message,
            DKDebugExportWorkingDirectoryKey: rootDir,
        }];
        if (underlying) info[NSUnderlyingErrorKey] = underlying;
        if (error) *error = [NSError errorWithDomain:DKExportErrorDomain code:4 userInfo:info];
        return nil;
    }

    DKDebugExportResult *result = [DKDebugExportResult new];
    result.zipURL = [NSURL fileURLWithPath:zipPath];
    result.workingDirectoryURL = [NSURL fileURLWithPath:rootDir isDirectory:YES];
    return result;
}

void DKDebugCleanupExport(DKDebugExportResult *result) {
    if (!result) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (result.workingDirectoryURL.isFileURL) [fm removeItemAtURL:result.workingDirectoryURL error:nil];
    if (result.zipURL.isFileURL) [fm removeItemAtURL:result.zipURL error:nil];
}
// DK_README_V3
