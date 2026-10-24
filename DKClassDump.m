//
//  DKClassDump.m
//  DYKiller
//
//  基于 ObjC 运行时生成类头文件文本。
//  DKClassIsSafe 用于限制可内省类集合。
//

#import "DKClassDump.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *DKCString(const char *value) {
    if (!value) return @"";
    NSString *utf8 = [NSString stringWithUTF8String:value];
    if (utf8) return utf8;
    size_t length = strnlen(value, 4096);
    NSString *latin = [[NSString alloc] initWithBytes:value length:length encoding:NSISOLatin1StringEncoding];
    if (latin) return latin;
    NSMutableString *hex = [NSMutableString stringWithString:@"<bytes:"];
    for (size_t i = 0; i < MIN(length, (size_t)64); i++) [hex appendFormat:@"%02x", (unsigned char)value[i]];
    [hex appendString:@">"];
    return hex;
}

#pragma mark - 安全内省检查

// 用 CFSet + NULL 回调按指针身份比较，用于跳过不安全类。
static CFSetRef DKUnsafeClassSet;
static Class DKcNSObject;
static Class DKcNSProxy;

__attribute__((constructor))
static void DKClassDumpInit(void) {
    DKcNSObject = [NSObject class];
    DKcNSProxy = [NSProxy class];

    static const char *const kUnsafeNames[] = {
        "__ARCLite__", "__NSCFCalendar", "__NSCFTimer", "NSCFTimer",
        "__NSGenericDeallocHandler", "NSAutoreleasePool", "NSPlaceholderNumber",
        "NSPlaceholderString", "NSPlaceholderValue", "Object", "VMUArchitecture",
        "JSExport", "__NSAtom", "_NSZombie_", "_CNZombie_", "__NSMessage",
        "__NSMessageBuilder", "FigIrisAutoTrimmerMotionSampleExport", "_UIPointVector",
    };
    NSUInteger n = sizeof(kUnsafeNames) / sizeof(kUnsafeNames[0]);
    const void **classes = malloc(n * sizeof(void *));
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < n; i++) {
        Class c = objc_getClass(kUnsafeNames[i]);
        if (c) classes[count++] = (__bridge const void *)c;
    }
    DKUnsafeClassSet = CFSetCreate(kCFAllocatorDefault, classes, count, NULL);
    free(classes);
}

BOOL DKClassIsSafe(Class cls) {
    if (!cls) return NO;
    if (DKUnsafeClassSet && CFSetContainsValue(DKUnsafeClassSet, (__bridge const void *)cls)) return NO;
    // 无父类者只有 NSObject / NSProxy 两个已知根类是安全的
    if (!class_getSuperclass(cls)) {
        return cls == DKcNSObject || cls == DKcNSProxy;
    }
    return YES;
}

#pragma mark - 过滤

static BOOL DKIsLikelySwiftName(NSString *name) {
    if (name.length == 0) return YES;
    if ([name hasPrefix:@"_Tt"]) return YES;
    if ([name hasPrefix:@"Swift."]) return YES;
    if ([name hasPrefix:@"SwiftUI."]) return YES;
    if ([name containsString:@"<"]) return YES;
    if ([name containsString:@"`"]) return YES;
    if ([name containsString:@"."]) return YES;
    return NO;
}

// Swift mangled name 简化：_TtC6LottieXXX → Lottie.XXX
// 完整 demangle 需 libswiftCore 的 swift_demangle，这里只提取模块名
NSString *DKDeduceSwiftModule(NSString *name) {
    if (![name hasPrefix:@"_TtC"]) return nil;
    const char *c = name.UTF8String + 4;
    // 读模块名长度
    int len = 0;
    while (*c >= '0' && *c <= '9') { len = len * 10 + (*c - '0'); c++; }
    if (len <= 0 || strlen(c) < (size_t)len) return nil;
    return [[NSString alloc] initWithBytes:c length:len encoding:NSUTF8StringEncoding];
}

BOOL DKClassNameIsRuntimeGenerated(NSString *name) {
    if (name.length == 0) return YES;
    if ([name hasPrefix:@"NSKVONotifying_"]) return YES;   // KVO 运行时子类
    if ([name containsString:@"_hmd_subfix_"]) return YES; // Heimdallr 崩溃修复子类
    if ([name containsString:@"_AWEPERF_"]) return YES;    // 性能监控子类
    if ([name containsString:@"_block_invoke"]) return YES;
    if ([name containsString:@"%"]) return YES;
    return NO;
}

