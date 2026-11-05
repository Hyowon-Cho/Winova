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
@property(nonatomic, copy) WinovaLogHandler logHandler;
@property(nonatomic, copy) WinovaStatusHandler statusHandler;
- (NSString *)enginePath;
- (void)selectEngine:(NSString *)path;
- (void)reportEngineStatus;
- (void)prepareEnvironment:(WinovaCompletion)completion;
- (void)launchProgram:(NSURL *)program completion:(WinovaCompletion)completion;
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
        _prefixURL = [[[[base URLByAppendingPathComponent:@"Winova" isDirectory:YES]
            URLByAppendingPathComponent:@"Prefixes" isDirectory:YES]
            URLByAppendingPathComponent:@"default" isDirectory:YES] copy];
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
        @"/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine",
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

- (NSMutableDictionary *)runtimeEnvironment:(NSString *)engine {
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"WINEPREFIX"] = self.prefixURL.path;
    environment[@"WINEDEBUG"] = @"-all";
    NSString *engineDirectory = [engine stringByDeletingLastPathComponent];
    NSString *oldPath = environment[@"PATH"] ?: @"";
    environment[@"PATH"] = [@[engineDirectory, @"/opt/homebrew/bin", @"/usr/local/bin", oldPath]
        componentsJoinedByString:@":"];
    return environment;
}

- (NSTask *)taskWithEngine:(NSString *)engine
                  arguments:(NSArray<NSString *> *)arguments
           workingDirectory:(NSURL *)directory {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:engine];
    task.arguments = arguments;
    task.currentDirectoryURL = directory;
    task.environment = [self runtimeEnvironment:engine];
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

- (void)prepareEnvironment:(WinovaCompletion)completion {
    NSString *engine = self.enginePath;
    if (!engine) {
        completion(WinovaError(@"Choose a Wine engine first."));
        return;
    }
    dispatch_async(_queue, ^{
        [self writeLog:@"Preparing the default Windows environment…"];
        NSTask *task = [self taskWithEngine:engine arguments:@[@"wineboot", @"-u"] workingDirectory:nil];
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
    NSArray *arguments = installer ? @[@"msiexec", @"/i", program.path] : @[program.path];
    dispatch_async(_queue, ^{
        NSTask *task = [self taskWithEngine:engine
                                  arguments:arguments
                           workingDirectory:program.URLByDeletingLastPathComponent];
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

- (void)openConfiguration:(WinovaCompletion)completion {
    NSString *engine = self.enginePath;
    if (!engine) {
        completion(WinovaError(@"Choose a Wine engine first."));
        return;
    }
    dispatch_async(_queue, ^{
        NSTask *task = [self taskWithEngine:engine arguments:@[@"winecfg"] workingDirectory:nil];
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
    NSMutableArray<NSMutableDictionary *> *_recent;
    NSTableView *_tableView;
    NSTextField *_emptyLabel;
    NSTextView *_logView;
    NSTextField *_engineStatus;
    NSView *_engineDot;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    _runtime = [WinovaRuntime new];
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"recentPrograms"] ?: @[];
    _recent = [[saved filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, id bindings) {
        return [[NSFileManager defaultManager] fileExistsAtPath:item[@"path"] ?: @""];
    }]] mutableCopy];
    [self configureMenu];
    [self buildWindow];
    [self connectRuntime];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [_runtime reportEngineStatus];
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
    NSStackView *actions = [NSStackView stackViewWithViews:@[run, install]];
    actions.spacing = 10;
    NSStackView *header = [NSStackView stackViewWithViews:@[titles, headerSpacer, actions]];
    header.alignment = NSLayoutAttributeCenterY;

    WinovaDropView *drop = [WinovaDropView new];
    [drop.heightAnchor constraintEqualToConstant:120].active = YES;
    __weak typeof(self) weakSelf = self;
    drop.fileHandler = ^(NSURL *url) { [weakSelf launchURL:url]; };

    NSTextField *recentTitle = [NSTextField labelWithString:@"Recent"];
    recentTitle.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    [self configureTable];
    NSScrollView *tableScroll = [NSScrollView new];
    tableScroll.documentView = _tableView;
    tableScroll.hasVerticalScroller = YES;
    tableScroll.drawsBackground = NO;
    [tableScroll.heightAnchor constraintGreaterThanOrEqualToConstant:145].active = YES;
    _emptyLabel = [NSTextField labelWithString:@"Your recently launched apps will appear here."];
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
        header, drop, recentTitle, tableScroll, _emptyLabel, activity, logScroll
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
        [recentTitle.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
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
        @[@"name", @"Application", @280], @[@"path", @"Location", @390], @[@"type", @"Type", @60]
    ];
    for (NSArray *definition in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:definition[0]];
        column.title = definition[1];
        column.width = [definition[2] doubleValue];
        [_tableView addTableColumn:column];
    }
    _tableView.headerView = nil;
    _tableView.rowHeight = 38;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.target = self;
    _tableView.doubleAction = @selector(runSelectedRecent:);
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

- (void)runSelectedRecent:(id)sender {
    NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_recent.count) return;
    NSURL *url = [NSURL fileURLWithPath:_recent[row][@"path"]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        [_recent removeObjectAtIndex:row];
        [self saveRecent];
        [self showError:@"This file no longer exists."];
        return;
    }
    [self launchURL:url];
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
        else [self addRecent:url];
    }];
}

- (void)addRecent:(NSURL *)url {
    NSIndexSet *matches = [_recent indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        return [item[@"path"] isEqualToString:url.path];
    }];
    if (matches.count) [_recent removeObjectsAtIndexes:matches];
    [_recent insertObject:[@{@"path": url.path, @"lastOpened": @([NSDate date].timeIntervalSince1970)} mutableCopy]
                   atIndex:0];
    if (_recent.count > 20) [_recent removeObjectsInRange:NSMakeRange(20, _recent.count - 20)];
    [self saveRecent];
}

- (void)saveRecent {
    [[NSUserDefaults standardUserDefaults] setObject:_recent forKey:@"recentPrograms"];
    [_tableView reloadData];
    [self updateEmptyState];
}

- (void)updateEmptyState {
    _emptyLabel.hidden = _recent.count > 0;
    _tableView.hidden = _recent.count == 0;
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

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return _recent.count; }

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    NSDictionary *item = _recent[row];
    NSTableCellView *cell = [NSTableCellView new];
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
    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:@"name"]) {
        label.stringValue = [[item[@"path"] lastPathComponent] stringByDeletingPathExtension];
        label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    } else if ([identifier isEqualToString:@"path"]) {
        label.stringValue = item[@"path"];
        label.textColor = NSColor.secondaryLabelColor;
        label.font = [NSFont systemFontOfSize:11];
    } else {
        label.stringValue = [item[@"path"] pathExtension].uppercaseString;
        label.textColor = NSColor.tertiaryLabelColor;
        label.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium];
    }
    return cell;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        WinovaAppDelegate *delegate = [WinovaAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
