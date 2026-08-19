#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYDebugSnapshot : NSObject

@property(nonatomic, copy) NSString *viewTree;
@property(nonatomic, copy) NSString *viewControllers;

@end

#ifdef __cplusplus
extern "C" {
#endif

UIWindow * _Nullable DYDebugTargetWindow(void);

DYDebugSnapshot * _Nullable
DYDebugCaptureSnapshot(UIWindow * _Nullable window);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END