//
//  TZDebugCapture.m
//  tz
//
//  只读地遍历 UIKit/CoreAnimation 安全字段 + 收集本页类，产出 TZDebugExportContext。
//  不递归读任意对象的 ivar 值。
//

#ifndef DK_VERSION
#define DK_VERSION @"1.0.0"
#endif

#import "TZDebugCapture.h"
#import "TZClassDump.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSMutableSet<NSString *> *gPageSwiftClasses = nil;

void DKRecordHitTest(UIView *hitView, CGPoint point);

@implementation TZDebugExportContext
@end

#pragma mark - 小型格式化工具

static NSString *DKStringFromPointer(const void *pointer) {
    return [NSString stringWithFormat:@"%p", pointer];
}

static NSString *TZClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"";
}

static NSString *DKObjectDesc(id object) {
    if (!object) return @"";
    @try {
        return [object description] ?: @"";
    } @catch (__unused NSException *exception) {
        return @"<description threw>";
    }
}

static NSNumber *DKNum(double value) {
    return @(isfinite(value) ? value : 0);
}

static NSString *DKStringFromColor(UIColor *color) {
    if (!color) return @"";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"rgba(%.4f, %.4f, %.4f, %.4f)", r, g, b, a];
    }
    return DKObjectDesc(color);
}

static NSDictionary *DKRectDict(CGRect rect) {
    return @{
        @"x": DKNum(rect.origin.x),
        @"y": DKNum(rect.origin.y),
        @"width": DKNum(rect.size.width),
        @"height": DKNum(rect.size.height),
        @"string": NSStringFromCGRect(rect)
    };
}

static NSDictionary *DKPointDict(CGPoint point) {
    return @{ @"x": DKNum(point.x), @"y": DKNum(point.y), @"string": NSStringFromCGPoint(point) };
}

static NSDictionary *DKSizeDict(CGSize size) {
    return @{ @"width": DKNum(size.width), @"height": DKNum(size.height), @"string": NSStringFromCGSize(size) };
}

static NSDictionary *DKAffineDict(CGAffineTransform t) {
    return @{
        @"a": DKNum(t.a), @"b": DKNum(t.b), @"c": DKNum(t.c),
        @"d": DKNum(t.d), @"tx": DKNum(t.tx), @"ty": DKNum(t.ty)
    };
}

static NSDictionary *DKTransform3DDict(CATransform3D t) {
    return @{
        @"m11": DKNum(t.m11), @"m12": DKNum(t.m12), @"m13": DKNum(t.m13), @"m14": DKNum(t.m14),
        @"m21": DKNum(t.m21), @"m22": DKNum(t.m22), @"m23": DKNum(t.m23), @"m24": DKNum(t.m24),
        @"m31": DKNum(t.m31), @"m32": DKNum(t.m32), @"m33": DKNum(t.m33), @"m34": DKNum(t.m34),
        @"m41": DKNum(t.m41), @"m42": DKNum(t.m42), @"m43": DKNum(t.m43), @"m44": DKNum(t.m44)
    };
}

#pragma mark - 窗口与控制器工具

// DK_WINDOW_FILTER: 排除 tz 自身窗口（类名/控制器/层级三重判断）
static BOOL TZIsDebugWindow(UIWindow *window) {
    if (!window) return YES;
    NSString *cls = TZClassName(window);
    NSString *rvc = TZClassName(window.rootViewController);

    NSArray<NSString *> *prefixes =
        @[@"TZDebug", @"DYDebug", @"tz", @"FLEX",
          @"DKOverlay", @"DYOverlay"];
    for (NSString *p in prefixes) {
        if ([cls hasPrefix:p]) return YES;
        if ([rvc hasPrefix:p]) return YES;
    }

    // tz 浮层 windowLevel = UIWindowLevelAlert + 100
    CGFloat lv = window.windowLevel;
    if (lv >= UIWindowLevelAlert + 99.5 && lv <= UIWindowLevelAlert + 100.5) {
        return YES;
    }
    return NO;
}

NSArray<UIWindow *> *TZDebugActiveWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window || TZIsDebugWindow(window)) continue;
                if (window.hidden || window.alpha <= 0.01) continue;
                [windows addObject:window];
            }
        }
    }
    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (!window || TZIsDebugWindow(window)) continue;
            if (window.hidden || window.alpha <= 0.01) continue;
            [windows addObject:window];
        }
#pragma clang diagnostic pop
    }
    return windows;
}

UIWindow *TZDebugTargetWindow(void) {
    NSArray<UIWindow *> *windows = TZDebugActiveWindows();
    for (UIWindow *window in windows) if (window.isKeyWindow) return window;
    return windows.firstObject;
}

static UIViewController *DKViewControllerForView(UIView *view) {
    UIResponder *responder = view;
    for (NSUInteger i = 0; responder && i < 80; i++) {
        responder = responder.nextResponder;
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
    }
    return nil;
}

static UIViewController *DKTopViewControllerFrom(UIViewController *vc) {
    for (NSUInteger i = 0; vc && i < 80; i++) {
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
        } else if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *visible = ((UINavigationController *)vc).visibleViewController;
            if (!visible || visible == vc) break;
            vc = visible;
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected = ((UITabBarController *)vc).selectedViewController;
            if (!selected || selected == vc) break;
            vc = selected;
        } else {
            break;
        }
    }
    return vc;
}

UIViewController *TZDebugTopPresenter(UIWindow *window) {
    return DKTopViewControllerFrom(window.rootViewController);
}

#pragma mark - 页面快照

