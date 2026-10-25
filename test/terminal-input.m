/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Test-only event injection inside the disposable Emacs process.  Exercises
   AppKit event dispatch without Accessibility permission or global key events. */
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <IOSurface/IOSurface.h>
#import <WebKit/WebKit.h>
#include <emacs-module.h>
#include <stdlib.h>
#include <string.h>

int plugin_is_GPL_compatible;
static __weak NSWindow *explicitWindow;

static NSWindow *activeWindow(void)
{
    if (explicitWindow) return explicitWindow;
    static __weak NSWindow *lastWindow;
    NSWindow *window = NSApp.keyWindow;
    // The desktop app may regain activation between tool calls. Keep local
    // injection addressed to this disposable Emacs window in that case.
    if (!window) {
        window = NSApp.mainWindow ?: lastWindow;
        [window makeKeyWindow];
    }
    lastWindow = window;
    return window;
}

static emacs_value targetFrame(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    explicitWindow = nil;
    if (!env->is_not_nil(env, args[0])) return env->intern(env, "t");
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[0], NULL, &size)) return env->intern(env, "nil");
    char *bytes = malloc((size_t)size);
    if (!bytes) return env->intern(env, "nil");
    if (!env->copy_string_contents(env, args[0], bytes, &size)) { free(bytes); return env->intern(env, "nil"); }
    NSString *title = [NSString stringWithUTF8String:bytes];
    free(bytes);
    for (NSWindow *window in NSApp.windows) {
        if ([window.title isEqualToString:title]) { explicitWindow = window; break; }
    }
    return env->intern(env, explicitWindow ? "t" : "nil");
}

static emacs_value focusTarget(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)args; (void)data;
    [explicitWindow makeKeyAndOrderFront:nil];
    return env->intern(env, explicitWindow.isKeyWindow ? "t" : "nil");
}

static NSArray<NSView *> *descendants(NSView *root)
{
    NSMutableArray<NSView *> *result = [NSMutableArray array];
    for (NSView *child in root.subviews) {
        [result addObject:child];
        [result addObjectsFromArray:descendants(child)];
    }
    return result;
}

static emacs_value click(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    NSPoint offset = NSMakePoint(env->extract_integer(env, args[0]), env->extract_integer(env, args[1]));
    NSWindow *window = activeWindow();
    for (NSView *view in descendants(window.contentView)) {
        if ([view isKindOfClass:WKWebView.class] && !view.isHiddenOrHasHiddenAncestor) {
            // WKWebView is flipped, so OFFSET is from its top-left corner.
            NSPoint point = [view convertPoint:offset toView:nil];
            for (NSNumber *type in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
                [NSApp sendEvent:[NSEvent mouseEventWithType:type.unsignedIntegerValue location:point
                    modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                    windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1]];
            }
            return env->intern(env, "t");
        }
    }
    return env->intern(env, "nil");
}

static emacs_value key(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    emacs_value nilValue = env->intern(env, "nil");
    NSInteger code = env->extract_integer(env, args[0]);
    NSEventModifierFlags flags = (NSEventModifierFlags)env->extract_integer(env, args[1]);
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[2], NULL, &size)) return nilValue;
    char *bytes = malloc((size_t)size);
    if (!bytes) return nilValue;
    if (!env->copy_string_contents(env, args[2], bytes, &size)) { free(bytes); return nilValue; }
    NSString *text = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)(size - 1)
                                         encoding:NSUTF8StringEncoding];
    free(bytes);
    NSWindow *window = activeWindow();
    if (!window || !text) return nilValue;
    BOOL windowless = nargs > 3 && env->is_not_nil(env, args[3]);
    NSString *unmodified = text;
    if ((flags & NSEventModifierFlagControl) && text.length == 1) {
        unichar character = [text characterAtIndex:0];
        if (character <= 31) {
            // Match AppKit's unmodified character for control punctuation too
            // (e.g. C-] is byte 29, but charactersIgnoringModifiers is "]").
            character += character >= 1 && character <= 26 ? 'a' - 1 : '@';
            unmodified = [NSString stringWithCharacters:&character length:1];
        }
    }
    for (NSNumber *type in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
        NSEvent *event = [NSEvent keyEventWithType:type.unsignedIntegerValue
            location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime
            windowNumber:windowless ? 0 : window.windowNumber context:nil characters:text
            charactersIgnoringModifiers:unmodified isARepeat:NO keyCode:(unsigned short)code];
        if (data) [NSApp postEvent:event atStart:NO];
        else [NSApp sendEvent:event];
    }
    return env->intern(env, "t");
}

