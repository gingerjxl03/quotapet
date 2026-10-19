#import <Cocoa/Cocoa.h>

@interface QPUsageSnapshot : NSObject
@property NSInteger primaryRemaining;
@property NSInteger secondaryRemaining;
@property NSTimeInterval primaryReset;
@property NSTimeInterval secondaryReset;
@property NSInteger resetCredits;
@property(copy) NSString *plan;
@end

@implementation QPUsageSnapshot
@end

typedef void (^QPSnapshotHandler)(QPUsageSnapshot *snapshot);
typedef void (^QPErrorHandler)(NSString *message);

@interface QPCodexUsageClient : NSObject
@property(copy) QPSnapshotHandler onSnapshot;
@property(copy) QPErrorHandler onError;
@property(strong) NSTask *task;
@property(strong) NSFileHandle *inputHandle;
@property(strong) NSMutableData *buffer;
@property NSInteger nextRequestID;
@property BOOL initialized;
@property dispatch_queue_t queue;
- (void)start;
- (void)refresh;
- (void)stop;
@end

@implementation QPCodexUsageClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _buffer = [NSMutableData data];
        _nextRequestID = 2;
        _queue = dispatch_queue_create("QuotaPet.CodexUsageClient", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)start {
    dispatch_async(self.queue, ^{ [self startLocked]; });
}

- (void)refresh {
    dispatch_async(self.queue, ^{
        if (!self.initialized || !self.task.running) {
            [self stopLocked];
            [self startLocked];
            return;
        }
        [self requestUsageLocked];
    });
}

- (void)stop {
    dispatch_sync(self.queue, ^{ [self stopLocked]; });
}

- (NSString *)codexExecutable {
    NSArray<NSString *> *candidates = @[
        @"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        @"/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        @"/usr/local/bin/codex",
        @"/opt/homebrew/bin/codex"
    ];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

- (void)startLocked {
    if (self.task.running) return;
    NSString *executable = [self codexExecutable];
    if (!executable) {
        [self reportError:@"未找到 ChatGPT 内置的 Codex 程序"];
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    NSPipe *input = [NSPipe pipe];
    NSPipe *output = [NSPipe pipe];
    NSPipe *errors = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[@"app-server"];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = errors;

    __weak typeof(self) weakSelf = self;
    output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;
        dispatch_async(weakSelf.queue, ^{ [weakSelf consumeLocked:data]; });
    };
    errors.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        (void)handle.availableData;
    };
    task.terminationHandler = ^(NSTask *finishedTask) {
        if (finishedTask.terminationStatus != 0) {
            [weakSelf reportError:[NSString stringWithFormat:@"Codex 状态服务已停止（%d）", finishedTask.terminationStatus]];
        }
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self reportError:error.localizedDescription ?: @"Codex 状态服务启动失败"];
        return;
    }

    self.task = task;
    self.inputHandle = input.fileHandleForWriting;
    self.initialized = NO;
    [self.buffer setLength:0];
    [self sendLocked:@{
        @"id": @1,
        @"method": @"initialize",
        @"params": @{
            @"clientInfo": @{
                @"name": @"quota-pet",
                @"title": @"额度桌宠",
                @"version": @"0.1.0"
            },
            @"capabilities": @{@"experimentalApi": @YES}
        }
    }];
}

- (void)requestUsageLocked {
    NSNumber *requestID = @(self.nextRequestID++);
    [self sendLocked:@{
        @"id": requestID,
        @"method": @"account/rateLimits/read",
        @"params": @{@"excludeResetCreditDetails": @YES}
    }];
}

- (void)sendLocked:(NSDictionary *)object {
    NSError *error = nil;
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:object options:0 error:&error] mutableCopy];
    if (!data) {
        [self reportError:error.localizedDescription ?: @"无法生成状态请求"];
        return;
    }
    const uint8_t newline = '\n';
    [data appendBytes:&newline length:1];
    @try {
        [self.inputHandle writeData:data];
    } @catch (NSException *exception) {
        [self reportError:exception.reason ?: @"无法连接 Codex 状态服务"];
    }
}

