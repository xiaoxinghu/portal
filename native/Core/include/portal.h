/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The platform interface of Portal's Emacs module.

   The C core in native/Core is the module's portable part.  emacs.c
   registers the Lisp interface (docs/adr/0002), converts arguments and
   results, and signals errors.  views.c owns every Portal view's identity
   and lifecycle, input.c decides who gets each key press, terminals.c keeps
   the rules of terminal views, web.c those of web views and the bridge,
   shortcuts.c the system-wide shortcuts,
   status.c where the status panel goes, and channel.c owns the pipe that
   carries records to Emacs.
   The platform implements the operations below: the production module links
   the macOS backend, native/Backend.swift, and the core's tests link
   test/portal-fake-backend.c.  Nothing here knows about Emacs values or a UI
   toolkit.

   Every operation is a primitive (docs/adr/0003): something a platform must
   do, which the core cannot build from the others.  Portal's rules stay in
   the core, which the platform tells what happened with the calls at the
   end of this file.

   Threads: the core calls each operation synchronously, on the thread that
   runs the Emacs module call.  A backend may require a particular thread and
   fail otherwise; the macOS backend requires the main thread.  The platform
   calls into the core, below, only on that thread too.

   Borrowed data: a portal_string, and any array argument, belongs to the
   caller and is valid only until the call returns.  A portal_string is UTF-8
   with an explicit length, which may include NUL bytes; it is also
   NUL-terminated.  The callee copies whatever it keeps.

   Owned data: text an operation returns was allocated with malloc, and the
   core frees it.  It is valid UTF-8.  Structured results are JSON.

   Errors: an operation returns true on success.  On failure it returns false
   and sets *error to a message for a Lisp `error' signal, leaving its other
   outputs unset.

   Callbacks: none into Emacs.  Native work that outlives a call uses copies,
   and native notifications reach Emacs as records through the core's pipe, so
   no native code retains an Emacs environment or value.  The platform may
   call the core's functions at the end of this file whenever it runs on the
   module thread, with borrowed arguments, even from inside an operation the
   core called, except where a function says otherwise; they never reach
   Emacs.  The core in turn may call operations from inside those calls: a
   hosted app's link to a local file, for example, first gives Emacs the
   keyboard with portal_view_unfocus. */
#ifndef PORTAL_H
#define PORTAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Borrowed UTF-8. */
typedef struct portal_string {
    const char *data;
    size_t length;
} portal_string;

/* Owned UTF-8: DATA was allocated with malloc. */
typedef struct portal_text {
    char *data;
    size_t length;
} portal_text;

/* One entry of portal--open's options plist, such as :directory "~/" or
   :quick t.  Entries keep the plist's order; a later duplicate name wins. */
typedef struct portal_option {
    portal_string name; /* Without the leading colon. */
    bool is_string;
    portal_string string; /* When IS_STRING. */
    bool flag;            /* Otherwise: true for t, false for nil. */
} portal_option;

/* A rectangle in a frame, in Emacs's frame pixels, as
   `window-inside-pixel-edges' measures them: the origin is the top left of
   the frame's native content area, and y grows downward.  WIDTH and HEIGHT
   are positive, and every value fits in 32 bits.  The platform converts it
   to its own coordinates and scale; on macOS, Emacs's pixels are AppKit
   points, so only the y axis flips.  Screens and the status panel use the
   same type on another plane; see portal_screens. */
typedef struct portal_rect {
    int64_t x, y, width, height;
} portal_rect;

/* One dedicated launcher frame, independent of the Portal view registry.
   Attach moves a new hidden Emacs frame's content into a platform panel; it
   refuses a second attachment. The caller checks the supported Emacs build
   first and MUST detach before Emacs deletes the frame. Detach and hide are
   idempotent. Show uses logical points, centered in the pointer screen's usable
   area (SCREEN=-1), or the current screen index; a missing index falls back to
   the pointer. WIDTH is at least 200 and HEIGHT positive: the caller chooses a
   height its Emacs frame can legally have. Positive DX/DY mean right/down. The
   platform clamps to the screen, and reapplies placement when displays change.
   Describe returns JSON.
   No environment, Lisp value, or Portal view target is retained here. */
