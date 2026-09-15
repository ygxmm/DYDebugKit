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
static NSHashTable<UIWindow *> *gAttachedWindows = nil;
static id<UIGestureRecognizerDelegate> gGestureDelegate = nil;

#pragma mark - Overlay Controller

@implementation DYDebugOverlayController

- (void)loadView {
    self.view = [UIView new];
    self.view.backgroundColor = UIColor.clearColor;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.button.frame = CGRectMake(0, 0, 48.0, 48.0);
    self.button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    self.button.tintColor = UIColor.whiteColor;
    self.button.layer.cornerRadius = 24.0;
    self.button.layer.masksToBounds = YES;

    [self.button setTitle:@"⌘" forState:UIControlStateNormal];
    [self.button addTarget:self
                    action:@selector(debugTapped)
          forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:self.button];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    self.button.center = CGPointMake(
        self.view.bounds.size.width - 38.0,
        self.view.safeAreaInsets.top + 38.0
    );
}

- (void)debugTapped {
    // 防止 Alert / 分享面板叠加
    if (self.presentedViewController != nil) {
        return;
    }

    UIWindow *target = DYDebugTargetWindow();

    if (target == nil) {
        [self showResult:@"找不到当前窗口"];
        return;
    }

    DYDebugSnapshot *snapshot = DYDebugCaptureSnapshot(target);

    if (snapshot == nil) {
        [self showResult:@"无法创建调试快照"];
        return;
    }

    NSError *error = nil;
    BOOL success = [DYDebugExport exportSnapshot:snapshot error:&error];

    if (!success) {
        NSLog(@"[DYDebugKit] Export failed: %@", error);
        [self showResult:error.localizedDescription ?: @"导出失败"];
        return;
    }

    // 导出成功后：zip 路径
    NSString *zipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DYDebugKit.zip"];

    // 清理中间目录，只保留 zip
    NSString *workDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DYDebugKit"];
    [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];

    NSLog(@"[DYDebugKit] Export succeeded: %@", zipPath);

    // 弹系统分享面板
    [self shareZipAtPath:zipPath];
}

// 系统分享面板
- (void)shareZipAtPath:(NSString *)zipPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:zipPath]) {
        [self showResult:[NSString stringWithFormat:@"文件不存在：\n%@", zipPath]];
        return;
    }

    NSURL *zipURL = [NSURL fileURLWithPath:zipPath];

    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[zipURL]
                                          applicationActivities:nil];

    // iPad / 弹窗必须设置 popover 锚点，否则崩溃
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = self.button;
        activity.popoverPresentationController.sourceRect = self.button.bounds;
        activity.popoverPresentationController.permittedArrowDirections = 0;
    }

    // 关闭后恢复 overlay key 状态
    activity.completionWithItemsHandler = ^(UIActivityType activityType,
                                            BOOL completed,
                                            NSArray *returnedItems,
                                            NSError *activityError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gWindow != nil && !gWindow.hidden) {
                [gWindow makeKeyWindow];
            }
        });
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:activity animated:YES completion:nil];
    });
}

// 统一显示提示
- (void)showResult:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"DYDebugKit"
                                           message:message
                                    preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gWindow != nil && !gWindow.hidden) {
                [gWindow makeKeyWindow];
            }
        });
    }]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end

#pragma mark - Overlay Window

@implementation DYDebugOverlayWindow

- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)event {
    DYDebugOverlayController *controller =
        (DYDebugOverlayController *)self.rootViewController;

    if (controller == nil || controller.button == nil) {
        return NO;
    }

    CGPoint local = [self convertPoint:p toView:controller.button];
    return [controller.button pointInside:local withEvent:event];
}

@end

#pragma mark - Show Overlay

static UIWindowScene *DYDebugForegroundWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        UIApplication *application = UIApplication.sharedApplication;

        for (UIScene *scene in application.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) {
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
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gWindow != nil && gWindow.windowScene != nil && !gWindow.hidden) {
            return;
        }

        UIWindowScene *scene = DYDebugForegroundWindowScene();

        if (scene == nil) {
            NSLog(@"[DYDebugKit] No foreground scene, retry...");
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{
                    DYShowOverlay();
                }
            );
            return;
        }

        gWindow = [[DYDebugOverlayWindow alloc] initWithWindowScene:scene];
        gWindow.backgroundColor = UIColor.clearColor;
        gWindow.opaque = NO;
        gWindow.windowLevel = UIWindowLevelAlert + 100.0;
        gWindow.rootViewController = [DYDebugOverlayController new];
        gWindow.hidden = NO;

        NSLog(@"[DYDebugKit] Overlay shown on scene: %@", scene);
    });
}