#pragma mark - 类型编码 → 可读类型

static NSString *DKTypeFromEncoding(const char *encoding) {
    if (!encoding) return @"id";
    NSString *e = DKCString(encoding);
    if (e.length == 0) return @"id";

    if ([e hasPrefix:@"@\""]) {
        NSRange r1 = [e rangeOfString:@"\""];
        NSRange r2 = [e rangeOfString:@"\"" options:NSBackwardsSearch];
        if (r1.location != NSNotFound && r2.location != NSNotFound && r2.location > r1.location) {
            NSString *cls = [e substringWithRange:NSMakeRange(r1.location + 1, r2.location - r1.location - 1)];
            if (cls.length) return [NSString stringWithFormat:@"%@ *", cls];
        }
    }

    switch ([e characterAtIndex:0]) {
        case 'v': return @"void";
        case '@': return @"id";
        case '#': return @"Class";
        case ':': return @"SEL";
        case 'c': return @"char";
        case 'C': return @"unsigned char";
        case 's': return @"short";
        case 'S': return @"unsigned short";
        case 'i': return @"int";
        case 'I': return @"unsigned int";
        case 'l': return @"long";
        case 'L': return @"unsigned long";
        case 'q': return @"long long";
        case 'Q': return @"unsigned long long";
        case 'f': return @"float";
        case 'd': return @"double";
        case 'B': return @"BOOL";
        case '*': return @"char *";
        case '^': return @"void *";
        case '{': return @"struct";
        case '[': return @"void *";
        default:  return @"id";
    }
}

#pragma mark - 属性 / 方法行

static NSString *DKPropertyLine(objc_property_t property) {
    const char *n = property_getName(property);
    if (!n) return nil;
    NSString *name = DKCString(n);

    NSString *attrs = @"";
    const char *a = property_getAttributes(property);
    if (a) attrs = DKCString(a);

    NSString *type = @"id";
    BOOL readonly = [attrs containsString:@",R"];
    BOOL copy = [attrs containsString:@",C"];
    BOOL weak = [attrs containsString:@",W"];
    BOOL nonatomic = [attrs containsString:@",N"];

    if ([attrs hasPrefix:@"T"]) {
        NSString *typePart = [[attrs substringFromIndex:1] componentsSeparatedByString:@","].firstObject ?: @"@";
        type = DKTypeFromEncoding(typePart.UTF8String);
    }

    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject:(nonatomic ? @"nonatomic" : @"atomic")];
    if (readonly) [parts addObject:@"readonly"];
    if (copy) [parts addObject:@"copy"];
    else if (weak) [parts addObject:@"weak"];
    else if ([type containsString:@"*"] || [type isEqualToString:@"id"]) [parts addObject:@"strong"];
    else [parts addObject:@"assign"];

    return [NSString stringWithFormat:@"@property (%@) %@ %@;", [parts componentsJoinedByString:@", "], type, name];
}

static NSString *DKMethodLine(Method m, BOOL isClassMethod) {
    SEL sel = method_getName(m);
    if (!sel) return nil;

    const char *ret = method_copyReturnType(m);
    NSString *retType = DKTypeFromEncoding(ret);
    if (ret) free((void *)ret);

    NSString *name = NSStringFromSelector(sel);
    if (name.length == 0) return nil;

    unsigned int argCount = method_getNumberOfArguments(m);
    if (![name containsString:@":"] || argCount <= 2) {
        return [NSString stringWithFormat:@"%c (%@)%@;", isClassMethod ? '+' : '-', retType, name];
    }

    NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
    NSMutableString *line = [NSMutableString stringWithFormat:@"%c (%@)", isClassMethod ? '+' : '-', retType];
    for (NSUInteger i = 0; i < parts.count - 1; i++) {
        NSString *label = parts[i];
        char *argTypeRaw = method_copyArgumentType(m, (unsigned int)i + 2);
        NSString *argType = DKTypeFromEncoding(argTypeRaw);
        if (argTypeRaw) free(argTypeRaw);
        if (i == 0) {
            [line appendFormat:@"%@:(%@)arg%lu", label.length ? label : @"method", argType, (unsigned long)i];
        } else {
            [line appendFormat:@" %@:(%@)arg%lu", label.length ? label : @"param", argType, (unsigned long)i];
        }
    }
    [line appendString:@";"];
    return line;
}