- (void)consumeLocked:(NSData *)data {
    [self.buffer appendData:data];
    while (self.buffer.length > 0) {
        const uint8_t *bytes = self.buffer.bytes;
        NSUInteger newlineIndex = NSNotFound;
        for (NSUInteger i = 0; i < self.buffer.length; i++) {
            if (bytes[i] == '\n') { newlineIndex = i; break; }
        }
        if (newlineIndex == NSNotFound) break;

        NSData *line = [self.buffer subdataWithRange:NSMakeRange(0, newlineIndex)];
        [self.buffer replaceBytesInRange:NSMakeRange(0, newlineIndex + 1) withBytes:NULL length:0];
        if (line.length == 0) continue;

        NSDictionary *object = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if ([object isKindOfClass:NSDictionary.class]) [self handleLocked:object];
    }
}

- (void)handleLocked:(NSDictionary *)object {
    if ([object[@"id"] integerValue] == 1 && object[@"result"]) {
        self.initialized = YES;
        [self sendLocked:@{@"method": @"initialized"}];
        [self requestUsageLocked];
        return;
    }

    NSDictionary *result = object[@"result"];
    if (![result isKindOfClass:NSDictionary.class]) return;
    NSDictionary *limits = result[@"rateLimits"];
    NSDictionary *primary = limits[@"primary"];
    NSDictionary *secondary = limits[@"secondary"];
    if (![limits isKindOfClass:NSDictionary.class] ||
        ![primary isKindOfClass:NSDictionary.class] ||
        ![secondary isKindOfClass:NSDictionary.class]) return;

    QPUsageSnapshot *snapshot = [[QPUsageSnapshot alloc] init];
    snapshot.primaryRemaining = MAX(0, MIN(100, 100 - [primary[@"usedPercent"] integerValue]));
    snapshot.secondaryRemaining = MAX(0, MIN(100, 100 - [secondary[@"usedPercent"] integerValue]));
    snapshot.primaryReset = [primary[@"resetsAt"] doubleValue];
    snapshot.secondaryReset = [secondary[@"resetsAt"] doubleValue];
    snapshot.resetCredits = [result[@"rateLimitResetCredits"][@"availableCount"] integerValue];
    snapshot.plan = limits[@"planType"] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onSnapshot) self.onSnapshot(snapshot);
    });
}

- (void)stopLocked {
    self.task.standardOutput = nil;
    [self.inputHandle closeFile];
    self.inputHandle = nil;
    if (self.task.running) [self.task terminate];
    self.task = nil;
    self.initialized = NO;
}

- (void)reportError:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onError) self.onError(message);
    });
}

@end

@interface QPQuotaBubbleView : NSView
@property(nonatomic, strong) QPUsageSnapshot *snapshot;
@property(nonatomic, copy) NSString *statusText;
@property(copy) dispatch_block_t onDoubleClick;
@property NSPoint dragOrigin;
@property NSPoint windowOrigin;
@end

@implementation QPQuotaBubbleView

- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)setSnapshot:(QPUsageSnapshot *)snapshot {
    _snapshot = snapshot;
    [self setNeedsDisplay:YES];
}

- (void)setStatusText:(NSString *)statusText {
    _statusText = [statusText copy];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect panelRect = NSInsetRect(self.bounds, 1, 1);
    NSBezierPath *panel = [NSBezierPath bezierPathWithRoundedRect:panelRect xRadius:20 yRadius:20];
    [[NSColor colorWithCalibratedWhite:0.10 alpha:0.88] setFill];
    [panel fill];
    [[NSColor colorWithWhite:1 alpha:0.12] setStroke];
    panel.lineWidth = 1;
    [panel stroke];

    if (!self.snapshot) {
        [self drawCentered:self.statusText ?: @"正在连接…" inRect:self.bounds
                      font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                     color:[NSColor colorWithWhite:1 alpha:0.82]];
        return;
    }

    [self drawRingAt:NSMakePoint(43, NSMidY(self.bounds) + 1) radius:25
           remaining:self.snapshot.primaryRemaining label:@"5小时"];
    [self drawRingAt:NSMakePoint(108, NSMidY(self.bounds) + 1) radius:25
           remaining:self.snapshot.secondaryRemaining label:@"本周"];
}

