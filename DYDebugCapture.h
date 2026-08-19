#import <UIKit/UIKit.h>

@interface DYDebugSnapshot : NSObject
@property(nonatomic,copy) NSDictionary *metadata;
@property(nonatomic,copy) NSArray *windows;
@property(nonatomic,copy) NSString *viewTree;
@property(nonatomic,copy) NSString *viewControllers;
@property(nonatomic,strong) NSData *screenshotPNG;
@end

DYDebugSnapshot *DYDebugCaptureSnapshot(UIWindow *window);
UIWindow *DYDebugTargetWindow(void);
UIViewController *DYDebugTopViewController(UIViewController *root);
