#import <Foundation/Foundation.h>

void DKStaticDumpCategories(NSString *binaryPath,
                            void (^onCategory)(NSString *className, NSString *categoryName, NSString *text));