bool portal_launcher_attach(portal_string title, portal_text *error);
/* Capture the frontmost application BEFORE creating/selecting an Emacs frame.
   Repeated preparation while presented retains the original application. */
bool portal_launcher_prepare(portal_text *error);
bool portal_launcher_show(int64_t width, int64_t height, int64_t dx, int64_t dy,
                          int64_t screen, bool shadow, int64_t radius, portal_text *error);
/* Layout only, never presentation: resize the panel of presentation SESSION
   (the counter Describe reports as "session") to positive HEIGHT logical
   points, chosen as for Show. Its screen, left edge, width and top edge stay;
   the bottom edge is clamped to that screen's usable area. The session, focus
   and first responder are unchanged. A stale SESSION, a hidden panel or an
   unchanged rectangle does nothing. A display change centers the fitted height
   again, and later fits keep that new top edge. */
bool portal_launcher_fit(uint64_t session, int64_t height, portal_text *error);
/* RESTORE_FOCUS requests cancellation focus restoration, only while the panel
   still owns the keyboard. Success and click-away hide without activation. */
bool portal_launcher_hide(bool restore_focus, portal_text *error);
bool portal_launcher_detach(portal_text *error);
bool portal_launcher_describe(portal_text *state, portal_text *error);

/* A view kind (CONTEXT.md). */
typedef enum portal_kind { PORTAL_WEB, PORTAL_TERMINAL } portal_kind;

/* A native view, opaque to the core. */
typedef struct portal_view portal_view;

/* Native views.  The core owns every view from create to destroy, and never
   passes a view to the platform after destroying it: it resolves each Lisp
   target to its view, checks the view's kind, and keeps the bookkeeping that
   every kind shares: its identity, whether it is attached, and where.  Each
   primitive either does all it says or, on failure, changes nothing.  Only
   create and attach fail for reasons of their own; any primitive fails when
   the platform cannot run it at all, such as on the wrong thread.

   Create a view of KIND from OPTIONS, detached, with its page or session
   running.  TARGET, such as "web:3", names it in the records it sends; it is
   never reused.  On failure, the platform has already released anything it
   made.  Destroying VIEW ends its page or session, wherever it is; the core
   destroys each view once, when Lisp closes it. */
bool portal_view_create(portal_kind kind, portal_string target, const portal_option *options,
                        size_t count, portal_view **view, portal_text *error);
bool portal_view_destroy(portal_view *view, portal_text *error);
/* Attach VIEW to the frame whose title is FRAME now, at RECT.  The title is
   temporary and unique (docs/adr/0002), so a platform finds the frame again on
   every call and keeps nothing that could go stale.  VIEW may be detached or
   attached to this or another frame; it moves in one step, keeping its page
   or session.  A failed attach, such as for a frame that is gone, leaves VIEW
   where it was. */
bool portal_view_attach(portal_view *view, portal_string frame, portal_rect rect,
                        portal_text *error);
/* Detach an attached VIEW, keeping its page or session and its last size.
   Where a detached view lives is the platform's business: macOS parks it in
   an offscreen window. */
bool portal_view_detach(portal_view *view, portal_text *error);
/* Describe VIEW as a JSON object of flags, integers, integer arrays and
   strings: only what the platform alone knows, such as a page's title or a
   terminal's grid.  The core adds the view's "id", "kind", "visible" and
   "edges", so the platform never reports those. */
bool portal_view_describe(portal_view *view, portal_text *state, portal_text *error);

/* Web views.  The core decides what a web view loads and how, where its page
   may navigate, and which messages cross the bridge (native/Core/web.c); the
   platform loads pages, delivers messages, and reports what pages do through
   the calls into the core below.  A page's URL, title, loading state and
   errors come from portal_view_describe.

   A web view's options, passed to portal_view_create, are :hosted, a flag
   or a string, for a hosted app, whose view keeps no data between sessions
   and runs the bridge and the links script; and :appearance, which the core
   has checked is "light", "dark" or false, starting the view in that
   portal_appearance, below: false for the system's.  The platform ignores
   any other option.

   Load URL in WEB as a new document, adding it to WEB's history.  The core
   has checked that URL is an absolute http, https, file, data or about URL,
   and passes it as portal_web_parse_url spelled it.  A file URL may read the
   other files in its directory. */
