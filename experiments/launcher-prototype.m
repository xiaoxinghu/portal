// SPDX-License-Identifier: GPL-3.0-or-later
// THROWAWAY: can a real EmacsView live in an NSPanel and answer a global hotkey?
// Run only in the isolated Emacs started by launcher-prototype.sh.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <emacs-module.h>
#include <fcntl.h>
#include <math.h>
#include <unistd.h>

int plugin_is_GPL_compatible;
static NSWindow *donor, *launcher;
static NSView *content;
static id editor;
static NSRunningApplication *previousApp;
static EventHotKeyRef hotkey;
static EventHandlerRef handler;
static int channel = -1;
static BOOL installed, changing;
static NSUInteger presses;
static NSRect requested;

static void notify(const char *message) {
    if (installed && channel >= 0) (void)write(channel, message, strlen(message));
}

@interface PortalPrototypePanel : NSPanel
@end
@implementation PortalPrototypePanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (NSRect)constrainFrameRect:(NSRect)rect toScreen:(NSScreen *)screen {
    (void)screen;
    return rect;
}
- (void)resignKeyWindow {
    [super resignKeyWindow];
    if (installed && !changing && self.visible) {
        [self orderOut:nil];
        notify("blur\n");
    }
}
// EmacsView sends some EmacsWindow-specific messages (e.g. setLastDragEvent:).
// Preserve its original window as the fallback receiver for this experiment.
// This is deliberately NOT a supported general-purpose EmacsWindow replacement.
- (id)forwardingTargetForSelector:(SEL)selector {
    if ([donor respondsToSelector:selector]) {
        NSLog(@"Launcher prototype forwards %@ to EmacsWindow", NSStringFromSelector(selector));
        return donor;
    }
    return [super forwardingTargetForSelector:selector];
}
@end

static emacs_value fail(emacs_env *env, const char *message) {
    emacs_value text = env->make_string(env, message, strlen(message));
    emacs_value args = env->funcall(env, env->intern(env, "list"), 1, &text);
    env->non_local_exit_signal(env, env->intern(env, "error"), args);
    return env->intern(env, "nil");
}

static NSString *stringValue(emacs_env *env, emacs_value value) {
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, value, NULL, &size)) return nil;
    char *bytes = malloc(size);
    env->copy_string_contents(env, value, bytes, &size);
    NSString *result = [[NSString alloc] initWithBytes:bytes length:size - 1 encoding:NSUTF8StringEncoding];
    free(bytes);
    return result;
}

static OSStatus pressed(EventHandlerCallRef call, EventRef event, void *context) {
    (void)call; (void)event; (void)context;
    presses++;
    // No Lisp calls from this callback: wake Emacs through a module channel.
    notify("hotkey\n");
    return noErr;
}

static void stop(void) {
    installed = NO;
    changing = YES;
    if (hotkey) { UnregisterEventHotKey(hotkey); hotkey = NULL; }
    if (handler) { RemoveEventHandler(handler); handler = NULL; }
    [launcher orderOut:nil];
    if (launcher && launcher != donor) {
        launcher.delegate = nil;
        launcher.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
        donor.contentView = content;
        donor.delegate = editor;
        [donor makeFirstResponder:editor];
        [launcher close];
    }
    launcher = nil; content = nil; editor = nil; donor = nil; previousApp = nil;
    if (channel >= 0) { close(channel); channel = -1; }
    changing = NO;
}

static emacs_value install(emacs_env *env, ptrdiff_t count, emacs_value *args, void *data) {
    (void)count; (void)data;
    if (installed) return fail(env, "Prototype already installed; stop it first");
    NSString *title = stringValue(env, args[0]);
    for (NSWindow *window in NSApp.windows) if ([window.title isEqualToString:title]) { donor = window; break; }
    if (!donor) return fail(env, "Cannot find the prototype Emacs frame");
    channel = env->open_channel(env, args[1]);
    if (channel < 0) { donor = nil; return fail(env, "Cannot open notification pipe"); }
    fcntl(channel, F_SETFL, fcntl(channel, F_GETFL) | O_NONBLOCK);
    fcntl(channel, F_SETNOSIGPIPE, 1);
    editor = donor.delegate;
    content = donor.contentView;
    changing = YES;
    [donor orderOut:nil];
    if (env->is_not_nil(env, args[2])) {
        PortalPrototypePanel *panel = [[PortalPrototypePanel alloc]
            initWithContentRect:donor.frame
                      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                        backing:NSBackingStoreBuffered defer:NO];
        panel.releasedWhenClosed = NO;
        panel.hidesOnDeactivate = NO;
        panel.becomesKeyOnlyIfNeeded = NO;
        panel.floatingPanel = YES;
        donor.delegate = nil;
        donor.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
        panel.contentView = content;
        panel.delegate = editor;
        launcher = panel;
    } else launcher = donor;
    launcher.title = @"Portal launcher prototype";
    launcher.level = NSFloatingWindowLevel;
    launcher.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient
        | NSWindowCollectionBehaviorIgnoresCycle;
    launcher.tabbingMode = NSWindowTabbingModeDisallowed;
    launcher.hasShadow = YES;
    launcher.opaque = NO;
    launcher.backgroundColor = [NSColor colorWithRed:0.09 green:0.10 blue:0.13 alpha:1];
    launcher.contentView.wantsLayer = YES;
    launcher.contentView.layer.cornerRadius = 14;
    launcher.contentView.layer.masksToBounds = YES;
    [launcher makeFirstResponder:editor];
    EventTypeSpec type = { kEventClassKeyboard, kEventHotKeyPressed };
    OSStatus status = InstallEventHandler(GetApplicationEventTarget(), pressed, 1, &type, NULL, &handler);
    if (status == noErr) {
        EventHotKeyID identity = { 'PrLP', 1 };
        status = RegisterEventHotKey(kVK_ANSI_P, controlKey | optionKey | cmdKey,
                                    identity, GetApplicationEventTarget(), 0, &hotkey);
    }
    if (status != noErr) { stop(); return fail(env, "Cannot register Control-Option-Command-P (possibly already registered)"); }
    installed = YES;
    changing = NO;
    return env->intern(env, "t");
}

