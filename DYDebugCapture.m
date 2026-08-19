#import "DYDebugCapture.h"

@implementation DYDebugSnapshot

@end

UIWindow *DYDebugTargetWindow(void) {

    UIApplication *application =
        UIApplication.sharedApplication;

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

                if (window.hidden ||
                    window.alpha <= 0.0 ||
                    window.windowLevel != UIWindowLevelNormal) {
                    continue;
                }

                if (window.isKeyWindow) {
                    return window;
                }
            }

            for (UIWindow *window
                 in windowScene.windows) {

                if (!window.hidden &&
                    window.alpha > 0.0 &&
                    window.windowLevel == UIWindowLevelNormal) {
                    return window;
                }
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

    for (UIWindow *window in application.windows) {

        if (window.hidden ||
            window.alpha <= 0.0 ||
            window.windowLevel != UIWindowLevelNormal) {
            continue;
        }

        if (window.isKeyWindow) {
            return window;
        }
    }

    for (UIWindow *window in application.windows) {

        if (!window.hidden &&
            window.alpha > 0.0 &&
            window.windowLevel == UIWindowLevelNormal) {
            return window;
        }
    }

#pragma clang diagnostic pop

    return nil;
}

static void DYDebugAppendViewTree(
    UIView *view,
    NSMutableString *output,
    NSUInteger depth
) {

    if (view == nil) {
        return;
    }

    for (NSUInteger i = 0; i < depth; i++) {
        [output appendString:@"  "];
    }

    NSString *className =
        NSStringFromClass(view.class);

    NSString *frame =
        NSStringFromCGRect(view.frame);

    NSString *identifier =
        view.accessibilityIdentifier ?: @"";

    [output appendFormat:
        @"%@ frame=%@ id=%@\n",
        className,
        frame,
        identifier];

    for (UIView *subview in view.subviews) {
        DYDebugAppendViewTree(
            subview,
            output,
            depth + 1
        );
    }
}

DYDebugSnapshot *
DYDebugCaptureSnapshot(UIWindow *window) {

    if (window == nil) {
        return nil;
    }

    DYDebugSnapshot *snapshot =
        [DYDebugSnapshot new];

    NSMutableString *viewTree =
        [NSMutableString string];

    DYDebugAppendViewTree(
        window,
        viewTree,
        0
    );

    snapshot.viewTree =
        [viewTree copy];

    NSMutableString *controllers =
        [NSMutableString string];

    UIViewController *controller =
        window.rootViewController;

    while (controller != nil) {

        [controllers appendFormat:
            @"%@\n",
            NSStringFromClass(controller.class)];

        UIViewController *next =
            controller.presentedViewController;

        if (next == nil) {
            break;
        }

        controller = next;
    }

    snapshot.viewControllers =
        [controllers copy];

    return snapshot;
}