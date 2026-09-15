#import "DYDebugKitRootListController.h"
#import <notify.h>

#define kPrefsPath @"/var/mobile/Library/Preferences/com.ygxmm.dydebugkit.plist"

@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)itemName;
- (NSString *)bundleIdentifier;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
- (NSArray *)atl_allInstalledApplications;
@end

@interface DYDebugKitRootListController ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *enabledApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@end

@implementation DYDebugKitRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DYDebugKit";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(savePrefs)];
    [self loadPrefs];
    [self loadApps];
}

- (void)loadPrefs {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    NSDictionary *enabled = dict[@"enabledApps"];
    self.enabledApps = [enabled mutableCopy] ?: [NSMutableDictionary dictionary];
}

- (void)savePrefs {
    @try {
        NSDictionary *dict = @{ @"enabledApps": self.enabledApps ?: @{} };
        [dict writeToFile:kPrefsPath atomically:YES];
        notify_post("com.ygxmm.dydebugkit/reload");
    } @catch (NSException *e) {}
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"DYDebugKit"
                                           message:@"已保存，重启对应 App 后生效"
                                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)loadApps {
    NSMutableDictionary<NSString *, NSString *> *dict = [NSMutableDictionary dictionary];
    NSArray *proxies = [self fetchApplicationProxies];
    for (id proxy in proxies) {
        @try {
            NSString *bid = [self bundleIDFromProxy:proxy];
            if (bid.length == 0) continue;
            if ([bid hasPrefix:@"com.apple."]) continue;
            NSString *name = [self displayNameFromProxy:proxy fallback:bid];
            dict[bid] = name;
        } @catch (NSException *e) {}
    }
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (NSString *bid in dict) {
        [list addObject:@{ @"bundleID": bid, @"name": dict[bid] }];
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCompare:b[@"name"]];
    }];
    self.allApps = list;
    NSLog(@"[DYDebugKit] found %lu apps", (unsigned long)list.count);
}

- (NSArray *)fetchApplicationProxies {
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (wsClass == nil) return @[];
    id ws = nil;
    @try { ws = [wsClass performSelector:@selector(defaultWorkspace)]; }
    @catch (NSException *e) {}
    if (ws == nil) return @[];
    if ([ws respondsToSelector:@selector(atl_allInstalledApplications)]) {
        @try {
            NSArray *arr = [ws performSelector:@selector(atl_allInstalledApplications)];
            if (arr.count) return arr;
        } @catch (NSException *e) {}
    }
    if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
        @try {
            NSArray *arr = [ws performSelector:@selector(allInstalledApplications)];
            if (arr.count) return arr;
        } @catch (NSException *e) {}
    }
    if ([ws respondsToSelector:@selector(allApplications)]) {
        @try {
            NSArray *arr = [ws performSelector:@selector(allApplications)];
            if (arr.count) return arr;
        } @catch (NSException *e) {}
    }
    return @[];
}

- (NSString *)bundleIDFromProxy:(id)proxy {
    NSString *bid = nil;
    @try { if ([proxy respondsToSelector:@selector(applicationIdentifier)])
        bid = [proxy performSelector:@selector(applicationIdentifier)]; }
    @catch (__unused NSException *e) {}
    if (bid.length == 0) {
        @try { if ([proxy respondsToSelector:@selector(bundleIdentifier)])
            bid = [proxy performSelector:@selector(bundleIdentifier)]; }
        @catch (__unused NSException *e) {}
    }
    return bid;
}

- (NSString *)displayNameFromProxy:(id)proxy fallback:(NSString *)fallback {
    NSString *name = nil;
    @try { if ([proxy respondsToSelector:@selector(localizedName)])
        name = [proxy performSelector:@selector(localizedName)]; }
    @catch (__unused NSException *e) {}
    if (name.length == 0) {
        @try { if ([proxy respondsToSelector:@selector(itemName)])
            name = [proxy performSelector:@selector(itemName)]; }
        @catch (__unused NSException *e) {}
    }
    if (name.length == 0) name = fallback;
    return name;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            NSMutableArray *specs = [NSMutableArray array];
            PSSpecifier *header = [PSSpecifier emptyGroupSpecifier];
            header.name = [NSString stringWithFormat:@"共 %lu 个 App（系统已过滤）",
                           (unsigned long)self.allApps.count];
            [specs addObject:header];
            for (NSDictionary *app in self.allApps) {
                NSString *bid = app[@"bundleID"] ?: @"";
                NSString *name = app[@"name"] ?: bid;
                if (name.length == 0) name = @"Unknown";
                PSSpecifier *spec =
                    [PSSpecifier preferenceSpecifierNamed:name
                                                  target:self
                                                     set:@selector(setValue:forSpecifier:)
                                                     get:@selector(getValue:)
                                                  detail:nil
                                                    cell:PSSwitchCell
                                                    edit:nil];
                [spec setProperty:bid forKey:@"bundleID"];
                [specs addObject:spec];
            }
            if (self.allApps.count == 0) {
                PSSpecifier *empty =
                    [PSSpecifier preferenceSpecifierNamed:@"未找到 App"
                                                   target:nil set:nil get:nil
                                                   detail:nil cell:PSStaticTextCell edit:nil];
                [specs addObject:empty];
            }
            _specifiers = specs;
        } @catch (NSException *e) {
            _specifiers = [NSMutableArray array];
        }
    }
    return _specifiers;
}

- (id)getValue:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    if (!bid) return @NO;
    return @([self.enabledApps[bid] boolValue]);
}

- (void)setValue:(id)value forSpecifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    if (!bid) return;
    self.enabledApps[bid] = @([value boolValue]);
}

@end
