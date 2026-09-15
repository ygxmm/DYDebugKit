#import "DYDebugKitRootListController.h"
#import <notify.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

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
@property (nonatomic, strong) NSString *diagInfo;
@end

@implementation DYDebugKitRootListController

static void DYLoadAltListIfNeeded(NSMutableArray *log) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = @[
            @"/var/jb/Library/Frameworks/AltList.framework/AltList",
            @"/Library/Frameworks/AltList.framework/AltList",
        ];
        // 再扫 roothide 的 .jbroot-* 目录
        NSString *containers = @"/private/var/containers/Bundle/Application";
        NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:containers error:nil];
        for (NSString *d in dirs) {
            if ([d hasPrefix:@".jbroot-"]) {
                NSString *p = [containers stringByAppendingPathComponent:
                               [d stringByAppendingString:@"/Library/Frameworks/AltList.framework/AltList"]];
                paths = [paths arrayByAddingObject:p];
            }
        }

        BOOL loaded = NO;
        for (NSString *p in paths) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
                [log addObject:[NSString stringWithFormat:@"X %@", p.lastPathComponent]];
                continue;
            }
            void *h = dlopen(p.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
            if (h) {
                [log addObject:[NSString stringWithFormat:@"OK %@", p]];
                loaded = YES;
                break;
            } else {
                [log addObject:[NSString stringWithFormat:@"FAIL %@", dlerror()]];
            }
        }
        if (!loaded) [log addObject:@"AltList not loaded"];
    });
}

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
                                           message:@"已保存"
                                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)loadApps {
    NSMutableArray *log = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *dict = [NSMutableDictionary dictionary];

    DYLoadAltListIfNeeded(log);

    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    [log addObject:[NSString stringWithFormat:@"WS=%@", wsClass ? @"Y" : @"N"]];

    if (wsClass) {
        id ws = [wsClass performSelector:@selector(defaultWorkspace)];
        [log addObject:[NSString stringWithFormat:@"ws=%@", ws ? @"Y" : @"N"]];

        if (ws) {
            BOOL hasAtl = [ws respondsToSelector:@selector(atl_allInstalledApplications)];
            [log addObject:[NSString stringWithFormat:@"atl=%@", hasAtl ? @"Y" : @"N"]];

            NSArray *proxies = nil;
            if (hasAtl) {
                @try {
                    proxies = [ws performSelector:@selector(atl_allInstalledApplications)];
                } @catch (NSException *e) {
                    [log addObject:[NSString stringWithFormat:@"atl-err:%@", e.reason ?: @"?"]];
                }
            }
            if (!proxies.count && [ws respondsToSelector:@selector(allApplications)]) {
                @try {
                    proxies = [ws performSelector:@selector(allApplications)];
                } @catch (NSException *e) {
                    [log addObject:[NSString stringWithFormat:@"all-err:%@", e.reason ?: @"?"]];
                }
            }
            [log addObject:[NSString stringWithFormat:@"raw=%lu", (unsigned long)proxies.count]];

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
    }

    if (dict.count == 0) {
        NSArray *roots = @[
            @"/var/containers/Bundle/Application",
            @"/private/var/containers/Bundle/Application",
            @"/Applications",
        ];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *root in roots) {
            if (![fm fileExistsAtPath:root]) {
                [log addObject:[NSString stringWithFormat:@"X %@", root.lastPathComponent]];
                continue;
            }
            NSArray *items = [fm contentsOfDirectoryAtPath:root error:nil];
            [log addObject:[NSString stringWithFormat:@"scan %@=%lu",
                            root.lastPathComponent, (unsigned long)items.count]];
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
    }

    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (NSString *bid in dict) {
        [list addObject:@{ @"bundleID": bid, @"name": dict[bid] }];
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCompare:b[@"name"]];
    }];
    self.allApps = list;
    [log addObject:[NSString stringWithFormat:@"total=%lu", (unsigned long)list.count]];
    self.diagInfo = [log componentsJoinedByString:@" | "];
    NSLog(@"[DYDebugKit] DIAG: %@", self.diagInfo);
}

- (NSArray *)specifiers {
    if (!self.cachedSpecifiers) {
        @try {
            NSMutableArray *specs = [NSMutableArray array];
            PSSpecifier *header = [PSSpecifier emptyGroupSpecifier];
            header.name = self.diagInfo ?: @"诊断信息未生成";
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
            self.cachedSpecifiers = [specs copy];
        } @catch (NSException *e) {
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
