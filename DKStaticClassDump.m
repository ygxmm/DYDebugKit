// DKStaticClassDump.m - v4
// 修复：1) clsPtr 结构校验 2) chain handler 3) __objc_catlist2 兼容
// 纯 ASCII 注释，避免编码问题

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <signal.h>
#import <setjmp.h>
#import <string.h>
#include <stdio.h>
#include <stdarg.h>
#import "DKStaticClassDump.h"

#pragma mark - Crash isolation

static FILE *gScanLog = NULL;
static void DKScanLog(const char *fmt, ...) {
    if (!gScanLog) {
        NSString *path = nil;
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (docs.count > 0) path = [docs[0] stringByAppendingPathComponent:@"tzyhb_last_scan.log"];
        if (!path) path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tzyhb_last_scan.log"];
        if (path) gScanLog = fopen([path fileSystemRepresentation], "w");
        if (gScanLog) setvbuf(gScanLog, NULL, _IONBF, 0);
    }
    if (gScanLog) { va_list ap; va_start(ap, fmt); vfprintf(gScanLog, fmt, ap); va_end(ap); fputc(10, gScanLog); }
}

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
    sigaction(SIGBUS,  &sa, &gOldSIGBUSAction);
}

#define DK_TRY_BEGIN() \
    do { \
        gCrashedThisAttempt = 0; \
        if (sigsetjmp(gCrashJmp, 1) != 0) break; \
        gCrashGuardActive = 1;

#define DK_TRY_END() \
        gCrashGuardActive = 0; \
    } while (0)

#pragma mark - PAC

#define DK_PAC_MASK 0x0000FFFFFFFFFFFFULL
static inline uintptr_t DKStripPAC(uint64_t raw) {
    return (uintptr_t)(raw & DK_PAC_MASK);
}

#pragma mark - Segment checks

static BOOL DKAddressInSegments(uintptr_t addr, const struct mach_header_64 *header,
                                intptr_t slide, size_t minLen) {
    if (addr == 0) return NO;
    const struct load_command *cmd = (const struct load_command *)((const uint8_t *)header + sizeof(*header));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (seg->filesize != 0 && seg->initprot != 0
                && seg->vmsize <= (1ULL << 30)
                && strcmp(seg->segname, "__PAGEZERO") != 0) {
                uintptr_t start = seg->vmaddr + slide;
                uintptr_t end = start + seg->vmsize;
                if (addr >= start && addr + minLen <= end) return YES;
            }
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
        unsigned char c = (unsigned char)p[i];
        if (c == 0) return i > 0;
        if (c < 0x20 || c == 0x7F) return NO;
    }
    return NO;
}

#pragma mark - ObjC class structure validation

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

#pragma mark - Per-entry handling

static BOOL DKReadClassNameFast(uintptr_t clsPtr, char *outBuf, size_t outBufLen) {
    if (clsPtr == 0 || (clsPtr & 7)) return NO;
    if (!DKAddressInAnyLoadedImage(clsPtr, 40)) return NO;
    uintptr_t bits = *(uintptr_t *)(clsPtr + 32);
    uintptr_t ro = bits & ~(uintptr_t)0x7;
    if (ro == 0) return NO;
    if (!DKAddressInAnyLoadedImage(ro, 32)) return NO;
    const char *name = *(const char **)(ro + 24);
    if (name == NULL) return NO;
    if (!DKAddressInAnyLoadedImage((uintptr_t)name, 1)) return NO;
    if (!DKIsPrintableString(name, 512)) return NO;
    size_t len = strlen(name);
    if (len >= outBufLen) len = outBufLen - 1;
    memcpy(outBuf, name, len); outBuf[len] = 0;
    return YES;
}

static void DKProcessCategory(uintptr_t catAddr,
                              const struct mach_header_64 *header,
                              intptr_t slide,
                              const char *tag,
                              NSUInteger *skipped,
                              NSUInteger *totalCats,
                              void (^onCategory)(NSString *, NSString *, NSString *)) {
    if (!DKAddressInSegments(catAddr, header, slide, 48)) { (*skipped)++; return; }
    uint64_t *fields = (uint64_t *)catAddr;

    uintptr_t namePtr = DKStripPAC(fields[0]);
    if (namePtr == 0 || !DKAddressInSegments(namePtr, header, slide, 1)) { (*skipped)++; return; }
    const char *nameC = (const char *)namePtr;
    if (!DKIsPrintableString(nameC, 256)) { (*skipped)++; return; }
    NSString *catName = [NSString stringWithUTF8String:nameC];
    if (!catName.length) { (*skipped)++; return; }

    uintptr_t clsPtr = DKStripPAC(fields[1]);
    NSString *className = nil;

    if (clsPtr != 0 && !DKIsValidObjCClassPtr(clsPtr)) {
        NSLog(@"[DKCAT-DIAG] %s bad cls=%016lx name=%@",
              tag, (unsigned long)clsPtr, catName);
        (*skipped)++;
        clsPtr = 0;
    }
    if (clsPtr != 0) {
        DK_TRY_BEGIN();
        char _nameBuf[512];
        if (DKReadClassNameFast(clsPtr, _nameBuf, sizeof(_nameBuf))) {
            className = [NSString stringWithUTF8String:_nameBuf];
        } else {
            DKScanLog("bad cls=%016lx name=%@", (unsigned long)clsPtr, catName);
        }
        DK_TRY_END();
        if (gCrashedThisAttempt) className = nil;
    }
    if (clsPtr == 0) {
        DKScanLog("ZERO cat=%016lx f0=%016lx f1=%016lx f2=%016lx f3=%016lx name=%@ tag=%s",
                  (unsigned long)catAddr,
                  (unsigned long)fields[0], (unsigned long)fields[1],
                  (unsigned long)fields[2], (unsigned long)fields[3],
                  catName, tag);
    }
    if (!className.length) {
        for (int _off = 2; _off <= 5; _off++) {
            uintptr_t _cand = DKStripPAC(fields[_off]);
            if (_cand == 0) continue;
            char _cb[512];
            if (DKReadClassNameFast(_cand, _cb, sizeof(_cb))) {
                className = [NSString stringWithUTF8String:_cb];
                DKScanLog("FOUND cls off=%d cat=%@ val=%016lx",
                          _off, catName, (unsigned long)_cand);
                break;
            }
        }
    }
    if (!className.length) className = @"_UnknownClass";

    NSMutableString *text = [NSMutableString string];
    [text appendString:@"//\n"];
    [text appendFormat:@"// %@ (%@)\n", className, catName];
    [text appendFormat:@"// scanned from %s\n//\n\n", tag];
    [text appendFormat:@"@interface %@ (%@)\n\n@end\n", className, catName];
    onCategory(className, catName, text);
    (*totalCats)++;
}