// Asynchronous JS inspection stays inside this test module. No emacs_env is
// captured by WebKit completions, and the production editor has no eval API.
static NSString *webResult;
static emacs_value webEval(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    if (!env->is_not_nil(env, args[0])) {
        if (!webResult) return env->intern(env, "nil");
        return env->make_string(env, webResult.UTF8String, (ptrdiff_t)[webResult lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[0], NULL, &size)) return env->intern(env, "nil");
    char *bytes = malloc((size_t)size);
    if (!bytes) return env->intern(env, "nil");
    if (!env->copy_string_contents(env, args[0], bytes, &size)) { free(bytes); return env->intern(env, "nil"); }
    NSString *script = [NSString stringWithUTF8String:bytes];
    free(bytes);
    webResult = nil;
    for (NSView *view in descendants(activeWindow().contentView)) {
        if ([view isKindOfClass:WKWebView.class] && !view.isHiddenOrHasHiddenAncestor) {
            [(WKWebView *)view callAsyncJavaScript:script arguments:@{} inFrame:nil
                inContentWorld:WKContentWorld.pageWorld completionHandler:^(id value, NSError *error) {
                    NSDictionary *result = error ? @{ @"error": error.localizedDescription }
                        : @{ @"value": value ?: NSNull.null };
                    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingFragmentsAllowed error:nil];
                    webResult = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
                }];
            return env->intern(env, "t");
        }
    }
    return env->intern(env, "nil");
}

/* Deliver a Carbon notification to the installed production handler. This
   tests callback -> pipe -> command loop, not physical/global key detection.
   HOTKEY is the core's, as portal--shortcuts reports it. */
static emacs_value hotkey(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    EventHotKeyID key = {0x5072744c, (UInt32)env->extract_integer(env, args[0])};
    EventRef event = NULL;
    OSStatus status = CreateEvent(NULL, kEventClassKeyboard,
        env->is_not_nil(env, args[1]) ? kEventHotKeyPressed : kEventHotKeyReleased,
        GetCurrentEventTime(), 0, &event);
    if (status != noErr) return env->intern(env, "nil");
    SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, sizeof key, &key);
    status = SendEventToEventTarget(event, GetApplicationEventTarget());
    ReleaseEvent(event);
    return env->intern(env, status == noErr ? "t" : "nil");
}

/* Inspect/activate a running app by PID. A string selects a bundle ID, used
   for Finder in focus tests; no app is launched and no global keys are sent. */
