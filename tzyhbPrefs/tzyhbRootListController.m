#import "tzyhbRootListController.h"
#import <notify.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
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


#define kPrefsPath @"/var/mobile/Library/Preferences/com.tzyhb.tzyhb.plist"

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

@interface tzyhbRootListController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *enabledApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@property (nonatomic, strong) UISearchController *appSearchController;
@property (nonatomic, copy) NSString *appSearchText;
@property (nonatomic, assign) BOOL hasPendingPreferenceChanges;
@end

@implementation tzyhbRootListController

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
    self.title = @"tzyhb";
    self.definesPresentationContext = YES;
    self.appSearchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.appSearchController.searchResultsUpdater = self;
    self.appSearchController.obscuresBackgroundDuringPresentation = NO;
    self.appSearchController.hidesNavigationBarDuringPresentation = NO;
    self.appSearchController.searchBar.placeholder = @"搜索 App 名称或 Bundle ID";
    self.appSearchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.appSearchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.appSearchController.searchBar.accessibilityLabel = @"搜索已安装的 App";
    self.appSearchController.searchBar.accessibilityHint = @"输入应用名称或 Bundle ID 过滤列表";
    self.appSearchController.searchBar.searchTextField.accessibilityLabel = @"搜索已安装的 App";
    self.appSearchController.searchBar.searchTextField.accessibilityHint = @"输入应用名称或 Bundle ID 过滤列表";
    self.navigationItem.searchController = self.appSearchController;
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
    if (!self.hasPendingPreferenceChanges) [self loadPrefs];
    _specifiers = nil;          // 强制重建
    if (self.allApps.count == 0) [self loadApps];
    [self rebuildSpecifiers];
}

