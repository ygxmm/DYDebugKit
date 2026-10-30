#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>

#import "DKDebugCapture.h"
#import "DKDebugExport.h"

#pragma mark - 是否启用当前 App





static BOOL DYIsCurrentAppEnabled(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if (bid.length == 0) return NO;
    if ([bid isEqualToString:@"com.apple.springboard"]) return NO;

    // TrollFools 注入模式：注入即启用，不读任何配置文件
    NSLog(@"[tzyhb] ==enabled== %@ -> 1 (injected)", bid);
    return YES;
}

#pragma mark - Forward

@interface DYDebugOverlayController : UIViewController
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, assign) CGPoint buttonCenter;
@property(nonatomic, assign) BOOL hasCustomPosition;
@property(nonatomic, assign) BOOL exporting;
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

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleButtonPan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    [self.button addGestureRecognizer:pan];

    NSDictionary *saved = [[NSUserDefaults standardUserDefaults]
        objectForKey:@"DYOverlayButtonCenter"];
    if (saved && saved[@"x"] && saved[@"y"]) {
        self.buttonCenter = CGPointMake([saved[@"x"] doubleValue],
                                        [saved[@"y"] doubleValue]);
        self.hasCustomPosition = YES;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat halfW = self.button.bounds.size.width * 0.5;
    CGFloat halfH = self.button.bounds.size.height * 0.5;
    CGFloat margin = 8.0;
    CGFloat safeTop = self.view.safeAreaInsets.top;
    CGFloat safeBottom = self.view.safeAreaInsets.bottom;

    CGPoint c;
    if (self.hasCustomPosition) {
        c = self.buttonCenter;
    } else {
        c = CGPointMake(
            self.view.bounds.size.width - 38.0,
            self.view.safeAreaInsets.top + 38.0
        );
    }
    c.x = MAX(halfW + margin,
              MIN(self.view.bounds.size.width - halfW - margin, c.x));
    c.y = MAX(safeTop + halfH + margin,
              MIN(self.view.bounds.size.height - safeBottom - halfH - margin, c.y));
    self.buttonCenter = c;
    self.button.center = c;
}

#pragma mark - 拖动浮窗