#pragma mark - Gesture Delegate

@interface DYGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation DYGestureDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

#pragma mark - Activator

@implementation DYDebugActivator

+ (void)handle:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }

    NSLog(@"[DYDebugKit] Two-finger long press detected");
    DYShowOverlay();
}

@end

#pragma mark - Install Gesture

static BOOL DYWindowAlreadyAttached(UIWindow *window) {
    if (window == nil) {
        return YES;
    }

    if (gAttachedWindows == nil) {
        gAttachedWindows = [NSHashTable weakObjectsHashTable];
        return NO;
    }

    return [gAttachedWindows containsObject:window];
}

static void DYInstallActivatorOnWindow(UIWindow *window) {
    if (window == nil) return;
    if (window == gWindow) return;
    if (window.hidden) return;
    if (window.alpha <= 0.0) return;
    if (window.windowLevel > UIWindowLevelNormal + 1.0) return;
    if (DYWindowAlreadyAttached(window)) return;

    UILongPressGestureRecognizer *gesture =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:[DYDebugActivator class]
                    action:@selector(handle:)];

    gesture.minimumPressDuration = 1.5;
    gesture.numberOfTouchesRequired = 2;
    gesture.numberOfTapsRequired = 0;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;

    if (gGestureDelegate == nil) {
        gGestureDelegate = [DYGestureDelegate new];
    }
    gesture.delegate = gGestureDelegate;

    [window addGestureRecognizer:gesture];

    if (gAttachedWindows == nil) {
        gAttachedWindows = [NSHashTable weakObjectsHashTable];
    }

    [gAttachedWindows addObject:window];

    NSLog(@"[DYDebugKit] Activator attached to window: %@ level=%f",
          NSStringFromClass(window.class),
          window.windowLevel);
}

#pragma mark - Attach All Windows

static void DYAttachToCurrentWindows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *application = UIApplication.sharedApplication;
        NSUInteger count = 0;

        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in application.connectedScenes) {
                if (scene.activationState != UISceneActivationStateForegroundActive) {
                    continue;
                }

                if (![scene isKindOfClass:UIWindowScene.class]) {
                    continue;
                }

                UIWindowScene *windowScene = (UIWindowScene *)scene;

                for (UIWindow *window in windowScene.windows) {
                    DYInstallActivatorOnWindow(window);
                    count++;
                }
            }
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

            for (UIWindow *window in application.windows) {
                DYInstallActivatorOnWindow(window);
                count++;
            }

#pragma clang diagnostic pop
        }

        NSLog(@"[DYDebugKit] Window scan completed: %lu", (unsigned long)count);
    });
}

#pragma mark - Periodic Window Scan

static void DYScanWindowsPeriodically(void) {
    DYAttachToCurrentWindows();

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            DYScanWindowsPeriodically();
        }
    );
}

static void DYStartWindowMonitor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DYScanWindowsPeriodically();
    });
}

#pragma mark - Constructor

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[DYDebugKit] Loaded");

        DYAttachToCurrentWindows();

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIWindowDidBecomeKeyNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        UIWindow *window = note.object;
                        if (![window isKindOfClass:UIWindow.class]) {
                            return;
                        }
                        DYInstallActivatorOnWindow(window);
                    }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIWindowDidBecomeVisibleNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        UIWindow *window = note.object;
                        if (![window isKindOfClass:UIWindow.class]) {
                            return;
                        }
                        DYInstallActivatorOnWindow(window);
                    }];

        if (@available(iOS 13.0, *)) {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UISceneDidActivateNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
                            DYAttachToCurrentWindows();
                        }];

            [[NSNotificationCenter defaultCenter]
                addObserverForName:@"UISceneDidConnectNotification"
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
                            DYAttachToCurrentWindows();
                        }];
        }

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
                        DYAttachToCurrentWindows();
                        DYShowOverlay();
                    }];

        DYStartWindowMonitor();

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                DYShowOverlay();
            }
        );
    });
}