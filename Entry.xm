#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "DYDebugCapture.h"
#import "DYDebugExport.h"

#pragma mark - Forward

@interface DYDebugOverlayController : UIViewController
@property(nonatomic, strong) UIButton *button;
@end

@interface DYDebugOverlayWindow : UIWindow
@end

@interface DYDebugActivator : NSObject
+ (void)handle:(UILongPressGestureRecognizer *)gesture;
@end

#pragma mark - Globals

static DYDebugOverlayWindow *gWindow = nil;

/*
 * 使用 weakObjectsHashTable 保存已经安装过的 Window。
 *
 * 原来的实现：
 *
 *     static UILongPressGestureRecognizer *gActivator;
 *     static __weak UIWindow *gAttachedWindow;
 *
 * 只能维护一个 Window。
 *
 * 多 Scene / 多 Window 环境下容易导致手势安装到错误 Window。
 */
static NSHashTable<UIWindow *> *gAttachedWindows = nil;

#pragma mark - Overlay Controller

@implementation DYDebugOverlayController

- (void)loadView {

    self.view = [UIView new];

    self.view.backgroundColor =
        UIColor.clearColor;
}

- (void)viewDidLoad {

    [super viewDidLoad];

    self.button =
        [UIButton buttonWithType:UIButtonTypeSystem];

    self.button.frame =
        CGRectMake(0, 0, 48.0, 48.0);

    self.button.backgroundColor =
        [UIColor colorWithWhite:0.0
                          alpha:0.78];

    self.button.tintColor =
        UIColor.whiteColor;

    self.button.layer.cornerRadius =
        24.0;

    self.button.layer.masksToBounds =
        YES;

    [self.button setTitle:@"⌘"
                 forState:UIControlStateNormal];

    [self.button addTarget:self
                    action:@selector(debugTapped)
          forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:self.button];
}

- (void)viewDidLayoutSubviews {

    [super viewDidLayoutSubviews];

    self.button.center =
        CGPointMake(
            self.view.bounds.size.width - 38.0,
            self.view.safeAreaInsets.top + 38.0
        );
}

- (void)debugTapped {

    UIWindow *target =
        DYDebugTargetWindow();

    if (target == nil) {

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"DYDebugKit"
                                   message:@"找不到当前窗口"
                            preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:@"确定"
                          style:UIAlertActionStyleCancel
                        handler:nil]];

        [self presentViewController:alert
                           animated:YES
                         completion:nil];

        return;
    }

    DYDebugSnapshot *snapshot =
        DYDebugCaptureSnapshot(target);

    if (snapshot == nil) {

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"DYDebugKit"
                                   message:@"无法创建调试快照"
                            preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:@"确定"
                          style:UIAlertActionStyleCancel
                        handler:nil]];

        [self presentViewController:alert
                           animated:YES
                         completion:nil];

        return;
    }

    NSError *error = nil;

    BOOL success =
        [DYDebugExport exportSnapshot:snapshot
                                error:&error];

    NSString *message = nil;

    if (success) {

        message =
            [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"DYDebugKit"];

        NSLog(
            @"[DYDebugKit] Export succeeded: %@",
            message
        );

    } else {

        message =
            error.localizedDescription
                ?: @"导出失败";

        NSLog(
            @"[DYDebugKit] Export failed: %@",
            error
        );
    }

    UIAlertController *alert =
        [UIAlertController
            alertControllerWithTitle:@"DYDebugKit"
                               message:message
                        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction
            actionWithTitle:@"确定"
                      style:UIAlertActionStyleCancel
                    handler:nil]];

    [self presentViewController:alert
                       animated:YES
                     completion:nil];
}

@end

#pragma mark - Overlay Window

@implementation DYDebugOverlayWindow

- (BOOL)pointInside:(CGPoint)p
          withEvent:(UIEvent *)event {

    DYDebugOverlayController *controller =
        (DYDebugOverlayController *)self.rootViewController;

    if (controller == nil ||
        controller.button == nil) {

        return NO;
    }

    CGPoint local =
        [self convertPoint:p
                    toView:controller.button];

    return
        [controller.button pointInside:local
                            withEvent:event];
}

@end

#pragma mark - Show Overlay

