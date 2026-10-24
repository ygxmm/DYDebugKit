#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

// 保留原 visitor 类（链接期不会断链，虽然新路径不用它）
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
@property (nonatomic, copy) void (^onCategory)(NSString *className, NSString *categoryName, NSString *text);
@property (nonatomic, assign) NSUInteger categoryStartIndex;
@end

@implementation DKCategoryVisitor
- (void)willVisitClass:(CDOCClass *)aClass {}
- (void)willVisitProtocol:(CDOCProtocol *)protocol {}
- (void)willVisitCategory:(CDOCCategory *)category {
    [self.resultString setString:@""];
    self.categoryStartIndex = 0;
    [super willVisitCategory:category];
}
- (void)didVisitCategory:(CDOCCategory *)category {
    [super didVisitCategory:category];
    NSString *text = [self.resultString copy];
    if (self.onCategory && text.length > 0) {
        self.onCategory(category.className, category.name, text);
    }
}
@end

#pragma mark - 内存 image 结构体

typedef struct {
    const char *name;
    void       *cls;
    void       *instanceMethods;
    void       *classMethods;
    void       *protocols;
    void       *instanceProperties;
} DKCategory_t;

typedef struct {
    uint32_t entsizeAndFlags;
    uint32_t count;
} DKMethodList_t;

typedef struct {
    int32_t nameOffset;
    int32_t typesOffset;
    int32_t impOffset;
} DKRelativeMethod_t;

typedef struct {
    SEL name;
    const char *types;
    void *imp;
} DKDirectMethod_t;

#pragma mark - type encoding 解析

static NSString *DKParseSingleType(NSString *enc, NSUInteger *idx);

static NSString *DKParseSingleType(NSString *enc, NSUInteger *idx) {
    if (*idx >= enc.length) return nil;
    unichar c = [enc characterAtIndex:*idx];
    (*idx)++;
    switch (c) {
        case 'v': return @"void";
        case 'c': return @"char";
        case 'C': return @"unsigned char";
        case 'B': return @"BOOL";
        case 'i': return @"int";
        case 'I': return @"unsigned int";
        case 's': return @"short";
        case 'S': return @"unsigned short";
        case 'l': return @"long";
        case 'L': return @"unsigned long";
        case 'q': return @"long long";
        case 'Q': return @"unsigned long long";
        case 'f': return @"float";
        case 'd': return @"double";
        case '*': return @"char *";
        case ':': return @"SEL";
        case '#': return @"Class";
        case '@': {
            if (*idx < enc.length) {
                unichar n = [enc characterAtIndex:*idx];
                if (n == '?') { (*idx)++; return @"id /*block*/"; }
                if (n == '"') {
                    (*idx)++;
                    NSUInteger s = *idx;
                    while (*idx < enc.length && [enc characterAtIndex:*idx] != '"') (*idx)++;
                    NSString *cls = [enc substringWithRange:NSMakeRange(s, *idx - s)];
                    if (*idx < enc.length) (*idx)++;
                    return [NSString stringWithFormat:@"%@ *", cls];
                }
            }
            return @"id";
        }
        case '^': {
            NSString *inner = DKParseSingleType(enc, idx);
            return [NSString stringWithFormat:@"%@*", inner ?: @"void "];
        }
        case '{':
        case '(': {
            NSUInteger start = *idx - 1;
            unichar close = (c == '{') ? '}' : ')';
            NSUInteger depth = 1;
            while (*idx < enc.length && depth > 0) {
                unichar ch = [enc characterAtIndex:*idx];
                if (ch == c) depth++;
                else if (ch == close) depth--;
                (*idx)++;
            }
            NSString *full = [enc substringWithRange:NSMakeRange(start, *idx - start)];
            NSUInteger eq = [full rangeOfString:@"="].location;
            NSString *kw = (c == '{') ? @"struct" : @"union";
            if (eq != NSNotFound) {
                NSString *nm = [full substringWithRange:NSMakeRange(1, eq - 1)];
                return [NSString stringWithFormat:@"%@ %@", kw, nm];
            }
            return [NSString stringWithFormat:@"%@ /*anon*/", kw];
        }
        case '[': {
            NSUInteger start = *idx - 1;
            while (*idx < enc.length && [enc characterAtIndex:*idx] != ']') (*idx)++;
            if (*idx < enc.length) (*idx)++;
            return [enc substringWithRange:NSMakeRange(start, *idx - start)];
        }
        default:
            return [NSString stringWithFormat:@"%C", (unichar)c];
    }
}

static NSArray<NSString *> *DKParseTypeEncoding(NSString *enc) {
    NSMutableArray *res = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < enc.length) {
        unichar c = [enc characterAtIndex:i];
        if (c >= '0' && c <= '9') { i++; continue; }
        if (c == 'r' || c == 'n' || c == 'N' || c == 'o' || c == 'O' || c == 'R' || c == 'V') { i++; continue; }
        NSString *t = DKParseSingleType(enc, &i);
        if (t) [res addObject:t]; else i++;
    }
    return res;
}

static NSString *DKFormatMethod(NSString *sel, NSString *enc) {
    NSArray<NSString *> *parts = DKParseTypeEncoding(enc ?: @"");
    NSString *ret = parts.count > 0 ? parts[0] : @"void";
    NSMutableArray *argTypes = [NSMutableArray array];
    for (NSUInteger i = 3; i < parts.count; i++) [argTypes addObject:parts[i]];

    NSMutableString *out = [NSMutableString string];
    NSArray *selParts = [sel componentsSeparatedByString:@":"];
    if (selParts.count == 1) {
        [out appendFormat:@"- (%@)%@;", ret, sel];
        return out;
    }
    [out appendFormat:@"- (%@)", ret];
    NSUInteger argIdx = 0;
    for (NSUInteger i = 0; i + 1 < selParts.count; i++) {
        if (argIdx < argTypes.count) {
            [out appendFormat:@"%@:(%@)arg%lu ", selParts[i], argTypes[argIdx], (unsigned long)argIdx];
            argIdx++;
        } else {
            [out appendFormat:@"%@ ", selParts[i]];
        }
    }
    [out appendString:@";"];
    return out;
}

