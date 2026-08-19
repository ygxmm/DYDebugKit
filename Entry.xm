#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "Debug/DYDebugCapture.h"
#import "Debug/DYDebugExport.h"

#pragma mark - Overlay

@interface DYDebugOverlayController : UIViewController
@property(nonatomic,strong) UIButton *button;
@end

@implementation DYDebugOverlayController
- (void)loadView { self.view = [UIView new]; self.view.backgroundColor = UIColor.clearColor; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.button.frame = CGRectMake(0, 0, 48, 48);
    self.button.backgroundColor = [UIColor colorWithWhite:0 alpha:.78];
    self.button.tintColor = UIColor.whiteColor;
    self.button.layer.cornerRadius = 24;
    self.button.layer.masksToBounds = YES;
    [self.button setTitle:@"⌘" forState:UIControlStateNormal];
    [self.button addTarget:self action:@selector(debugTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.button];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.button.center = CGPointMake(self.view.bounds.size.width - 38,
                                     self.view.safeAreaInsets.top + 38);
}
- (void)debugTapped {
    UIWindow *target = DYDebugTargetWindow();
    DYDebugSnapshot *snapshot = DYDebugCaptureSnapshot(target);
    NSError *error = nil;
    NSURL *url = DYDebugExportSnapshot(snapshot, &error);
    NSString *message = url ? url.path : (error.localizedDescription ?: @"未知错误");
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"DYDebugKit"
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

@interface DYDebugOverlayWindow : UIWindow @end
@implementation DYDebugOverlayWindow
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)event {
    DYDebugOverlayController *c = (DYDebugOverlayController *)self.rootViewController;
    CGPoint local = [self convertPoint:p toView:c.button];
    return [c.button pointInside:local withEvent:event];
}
@end

#pragma mark - Two-finger, 3-second activation

static DYDebugOverlayWindow *gWindow;
static UILongPressGestureRecognizer *gActivator;
static __weak UIWindow *gAttachedWindow;

static void DYShowOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gWindow && !gWindow.hidden) return;

        UIWindowScene *scene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:UIWindowScene.class]) {
                    scene = (UIWindowScene *)s;
                    break;
                }
            }
        }

        gWindow = scene ? [[DYDebugOverlayWindow alloc] initWithWindowScene:scene]
                        : [[DYDebugOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gWindow.backgroundColor = UIColor.clearColor;
        gWindow.opaque = NO;
        gWindow.windowLevel = UIWindowLevelAlert + 100;
        gWindow.rootViewController = [DYDebugOverlayController new];
        gWindow.hidden = NO;
    });
}

static void DYHideOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gWindow.hidden = YES;
        gWindow = nil;
    });
}

static void DYActivationChanged(UITapGestureRecognizer *recognizer) {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        DYShowOverlay();
    }
}

@interface DYDebugActivator : NSObject
+ (void)handle:(UILongPressGestureRecognizer *)gesture;
@end

static void DYInstallActivatorOnWindow(UIWindow *window) {
    if (!window || window == gWindow || gAttachedWindow == window) return;

    // 默认完全不显示调试浮窗；仅在当前 App 的普通 UIWindow 上安装一个不可见手势识别器。
    if (gActivator && gAttachedWindow) {
        [gAttachedWindow removeGestureRecognizer:gActivator];
    }

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:[DYDebugActivator class] action:@selector(handle:)];
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
    if (gesture.state == UIGestureRecognizerStateBegan) {
        DYShowOverlay();
    }
}
@end

static void DYAttachToCurrentWindow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gWindow && !gWindow.hidden) return;
        UIWindow *window = DYDebugTargetWindow();
        if (window) DYInstallActivatorOnWindow(window);
    });
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 不创建任何可见 UIWindow。
        // 插件启动后仅监听当前 App 的普通窗口，用户双指长按 3 秒才显示调试浮窗。
        DYAttachToCurrentWindow();

        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            UIWindow *window = note.object;
            if ([window isKindOfClass:UIWindow.class]) DYInstallActivatorOnWindow(window);
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            DYAttachToCurrentWindow();
        }];
    });
}
