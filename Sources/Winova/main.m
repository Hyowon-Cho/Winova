#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef void (^WinovaLogHandler)(NSString *line);
typedef void (^WinovaStatusHandler)(NSString *text, BOOL ready);
typedef void (^WinovaCompletion)(NSError *error);

static NSError *WinovaError(NSString *message) {
    return [NSError errorWithDomain:@"com.hyowoncho.winova"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface WinovaRuntime : NSObject
@property(nonatomic, strong, readonly) NSURL *prefixURL;
@property(nonatomic, strong, readonly) NSURL *prefixRootURL;
@property(nonatomic, copy) WinovaLogHandler logHandler;
@property(nonatomic, copy) WinovaStatusHandler statusHandler;
- (NSString *)enginePath;
- (void)selectEngine:(NSString *)path;
- (void)reportEngineStatus;
- (NSArray<NSDictionary *> *)installedApplications;
- (void)prepareEnvironment:(WinovaCompletion)completion;
- (void)launchProgram:(NSURL *)program completion:(WinovaCompletion)completion;
- (void)launchInstalledApplication:(NSDictionary *)application completion:(WinovaCompletion)completion;
- (void)openConfiguration:(WinovaCompletion)completion;
@end

@implementation WinovaRuntime {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSNumber *, NSTask *> *_tasks;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.hyowoncho.winova.runtime", DISPATCH_QUEUE_SERIAL);
        _tasks = [NSMutableDictionary dictionary];
        NSURL *base = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask] firstObject];
        _prefixRootURL = [[[base URLByAppendingPathComponent:@"Winova" isDirectory:YES]
            URLByAppendingPathComponent:@"Prefixes" isDirectory:YES] copy];
        _prefixURL = [[_prefixRootURL URLByAppendingPathComponent:@"default" isDirectory:YES] copy];
        [[NSFileManager defaultManager] createDirectoryAtURL:_prefixURL
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    }
    return self;
}

- (NSString *)enginePath {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"enginePath"];
    if (saved.length && [files isExecutableFileAtPath:saved]) return saved;

    NSString *environment = NSProcessInfo.processInfo.environment[@"WINOVA_WINE"];
    if (environment.length && [files isExecutableFileAtPath:environment]) return environment;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSURL *resourceURL = NSBundle.mainBundle.resourceURL;
    if (resourceURL) [candidates addObject:[[resourceURL URLByAppendingPathComponent:@"engine/bin/wine"] path]];
    [candidates addObjectsFromArray:@[
        @"/opt/homebrew/bin/wine",
        @"/usr/local/bin/wine",
        @"/Applications/Wine Devel.app/Contents/Resources/wine/bin/wine",
        @"/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/Wine Devel.app/Contents/Resources/wine/bin/wine"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/Wine Stable.app/Contents/Resources/wine/bin/wine"]
    ]];
    for (NSString *path in candidates) {
        if ([files isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

- (void)selectEngine:(NSString *)path {
    [[NSUserDefaults standardUserDefaults] setObject:path forKey:@"enginePath"];
    [self reportEngineStatus];
}

- (void)reportEngineStatus {
    NSString *engine = self.enginePath;
    if (!engine) {
        if (self.statusHandler) self.statusHandler(@"Engine not configured", NO);
        return;
    }
    dispatch_async(_queue, ^{
        NSTask *task = [NSTask new];
        NSPipe *pipe = [NSPipe pipe];
        task.executableURL = [NSURL fileURLWithPath:engine];
        task.arguments = @[@"--version"];
        task.standardOutput = pipe;
        task.standardError = pipe;
        NSError *error = nil;
        [task launchAndReturnError:&error];
        [task waitUntilExit];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *version = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        version = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && task.terminationStatus == 0) {
                if (self.statusHandler) self.statusHandler(version.length ? version : @"Engine ready", YES);
            } else {
                if (self.statusHandler) self.statusHandler(@"Engine could not start", NO);
            }
        });
    });
}

- (NSURL *)prefixURLForName:(NSString *)prefixName {
    NSString *safeName = prefixName.lastPathComponent.length ? prefixName.lastPathComponent : @"default";
    return [self.prefixRootURL URLByAppendingPathComponent:safeName isDirectory:YES];
}

- (NSString *)prefixNameContainingPath:(NSString *)path {
    NSString *root = [self.prefixRootURL.path stringByStandardizingPath];
    NSString *candidate = [path stringByStandardizingPath];
    NSString *rootWithSlash = [root stringByAppendingString:@"/"];
    if (![candidate hasPrefix:rootWithSlash]) return @"default";
    NSString *relative = [candidate substringFromIndex:rootWithSlash.length];
    NSString *name = relative.pathComponents.firstObject;
    return name.length ? name : @"default";
}

