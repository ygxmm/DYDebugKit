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

#pragma mark - darwinscope 参考常量

// 来自 darwinscope src/ptrauth.rs:29
// "Mask covering the user virtual-address window (low 48 bits)"
// arm64e PAC 签名在 bits 48..63，低 48 位是有效 VA
#define DK_PAC_MASK 0x0000FFFFFFFFFFFFULL

#pragma mark - 崩溃隔离

static sigjmp_buf gCrashJmp;
static volatile int gCrashGuardActive = 0;
static volatile int gCrashedThisAttempt = 0;

static struct sigaction gOldSEGVAction;
static struct sigaction gOldSIGBUSAction;

static void DKCrashHandler(int sig) {
    if (gCrashGuardActive) {
        gCrashGuardActive = 0;
        gCrashedThisAttempt = 1;
        siglongjmp(gCrashJmp, 1);
    }
    struct sigaction *old = (sig == SIGSEGV) ? &gOldSEGVAction : &gOldSIGBUSAction;
    if (old->sa_handler && old->sa_handler != SIG_DFL && old->sa_handler != SIG_IGN) {
        old->sa_handler(sig);
        return;
    }
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
    sigaction(SIGSEGV, &sa, &gOldSEGVAction);
    sigaction(SIGBUS, &sa, &gOldSIGBUSAction);
}

#define DK_TRY_BEGIN() \
    do { \
        gCrashedThisAttempt = 0; \
        if (sigsetjmp(gCrashJmp, 1) != 0) break; \
        gCrashGuardActive = 1;

#define DK_TRY_END() \
        gCrashGuardActive = 0; \
    } while (0)

#pragma mark - 工具函数

// 检查地址是否落在某个 segment 内（保护 minLen 字节）
static BOOL DKAddressInSegments(uintptr_t addr, const struct mach_header_64 *header,
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

static BOOL DKAddressInAnyLoadedImage(uintptr_t addr, size_t minLen) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        intptr_t sl = _dyld_get_image_vmaddr_slide(i);
        if (DKAddressInSegments(addr, h, sl, minLen)) return YES;
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

// darwinscope 的 strip_signature 等价实现：raw & 0x0000FFFFFFFFFFFF
static inline uintptr_t DKStripPAC(uint64_t raw) {
    return (uintptr_t)(raw & DK_PAC_MASK);
}

#pragma mark - 主入口

static BOOL DKIsValidObjCClassPtr(uintptr_t clsPtr) {
    if (clsPtr == 0 || (clsPtr & 0x7)) return NO;
    if (!DKAddressInAnyLoadedImage(clsPtr, 40)) return NO;
    uintptr_t isa = *(uintptr_t *)clsPtr;
    if (isa == 0 || (isa & 0x7)) return NO;
    if (!DKAddressInAnyLoadedImage(isa, 8)) return NO;
    uintptr_t bits = *(uintptr_t *)(clsPtr + 32);
    uintptr_t dataPtr = bits & ~(uintptr_t)0x7;
    if (dataPtr == 0) return NO;
    if (!DKAddressInAnyLoadedImage(dataPtr, 32)) return NO;
    const char *name = *(const char **)(dataPtr + 24);
    if (name == NULL) return NO;
    if (!DKAddressInAnyLoadedImage((uintptr_t)name, 1)) return NO;
    if (!DKIsPrintableString(name, 512)) return NO;
    return YES;
}

void DKStaticDumpCategories(NSString *binaryPath,
                            void (^onCategory)(NSString *className,
                                               NSString *categoryName,
                                               NSString *text)) {
    if (!onCategory) return;

    DKInstallCrashHandlers();
    NSLog(@"[DKStatic] scanning categories (darwinscope-style)...");

    uint32_t total = _dyld_image_count();
    NSUInteger totalCats = 0;
    NSUInteger skipped = 0;

    for (uint32_t img = 0; img < total; img++) {
        @autoreleasepool {
            const char *imgName = _dyld_get_image_name(img);
            if (!imgName) continue;

            const struct mach_header *hdrRaw = _dyld_get_image_header(img);
            if (!hdrRaw || hdrRaw->magic != MH_MAGIC_64) continue;
            const struct mach_header_64 *header = (const struct mach_header_64 *)hdrRaw;
            intptr_t slide = _dyld_get_image_vmaddr_slide(img);

            // 找 __objc_catlist / __objc_catlist2 段
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

            if (catlistAddr == 0 || catlistSize < 8) continue;

            // darwinscope: catlist 项是 8 字节 u64（category.rs:171 off += 8）
            NSUInteger count = catlistSize / 8;
            uint64_t *slots = (uint64_t *)catlistAddr;

            NSUInteger catsThisImage = 0;

            for (NSUInteger i = 0; i < count; i++) {
                @autoreleasepool {
                    uint64_t cat_raw = slots[i];
                    uintptr_t catAddr = DKStripPAC(cat_raw);

                    if (catAddr == 0) continue;
                    // category_t 前 6 个 u64 = 48 字节
                    if (!DKAddressInSegments(catAddr, header, slide, 48)) {
                        skipped++;
                        continue;
                    }

                    uint64_t *fields = (uint64_t *)catAddr;

                    // ① name (offset 0): u64 ptr
                    uintptr_t namePtr = DKStripPAC(fields[0]);
                    if (namePtr == 0) { skipped++; continue; }
                    if (!DKAddressInSegments(namePtr, header, slide, 1)) {
                        skipped++;
                        continue;
                    }
                    const char *nameC = (const char *)namePtr;
                    if (!DKIsPrintableString(nameC, 256)) { skipped++; continue; }
                    NSString *catName = [NSString stringWithUTF8String:nameC];
                    if (!catName.length) { skipped++; continue; }

                    // ② cls (offset 8): u64 ptr，可能跨 image
                    uintptr_t clsPtr = DKStripPAC(fields[1]);
                    NSString *className = nil;

                    if (clsPtr != 0 && !DKIsValidObjCClassPtr(clsPtr)) {
                        NSLog(@"[DKCAT-DIAG] skip bad clsPtr=%016lx name=%@",
                              (unsigned long)clsPtr, catName);
                        skipped++;
                        clsPtr = 0;
                    }
                    if (clsPtr != 0) {
                        DK_TRY_BEGIN();
                        {
                            Class cls = (__bridge Class)(void *)clsPtr;
                            const char *clsNameC = class_getName(cls);
                            if (clsNameC && DKIsPrintableString(clsNameC, 512)) {
                                className = [NSString stringWithUTF8String:clsNameC];
                            }
                        }
                        DK_TRY_END();

                        if (gCrashedThisAttempt) {
                            className = nil;
                        }
                    }

                    if (!className.length) className = @"_UnknownClass";

                    // 输出（方法列表下轮补）
                    NSMutableString *text = [NSMutableString string];
                    [text appendString:@"//\n"];
                    [text appendFormat:@"// %@ (%@)\n", className, catName];
                    [text appendString:@"// 静态扫描 __objc_catlist (darwinscope-style)\n"];
                    [text appendString:@"// 注意: 方法列表待补全\n//\n\n"];
                    [text appendFormat:@"@interface %@ (%@)\n\n", className, catName];
                    [text appendString:@"@end\n"];

                    onCategory(className, catName, text);
                    catsThisImage++;
                    totalCats++;
                }
            }

            if (catsThisImage > 0) {
                NSLog(@"[DKStatic] %s : %lu cats", imgName, (unsigned long)catsThisImage);
            }
        }
    }

    NSLog(@"[DKStatic] done: total=%lu skipped=%lu", (unsigned long)totalCats, (unsigned long)skipped);
}
