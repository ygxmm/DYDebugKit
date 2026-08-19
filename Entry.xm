#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "DYDebugCapture.h"
#import "DYDebugExport.h"

#pragma mark - Overlay

@interface DYDebugOverlayController : UIViewController
@property(nonatomic, strong) UIButton *button;
@end

@implementation DYDebugOverlayController

- (void)loadView {
    self.view = [UIView new];
    self.view.backgroundColor = UIColor.clearColor;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.button.frame = CGRectMake(0, 0, 48, 48);
    self.button.backgroundColor =
        [UIColor colorWithWhite:0.0 alpha:0.78];

    self.button.tintColor = UIColor.whiteColor;
    self.button.layer.cornerRadius = 24.0;
    self.button.layer.masksToBounds = YES;

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
        CGPointMake(self.view.bounds.size.width - 38.0,
                    self.view.safeAreaInsets.top + 38.0);
}

- (void)debugTapped {
    UIWindow *target = DYDebugTargetWindow();

    if (target == nil) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"DYDebugKit"
                                                 message:@"找不到当前窗口"
                                          preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"确定"
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
            [UIAlertController alertControllerWithTitle:@"DYDebugKit"
                                                 message:@"无法创建调试快照"
                                          preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"确定"
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

        NSLog(@"[DYDebugKit] Export succeeded: %@",
              message);
    } else {
        message =
            error.localizedDescription ?: @"导出失败";

        NSLog(@"[DYDebugKit] Export failed: %@",
              error);
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"DYDebugKit"
                                             message:message
                                      preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"确定"
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

    [self presentViewController:alert
                       animated:YES
                     completion:nil];
}

@end

#pragma mark - Overlay Window

@interface DYDebugOverlayWindow : UIWindow
@end

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

    return [controller.button pointInside:local
                                withEvent:event];
}

@end

#pragma mark - Activation

static DYDebugOverlayWindow *gWindow;
static UILongPressGestureRecognizer *gActivator;
static __weak UIWindow *gAttachedWindow;

static void DYShowOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{

        if (gWindow && !gWindow.hidden) {
            return;
        }

        UIWindowScene *scene = nil;

        if (@available(iOS 13.0, *)) {
            for (UIScene *candidate
                 in UIApplication.sharedApplication.connectedScenes) {

                if (candidate.activationState ==
                        UISceneActivationStateForegroundActive &&
                    [candidate isKindOfClass:UIWindowScene.class]) {

                    scene = (UIWindowScene *)candidate;
                    break;
                }
            }
        }

        if (scene != nil) {
            gWindow =
                [[DYDebugOverlayWindow alloc]
                    initWithWindowScene:scene];
        } else {
            gWindow =
                [[DYDebugOverlayWindow alloc]
                    initWithFrame:UIScreen.mainScreen.bounds];
        }

        gWindow.backgroundColor = UIColor.clearColor;
        gWindow.opaque = NO;
        gWindow.windowLevel = UIWindowLevelAlert + 100.0;

        gWindow.rootViewController =
            [DYDebugOverlayController new];

        gWindow.hidden = NO;
    });
}

#pragma mark - Activator

@interface DYDebugActivator : NSObject

+ (void)handle:(UILongPressGestureRecognizer *)gesture;

@end

static void DYInstallActivatorOnWindow(UIWindow *window) {

    if (window == nil ||
        window == gWindow ||
        gAttachedWindow == window) {
        return;
    }

    if (gActivator != nil &&
        gAttachedWindow != nil) {

        [gAttachedWindow removeGestureRecognizer:gActivator];
    }

    UILongPressGestureRecognizer *gesture =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:[DYDebugActivator class]
                    action:@selector(handle:)];

    gesture.minimumPressDuration = 3.0;
    gesture.numberOfTouchesRequired = 2;
    gesture.numberOfTapsRequired = 0;

    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;

    [window addGestureRecognizer:gesture];

    gActivator = gesture;
    gAttachedWindow = window;
}

@implementation DYDebugActivator

+ (void)handle:(UILongPressGestureRecognizer *)gesture {

    if (gesture.state ==
        UIGestureRecognizerStateBegan) {

        DYShowOverlay();
    }
}

@end

#pragma mark - Window Attachment

static void DYAttachToCurrentWindow(void) {

    dispatch_async(dispatch_get_main_queue(), ^{

        if (gWindow && !gWindow.hidden) {
            return;
        }

        UIWindow *window =
            DYDebugTargetWindow();

        if (window != nil) {
            DYInstallActivatorOnWindow(window);
        }
    });
}

#pragma mark - Constructor

%ctor {

    dispatch_async(dispatch_get_main_queue(), ^{

        /*
         不主动创建可见 UIWindow。

         插件启动后只在当前普通 UIWindow
         上安装不可见的双指长按手势。

         双指长按 3 秒后才显示调试浮窗。
         */

        DYAttachToCurrentWindow();

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIWindowDidBecomeKeyNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {

            UIWindow *window = note.object;

            if ([window isKindOfClass:UIWindow.class]) {
                DYInstallActivatorOnWindow(window);
            }
        }];

        if (@available(iOS 13.0, *)) {

            [[NSNotificationCenter defaultCenter]
                addObserverForName:UISceneDidActivateNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {

                DYAttachToCurrentWindow();
            }];
        }
    });
}