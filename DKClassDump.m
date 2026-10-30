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

static NSString *DKTypeFromEncoding(const char *encoding);
static NSString *DKParseBlockSignature(const char *s); // DK_BLOCK_SIGNATURE
static const char *DKSkipBlockSignature(const char *p);

static NSString *DKTypeFromEncoding(const char *encoding) {
    if (!encoding || !*encoding) return @"id";
    const char *s = encoding;
    while (*s == 'r' || *s == 'n' || *s == 'N' || *s == 'o' || *s == 'O' || *s == 'R' || *s == 'V') s++;
    char c = *s;
    switch (c) {
        case 'v': return @"void";
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
        case 'D': return @"long double";
        case 'B': return @"BOOL";
        case '*': return @"char *";
        case ':': return @"SEL";
        case '#': return @"Class";
        case '?': return @"void *";
        case '@':
            if (s[1] == '?') {
                if (s[2] == '<') return DKParseBlockSignature(s + 2);
                return @"id /* block */";
            }
            if (s[1] == '"') {
                const char *st = s + 2;
                const char *en = strchr(st, '"');
                if (en) {
                    NSString *nm = [[NSString alloc] initWithBytes:st
                        length:(NSUInteger)(en - st)
                        encoding:NSUTF8StringEncoding];
                    if (nm.length > 0) {
                        if ([nm characterAtIndex:0] == '<') {
                            return [NSString stringWithFormat:@"id%@", nm];
                        }
                        return [NSString stringWithFormat:@"%@ *", nm];
                    }
                }
            }
            return @"id";
        case '^': {
            NSString *inner = DKTypeFromEncoding(s + 1);
            return [NSString stringWithFormat:@"%@ *", inner];
        }
        case '{': {
            const char *pp = s + 1;
            const char *ns = pp;
            while (*pp && *pp != '=' && *pp != '}') pp++;
            size_t nl = (size_t)(pp - ns);
            if (nl > 0) {
                char b[128] = {0};
                size_t nn = nl < 127 ? nl : 127;
                memcpy(b, ns, nn);
                NSString *nm = [NSString stringWithUTF8String:b];
                if (nm.length > 0) {
                    if ([nm hasPrefix:@"_"]) nm = [nm substringFromIndex:1];
                    return nm;
                }
            }
            return @"void *";
        }
        case '(': return @"void *";
        case '[': {
            const char *pp = s + 1;
            while (*pp >= '0' && *pp <= '9') pp++;
            NSString *inner = DKTypeFromEncoding(pp);
            return [NSString stringWithFormat:@"%@ *", inner];
        }
        case 'b': return @"unsigned int";
        default: return @"id";
    }
}

// DK_BLOCK_SIGNATURE: 跳过 block 签名 <...>，返回 '>' 之后
static const char *DKSkipBlockSignature(const char *p) {
    if (!p || *p != '<') return p;
    int depth = 1; p++;
    while (*p && depth > 0) { if (*p == '<') depth++; else if (*p == '>') depth--; p++; }
    return p;
}

