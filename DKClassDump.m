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
NSArray<NSString *> *DKClassDumpCategoriesForClass(Class cls) {
    if (!cls) return @[];
    NSString *clsName = NSStringFromClass(cls);
    if (clsName.length == 0) return @[];

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    uint32_t imageCount = _dyld_image_count();

    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header) continue;
        unsigned long size = 0;
        uintptr_t *catlist = NULL;
        // 优先 __DATA_CONST，再试 __DATA
        catlist = (uintptr_t *)getsectiondata(header, "__DATA_CONST", "__objc_catlist", &size);
        if (!catlist) {
            catlist = (uintptr_t *)getsectiondata(header, "__DATA", "__objc_catlist", &size);
        }
        if (!catlist || size == 0) continue;

        uintptr_t *end = catlist + (size / sizeof(uintptr_t));
        for (uintptr_t *p = catlist; p < end; p++) {
            DKCategory_t *cat = (DKCategory_t *)(*p);
            if (!cat || !cat->name) continue;
            if (cat->cls != (uintptr_t)(__bridge void *)cls) continue;

            @try {
                NSMutableString *h = [NSMutableString string];
                [h appendFormat:@"@interface %@ (%@)", clsName, [NSString stringWithUTF8String:cat->name]];

                // 协议列表
                if (cat->protocols) {
                    // protocol_list_t: uintptr_t count; void *list[count];
                    uintptr_t *pl = (uintptr_t *)cat->protocols;
                    uintptr_t pcount = pl[0];
                    if (pcount > 0) {
                        [h appendString:@" <"];
                        for (uintptr_t j = 0; j < pcount; j++) {
                            Protocol *proto = (__bridge Protocol *)((void *)pl[j + 1]);
                            if (proto) {
                                const char *pn = protocol_getName(proto);
                                if (pn) {
                                    if (j > 0) [h appendString:@", "];
                                    [h appendString:[NSString stringWithUTF8String:pn]];
                                }
                            }
                        }
                        [h appendString:@">"];
                    }
                }
                [h appendString:@"\n\n"];

                // category 属性
                if (cat->instanceProperties) {
                    // property_list_t: uint32_t entsizeAndFlags; uint32_t count; property_t list[count];
                    uint32_t *pl = (uint32_t *)cat->instanceProperties;
                    uint32_t entsize = pl[0] & 0xFFFFFFFC;
                    uint32_t count = pl[1];
                    if (count > 0 && entsize >= 16) {
                        for (uint32_t j = 0; j < count; j++) {
                            uint8_t *entry = (uint8_t *)cat->instanceProperties + 8 + j * entsize;
                            const char *pname = *(const char **)entry;
                            const char *pattrs = *(const char **)(entry + 8);
                            if (pname) {
                                [h appendFormat:@"@property %s %s;\n",
                                 pattrs ?: "", pname];
                            }
                        }
                        [h appendString:@"\n"];
                    }
                }

                // category 实例方法
                if (cat->instanceMethods) {
                    uint32_t *ml = (uint32_t *)cat->instanceMethods;
                    uint32_t entsize = ml[0] & 0xFFFFFFFC;
                    uint32_t count = ml[1];
                    if (count > 0 && entsize >= 24) {
                        for (uint32_t j = 0; j < count; j++) {
                            uint8_t *entry = (uint8_t *)cat->instanceMethods + 8 + j * entsize;
                            SEL sel = *(SEL *)entry;
                            const char *types = *(const char **)(entry + 8);
                            if (sel) {
                                [h appendFormat:@"- (%s)%s;\n", "void", sel_getName(sel)];
                            }
                        }
                    }
                }

                // category 类方法
                if (cat->classMethods) {
                    uint32_t *ml = (uint32_t *)cat->classMethods;
                    uint32_t entsize = ml[0] & 0xFFFFFFFC;
                    uint32_t count = ml[1];
                    if (count > 0 && entsize >= 24) {
                        for (uint32_t j = 0; j < count; j++) {
                            uint8_t *entry = (uint8_t *)cat->classMethods + 8 + j * entsize;
                            SEL sel = *(SEL *)entry;
                            if (sel) {
                                [h appendFormat:@"+ (%s)%s;\n", "void", sel_getName(sel)];
                            }
                        }
                    }
                }

                [h appendString:@"@end\n"];
                [result addObject:h];
            } @catch (NSException *e) {
                // 单个 category 失败不影响其他
            }
        }
    }
    return result;
}

NSString *DKClassDumpHeaderForClass(Class cls) {
    if (!DKClassIsSafe(cls)) return nil;
    NSString *imageName = @"Unknown";
    const char *img = class_getImageName(cls);
    if (img) imageName = [DKCString(img) lastPathComponent] ?: @"Unknown";
    return DKHeaderForClass(cls, imageName);
}