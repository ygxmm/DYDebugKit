#import "DYDebugKitRootListController.h"
#import <notify.h>
#import <dlfcn.h>

#define kPrefsPath @"/var/jb/var/mobile/Library/Preferences/com.ygxmm.dydebugkit.plist"

@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)itemName;
- (NSString *)bundleIdentifier;
- (NSURL *)bundleURL;
- (NSData *)iconDataForVariant:(int)variant;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
- (NSArray *)atl_allInstalledApplications;
@end

@interface DYDebugKitRootListController ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *enabledApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@end

@implementation DYDebugKitRootListController

static void DYLoadAltListOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *paths = [NSMutableArray arrayWithObjects:
            @"/var/jb/Library/Frameworks/AltList.framework/AltList",
            @"/Library/Frameworks/AltList.framework/AltList", nil];
        NSString *containers = @"/private/var/containers/Bundle/Application";
        NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:containers error:nil];
        for (NSString *d in dirs) {
            if ([d hasPrefix:@".jbroot-"]) {
                NSString *p = [containers stringByAppendingPathComponent:
                    [d stringByAppendingString:@"/Library/Frameworks/AltList.framework/AltList"]];
                [paths addObject:p];
            }
        }
        for (NSString *p in paths) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
            if (dlopen(p.UTF8String, RTLD_LAZY | RTLD_GLOBAL)) return;
        }
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
    [self rebuildSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadPrefs];
    if (self.allApps.count == 0) [self loadApps];
    [self rebuildSpecifiers];
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

    NSMutableDictionary<NSString *, NSDictionary *> *dict = [NSMutableDictionary dictionary];

    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (wsClass) {
            id ws = [wsClass performSelector:@selector(defaultWorkspace)];
            NSArray *proxies = nil;
            if ([ws respondsToSelector:@selector(atl_allInstalledApplications)])
                proxies = [ws performSelector:@selector(atl_allInstalledApplications)];
            if (!proxies.count && [ws respondsToSelector:@selector(allApplications)])
                proxies = [ws performSelector:@selector(allApplications)];

            for (id proxy in proxies) {
                @try {
                    NSString *bid = [proxy performSelector:@selector(applicationIdentifier)];
                    if (!bid.length) bid = [proxy performSelector:@selector(bundleIdentifier)];
                    if (!bid.length) continue;

                    NSString *name = [proxy performSelector:@selector(localizedName)];
                    if (!name.length) name = [proxy performSelector:@selector(itemName)];
                    if (!name.length) name = bid;

                    // 用私有 API 拿图标
                    UIImage *icon = nil;
                    @try {
                        SEL sel = @selector(iconDataForVariant:);
                        if ([proxy respondsToSelector:sel]) {
                            NSData *data = [proxy performSelector:sel withObject:(__bridge id)(void *)2];
                            if (!data) data = [proxy performSelector:sel withObject:(__bridge id)(void *)0];
                            if (data) icon = [UIImage imageWithData:data];
                        }
                    } @catch (__unused NSException *e) {}

                    NSMutableDictionary *item = [NSMutableDictionary dictionary];
                    item[@"bundleID"] = bid;
                    item[@"name"] = name;
                    if (icon) item[@"icon"] = icon;

                    dict[bid] = item;
                } @catch (__unused NSException *e) {}
            }
        }
    } @catch (NSException *e) {}

    NSArray *sorted = [dict.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCompare:b[@"name"]];
    }];
    self.allApps = sorted;
}

- (void)rebuildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    PSSpecifier *header = [PSSpecifier emptyGroupSpecifier];
    header.name = [NSString stringWithFormat:@"共 %lu 个 App（开关后重启对应 App 生效）",
                   (unsigned long)self.allApps.count];
    [specs addObject:header];

    for (NSDictionary *app in self.allApps) {
        NSString *bid = app[@"bundleID"] ?: @"";
        NSString *name = app[@"name"] ?: bid;
        UIImage *icon = app[@"icon"];

        PSSpecifier *spec =
            [PSSpecifier preferenceSpecifierNamed:name
                                          target:self
                                             set:@selector(setPreferenceValue:specifier:)
                                             get:@selector(readPreferenceValue:)
                                          detail:nil
                                            cell:PSSwitchCell
                                            edit:nil];
        [spec setProperty:bid forKey:@"bundleID"];
        [spec setProperty:bid forKey:@"subtitle"];
        [spec setProperty:@"PSSubtitleSwitchCell" forKey:@"cell"];

        if (icon) {
            [spec setProperty:icon forKey:@"iconImage"];
        }

        [specs addObject:spec];
    }

    [self setSpecifiers:specs];
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    if (!bid) return @NO;
    return @([self.enabledApps[bid] boolValue]);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    if (!bid) return;
    self.enabledApps[bid] = @([value boolValue]);
}

@end