// DK_BLOCK_SIGNATURE: 解析 @?<...>，输出 "ret (^)(args)"
static NSString *DKParseBlockSignature(const char *s) {
    if (!s || *s != '<') return @"id /* block */";
    const char *p = s + 1;
    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' || *p == 'R' || *p == 'V') p++;
    const char *retStart = p;
    if (*p == '{') { int d = 1; p++; while (*p && d > 0) { if (*p == '{') d++; else if (*p == '}') d--; p++; } }
    else if (*p == '^') { p++; if (*p) p++; }
    else if (*p == '[') { int d = 1; p++; while (*p && d > 0) { if (*p == '[') d++; else if (*p == ']') d--; p++; } }
    else if (*p == '@') { if (p[1] == '"') { p += 2; while (*p && *p != '"') p++; if (*p == '"') p++; } else if (p[1] == '?') { p += 2; if (*p == '<') p = DKSkipBlockSignature(p); } else p++; }
    else if (*p) p++;
    while (*p >= '0' && *p <= '9') p++;
    size_t retLen = (size_t)(p - retStart); if (retLen > 255) retLen = 255;
    char retBuf[256] = {0}; memcpy(retBuf, retStart, retLen);
    NSString *retType = DKTypeFromEncoding(retBuf);
    if (*p == '@') p++;
    while (*p >= '0' && *p <= '9') p++;
    if (*p == '?') p++;
    while (*p >= '0' && *p <= '9') p++;
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    while (*p && *p != '>') {
        while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' || *p == 'R' || *p == 'V') p++;
        if (!*p || *p == '>') break;
        const char *argStart = p;
        if (*p == '{') { int d = 1; p++; while (*p && d > 0) { if (*p == '{') d++; else if (*p == '}') d--; p++; } }
        else if (*p == '^') { p++; if (*p) { if (*p == '{') { int d=1; p++; while (*p && d>0) { if (*p=='{')d++; else if (*p=='}')d--; p++; } } else p++; } }
        else if (*p == '[') { int d = 1; p++; while (*p && d > 0) { if (*p == '[') d++; else if (*p == ']') d--; p++; } }
        else if (*p == '@') { if (p[1] == '"') { p += 2; while (*p && *p != '"') p++; if (*p == '"') p++; } else if (p[1] == '?') { p += 2; if (*p == '<') p = DKSkipBlockSignature(p); } else p++; }
        else if (*p) p++;
        while (*p >= '0' && *p <= '9') p++;
        size_t aLen = (size_t)(p - argStart); if (aLen > 255) aLen = 255;
        char argBuf[256] = {0}; memcpy(argBuf, argStart, aLen);
        [args addObject:DKTypeFromEncoding(argBuf)];
    }
    if (args.count == 0) return [NSString stringWithFormat:@"%@ (^)(void)", retType];
    return [NSString stringWithFormat:@"%@ (^)(%@)", retType, [args componentsJoinedByString:@", "]];
}

#pragma mark - 属性 / 方法行

