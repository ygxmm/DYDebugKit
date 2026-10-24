#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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

void DKStaticDumpCategories(NSString *binaryPath,
                            void (^onCategory)(NSString *className,
                                               NSString *categoryName,
                                               NSString *text)) {
    // iOS 15+ 的 objc 结构体（__objc_const 位于 __DATA 段）里，category_t 的
    // name / instanceMethods / classMethods 字段是 WrappedPtr（relative to
    // field address 的偏移量），不是绝对指针。直接解引用得到垃圾地址，
    // 触发 SIGSEGV（lazyaudio 实测 far=0xa79cd2f5，Translation fault）。
    //
    // 且 SIGSEGV 不是 ObjC exception，@try/@catch 无法捕获。
    //
    // 结论：当前实现无法安全解析 category，临时禁用以免闪退。
    // 后续方案：
    //   1. 研究 objc4 里 WrappedPtr<T, PtrauthStrip> 的 IsRelative 解包规则，
    //      手动还原每个字段的指针（需要拿到 iOS 16 runtime 里对应宏的定义）。
    //   2. 或者用 frida / lief 在外部工具里做 category 解析，输出 JSON 给本 tweak。
    //   3. 或者退回运行时反射：class_copyMethodList 拿 merge 后的方法，
    //      但拿不到 category 名字。
    (void)binaryPath;
    (void)onCategory;
    NSLog(@"[DKStatic] static category parsing disabled on iOS 15+ (WrappedPtr relative offsets)");
}