#pragma mark - Main

void DKStaticDumpCategories(NSString *binaryPath,
                            void (^onCategory)(NSString *className,
                                               NSString *categoryName,
                                               NSString *text)) {
    DKScanLog("=== ENTER v5 ===");
    if (!onCategory) return;
    DKInstallCrashHandlers();
    NSLog(@"[DKStatic] scanning categories v4...");

    uint32_t total = _dyld_image_count();
    NSUInteger totalCats = 0;
    NSUInteger skipped = 0;
    NSUInteger seenCatlist = 0;
    NSUInteger seenCatlist2 = 0;

    for (uint32_t img = 0; img < total; img++) {
        @autoreleasepool {
            const char *imgName = _dyld_get_image_name(img);
            if (!imgName) continue;
            const struct mach_header *hdrRaw = _dyld_get_image_header(img);
            if (!hdrRaw || hdrRaw->magic != MH_MAGIC_64) continue;
            const struct mach_header_64 *header = (const struct mach_header_64 *)hdrRaw;
            intptr_t slide = _dyld_get_image_vmaddr_slide(img);

            uintptr_t catlistAddr = 0, catlist2Addr = 0;
            uint64_t  catlistSize = 0, catlist2Size = 0;

            const struct load_command *cmd = (const struct load_command *)((const uint8_t *)header + sizeof(*header));
            for (uint32_t i = 0; i < header->ncmds; i++) {
                if (cmd->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                    const struct section_64 *sects = (const struct section_64 *)((const uint8_t *)seg + sizeof(*seg));
                    for (uint32_t s = 0; s < seg->nsects; s++) {
                        const char *sn = sects[s].sectname;
                        if (strcmp(sn, "__objc_catlist") == 0) {
                            catlistAddr = sects[s].addr + slide;
                            catlistSize = sects[s].size;
                        } else if (strcmp(sn, "__objc_catlist2") == 0) {
                            catlist2Addr = sects[s].addr + slide;
                            catlist2Size = sects[s].size;
                        }
                    }
                }
                cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
            }

            if (catlistAddr != 0 && catlistSize >= 8) seenCatlist++;
            if (catlist2Addr != 0 && catlist2Size >= 4) seenCatlist2++;

            // --- __objc_catlist : each slot is 8-byte u64 absolute pointer ---
            if (catlistAddr != 0 && catlistSize >= 8) {
                NSUInteger count = catlistSize / 8;
                uint64_t *slots = (uint64_t *)catlistAddr;
                for (NSUInteger i = 0; i < count; i++) {
                    @autoreleasepool {
                        uintptr_t catAddr = DKStripPAC(slots[i]);
                        if (catAddr == 0) { skipped++; continue; }
                        DKProcessCategory(catAddr, header, slide, "catlist",
                                          &skipped, &totalCats, onCategory);
                    }
                }
            }

            // --- __objc_catlist2 : each slot is 4-byte int32 rel offset from slot self ---
            if (catlist2Addr != 0 && catlist2Size >= 4) {
                NSUInteger count = catlist2Size / 4;
                int32_t *offsets = (int32_t *)catlist2Addr;
                for (NSUInteger i = 0; i < count; i++) {
                    @autoreleasepool {
                        int32_t rel = offsets[i];
                        if (rel == 0) { skipped++; continue; }
                        uintptr_t slotAddr = catlist2Addr + i * 4;
                        uintptr_t catAddr = slotAddr + (intptr_t)rel;
                        DKProcessCategory(catAddr, header, slide, "catlist2",
                                          &skipped, &totalCats, onCategory);
                    }
                }
            }

            if (catlistAddr != 0 || catlist2Addr != 0) {
                NSLog(@"[DKStatic] %s: catlist=%lu catlist2=%lu",
                      imgName,
                      (unsigned long)(catlistSize / 8),
                      (unsigned long)(catlist2Size / 4));
            }
        }
    }

    NSLog(@"[DKStatic] done: total=%lu skipped=%lu seenCatlist=%lu seenCatlist2=%lu",
          (unsigned long)totalCats, (unsigned long)skipped,
          (unsigned long)seenCatlist, (unsigned long)seenCatlist2);

    DKScanLog("DONE total=%lu skipped=%lu seenCatlist=%lu seenCatlist2=%lu", (unsigned long)totalCats, (unsigned long)skipped, (unsigned long)seenCatlist, (unsigned long)seenCatlist2);
}
