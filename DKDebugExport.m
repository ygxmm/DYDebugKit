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
#import "DKStaticClassDump.h"
#import "DKAudioProbe.h"
#import "DKClassDump.h"
#import "DKZipWriter.h"

NSString *const DKDebugExportWorkingDirectoryKey = @"DKDebugExportWorkingDirectory";

static NSString *const DKExportErrorDomain = @"com.dykiller.debug-export";

// 单个导出包的文件数上限。页面导出约 200 个、音频导出约 15 个，
// 这道闸门只用来防止将来某处再写出失控的循环。
static const NSUInteger kDKMaxExportFiles = 100000;

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
        [text appendString:@"- probe/tabbar.txt: 液态玻璃底栏现场\n- ui/: 目标窗口截图\n"];
    }
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
    DKWriteString(sink, @"page/view-tree.txt", context.viewTreeText, NO);
    DKWriteJSON(sink, @"page/view-tree.json", context.viewTreeJSON ?: @[], NO);
    DKWriteJSON(sink, @"page/selected-view.json", context.selectedViewJSON ?: @{}, NO);
    DKWriteString(sink, @"page/view-controllers.txt", context.viewControllersText, NO);
    DKWriteJSON(sink, @"page/layers.json", context.layersJSON ?: @[], NO);
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
    DKWriteString(sink, @"probe/tabbar.txt", context.probeText, NO);

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
