#import "DYDebugCapture.h"
#import <QuartzCore/QuartzCore.h>

@implementation DYDebugSnapshot
@end

static void DYAppendView(UIView *view, NSMutableString *out, NSUInteger depth) {
    if (!view) return;
    for (NSUInteger i = 0; i < depth; i++) [out appendString:@"  "];
    [out appendFormat:@"%@ frame=%@ hidden=%@ alpha=%.2f\n", NSStringFromClass(view.class), NSStringFromCGRect(view.frame), view.hidden ? @"YES" : @"NO", view.alpha];
    for (UIView *sub in view.subviews) DYAppendView(sub, out, depth + 1);
}

static void DYAppendVC(UIViewController *vc, NSMutableString *out, NSUInteger depth) {
    if (!vc) return;
    for (NSUInteger i = 0; i < depth; i++) [out appendString:@"  "];
    [out appendFormat:@"%@\n", NSStringFromClass(vc.class)];
    for (UIViewController *child in vc.childViewControllers) DYAppendVC(child, out, depth + 1);
    if (vc.presentedViewController) {
        for (NSUInteger i = 0; i < depth + 1; i++) [out appendString:@"  "];
        [out appendString:@"presented:\n"];
        DYAppendVC(vc.presentedViewController, out, depth + 2);
    }
}

UIWindow *DYDebugTargetWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden && window.alpha > 0.01 && window.rootViewController) return window;
            }
        }
    }
    for (UIWindow *window in app.windows) {
        if (!window.hidden && window.alpha > 0.01 && window.rootViewController) return window;
    }
    return nil;
}

UIViewController *DYDebugTopViewController(UIViewController *root) {
    if (!root) return nil;
    if (root.presentedViewController) return DYDebugTopViewController(root.presentedViewController);
    if ([root isKindOfClass:UINavigationController.class]) return DYDebugTopViewController(((UINavigationController *)root).visibleViewController);
    if ([root isKindOfClass:UITabBarController.class]) return DYDebugTopViewController(((UITabBarController *)root).selectedViewController);
    if ([root isKindOfClass:UISplitViewController.class]) {
        UIViewController *last = root.childViewControllers.lastObject;
        return DYDebugTopViewController(last ?: root);
    }
    for (UIViewController *child in root.childViewControllers.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) return DYDebugTopViewController(child);
    }
    return root;
}

DYDebugSnapshot *DYDebugCaptureSnapshot(UIWindow *window) {
    if (!window) return nil;
    DYDebugSnapshot *snapshot = [DYDebugSnapshot new];
    UIViewController *top = DYDebugTopViewController(window.rootViewController);
    NSMutableString *viewTree = [NSMutableString string];
    DYAppendView(window, viewTree, 0);
    NSMutableString *vcs = [NSMutableString string];
    DYAppendVC(window.rootViewController, vcs, 0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
    snapshot.screenshotPNG = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    snapshot.viewTree = viewTree.copy;
    snapshot.viewControllers = vcs.copy;
    snapshot.windows = @[ @{ @"class": NSStringFromClass(window.class), @"frame": NSStringFromCGRect(window.frame), @"windowLevel": @(window.windowLevel), @"key": @(window.isKeyWindow) } ];
    snapshot.metadata = @{
        @"app": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"build": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"iOS": UIDevice.currentDevice.systemVersion ?: @"unknown",
        @"device": UIDevice.currentDevice.model ?: @"unknown",
        @"topViewController": top ? NSStringFromClass(top.class) : @"unknown",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    return snapshot;
}