static emacs_value frontmost(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)data;
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (nargs && env->is_not_nil(env, args[0])) {
        if (env->eq(env, env->type_of(env, args[0]), env->intern(env, "string"))) {
            ptrdiff_t size = 0;
            if (!env->copy_string_contents(env, args[0], NULL, &size)) return env->intern(env, "nil");
            char *bytes = malloc((size_t)size);
            if (!bytes) return env->intern(env, "nil");
            if (!env->copy_string_contents(env, args[0], bytes, &size)) { free(bytes); return env->intern(env, "nil"); }
            app = [NSRunningApplication runningApplicationsWithBundleIdentifier:[NSString stringWithUTF8String:bytes]].firstObject;
            free(bytes);
        } else {
            pid_t pid = (pid_t)env->extract_integer(env, args[0]);
            if (pid == -1) {
                for (NSRunningApplication *candidate in NSWorkspace.sharedWorkspace.runningApplications) {
                    if (candidate.activationPolicy == NSApplicationActivationPolicyRegular && candidate.bundleURL
                        && ![candidate isEqual:app]
                        && ![candidate.bundleIdentifier isEqual:NSRunningApplication.currentApplication.bundleIdentifier])
                        return env->make_integer(env, candidate.processIdentifier);
                }
                return env->intern(env, "nil");
            }
            app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        }
        if (!app.bundleURL) return env->intern(env, "nil");
        // Exercise an application-launch action from a nonactivating panel.
        // activateWithOptions alone can be refused when Emacs is inactive.
        NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
        configuration.activates = YES;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:app.bundleURL
            configuration:configuration completionHandler:nil];
    }
    return app ? env->make_integer(env, app.processIdentifier) : env->intern(env, "nil");
}

/* Save what Emacs last drew in the targeted frame as a PNG at FILE. This
   reads the surface Emacs gave its view's layer, not the screen, so it needs
   no Screen Recording permission and shows no window decoration. */
static emacs_value capture(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    emacs_value nilValue = env->intern(env, "nil");
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[0], NULL, &size)) return nilValue;
    char *bytes = malloc((size_t)size);
    if (!bytes) return nilValue;
    if (!env->copy_string_contents(env, args[0], bytes, &size)) { free(bytes); return nilValue; }
    NSString *path = [NSString stringWithUTF8String:bytes];
    free(bytes);
    NSView *content = explicitWindow.contentView;
    if (!content || !path) return nilValue;
    for (NSView *view in [@[content] arrayByAddingObjectsFromArray:descendants(content)]) {
        if (![view isKindOfClass:NSClassFromString(@"EmacsView")]) continue;
        // Emacs's layer takes its newest surface only when displayed; do now
        // what Core Animation would do at its next commit.
        [view.layer displayIfNeeded];
        id contents = view.layer.contents;
        if (!contents || CFGetTypeID((__bridge CFTypeRef)contents) != IOSurfaceGetTypeID()) return nilValue;
        IOSurfaceRef surface = (__bridge IOSurfaceRef)contents;
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(
            IOSurfaceGetBaseAddress(surface), IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface),
            8, IOSurfaceGetBytesPerRow(surface), space,
            (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
        CGContextRelease(context);
        CGColorSpaceRelease(space);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        if (!image) return nilValue;
        NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:image]
                          representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        CGImageRelease(image);
        return env->intern(env, [png writeToFile:path atomically:YES] ? "t" : "nil");
    }
    return nilValue;
}

/* Move the pointer to X Y, in AppKit points from the main display's
   bottom-left corner, if given. Return where AppKit reports it, (X . Y). */
static emacs_value pointer(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)data;
    if (nargs == 2) {
        CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
        CGWarpMouseCursorPosition(CGPointMake(env->extract_integer(env, args[0]),
                                              top - env->extract_integer(env, args[1])));
    }
    NSPoint location = NSEvent.mouseLocation;
    emacs_value pair[] = {env->make_integer(env, (intmax_t)floor(location.x)),
                          env->make_integer(env, (intmax_t)floor(location.y))};
    return env->funcall(env, env->intern(env, "cons"), 2, pair);
}

/* Compose TEXT in the targeted window's first responder as an input method
   does: as marked text or, with COMMIT, inserted, ending the composition.
   Emacs reads either only while it handles an event, so a one-shot monitor
   does this as Emacs's own event loop dispatches a posted F19 key. */