bool portal_web_load(portal_view *web, portal_string url, portal_text *error);
/* Parse URL as this platform's web views do, and return in *PARSED how the
   platform spells the result, as it spells the URLs it reports to the core:
   characters such as spaces percent-encoded, and the host and port as
   parsed, such as a Unicode host in punycode, example.com for %65xample.com
   and 80 for 080.  The core keeps and compares URLs only in this
   spelling, so one parser, the platform's, decides when two are the same.
   Fails for a URL the platform cannot parse. */
bool portal_web_parse_url(portal_string url, portal_text *parsed, portal_text *error);
/* A step through a web view's history. */
typedef enum portal_history { PORTAL_BACK, PORTAL_FORWARD, PORTAL_RELOAD } portal_history;
/* Go back or forward in WEB's history, doing nothing where there is no page
   to go to, or load its page again without a new history entry. */
bool portal_web_go(portal_view *web, portal_history step, portal_text *error);
/* Pass JSON, which must be a JSON object, to the page in WEB, as the argument
   of its portalBridge.receive (docs/editor-bridge.md).  The argument crosses
   as data, never as script text.  Delivery finishes after this call returns;
   if it fails, such as when the page defines no receive function, call
   portal_web_failed with TOKEN.  Fails at once, changing nothing, for JSON
   that is not an object. */
bool portal_web_post(portal_view *web, portal_string json, uint64_t token, portal_text *error);
/* The appearance a web view's pages see, as CSS's prefers-color-scheme and
   the colors of their controls: the system's, following its changes, or
   always light or dark.  The system's is the user's own setting, whatever the
   window around the view shows: on macOS, an Emacs frame may force its own. */
typedef enum portal_appearance {
    PORTAL_APPEARANCE_SYSTEM,
    PORTAL_APPEARANCE_LIGHT,
    PORTAL_APPEARANCE_DARK,
} portal_appearance;
/* Show WEB's pages in APPEARANCE from now on, including the page on screen,
   without loading it again. */
bool portal_web_set_appearance(portal_view *web, portal_appearance appearance,
                               portal_text *error);
/* Create a web view, detached, for the window the page in OPENER asked for
   with portal_web_window, below, passing REQUEST through.  The platform
   makes it from REQUEST, as its toolkit may require: on macOS, WebKit's
   configuration for the window, which keeps OPENER's data store and gives
   the new page its opener.  The new view starts in OPENER's appearance,
   and loads what the page asked for by itself.  TARGET names it, as for
   portal_view_create, and it is the core's to destroy in the same way. */
bool portal_web_create_window(portal_view *opener, portal_string target, void *request,
                              portal_view **view, portal_text *error);

/* Terminal views.  The core implements the terminal Lisp functions with
   these primitives, each on one terminal, and keeps Portal's rules: it checks
   a terminal's options before creating it, and a theme's name against
   portal_terminal_list_themes before applying it to any terminal.  A
   terminal's options, passed to portal_view_create, are :directory, the
   working directory, a string; :command, a shell command line to run instead
   of the login shell, a string or false; :argv, a JSON array containing a
   program name or path and literal arguments to run through the user's
   interactive login shell, a string or false, mutually exclusive with
   :command; :theme, a name the platform lists, or false for the default;
   and :quick, a flag. The shell loads startup files and resolves the program;
   no Lisp environment snapshot is passed to the platform.  A terminal starts
   at PORTAL_TERMINAL_POINTS.

   A terminal describes itself with "ready", whether its engine can draw and
   take input; "title", which the running program may set, "" until it does;
   "pwd", the working directory the running program last reported from this
   host, "" until it does; "columns" and "rows", its grid, 0 until known; and
   "exited", whether its process has ended.  Report each change of title,
   working directory or exit with portal_terminal_changed, below.  A process
   that exits leaves its view open, showing its last output, until Lisp
   closes it; destroying a view ends its process.  Any other fact a platform
   describes, such as macOS's "layer", the class of the renderer's layer, is
   a diagnostic for tests.

   List the names of the themes the terminal engine offers, in any order:
   *NAMES is an array of *COUNT texts, allocated with malloc like each text,
   and the core frees them all. */
