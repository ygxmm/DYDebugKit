#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <signal.h>
#import <setjmp.h>

#import "CDFile.h"
#import "CDMachOFile.h"
#import "CDFatFile.h"
#import "CDSearchPathState.h"
#import "CDObjectiveCProcessor.h"
#import "CDObjectiveC2Processor.h"
#import "CDOCCategory.h"
#import "CDVisitor.h"
#import "CDTextClassDumpVisitor.h"

@interface DKCategoryVisitor : CDTextClassDumpVisitor
@end
@implementation DKCategoryVisitor
@end

#pragma mark - 崩溃隔离

static sigjmp_buf gCrashJmp;
static volatile int gCrashGuardActive = 0;
static volatile int gCrashedThisAttempt = 0;
static struct sigaction gOldSEGV, gOldBUS;

static void DKCrashHandler(int sig) {
    if (gCrashGuardActive) {
        gCrashGuardActive = 0;
        gCrashedThisAttempt = 1;
        siglongjmp(gCrashJmp, 1);
    }
    // 不在 guard 里，交还系统
    signal(sig, SIG_DFL);
    raise(sig);
}

static void DKInstallCrashHandlers(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    struct sigaction sa = {0};
    sa.sa_handler = DKCrashHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGSEGV, &sa, &gOldSEGV);
    sigaction(SIGBUS,  &sa, &gOldBUS);
}

// 带崩溃保护的执行块：返回值 0=正常完成，1=崩溃
#define DK_TRY_BEGIN() \
    do { \
        gCrashedThisAttempt = 0; \
        if (sigsetjmp(gCrashJmp, 1) != 0) break; \
        gCrashGuardActive = 1;

#define DK_TRY_END() \
        gCrashGuardActive = 0; \
    } while (0)

#pragma mark - 地址校验

static BOOL DKAddressInImage(uintptr_t addr, const struct mach_header_64 *header,
                             intptr_t slide, size_t minLen) {
    if (addr == 0) return NO;
    const struct load_command *cmd = (const struct load_command *)((const uint8_t *)header + sizeof(*header));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            uintptr_t start = seg->vmaddr + slide;
            uintptr_t end = start + seg->vmsize;
            if (addr >= start && addr + minLen <= end) return YES;
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }
    return NO;
}

static BOOL DKIsPrintableString(const char *p, size_t maxLen) {
    if (!p) return NO;
    for (size_t i = 0; i < maxLen; i++) {
        char c = p[i];
        if (c == '\0') return i > 0;
        if (c < 0x20 || c > 0x7e) return NO;
    }
    return NO;
}

#pragma mark - WrappedPtr 多策略解包

// 尝试三种解包方式，返回第一个通过 image 地址检查的指针
static void *DKResolveWrappedPtr(uintptr_t raw, void *fieldAddr,
                                 const struct mach_header_64 *header, intptr_t slide) {
    // ① relative（bit 0 = 1）
    if (raw & 1) {
        uintptr_t p = (uintptr_t)fieldAddr + ((intptr_t)raw & ~(intptr_t)1);
        if (DKAddressInImage(p, header, slide, sizeof(void *))) return (void *)p;
    }
    // ② ptrauth-signed absolute（strip 高 24 位签名 + 低 3 位）
    {
        uintptr_t p = raw & 0x00007ffffffffff8ULL;
        if (DKAddressInImage(p, header, slide, sizeof(void *))) return (void *)p;
    }
    // ③ 原值（普通 absolute）
    if (DKAddressInImage(raw, header, slide, sizeof(void *))) return (void *)raw;
    return NULL;
}

// 进一步校验：cls 的 isa 必须在 image 内
static BOOL DKLooksLikeClass(void *clsPtr, const struct mach_header_64 *header, intptr_t slide) {
    if (!clsPtr) return NO;
    if (!DKAddressInImage((uintptr_t)clsPtr, header, slide, sizeof(void *) * 5)) return NO;
    uintptr_t isa = *(uintptr_t *)clsPtr;
    if (!DKAddressInImage(isa, header, slide, sizeof(void *))) return NO;
    return YES;
}

#pragma mark - 主入口

