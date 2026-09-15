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
    if (!class_getSuperclass(cls)) {
        return cls == DKcNSObject || cls == DKcNSProxy;
    }
    return YES;
}

// ... 其余部分（DKIsLikelySwiftName、DKClassNameIsRuntimeGenerated、
// DKTypeFromEncoding、DKPropertyLine、DKMethodLine、
// DKHeaderForClass、DKClassDumpHeaderForClass）
// 完全沿用你之前发我的版本即可