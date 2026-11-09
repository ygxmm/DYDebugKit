#import <Foundation/Foundation.h>

void TZStaticDumpCategories(NSString *binaryPath,
                            void (^onCategory)(NSString *className, NSString *categoryName, NSString *text));