bool portal_terminal_list_themes(portal_text **names, size_t *count, portal_text *error);
/* Apply the theme NAME, which the platform listed, or the default theme for a
   null NAME, to TERMINAL.  The default may follow the system's appearance. */
bool portal_terminal_apply_theme(portal_view *terminal, const portal_string *name,
                                 portal_text *error);
/* Paste TEXT as the user's paste, bracketed if the running program asked. */
bool portal_terminal_paste_text(portal_view *terminal, portal_string text, portal_text *error);
/* Press and release the Enter key. */
bool portal_terminal_press_enter(portal_view *terminal, portal_text *error);
/* Read all of TERMINAL's text, its scrollback and screen.  macOS reads it by
   selecting everything, and leaves that selection active. */
bool portal_terminal_read_text(portal_view *terminal, portal_text *text, portal_text *error);
/* The font size a terminal starts at, in points. */
enum { PORTAL_TERMINAL_POINTS = 14 };

/* Input, for a view of any kind.  The core decides what each key press in a
   view does (native/Core/input.c): the view's app gets it, one of the view's
   shortcuts runs, or it starts a handoff, in which Emacs reads and runs a
   command (docs/terminal-input-bridge.md).  The platform captures keys,
   moves the keyboard, and keeps the native events: the core sees only
   portal_chord values, never replays them.

   Give VIEW the keyboard, if it is attached; or, if VIEW has the keyboard,
   return it to Emacs.  Either reports what changed with portal_input_focus
   before it returns, so the core knows the result. */
bool portal_view_focus(portal_view *view, portal_text *error);
bool portal_view_unfocus(portal_view *view, portal_text *error);
/* The key events VIEW holds, from a press the core answered
   PORTAL_KEY_HOLD (below): that press, its trigger, and the events after it.
   With REPLAY, deliver the events after the trigger again, in order, ahead
   of any new ones, as if they had just happened, and stop holding them; VIEW
   keeps its trigger.  Without, discard them all, trigger included.  Holding
   nothing, either does nothing. */
bool portal_view_replay(portal_view *view, bool replay, portal_text *error);
/* Deliver VIEW's trigger to the app, as a real press and release of that
   key where VIEW's keyboard input goes.  The core gives VIEW the keyboard
   first.  Fails if VIEW holds no trigger. */
bool portal_view_literal(portal_view *view, portal_text *error);
/* Copy what is selected in VIEW's app to the system clipboard, as the app's
   own Copy command does; with nothing selected, do nothing.  Paste the
   system clipboard where VIEW's keyboard input goes, as the app's own Paste
   command does: a terminal pastes text, bracketed if its program asked. */
bool portal_view_copy(portal_view *view, portal_text *error);
bool portal_view_paste(portal_view *view, portal_text *error);

/* Timers, implemented by the platform.  Call portal_timer_fired(TOKEN) once,
   from the platform's event loop on the module thread, no sooner than
   MILLISECONDS from now; never from inside this call.  A timer cannot fail
   and is never cancelled: the core cancels one by ignoring its token when it
   fires.  The core chooses TOKEN, which is never 0 and never reused. */
void portal_timer_start(uint64_t token, uint64_t milliseconds);

/* System-wide hot keys, for the core's shortcuts (shortcuts.h).  KEY is a
   physical key, by its position on a US keyboard whatever the input source:
   an uppercase letter 'A' to 'Z', a digit '0' to '9', ' ' for Space,
   PORTAL_ESCAPE_KEY, or PORTAL_FUNCTION_KEY + N for function key FN, N from
   1 to 20.  MODIFIERS are the portal_modifier bits held with it, exactly,
   and include Control, Meta or Super unless KEY is Escape.  Register fails,
   saying why, when the system or another application has the chord; the core never registers one chord under two
   hot keys.  HOTKEY is the core's name for the registration, never 0 and
   never given to another one, which the platform reports presses and
   releases with.  Registering HOTKEY again with its own chord restarts it:
   the platform keeps the chord, and reports nothing that happened before,
   such as a press still waiting in the system's queue.  Once unregister
   returns, the platform reports nothing more for HOTKEY. */