static emacs_value show(emacs_env *env, ptrdiff_t count, emacs_value *args, void *data) {
    (void)count; (void)data;
    if (!installed) return fail(env, "Prototype not installed");
    double width = env->extract_integer(env, args[0]), height = env->extract_integer(env, args[1]);
    double dx = env->extract_integer(env, args[2]), dy = env->extract_integer(env, args[3]);
    NSInteger index = env->extract_integer(env, args[4]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) return env->intern(env, "nil");
    if (width < 200 || height < 100) return fail(env, "Size must be at least 200 by 100 points");
    NSArray<NSScreen *> *screens = NSScreen.screens;
    NSScreen *screen = screens.firstObject;
    if (index >= 0 && index < (NSInteger)screens.count) screen = screens[index];
    else for (NSScreen *candidate in screens) if (NSPointInRect(NSEvent.mouseLocation, candidate.frame)) { screen = candidate; break; }
    NSRect area = screen.visibleFrame;
    width = MIN(width, area.size.width); height = MIN(height, area.size.height);
    // Native Cocoa logical points, including negative origins on other screens.
    // Emacs stores frame origins as integer logical points. Avoid a half-point
    // correction from its window delegate when centering an odd-sized frame.
    requested = NSMakeRect(floor(NSMidX(area) - width / 2 + dx),
                           floor(NSMidY(area) - height / 2 - dy), width, height);
    if (!launcher.visible) previousApp = NSWorkspace.sharedWorkspace.frontmostApplication;
    changing = YES;
    [launcher setFrame:requested display:YES];
    if (![launcher isKindOfClass:NSPanel.class]) [NSApp activateIgnoringOtherApps:YES];
    [launcher makeKeyAndOrderFront:nil];
    [launcher makeFirstResponder:editor];
    changing = NO;
    NSLog(@"Launcher prototype %@ requested=%@ actual=%@ key=%d appActive=%d",
          NSStringFromClass(launcher.class), NSStringFromRect(requested), NSStringFromRect(launcher.frame),
          launcher.keyWindow, NSApp.active);
    return env->intern(env, "t");
}

static emacs_value hide(emacs_env *env, ptrdiff_t count, emacs_value *args, void *data) {
    (void)count; (void)args; (void)data;
    changing = YES;
    BOOL owned = launcher.keyWindow;
    [launcher orderOut:nil];
    if (owned && NSApp.active && previousApp && previousApp.processIdentifier != getpid())
        [previousApp activateWithOptions:0];
    changing = NO;
    return env->intern(env, "nil");
}

static NSArray *rect(NSRect value) { return @[@(value.origin.x), @(value.origin.y), @(value.size.width), @(value.size.height)]; }
static emacs_value state(emacs_env *env, ptrdiff_t count, emacs_value *args, void *data) {
    (void)count; (void)args; (void)data;
    NSMutableArray *screens = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens)
        [screens addObject:@{@"name":screen.localizedName, @"frame":rect(screen.frame), @"visible":rect(screen.visibleFrame), @"scale":@(screen.backingScaleFactor)}];
    NSDictionary *value = @{@"installed":@(installed), @"class":launcher ? NSStringFromClass(launcher.class) : @"none",
        @"panel":@([launcher isKindOfClass:NSPanel.class]), @"visible":@(launcher.visible), @"key":@(launcher.keyWindow),
        @"appActive":@(NSApp.active), @"hotkeyPresses":@(presses), @"requested":rect(requested),
        @"actual":rect(launcher.frame), @"content":rect(launcher.contentView.bounds),
        @"responder":launcher.firstResponder ? NSStringFromClass(launcher.firstResponder.class) : @"none",
        @"frontmost":NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier ?: @"none", @"screens":screens};
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    return env->make_string(env, json.bytes, json.length);
}
static emacs_value finish(emacs_env *env, ptrdiff_t count, emacs_value *args, void *data) {
    (void)count; (void)args; (void)data;
    stop();
    return env->intern(env, "nil");
}

int emacs_module_init(struct emacs_runtime *runtime) {
    emacs_env *env = runtime->get_environment(runtime);
    struct { const char *name; ptrdiff_t arity; emacs_function fn; } exports[] = {
        {"portal-prototype--install", 3, install}, {"portal-prototype--show", 5, show},
        {"portal-prototype--hide", 0, hide}, {"portal-prototype--state", 0, state},
        {"portal-prototype--stop", 0, finish}
    };
    for (size_t i = 0; i < sizeof(exports) / sizeof(exports[0]); i++) {
        emacs_value args[] = {env->intern(env, exports[i].name),
            env->make_function(env, exports[i].arity, exports[i].arity, exports[i].fn, "Throwaway launcher experiment.", NULL)};
        env->funcall(env, env->intern(env, "fset"), 2, args);
    }
    return 0;
}