- (void)handleButtonPan:(UIPanGestureRecognizer *)g {
    UIView *v = self.button;
    UIGestureRecognizerState st = g.state;

    if (st == UIGestureRecognizerStateBegan ||
        st == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.view];
        v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
        [g setTranslation:CGPointZero inView:self.view];
        self.buttonCenter = v.center;
        self.hasCustomPosition = YES;
    } else if (st == UIGestureRecognizerStateEnded ||
               st == UIGestureRecognizerStateCancelled) {
        CGFloat halfW = v.bounds.size.width * 0.5;
        CGFloat halfH = v.bounds.size.height * 0.5;
        CGFloat margin = 8.0;
        CGFloat safeTop = self.view.safeAreaInsets.top;
        CGFloat safeBottom = self.view.safeAreaInsets.bottom;
        CGPoint c = v.center;
        if (c.x < self.view.bounds.size.width * 0.5) {
            c.x = halfW + margin;
        } else {
            c.x = self.view.bounds.size.width - halfW - margin;
        }
        c.y = MAX(safeTop + halfH + margin,
                  MIN(self.view.bounds.size.height - safeBottom - halfH - margin, c.y));
        [UIView animateWithDuration:0.2 animations:^{ v.center = c; }];
        self.buttonCenter = c;
        [[NSUserDefaults standardUserDefaults]
            setObject:@{@"x": @(c.x), @"y": @(c.y)}
               forKey:@"DYOverlayButtonCenter"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

#pragma mark - 弹出功能菜单

- (void)debugTapped {
    if (self.presentedViewController != nil) return;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"tzyhb"
                                           message:@"选择导出范围"
                                    preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    [sheet addAction:[UIAlertAction actionWithTitle:@"① 导出本页头文件"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf performExportWithMode:DKDebugExportModePage];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"② 导出全部 ClassDump"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf performExportWithMode:DKDebugExportModeAllClasses];
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

- (void)performExportWithMode:(DKDebugExportMode)mode {
    UIWindow *target = DKDebugTargetWindow();
    if (target == nil) { [self showResult:@"找不到当前窗口"]; return; }
    DKDebugExportContext *context = DKDebugCaptureContext(target, CGPointZero, nil);
    if (context == nil) { [self showResult:@"无法创建调试快照"]; return; }

    self.exporting = YES;
    UIView *hud = [self showLoadingHUD:@"正在导出..."];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        DKDebugExportResult *result = DKDebugCreateExport(context, mode, ^(NSString *text) {
            if (!text.length) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                // DK_HUD_V2
                UILabel *title = (UILabel *)[hud viewWithTag:7777];
                UILabel *pctLbl = (UILabel *)[hud viewWithTag:6666];
                UILabel *detail = (UILabel *)[hud viewWithTag:9999];
                UIProgressView *bar = (UIProgressView *)[hud viewWithTag:8888];
                if (![bar isKindOfClass:[UIProgressView class]]) return;

                NSString *phase = @"导出中";
                NSString *detailText = text;
                float target = bar.progress;

                if ([text containsString:@"读取运行时类列表"]) { phase = @"读取类列表"; target = 0.03; }
                else if ([text containsString:@"运行时共"]) { phase = @"扫描运行时"; target = 0.05; }
                else if ([text containsString:@"补全 future class"]) { phase = @"补全类名"; target = 0.08; }
                else if ([text containsString:@"future class 补全"]) { phase = @"补全完成"; target = 0.12; }
                else if ([text containsString:@"写入全部类头文件"]) { phase = @"写入头文件"; target = 0.15; }
                else if ([text containsString:@"写入页面结构"]) { phase = @"写入页面"; target = 0.10; }
                else if ([text containsString:@"导出本页类头文件"]) { phase = @"导出本页类"; target = 0.15; }
                else if ([text containsString:@"全部类导出完成"]) { phase = @"头文件完成"; target = 0.95; }
                else if ([text containsString:@"静态解析 category"]) { phase = @"解析 category"; target = 0.96; }
                else if ([text containsString:@"已解析"]) { phase = @"解析 category"; target = MIN(0.98, bar.progress + 0.002); }
                else if ([text containsString:@"category 解析完成"]) { phase = @"category 完成"; target = 0.98; }
                else if ([text containsString:@"写入音频采集结果"]) { phase = @"写入音频"; target = 0.90; }
                else if ([text containsString:@"压缩 zip"]) { phase = @"压缩打包"; target = 0.99; }

                NSRegularExpression *re = [NSRegularExpression
                    regularExpressionWithPattern:@"（([0-9.]+)%）" options:0 error:nil];
                NSTextCheckingResult *m = [re firstMatchInString:text options:0
                                                           range:NSMakeRange(0, text.length)];
                if (m) {
                    float pct = [[text substringWithRange:[m rangeAtIndex:1]] floatValue] / 100.0f;
                    if ([text containsString:@"已导出"]) {
                        phase = @"写入头文件";
                        target = 0.15f + pct * 0.80f;
                        NSRange prefix = [text rangeOfString:@"已导出 "];
                        if (prefix.location != NSNotFound) {
                            NSString *rest = [text substringFromIndex:NSMaxRange(prefix)];
                            NSRange pctStart = [rest rangeOfString:@"（"];
                            if (pctStart.location != NSNotFound) {
                                detailText = [rest substringToIndex:pctStart.location];
                            }
                        }
                    }
                }

                target = MIN(MAX(target, bar.progress), 1.0f);
                [bar setProgress:target animated:YES];
                if ([title isKindOfClass:[UILabel class]]) title.text = phase;
                if ([pctLbl isKindOfClass:[UILabel class]]) {
                    pctLbl.text = [NSString stringWithFormat:@"%.0f%%", target * 100.0f];
                }
                if ([detail isKindOfClass:[UILabel class]]) detail.text = detailText;
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.exporting = NO;
            [self hideLoadingHUD:hud];
            if (result == nil || result.zipURL == nil) {
                [self showResult:error.localizedDescription ?: @"导出失败"];
                return;
            }
            NSLog(@"[tzyhb] Export succeeded: %@", result.zipURL.path);
            [self shareZipAtPath:result.zipURL.path];
        });
    });
}

- (UIView *)showLoadingHUD:(NSString *)text {
    // DK_HUD_V2: 现代进度 HUD
    UIView *hud = [[UIView alloc] initWithFrame:self.view.bounds];
    hud.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    hud.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 208)];
    box.center = CGPointMake(hud.bounds.size.width / 2.0, hud.bounds.size.height / 2.0);
    box.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
    box.layer.cornerRadius = 18.0;
    box.layer.masksToBounds = YES;
    box.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin
                         | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 22, 240, 20)];
    title.text = text;
    title.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    title.tag = 7777;
    [box addSubview:title];

    UILabel *pct = [[UILabel alloc] initWithFrame:CGRectMake(20, 46, 240, 48)];
    pct.text = @"0%";
    pct.textColor = UIColor.whiteColor;
    pct.textAlignment = NSTextAlignmentCenter;
    pct.font = [UIFont monospacedDigitSystemFontOfSize:42 weight:UIFontWeightBold];
    pct.tag = 6666;
    [box addSubview:pct];

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.frame = CGRectMake(24, 106, 232, 6);
    bar.transform = CGAffineTransformMakeScale(1.0, 3.0);
    bar.progressTintColor = [UIColor colorWithRed:0.20 green:0.60 blue:1.00 alpha:1.0];
    bar.trackTintColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    bar.layer.cornerRadius = 3.0;
    bar.clipsToBounds = YES;
    bar.progress = 0.0f;
    bar.tag = 8888;
    [box addSubview:bar];

    UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(20, 128, 240, 56)];
    detail.text = @"";
    detail.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    detail.textAlignment = NSTextAlignmentCenter;
    detail.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    detail.numberOfLines = 2;
    detail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    detail.tag = 9999;
    [box addSubview:detail];

    [hud addSubview:box];
    [self.view addSubview:hud];
    hud.alpha = 0.0;
    [UIView animateWithDuration:0.18 animations:^{ hud.alpha = 1.0; }];
    return hud;
}

- (void)hideLoadingHUD:(UIView *)hud {
    if (hud == nil) return;
    [UIView animateWithDuration:0.15 animations:^{ hud.alpha = 0.0; } completion:^(BOOL finished) {
        [hud removeFromSuperview];
    }];
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
        [UIAlertController alertControllerWithTitle:@"tzyhb"
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

    if (controller.exporting) return YES;
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

        NSLog(@"[tzyhb] Overlay shown");
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
    NSString *line1 = [NSString stringWithFormat:@"ctor bid=%@ enabled=%d", bid, en];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tzyhb_ctor.txt"];
    [line1 writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];

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
