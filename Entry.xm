#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <roothide.h>

#import "DYDebugCapture.h"
#import "DYDebugExport.h"

#pragma mark - 是否启用当前 App

#define kPrefsPath @"/var/mobile/Library/Preferences/com.ygxmm.dydebugkit.plist"


#import <fcntl.h>
#import <unistd.h>


static BOOL DYIsCurrentAppEnabled(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if (bid.length == 0) return NO;
    if ([bid isEqualToString:@"com.apple.springboard"]) return NO;

    NSString *path = jbroot(@"/var/mobile/Library/Preferences/dydebugkit.json");
    int fd = open(path.UTF8String, O_RDONLY);
    if (fd < 0) return NO;

    NSMutableData *data = [NSMutableData data];
    char buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:n];
    }
    close(fd);

    if (data.length == 0) return NO;
    NSDictionary *enabled = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![enabled isKindOfClass:NSDictionary.class]) return NO;
    BOOL enabled_ = [enabled[bid] boolValue];
    NSLog(@"[DYDebugKit] ==enabled== %@ -> %d", bid, enabled_);
    return enabled_;
}

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

#pragma mark - 弹出功能菜单

- (void)debugTapped {
    if (self.presentedViewController != nil) return;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"DYDebugKit"
                                           message:@"选择导出范围"
                                    preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    [sheet addAction:[UIAlertAction actionWithTitle:@"① 导出本页头文件"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf performExportWithScope:DYDebugExportScopeCurrentPage];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"② 导出当前 App 头文件"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf performExportWithScope:DYDebugExportScopeCurrentApp];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"③ 导出当前播放音频头文件"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf performExportWithScope:DYDebugExportScopeCurrentAudio];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.button;
        sheet.popoverPresentationController.sourceRect = self.button.bounds;
        sheet.popoverPresentationController.permittedArrowDirections = 0;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 执行导出

- (void)performExportWithScope:(DYDebugExportScope)scope {
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
    BOOL success = [DYDebugExport exportSnapshot:snapshot scope:scope error:&error];

    if (!success) {
        NSLog(@"[DYDebugKit] Export failed: %@", error);
        [self showResult:error.localizedDescription ?: @"导出失败"];
        return;
    }

    NSString *zipName = nil;
    switch (scope) {
        case DYDebugExportScopeCurrentPage:  zipName = @"DYDebugKit-page.zip";  break;
        case DYDebugExportScopeCurrentApp:   zipName = @"DYDebugKit-app.zip";   break;
        case DYDebugExportScopeCurrentAudio: zipName = @"DYDebugKit-audio.zip"; break;
    }

    NSString *zipPath = [DYDebugExportBaseDirectory() stringByAppendingPathComponent:zipName];

    NSString *workDirName = [zipName stringByReplacingOccurrencesOfString:@".zip" withString:@""];
    NSString *workDir = [DYDebugExportBaseDirectory() stringByAppendingPathComponent:workDirName];
    [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];

    NSLog(@"[DYDebugKit] Export succeeded: %@", zipPath);

    [self shareZipAtPath:zipPath];
}

#pragma mark - 分享

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

    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = self.button;
        activity.popoverPresentationController.sourceRect = self.button.bounds;
        activity.popoverPresentationController.permittedArrowDirections = 0;
    }

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

#pragma mark - 提示

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

    if (controller == nil) return NO;

    if (controller.presentedViewController != nil) return YES;

    if (controller.button == nil) return NO;

    CGPoint local = [self convertPoint:p toView:controller.button];
    return [controller.button pointInside:local withEvent:event];
}

@end

#pragma mark - Show Overlay

static UIWindowScene *DYDebugForegroundWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        UIApplication *application = UIApplication.sharedApplication;

        for (UIScene *scene in application.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static void DYShowOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gWindow != nil && gWindow.windowScene != nil && !gWindow.hidden) return;

        UIWindowScene *scene = DYDebugForegroundWindowScene();

        if (scene == nil) {
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

        NSLog(@"[DYDebugKit] Overlay shown");
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
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    DYShowOverlay();
}

@end

#pragma mark - Install Gesture

static BOOL DYWindowAlreadyAttached(UIWindow *window) {
    if (window == nil) return YES;
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
}

#pragma mark - Attach All Windows

static void DYAttachToCurrentWindows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *application = UIApplication.sharedApplication;

        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in application.connectedScenes) {
                if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    DYInstallActivatorOnWindow(window);
                }
            }
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            for (UIWindow *window in application.windows) {
                DYInstallActivatorOnWindow(window);
            }
#pragma clang diagnostic pop
        }
    });
}

#pragma mark - Periodic Scan

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

#pragma mark - Constructor

%ctor {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
    BOOL en = DYIsCurrentAppEnabled();
    NSString *msg = [NSString stringWithFormat:@"ctor bid=%@ enabled=%d", bid, en];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DYDebugKit_ctor.txt"];
    [msg writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (!en) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        DYAttachToCurrentWindows();
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            DYAttachToCurrentWindows();
            DYShowOverlay();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ DYShowOverlay(); });
    });
}