static NSDictionary *DKLayerInfo(CALayer *layer) {
    if (!layer) return @{};
    return @{
        @"class": TZClassName(layer),
        @"address": DKStringFromPointer((__bridge const void *)layer),
        @"bounds": DKRectDict(layer.bounds),
        @"position": DKPointDict(layer.position),
        @"anchorPoint": DKPointDict(layer.anchorPoint),
        @"zPosition": DKNum(layer.zPosition),
        @"opacity": DKNum(layer.opacity),
        @"hidden": @(layer.hidden),
        @"masksToBounds": @(layer.masksToBounds),
        @"cornerRadius": DKNum(layer.cornerRadius),
        @"sublayerCount": @(layer.sublayers.count),
        @"transform": DKTransform3DDict(layer.transform),
        @"mask": layer.mask ? @{
            @"class": TZClassName(layer.mask),
            @"address": DKStringFromPointer((__bridge const void *)layer.mask),
            @"bounds": DKRectDict(layer.mask.bounds)
        } : @{}
    };
}

static NSMutableDictionary *DKBaseViewInfo(UIView *view, NSUInteger depth) {
    UIViewController *nearestVC = DKViewControllerForView(view);
    NSMutableDictionary *info = [@{
        @"class": TZClassName(view),
        @"address": DKStringFromPointer((__bridge const void *)view),
        @"depth": @(depth),
        @"frame": DKRectDict(view.frame),
        @"bounds": DKRectDict(view.bounds),
        @"center": DKPointDict(view.center),
        @"alpha": DKNum(view.alpha),
        @"hidden": @(view.hidden),
        @"opaque": @(view.opaque),
        @"clipsToBounds": @(view.clipsToBounds),
        @"userInteractionEnabled": @(view.userInteractionEnabled),
        @"multipleTouchEnabled": @(view.multipleTouchEnabled),
        @"contentMode": @(view.contentMode),
        @"tag": @(view.tag),
        @"autoresizingMask": @(view.autoresizingMask),
        @"autoresizesSubviews": @(view.autoresizesSubviews),
        @"transform": DKAffineDict(view.transform),
        @"backgroundColor": DKStringFromColor(view.backgroundColor),
        @"tintColor": DKStringFromColor(view.tintColor),
        @"accessibilityIdentifier": view.accessibilityIdentifier ?: @"",
        @"accessibilityLabel": view.accessibilityLabel ?: @"",
        @"nearestViewController": nearestVC ? @{
            @"class": TZClassName(nearestVC),
            @"address": DKStringFromPointer((__bridge const void *)nearestVC)
        } : @{},
        @"layer": DKLayerInfo(view.layer),
        @"subviewCount": @(view.subviews.count)
    } mutableCopy];

    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        info[@"label"] = @{
            @"text": label.text ?: @"",
            @"attributedText": label.attributedText.string ?: @"",
            @"font": DKObjectDesc(label.font),
            @"textColor": DKStringFromColor(label.textColor),
            @"numberOfLines": @(label.numberOfLines),
            @"textAlignment": @(label.textAlignment)
        };
    }
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        info[@"button"] = @{
            @"currentTitle": [button titleForState:UIControlStateNormal] ?: (button.currentTitle ?: @""),
            @"currentAttributedTitle": button.currentAttributedTitle.string ?: @"",
            @"enabled": @(button.enabled),
            @"selected": @(button.selected),
            @"highlighted": @(button.highlighted)
        };
    }
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)view;
        info[@"imageView"] = @{
            @"imageSize": imageView.image ? DKSizeDict(imageView.image.size) : @{},
            @"highlighted": @(imageView.highlighted)
        };
    }
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        info[@"control"] = @{
            @"enabled": @(control.enabled),
            @"selected": @(control.selected),
            @"highlighted": @(control.highlighted),
            @"state": @(control.state)
        };
    }
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll = (UIScrollView *)view;
        info[@"scrollView"] = @{
            @"contentOffset": DKPointDict(scroll.contentOffset),
            @"contentSize": DKSizeDict(scroll.contentSize),
            @"contentInset": NSStringFromUIEdgeInsets(scroll.contentInset),
            @"adjustedContentInset": NSStringFromUIEdgeInsets(scroll.adjustedContentInset),
            @"zoomScale": DKNum(scroll.zoomScale),
            @"minimumZoomScale": DKNum(scroll.minimumZoomScale),
            @"maximumZoomScale": DKNum(scroll.maximumZoomScale),
            @"pagingEnabled": @(scroll.pagingEnabled),
            @"scrollEnabled": @(scroll.scrollEnabled),
            @"dragging": @(scroll.dragging),
            @"tracking": @(scroll.tracking),
            @"decelerating": @(scroll.decelerating)
        };
    }
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        info[@"visualEffectView"] = @{ @"effect": DKObjectDesc(((UIVisualEffectView *)view).effect) };
    }
    return info;
}

static NSDictionary *DKViewTreeJSON(UIView *view, NSUInteger depth, NSMutableArray *layers) {
    NSMutableDictionary *info = DKBaseViewInfo(view, depth);
    [layers addObject:@{
        @"viewClass": info[@"class"],
        @"viewAddress": info[@"address"],
        @"nearestViewController": info[@"nearestViewController"],
        @"layer": info[@"layer"]
    }];

    NSMutableArray *children = [NSMutableArray arrayWithCapacity:view.subviews.count];
    for (UIView *subview in view.subviews) {
        [children addObject:DKViewTreeJSON(subview, depth + 1, layers)];
    }
    info[@"children"] = children;
    return info;
}

