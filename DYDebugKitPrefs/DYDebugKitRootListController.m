#import "DYDebugKitRootListController.h"
#import <notify.h>
#import <dlfcn.h>

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
@property (nonatomic, strong) NSArray *cachedSpecifiers;
@end

@implementation DYDebugKitRootListController

#pragma mark - AltList 动态加载

static void DYLoadAltListIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *paths[] = {
            "/var/jb/Library/Frameworks/AltList.framework/AltList",
            "/Library/Frameworks/AltList.framework/AltList",
            NULL,
        };
        void *handle = NULL;
        for (int i = 0; paths[i] != NULL; i++) {
            handle = dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
            if (handle) {
                NSLog(@"[DYDebugKit] AltList loaded: %s", paths[i]);
                break;
            }
            NSLog(@"[DYDebugKit] AltList dlopen fail: %s", dlerror());
        }
    });
}

#pragma mark - Lifecycle

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
        NSDictionary *d = @{ @"enabledApps": self.enabledApps ?: @{} };
        [d writeToFile:kPrefsPath atomically:YES];
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

#pragma mark - 枚举 App

- (void)loadApps {
    // 关键：先加载 AltList
    DYLoadAltListIfNeeded();

    NSMutableDictionary<NSString *, NSString *> *dict = [NSMutableDictionary dictionary];

    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (wsClass) {
            id ws = [wsClass performSelector:@selector(defaultWorkspace)];
            NSArray *proxies = nil;

            if ([ws respondsToSelector:@selector(atl_allInstalledApplications)]) {
                proxies = [ws performSelector:@selector(atl_allInstalledApplications)];
                NSLog(@"[DYDebugKit] using AltList atl_allInstalledApplications: %lu",
                      (unsigned long)proxies.count);
            }
            if (!proxies.count && [ws respondsToSelector:@selector(allInstalledApplications)]) {
                proxies = [ws performSelector:@selector(allInstalledApplications)];
                NSLog(@"[DYDebugKit] using allInstalledApplications: %lu",
                      (unsigned long)proxies.count);
            }
            if (!proxies.count && [ws respondsToSelector:@selector(allApplications)]) {
                proxies = [ws performSelector:@selector(allApplications)];
                NSLog(@"[DYDebugKit] using allApplications: %lu",
                      (unsigned long)proxies.count);
            }

            for (id proxy in proxies) {
                @try {
                    NSString *bid = [proxy performSelector:@selector(applicationIdentifier)];
                    if (!bid.length) bid = [proxy performSelector:@selector(bundleIdentifier)];
                    if (!bid.length) continue;
                    if ([bid hasPrefix:@"com.apple."]) continue;
                    NSString *name = [proxy performSelector:@selector(localizedName)];
                    if (!name.length) name = [proxy performSelector:@selector(itemName)];
                    if (!name.length) name = bid;
                    dict[bid] = name;
                } @catch (__unused NSException *e) {}
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[DYDebugKit] workspace error: %@", e);
    }

    // 目录扫描兜底
    if (dict.count == 0) {
        NSArray *roots = @[
            @"/var/containers/Bundle/Application",
            @"/private/var/containers/Bundle/Application",
            @"/Applications",
        ];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *root in roots) {
            NSArray *items = [fm contentsOfDirectoryAtPath:root error:nil];
            for (NSString *item in items) {
                @try {
                    NSString *appPath = nil;
                    NSString *full = [root stringByAppendingPathComponent:item];
                    if ([item hasSuffix:@".app"]) {
                        appPath = full;
                    } else {
                        NSArray *subs = [fm contentsOfDirectoryAtPath:full error:nil];
                        for (NSString *sub in subs) {
                            if ([sub hasSuffix:@".app"]) {
                                appPath = [full stringByAppendingPathComponent:sub];
                                break;
                            }
                        }
                    }
                    if (!appPath) continue;
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                          [appPath stringByAppendingPathComponent:@"Info.plist"]];
                    NSString *bid = info[@"CFBundleIdentifier"];
                    if (!bid.length) continue;
                    if ([bid hasPrefix:@"com.apple."]) continue;
                    NSString *name = info[@"CFBundleDisplayName"]
                                     ?: info[@"CFBundleName"]
                                     ?: appPath.lastPathComponent;
                    dict[bid] = name;
                } @catch (__unused NSException *e) {}
            }
        }
        NSLog(@"[DYDebugKit] after directory scan: %lu", (unsigned long)dict.count);
    }

    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (NSString *bid in dict) {
        [list addObject:@{ @"bundleID": bid, @"name": dict[bid] }];
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCompare:b[@"name"]];
    }];
    self.allApps = list;
    NSLog(@"[DYDebugKit] total found %lu apps", (unsigned long)list.count);
}

#pragma mark - Specifiers

- (NSArray *)specifiers {
    if (!self.cachedSpecifiers) {
        @try {
            NSMutableArray *specs = [NSMutableArray array];
            PSSpecifier *header = [PSSpecifier emptyGroupSpecifier];
            header.name = [NSString stringWithFormat:@"共 %lu 个 App（系统已过滤）",
                           (unsigned long)self.allApps.count];
            [specs addObject:header];

            for (NSDictionary *app in self.allApps) {
                NSString *bid = app[@"bundleID"] ?: @"";
                NSString *name = app[@"name"] ?: bid;
                if (!name.length) name = @"Unknown";
                PSSpecifier *spec =
                    [PSSpecifier preferenceSpecifierNamed:name
                                                  target:self
                                                     set:@selector(dy_setValue:forSpecifier:)
                                                     get:@selector(dy_getValue:)
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
                                                   detail:nil cell:PSGroupCell edit:nil];
                [specs addObject:empty];
            }
            self.cachedSpecifiers = [specs copy];
        } @catch (NSException *e) {
            NSLog(@"[DYDebugKit] specifiers error: %@", e);
            self.cachedSpecifiers = @[];
        }
    }
    return self.cachedSpecifiers;
}

- (id)dy_getValue:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    if (!bid) return @NO;
    return @([self.enabledApps[bid] boolValue]);
}

- (void)dy_setValue:(id)value forSpecifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    if (!bid) return;
    self.enabledApps[bid] = @([value boolValue]);
}

@end