#pragma mark - method_list_t 遍历

static NSString *DKFormatMethodList(void *ptr, BOOL isClassMethod) {
    if (!ptr) return @"";
    DKMethodList_t *list = (DKMethodList_t *)ptr;
    if (list->count == 0 || list->count > 50000) return @"";
    uint32_t entsizeAndFlags = list->entsizeAndFlags;
    uint32_t entsize = entsizeAndFlags & ~0x3u;
    if (entsize < 8 || entsize > 100) return @"";
    BOOL relative = (entsizeAndFlags & 0x3) == 0x3;

    NSMutableString *result = [NSMutableString string];
    uint8_t *base = (uint8_t *)ptr + 8;
    for (uint32_t i = 0; i < list->count; i++) {
        uint8_t *entry = base + (uint64_t)i * entsize;
        NSString *selName = nil;
        NSString *types = nil;
        if (relative) {
            DKRelativeMethod_t *rm = (DKRelativeMethod_t *)entry;
            const char *n = (const char *)(entry + rm->nameOffset);
            const char *t = (const char *)(entry + rm->typesOffset);
            if (n && n[0] >= 0x20 && n[0] < 0x7f) selName = @(n);
            if (t) types = @(t);
        } else {
            DKDirectMethod_t *dm = (DKDirectMethod_t *)entry;
            if (dm->name) selName = NSStringFromSelector(dm->name);
            if (dm->types) types = @(dm->types);
        }
        if (!selName.length) continue;
        NSString *f = DKFormatMethod(selName, types);
        if (f.length) {
            if (isClassMethod && [f hasPrefix:@"- "]) {
                f = [@"+ " stringByAppendingString:[f substringFromIndex:2]];
            }
            [result appendString:f];
            [result appendString:@"\n"];
        }
    }
    return result;
}

#pragma mark - dyld 扫描

static void DKScanImage(uint32_t imageIndex,
                        void (^onCategory)(NSString *, NSString *, NSString *)) {
    const struct mach_header *hdrRaw = _dyld_get_image_header(imageIndex);
    if (!hdrRaw || hdrRaw->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *header = (const struct mach_header_64 *)hdrRaw;
    intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);

    const struct load_command *cmd =
        (const struct load_command *)((uint8_t *)header + sizeof(struct mach_header_64));
    uint32_t ncmds = header->ncmds;

    uintptr_t catlistAddr = 0;
    uint64_t  catlistSize = 0;

    for (uint32_t i = 0; i < ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, "__DATA_CONST") == 0 ||
                strcmp(seg->segname, "__DATA") == 0) {
                const struct section_64 *sect =
                    (const struct section_64 *)((uint8_t *)seg + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (strcmp(sect[j].sectname, "__objc_catlist") == 0) {
                        catlistAddr = (uintptr_t)(sect[j].addr + slide);
                        catlistSize = sect[j].size;
                        break;
                    }
                }
            }
        }
        cmd = (const struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
    }
    if (catlistAddr == 0 || catlistSize == 0) return;

    NSUInteger count = catlistSize / sizeof(uintptr_t);
    if (count > 100000) count = 100000;
    uintptr_t *ptrs = (uintptr_t *)catlistAddr;

    for (NSUInteger i = 0; i < count; i++) {
        @autoreleasepool {
            DKCategory_t *cat = (DKCategory_t *)ptrs[i];
            if (!cat || !cat->name) continue;
            NSString *catName = @(cat->name);
            if (!catName.length) continue;

            Class cls = (__bridge Class)cat->cls;
            if (!cls) continue;
            const char *clsNameC = class_getName(cls);
            if (!clsNameC) continue;
            NSString *className = @(clsNameC);

            NSMutableString *text = [NSMutableString string];
            [text appendString:@"//\n"];
            [text appendFormat:@"// %@ (%@)\n", className, catName];
            [text appendString:@"// 来源: 静态扫描 __objc_catlist (进程内存)\n"];
            [text appendString:@"//\n\n"];
            [text appendFormat:@"@interface %@ (%@)\n\n", className, catName];

            NSString *instM = DKFormatMethodList(cat->instanceMethods, NO);
            NSString *clsM  = DKFormatMethodList(cat->classMethods, YES);
            if (instM.length) { [text appendString:instM]; [text appendString:@"\n"]; }
            if (clsM.length)  { [text appendString:clsM];  [text appendString:@"\n"]; }

            [text appendString:@"@end\n"];
            onCategory(className, catName, text);
        }
    }
}

#pragma mark - 对外 API

void DKStaticDumpCategories(NSString *binaryPath,
                            void (^onCategory)(NSString *className,
                                               NSString *categoryName,
                                               NSString *text)) {
    if (!onCategory) return;

    // 从 binaryPath 提取路径末尾两段用于匹配 dyld image
    NSString *key = nil;
    if (binaryPath.length > 0) {
        NSArray *comps = [binaryPath pathComponents];
        if (comps.count >= 2) {
            key = [comps[comps.count - 2] stringByAppendingPathComponent:comps.lastObject];
        } else {
            key = binaryPath;
        }
    }

    uint32_t total = _dyld_image_count();
    for (uint32_t i = 0; i < total; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        NSString *p = @(path);
        if (key && ![p containsString:key]) continue;
        DKScanImage(i, onCategory);
        if (key) return;  // 命中目标 image 后不再继续
    }
}