static void DKAppendViewTreeText(UIView *view, NSUInteger depth, NSMutableString *out) {
    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    UIViewController *vc = DKViewControllerForView(view);
    
    NSString *extra = @"";
    if ([view isKindOfClass:[UILabel class]] && ((UILabel *)view).text.length > 0) {
        extra = [NSString stringWithFormat:@"text=\"%@\" ", ((UILabel *)view).text];
    } else if ([view isKindOfClass:[UIButton class]] && ((UIButton *)view).currentTitle.length > 0) {
        extra = [NSString stringWithFormat:@"text=\"%@\" ", ((UIButton *)view).currentTitle];
    } else if (view.accessibilityLabel.length > 0) {
        extra = [NSString stringWithFormat:@"label=\"%@\" ", view.accessibilityLabel];
    }
    
    // 计算绝对坐标
    NSString *absStr = @"";
    if (view.window) {
        CGRect absRect = [view convertRect:view.bounds toView:view.window];
        absStr = [NSString stringWithFormat:@"abs=%@ ", NSStringFromCGRect(absRect)];
    }
    
    // 检查是否被裁剪
    BOOL isClipped = NO;
    if (view.superview && view.superview.clipsToBounds) {
        if (!CGRectContainsRect(view.superview.bounds, view.frame)) {
            isClipped = YES;
        }
    }
    NSString *clippedStr = isClipped ? @"[clipped] " : @"";

    [out appendFormat:@"%@%@ %@ frame=%@ %@%@vc=%@ %@ %@hidden=%d alpha=%.3f clips=%d user=%d layer=%@\n",
     indent,
     TZClassName(view),
     DKStringFromPointer((__bridge const void *)view),
     NSStringFromCGRect(view.frame),
     absStr,
     clippedStr,
     vc ? TZClassName(vc) : @"",
     vc ? DKStringFromPointer((__bridge const void *)vc) : @"",
     extra,
     view.hidden,
     view.alpha,
     view.clipsToBounds,
     view.userInteractionEnabled,
     TZClassName(view.layer)];
    for (UIView *subview in view.subviews) DKAppendViewTreeText(subview, depth + 1, out);
}

static NSDictionary *DKWindowJSON(UIWindow *window) {
    return @{
        @"class": TZClassName(window),
        @"address": DKStringFromPointer((__bridge const void *)window),
        @"frame": DKRectDict(window.frame),
        @"bounds": DKRectDict(window.bounds),
        @"windowLevel": DKNum(window.windowLevel),
        @"hidden": @(window.hidden),
        @"alpha": DKNum(window.alpha),
        @"keyWindow": @(window.isKeyWindow),
        @"rootViewController": window.rootViewController ? @{
            @"class": TZClassName(window.rootViewController),
            @"address": DKStringFromPointer((__bridge const void *)window.rootViewController)
        } : @{}
    };
}

static NSArray *DKAncestorChain(UIView *view) {
    NSMutableArray *chain = [NSMutableArray array];
    UIView *v = view;
    for (NSUInteger depth = 0; v && depth < 120; depth++, v = v.superview) {
        [chain addObject:DKBaseViewInfo(v, depth)];
    }
    return chain;
}

static void DKAppendVCText(UIViewController *vc, NSUInteger depth, NSMutableString *out, NSHashTable *seen) {
    if (!vc || [seen containsObject:vc]) return;
    [seen addObject:vc];
    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    BOOL loaded = vc.isViewLoaded;
    UIView *view = loaded ? vc.view : nil;
    [out appendFormat:@"%@%@ %@ viewLoaded=%@ view=%@ %@ frame=%@\n",
     indent,
     TZClassName(vc),
     DKStringFromPointer((__bridge const void *)vc),
     loaded ? @"YES" : @"NO",
     TZClassName(view),
     view ? DKStringFromPointer((__bridge const void *)view) : @"",
     view ? NSStringFromCGRect(view.frame) : @"null"];

    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        [out appendFormat:@"%@  nav.top=%@ nav.visible=%@\n", indent, TZClassName(nav.topViewController), TZClassName(nav.visibleViewController)];
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)vc;
        [out appendFormat:@"%@  tab.selected=%@\n", indent, TZClassName(tab.selectedViewController)];
    }
    for (UIViewController *child in vc.childViewControllers) DKAppendVCText(child, depth + 1, out, seen);
    if (vc.presentedViewController) {
        [out appendFormat:@"%@  presented:\n", indent];
        DKAppendVCText(vc.presentedViewController, depth + 1, out, seen);
    }
}

// 按 windowLevel 从低到高逐个画，截图才等于用户真正看到的画面。
// 只画 key 窗口会漏掉浮层：某些 App 的内嵌画中画窗口 在 windowLevel 2000，
// 它铺满全屏时导出截图却一切正常，排查会整整绕一轮。
static NSData *DKScreenshotPNG(UIWindow *targetWindow) {
    if (!targetWindow) return NSData.data;

    NSArray<UIWindow *> *windows =
        [TZDebugActiveWindows() sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
            if (a.windowLevel == b.windowLevel) return NSOrderedSame;
            return a.windowLevel < b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
        }];
    if (windows.count == 0) windows = @[ targetWindow ];

    UIGraphicsBeginImageContextWithOptions(targetWindow.bounds.size, NO, 0);
    for (UIWindow *window in windows) {
        BOOL drew = [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
        if (!drew) [window.layer renderInContext:UIGraphicsGetCurrentContext()];
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image ? UIImagePNGRepresentation(image) : NSData.data;
}

#pragma mark - 通用探针框架

static NSMutableDictionary<NSString *, DKProbeBlock> *gProbeBlocks = nil;
static NSMutableArray<NSString *> *gProbeOrder = nil;

void TZRegisterProbe(NSString *name, DKProbeBlock block) {
    if (!name.length || !block) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gProbeBlocks = [NSMutableDictionary dictionary];
        gProbeOrder = [NSMutableArray array];
    });
    if (!gProbeBlocks[name]) [gProbeOrder addObject:name];
    gProbeBlocks[name] = [block copy];
}

static NSDictionary<NSString *, NSString *> *TZRunAllProbes(UIWindow *window) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *name in gProbeOrder) {
        @try {
            NSString *text = gProbeBlocks[name](window);
            if (text.length) result[name] = text;
        } @catch (NSException *e) {
            result[name] = [NSString stringWithFormat:@"# probe '%@' threw: %@\n", name, e.reason];
        }
    }
    return result;
}

static BOOL TZIsDecorativeView(UIView *v) {
    NSString *cls = NSStringFromClass([v class]);
    return [cls isEqualToString:@"_UIBarBackground"]
        || [cls hasPrefix:@"AWETabBarSkin"]
        || [cls containsString:@"BlurView"]
        || [cls containsString:@"TransitionBackground"]
        || [cls isEqualToString:@"UIImageView"];
}

