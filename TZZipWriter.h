//
//  TZZipWriter.h
//  tz
//
//  调试导出使用的最小 ZIP 写入器。
//  以不压缩方式写入文件，使用 zlib 计算 CRC32，并支持 ZIP64 条目计数。
//

#ifndef TZZipWriter_h
#define TZZipWriter_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TZZipProgressBlock)(CGFloat progress);

@interface TZZipWriter : NSObject

+ (BOOL)createZipAtPath:(NSString *)zipPath
                rootDir:(NSString *)rootDir
                  files:(NSArray<NSString *> *)files
               progress:(TZZipProgressBlock _Nullable)progress
                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* TZZipWriter_h */