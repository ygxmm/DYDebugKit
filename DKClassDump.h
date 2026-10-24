//
//  DKClassDump.h
//  DYKiller
//
//  把 ObjC 运行时元数据生成类头文件文本。内置安全内省检查。
//

#ifndef DKClassDump_h
#define DKClassDump_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 该类是否可安全内省（不安全类集合 + 根类检查）。
BOOL DKClassIsSafe(Class cls);

/// 该类名是否为运行时生成的子类噪声（NSKVONotifying_ / _hmd_subfix_ / _AWEPERF_ / _block_invoke / %）。
BOOL DKClassNameIsRuntimeGenerated(NSString *name);

/// 生成单个类的头文件文本。
/// 内含安全内省检查 + @try 兜底；不安全 / nil 一律返回 nil。
NSString *DKClassDumpHeaderForClass(Class cls);

/// 导出指定类的所有 category 头文件文本（每个 category 一个 @interface...@end 块）。
/// 通过扫描 Mach-O 的 __objc_catlist section 获得。
NSArray<NSString *> *DKClassDumpCategoriesForClass(Class cls);

#ifdef __cplusplus
}
#endif

#endif /* DKClassDump_h */