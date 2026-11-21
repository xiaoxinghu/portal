/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Test-only: read back what the window server shows of this Emacs's own
   window, Portal's native views included, for test/render-smoke.sh.

   (portal-test-capture-window FILE) captures the key window, or the main
   window, and writes its content area, without title bar or shadow, at
   FILE as a binary PPM in device pixels, and as a PNG at FILE.png for a
   person to look at.  It returns (WIDTH HEIGHT SCALE SECONDS METHOD), or a
   string saying why it could not capture.

   It asks ScreenCaptureKit for the current process's own content (macOS
   14.4), which needs no Screen Recording permission for a process's own
   windows.  Before 14.4 it calls CGWindowListCreateImage, which the SDK
   marks unavailable and so is looked up at run time.  Reading the layers
   instead does not do: Ghostty draws into a layer of its own, and Emacs's
   layer, which `portal-test-capture-target' reads, has none of it. */
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <dlfcn.h>
#include <emacs-module.h>
#include <stdlib.h>
#include <string.h>

int plugin_is_GPL_compatible;

static NSWindow *emacsWindow(void)
{
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (window) return window;
    for (NSWindow *candidate in NSApp.windows)
        if (candidate.isVisible && [candidate.contentView isKindOfClass:NSClassFromString(@"EmacsView")])
            return candidate;
    return nil;
}

/* The content view's rectangle in device pixels, in an image of the
   window's own bounds. */
static CGRect contentCrop(NSWindow *window, CGImageRef image)
{
    double scale = (double)CGImageGetWidth(image) / window.frame.size.width;
    NSRect content = [window contentRectForFrameRect:window.frame];
    double top = (NSMaxY(window.frame) - NSMaxY(content)) * scale;
    return CGRectMake(0, round(top), round(content.size.width * scale), round(content.size.height * scale));
}

/* Write CROP of IMAGE as a PPM at PATH and a PNG beside it; nil or why not. */
static NSString *writeImage(CGImageRef image, CGRect crop, NSString *path)
{
    size_t width = (size_t)crop.size.width, height = (size_t)crop.size.height;
    if (!width || !height) return @"the window has no content area";
    uint8_t *rgba = calloc(width * height, 4);
    if (!rgba) return @"out of memory";
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(rgba, width, height, 8, width * 4, space,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) { free(rgba); return @"no bitmap context"; }
    /* Draw the whole image so that the crop's top left lands at 0, 0. */
    CGContextDrawImage(context,
        CGRectMake(-crop.origin.x, -(CGImageGetHeight(image) - crop.origin.y - crop.size.height),
                   CGImageGetWidth(image), CGImageGetHeight(image)), image);
    CGImageRef cropped = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    NSMutableData *ppm = [[NSString stringWithFormat:@"P6\n%zu %zu\n255\n", width, height]
                             dataUsingEncoding:NSASCIIStringEncoding].mutableCopy;
    for (size_t i = 0; i < width * height; i++) [ppm appendBytes:rgba + i * 4 length:3];
    free(rgba);
    if (cropped) {
        NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:cropped]
                          representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        CGImageRelease(cropped);
        [png writeToFile:[path stringByAppendingString:@".png"] atomically:YES];
    }
    return [ppm writeToFile:path atomically:YES] ? nil : @"could not write the capture";
}

/* Run the main run loop until *DONE or SECONDS pass: ScreenCaptureKit
   answers on its own queue, and Emacs's main thread is waiting here. */
static void waitFor(volatile BOOL *done, double seconds)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!*done && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

/* The window's image by ScreenCaptureKit, retained, or NULL and *ERROR. */
static CGImageRef captureBySCK(NSWindow *window, NSString **error) API_AVAILABLE(macos(14.4))
{
    __block SCShareableContent *content = nil;
    __block NSError *failure = nil;
    __block volatile BOOL done = NO;
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:
        ^(SCShareableContent *found, NSError *problem) { content = found; failure = problem; done = YES; }];
    waitFor(&done, 5);
    if (!content) {
        *error = [NSString stringWithFormat:@"ScreenCaptureKit gave no content: %@",
                     failure.localizedDescription ?: @"timed out"];
        return NULL;
    }
    SCWindow *own = nil;
    for (SCWindow *candidate in content.windows)
        if (candidate.windowID == (CGWindowID)window.windowNumber) own = candidate;
    if (!own) {
        *error = [NSString stringWithFormat:@"ScreenCaptureKit lists %lu windows, not window %ld",
                     (unsigned long)content.windows.count, (long)window.windowNumber];
        return NULL;
    }
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:own];
    SCStreamConfiguration *configuration = [SCStreamConfiguration new];
    configuration.width = (size_t)round(own.frame.size.width * window.backingScaleFactor);
    configuration.height = (size_t)round(own.frame.size.height * window.backingScaleFactor);
    configuration.showsCursor = NO;
    configuration.ignoreShadowsSingleWindow = YES;
    __block CGImageRef image = NULL;
    done = NO;
    [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
                              completionHandler:^(CGImageRef found, NSError *problem) {
        if (found) image = CGImageRetain(found);
        failure = problem;
        done = YES;
    }];
    waitFor(&done, 5);
    if (!image)
        *error = [NSString stringWithFormat:@"ScreenCaptureKit took no screenshot: %@",
                     failure.localizedDescription ?: @"timed out"];
    return image;
}

/* The window's image by CGWindowListCreateImage, retained, or NULL. */
static CGImageRef captureByWindowList(NSWindow *window, NSString **error)
{
    typedef CGImageRef (*Create)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
    Create create = (Create)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (!create) { *error = @"CGWindowListCreateImage is not in this system"; return NULL; }
    CGImageRef image = create(CGRectNull, kCGWindowListOptionIncludingWindow,
                              (CGWindowID)window.windowNumber,
                              kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
    if (!image) *error = @"CGWindowListCreateImage returned no image";
    return image;
}

static emacs_value captureWindow(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[0], NULL, &size)) return env->intern(env, "nil");
    char *bytes = malloc((size_t)size);
    if (!bytes) return env->intern(env, "nil");
    if (!env->copy_string_contents(env, args[0], bytes, &size)) { free(bytes); return env->intern(env, "nil"); }
    NSString *path = [NSString stringWithUTF8String:bytes];
    free(bytes);
    NSString *error = nil, *method;
    NSWindow *window = emacsWindow();
    CGImageRef image = NULL;
    NSDate *start = NSDate.date;
    if (!window) {
        error = @"Emacs has no window";
    } else if (@available(macOS 14.4, *)) {
        method = @"ScreenCaptureKit";
        image = captureBySCK(window, &error);
    } else {
        method = @"CGWindowListCreateImage";
        image = captureByWindowList(window, &error);
    }
    CGRect crop = CGRectZero;
    if (image) {
        crop = contentCrop(window, image);
        error = writeImage(image, crop, path);
        CGImageRelease(image);
    }
    double seconds = -start.timeIntervalSinceNow;
    if (error) return env->make_string(env, error.UTF8String, (ptrdiff_t)strlen(error.UTF8String));
    emacs_value items[5] = {
        env->make_integer(env, (intmax_t)crop.size.width), env->make_integer(env, (intmax_t)crop.size.height),
        env->make_float(env, window.backingScaleFactor), env->make_float(env, seconds),
        env->make_string(env, method.UTF8String, (ptrdiff_t)strlen(method.UTF8String))};
    return env->funcall(env, env->intern(env, "list"), 5, items);
}

int emacs_module_init(struct emacs_runtime *runtime)
{
    emacs_env *env = runtime->get_environment(runtime);
    emacs_value args[] = {
        env->intern(env, "portal-test-capture-window"),
        env->make_function(env, 1, 1, captureWindow,
            "Write the key window's content as it is shown, at FILE as a PPM and FILE.png.\n"
            "Return (WIDTH HEIGHT SCALE SECONDS METHOD), or a string saying why it could not.", NULL)
    };
    env->funcall(env, env->intern(env, "fset"), 2, args);
    return 0;
}