static emacs_value compose(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)data;
    emacs_value nilValue = env->intern(env, "nil");
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[0], NULL, &size)) return nilValue;
    char *bytes = malloc((size_t)size);
    if (!bytes) return nilValue;
    if (!env->copy_string_contents(env, args[0], bytes, &size)) { free(bytes); return nilValue; }
    NSString *text = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)(size - 1)
                                         encoding:NSUTF8StringEncoding];
    free(bytes);
    NSWindow *window = activeWindow();
    if (!window || !text) return nilValue;
    BOOL commit = nargs > 1 && env->is_not_nil(env, args[1]);
    __block id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                               handler:^NSEvent *(NSEvent *event) {
        if (event.window != window || event.keyCode != kVK_F19) return event;
        [NSEvent removeMonitor:monitor];
        monitor = nil;
        id<NSTextInputClient> client = (id<NSTextInputClient>)window.firstResponder;
        NSRange none = NSMakeRange(NSNotFound, 0);
        if (commit) [client insertText:text replacementRange:none];
        else [client setMarkedText:text selectedRange:NSMakeRange(text.length, 0) replacementRange:none];
        return nil;
    }];
    [NSApp postEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                       timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:window.windowNumber context:nil characters:@""
                     charactersIgnoringModifiers:@"" isARepeat:NO keyCode:kVK_F19]
             atStart:NO];
    return env->intern(env, "t");
}

static emacs_value marked(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)args; (void)data;
    id responder = activeWindow().firstResponder;
    BOOL composing = [responder respondsToSelector:@selector(hasMarkedText)] && [responder hasMarkedText];
    return env->intern(env, composing ? "t" : "nil");
}

/* Describe who has the keyboard: the key window's title and the class of its
   first responder, for failure reports. */
static emacs_value responder(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)args; (void)data;
    NSWindow *window = NSApp.keyWindow;
    NSString *text = window
        ? [NSString stringWithFormat:@"%@ in %@ (%@active)",
              NSStringFromClass([window.firstResponder class]), window.title, NSApp.active ? @"" : @"in"]
        : [NSString stringWithFormat:@"no key window (%@active)", NSApp.active ? @"" : @"in"];
    return env->make_string(env, text.UTF8String, (ptrdiff_t)strlen(text.UTF8String));
}

/* Describe the sheet on the targeted window as JSON, or return nil without
   one: its labels' texts, its text field's text or null, its buttons' titles,
   and whether it has the keyboard. With BUTTON, first put TEXT, if given, in
   its text field, then press the button titled BUTTON; nil if none is. */
static emacs_value sheet(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)data;
    emacs_value nilValue = env->intern(env, "nil");
    NSString *strings[2] = {nil, nil};
    for (ptrdiff_t i = 0; i < nargs && i < 2; i++) {
        if (!env->is_not_nil(env, args[i])) continue;
        ptrdiff_t size = 0;
        if (!env->copy_string_contents(env, args[i], NULL, &size)) return nilValue;
        char *bytes = malloc((size_t)size);
        if (!bytes) return nilValue;
        if (!env->copy_string_contents(env, args[i], bytes, &size)) { free(bytes); return nilValue; }
        strings[i] = [NSString stringWithUTF8String:bytes];
        free(bytes);
    }
    NSWindow *panel = activeWindow().attachedSheet;
    if (!panel) return nilValue;
    NSMutableArray<NSString *> *texts = [NSMutableArray array], *titles = [NSMutableArray array];
    NSTextField *field = nil;
    NSButton *chosen = nil;
    for (NSView *view in descendants(panel.contentView)) {
        if (view.isHiddenOrHasHiddenAncestor) continue;
        if ([view isKindOfClass:NSTextField.class]) {
            NSTextField *text = (NSTextField *)view;
            if (text.isEditable) field = text;
            else if (text.stringValue.length) [texts addObject:text.stringValue];
        } else if ([view isKindOfClass:NSButton.class] && ((NSButton *)view).title.length) {
            [titles addObject:((NSButton *)view).title];
            if ([((NSButton *)view).title isEqualToString:strings[0]]) chosen = (NSButton *)view;
        }
    }
    if (strings[0]) {
        if (!chosen) return nilValue;
        if (strings[1]) field.stringValue = strings[1];
        [chosen performClick:nil];
        return env->intern(env, "t");
    }
    NSDictionary *result = @{ @"texts": texts, @"field": field ? field.stringValue : NSNull.null,
                              @"buttons": titles, @"key": @(panel.isKeyWindow) };
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    return env->make_string(env, text.UTF8String, (ptrdiff_t)strlen(text.UTF8String));
}