static UIWindowScene *DYDebugForegroundWindowScene(void) {

    if (@available(iOS 13.0, *)) {

        UIApplication *application =
            UIApplication.sharedApplication;

        for (UIScene *scene
             in application.connectedScenes) {

            if (scene.activationState !=
                UISceneActivationStateForegroundActive) {

                continue;
            }

            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }

            return (UIWindowScene *)scene;
        }
    }

    return nil;
}

static void DYShowOverlay(void) {

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            if (gWindow != nil &&
                !gWindow.hidden) {

                return;
            }

            UIWindowScene *scene =
                DYDebugForegroundWindowScene();

            if (scene != nil) {

                gWindow =
                    [[DYDebugOverlayWindow alloc]
                        initWithWindowScene:scene];

            } else {

                gWindow =
                    [[DYDebugOverlayWindow alloc]
                        initWithFrame:
                            UIScreen.mainScreen.bounds];
            }

            gWindow.backgroundColor =
                UIColor.clearColor;

            gWindow.opaque = NO;

            /*
             * 只让浮窗自身可见。
             *
             * pointInside: 已经限制了实际触摸区域，
             * 所以不会覆盖整个 App 的触摸。
             */
            gWindow.windowLevel =
                UIWindowLevelAlert + 100.0;

            gWindow.rootViewController =
                [DYDebugOverlayController new];

            gWindow.hidden = NO;

            NSLog(
                @"[DYDebugKit] Overlay shown"
            );
        }
    );
}

#pragma mark - Activator

@implementation DYDebugActivator

+ (void)handle:(UILongPressGestureRecognizer *)gesture {

    if (gesture.state !=
        UIGestureRecognizerStateBegan) {

        return;
    }

    NSLog(
        @"[DYDebugKit] Two-finger long press detected"
    );

    DYShowOverlay();
}

@end

#pragma mark - Install Gesture

static BOOL DYWindowAlreadyAttached(UIWindow *window) {

    if (window == nil) {
        return YES;
    }

    if (gAttachedWindows == nil) {

        gAttachedWindows =
            [NSHashTable weakObjectsHashTable];

        return NO;
    }

    return
        [gAttachedWindows containsObject:window];
}

static void DYInstallActivatorOnWindow(UIWindow *window) {

    if (window == nil) {
        return;
    }

    /*
     * 不安装到自己的 Overlay Window。
     */
    if (window == gWindow) {
        return;
    }

    /*
     * 不处理隐藏 Window。
     */
    if (window.hidden) {
        return;
    }

    /*
     * alpha 为 0 的 Window 不参与。
     */
    if (window.alpha <= 0.0) {
        return;
    }

    /*
     * 只处理普通应用 Window。
     *
     * 避免给系统 Alert / 键盘 / 其他特殊 Window
     * 重复添加手势。
     */
    if (window.windowLevel != UIWindowLevelNormal) {
        return;
    }

    if (DYWindowAlreadyAttached(window)) {
        return;
    }

    UILongPressGestureRecognizer *gesture =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:[DYDebugActivator class]
                    action:@selector(handle:)];

    /*
     * 双指长按。
     *
     * 2 秒用于测试，比原来的 3 秒更容易确认。
     */
    gesture.minimumPressDuration = 2.0;

    gesture.numberOfTouchesRequired = 2;

    gesture.numberOfTapsRequired = 0;

    /*
     * 不主动取消 App 原来的触摸。
     */
    gesture.cancelsTouchesInView = NO;

    gesture.delaysTouchesBegan = NO;

    gesture.delaysTouchesEnded = NO;

    /*
     * 如果目标 App 自己有复杂手势，
     * 尽可能不要阻止它们。
     */
    gesture.delegate = nil;

    [window addGestureRecognizer:gesture];

    if (gAttachedWindows == nil) {

        gAttachedWindows =
            [NSHashTable weakObjectsHashTable];
    }

    [gAttachedWindows addObject:window];

    NSLog(
        @"[DYDebugKit] Activator attached to window: %@ level=%f",
        NSStringFromClass(window.class),
        window.windowLevel
    );
}

#pragma mark - Attach All Windows