static NSString *DKProtocolMethodLine(SEL sel, const char *types, BOOL isClassMethod) {
    if (!sel) return nil;
    const char *name = sel_getName(sel);
    if (!name) return nil;
    NSString *nameStr = [NSString stringWithUTF8String:name];
    if (!nameStr.length) return nil;

    NSString *retType = @"void";
    NSMutableArray<NSString *> *argTypes = [NSMutableArray array];

    if (types && *types) {
        const char *p = types;
        retType = DKTypeFromEncoding(p);
        // 跳过返回值类型
        while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' || *p == 'R' || *p == 'V') p++;
        char rc = *p;
        if (rc == '{') { int d = 1; p++; while (*p && d > 0) { if (*p == '{') d++; else if (*p == '}') d--; p++; } }
        else if (rc == '^') { p++; if (*p) p++; }
        else if (rc == '[') { int d = 1; p++; while (*p && d > 0) { if (*p == '[') d++; else if (*p == ']') d--; p++; } }
        else if (rc == '@') { if (p[1] == '"') { p += 2; while (*p && *p != '"') p++; if (*p == '"') p++; } else p++; }
        else if (*p) p++;
        // 跳过返回值偏移数字
        while (*p >= '0' && *p <= '9') p++;
        // 跳过 self(@) 类型 + 偏移
        if (*p == '@') p++;
        while (*p >= '0' && *p <= '9') p++;
        // 跳过 _cmd(:) 类型 + 偏移
        if (*p == ':') p++;
        while (*p >= '0' && *p <= '9') p++;

        // 逐个参数解析
        while (*p) {
            while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' || *p == 'R' || *p == 'V') p++;
            if (!*p) break;
            NSString *t = DKTypeFromEncoding(p);
            [argTypes addObject:t ?: @"id"];
            char c2 = *p;
            if (c2 == '{') { int d = 1; p++; while (*p && d > 0) { if (*p == '{') d++; else if (*p == '}') d--; p++; } }
            else if (c2 == '^') { p++; if (*p) { if (*p == '{') { int d=1; p++; while (*p && d>0) { if (*p=='{')d++; else if (*p=='}')d--; p++; } } else p++; } }
            else if (c2 == '[') { int d = 1; p++; while (*p && d > 0) { if (*p == '[') d++; else if (*p == ']') d--; p++; } }
            else if (c2 == '@') { if (p[1] == '"') { p += 2; while (*p && *p != '"') p++; if (*p == '"') p++; } else if (p[1] == '?') { p += 2; if (*p == '<') p = DKSkipBlockSignature(p); } else p++; }
            else if (*p) p++;
            while (*p >= '0' && *p <= '9') p++;
        }
    }

    NSArray<NSString *> *parts = [nameStr componentsSeparatedByString:@":"];
    NSInteger argCount = 0;
    if ([nameStr containsString:@":"]) argCount = (NSInteger)parts.count - 1;

    NSMutableString *line = [NSMutableString string];
    [line appendFormat:@"%c (%@)", isClassMethod ? '+' : '-', retType];
    if (argCount <= 0) {
        [line appendFormat:@"%@;\n", nameStr];
        return line;
    }
    for (NSInteger k = 0; k < argCount; k++) {
        NSString *seg = (k < (NSInteger)parts.count) ? parts[k] : @"";
        NSString *t = (k < (NSInteger)argTypes.count) ? argTypes[k] : @"id";
        if (k == 0) {
            [line appendFormat:@"%@:(%@)", seg, t]; // DK_NO_ARGN
        } else {
            [line appendFormat:@" %@:(%@)", seg, t]; // DK_NO_ARGN
        }
    }
    [line appendString:@";\n"];
    return line;
}

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

        // DK_PROTO_FALLBACK: typePart 带 <...> 协议但 type 未保留时补回去。
        // 覆盖 id<Proto> / Class<Proto>；UIView<Proto> * 若已保留则跳过。
        if ([typePart containsString:@"<"] && ![type containsString:@"<"]) {
            NSRange lt = [typePart rangeOfString:@"<"];
            NSRange gt = [typePart rangeOfString:@">" options:NSBackwardsSearch];
            if (lt.location != NSNotFound && gt.location != NSNotFound && gt.location > lt.location) {
                NSString *proto = [typePart substringWithRange:NSMakeRange(lt.location, gt.location - lt.location + 1)];
                if ([type isEqualToString:@"id"] || [type isEqualToString:@"Class"]) {
                    type = [type stringByAppendingString:proto];
                } else if ([type hasSuffix:@" *"]) {
                    type = [[type substringToIndex:type.length - 2]
                            stringByAppendingFormat:@"%@ *", proto];
                }
            }
        }
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

    if (![name containsString:@":"]) {
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
            [line appendFormat:@"%@:(%@)", label.length ? label : @"method", argType]; // DK_NO_ARGN
        } else {
            [line appendFormat:@" %@:(%@)", label.length ? label : @"param", argType]; // DK_NO_ARGN
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
        // 仅对纯 Swift mangled name (如 _TtC...) 跳过，允许带点(.)的 ObjC 兼容类强行输出
        if ([className hasPrefix:@"_Tt"] || [className hasPrefix:@"Swift."] || [className hasPrefix:@"SwiftUI."]) {
            return [NSString stringWithFormat:
                    @"// Runtime class: %@\n// Image: %@\n// 纯 Swift 类 (mangled name)，未暴露为 ObjC 类\n",
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
                        NSString *ln = DKProtocolMethodLine(instM[j].name, instM[j].types, NO);
                        if (ln) [protocolBlocks appendString:ln];
                    }
                    for (unsigned int j = 0; j < clsCount; j++) {
                        NSString *ln = DKProtocolMethodLine(clsM[j].name, clsM[j].types, YES);
                        if (ln) [protocolBlocks appendString:ln];
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

        // DK_FEATURE_FORWARD: 扫描 h 提取类名/协议名，在 #import 后插入前向声明
        NSRange importEnd = [h rangeOfString:@"#import <UIKit/UIKit.h>\n\n"];
        if (importEnd.location != NSNotFound) {
            NSMutableSet<NSString *> *fwdClasses = [NSMutableSet set];
            NSMutableSet<NSString *> *fwdProtocols = [NSMutableSet setWithArray:protocolNames];

            // 从 <...> 里扫协议
            NSRegularExpression *protoRe = [NSRegularExpression
                regularExpressionWithPattern:@"<([^>]+)>" options:0 error:nil];
            for (NSTextCheckingResult *m in [protoRe matchesInString:h options:0
                                                    range:NSMakeRange(0, h.length)]) {
                NSString *inner = [h substringWithRange:[m rangeAtIndex:1]];
                for (NSString *p in [inner componentsSeparatedByString:@","]) {
                    NSString *trimmed = [p stringByTrimmingCharactersInSet:
                                         [NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length > 0 && [trimmed rangeOfString:@"<"].location == NSNotFound) {
                        [fwdProtocols addObject:trimmed];
                    }
                }
            }

            // 从 `类名 *` 扫类
            NSRegularExpression *clsRe = [NSRegularExpression
                regularExpressionWithPattern:@"\\b([A-Z][A-Za-z0-9_]+)\\s*\\*" options:0 error:nil];
            for (NSTextCheckingResult *m in [clsRe matchesInString:h options:0
                                                   range:NSMakeRange(0, h.length)]) {
                [fwdClasses addObject:[h substringWithRange:[m rangeAtIndex:1]]];
            }

            // 过滤系统类/协议
            NSSet *sys = [NSSet setWithArray:@[
                @"NSString", @"NSArray", @"NSMutableArray", @"NSDictionary", @"NSMutableDictionary",
                @"NSObject", @"NSNumber", @"NSData", @"NSDate", @"NSError", @"NSURL", @"NSBundle",
                @"NSSet", @"NSMutableSet", @"NSHashTable", @"NSNotification", @"NSCoder",
                @"NSCoding", @"NSCopying", @"NSMutableCopying", @"NSSecureCoding", @"NSFastEnumeration",
                @"UIView", @"UIViewController", @"UIImage", @"UIColor", @"UIFont", @"UIWindow",
                @"UIApplication", @"UIScreen", @"UIButton", @"UILabel", @"UITableView",
                @"UICollectionView", @"UIScrollView", @"UITableViewCell", @"UICollectionViewCell",
                @"UITextField", @"UITextView", @"UINavigationController", @"UITabBarController",
                @"UIResponder", @"UIControl", @"UIStackView", @"UIGestureRecognizer",
            ]];
            [fwdClasses minusSet:sys];
            [fwdProtocols minusSet:sys];
            [fwdClasses removeObject:className];
            [fwdClasses removeObject:superName];
            [fwdClasses minusSet:fwdProtocols];

            NSMutableString *fwd = [NSMutableString string];
            for (NSString *c in [[fwdClasses allObjects]
                                 sortedArrayUsingSelector:@selector(compare:)]) {
                [fwd appendFormat:@"@class %@;\n", c];
            }
            for (NSString *p in [[fwdProtocols allObjects]
                                 sortedArrayUsingSelector:@selector(compare:)]) {
                [fwd appendFormat:@"@protocol %@;\n", p];
            }
            if (fwd.length > 0) {
                [h insertString:[NSString stringWithFormat:@"%@\n", fwd]
                        atIndex:importEnd.location + importEnd.length];
            }
        }

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

// 返回指定类名对应的 category 头文件文本数组
// 格式：@interface ClassName (CategoryName) <Protocols> ... @end
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
// DK_WARNING_CLEANUP