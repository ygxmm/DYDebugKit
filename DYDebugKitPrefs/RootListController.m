#import "RootListController.h"
#import <notify.h>

#define kPrefsPath @"/var/mobile/Library/Preferences/com.ygxmm.dydebugkit.plist"

@interface RootListController ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *enabledApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@end

@implementation RootListController

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
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray<NSString *> *roots = @[
        @"/Applications",
        @"/var/containers/Bundle/Application",
        @"/private/var/containers/Bundle/Application",
    ];

    for (NSString *root in roots) {
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *item in items) {
            NSString *full = [root stringByAppendingPathComponent:item];
            if ([item hasSuffix:@".app"]) {
                [self addAppAtPath:full toDict:dict];
                continue;
            }
            NSArray<NSString *> *subs = [fm contentsOfDirectoryAtPath:full error:nil];
            for (NSString *sub in subs) {
                if ([sub hasSuffix:@".app"]) {
                    [self addAppAtPath:[full stringByAppendingPathComponent:sub] toDict:dict];
                }
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

- (void)addAppAtPath:(NSString *)appPath
              toDict:(NSMutableDictionary<NSString *, NSString *> *)dict {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [appPath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bid = info[@"CFBundleIdentifier"];
    if (bid.length == 0) return;

    NSString *name = info[@"CFBundleDisplayName"]
                     ?: info[@"CFBundleName"]
                     ?: appPath.lastPathComponent;
    dict[bid] = name;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *groupHeader = [PSSpecifier emptyGroupSpecifier];
        groupHeader.name = @"勾选后重启对应 App 即可使用浮窗（默认全部关闭）";
        [specs addObject:groupHeader];

        for (NSDictionary *app in self.allApps) {
            NSString *bid = app[@"bundleID"];
            NSString *name = app[@"name"];

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
