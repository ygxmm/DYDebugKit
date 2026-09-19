#import "DYDebugKitRootListController.h"
#import <notify.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <mach-o/dyld.h>

// 自己扫描 jbroot 目录，绕过 roothide.h
static NSString *DYJBPath(NSString *path) {
    static NSString *jbroot = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *dirs = [fm contentsOfDirectoryAtPath:@"/var/mobile/Containers/Shared/AppGroup" error:nil];
        for (NSString *d in dirs) {
            if ([d hasPrefix:@".jbroot-"]) {
                jbroot = [@"/var/mobile/Containers/Shared/AppGroup" stringByAppendingPathComponent:d];
                break;
            }
        }
    });
    if (jbroot == nil) return path;
    return [jbroot stringByAppendingPathComponent:path];
}


#define kPrefsPath @"/var/mobile/Library/Preferences/com.ygxmm.dydebugkit.plist"

@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)itemName;
- (NSString *)bundleIdentifier;
- (NSURL *)bundleURL;
- (NSData *)iconDataForVariant:(int)variant;
- (UIImage *)atl_icon;
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

// 切后台回来时 PSListController 会清掉 _specifiers，
// override getter 保证任何时候都是最新的。
- (NSArray *)specifiers {
    if (_specifiers == nil || _specifiers.count == 0) {
        [self rebuildSpecifiers];
    }
    return _specifiers;
}

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
    _specifiers = nil;          // 强制重建
    if (self.allApps.count == 0) [self loadApps];
    [self rebuildSpecifiers];
}

- (void)loadPrefs {
    NSString *path = DYJBPath(@"/var/mobile/Library/Preferences/dydebugkit.json");
    int fd = open(path.UTF8String, O_RDONLY);
    if (fd >= 0) {
        NSMutableData *data = [NSMutableData data];
        char buf[4096]; ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0) [data appendBytes:buf length:n];
        close(fd);
        if (data.length > 0) {
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([d isKindOfClass:NSDictionary.class]) {
                self.enabledApps = [d mutableCopy];
                return;
            }
        }
    }
    self.enabledApps = [NSMutableDictionary dictionary];
}

- (void)savePrefs {
    @try {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:self.enabledApps ?: @{} options:0 error:nil];
        NSString *prefPath = DYJBPath(@"/var/mobile/Library/Preferences/dydebugkit.json");
        int pfd = open(prefPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (pfd >= 0) { write(pfd, jsonData.bytes, jsonData.length); close(pfd); }
    } @catch (NSException *e) {}

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"];
    [xml appendString:@"<plist version=\"1.0\">\n<dict>\n<key>Filter</key>\n<dict>\n<key>Bundles</key>\n<array>\n"];
    NSUInteger cnt = 0;
    for (NSString *bid in self.enabledApps) {
        if ([self.enabledApps[bid] boolValue]) {
            [xml appendFormat:@"    <string>%@</string>\n", bid];
            cnt++;
        }
    }
    [xml appendString:@"</array>\n</dict>\n</dict>\n</plist>\n"];

    @try {
        NSData *xmlData = [xml dataUsingEncoding:NSUTF8StringEncoding];
        NSString *plistPath = DYJBPath(@"/usr/lib/TweakInject/DYDebugKit.plist");
        int fd = open(plistPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) { write(fd, xmlData.bytes, xmlData.length); close(fd); }
    } @catch (NSException *e) {}

    notify_post("com.ygxmm.dydebugkit/reload");

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"DYDebugKit"
                                           message:[NSString stringWithFormat:@"已保存 %lu 个 App\n重启对应 App 后生效", (unsigned long)cnt]
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

                    UIImage *icon = nil;
                    @try {
                        // AltList 提供 atl_icon，跨进程拿图标
                        if ([proxy respondsToSelector:@selector(atl_icon)]) {
                            icon = [proxy performSelector:@selector(atl_icon)];
                        }
                        // 兜底：直接 iconDataForVariant
                        if (icon == nil && [proxy respondsToSelector:@selector(iconDataForVariant:)]) {
                            NSData *data = [proxy performSelector:@selector(iconDataForVariant:) withObject:(__bridge id)(void *)2];
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

    self.allApps = [dict.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCompare:b[@"name"]];
    }];
}

- (void)rebuildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    NSUInteger enabledCount = 0;
    for (NSString *bid in self.enabledApps) {
        if ([self.enabledApps[bid] boolValue]) enabledCount++;
    }
    PSSpecifier *header = [PSSpecifier emptyGroupSpecifier];
    header.name = [NSString stringWithFormat:@"已启用 %lu / 共 %lu 个 App",
                   (unsigned long)enabledCount, (unsigned long)self.allApps.count];
    [specs addObject:header];

    UILocalizedIndexedCollation *collation = [UILocalizedIndexedCollation currentCollation];
    NSInteger sectionCount = [collation sectionIndexTitles].count;
    NSMutableArray<NSMutableArray *> *sections = [NSMutableArray array];
    for (NSInteger i = 0; i < sectionCount; i++) [sections addObject:[NSMutableArray array]];
    for (NSDictionary *app in self.allApps) {
        NSString *name = app[@"name"] ?: @"?";
        NSInteger idx = [collation sectionForObject:@[name, app] collationStringSelector:@selector(firstObject)];
        if (idx < 0 || idx >= sectionCount) idx = sectionCount - 1;
        [sections[idx] addObject:app];
    }

    NSArray *titles = [collation sectionIndexTitles];
    for (NSInteger si = 0; si < sectionCount; si++) {
        NSMutableArray *appsInSection = sections[si];
        if (appsInSection.count == 0) continue;

        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        group.name = titles[si];
        [specs addObject:group];

        for (NSDictionary *app in appsInSection) {
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
            if (icon) [spec setProperty:icon forKey:@"iconImage"];
            [specs addObject:spec];
        }
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