#pragma mark - 单类头文件

static NSString *DKHeaderForClass(Class cls, NSString *imageName) {
    if (!DKClassIsSafe(cls)) return nil;
    @try {
        NSString *className = NSStringFromClass(cls);
        if (className.length == 0) return nil;
        if (DKIsLikelySwiftName(className)) {
            return [NSString stringWithFormat:
                    @"// Runtime class: %@\n// Image: %@\n// 该名称不是有效的 Objective-C 标识符，无法生成头文件。\n",
                    className, imageName ?: @"Unknown"];
        }

        Class superCls = class_getSuperclass(cls);
        NSString *superName = superCls ? NSStringFromClass(superCls) : @"NSObject";

        NSMutableString *h = [NSMutableString string];
        [h appendString:@"//\n"];
        [h appendString:@"// Dumped by DYKiller DKClassDump\n"];
        [h appendFormat:@"// Bundle: %@\n", NSBundle.mainBundle.bundleIdentifier ?: @"Unknown"];
        [h appendFormat:@"// Image: %@\n", imageName ?: @"Unknown"];
        [h appendString:@"//\n\n"];
        [h appendString:@"#import <Foundation/Foundation.h>\n"];
        [h appendString:@"#import <UIKit/UIKit.h>\n\n"];

        unsigned int protocolCount = 0;
        Protocol *__unsafe_unretained *protocols = class_copyProtocolList(cls, &protocolCount);
        // 协议方法展开：在 @interface 后追加 @protocol 块
        NSMutableString *protocolBlocks = [NSMutableString string];
        NSMutableArray *protocolNames = [NSMutableArray array];
        for (unsigned int i = 0; i < protocolCount; i++) {
            const char *pn = protocol_getName(protocols[i]);
            if (pn) {
                Protocol *p = protocols[i];
                unsigned int instCount = 0, clsCount = 0;
                struct objc_method_description *instM = protocol_copyMethodDescriptionList(p, YES, YES, &instCount);
                struct objc_method_description *clsM = protocol_copyMethodDescriptionList(p, NO, YES, &clsCount);
                if (instCount > 0 || clsCount > 0) {
                    [protocolBlocks appendFormat:@"\n@protocol %s\n", pn];
                    for (unsigned int j = 0; j < instCount; j++) {
                        [protocolBlocks appendFormat:@"- (%s)%s;\n", "void", sel_getName(instM[j].name)];
                    }
                    for (unsigned int j = 0; j < clsCount; j++) {
                        [protocolBlocks appendFormat:@"+ (%s)%s;\n", "void", sel_getName(clsM[j].name)];
                    }
                    [protocolBlocks appendString:@"@end\n\n"];
                }
                if (instM) free(instM);
                if (clsM) free(clsM);
            }
            if (pn) [protocolNames addObject:DKCString(pn)];
        }
        if (protocols) free(protocols);

        if (protocolNames.count) {
            [h appendFormat:@"@interface %@ : %@ <%@>\n\n", className, superName, [protocolNames componentsJoinedByString:@", "]];
        } else {
            [h appendFormat:@"@interface %@ : %@\n\n", className, superName];
        }

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        if (ivarCount > 0) [h appendString:@"{\n"];
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *in = ivar_getName(ivars[i]);
            const char *it = ivar_getTypeEncoding(ivars[i]);
            if (in) [h appendFormat:@"    %@ %@;\n", DKTypeFromEncoding(it), DKCString(in)];
        }
        if (ivarCount > 0) [h appendString:@"}\n\n"];
        if (ivars) free(ivars);

        unsigned int propertyCount = 0;
        objc_property_t *props = class_copyPropertyList(cls, &propertyCount);
        if (propertyCount > 0) [h appendString:@"#pragma mark - Properties\n\n"];
        for (unsigned int i = 0; i < propertyCount; i++) {
            NSString *line = DKPropertyLine(props[i]);
            if (line.length) [h appendFormat:@"%@\n", line];
        }
        if (props) free(props);

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        if (methodCount > 0) [h appendString:@"\n#pragma mark - Instance Methods\n\n"];
        for (unsigned int i = 0; i < methodCount; i++) {
            @try {
                NSString *line = DKMethodLine(methods[i], NO);
                if (line.length) [h appendFormat:@"%@\n", line];
            } @catch (NSException *e) {
                [h appendFormat:@"// [method %u 解析失败]\n", i];
            }
        }
        if (methods) free(methods);

        Class meta = object_getClass(cls);
        unsigned int classMethodCount = 0;
        Method *classMethods = class_copyMethodList(meta, &classMethodCount);
        if (classMethodCount > 0) [h appendString:@"\n#pragma mark - Class Methods\n\n"];
        for (unsigned int i = 0; i < classMethodCount; i++) {
            NSString *line = DKMethodLine(classMethods[i], YES);
            if (line.length) [h appendFormat:@"%@\n", line];
        }
        if (classMethods) free(classMethods);

        [h appendString:@"\n@end\n"];
        if (protocolBlocks.length > 0) [h appendString:protocolBlocks];
        return h;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

#pragma mark - 对外 API

#pragma mark - Category 导出

#include <mach-o/dyld.h>
#include <mach-o/getsect.h>

// category_t 是私有结构，自己定义
typedef struct {
    const char *name;
    uintptr_t cls;
    uintptr_t instanceMethods;
    uintptr_t classMethods;
    uintptr_t protocols;
    uintptr_t instanceProperties;
} DKCategory_t;

// 返回指定类名对应的 category 头文件文本数组
// 格式：@interface ClassName (CategoryName) <Protocols> ... @end
#pragma mark - 安全指针读取（iOS 16 chained fixup）

#include <mach/vm_region.h>
#include <mach/mach_vm.h>
#include <dlfcn.h>

// 检查指针是否在可读内存
static BOOL DK_PtrReadable(uintptr_t addr) {
    if (addr == 0) return NO;
    vm_address_t rAddr = (vm_address_t)addr;
    vm_size_t rSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_port_t obj;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    kern_return_t kr = vm_region_64(mach_task_self(), &rAddr, &rSize,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &cnt, &obj);
    if (kr != KERN_SUCCESS) return NO;
    if (!(info.protection & VM_PROT_READ)) return NO;
    if (addr < rAddr || addr >= rAddr + rSize) return NO;
    return YES;
}

// 解码可能是 chained fixup rebase 编码的指针
// iOS 16 __DATA_CONST 里存的是 dyld_chained_ptr_64_rebase 格式：
// bits 0-35: target（image-relative）
// bits 36-43: high8
// bits 51-62: next
// bit 63: bind
// 先试原始值，再试解码值
static uintptr_t DK_ResolvePtr(uint64_t raw, uintptr_t slide) {
    if (raw == 0) return 0;

    // 候选 1：原始值（已经被 dyld fixup 过的普通指针）
    if (DK_PtrReadable((uintptr_t)raw)) return (uintptr_t)raw;

    // 候选 2：chained fixup 解码
    uint64_t target = raw & 0xFFFFFFFFFULL;
    uintptr_t decoded = (uintptr_t)(target + slide);
    if (DK_PtrReadable(decoded)) return decoded;

    return 0;
}

// 安全读取 C 字符串（带长度限制 + 内存可读检查）
static NSString *DK_SafeCString(uintptr_t addr, size_t maxLen) {
    if (addr == 0 || maxLen == 0) return nil;
    if (!DK_PtrReadable(addr)) return nil;

    vm_address_t rAddr = (vm_address_t)addr;
    vm_size_t rSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_port_t obj;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    if (vm_region_64(mach_task_self(), &rAddr, &rSize,
                     VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return nil;

    size_t available = (rAddr + rSize) - addr;
    size_t scanLen = MIN(available, maxLen);
    const char *c = (const char *)addr;
    size_t len = 0;
    for (; len < scanLen; len++) {
        if (c[len] == 0) break;
    }
    if (len == 0 || len >= scanLen) return nil;
    return [[NSString alloc] initWithBytes:c length:len encoding:NSUTF8StringEncoding];
}

void DKClassDumpCategoriesForClass(Class cls, void (^writeBlock)(NSString *categoryName, NSString *headerText)) {
    if (!cls || !writeBlock) return;
    NSString *clsName = NSStringFromClass(cls);
    if (clsName.length == 0) return;

    uintptr_t targetCls = (uintptr_t)(__bridge void *)cls;
    uint32_t imageCount = _dyld_image_count();

    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header *headerRaw = _dyld_get_image_header(i);
        if (!headerRaw || headerRaw->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)headerRaw;
        uintptr_t slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);

        unsigned long size = 0;
        uintptr_t *catlist = (uintptr_t *)getsectiondata(header, "__DATA_CONST", "__objc_catlist", &size);
        if (!catlist || size == 0) {
            catlist = (uintptr_t *)getsectiondata(header, "__DATA", "__objc_catlist", &size);
        }
        if (!catlist || size == 0) continue;

        uintptr_t *endPtr = catlist + (size / sizeof(uintptr_t));
        for (uintptr_t *p = catlist; p < endPtr; p++) {
            @autoreleasepool {
                uintptr_t rawCat = *p;
                uintptr_t catPtr = DK_ResolvePtr(rawCat, slide);
                if (!catPtr) continue;

                DKCategory_t *cat = (DKCategory_t *)catPtr;
                if (!cat) continue;

                // 解析 cat->cls
                uintptr_t rawCls = (uintptr_t)cat->cls;
                uintptr_t resolvedCls = DK_ResolvePtr(rawCls, slide);
                if (resolvedCls != targetCls) continue;

                // 解析 cat->name
                uintptr_t rawName = (uintptr_t)cat->name;
                uintptr_t namePtr = DK_ResolvePtr(rawName, slide);
                if (!namePtr) continue;
                NSString *catName = DK_SafeCString(namePtr, 256);
                if (!catName) continue;

                @try {
                    NSMutableString *h = [NSMutableString string];
                    [h appendFormat:@"@interface %@ (%@)", clsName, catName];

                    // 协议列表
                    uintptr_t rawProtos = (uintptr_t)cat->protocols;
                    uintptr_t protosPtr = DK_ResolvePtr(rawProtos, slide);
                    if (protosPtr) {
                        uintptr_t *pl = (uintptr_t *)protosPtr;
                        uintptr_t pcount = pl[0];
                        if (pcount > 0 && pcount < 1000) {
                            NSMutableArray *protos = [NSMutableArray array];
                            for (uintptr_t j = 0; j < pcount; j++) {
                                uintptr_t rawP = pl[j + 1];
                                uintptr_t pPtr = DK_ResolvePtr(rawP, slide);
                                if (!pPtr) continue;
                                Protocol *proto = (__bridge Protocol *)((void *)pPtr);
                                if (proto) {
                                    const char *pn = protocol_getName(proto);
                                    if (pn) {
                                        NSString *pnStr = [NSString stringWithUTF8String:pn];
                                        if (pnStr) [protos addObject:pnStr];
                                    }
                                }
                            }
                            if (protos.count > 0) {
                                [h appendFormat:@" <%@>", [protos componentsJoinedByString:@", "]];
                            }
                        }
                    }
                    [h appendString:@"\n\n"];

                    // category 属性
                    uintptr_t rawProps = (uintptr_t)cat->instanceProperties;
                    uintptr_t propsPtr = DK_ResolvePtr(rawProps, slide);
                    if (propsPtr) {
                        uint32_t *pl = (uint32_t *)propsPtr;
                        uint32_t entsize = pl[0] & 0xFFFFFFFC;
                        uint32_t count = pl[1];
                        if (count > 0 && count < 10000 && entsize >= 16 && entsize <= 128) {
                            for (uint32_t j = 0; j < count; j++) {
                                uint8_t *entry = (uint8_t *)propsPtr + 8 + j * entsize;
                                uintptr_t rawPn = *(uintptr_t *)entry;
                                uintptr_t rawPa = *(uintptr_t *)(entry + 8);
                                uintptr_t pnPtr = DK_ResolvePtr(rawPn, slide);
                                if (!pnPtr) continue;
                                NSString *pName = DK_SafeCString(pnPtr, 256);
                                if (!pName) continue;
                                NSString *pAttr = nil;
                                uintptr_t paPtr = DK_ResolvePtr(rawPa, slide);
                                if (paPtr) pAttr = DK_SafeCString(paPtr, 512);
                                [h appendFormat:@"@property %@ %@;\n",
                                 pAttr ?: @"", pName];
                            }
                            [h appendString:@"\n"];
                        }
                    }

                    // category 实例方法
                    uintptr_t rawIM = (uintptr_t)cat->instanceMethods;
                    uintptr_t imPtr = DK_ResolvePtr(rawIM, slide);
                    if (imPtr) {
                        uint32_t *ml = (uint32_t *)imPtr;
                        uint32_t entsize = ml[0] & 0xFFFFFFFC;
                        uint32_t count = ml[1];
                        if (count > 0 && count < 10000 && entsize >= 24 && entsize <= 128) {
                            for (uint32_t j = 0; j < count; j++) {
                                uint8_t *entry = (uint8_t *)imPtr + 8 + j * entsize;
                                uintptr_t rawSel = *(uintptr_t *)entry;
                                uintptr_t selPtr = DK_ResolvePtr(rawSel, slide);
                                if (!selPtr) continue;
                                NSString *selStr = DK_SafeCString(selPtr, 512);
                                if (!selStr) continue;
                                [h appendFormat:@"- (void)%@;\n", selStr];
                            }
                        }
                    }

                    // category 类方法
                    uintptr_t rawCM = (uintptr_t)cat->classMethods;
                    uintptr_t cmPtr = DK_ResolvePtr(rawCM, slide);
                    if (cmPtr) {
                        uint32_t *ml = (uint32_t *)cmPtr;
                        uint32_t entsize = ml[0] & 0xFFFFFFFC;
                        uint32_t count = ml[1];
                        if (count > 0 && count < 10000 && entsize >= 24 && entsize <= 128) {
                            for (uint32_t j = 0; j < count; j++) {
                                uint8_t *entry = (uint8_t *)cmPtr + 8 + j * entsize;
                                uintptr_t rawSel = *(uintptr_t *)entry;
                                uintptr_t selPtr = DK_ResolvePtr(rawSel, slide);
                                if (!selPtr) continue;
                                NSString *selStr = DK_SafeCString(selPtr, 512);
                                if (!selStr) continue;
                                [h appendFormat:@"+ (void)%@;\n", selStr];
                            }
                        }
                    }

                    [h appendString:@"@end\n"];
                    writeBlock(catName, h);
                } @catch (NSException *e) {
                }
            }
        }
    }
}

#pragma mark - Mach-O 静态解析

#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/nlist.h>
#include <objc/runtime.h>

// 遍历所有已加载 image 的 __objc_classlist，返回 class_t* 数组
// 运行时指针已重定位，直接解引用，不需要自己算 base address
NSArray<NSValue *> *DKClassDumpAllClassesFromMachO(void) {
    NSMutableArray<NSValue *> *result = [NSMutableArray array];
    uint32_t imageCount = _dyld_image_count();

    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *h64 = (const struct mach_header_64 *)h;

        unsigned long size = 0;
        uintptr_t *classlist = (uintptr_t *)getsectiondata(h64, "__DATA_CONST", "__objc_classlist", &size);
        if (!classlist || size == 0) {
            classlist = (uintptr_t *)getsectiondata(h64, "__DATA", "__objc_classlist", &size);
        }
        if (!classlist || size == 0) continue;

        uintptr_t *end = classlist + (size / sizeof(uintptr_t));
        for (uintptr_t *p = classlist; p < end; p++) {
            uintptr_t cls = *p;
            if (cls) [result addObject:[NSValue valueWithPointer:(void *)cls]];
        }
    }
    return result;
}

// Phase 1 测试：统计每个 image 的类数量
NSDictionary<NSString *, NSNumber *> *DKClassDumpCountClassesPerImage(void) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    uint32_t imageCount = _dyld_image_count();

    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *imageName = [[NSString stringWithUTF8String:name] lastPathComponent];
        const struct mach_header_64 *h64 = (const struct mach_header_64 *)h;

        unsigned long size = 0;
        uintptr_t *classlist = (uintptr_t *)getsectiondata(h64, "__DATA_CONST", "__objc_classlist", &size);
        if (!classlist || size == 0) {
            classlist = (uintptr_t *)getsectiondata(h64, "__DATA", "__objc_classlist", &size);
        }
        if (!classlist || size == 0) continue;

        NSUInteger count = size / sizeof(uintptr_t);
        counts[imageName] = @(count);
    }
    return counts;
}

NSString *DKClassDumpHeaderForClass(Class cls) {
    if (!DKClassIsSafe(cls)) return nil;
    NSString *imageName = @"Unknown";
    const char *img = class_getImageName(cls);
    if (img) imageName = [DKCString(img) lastPathComponent] ?: @"Unknown";
    return DKHeaderForClass(cls, imageName);
}