enum { PORTAL_ESCAPE_KEY = 0x1b, PORTAL_FUNCTION_KEY = 0x100 };
bool portal_hotkey_register(uint64_t hotkey, uint32_t key, uint32_t modifiers,
                            portal_text *error);
bool portal_hotkey_unregister(uint64_t hotkey, portal_text *error);

/* Press and release KEY with exactly MODIFIERS, the portal_modifier bits, in
   whatever application is frontmost, which may be Emacs: keys or modifiers
   the user still holds do not join the chord.  KEY is as for
   portal_hotkey_register, but a letter or digit names a character, not a
   position on a US keyboard: the key that types it, ignoring case, in the
   current keyboard layout, with Command held when MODIFIERS include Super,
   as an application matching the chord to its shortcuts reads it.  Finding
   that key is the platform's job.  Fails, posting nothing, when no key
   types the character, or when the system would drop the events, as macOS
   does without Accessibility permission; asking the user for a permission
   then is the platform's business too.  The events are only posted: the
   application handles them after this returns, or ignores them. */
bool portal_key_post(uint32_t key, uint32_t modifiers, portal_text *error);

/* The screens, for the core's status panel (status.h).  Each screen's AREA
   is the part windows may use, without menu bars or docks, in logical points
   on one plane for all screens: the origin is the top left of the primary
   screen, the one with the menu bar, and y grows downward.  The primary
   screen comes first, and exactly one screen, the one under the pointer, has
   POINTER set.  *SCREENS was allocated with malloc and the core frees it;
   *COUNT is at least 1. */
typedef struct portal_screen {
    portal_rect area;
    bool pointer;
} portal_screen;
bool portal_screens(portal_screen **screens, size_t *count, portal_text *error);

/* What a status means, which decides how the platform marks it: an icon or a
   color, and for PROGRESS and RECORDING an animation, such as a spinner and
   a red dot that breathes.  NEUTRAL has no mark. */
typedef enum portal_status_tone {
    PORTAL_STATUS_NEUTRAL,
    PORTAL_STATUS_PROGRESS,
    PORTAL_STATUS_SUCCESS,
    PORTAL_STATUS_WARNING,
    PORTAL_STATUS_ERROR,
    PORTAL_STATUS_RECORDING
} portal_status_tone;

/* The status panel: one small panel, above every application's windows and
   on every Space, that shows TEXT, such as what a command running in the
   background is doing.  The core decides its rectangle; how it looks inside
   it is the platform's.  The panel never takes the keyboard or the mouse:
   showing it changes neither the frontmost application nor where keys go.

   Measure sets *WIDTH and *HEIGHT to the size of a panel at most WIDTH wide,
   both positive, showing TEXT with TONE: as narrow as fits the text, wrapped
   to at most LINES lines, the last cut short if needed.  WIDTH and LINES are
   positive.  Show displays TEXT with TONE in RECT, a rectangle on the plane
   of portal_screens, wrapped to at most LINES lines and centered vertically,
   replacing what the panel showed, and shows the panel if hidden.  Hide hides
   it, and does nothing when it is hidden. */
bool portal_status_measure(portal_string text, portal_status_tone tone, int64_t width,
                           int64_t lines, int64_t *fitted_width, int64_t *height,
                           portal_text *error);
bool portal_status_show(portal_string text, portal_status_tone tone, portal_rect rect,
                        int64_t lines, portal_text *error);
bool portal_status_hide(portal_text *error);

/* Calls into the core, implemented by the core for the platform. */

/* Send Emacs the record "TYPE TARGET FIELD...", one line of COUNT + 2 words
   joined by spaces.  Each word is nonempty printable ASCII without spaces,
   and the line, with its newline, is at most PIPE_BUF bytes, so each write
   of it is atomic.  Records reach Emacs in the order they are sent: while
   the pipe is full or disconnected, a record waits with those sent after it
   and none is lost.  Returns false only for a record that will never be sent:
   malformed, too long, with no memory to hold it while it waits, or for a
   TARGET that names no open view, before create returns or once Lisp has
   closed it.  Payloads that may be longer stay with the platform, which
   announces them here. */