static void DKAppendViewNode(UIView *v, NSMutableString *out, NSUInteger depth) {
    if (!v) return;
    if (TZIsDecorativeView(v)) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN(depth, 8); i++) [indent appendString:@"  "];
    [out appendFormat:@"%@%@ frame=%@ hidden=%d alpha=%.2f user=%d\n",
     indent, NSStringFromClass([v class]), NSStringFromCGRect(v.frame),
     (int)v.hidden, v.alpha, (int)v.userInteractionEnabled];
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        if (lbl.text.length > 0) {
            [out appendFormat:@"%@  text=%@\n", indent, lbl.text];
        }
    }
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *label = v.accessibilityLabel ?: @"";
        NSString *ident = v.accessibilityIdentifier ?: @"";
        NSString *title = b.currentTitle ?: @"";
        if (label.length == 0) label = title;
        [out appendFormat:@"%@  title=%@ label=%@ id=%@ enabled=%d selected=%d\n",
         indent, title, label, ident, b.enabled, b.selected];
    }
    for (UIView *sub in v.subviews) DKAppendViewNode(sub, out, depth + 1);
}

static NSString *DKTabBarLabel(UIView *v) {
    NSString *cls = NSStringFromClass([v class]);
    NSString *label = v.accessibilityLabel ?: @"";
    if (label.length == 0 && [cls containsString:@"Plus"]) label = @"+";
    
    // 深入子视图找 UILabel 或 UIButton 的 title
    if (label.length == 0) {
        for (UIView *sub in v.subviews) {
            if ([sub isKindOfClass:[UILabel class]] && ((UILabel *)sub).text.length > 0) {
                label = ((UILabel *)sub).text; break;
            }
            if ([sub isKindOfClass:[UIButton class]] && ((UIButton *)sub).currentTitle.length > 0) {
                label = ((UIButton *)sub).currentTitle; break;
            }
        }
    }
    if (label.length == 0) label = cls;
    return label;
}

static NSString *DKTabBarSummaryText(UIView *bar) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== Summary ===\n"];

    NSMutableArray<NSString *> *visibleItems = [NSMutableArray array];
    NSMutableArray<NSString *> *hiddenItems = [NSMutableArray array];
    NSMutableArray<NSValue *> *visibleRects = [NSMutableArray array];

    for (UIView *sub in bar.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        BOOL isBtn = [cls containsString:@"GeneralButton"]
                  || [cls containsString:@"PlusInnerButton"]
                  || [cls isEqualToString:@"UITabBarButton"]
                  || ([cls isEqualToString:@"UIButton"] && sub.bounds.size.width > 50);
        if (!isBtn) continue;

        NSString *label = DKTabBarLabel(sub);
        // 如果坐标 x 是 0 但是是内部 item，尽量用父类的 x
        CGRect rect = sub.frame;
        if (rect.origin.x == 0 && sub.superview != bar) {
            rect.origin.x = sub.superview.frame.origin.x;
        }
        NSString *item = [NSString stringWithFormat:@"%@%s", label, NSStringFromCGRect(rect).UTF8String];
        if (sub.hidden) {
            [hiddenItems addObject:item];
        } else {
            [visibleItems addObject:item];
            [visibleRects addObject:[NSValue valueWithCGRect:sub.frame]];
        }
    }

    [out appendFormat:@"total: %lu\n", (unsigned long)(visibleItems.count + hiddenItems.count)];
    [out appendFormat:@"visible: %lu\n", (unsigned long)visibleItems.count];
    [out appendFormat:@"hidden: %lu\n", (unsigned long)hiddenItems.count];
    if (visibleItems.count) [out appendFormat:@"visible_items: %@\n", [visibleItems componentsJoinedByString:@", "]];
    if (hiddenItems.count) [out appendFormat:@"hidden_items: %@\n", [hiddenItems componentsJoinedByString:@", "]];

    BOOL overlap = NO;
    for (NSUInteger i = 0; i < visibleRects.count; i++) {
        for (NSUInteger j = i + 1; j < visibleRects.count; j++) {
            if (CGRectIntersectsRect([visibleRects[i] CGRectValue], [visibleRects[j] CGRectValue])) {
                overlap = YES;
            }
        }
    }
    [out appendFormat:@"visible_overlaps: %@\n", overlap ? @"YES" : @"no"];

    if (visibleRects.count > 0) {
        CGFloat totalW = 0;
        for (NSValue *v in visibleRects) totalW += [v CGRectValue].size.width;
        [out appendFormat:@"visible_total_width: %.1f / %.1f\n", totalW, bar.bounds.size.width];
    }
    [out appendString:@"\n"];
    return out;
}


#pragma mark - 内置探针：全局异常扫描 (Anomalies)

static void DKCollectAnomaliesFromView(UIView *v, NSMutableString *out, CGRect windowRect, NSMutableSet *seen) {
    if (!v || v.hidden || v.alpha < 0.05) return;
    if ([seen containsObject:[NSValue valueWithPointer:(__bridge const void *)v]]) return;
    [seen addObject:[NSValue valueWithPointer:(__bridge const void *)v]];
    
    CGRect rectInWindow = [v convertRect:v.bounds toView:nil];
    BOOL isZeroSize = (v.bounds.size.width == 0 || v.bounds.size.height == 0);
    
    // 1. 尺寸为 0 但未隐藏 (过滤掉 0 尺寸的占位符，通常如果是 0 尺寸且 userInteractionEnabled 会有问题)
    if (isZeroSize && v.userInteractionEnabled) {
        [out appendFormat:@"[ZeroSize] %@ frame=%@ vc=%@\n", 
         NSStringFromClass([v class]), NSStringFromCGRect(v.frame), NSStringFromClass([DKViewControllerForView(v) class])];
    }
    
    // 2. 越界 (完全在屏幕外)
    if (!isZeroSize && !CGRectIntersectsRect(rectInWindow, windowRect)) {
        // 排除 UITableView / UICollectionView 的隐藏 cell，或者被 ScrollView 裁剪的
        BOOL isScrollCell = NO;
        UIResponder *r = v;
        while (r && ![r isKindOfClass:[UIScrollView class]]) { r = r.nextResponder; }
        if (r) isScrollCell = YES;
        
        if (!isScrollCell) {
            [out appendFormat:@"[Offscreen] %@ frame=%@ abs=%@\n", 
             NSStringFromClass([v class]), NSStringFromCGRect(v.frame), NSStringFromCGRect(rectInWindow)];
        }
    }
    
    for (UIView *sub in v.subviews) {
        DKCollectAnomaliesFromView(sub, out, windowRect, seen);
    }
}


