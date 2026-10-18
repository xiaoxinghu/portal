// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore

extension portal_chord {
    /// EVENT's key as the core sees it: the character it types with Shift but
    /// no other modifier, and Portal's modifiers. Option is Meta, Command Super.
    /// A key that types no character, such as an arrow, whose character AppKit
    /// gives from the private-use range, is 0.
    @MainActor init(_ event: NSEvent) {
        let scalars = (event.charactersIgnoringModifiers ?? "").unicodeScalars
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        for (flag, modifier) in [(NSEvent.ModifierFlags.shift, PORTAL_SHIFT), (.control, PORTAL_CONTROL),
                                 (.option, PORTAL_META), (.command, PORTAL_SUPER)] where flags.contains(flag) {
            modifiers |= modifier.rawValue
        }
        let character = scalars.count == 1 ? scalars.first!.value : 0
        self.init(character: (0xF700...0xF8FF).contains(character) ? 0 : character, modifiers: modifiers)
    }
}

/// One view's native input, for Ghostty and WebKit alike. The core decides
/// what each key press does (native/Core/input.c); this keeps the native
/// events it holds, replays them, offers a press to the view's app when the
/// core says so, and tells the core when the view gains or loses the keyboard.
@MainActor
final class NativeInput: NativeInputHandler {
    let target: String
    weak var view: NSView?
    var host: NativeHost
    let focusView: () -> Bool
    /// Deliver a press the core offers to the view's app, which answers with
    /// `settle`. Only web views have apps that are offered keys.
    var offer: ((NSEvent) -> Void)?
    /// The key press that started Emacs's handoff, until the core discards
    /// it, or the press offered to the app, until the app answers. While it
    /// is held, key events in its window are this view's.
    private(set) var trigger: NSEvent?
    /// Whether the trigger is a press offered to the app.
    private var offering = false
    /// The key events after the trigger, until the core replays them or the
    /// app answers.
    private var held: [NSEvent]?
    /// Whether the core was last told the view has the keyboard.
    private var reported = false
    /// Whether `focus` is giving the view the keyboard.
    private var focusing = false

    /// Whether the view may take the keyboard: it has it, as far as the core
    /// knows, or Emacs, the core or the user is giving it to it. Nothing else
    /// moves it (`portal_input_focus`), so a view refuses other requests,
    /// such as a page's.
    var mayTakeKeyboard: Bool { focusing || reported }

    init(target: String, view: NSView, host: NativeHost, focus: @escaping () -> Bool) {
        self.target = target
        self.view = view
        self.host = host
        focusView = focus
    }

    /// Return to Emacs, as the configured escape does, ending any handoff Emacs is
    /// handling: Emacs would otherwise read the next event as its next key.
    func escape() {
        if let view { host.returnFocus(from: view) }
        report(false)
    }

    /// The user is giving the view the keyboard, as a click does.
    func claim() { report(true) }

    /// Tell the core whether the view has the keyboard, when that changed.
    func observe() {
        let focused = view.map { host.ownsFocus($0) } ?? false
        if focused != reported { report(focused) }
    }

    private func report(_ focused: Bool) {
        reported = focused
        Core.focus(target, focused)
    }

    /// What to do with EVENT, a key event in the view's window: true if this
    /// took it.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Recovery must work even before Lisp acknowledges, without a JS flush.
        if event.type == .keyDown, portal_input_is_escape(portal_chord(event)) {
            escape()
            return true
        }
        // The app hands back an offered press it did not use.
        if offering, event === trigger {
            settle(event, used: false)
            return true
        }
        if held != nil {
            held?.append(event)
            return true
        }
        guard event.type == .keyDown else { return false }
        switch Core.key(target, event) {
        case PORTAL_KEY_HOLD:
            if trigger == nil {
                trigger = event
                held = []
            } else {
                held?.append(event)
            }
            return true
        case PORTAL_KEY_TAKE: return true
        case PORTAL_KEY_OFFER:
            guard let offer else { return false }
            trigger = event
            held = []
            offering = true
            offer(event)
            return true
        default: return false
        }
    }

    /// The app has handled EVENT, the press offered to it: it USED it, or the
    /// core decides what happens to it. An answer for another press, or a
    /// second answer, does nothing.
    func settle(_ event: NSEvent, used: Bool) {
        guard offering, event === trigger else { return }
        offering = false
        NativeHost.delivered(event)
        if !used, Core.unused(target, event) == PORTAL_KEY_HOLD { return }
        trigger = nil
        replay()
    }

    // The primitives of native/Core/include/portal.h.

    /// Keys go to the key window's first responder: the view's window must
    /// take the keyboard too, from another window of Emacs's, such as a child
    /// frame's, that may hold it.
    func focus() {
        focusing = true
        defer { focusing = false }
        if focusView(), let window = view?.window, !window.isKeyWindow { window.makeKey() }
        host.refreshOwnership()
    }

    func unfocus() {
        if let view { host.returnFocus(from: view) }
    }

    func replay() {
        let events = held ?? []
        held = nil
        for event in events.reversed() { NSApp.postEvent(event, atStart: true) }
    }

    func discard() {
        trigger = nil
        offering = false
        held = nil
    }

    func literal() throws {
        guard let down = trigger, let view, let window = view.window,
              let up = NSEvent.keyEvent(with: .keyUp, location: down.locationInWindow,
                modifierFlags: down.modifierFlags, timestamp: down.timestamp,
                windowNumber: window.windowNumber, context: nil, characters: down.characters ?? "",
                charactersIgnoringModifiers: down.charactersIgnoringModifiers ?? "",
                isARepeat: false, keyCode: down.keyCode) else {
            throw NativeError.message("No captured prefix key to send")
        }
        // Deliver the matched pair to the actual native content responder.
        // NSWindow's key-up bookkeeping did not see the captured key-down.
        NativeHost.deliverLiteral(down, up: up, in: view)
    }
}