static void DYAttachToCurrentWindows(void) {

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            UIApplication *application =
                UIApplication.sharedApplication;

            NSUInteger count = 0;

            /*
             * iOS 13+
             *
             * 一个 App 可以存在多个 UIWindowScene。
             */
            if (@available(iOS 13.0, *)) {

                for (UIScene *scene
                     in application.connectedScenes) {

                    if (scene.activationState !=
                        UISceneActivationStateForegroundActive) {

                        continue;
                    }

                    if (![scene isKindOfClass:UIWindowScene.class]) {
                        continue;
                    }

                    UIWindowScene *windowScene =
                        (UIWindowScene *)scene;

                    for (UIWindow *window
                         in windowScene.windows) {

                        DYInstallActivatorOnWindow(window);

                        count++;
                    }
                }

            } else {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

                for (UIWindow *window
                     in application.windows) {

                    DYInstallActivatorOnWindow(window);

                    count++;
                }

#pragma clang diagnostic pop
            }

            NSLog(
                @"[DYDebugKit] Window scan completed: %lu",
                (unsigned long)count
            );
        }
    );
}

#pragma mark - Periodic Window Scan

static void DYStartWindowMonitor(void) {

    /*
     * 某些 App 在启动后才创建真正的业务 Window。
     *
     * 因此不能只在 %ctor 执行一次。
     */
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            DYAttachToCurrentWindows();

            /*
             * 后续反复检查新出现的 Window。
             *
             * 已经安装过的 Window 会通过
             * NSHashTable 自动跳过。
             */
            __block void (^scanBlock)(void);

            scanBlock = ^{

                DYAttachToCurrentWindows();

                dispatch_after(
                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        (int64_t)(2.0 *
                                  NSEC_PER_SEC)
                    ),
                    dispatch_get_main_queue(),
                    scanBlock
                );
            };

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    (int64_t)(2.0 *
                              NSEC_PER_SEC)
                ),
                dispatch_get_main_queue(),
                scanBlock
            );
        }
    );
}

#pragma mark - Constructor

%ctor {

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            NSLog(
                @"[DYDebugKit] Loaded"
            );

            /*
             * 初始扫描。
             */
            DYAttachToCurrentWindows();

            /*
             * Window 成为 Key。
             */
            [[NSNotificationCenter defaultCenter]
                addObserverForName:
                    UIWindowDidBecomeKeyNotification
                object:nil
                 queue:
                    [NSOperationQueue mainQueue]
            usingBlock:
                ^(NSNotification *note) {

                    UIWindow *window =
                        note.object;

                    if (![window
                            isKindOfClass:UIWindow.class]) {

                        return;
                    }

                    DYInstallActivatorOnWindow(window);
                }];

            /*
             * Window 显示。
             */
            [[NSNotificationCenter defaultCenter]
                addObserverForName:
                    UIWindowDidBecomeVisibleNotification
                object:nil
                 queue:
                    [NSOperationQueue mainQueue]
            usingBlock:
                ^(NSNotification *note) {

                    UIWindow *window =
                        note.object;

                    if (![window
                            isKindOfClass:UIWindow.class]) {

                        return;
                    }

                    DYInstallActivatorOnWindow(window);
                }];

            /*
             * Scene 激活。
             */
            if (@available(iOS 13.0, *)) {

                [[NSNotificationCenter defaultCenter]
                    addObserverForName:
                        UISceneDidActivateNotification
                    object:nil
                     queue:
                        [NSOperationQueue mainQueue]
                usingBlock:
                    ^(__unused NSNotification *note) {

                        DYAttachToCurrentWindows();
                    }];

                /*
                 * Scene 连接。
                 */
                [[NSNotificationCenter defaultCenter]
                    addObserverForName:
                        UISceneDidConnectNotification
                    object:nil
                     queue:
                        [NSOperationQueue mainQueue]
                usingBlock:
                    ^(__unused NSNotification *note) {

                        DYAttachToCurrentWindows();
                    }];
            }

            /*
             * App 从后台回来时再次扫描。
             */
            [[NSNotificationCenter defaultCenter]
                addObserverForName:
                    UIApplicationDidBecomeActiveNotification
                object:nil
                 queue:
                    [NSOperationQueue mainQueue]
            usingBlock:
                ^(__unused NSNotification *note) {

                    DYAttachToCurrentWindows();
                }];

            /*
             * 处理某些 App 延迟创建 Window 的情况。
             */
            DYStartWindowMonitor();
        }
    );
}