- (void)loadPrefs {
    self.hasPendingPreferenceChanges = NO;
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
    NSError *error = nil;
    NSDictionary *settings = self.enabledApps ?: @{};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:settings options:0 error:&error];
    if (jsonData == nil) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存失败"
            message:[NSString stringWithFormat:@"无法序列化应用设置：%@", error.localizedDescription ?: @"未知错误"]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSMutableArray<NSString *> *bundles = [NSMutableArray array];
    for (NSString *bid in settings) {
        if ([settings[bid] boolValue]) [bundles addObject:bid];
    }
    NSUInteger cnt = bundles.count;
    NSDictionary *plist = @{ @"Filter": @{ @"Bundles": bundles } };
    error = nil;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:plist
        format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (plistData == nil) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存失败"
            message:[NSString stringWithFormat:@"无法生成注入配置：%@", error.localizedDescription ?: @"未知错误"]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *prefPath = DYJBPath(@"/var/mobile/Library/Preferences/dydebugkit.json");
    BOOL previousJSONExists = NO;
    NSData *previousJSON = nil;
    int previousFD = open(prefPath.UTF8String, O_RDONLY);
    int snapshotErrorCode = 0;
    if (previousFD >= 0) {
        previousJSONExists = YES;
        NSMutableData *snapshot = [NSMutableData data];
        char buffer[4096];
        while (YES) {
            ssize_t bytesRead = read(previousFD, buffer, sizeof(buffer));
            if (bytesRead > 0) {
                [snapshot appendBytes:buffer length:(NSUInteger)bytesRead];
            } else if (bytesRead == 0) {
                break;
            } else if (errno != EINTR) {
                snapshotErrorCode = errno;
                break;
            }
        }
        close(previousFD);
        if (snapshotErrorCode == 0) previousJSON = [snapshot copy];
    } else if (errno != ENOENT) {
        snapshotErrorCode = errno;
    }
    if (snapshotErrorCode != 0) {
        NSError *snapshotError = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:snapshotErrorCode userInfo:nil];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存失败"
            message:[NSString stringWithFormat:@"无法备份当前设置，未写入新配置（%@）：%@", prefPath, snapshotError.localizedDescription ?: @"未知错误"]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    error = nil;
    if (![jsonData writeToFile:prefPath options:NSDataWritingAtomic error:&error]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存失败"
            message:[NSString stringWithFormat:@"写入应用设置文件失败（%@）：%@", prefPath, error.localizedDescription ?: @"未知错误"]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *plistPath = DYJBPath(@"/usr/lib/TweakInject/tzyhb.plist");
    error = nil;
    if (![plistData writeToFile:plistPath options:NSDataWritingAtomic error:&error]) {
        NSError *rollbackError = nil;
        BOOL rolledBack = NO;
        if (previousJSONExists) {
            rolledBack = [previousJSON writeToFile:prefPath options:NSDataWritingAtomic error:&rollbackError];
        } else {
            int unlinkResult = unlink(prefPath.UTF8String);
            if (unlinkResult == 0 || errno == ENOENT) {
                rolledBack = YES;
            } else {
                rollbackError = [NSError errorWithDomain:NSPOSIXErrorDomain
                    code:errno userInfo:nil];
            }
        }
        NSString *rollbackMessage = rolledBack
            ? @"应用设置 JSON 已恢复为保存前状态。"
            : [NSString stringWithFormat:@"JSON 回滚也失败（%@）；请检查设置文件。", rollbackError.localizedDescription ?: @"未知错误"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存失败"
            message:[NSString stringWithFormat:@"写入注入配置失败（%@）：%@\n%@", plistPath, error.localizedDescription ?: @"未知错误", rollbackMessage]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.hasPendingPreferenceChanges = NO;
    notify_post("com.tzyhb.tzyhb/reload");

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"tzyhb"
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

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text ?: @"";
    if ([self.appSearchText isEqualToString:query]) return;
    self.appSearchText = query;
    [self rebuildSpecifiers];
}

- (void)rebuildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSString *query = [self.appSearchText stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    BOOL isSearching = query.length > 0;
    NSArray<NSDictionary *> *appsToDisplay = self.allApps ?: @[];
    if (isSearching) {
        NSPredicate *match = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
            NSString *name = app[@"name"] ?: @"";
            NSString *bundleID = app[@"bundleID"] ?: @"";
            return [name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [bundleID rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        appsToDisplay = [appsToDisplay filteredArrayUsingPredicate:match];
    }

    NSUInteger enabledCount = 0;
    for (NSString *bid in self.enabledApps) {
        if ([self.enabledApps[bid] boolValue]) enabledCount++;
    }
    PSSpecifier *header = [PSSpecifier emptyGroupSpecifier];
    header.name = [NSString stringWithFormat:@"已启用 %lu / 共 %lu 个 App",
                   (unsigned long)enabledCount, (unsigned long)self.allApps.count];
    [specs addObject:header];

    UILocalizedIndexedCollation *collation = [UILocalizedIndexedCollation currentCollation];
    NSArray *titles = [collation sectionIndexTitles];
    NSInteger sectionCount = isSearching ? 1 : (NSInteger)titles.count;
    NSMutableArray<NSMutableArray *> *sections = [NSMutableArray array];
    for (NSInteger i = 0; i < sectionCount; i++) [sections addObject:[NSMutableArray array]];
    if (isSearching) {
        [sections[0] addObjectsFromArray:appsToDisplay];
    } else {
        for (NSDictionary *app in appsToDisplay) {
            NSString *name = app[@"name"] ?: @"?";
            NSInteger idx = [collation sectionForObject:@[name, app] collationStringSelector:@selector(firstObject)];
            if (idx < 0 || idx >= sectionCount) idx = sectionCount - 1;
            [sections[idx] addObject:app];
        }
    }

    for (NSInteger si = 0; si < sectionCount; si++) {
        NSMutableArray *appsInSection = sections[si];
        if (appsInSection.count == 0 && !isSearching) continue;

        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        group.name = isSearching
            ? (appsInSection.count ? [NSString stringWithFormat:@"搜索结果（%lu）", (unsigned long)appsInSection.count] : @"没有匹配的 App")
            : titles[si];
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
    self.hasPendingPreferenceChanges = YES;
}

@end
