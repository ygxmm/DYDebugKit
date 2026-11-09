//
//  TZDebugExport.m
//  tz
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

#import "TZDebugExport.h"
#import "TZDebugCapture.h"
#import <mach-o/dyld.h>
#import "TZStaticClassDump.h"
#import "TZAudioProbe.h"
#import "TZClassDump.h"
#import "TZZipWriter.h"

NSString *const TZDebugExportWorkingDirectoryKey = @"TZDebugExportWorkingDirectory";

static NSString *const DKExportErrorDomain = @"com.tz.debug-export";

// 单个导出包的文件数上限。页面导出约 200 个、音频导出约 15 个，
// 这道闸门只用来防止将来某处再写出失控的循环。
static const NSUInteger kDKMaxExportFiles = 500000;

@implementation TZDebugExportResult
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
    if (!safe.length) return @"Unknown";
    // DK_FILENAME_LEN: APFS 单文件名 255 字节上限，超长时截断 + hash 后缀
    if (safe.length > 200) {
        NSUInteger h = (NSUInteger)safe.hash;
        safe = [NSString stringWithFormat:@"%@_%08lx",
                [safe substringToIndex:190], (unsigned long)h];
    }
    return safe;
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

static NSString *DKModeName(TZDebugExportMode mode) {
    if (mode == TZDebugExportModeAudio) return @"audio";
    if (mode == TZDebugExportModeAllClasses) return @"all-classes";
    return @"page";
}

#pragma mark - README