#pragma mark - 内置探针：最后一次点击命中 (Hit Test)

static UIView *gLastHitView = nil;
static CGPoint gLastHitPoint = {0, 0};
static NSDate *gLastHitTime = nil;

void DKRecordHitTest(UIView *hitView, CGPoint point) {
    gLastHitView = hitView;
    gLastHitPoint = point;
    gLastHitTime = [NSDate date];
}

static NSString *TZCaptureHitTestProbe(UIWindow *window) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# Touch Hit Test Probe\n"];
    [out appendString:@"# 记录用户在点击悬浮球导出前，最后一次触摸屏幕命中的视图\n\n"];
    
    if (!gLastHitView || !gLastHitTime) {
        [out appendString:@"(No touch recorded yet)\n"];
        return out;
    }
    
    [out appendFormat:@"Touch Point: %@\n", NSStringFromCGPoint(gLastHitPoint)];
    [out appendFormat:@"Time: %@\n\n", gLastHitTime];
    
    [out appendString:@"--- Hit View Info ---\n"];
    [out appendFormat:@"Class: %@\n", NSStringFromClass([gLastHitView class])];
    [out appendFormat:@"Frame: %@\n", NSStringFromCGRect(gLastHitView.frame)];
    
    [out appendString:@"\n--- Responder Chain (点击事件传给谁) ---\n"];
    UIResponder *r = gLastHitView;
    int depth = 0;
    while (r && depth < 15) {
        [out appendFormat:@"%@[%d] %@\n", 
         (depth == 0 ? @"> " : @"  "), depth, NSStringFromClass([r class])];
        r = r.nextResponder;
        depth++;
    }
    
    return out;
}

static NSString *TZCaptureAnomaliesProbe(UIWindow *window) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# Global Anomalies Probe\n"];
    [out appendString:@"# 自动扫描：尺寸为0的交互、完全越界(不在屏幕上)的视图\n\n"];
    if (!window) { [out appendString:@"(no window)\n"]; return out; }
    
    NSMutableSet *seen = [NSMutableSet set];
    DKCollectAnomaliesFromView(window, out, window.bounds, seen);
    if (out.length < 80) {
        [out appendString:@"(No obvious anomalies detected)\n"];
    }
    return out;
}

static NSString *TZCaptureTabBarProbe(UIWindow *window) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# TabBar probe (generic)\n"];
    if (!window) { [out appendString:@"(no window)\n"]; return out; }

    NSMutableArray<UIView *> *tabBars = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    while (queue.count) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *cls = NSStringFromClass([v class]);
        BOOL isRootTabBar = [v isKindOfClass:[UITabBar class]]
                         || [cls hasSuffix:@"TabBar"];
        if (isRootTabBar) {
            [tabBars addObject:v];
            continue; // 找到根后不再深入，避免子树被反复打印
        }
        [queue addObjectsFromArray:v.subviews];
    }

    if (tabBars.count == 0) {
        [out appendString:@"(no TabBar in window)\n"];
        return out;
    }
    for (UIView *bar in tabBars) {
        [out appendString:DKTabBarSummaryText(bar)];
        [out appendString:@"=== TabBar ===\n"];
        DKAppendViewNode(bar, out, 0);
    }
    return out;
}

static void TZRegisterBuiltinProbes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TZRegisterProbe(@"tabbar", ^NSString *(UIWindow *window) {
            return TZCaptureTabBarProbe(window);
        });
        TZRegisterProbe(@"anomalies", ^NSString *(UIWindow *window) {
            return TZCaptureAnomaliesProbe(window);
        });
        TZRegisterProbe(@"touch", ^NSString *(UIWindow *window) {
            return TZCaptureHitTestProbe(window);
        });
    });
}

#pragma mark - 页面类收集

// 收集一个类及其整条继承链的类名：跳过运行时生成子类噪声，但继续上溯 → 自动收到真实基类。
static void DKCollectClassAndSupers(Class cls, NSMutableSet<NSString *> *names) {
    for (int i = 0; cls && i < 50; i++) {
        if (!TZClassIsSafe(cls)) break;
        NSString *name = NSStringFromClass(cls);
        if (name.length && !TZClassNameIsRuntimeGenerated(name)) [names addObject:name];
        cls = class_getSuperclass(cls);
    }
}

// 递归收集视图子树里每个 view 及其 layer 的类（含继承链）。
static void DKCollectPageClassesFromView(UIView *view, NSMutableSet<NSString *> *names) {
    if (!view) return;
    NSString *vClsName = NSStringFromClass(object_getClass(view));
    if ([vClsName containsString:@"."] || [vClsName hasPrefix:@"_TtC"]) {
        if (!gPageSwiftClasses) gPageSwiftClasses = [NSMutableSet set];
        [gPageSwiftClasses addObject:vClsName];
    }
    DKCollectClassAndSupers(object_getClass(view), names);
    DKCollectClassAndSupers(object_getClass(view.layer), names);
    for (UIView *sub in view.subviews) DKCollectPageClassesFromView(sub, names);
}