- (NSColor *)colorForRemaining:(NSInteger)remaining {
    if (remaining <= 20) return NSColor.systemRedColor;
    if (remaining <= 45) return NSColor.systemOrangeColor;
    return NSColor.systemGreenColor;
}

- (void)drawRingAt:(NSPoint)center radius:(CGFloat)radius remaining:(NSInteger)remaining label:(NSString *)label {
    NSRect ringRect = NSMakeRect(center.x - radius, center.y - radius, radius * 2, radius * 2);
    NSBezierPath *background = [NSBezierPath bezierPathWithOvalInRect:ringRect];
    [[NSColor colorWithWhite:1 alpha:0.14] setStroke];
    background.lineWidth = 5;
    [background stroke];

    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:center radius:radius startAngle:90
                                  endAngle:90 - remaining * 3.6 clockwise:YES];
    arc.lineWidth = 5;
    arc.lineCapStyle = NSLineCapStyleRound;
    [[self colorForRemaining:remaining] setStroke];
    [arc stroke];

    NSDictionary *percentAttributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSString *percent = [NSString stringWithFormat:@"%ld%%", (long)remaining];
    NSSize percentSize = [percent sizeWithAttributes:percentAttributes];
    [percent drawAtPoint:NSMakePoint(center.x - percentSize.width / 2, center.y - 5)
          withAttributes:percentAttributes];

    NSDictionary *labelAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.62]
    };
    NSSize labelSize = [label sizeWithAttributes:labelAttributes];
    [label drawAtPoint:NSMakePoint(center.x - labelSize.width / 2, center.y - 17)
        withAttributes:labelAttributes];
}

- (void)drawCentered:(NSString *)text inRect:(NSRect)rect font:(NSFont *)font color:(NSColor *)color {
    NSDictionary *attributes = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color};
    NSSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:NSMakePoint(NSMidX(rect) - size.width / 2, NSMidY(rect) - size.height / 2)
       withAttributes:attributes];
}

- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) {
        if (self.onDoubleClick) self.onDoubleClick();
        return;
    }
    self.dragOrigin = NSEvent.mouseLocation;
    self.windowOrigin = self.window.frame.origin;
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint current = NSEvent.mouseLocation;
    NSPoint origin = NSMakePoint(self.windowOrigin.x + current.x - self.dragOrigin.x,
                                 self.windowOrigin.y + current.y - self.dragOrigin.y);
    [self.window setFrameOrigin:origin];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint origin = self.window.frame.origin;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:origin.x forKey:@"bubbleX"];
    [defaults setDouble:origin.y forKey:@"bubbleY"];
    [defaults setBool:YES forKey:@"hasBubblePosition"];
}

@end

@interface QPAppDelegate : NSObject <NSApplicationDelegate>
@property(strong) QPCodexUsageClient *client;
@property(strong) NSStatusItem *statusItem;
@property(strong) NSPanel *panel;
@property(strong) QPQuotaBubbleView *bubbleView;
@property(strong) NSTimer *timer;
@property(strong) QPUsageSnapshot *snapshot;
@property(copy) NSString *lastError;
@end

@implementation QPAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.client = [[QPCodexUsageClient alloc] init];
    [self setupStatusItem];
    [self setupPanel];
    [self wireClient];
    [self.client start];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:120 target:self selector:@selector(refresh)
                                                userInfo:nil repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    [self.client stop];
}

- (void)setupStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
    self.statusItem.button.title = @"额度 …";
    self.statusItem.menu = [self buildMenu];
}

