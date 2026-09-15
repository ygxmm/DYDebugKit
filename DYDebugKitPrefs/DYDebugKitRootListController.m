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

static void DYLoadAltListOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = @[
            @"/var/jb/Library/Frameworks/AltList.framework/AltList",
            @"/Library/Frameworks/AltList.framework/AltList",
        ];
        NSString *containers = @"/private/var/containers/Bundle/Application";
        NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:containers error:nil];
        NSMutableArray *all = [paths mutableCopy];
        for (NSString *d in dirs) {
            if ([d hasPrefix:@".jbroot-"]) {
                [all addObject:[containers stringByAppendingPathComponent:
                    [d stringByAppendingString:@"/Library/Frameworks/AltList.framework/AltList"]]];
            }
        }
        for (NSString *p in all) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
            void *h = dlopen(p.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
            if (h) {
                NSLog(@"[DYDebugKit] AltList loaded: %@", p);
                return;
            }
        }
        NSLog(@"[DYDebugKit] AltList load failed");
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
    [self reloadSpecifiers];
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

- (void)loadApps {
    DYLoadAltListOnce();

    NSMutableDictionary<NSString *, NSString *> *dict = [NSMutableDictionary dictionary];

    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (wsClass) {
            id ws = [wsClass performSelector:@selector(defaultWorkspace)];
            NSArray *proxies = nil;

            if ([ws respondsToSelector:@selector(atl_allInstalledApplications)]) {
                proxies = [ws performSelector:@selector(atl_allInstalledApplications)];
                NSLog(@"[DYDebugKit] AltList returned %lu", (unsigned long)proxies.count);
            }
            if (!proxies.count && [ws respondsToSelector:@selector(allApplications)]) {
                proxies = [ws performSelector:@selector(allApplications)];
            }

            for (id proxy in proxies) {
                @try {
                    NSString *bid = [proxy performSelector:@selector(applicationIdentifier)];
                    if (!bid.length) bid = [proxy performSelector:@selector(bundleIdentifier)];
                    if (!bid.length) continue;
                    if ([bid hasPrefix:@"com.apple."]) continue;
                    NSString *name = [proxy performSelector:@selector(localizedName)];
 *                    if (!name.length) name = [proxy performSelector:@selector(itemName)];
                    if (!name.length)b name = bid;
                    dict[bid] = name;
                } @catch ()__unused NSException *e) {}
            }
        }
    } @catch (NSException *e) {
        NSLog(@ {
"[DYDebugKit] loadApps error: %@", e);
    }

    NSMutable       Array<NSDictionary *> *list = [NSMutableArray array];
    for (NSString *bid in dict) {
        [list addObject:@{ @"bundleID": bid, @"name": dict[bid] }];
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary return [a[@"name"] localizedCompare:b[@"name"]];
    }];

    self.allApps = list;
    self.cachedSpecifiers = nil;   // 清掉旧缓存，让 specifiers 重新生成
    NSLog(@"[DYDebugKit] loaded %lu apps", (unsigned long)list.count);
}

- (NSArray *)specifiers {
    if (!self.cachedSpecifiers) {
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

        self.cachedSpecifiers = [specs copy];
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