- (NSMutableDictionary *)runtimeEnvironment:(NSString *)engine prefixName:(NSString *)prefixName {
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"WINEPREFIX"] = [self prefixURLForName:prefixName].path;
    environment[@"WINEDEBUG"] = @"-all";
    NSString *engineDirectory = [engine stringByDeletingLastPathComponent];
    NSString *oldPath = environment[@"PATH"] ?: @"";
    environment[@"PATH"] = [@[engineDirectory, @"/opt/homebrew/bin", @"/usr/local/bin", oldPath]
        componentsJoinedByString:@":"];
    return environment;
}

- (NSTask *)taskWithEngine:(NSString *)engine
                  arguments:(NSArray<NSString *> *)arguments
           workingDirectory:(NSURL *)directory
                 prefixName:(NSString *)prefixName {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:engine];
    task.arguments = arguments;
    task.currentDirectoryURL = directory;
    task.environment = [self runtimeEnvironment:engine prefixName:prefixName];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    __weak typeof(self) weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) return;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text.length) [weakSelf writeLog:[text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]];
    };
    return task;
}

- (NSString *)urlTargetAtURL:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data.length) return nil;
    NSArray<NSNumber *> *encodings = @[@(NSUTF8StringEncoding), @(NSUTF16LittleEndianStringEncoding),
                                       @(NSWindowsCP1252StringEncoding)];
    NSString *contents = nil;
    for (NSNumber *encoding in encodings) {
        contents = [[NSString alloc] initWithData:data encoding:encoding.unsignedIntegerValue];
        if (contents.length) break;
    }
    for (NSString *line in [contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if ([line.uppercaseString hasPrefix:@"URL="]) {
            return [[line substringFromIndex:4] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
    }
    return nil;
}

- (NSString *)decodedRegistryValue:(NSString *)value {
    NSString *decoded = [value stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
    return [decoded stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
}

- (NSString *)registryValueForLine:(NSString *)line name:(NSString *)name {
    NSString *prefix = [NSString stringWithFormat:@"\"%@\"=\"", name];
    if (![line hasPrefix:prefix] || ![line hasSuffix:@"\""] || line.length <= prefix.length) return nil;
    NSString *value = [line substringWithRange:NSMakeRange(prefix.length, line.length - prefix.length - 1)];
    return [self decodedRegistryValue:value];
}

- (NSURL *)fileURLForWindowsPath:(NSString *)windowsPath prefixURL:(NSURL *)prefixURL {
    NSString *path = [windowsPath stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([path hasPrefix:@"\""] && [path hasSuffix:@"\""] && path.length > 1) {
        path = [path substringWithRange:NSMakeRange(1, path.length - 2)];
    }
    NSRange comma = [path rangeOfString:@"," options:NSBackwardsSearch];
    if (comma.location != NSNotFound) {
        NSString *suffix = [path substringFromIndex:comma.location + 1];
        if ([[suffix stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
             rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound) {
            path = [path substringToIndex:comma.location];
        }
    }
    if (path.length >= 3 && [[path substringToIndex:3].lowercaseString isEqualToString:@"c:\\"]) {
        NSString *relative = [[path substringFromIndex:3] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        return [[prefixURL URLByAppendingPathComponent:@"drive_c" isDirectory:YES]
            URLByAppendingPathComponent:relative];
    }
    return nil;
}

- (NSArray<NSDictionary *> *)registryApplicationsForPrefixURL:(NSURL *)prefixURL {
    NSMutableArray<NSDictionary *> *applications = [NSMutableArray array];
    for (NSString *registryName in @[@"system.reg", @"user.reg"]) {
        NSURL *registryURL = [prefixURL URLByAppendingPathComponent:registryName];
        NSString *contents = [NSString stringWithContentsOfURL:registryURL encoding:NSUTF8StringEncoding error:nil];
        if (!contents.length) continue;
        BOOL uninstallSection = NO;
        NSString *displayName = nil;
        NSString *displayIcon = nil;
        for (NSString *line in [contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if ([line hasPrefix:@"["]) {
                if (uninstallSection && displayName.length) {
                    [applications addObject:@{@"name": displayName, @"icon": displayIcon ?: @""}];
                }
                uninstallSection = [line.lowercaseString containsString:@"\\\\uninstall\\\\"];
                displayName = nil;
                displayIcon = nil;
                continue;
            }
            if (!uninstallSection) continue;
            NSString *nameValue = [self registryValueForLine:line name:@"DisplayName"];
            NSString *iconValue = [self registryValueForLine:line name:@"DisplayIcon"];
            if (nameValue) displayName = nameValue;
            if (iconValue) displayIcon = iconValue;
        }
        if (uninstallSection && displayName.length) {
            [applications addObject:@{@"name": displayName, @"icon": displayIcon ?: @""}];
        }
    }
    return applications;
}

- (BOOL)isUsefulApplicationName:(NSString *)name {
    NSString *lower = name.lowercaseString;
    for (NSString *word in @[@"uninstall", @"readme", @"website", @"help", @"manual",
                             @"redistributable", @"runtime", @"webview", @"driver", @"update",
                             @"component", @"support package"]) {
        if ([lower containsString:word]) return NO;
    }
    return name.length > 0;
}

- (BOOL)isUsefulExecutablePath:(NSString *)path {
    NSString *name = path.lastPathComponent.lowercaseString;
    if (![name.pathExtension isEqualToString:@"exe"]) return NO;
    for (NSString *word in @[@"unins", @"uninstall", @"setup", @"update", @"crash", @"helper", @"service"] ) {
        if ([name containsString:word]) return NO;
    }
    return YES;
}

- (NSURL *)artworkURLNearExecutable:(NSURL *)executableURL displayName:(NSString *)displayName {
    if (!executableURL) return nil;
    NSURL *directory = executableURL.URLByDeletingLastPathComponent;
    NSString *compactName = [[displayName lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSArray<NSString *> *candidates = @[
        @"dist/icon.png", @"icon.png", @"favicon.ico",
        [NSString stringWithFormat:@"%@.ico", compactName],
        [NSString stringWithFormat:@"public/%@_tray.ico", compactName],
        [NSString stringWithFormat:@"public/%@.ico", compactName]
    ];
    for (NSString *relativePath in candidates) {
        NSURL *candidate = [directory URLByAppendingPathComponent:relativePath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate.path]) return candidate;
    }
    return nil;
}

- (NSArray<NSDictionary *> *)installedApplications {
    NSFileManager *files = [NSFileManager defaultManager];
    NSArray<NSURL *> *prefixes = [files contentsOfDirectoryAtURL:self.prefixRootURL
                                      includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                           error:nil] ?: @[];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *found = [NSMutableDictionary dictionary];
    for (NSURL *prefixURL in prefixes) {
        NSNumber *isDirectory = nil;
        [prefixURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (!isDirectory.boolValue || ![files fileExistsAtPath:[prefixURL URLByAppendingPathComponent:@"drive_c"].path]) continue;
        NSString *prefixName = prefixURL.lastPathComponent;
        NSMutableArray<NSURL *> *menuRoots = [NSMutableArray arrayWithObject:
            [prefixURL URLByAppendingPathComponent:@"drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs" isDirectory:YES]];
        NSURL *usersURL = [prefixURL URLByAppendingPathComponent:@"drive_c/users" isDirectory:YES];
        for (NSURL *userURL in [files contentsOfDirectoryAtURL:usersURL
                                    includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                         error:nil] ?: @[]) {
            [menuRoots addObject:[userURL URLByAppendingPathComponent:@"AppData/Roaming/Microsoft/Windows/Start Menu/Programs"
                                                          isDirectory:YES]];
        }
        for (NSURL *menuRoot in menuRoots) {
            NSDirectoryEnumerator<NSURL *> *enumerator = [files enumeratorAtURL:menuRoot
                                                     includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                   errorHandler:nil];
            for (NSURL *shortcutURL in enumerator) {
                NSString *extension = shortcutURL.pathExtension.lowercaseString;
                if (![@[@"lnk", @"url"] containsObject:extension]) continue;
                NSString *name = shortcutURL.lastPathComponent.stringByDeletingPathExtension;
                if (![self isUsefulApplicationName:name]) continue;
                NSString *kind = @"shortcut";
                NSString *launch = shortcutURL.path;
                if ([extension isEqualToString:@"url"]) {
                    NSString *target = [self urlTargetAtURL:shortcutURL];
                    if (!target.length) continue;
                    NSString *lowerTarget = target.lowercaseString;
                    if ([lowerTarget hasPrefix:@"http://"] || [lowerTarget hasPrefix:@"https://"]) continue;
                    kind = @"uri";
                    launch = target;
                }
                NSString *key = [NSString stringWithFormat:@"%@|%@", prefixName.lowercaseString, name.lowercaseString];
                if (!found[key] || [kind isEqualToString:@"uri"]) {
                    found[key] = [@{@"name": name, @"prefix": prefixName, @"kind": kind,
                                    @"launch": launch, @"location": shortcutURL.path} mutableCopy];
                }
            }
        }
        for (NSDictionary *registryApplication in [self registryApplicationsForPrefixURL:prefixURL]) {
            NSString *name = registryApplication[@"name"];
            if (![self isUsefulApplicationName:name]) continue;
            NSURL *iconURL = [self fileURLForWindowsPath:registryApplication[@"icon"] prefixURL:prefixURL];
            NSURL *artworkURL = [self artworkURLNearExecutable:iconURL displayName:name];
            NSString *key = [NSString stringWithFormat:@"%@|%@", prefixName.lowercaseString, name.lowercaseString];
            NSMutableDictionary *existing = found[key];
            BOOL usableIcon = iconURL && [files fileExistsAtPath:iconURL.path] && [self isUsefulExecutablePath:iconURL.path];
            if (existing) {
                if (artworkURL) existing[@"iconPath"] = artworkURL.path;
                else if (usableIcon) existing[@"iconPath"] = iconURL.path;
                if (usableIcon && [existing[@"kind"] isEqualToString:@"shortcut"]) {
                    existing[@"kind"] = @"file";
                    existing[@"launch"] = iconURL.path;
                }
            } else if (usableIcon) {
                found[key] = [@{@"name": name, @"prefix": prefixName, @"kind": @"file",
                                @"launch": iconURL.path, @"location": iconURL.path,
                                @"iconPath": iconURL.path} mutableCopy];
            }
        }
    }
    return [found.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
}

- (void)prepareEnvironment:(WinovaCompletion)completion {
    NSString *engine = self.enginePath;
    if (!engine) {
        completion(WinovaError(@"Choose a Wine engine first."));
        return;
    }
    dispatch_async(_queue, ^{
        [self writeLog:@"Preparing the default Windows environment…"];
        NSTask *task = [self taskWithEngine:engine
                                  arguments:@[@"wineboot", @"-u"]
                           workingDirectory:nil
                                 prefixName:@"default"];
        NSError *error = nil;
        [task launchAndReturnError:&error];
        [task waitUntilExit];
        if (!error && task.terminationStatus != 0) {
            error = WinovaError([NSString stringWithFormat:@"Engine exited with status %d.", task.terminationStatus]);
        }
        if (!error) [self writeLog:@"Environment is ready."];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)launchProgram:(NSURL *)program completion:(WinovaCompletion)completion {
    NSString *engine = self.enginePath;
    if (!engine) {
        completion(WinovaError(@"Choose a Wine engine first."));
        return;
    }
    BOOL installer = [program.pathExtension.lowercaseString isEqualToString:@"msi"];
    NSArray *arguments = installer ? @[@"msiexec", @"/i", program.path] : @[@"start", @"/unix", program.path];
    NSString *prefixName = [self prefixNameContainingPath:program.path];
    dispatch_async(_queue, ^{
        NSTask *task = [self taskWithEngine:engine
                                  arguments:arguments
                           workingDirectory:program.URLByDeletingLastPathComponent
                                 prefixName:prefixName];
        [self writeLog:[NSString stringWithFormat:@"Launching %@", program.lastPathComponent]];
        NSError *error = nil;
        [task launchAndReturnError:&error];
        if (!error) {
            self->_tasks[@(task.processIdentifier)] = task;
            __weak typeof(self) weakSelf = self;
            task.terminationHandler = ^(NSTask *finished) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                dispatch_async(strongSelf->_queue, ^{
                    [strongSelf->_tasks removeObjectForKey:@(finished.processIdentifier)];
                    [strongSelf writeLog:[NSString stringWithFormat:@"%@ exited with status %d.",
                        program.lastPathComponent, finished.terminationStatus]];
                });
            };
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)launchInstalledApplication:(NSDictionary *)application completion:(WinovaCompletion)completion {
    NSString *engine = self.enginePath;
    if (!engine) {
        completion(WinovaError(@"Choose a Wine engine first."));
        return;
    }
    NSString *launch = application[@"launch"];
    NSString *prefixName = application[@"prefix"] ?: @"default";
    NSString *kind = application[@"kind"] ?: @"file";
    if (!launch.length) {
        completion(WinovaError(@"This application does not have a valid launch target."));
        return;
    }
    NSArray<NSString *> *arguments = [kind isEqualToString:@"uri"]
        ? @[@"start", launch]
        : @[@"start", @"/unix", launch];
    NSURL *workingDirectory = [kind isEqualToString:@"uri"]
        ? [self prefixURLForName:prefixName]
        : [NSURL fileURLWithPath:launch].URLByDeletingLastPathComponent;
    dispatch_async(_queue, ^{
        NSTask *task = [self taskWithEngine:engine
                                  arguments:arguments
                           workingDirectory:workingDirectory
                                 prefixName:prefixName];
        NSString *lowerName = [application[@"name"] lowercaseString];
        NSString *lowerLaunch = launch.lowercaseString;
        if ([lowerName isEqualToString:@"stove"] || [lowerLaunch hasPrefix:@"sgup:"]) {
            NSMutableDictionary *environment = [task.environment mutableCopy];
            environment[@"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"] = @"--disable-gpu --disable-gpu-compositing";
            task.environment = environment;
        }
        [self writeLog:[NSString stringWithFormat:@"Launching %@ in %@", application[@"name"], prefixName]];
        NSError *error = nil;
        [task launchAndReturnError:&error];
        if (!error) {
            self->_tasks[@(task.processIdentifier)] = task;
            __weak typeof(self) weakSelf = self;
            task.terminationHandler = ^(NSTask *finished) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                dispatch_async(strongSelf->_queue, ^{
                    [strongSelf->_tasks removeObjectForKey:@(finished.processIdentifier)];
                });
            };
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)openConfiguration:(WinovaCompletion)completion {
    NSString *engine = self.enginePath;
    if (!engine) {
        completion(WinovaError(@"Choose a Wine engine first."));
        return;
    }
    dispatch_async(_queue, ^{
        NSTask *task = [self taskWithEngine:engine
                                  arguments:@[@"winecfg"]
                           workingDirectory:nil
                                 prefixName:@"default"];
        NSError *error = nil;
        [task launchAndReturnError:&error];
        if (!error) self->_tasks[@(task.processIdentifier)] = task;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)writeLog:(NSString *)line {
    if (!line.length || !self.logHandler) return;
    dispatch_async(dispatch_get_main_queue(), ^{ self.logHandler(line); });
}

@end

@interface WinovaDropView : NSView
@property(nonatomic, copy) void (^fileHandler)(NSURL *url);
@end

@implementation WinovaDropView {
    NSTextField *_titleLabel;
    NSTextField *_detailLabel;
    BOOL _highlighted;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 16;
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        _titleLabel = [NSTextField labelWithString:@"Drop a Windows app here"];
        _titleLabel.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
        _detailLabel = [NSTextField labelWithString:@".exe and .msi files are supported"];
        _detailLabel.font = [NSFont systemFontOfSize:12];
        _detailLabel.textColor = NSColor.secondaryLabelColor;
        NSStackView *stack = [NSStackView stackViewWithViews:@[_titleLabel, _detailLabel]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeCenterX;
        stack.spacing = 6;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
        [self updateAppearance];
    }
    return self;
}

- (NSURL *)supportedURL:(id<NSDraggingInfo>)sender {
    NSDictionary *options = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:options];
    for (NSURL *url in urls) {
        if ([@[@"exe", @"msi"] containsObject:url.pathExtension.lowercaseString]) return url;
    }
    return nil;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    _highlighted = [self supportedURL:sender] != nil;
    [self updateAppearance];
    return _highlighted ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    _highlighted = NO;
    [self updateAppearance];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSURL *url = [self supportedURL:sender];
    _highlighted = NO;
    [self updateAppearance];
    if (url && self.fileHandler) self.fileHandler(url);
    return url != nil;
}

- (void)updateAppearance {
    self.layer.backgroundColor = (_highlighted
        ? [NSColor.controlAccentColor colorWithAlphaComponent:0.16]
        : [NSColor.controlBackgroundColor colorWithAlphaComponent:0.7]).CGColor;
    self.layer.borderColor = (_highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).CGColor;
    self.layer.borderWidth = _highlighted ? 2 : 1;
}

@end

@interface WinovaAppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation WinovaAppDelegate {
    NSWindow *_window;
    WinovaRuntime *_runtime;
    NSArray<NSDictionary *> *_installedApps;
    NSTableView *_tableView;
    NSTextField *_emptyLabel;
    NSTextView *_logView;
    NSTextField *_engineStatus;
    NSView *_engineDot;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    _runtime = [WinovaRuntime new];
    _installedApps = @[];
    [self configureMenu];
    [self buildWindow];
    [self connectRuntime];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [_runtime reportEngineStatus];
    [self refreshInstalledApps:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (_runtime && _tableView) [self refreshInstalledApps:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)configureMenu {
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [main addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"About Winova" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"Quit Winova" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSMenuItem *fileItem = [NSMenuItem new];
    [main addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *open = [fileMenu addItemWithTitle:@"Run Program…" action:@selector(chooseProgram:) keyEquivalent:@"o"];
    open.target = self;
    fileItem.submenu = fileMenu;
    NSApp.mainMenu = main;
}

- (void)buildWindow {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1080, 720)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                                    NSWindowStyleMaskFullSizeContentView
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Winova";
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;
    _window.minSize = NSMakeSize(900, 620);
    [_window center];

    NSVisualEffectView *root = [NSVisualEffectView new];
    root.material = NSVisualEffectMaterialSidebar;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    root.state = NSVisualEffectStateActive;
    _window.contentView = root;

    NSView *sidebar = [self buildSidebar];
    NSView *content = [self buildContent];
    [root addSubview:sidebar];
    [root addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [sidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [sidebar.widthAnchor constraintEqualToConstant:250],
        [content.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:root.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]
    ]];
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeLarge;
    return button;
}

- (NSView *)buildSidebar {
    NSVisualEffectView *sidebar = [NSVisualEffectView new];
    sidebar.material = NSVisualEffectMaterialSidebar;
    sidebar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    sidebar.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *mark = [NSTextField labelWithString:@"W"];
    mark.font = [NSFont systemFontOfSize:22 weight:NSFontWeightBold];
    mark.alignment = NSTextAlignmentCenter;
    mark.textColor = NSColor.whiteColor;
    mark.wantsLayer = YES;
    mark.layer.backgroundColor = NSColor.controlAccentColor.CGColor;
    mark.layer.cornerRadius = 11;
    [mark.widthAnchor constraintEqualToConstant:44].active = YES;
    [mark.heightAnchor constraintEqualToConstant:44].active = YES;

    NSTextField *name = [NSTextField labelWithString:@"Winova"];
    name.font = [NSFont systemFontOfSize:24 weight:NSFontWeightBold];
    NSTextField *tagline = [NSTextField wrappingLabelWithString:@"Windows apps, at home on your Mac."];
    tagline.font = [NSFont systemFontOfSize:12];
    tagline.textColor = NSColor.secondaryLabelColor;

    _engineDot = [NSView new];
    _engineDot.wantsLayer = YES;
    _engineDot.layer.cornerRadius = 4;
    [_engineDot.widthAnchor constraintEqualToConstant:8].active = YES;
    [_engineDot.heightAnchor constraintEqualToConstant:8].active = YES;
    _engineStatus = [NSTextField labelWithString:@"Checking engine…"];
    _engineStatus.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _engineStatus.textColor = NSColor.secondaryLabelColor;
    _engineStatus.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSStackView *status = [NSStackView stackViewWithViews:@[_engineDot, _engineStatus]];
    status.spacing = 8;

    NSButton *choose = [self button:@"Choose Engine…" action:@selector(chooseEngine:)];
    NSButton *prepare = [self button:@"Prepare Environment" action:@selector(prepareEnvironment:)];
    NSButton *configure = [self button:@"Windows Settings" action:@selector(openConfiguration:)];
    NSButton *openFolder = [self button:@"Open Environment" action:@selector(openEnvironment:)];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    NSTextField *footer = [NSTextField wrappingLabelWithString:@"Private by default\nNo telemetry · No account"];
    footer.font = [NSFont systemFontOfSize:10];
    footer.textColor = NSColor.tertiaryLabelColor;

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        mark, name, tagline, status, choose, prepare, configure, openFolder, spacer, footer
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    [stack setCustomSpacing:22 afterView:tagline];
    [stack setCustomSpacing:22 afterView:status];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebar addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:52],
        [stack.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor constant:-24],
        [choose.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [prepare.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [configure.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [openFolder.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    return sidebar;
}

- (NSView *)buildContent {
    NSView *content = [NSView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *heading = [NSTextField labelWithString:@"Library"];
    heading.font = [NSFont systemFontOfSize:28 weight:NSFontWeightBold];
    NSTextField *subtitle = [NSTextField labelWithString:@"Launch and manage your Windows applications"];
    subtitle.textColor = NSColor.secondaryLabelColor;
    NSStackView *titles = [NSStackView stackViewWithViews:@[heading, subtitle]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 4;
    NSView *headerSpacer = [NSView new];
    [headerSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *run = [self button:@"Run Program" action:@selector(chooseProgram:)];
    run.keyEquivalent = @"\r";
    NSButton *install = [self button:@"Install Package" action:@selector(chooseInstaller:)];
    NSButton *refresh = [self button:@"Refresh Apps" action:@selector(refreshInstalledApps:)];
    NSStackView *actions = [NSStackView stackViewWithViews:@[refresh, run, install]];
    actions.spacing = 10;
    NSStackView *header = [NSStackView stackViewWithViews:@[titles, headerSpacer, actions]];
    header.alignment = NSLayoutAttributeCenterY;

    WinovaDropView *drop = [WinovaDropView new];
    [drop.heightAnchor constraintEqualToConstant:120].active = YES;
    __weak typeof(self) weakSelf = self;
    drop.fileHandler = ^(NSURL *url) { [weakSelf launchURL:url]; };

    NSTextField *installedTitle = [NSTextField labelWithString:@"Installed Apps"];
    installedTitle.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    [self configureTable];
    NSScrollView *tableScroll = [NSScrollView new];
    tableScroll.documentView = _tableView;
    tableScroll.hasVerticalScroller = YES;
    tableScroll.drawsBackground = NO;
    [tableScroll.heightAnchor constraintGreaterThanOrEqualToConstant:145].active = YES;
    _emptyLabel = [NSTextField labelWithString:@"No installed apps found. Install a package, then refresh."];
    _emptyLabel.textColor = NSColor.tertiaryLabelColor;
    _emptyLabel.alignment = NSTextAlignmentCenter;

    NSTextField *activity = [NSTextField labelWithString:@"Activity"];
    activity.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _logView = [NSTextView new];
    _logView.editable = NO;
    _logView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _logView.textColor = NSColor.secondaryLabelColor;
    _logView.backgroundColor = NSColor.clearColor;
    NSScrollView *logScroll = [NSScrollView new];
    logScroll.documentView = _logView;
    logScroll.hasVerticalScroller = YES;
    logScroll.wantsLayer = YES;
    logScroll.layer.backgroundColor = [NSColor.controlBackgroundColor colorWithAlphaComponent:0.55].CGColor;
    logScroll.layer.cornerRadius = 10;
    [logScroll.heightAnchor constraintEqualToConstant:105].active = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        header, drop, installedTitle, tableScroll, _emptyLabel, activity, logScroll
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    [stack setCustomSpacing:24 afterView:header];
    [stack setCustomSpacing:22 afterView:drop];
    [stack setCustomSpacing:18 afterView:_emptyLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-32],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:58],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24],
        [header.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [drop.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [installedTitle.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [tableScroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_emptyLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [activity.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [logScroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    [self updateEmptyState];
    return content;
}

- (void)configureTable {
    _tableView = [NSTableView new];
    NSArray *columns = @[
        @[@"name", @"Application", @300], @[@"prefix", @"Environment", @120], @[@"location", @"Location", @300]
    ];
    for (NSArray *definition in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:definition[0]];
        column.title = definition[1];
        column.width = [definition[2] doubleValue];
        [_tableView addTableColumn:column];
    }
    _tableView.headerView = nil;
    _tableView.rowHeight = 52;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.target = self;
    _tableView.doubleAction = @selector(runSelectedApplication:);
    _tableView.backgroundColor = NSColor.clearColor;
}

- (void)connectRuntime {
    __weak typeof(self) weakSelf = self;
    _runtime.logHandler = ^(NSString *line) { [weakSelf appendLog:line]; };
    _runtime.statusHandler = ^(NSString *text, BOOL ready) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_engineStatus.stringValue = text;
        strongSelf->_engineDot.layer.backgroundColor = (ready ? NSColor.systemGreenColor : NSColor.systemOrangeColor).CGColor;
    };
    [self appendLog:@"Winova is ready."];
}

- (void)chooseProgram:(id)sender { [self presentOpenPanel:@[@"exe", @"msi"]]; }
- (void)chooseInstaller:(id)sender { [self presentOpenPanel:@[@"msi", @"exe"]]; }

- (void)presentOpenPanel:(NSArray<NSString *> *)extensions {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Choose a Windows application";
    panel.prompt = @"Open";
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray array];
    for (NSString *extension in extensions) {
        UTType *contentType = [UTType typeWithFilenameExtension:extension];
        if (contentType) [contentTypes addObject:contentType];
    }
    panel.allowedContentTypes = contentTypes;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK && panel.URL) [self launchURL:panel.URL];
    }];
}

- (void)chooseEngine:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Choose the Wine executable";
    panel.message = @"Select the executable named wine from an open-source engine installation.";
    panel.prompt = @"Choose Engine";
    panel.canChooseDirectories = NO;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:panel.URL.path]) {
            [self showError:@"The selected file is not executable."];
            return;
        }
        [self->_runtime selectEngine:panel.URL.path];
        [self appendLog:[NSString stringWithFormat:@"Selected engine: %@", panel.URL.path]];
    }];
}

- (void)prepareEnvironment:(id)sender {
    [_runtime prepareEnvironment:^(NSError *error) { if (error) [self showError:error.localizedDescription]; }];
}

- (void)openConfiguration:(id)sender {
    [_runtime openConfiguration:^(NSError *error) { if (error) [self showError:error.localizedDescription]; }];
}

- (void)openEnvironment:(id)sender {
    [[NSFileManager defaultManager] createDirectoryAtURL:_runtime.prefixURL
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[_runtime.prefixURL]];
}

- (void)refreshInstalledApps:(id)sender {
    if (sender) [self appendLog:@"Scanning installed applications…"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSArray<NSDictionary *> *applications = [strongSelf->_runtime installedApplications];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) mainSelf = weakSelf;
            if (!mainSelf) return;
            mainSelf->_installedApps = applications;
            [mainSelf->_tableView reloadData];
            [mainSelf updateEmptyState];
            if (sender) {
                [mainSelf appendLog:[NSString stringWithFormat:@"Found %lu installed application%@.",
                    (unsigned long)applications.count, applications.count == 1 ? @"" : @"s"]];
            }
        });
    });
}

- (void)runInstalledButton:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)_installedApps.count) return;
    [self launchInstalledApplication:_installedApps[sender.tag]];
}

- (void)runSelectedApplication:(id)sender {
    NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_installedApps.count) return;
    [self launchInstalledApplication:_installedApps[row]];
}

- (void)launchInstalledApplication:(NSDictionary *)application {
    if (!_runtime.enginePath) {
        [self showError:@"Choose a Wine engine first."];
        return;
    }
    [_runtime launchInstalledApplication:application completion:^(NSError *error) {
        if (error) [self showError:error.localizedDescription];
    }];
}

- (BOOL)isSupported:(NSURL *)url {
    return [@[@"exe", @"msi"] containsObject:url.pathExtension.lowercaseString];
}

- (void)launchURL:(NSURL *)url {
    if (![self isSupported:url]) {
        [self showError:@"Winova supports .exe and .msi files."];
        return;
    }
    if (!_runtime.enginePath) {
        [self showError:@"Choose a Wine engine first."];
        return;
    }
    [_runtime launchProgram:url completion:^(NSError *error) {
        if (error) [self showError:error.localizedDescription];
        else [self appendLog:[NSString stringWithFormat:@"Started %@.", url.lastPathComponent]];
    }];
}

- (void)updateEmptyState {
    _emptyLabel.hidden = _installedApps.count > 0;
    _tableView.hidden = _installedApps.count == 0;
}

- (void)appendLog:(NSString *)line {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:NSDate.date], line];
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    };
    [_logView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:entry attributes:attributes]];
    [_logView scrollToEndOfDocument:nil];
}

- (void)showError:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Winova";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:_window completionHandler:nil];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return _installedApps.count; }

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    NSDictionary *item = _installedApps[row];
    NSTableCellView *cell = [NSTableCellView new];
    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:@"name"]) {
        NSButton *button = [NSButton buttonWithTitle:item[@"name"] target:self action:@selector(runInstalledButton:)];
        button.tag = row;
        button.bordered = NO;
        button.alignment = NSTextAlignmentLeft;
        button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        button.imagePosition = NSImageLeft;
        button.imageHugsTitle = YES;
        button.imageScaling = NSImageScaleProportionallyUpOrDown;
        NSString *iconPath = item[@"iconPath"] ?: item[@"location"];
        NSString *iconExtension = iconPath.pathExtension.lowercaseString;
        NSImage *icon = [@[@"png", @"ico", @"icns", @"jpg", @"jpeg"] containsObject:iconExtension]
            ? [[NSImage alloc] initWithContentsOfFile:iconPath]
            : (iconPath.length ? [[NSWorkspace sharedWorkspace] iconForFile:iconPath] : nil);
        if (!icon || icon.size.width <= 0) {
            icon = [NSImage imageWithSystemSymbolName:@"app.fill" accessibilityDescription:@"Application"];
        }
        icon.size = NSMakeSize(32, 32);
        button.image = icon;
        button.toolTip = [NSString stringWithFormat:@"Launch %@", item[@"name"]];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
            [button.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
            [button.topAnchor constraintEqualToAnchor:cell.topAnchor constant:4],
            [button.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-4]
        ]];
        return cell;
    }
    NSTextField *label = [NSTextField labelWithString:@""];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:label];
    cell.textField = label;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
    ]];
    if ([identifier isEqualToString:@"prefix"]) {
        label.stringValue = item[@"prefix"] ?: @"default";
        label.textColor = NSColor.secondaryLabelColor;
        label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    } else {
        label.stringValue = item[@"location"] ?: item[@"launch"] ?: @"";
        label.textColor = NSColor.secondaryLabelColor;
        label.font = [NSFont systemFontOfSize:11];
    }
    return cell;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && [[[NSString alloc] initWithUTF8String:argv[1]] isEqualToString:@"--list-apps"]) {
            WinovaRuntime *runtime = [WinovaRuntime new];
            for (NSDictionary *application in runtime.installedApplications) {
                printf("%s\t%s\t%s\n",
                    [application[@"name"] UTF8String],
                    [application[@"prefix"] UTF8String],
                    [application[@"kind"] UTF8String]);
            }
            return 0;
        }
        NSApplication *application = [NSApplication sharedApplication];
        WinovaAppDelegate *delegate = [WinovaAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
