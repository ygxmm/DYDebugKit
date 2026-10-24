#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

// 保留旧 visitor 类（链接需要）
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

#pragma mark - 安全辅助

// 解 WrappedPtr：iOS 15+ objc 结构里有些指针是 relative offset（bit 0 = 1）
static void *DKUnwrapRelativePtr(void *raw, void *fieldAddr) {
    if (!raw) return NULL;
    uintptr_t v = (uintptr_t)raw;
    if (v & 1) {
        intptr_t delta = (intptr_t)v & ~(intptr_t)1;
        return (void *)((uintptr_t)fieldAddr + delta);
    }
    return raw;
}

// 检查地址是否落在某个 image 的某个 segment 内（带 minLen 边界）
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

// 检查是否合法 C 字符串（可打印 ASCII，null 结束）
static BOOL DKIsPrintableString(const char *p, size_t maxLen) {
    if (!p) return NO;
    for (size_t i = 0; i < maxLen; i++) {
        char c = p[i];
        if (c == '\0') return i > 0;
        if (c < 0x20 || c > 0x7e) return NO;
    }
    return NO;
}

#pragma mark - category 扫描

void DKStaticDumpCategories(NSString *binaryPath,
                            void (^onCategory)(NSString *className,
                                               NSString *categoryName,
                                               NSString *text)) {
    if (!onCategory) return;

    uint32_t total = _dyld_image_count();
    NSLog(@"[DKStatic] scanning %u images for categories", total);

    NSUInteger totalCats = 0;

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

            if (catlistAddr == 0 || catlistSize == 0) continue;

            NSUInteger count = catlistSize / sizeof(uintptr_t);
            uintptr_t *ptrs = (uintptr_t *)catlistAddr;

            NSUInteger catsThisImage = 0;
            for (NSUInteger i = 0; i < count; i++) {
                @autoreleasepool {
                    uintptr_t catAddr = ptrs[i];
                    if (catAddr == 0) continue;
                    if (!DKAddressInImage(catAddr, header, slide, 6 * sizeof(uintptr_t))) continue;

                    // category_t 前 6 个字段: name, cls, instanceMethods, classMethods, protocols, instanceProperties
                    uintptr_t *fields = (uintptr_t *)catAddr;

                    // ① name: 普通 const char*（不用 WrappedPtr）
                    const char *nameC = (const char *)fields[0];
                    if (!DKAddressInImage((uintptr_t)nameC, header, slide, 1)) continue;
                    if (!DKIsPrintableString(nameC, 256)) continue;
                    NSString *catName = [NSString stringWithUTF8String:nameC];
                    if (!catName.length) continue;

                    // ② cls: WrappedPtr
                    void *clsRaw = (void *)fields[1];
                    void *clsPtr = DKUnwrapRelativePtr(clsRaw, &fields[1]);
                    if (!clsPtr) continue;
                    if (!DKAddressInImage((uintptr_t)clsPtr, header, slide, sizeof(void *))) continue;
                    Class cls = (__bridge Class)clsPtr;
                    const char *clsNameC = class_getName(cls);
                    if (!clsNameC) continue;
                    if (!DKIsPrintableString(clsNameC, 256)) continue;
                    NSString *className = [NSString stringWithUTF8String:clsNameC];
                    if (!className.length) continue;

                    // ③ 只出 category 名，方法列表下轮
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

    NSLog(@"[DKStatic] total categories found: %lu", (unsigned long)totalCats);
}