// 递归收集 VC 树（child + presented）里每个 VC 及其已加载 view 的类（含继承链）。
static void DKCollectPageClassesFromVC(UIViewController *vc, NSMutableSet<NSString *> *names, NSHashTable *seen) {
    if (!vc || [seen containsObject:vc]) return;
    [seen addObject:vc];
    NSString *vcClsName = NSStringFromClass(object_getClass(vc));
    if ([vcClsName containsString:@"."] || [vcClsName hasPrefix:@"_TtC"]) {
        if (!gPageSwiftClasses) gPageSwiftClasses = [NSMutableSet set];
        [gPageSwiftClasses addObject:vcClsName];
    }
    DKCollectClassAndSupers(object_getClass(vc), names);
    if (vc.isViewLoaded) DKCollectClassAndSupers(object_getClass(vc.view), names);
    for (UIViewController *child in vc.childViewControllers) DKCollectPageClassesFromVC(child, names, seen);
    if (vc.presentedViewController) DKCollectPageClassesFromVC(vc.presentedViewController, names, seen);
}

static NSDictionary *TZDebugMetadata(UIWindow *targetWindow, CGPoint point) {
    return @{
        @"generatedAt": DKObjectDesc(NSDate.date),
        @"tzVersion": DK_VERSION,
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"bundleName": NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"",
        @"appVersion": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
        @"buildVersion": NSBundle.mainBundle.infoDictionary[(NSString *)kCFBundleVersionKey] ?: @"",
        @"systemName": UIDevice.currentDevice.systemName ?: @"",
        @"systemVersion": UIDevice.currentDevice.systemVersion ?: @"",
        @"deviceModel": UIDevice.currentDevice.model ?: @"",
        @"screenBounds": DKRectDict(UIScreen.mainScreen.bounds),
        @"tapPointInTargetWindow": DKPointDict(point),
        @"targetWindow": targetWindow ? DKWindowJSON(targetWindow) : @{}
    };
}

// 音频专项导出只用得上元信息和截图。整棵 view tree 有几 MB，
// 采到再丢等于让主线程白跑一趟，所以单开这条轻量路径。
TZDebugExportContext *TZDebugCaptureMetadataContext(UIWindow *targetWindow) {
    TZDebugExportContext *context = [TZDebugExportContext new];
    context.metadata = TZDebugMetadata(targetWindow, CGPointZero);
    context.screenshotPNG = DKScreenshotPNG(targetWindow);
    context.sourceView = targetWindow;
    context.presenter = TZDebugTopPresenter(targetWindow);
    return context;
}


NSArray<NSString *> *TZGetCapturedPageSwiftClasses(void) {
    return gPageSwiftClasses ? [gPageSwiftClasses allObjects] : @[];
}

// DK_FORWARD_DECL: 采集函数 forward declaration（避免 implicit declaration）
static NSString *TZCaptureInteractivesText(UIWindow *window);
static NSString *TZCaptureTextsText(UIWindow *window);
static NSString *TZCaptureImagesText(UIWindow *window); // DK_FEATURE_IMAGES
static NSString *TZCaptureRespondersText(UIWindow *window); // DK_FEATURE_RESPONDERS

TZDebugExportContext *TZDebugCaptureContext(UIWindow *targetWindow, CGPoint point, UIView *selectedView) {
    TZDebugExportContext *context = [TZDebugExportContext new];
    NSArray<UIWindow *> *windows = TZDebugActiveWindows();
    NSMutableArray *windowsJSON = [NSMutableArray array];
    NSMutableArray *treeJSON = [NSMutableArray array];
    NSMutableArray *layersJSON = [NSMutableArray array];
    NSMutableString *treeText = [NSMutableString string];
    NSMutableString *vcText = [NSMutableString string];
    NSHashTable *seenVCs = [NSHashTable weakObjectsHashTable];
    NSMutableSet<NSString *> *pageClasses = [NSMutableSet set];
    NSHashTable *seenClassVCs = [NSHashTable weakObjectsHashTable];

    for (UIWindow *window in windows) {
        [windowsJSON addObject:DKWindowJSON(window)];
        [treeJSON addObject:DKViewTreeJSON(window, 0, layersJSON)];
        DKAppendViewTreeText(window, 0, treeText);
        DKCollectPageClassesFromView(window, pageClasses);
        DKCollectPageClassesFromVC(window.rootViewController, pageClasses, seenClassVCs);
        if (window.rootViewController) {
            [vcText appendFormat:@"Window %@ %@\n", TZClassName(window), DKStringFromPointer((__bridge const void *)window)];
            DKAppendVCText(window.rootViewController, 1, vcText, seenVCs);
        }
    }

    UIViewController *nearestVC = DKViewControllerForView(selectedView);
    NSDictionary *selected = @{
        @"tapPointInWindow": DKPointDict(point),
        @"hitView": DKBaseViewInfo(selectedView ?: targetWindow, 0),
        @"nearestViewController": nearestVC ? @{
            @"class": TZClassName(nearestVC),
            @"address": DKStringFromPointer((__bridge const void *)nearestVC)
        } : @{},
        @"ancestorChain": selectedView ? DKAncestorChain(selectedView) : @[]
    };

    NSString *summary = [NSString stringWithFormat:
                         @"Hit: %@ %@\nFrame: %@\nBounds: %@\nNearest VC: %@ %@\nWindows: %lu\nSubviews: %lu",
                         TZClassName(selectedView),
                         DKStringFromPointer((__bridge const void *)selectedView),
                         selectedView ? NSStringFromCGRect(selectedView.frame) : @"",
                         selectedView ? NSStringFromCGRect(selectedView.bounds) : @"",
                         nearestVC ? TZClassName(nearestVC) : @"",
                         nearestVC ? DKStringFromPointer((__bridge const void *)nearestVC) : @"",
                         (unsigned long)windows.count,
                         (unsigned long)selectedView.subviews.count];

    context.metadata = TZDebugMetadata(targetWindow, point);
    context.windowsJSON = windowsJSON;
    context.viewTreeJSON = treeJSON;
    context.viewTreeText = treeText;
    context.selectedViewJSON = selected;
    context.viewControllersText = vcText;
    context.layersJSON = layersJSON;
    context.screenshotPNG = DKScreenshotPNG(targetWindow);
    context.summary = summary;
    context.pageClassNames = pageClasses.allObjects;
    context.interactivesText = TZCaptureInteractivesText(targetWindow); // DK_FEATURE_INTERACTIVES
    context.textsText = TZCaptureTextsText(targetWindow);              // DK_FEATURE_TEXTS
    context.imagesText = TZCaptureImagesText(targetWindow);                // DK_FEATURE_IMAGES
    context.respondersText = TZCaptureRespondersText(targetWindow);        // DK_FEATURE_RESPONDERS
    TZRegisterBuiltinProbes();
    context.probes = TZRunAllProbes(targetWindow);
    context.probeText = context.probes[@"tabbar"] ?: @"";
    context.sourceView = targetWindow;
    context.presenter = TZDebugTopPresenter(targetWindow);
    return context;
}