bool portal_notify(portal_string type, portal_string target, const portal_string *fields,
                   size_t count);
/* The panel lost key status. Record: "launcher-blur SESSION". */
bool portal_launcher_blurred(uint64_t session);
/* A timer from portal_timer_start has fired. */
void portal_timer_fired(uint64_t token);
/* The user pressed HOTKEY's chord, or released it, in any application.
   Report only what happened after HOTKEY was registered.  A press may repeat
   while the chord is held. */
void portal_hotkey_pressed(uint64_t hotkey);
void portal_hotkey_released(uint64_t hotkey);

/* What TARGET's terminal describes changed: its title, its working
   directory or whether it exited.  The core tells Emacs with a "terminal TARGET" record,
   and sends no other for that view until Emacs has inspected it, so a
   program that retitles itself constantly never floods the pipe.  The core
   ignores a call for a target that names no open terminal. */
void portal_terminal_changed(portal_string target);

/* Modifier keys, as Emacs names them.  Which keys are Meta and Super is the
   platform's business: on macOS, Option and Command. */
typedef enum portal_modifier {
    PORTAL_SHIFT = 1 << 0,
    PORTAL_CONTROL = 1 << 1,
    PORTAL_META = 1 << 2,
    PORTAL_SUPER = 1 << 3,
} portal_modifier;

/* A key press: CHARACTER, the Unicode code point the key types with Shift
   but no other modifier, such as 'b' for Control-B and '!' for Shift-1 on a
   US layout, or 0 for a key that types no single character; and the
   portal_modifier bits held.  The core ignores other bits, case, and Shift
   on a character Shift already made. */
typedef struct portal_chord {
    uint32_t character;
    uint32_t modifiers;
} portal_chord;

/* Whether CHORD is the configured return-to-Emacs key (Super-period by
   default). Check key-downs before holding or offering events, including
   during a handoff. On a match return focus and report portal_input_focus
   even if already unfocused, so the handoff ends without waiting for Lisp
   or the app. Releases and modifier changes never trigger escape. */
bool portal_input_is_escape(portal_chord chord);

/* What the platform does with a key press.  PASS: deliver it as it would
   without Portal.  TAKE: drop it.  HOLD: keep it as the view's trigger, and
   hold every key event after it in the view's window, in order, presses,
   repeats, releases and modifier changes alike, without asking the core,
   until portal_view_replay.  While a view holds a trigger, the key events in
   its window are its own, whichever view has the keyboard: the platform asks
   the core about each press there.

   OFFER: deliver it to the view's app, and hold every key event after it in
   the view's window, as for HOLD, until the app has handled it.  Only a web
   view's app is offered keys, as only its page knows whether it uses one.
   If the app used the press, deliver the held events again, in order, ahead
   of any new ones, as if they had just happened.  If not, call
   portal_input_unused with the press, and do what it answers.  An app that
   never answers, such as a page that stopped responding, used the press. */
typedef enum portal_key {
    PORTAL_KEY_PASS,
    PORTAL_KEY_TAKE,
    PORTAL_KEY_HOLD,
    PORTAL_KEY_OFFER,
} portal_key;

/* CHORD was pressed, or REPEAT-ed, in TARGET's view: the view has the
   keyboard, or holds a trigger in the window where the key was pressed.
   Press and repeat only: a release or a modifier change never needs the
   core.  TIME is when the key was pressed, in milliseconds on a clock that
   never goes back, such as the time since the system started: the event's
   own time, not when the platform got to it.  The core may return the
   keyboard to Emacs before answering TAKE, as for a second Escape typed
   quickly (portal-input-double-escape). */
portal_key portal_input_key(portal_string target, portal_chord chord, bool repeat, uint64_t time);
/* The app of TARGET's view did not use CHORD, a press or REPEAT the core
   answered PORTAL_KEY_OFFER.  The answer is TAKE: drop the press, and
   deliver what was held after it as for a press the app used; or HOLD: the
   press is now the view's trigger, and the events held after it stay held
   as for PORTAL_KEY_HOLD. */