static NSString *DKReadme(TZDebugExportContext *context, TZDebugExportMode mode) {
    NSDictionary *meta = context.metadata;
    NSMutableString *text = [NSMutableString string];
    
    [text appendFormat:@"tz Runtime Snapshot\n"];
    [text appendFormat:@"App: %@ %@ (%@) | System: %@ %@ | Time: %@\n\n",
        meta[@"bundleName"] ?: @"UnknownApp", meta[@"appVersion"], meta[@"buildVersion"], meta[@"deviceModel"], meta[@"systemVersion"], meta[@"generatedAt"]];

    [text appendString:@"============================================================\n"];
    [text appendString:@"文件说明 (Data Dictionary)\n"];
    [text appendString:@"============================================================\n\n"];

    [text appendString:@"[manifest.json]\n"];
    [text appendString:@"- 采集元数据。包含 App 版本、系统版本、屏幕尺寸、目标窗口信息。\n\n"];

    [text appendString:@"[page/] UI 主线程快照与本页类\n"];
    [text appendString:@"- view-tree.txt       视图树文本，带层级缩进，含 Class、frame、hidden、alpha。\n"];
    [text appendString:@"- view-tree.json      同上，但为 JSON 格式，适合程序解析。\n"];
    [text appendString:@"- view-controllers.txt VC 树（含 nav.top / tab.selected）。\n"];
    [text appendString:@"- interactives.txt    可点击元素（UIControl / 手势），含 Target-Action。\n"];
    [text appendString:@"- texts.txt           页面上的所有文字（UILabel/YYLabel/Button title 等）。\n"];
    [text appendString:@"- images.txt          所有 UIImageView，含尺寸、帧数、scale。\n"];
    [text appendString:@"- responders.txt      可交互元素的响应链（view -> VC -> window）。\n"];
    [text appendString:@"- classes/*.h         运行时 dump 的 Objective-C 头文件。\n"];
    [text appendString:@"  * 注：仅 dump 了当前页面链路出现过的类。\n"];
    [text appendString:@"  * 注：方法参数类型多为 id（Runtime 限制），属性名和类名可信。\n\n"];

    [text appendString:@"[probe/] 专项探针数据\n"];
    [text appendString:@"- tabbar.txt          底栏（TabBar）现场。\n"];
    [text appendString:@"  * === Summary === 段：包含可见/隐藏数量、坐标是否重叠 (visible_overlaps)、总宽。\n"];
    [text appendString:@"  * === TabBar === 段：具体视图层级、按钮名称 (label)、frame。\n\n"];

    [text appendString:@"[ui/] 视觉辅助\n"];
    [text appendString:@"- screenshot.png      目标窗口的截图（按 windowLevel 从低到高合成）。\n\n"];

    [text appendString:@"[常见排查场景]\n"];
    [text appendString:@"- 按钮不见了：看 view-tree.txt 或 tabbar.txt 里的 hidden 字段。\n"];
    [text appendString:@"- 按钮点不动：看 interactives.txt 里的 targets 列。\n"];
    [text appendString:@"- 布局错乱：看 tabbar.txt 的 Summary，检查 visible_overlaps 和 frame 值。\n"];

    return text;
}
static void DKWritePageClasses(DKExportSink *sink, NSArray<NSString *> *classNames) {
    if (!classNames || classNames.count == 0) return;
    NSArray *sortedNames = [classNames sortedArrayUsingSelector:@selector(compare:)];
    
    // 如果类数量极大（all-classes模式），采用分批合并写入，防止写几万个文件卡死
    if (sortedNames.count > 1000) {
        NSUInteger batchSize = 2000;
        NSUInteger total = sortedNames.count;
        
        for (NSUInteger i = 0; i < total; i += batchSize) {
            NSUInteger length = MIN(batchSize, total - i);
            NSArray *batch = [sortedNames subarrayWithRange:NSMakeRange(i, length)];
            
            NSMutableString *hugeStr = [NSMutableString stringWithCapacity:1024 * 1024 * 5]; // 预分配 5MB
            [hugeStr appendFormat:@"// TZ Universal Class Dump - Part %lu\n\n", (unsigned long)(i/batchSize + 1)];
            
            for (NSString *name in batch) {
                @autoreleasepool {
                    @try {
                        Class cls = NSClassFromString(name);
                        NSString *header = cls ? TZClassDumpHeaderForClass(cls) : nil;
                        if (header.length > 0) {
                            [hugeStr appendString:header];
                            [hugeStr appendString:@"\n\n"];
                        }
                    } @catch (NSException *exception) {
                        DKRecordError(sink, name, @"page-class",
                                      DKMakeExportError(20, exception.reason ?: @"类头文件导出异常", nil), NO);
                    }
                }
            }
            NSString *fileName = [NSString stringWithFormat:@"page/classes/AllClasses_Part%lu.h", (unsigned long)(i/batchSize + 1)];
            DKWriteString(sink, fileName, hugeStr, NO);
        }
    } else {
        // 页面级导出，数量少，保持一个类一个文件
        for (NSString *name in sortedNames) {
            @autoreleasepool {
                @try {
                    Class cls = NSClassFromString(name);
                    NSString *header = cls ? TZClassDumpHeaderForClass(cls) : nil;
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
}

static void DKWritePageFiles(DKExportSink *sink,
                             TZDebugExportContext *context,
                             void (^progress)(NSString *text)) {
    if (progress) progress(@"写入页面结构...");
    DKWriteJSON(sink, @"page/windows.json", context.windowsJSON ?: @[], NO);
        NSArray *swiftArr = TZGetCapturedPageSwiftClasses();
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
    NSMutableDictionary<NSString *, NSString *> *futureImageMap = [NSMutableDictionary dictionary]; // DK_FUTURE_FIX
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
    //   二进制里定义的类在首次使用前不会注册，大型 App 会丢 40%+ 的类。
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
                    NSString *imgBase = [[NSString stringWithUTF8String:imgName] lastPathComponent];
                    imgBase = [imgBase stringByDeletingPathExtension];
                    if (imgBase.length > 0) futureImageMap[name] = imgBase; // DK_FUTURE_FIX
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
                NSString *header = cls ? TZClassDumpHeaderForClass(cls) : nil;
                NSString *imageName = nil;
                if (!cls) {
                    // DK_FUTURE_FIX: future class 未注册，用补全阶段记录的 imageName 输出空壳
                    imageName = futureImageMap[name];
                    if (!imageName.length) continue;
                    if ([imageName isEqualToString:@"tzyhb"]) continue;
                    header = [NSString stringWithFormat:
                        @"//\n// Future class: %@\n// Image: %@\n"
                        @"// 未在 objc runtime 注册（iOS 16+ future class），"
                        @"无属性/方法信息\n//\n\n"
                        @"#import <Foundation/Foundation.h>\n\n"
                        @"@interface %@ : NSObject\n@end\n",
                        name, imageName, name];
                } else {
                    if (!header.length) continue;
                    imageName = DKImageNameForClass(cls);
                    if (!imageName.length) continue;
                    if ([imageName isEqualToString:@"tzyhb"]) continue;
                }
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
        TZStaticDumpCategories(binaryPath, ^(NSString *className, NSString *categoryName, NSString *text) {
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
                              TZAudioProbeCapture *capture,
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

TZDebugExportResult *TZDebugCreateExport(TZDebugExportContext *context,
                                         TZDebugExportMode mode,
                                         void (^progress)(NSString *text),
                                         NSError **error) {
    if (!context || (mode == TZDebugExportModeAudio && !context.audioCapture)) {
        if (error) *error = DKMakeExportError(1, @"导出上下文不完整", nil);
        return nil;
    }

    NSString *state = mode == TZDebugExportModeAudio ? (context.audioCapture.declaredState ?: @"unknown") : @"";
    NSString *suffix = state.length ? [NSString stringWithFormat:@"-%@", DKSafeFileName(state)] : @"";
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"Unknown";
    NSString *appName = NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"UnknownApp";
    NSString *rootName = [NSString stringWithFormat:@"tz-%@-Debug-%@%@-%lld",
                          appName,
                          DKModeName(mode), suffix,
                          (long long)NSDate.date.timeIntervalSince1970];
    NSString *cacheRoot = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (cacheRoot.length == 0) cacheRoot = NSTemporaryDirectory();
    NSString *appDir = [[cacheRoot stringByAppendingPathComponent:@"tz"] stringByAppendingPathComponent:DKSafeFileName(bid)];
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
    DKWriteString(sink, @"README.txt", DKReadme(context, mode), mode == TZDebugExportModeAudio);
    DKWriteData(sink, @"ui/screenshot.png", context.screenshotPNG, NO);
    {
        NSDictionary<NSString *, NSString *> *probes = context.probes;
        if (probes.count == 0 && context.probeText.length) {
            probes = @{@"tabbar": context.probeText};
        }
        if (probes.count == 0) {
            DKWriteString(sink, @"probe/README.txt", @"no probes ran; check TZRegisterBuiltinProbes()\n", NO);
        } else {
            for (NSString *name in probes) {
                NSString *path = [NSString stringWithFormat:@"probe/%@.txt", name];
                DKWriteString(sink, path, probes[name], NO);
            }
        }
    }

    if (mode == TZDebugExportModeAudio) {
        DKWriteAudioFiles(sink, context.audioCapture, progress);
    } else if (mode == TZDebugExportModeAllClasses) {
        DKWriteAllClasses(sink, progress);
        DKWritePageFiles(sink, context, progress);
    } else {
        DKWritePageFiles(sink, context, progress);
    }

    NSDictionary *manifest = @{
        @"schemaVersion": mode == TZDebugExportModeAudio ? @"tz.audio-probe.v2" : @"tz.debug.v2",
        @"mode": DKModeName(mode),
        @"tzVersion": DK_VERSION,
        @"device": context.metadata ?: @{},
        @"declaredState": context.audioCapture.declaredState ?: @"not-applicable",
        @"actualState": context.audioCapture.actualState ?: @"not-applicable",
        @"sampling": mode == TZDebugExportModeAudio ? @{
            @"totalSeconds": @(TZAudioProbeTotalSeconds),
            @"warmupSeconds": @(TZAudioProbeWarmupSeconds),
            @"recordSeconds": @(TZAudioProbeRecordSeconds),
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
    DKWriteJSON(sink, @"manifest.json", manifest, mode == TZDebugExportModeAudio);

    if (sink.criticalFailed) {
        if (error) {
            *error = [NSError errorWithDomain:DKExportErrorDomain code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"关键文件写入失败，工作目录已保留",
                TZDebugExportWorkingDirectoryKey: rootDir,
            }];
        }
        return nil;
    }

    if (progress) progress(@"压缩 zip...");
    NSError *zipError = nil;
    BOOL zipped = sink.files.count > 0 && [TZZipWriter createZipAtPath:zipPath
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
            TZDebugExportWorkingDirectoryKey: rootDir,
        }];
        if (underlying) info[NSUnderlyingErrorKey] = underlying;
        if (error) *error = [NSError errorWithDomain:DKExportErrorDomain code:4 userInfo:info];
        return nil;
    }

    TZDebugExportResult *result = [TZDebugExportResult new];
    result.zipURL = [NSURL fileURLWithPath:zipPath];
    result.workingDirectoryURL = [NSURL fileURLWithPath:rootDir isDirectory:YES];
    return result;
}

void TZDebugCleanupExport(TZDebugExportResult *result) {
    if (!result) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (result.workingDirectoryURL.isFileURL) [fm removeItemAtURL:result.workingDirectoryURL error:nil];
    if (result.zipURL.isFileURL) [fm removeItemAtURL:result.zipURL error:nil];
}
// DK_README_V3
// DK_README_V31
// DK_README_V32