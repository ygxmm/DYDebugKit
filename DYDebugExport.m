#import "DYDebugExport.h"

NSURL *DYDebugExportSnapshot(DYDebugSnapshot *snapshot, NSError **error) {
    if (!snapshot) return nil;
    NSString *name = [NSString stringWithFormat:@"DYDebugKit-%@", [[NSUUID UUID].UUIDString substringToIndex:8]];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSDictionary *meta = snapshot.metadata ?: @{};
    NSData *json = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:error];
    if (!json) return nil;
    [json writeToFile:[root stringByAppendingPathComponent:@"metadata.json"] options:NSDataWritingAtomic error:error];
    [snapshot.viewTree dataUsingEncoding:NSUTF8StringEncoding].writeToFile([root stringByAppendingPathComponent:@"view-tree.txt"], YES);
    [snapshot.viewControllers dataUsingEncoding:NSUTF8StringEncoding].writeToFile([root stringByAppendingPathComponent:@"view-controllers.txt"], YES);
    [snapshot.screenshotPNG writeToFile:[root stringByAppendingPathComponent:@"screenshot.png"] atomically:YES];
    NSString *index = [root stringByAppendingPathComponent:@"README.txt"];
    [@"DYDebugKit diagnostic snapshot\nFiles: metadata.json, view-tree.txt, view-controllers.txt, screenshot.png\n" writeToFile:index atomically:YES encoding:NSUTF8StringEncoding error:error];
    return [NSURL fileURLWithPath:root isDirectory:YES];
}
