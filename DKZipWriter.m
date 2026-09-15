//
//  DKZipWriter.m
//  DYKiller
//
//  调试导出使用的最小 ZIP 写入器。
//  写入存储条目，并使用 zlib 计算 CRC32。
//

#import "DKZipWriter.h"
#import <CoreFoundation/CoreFoundation.h>
#import <zlib.h>

static void DKZipAppendUInt16(NSMutableData *data, uint16_t value) {
    uint16_t v = CFSwapInt16HostToLittle(value);
    [data appendBytes:&v length:sizeof(v)];
}

// ... 其余部分完全沿用你之前发我的版本