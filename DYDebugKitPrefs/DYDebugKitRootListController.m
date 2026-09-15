#import "DYDebugKitRootListController.h"
#import <notify.h>

#define kPrefsPath @"/var/mobile/Library/Preferences/com.ygxmm.dydebugkit.plist"

@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)itemName;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
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
    NSDictionary *dict = @{ @"enabledApps": self.enabledApps ?: @{} };
    [dict writeToFile:kPrefsPath atomically:YES];
    notify_post("com.ygxmm.dydebugkit/reload");
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

    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (wsClass) {
        id ws = [wsClass performSelector:@selector(defaultWorkspace)];
        NSArray *proxies = nil;
        if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
            proxies = [ws performSelector:@selector(allInstalledApplications)];
        }
        if (!proxies.count && [ws respondsToSelector:@selector(allApplications)]) {
            proxies = [ws performSelector:@selector(allApplications)];
        }

        for (id proxy in proxies) {
            @autoreleasepool {
                NSString *bid = nil;
                if ([proxy respondsToSelector:@selector(applicationIdentifier)]) {
                    bid = [proxy performSelector:@selector(applicationIdentifier)];
                }
                if (bid.length == 0) continue;
                if ([bid hasPrefix:@"com.apple."]) continue;

                NSString *name = nil;
                if ([proxy respondsToSelector:@selector(localizedName)]) {
                    name = [proxy performSelector:@selector(localizedName)];
                }
                if (name.length == 0 && [proxy respondsToSelector:@selector(itemName)]) {
                    name = [proxy performSelector:@selector(itemName)];
                }
                if (name.length == 0) name = bid;
                dict[bid] = name;
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
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *header = [PSSpecifier emptyGroupSpecifier];
        header.name = [NSString stringWithFormat:@"共 %lu 个 App（系统已过滤）",
                       (unsigned long)self.allApps.count];
        [specs addObject:header];

        for (NSDictionary *app in self.allApps) {
            PSSpecifier *spec =
                [PSSpecifier preferenceSpecifierNamed:app[@"name"]
                                              target:self
                                                 set:@selector(setValue:forSpecifier:)
                                                 get:@selector(getValue:)
                                              detail:nil
                                                cell:PSSwitchCell
                                                edit:nil];
            [spec setProperty:app[@"bundleID"] forKey:@"bundleID"];
            [specs addObject:spec];
        }

        _specifiers = specs;
    }
    return _specifiers;
}

- (id)getValue:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    return @([self.enabledApps[bid] boolValue]);
}

- (void)setValue:(id)value forSpecifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    if (bid) self.enabledApps[bid] = @([value boolValue]);
}

@end