portal_key portal_input_unused(portal_string target, portal_chord chord, bool repeat);

/* TARGET's view gained or lost the keyboard.  Report each change, whatever
   made it; one the platform makes for the core, before that call returns.
   Report the user moving the keyboard too, before anything changes: a click
   that will give the view the keyboard, and the platform's own way back to
   Emacs, the configured escape chord, which returns the keyboard without
   waiting for a handoff, even when the view does not have it.  A report that neither
   Emacs nor the core caused abandons the view's handoff. */
void portal_input_focus(portal_string target, bool focused);

/* Web views call these for what their pages do.  TARGET is the view's
   target, as portal_view_create received it; the core ignores a call for a
   target that names no open web view, such as one Lisp has closed, so an
   asynchronous completion can never reach a closed or newer view.

   What the platform observed natively about the frame that posted a message:
   whether it is the page's main frame, and the URL of the document in it.  A
   page's own claims, such as an origin it puts in a message, are not
   evidence. */
typedef struct portal_sender {
    bool main_frame;
    portal_string url;
} portal_sender;
/* The page in TARGET posted JSON, a JSON object the platform has checked,
   whose "type" member is TYPE, or "" when it has none or it is not a string.
   The core keeps it for Emacs only from a hosted app's main frame, showing
   the URL Emacs loaded last, spelled as portal_web_parse_url spells it,
   and never with a type the core itself sends. */
void portal_web_posted(portal_string target, portal_sender sender, portal_string type,
                       portal_string json);
/* What a web view does with a navigation its page asks for. */
typedef enum portal_navigation {
    PORTAL_NAVIGATION_ALLOW,    /* Load URL in the view. */
    PORTAL_NAVIGATION_EXTERNAL, /* Cancel, and open URL in the default browser. */
    PORTAL_NAVIGATION_EMACS,    /* Cancel: the core has handed URL to Emacs. */
} portal_navigation;
/* The page in TARGET asks to navigate to URL, in its main frame or, when
   MAIN_FRAME is false, in another frame.  A request for a new window counts
   as the main frame.  Call it for each navigation the platform can refuse,
   and for each click on a link that the platform cannot follow at all, such
   as a hosted app's links to local files, which the shared links script
   reports (portal_web_links_script); for those, allow means load URL. */
portal_navigation portal_web_navigating(portal_string target, portal_string url,
                                        bool main_frame);
/* The page in TARGET asks for a new window, as window.open and links to
   target=_blank do, once portal_web_navigating has allowed its URL.  The
   core opens a web view for it with portal_web_create_window, passing
   REQUEST through, and returns whether it did; the platform then gives the
   page that view.  A hosted app opens no windows.  Emacs hears of the view
   with an "opened NEW TARGET" record, NEW being the view's target, and
   gives it a buffer. */
bool portal_web_window(portal_string target, void *request);
/* The page in TARGET closed its window, as window.close does.  When TARGET
   is a window a page opened, the core tells Emacs with a "closed TARGET"
   record, and Emacs closes the view; it ignores any other view. */
void portal_web_closed(portal_string target);
/* The page in TARGET committed URL: a new document, or one from its history. */
void portal_web_committed(portal_string target, portal_string url);
/* Something failed that the page cannot report: a load of TARGET's page, its
   web process, or, when TOKEN is not 0, the delivery of the message that
   portal_web_post sent with TOKEN.  MESSAGE says what, for the app's buffer;
   a delivery to a page that has since gone is ignored. */
void portal_web_failed(portal_string target, uint64_t token, portal_string message);
/* The browser script that every platform's hosted web views share.  The
   core owns its source, embedded when it is compiled from
   native/Core/scripts, so a platform needs no files at run time and no app
   host.  It is one JavaScript function expression taking REPORT, a function
   it calls with a value for the platform.  The platform starts it in its own
   isolated world, out of the page's reach, as "(SOURCE)(REPORT)" with REPORT
   its transport to a native handler.

   Links: in a hosted app's main frame from the start of each document,
   reports the URL of each link to a local file the user clicks, which a page
   from the app host could not follow.  Treat each as portal_web_navigating
   asks. */
portal_string portal_web_links_script(void);

#endif
