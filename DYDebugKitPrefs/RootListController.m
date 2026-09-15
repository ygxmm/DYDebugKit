#import "RootListController.h"
#import <notify.h>

#define kPrefsPath @"/var/mobile/Library/Preferences/com.ygxmm.dydebugkit.plist"

@interface RootListController ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *enabledApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@end

@implementation RootListController

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

#pragma mark - Prefs I/O

- (void)loadPrefs {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    NSDictionary *enabled = dict[@"enabledApps"];
    self.enabledApps = [enabled mutableCopy] ?: [NSMutableDictionary dictionary];
}

- (void)savePrefs {
    NSDictionary *dict = @{ @"enabledApps": self.enabledApps ?: @{} };
    [dict writeToFile:kPrefsPath atomically:YES];

    // 通知所有进程刷新（App 重启后生效）
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

#pragma mark - 枚举已安装 App

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

            // 情况 1：直接是 .app
            if ([item hasSuffix:@".app"]) {
                [self addAppAtPath:full toDict:dict];
                continue;
            }

            // 情况 2：UUID 目录里含 .app
            NSArray<NSString *> *subs = [fm contentsOfDirectoryAtPath:full error:nil];
            for (NSString *sub in subs) {
                if ([sub hasSuffix:@".app"]) {
                    NSString *appFull = [full stringByAppendingPathComponent:sub];
                    [self addAppAtPath:appFull toDict:dict];
                }
            }
        }
    }

    // 转数组按名字排序
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
    // 跳过系统内部 App
    if ([bid hasPrefix:@"com.apple."] && ![@[@"com.apple.Preferences"] containsObject:bid]) {
        // 系统 App 也允许显示，但如果你不想显示系统 App，去掉这个 return 就行
    }
    NSString *name = info[@"CFBundleDisplayName"]
                     ?: info[@"CFBundleName"]
                     ?: appPath.lastPathComponent;
    dict[bid] = name;
}

#pragma mark - Specifiers

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
            [spec setProperty:name forKey:@"displayName"];
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
    if (!bid) return;
    self.enabledApps[bid] = @([value boolValue]);
}

@end