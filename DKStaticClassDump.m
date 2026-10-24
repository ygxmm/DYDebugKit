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

// 只输出 category 的 visitor：继承 CDTextClassDumpVisitor 复用 category 文本生成逻辑
@interface DKCategoryVisitor : CDTextClassDumpVisitor
@property (nonatomic, copy) void (^onCategory)(NSString *className, NSString *categoryName, NSString *text);
@property (nonatomic, assign) NSUInteger categoryStartIndex;
@end

@implementation DKCategoryVisitor

- (void)willVisitClass:(CDOCClass *)aClass {
    // 忽略 class 输出，只关心 category
}

- (void)willVisitProtocol:(CDOCProtocol *)protocol {
    // 忽略 protocol 输出
}

- (void)willVisitCategory:(CDOCCategory *)category {
    // 清空结果，从当前 category 重新开始
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

// 对外桥接函数：对目标二进制做静态解析，每个 category 回调一次
void DKStaticDumpCategories(NSString *binaryPath,
                            void (^onCategory)(NSString *className, NSString *categoryName, NSString *text)) {
    if (binaryPath.length == 0 || !onCategory) return;

    CDSearchPathState *searchPathState = [[CDSearchPathState alloc] init];
    CDFile *file = [CDFile fileWithContentsOfFile:binaryPath searchPathState:searchPathState];
    if (!file) return;

    CDMachOFile *machOFile = nil;
    if ([file isKindOfClass:[CDFatFile class]]) {
        CDArch arch = {CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL};
        machOFile = [file machOFileWithArch:arch];
    } else {
        machOFile = (CDMachOFile *)file;
    }
    if (!machOFile) return;

    CDObjectiveCProcessor *processor = [[[machOFile processorClass] alloc] initWithMachOFile:machOFile];
    if (!processor) return;
    [processor process];

    DKCategoryVisitor *visitor = [[DKCategoryVisitor alloc] init];
    visitor.onCategory = onCategory;
    [processor recursivelyVisit:visitor];
}