/* Give the visible webview WebKit's mock camera and microphone, which need
   no system permission, or its real devices again with nil. */
static emacs_value mockCapture(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    SEL selector = NSSelectorFromString(@"_setMockCaptureDevicesEnabled:");
    for (NSView *view in descendants(activeWindow().contentView)) {
        if ([view isKindOfClass:WKWebView.class] && !view.isHiddenOrHasHiddenAncestor) {
            WKPreferences *preferences = ((WKWebView *)view).configuration.preferences;
            if (![preferences respondsToSelector:selector]) return env->intern(env, "nil");
            void (*set)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[preferences methodForSelector:selector];
            set(preferences, selector, env->is_not_nil(env, args[0]));
            return env->intern(env, "t");
        }
    }
    return env->intern(env, "nil");
}

int emacs_module_init(struct emacs_runtime *runtime)
{
    emacs_env *env = runtime->get_environment(runtime);
    emacs_value args[] = {
        env->intern(env, "portal-test-native-key"),
        env->make_function(env, 3, 4, key, "Send an AppKit key event: CODE FLAGS TEXT &optional WINDOWLESS.", NULL)
    };
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-native-post-key");
    args[1] = env->make_function(env, 3, 4, key,
        "Queue an AppKit key event: CODE FLAGS TEXT &optional WINDOWLESS.", (void *)1);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-native-click");
    args[1] = env->make_function(env, 2, 2, click,
        "Click the visible native webview X Y points from its top-left corner.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-web-eval");
    args[1] = env->make_function(env, 1, 1, webEval,
        "Evaluate SCRIPT in the visible webview; nil retrieves the async JSON result.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-native-target-frame");
    args[1] = env->make_function(env, 1, 1, targetFrame,
        "Target a frame with TITLE for local test injection; nil restores active-window targeting.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-hotkey");
    args[1] = env->make_function(env, 2, 2, hotkey,
        "Dispatch a Carbon hot key notification: HOTKEY PRESSED.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-frontmost");
    args[1] = env->make_function(env, 0, 1, frontmost,
        "Return frontmost PID; APP activates PID/bundle ID; -1 finds another regular app without activating it.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-native-focus-target");
    args[1] = env->make_function(env, 0, 0, focusTarget,
        "Give the explicitly targeted native frame keyboard focus.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-capture-target");
    args[1] = env->make_function(env, 1, 1, capture,
        "Save what Emacs last drew in the targeted frame as a PNG at FILE.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-pointer");
    args[1] = env->make_function(env, 0, 2, pointer,
        "Move the pointer to X Y, AppKit points, if given; return its position as (X . Y).", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-compose");
    args[1] = env->make_function(env, 1, 2, compose,
        "Compose TEXT in the targeted frame as an input method does; COMMIT inserts it.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-responder");
    args[1] = env->make_function(env, 0, 0, responder,
        "Describe the key window and its first responder.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-marked-text");
    args[1] = env->make_function(env, 0, 0, marked,
        "Whether the targeted frame's first responder has marked text.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-sheet");
    args[1] = env->make_function(env, 0, 2, sheet,
        "Describe the targeted frame's sheet as JSON; BUTTON presses it, after typing TEXT if given.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-web-mock-capture");
    args[1] = env->make_function(env, 1, 1, mockCapture,
        "Give the visible webview WebKit's mock capture devices if ON, else its real ones.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    return 0;
}