// ============================================================
// DK_FEATURE_INTERACTIVES / DK_FEATURE_TEXTS
// 通用：不写死任何 App 类名，只读 UIKit 公开 API
// ============================================================
// DK_FEATURE_GESTURES_V2: 用 runtime ivar 偏移读 _target/_action（KVC 读 SEL 会失败）
static NSString *DKGestureTargetsString(UIGestureRecognizer *g) {
    if (!g) return nil;
    Ivar targetsIvar = class_getInstanceVariable([UIGestureRecognizer class], "_targets");
    if (!targetsIvar) return nil;
    NSArray *targets = object_getIvar(g, targetsIvar);
    if (![targets isKindOfClass:[NSArray class]] || targets.count == 0) return nil;

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id t in targets) {
        if (!t || t == [NSNull null]) continue;
        Class tc = object_getClass(t);
        id target = nil;
        SEL action = NULL;

        Ivar tIvar = class_getInstanceVariable(tc, "_target");
        if (tIvar) target = object_getIvar(t, tIvar);

        Ivar aIvar = class_getInstanceVariable(tc, "_action");
        if (aIvar) {
            ptrdiff_t off = ivar_getOffset(aIvar);
            action = *(SEL *)((char *)(__bridge void *)t + off);
        }
        if (!target || action == NULL) continue;

        NSString *targetCls = NSStringFromClass([target class]);
        NSString *sel = NSStringFromSelector(action);
        if (targetCls.length == 0 || sel.length == 0) continue;
        if ([sel containsString:@"awe_UITracker"]) continue; // DK_FEATURE_IMAGES: 过滤埋点手势

        NSString *item = [NSString stringWithFormat:@"%@:%@", targetCls, sel];
        if (![out containsObject:item]) [out addObject:item];
        if (out.count >= 3) break;
    }
    return out.count ? [out componentsJoinedByString:@","] : nil;
}

static void DKCollectInteractivesFromView(UIView *v, NSMutableString *out, NSUInteger depth) {
    if (!v) return;
    BOOL isControl = [v isKindOfClass:[UIControl class]];
    NSMutableArray<NSString *> *gestures = [NSMutableArray array];
    for (UIGestureRecognizer *g in v.gestureRecognizers) {
        NSString *gc = NSStringFromClass([g class]);
        if ([gc containsString:@"Tap"] || [gc containsString:@"Press"] || [gc containsString:@"Click"]) {
            NSString *tgt = DKGestureTargetsString(g); // DK_FEATURE_GESTURES
            if (tgt.length > 0) {
                [gestures addObject:[NSString stringWithFormat:@"%@{%@}", gc, tgt]];
            } else {
                [gestures addObject:gc];
            }
        }
    }
    if (isControl || gestures.count > 0) {
        NSMutableString *indent = [NSMutableString string];
        for (NSUInteger i = 0; i < MIN(depth, 8); i++) [indent appendString:@"  "]; // DK_FEATURE_INDENT
        NSString *cls = NSStringFromClass([v class]);
        NSString *frame = NSStringFromCGRect(v.frame);
        NSString *enabled = isControl ? (((UIControl *)v).enabled ? @"YES" : @"NO") : @"-";
        NSString *ident = v.accessibilityIdentifier ?: @"";
        NSString *label = v.accessibilityLabel ?: @"";
        NSString *title = @"";
        if ([v isKindOfClass:[UIButton class]]) title = ((UIButton *)v).currentTitle ?: @"";
        // DK_FEATURE_TARGETS: 解析 UIControl target-action
        NSString *targets = @"-";
        if (isControl) {
            NSMutableArray<NSString *> *acts = [NSMutableArray array];
            UIControl *ctrl = (UIControl *)v;
            NSArray<NSNumber *> *events = @[
                @(UIControlEventTouchUpInside),
                @(UIControlEventTouchDown),
                @(UIControlEventValueChanged),
                @(UIControlEventEditingDidEnd),
                @(UIControlEventEditingChanged),
                @(UIControlEventTouchUpOutside),
                @(UIControlEventTouchCancel),
                @(UIControlEventPrimaryActionTriggered),
            ];
            for (id tgt in ctrl.allTargets) {
                if (!tgt || tgt == [NSNull null]) continue;
                NSString *tc = NSStringFromClass([tgt class]);
                for (NSNumber *ev in events) {
                    NSArray<NSString *> *sels = [ctrl actionsForTarget:tgt
                                                       forControlEvent:(UIControlEvents)ev.unsignedIntegerValue];
                    for (NSString *sel in sels) {
                        if ([sel hasPrefix:@"_"]) continue; // DK_FEATURE_GESTURES: 过滤系统内部
                        if ([sel isEqualToString:@"sendAction:withEvent:"]) continue;
                        NSString *item = [NSString stringWithFormat:@"%@:%@", tc, sel];
                        if (![acts containsObject:item]) [acts addObject:item];
                        if (acts.count >= 5) break;
                    }
                    if (acts.count >= 5) break;
                }
                if (acts.count >= 5) break;
            }
            if (acts.count > 0) targets = [acts componentsJoinedByString:@","];
        }
        [out appendFormat:@"%@%@ frame=%@ hidden=%d enabled=%@ id=%@ label=%@ title=%@ targets=%@ gestures=%@\n",
         indent, cls, frame, (int)v.hidden, enabled, ident, label, title,
         targets, gestures.count ? [gestures componentsJoinedByString:@","] : @"-"];
    }
    for (UIView *sub in v.subviews) DKCollectInteractivesFromView(sub, out, depth + 1);
}