void DKStaticDumpCategories(NSString *binaryPath,
                            void (^onCategory)(NSString *className,
                                               NSString *categoryName,
                                               NSString *text)) {
    if (!onCategory) return;

    DKInstallCrashHandlers();
    NSLog(@"[DKStatic] scanning categories...");

    uint32_t total = _dyld_image_count();
    NSUInteger totalCats = 0;
    NSUInteger skippedCats = 0;

    for (uint32_t img = 0; img < total; img++) {
        @autoreleasepool {
            const char *imgName = _dyld_get_image_name(img);
            if (!imgName) continue;

            const struct mach_header *hdrRaw = _dyld_get_image_header(img);
            if (!hdrRaw || hdrRaw->magic != MH_MAGIC_64) continue;
            const struct mach_header_64 *header = (const struct mach_header_64 *)hdrRaw;
            intptr_t slide = _dyld_get_image_vmaddr_slide(img);

            uintptr_t catlistAddr = 0;
            uint64_t  catlistSize = 0;

            const struct load_command *cmd = (const struct load_command *)((const uint8_t *)header + sizeof(*header));
            for (uint32_t i = 0; i < header->ncmds; i++) {
                if (cmd->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                    const struct section_64 *sects = (const struct section_64 *)((const uint8_t *)seg + sizeof(*seg));
                    for (uint32_t s = 0; s < seg->nsects; s++) {
                        const char *sn = sects[s].sectname;
                        if (strcmp(sn, "__objc_catlist") == 0 ||
                            strcmp(sn, "__objc_catlist2") == 0) {
                            catlistAddr = sects[s].addr + slide;
                            catlistSize = sects[s].size;
                            break;
                        }
                    }
                }
                cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
            }

            if (catlistAddr == 0 || catlistSize == 0) continue;

            NSUInteger count = catlistSize / sizeof(uintptr_t);
            uintptr_t *ptrs = (uintptr_t *)catlistAddr;

            NSUInteger catsThisImage = 0;

            for (NSUInteger i = 0; i < count; i++) {
                @autoreleasepool {
                    NSString *className = nil;
                    NSString *catName = nil;

                    // 带崩溃保护的解包
                    DK_TRY_BEGIN();
                    {
                        uintptr_t catAddr = ptrs[i];
                        if (catAddr != 0 &&
                            DKAddressInImage(catAddr, header, slide, 6 * sizeof(uintptr_t))) {

                            uintptr_t *fields = (uintptr_t *)catAddr;

                            // name 字段（普通指针）
                            const char *nameC = (const char *)fields[0];
                            if (DKAddressInImage((uintptr_t)nameC, header, slide, 1) &&
                                DKIsPrintableString(nameC, 256)) {
                                catName = [NSString stringWithUTF8String:nameC];
                            }

                            // cls 字段（WrappedPtr 多策略解包 + isa 校验）
                            void *clsPtr = DKResolveWrappedPtr(fields[1], &fields[1], header, slide);
                            if (DKLooksLikeClass(clsPtr, header, slide)) {
                                @try {
                                    const char *clsNameC = class_getName((__bridge Class)clsPtr);
                                    if (clsNameC && DKIsPrintableString(clsNameC, 512)) {
                                        className = [NSString stringWithUTF8String:clsNameC];
                                    }
                                } @catch (NSException *e) {
                                    // 忽略 ObjC 异常
                                }
                            }
                        }
                    }
                    DK_TRY_END();

                    if (gCrashedThisAttempt) {
                        skippedCats++;
                        continue;
                    }

                    if (!catName.length) { skippedCats++; continue; }
                    if (!className.length) className = @"_Unknown";

                    NSMutableString *text = [NSMutableString string];
                    [text appendString:@"//\n"];
                    [text appendFormat:@"// %@ (%@)\n", className, catName];
                    [text appendString:@"// 静态扫描 __objc_catlist\n"];
                    [text appendString:@"// 注意: 方法列表待补全\n//\n\n"];
                    [text appendFormat:@"@interface %@ (%@)\n\n", className, catName];
                    [text appendString:@"@end\n"];

                    onCategory(className, catName, text);
                    catsThisImage++;
                    totalCats++;
                }
            }

            if (catsThisImage > 0) {
                NSLog(@"[DKStatic] %s : %lu categories", imgName, (unsigned long)catsThisImage);
            }
        }
    }

    NSLog(@"[DKStatic] total=%lu skipped=%lu", (unsigned long)totalCats, (unsigned long)skippedCats);
}