- (void)setupPanel {
    NSSize size = NSMakeSize(150, 76);
    NSPoint origin;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"hasBubblePosition"]) {
        origin = NSMakePoint([defaults doubleForKey:@"bubbleX"], [defaults doubleForKey:@"bubbleY"]);
    } else if (NSScreen.mainScreen) {
        NSRect visible = NSScreen.mainScreen.visibleFrame;
        origin = NSMakePoint(NSMaxX(visible) - size.width - 22, NSMinY(visible) + 88);
    } else {
        origin = NSMakePoint(100, 100);
    }

    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(origin.x, origin.y, size.width, size.height)
                                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered defer:NO];
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorStationary;
    self.panel.hidesOnDeactivate = NO;

    self.bubbleView = [[QPQuotaBubbleView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    self.bubbleView.statusText = @"正在连接…";
    __weak typeof(self) weakSelf = self;
    self.bubbleView.onDoubleClick = ^{ [weakSelf refresh]; };
    self.panel.contentView = self.bubbleView;
    [self.panel orderFrontRegardless];
}

- (void)wireClient {
    __weak typeof(self) weakSelf = self;
    self.client.onSnapshot = ^(QPUsageSnapshot *snapshot) {
        weakSelf.snapshot = snapshot;
        weakSelf.lastError = nil;
        [weakSelf updateUI];
    };
    self.client.onError = ^(NSString *message) {
        weakSelf.lastError = message;
        [weakSelf updateUI];
    };
}

- (void)refresh {
    self.bubbleView.statusText = @"正在刷新…";
    [self.client refresh];
}

- (void)updateUI {
    self.bubbleView.snapshot = self.snapshot;
    if (self.snapshot) {
        self.statusItem.button.title = [NSString stringWithFormat:@"5h %ld%% · 周 %ld%%",
            (long)self.snapshot.primaryRemaining, (long)self.snapshot.secondaryRemaining];
        self.statusItem.button.toolTip = @"额度桌宠：点击查看详情";
    } else {
        self.statusItem.button.title = @"额度 --";
        self.bubbleView.statusText = self.lastError ?: @"暂时无法读取";
    }
    self.statusItem.menu = [self buildMenu];
}

- (NSMenuItem *)disabledItem:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

- (NSString *)formatReset:(NSTimeInterval)timestamp {
    if (timestamp <= 0) return @"未知";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = [[NSCalendar currentCalendar] isDateInToday:date] ? @"今天 HH:mm" : @"M月d日 HH:mm";
    return [formatter stringFromDate:date];
}

- (NSMenu *)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    if (self.snapshot) {
        [menu addItem:[self disabledItem:[NSString stringWithFormat:@"5 小时剩余：%ld%%", (long)self.snapshot.primaryRemaining]]];
        [menu addItem:[self disabledItem:[NSString stringWithFormat:@"重置时间：%@", [self formatReset:self.snapshot.primaryReset]]]];
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItem:[self disabledItem:[NSString stringWithFormat:@"每周剩余：%ld%%", (long)self.snapshot.secondaryRemaining]]];
        [menu addItem:[self disabledItem:[NSString stringWithFormat:@"重置时间：%@", [self formatReset:self.snapshot.secondaryReset]]]];
        [menu addItem:[self disabledItem:[NSString stringWithFormat:@"可用完整重置券：%ld", (long)self.snapshot.resetCredits]]];
    } else {
        [menu addItem:[self disabledItem:self.lastError ?: @"正在读取额度…"]];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"立即刷新" action:@selector(refresh) keyEquivalent:@"r"];
    refresh.target = self;
    [menu addItem:refresh];
    NSString *toggleTitle = self.panel.visible ? @"隐藏桌面额度泡泡" : @"显示桌面额度泡泡";
    NSMenuItem *toggle = [[NSMenuItem alloc] initWithTitle:toggleTitle action:@selector(togglePanel) keyEquivalent:@""];
    toggle.target = self;
    [menu addItem:toggle];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出额度桌宠" action:@selector(quit) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
    return menu;
}

- (void)togglePanel {
    if (self.panel.visible) [self.panel orderOut:nil];
    else [self.panel orderFrontRegardless];
    self.statusItem.menu = [self buildMenu];
}

- (void)quit {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        QPAppDelegate *delegate = [[QPAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