static NSString *TZCaptureInteractivesText(UIWindow *window) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# Interactives (UIControl / gestures)\n"];
    if (!window) { [out appendString:@"(no window)\n"]; return out; }
    DKCollectInteractivesFromView(window, out, 0);
    return out;
}

static void DKCollectTextsFromView(UIView *v, NSMutableString *out, NSUInteger depth) {
    if (!v) return;
    NSString *text = nil;
    // DK_FEATURE_UNIVERSAL_TEXT: 通用 text 抓取，覆盖 UILabel / YYLabel /
    // DUXBaseLabel / AWEUserNameLabel 等所有自定义 Label 子类
    if ([v respondsToSelector:@selector(text)]) {
        @try {
            id t = [v performSelector:@selector(text)];
            if ([t isKindOfClass:[NSString class]] && [(NSString *)t length] > 0) text = (NSString *)t;
        } @catch (__unused NSException *e) {}
    }
    // attributedText 兜底（部分富文本 view 只有 attributedText）
    if (text.length == 0 && [v respondsToSelector:@selector(attributedText)]) {
        @try {
            id at = [v performSelector:@selector(attributedText)];
            if ([at isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)at length] > 0) {
                text = [(NSAttributedString *)at string];
            }
        } @catch (__unused NSException *e) {}
    }
    // UIButton 的 title 单独处理（UIButton 自身没有 text 属性）
    if (text.length == 0 && [v isKindOfClass:[UIButton class]]) {
        text = ((UIButton *)v).currentTitle;
    }
    if (text.length > 0) {
        NSMutableString *indent = [NSMutableString string];
        for (NSUInteger i = 0; i < MIN(depth, 8); i++) [indent appendString:@"  "]; // DK_FEATURE_INDENT
        NSString *safe = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
        if (safe.length > 200) safe = [[safe substringToIndex:200] stringByAppendingString:@"..."];
        [out appendFormat:@"%@%@ frame=%@ text=%@\n",
         indent, NSStringFromClass([v class]), NSStringFromCGRect(v.frame), safe];
    }
    for (UIView *sub in v.subviews) DKCollectTextsFromView(sub, out, depth + 1);
}

static NSString *TZCaptureTextsText(UIWindow *window) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# Texts (UILabel / UITextField / UITextView / UIButton title)\n"];
    if (!window) { [out appendString:@"(no window)\n"]; return out; }
    DKCollectTextsFromView(window, out, 0);
    return out;
}

// ============================================================
// DK_FEATURE_IMAGES: 图片资源清单
// ============================================================
static void DKCollectImagesFromView(UIView *v, NSMutableString *out, NSUInteger depth) {
    if (!v) return;
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        UIImage *img = iv.image;
        NSMutableString *indent = [NSMutableString string];
        for (NSUInteger i = 0; i < MIN(depth, 8); i++) [indent appendString:@"  "]; // DK_FEATURE_INDENT
        NSString *size = img ? NSStringFromCGSize(img.size) : @"null";
        NSUInteger frames = img.images.count;
        CGFloat scale = img ? img.scale : 0;
        NSString *ident = iv.accessibilityIdentifier ?: @"";
        NSString *label = iv.accessibilityLabel ?: @"";
        [out appendFormat:@"%@%@ frame=%@ hidden=%d image=%@ frames=%lu scale=%.1f id=%@ label=%@\n",
         indent, NSStringFromClass([v class]), NSStringFromCGRect(v.frame),
         (int)v.hidden, size, (unsigned long)frames, scale, ident, label];
    }
    for (UIView *sub in v.subviews) DKCollectImagesFromView(sub, out, depth + 1);
}

static NSString *TZCaptureImagesText(UIWindow *window) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# Images (UIImageView)\n"];
    if (!window) { [out appendString:@"(no window)\n"]; return out; }
    DKCollectImagesFromView(window, out, 0);
    return out;
}

// ============================================================
// DK_FEATURE_RESPONDERS: 可交互元素的响应链（view -> superview ... -> VC -> window）
// ============================================================
static void DKCollectRespondersFromView(UIView *v, NSMutableString *out, NSUInteger depth) {
    if (!v) return;
    BOOL interactive = [v isKindOfClass:[UIControl class]] || v.gestureRecognizers.count > 0;
    if (interactive) {
        NSMutableString *indent = [NSMutableString string];
        for (NSUInteger i = 0; i < MIN(depth, 8); i++) [indent appendString:@"  "];
        NSMutableArray<NSString *> *chain = [NSMutableArray array];
        UIResponder *cur = v;
        int d = 0;
        while (cur && d < 8) {
            [chain addObject:NSStringFromClass([cur class])];
            cur = cur.nextResponder;
            d++;
        }
        [out appendFormat:@"%@%@ frame=%@ chain=%@\n",
         indent, NSStringFromClass([v class]), NSStringFromCGRect(v.frame),
         [chain componentsJoinedByString:@" > "]];
    }
    for (UIView *sub in v.subviews) DKCollectRespondersFromView(sub, out, depth + 1);
}

static NSString *TZCaptureRespondersText(UIWindow *window) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# Responder chains (UIControl / gesture view -> nextResponder ...)\n"];
    if (!window) { [out appendString:@"(no window)\n"]; return out; }
    DKCollectRespondersFromView(window, out, 0);
    return out;
}
