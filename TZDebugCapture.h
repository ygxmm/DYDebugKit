//
//  TZDebugCapture.h
//  tz
//
//  抓取当前页面的运行时快照（窗口/视图树/VC 树/图层/截图/本页类），产出
//  一个只含"已算好数据"的 TZDebugExportContext，交给 TZDebugExport 落盘。
//

#ifndef TZDebugCapture_h
#define TZDebugCapture_h

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class TZAudioProbeCapture;

/// 一次页面快照的产物（纯数据；序列化由 TZDebugExport 负责）。
@interface TZDebugExportContext : NSObject
@property (nonatomic, strong) NSDictionary *metadata;
@property (nonatomic, strong) NSArray *windowsJSON;
@property (nonatomic, strong) NSArray *viewTreeJSON;
@property (nonatomic, copy) NSString *viewTreeText;
@property (nonatomic, strong) NSDictionary *selectedViewJSON;
@property (nonatomic, copy) NSString *viewControllersText;
@property (nonatomic, strong) NSArray *layersJSON;
@property (nonatomic, strong) NSData *screenshotPNG;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, strong) NSArray<NSString *> *pageClassNames;
@property (nonatomic, copy) NSString *interactivesText; // DK_FEATURE_INTERACTIVES
@property (nonatomic, copy) NSString *textsText;        // DK_FEATURE_TEXTS
@property (nonatomic, copy) NSString *imagesText;        // DK_FEATURE_IMAGES
@property (nonatomic, copy) NSString *respondersText;    // DK_FEATURE_RESPONDERS
/// 主线程生成的探针文本（probe/tabbar.txt）；后台导出只落盘，不再读 UIKit。
@property (nonatomic, copy) NSString *probeText;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *probes;
/// 音频专项模式的五秒采样产物；普通页面/全类导出时为 nil。
@property (nonatomic, strong) TZAudioProbeCapture *audioCapture;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) UIViewController *presenter;
@end

typedef NSString * _Nullable (^DKProbeBlock)(UIWindow * _Nullable window);
FOUNDATION_EXPORT void TZRegisterProbe(NSString *name, DKProbeBlock block);

#ifdef __cplusplus
extern "C" {
#endif

/// 前台全部可见窗口（排除调试自身窗口），按系统返回顺序。
/// 探针必须逐个看：浮层窗口（如 AWEDPlayerPiPWindow，windowLevel 2000）盖在主窗口之上，
/// 只看 key 窗口会把它当成不存在。
/// 记录最后一次点击命中的 View 及坐标（供 Hit-test 探针使用）
void DKRecordHitTest(UIView * _Nullable hitView, CGPoint point);

NSArray<UIWindow *> *TZDebugActiveWindows(void);

/// 前台 key 窗口（排除调试自身窗口）。
UIWindow *TZDebugTargetWindow(void);

/// 某窗口当前最顶层的 VC（穿透 present/nav/tab）。
UIViewController *TZDebugTopPresenter(UIWindow *window);

/// 抓取一次页面快照。
TZDebugExportContext *TZDebugCaptureContext(UIWindow *targetWindow, CGPoint point, UIView *selectedView);

/// 只采元信息与截图，不遍历 view tree；音频专项导出用。
TZDebugExportContext *TZDebugCaptureMetadataContext(UIWindow *targetWindow);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif /* TZDebugCapture_h */

NSArray<NSString *> *TZGetCapturedPageSwiftClasses(void);
