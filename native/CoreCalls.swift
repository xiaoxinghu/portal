// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore

// Calls between Swift and the C core outside the Lisp operations: the core's
// notification pipe, input, what web pages do, terminal changes, hot key
// presses, the shared links script, and the timer primitive, all in
// native/Core/include/portal.h. The standalone
// checks compile this file too.

extension String {
    /// A copy of borrowed UTF-8 from the core.
    init(copying string: portal_string) {
        self.init(decoding: UnsafeRawBufferPointer(start: string.data, count: string.length), as: UTF8.self)
    }
}

/// Call BODY with each of STRINGS borrowed as a `portal_string`.
private func borrowing<T>(_ strings: [String], _ body: ([portal_string]) -> T) -> T {
    var bytes: [CChar] = []
    var spans: [(start: Int, length: Int)] = []
    for string in strings {
        spans.append((bytes.count, string.utf8.count))
        bytes += string.utf8CString
    }
    return bytes.withUnsafeBufferPointer { bytes in
        body(spans.map { portal_string(data: bytes.baseAddress! + $0.start, length: $0.length) })
    }
}

/// The C core, as Swift features call it.
@MainActor
enum Core {
    /// Send Emacs the record `TYPE TARGET FIELD...` through the core's pipe,
    /// which delivers records in order and waits while the pipe is full or
    /// disconnected. Returns false only for a record that can never be sent.
    @discardableResult
    static func notify(_ type: String, target: String, fields: [String] = []) -> Bool {
        borrowing([type, target] + fields) { words in
            words.withUnsafeBufferPointer { portal_notify($0[0], $0[1], $0.baseAddress! + 2, fields.count) }
        }
    }

    static func hotkeyPressed(_ hotkey: UInt64) {
        portal_hotkey_pressed(hotkey)
    }

    static func hotkeyReleased(_ hotkey: UInt64) {
        portal_hotkey_released(hotkey)
    }

    static func launcherBlurred(session: UInt64) {
        portal_launcher_blurred(session)
    }

    /// What the core answers when a page asks to navigate.
    enum Navigation { case allow, external, emacs }

    /// The page in TARGET posted JSON, a JSON object whose "type" is TYPE,
    /// from its main frame or another, showing URL, as WebKit reports them.
    static func posted(_ target: String, mainFrame: Bool, url: String, type: String, json: String) {
        borrowing([target, url, type, json]) {
            portal_web_posted($0[0], portal_sender(main_frame: mainFrame, url: $0[1]), $0[2], $0[3])
        }
    }

    /// What to do with EVENT, a key press in TARGET's view or its window, at
    /// the time it was pressed: a replayed event keeps its own.
    static func key(_ target: String, _ event: NSEvent) -> portal_key {
        let chord = portal_chord(event)
        let time = UInt64(max(event.timestamp, 0) * 1000)
        return borrow(target) { portal_input_key($0, chord, event.isARepeat, time) }
    }

    /// The app of TARGET's view did not use EVENT, a press the core offered it.
    static func unused(_ target: String, _ event: NSEvent) -> portal_key {
        let chord = portal_chord(event)
        return borrow(target) { portal_input_unused($0, chord, event.isARepeat) }
    }

    /// TARGET's view gained or lost the keyboard.
    static func focus(_ target: String, _ focused: Bool) {
        borrow(target) { portal_input_focus($0, focused) }
    }

    private static func borrow<T>(_ text: String, _ body: (portal_string) -> T) -> T {
        text.withCString { body(portal_string(data: $0, length: text.utf8.count)) }
    }

    static func navigating(_ target: String, url: String, mainFrame: Bool) -> Navigation {
        let decision = borrowing([target, url]) { portal_web_navigating($0[0], $0[1], mainFrame) }
        return decision == PORTAL_NAVIGATION_EXTERNAL ? .external
            : decision == PORTAL_NAVIGATION_EMACS ? .emacs : .allow
    }

    /// The page in TARGET asks for a new window: whether the core opened a
    /// view for it, from REQUEST, which the core passes back to the platform.
    static func window(_ target: String, request: AnyObject) -> Bool {
        borrow(target) { portal_web_window($0, Unmanaged.passUnretained(request).toOpaque()) }
    }

    static func closed(_ target: String) {
        borrow(target) { portal_web_closed($0) }
    }

    static func committed(_ target: String, url: String) {
        borrowing([target, url]) { portal_web_committed($0[0], $0[1]) }
    }

    /// TOKEN is 0 for a failure of the page itself, or a post's token.
    static func failed(_ target: String, token: UInt64, message: String) {
        borrowing([target, message]) { portal_web_failed($0[0], token, $0[1]) }
    }

    /// What TARGET's terminal describes changed.
    static func terminalChanged(_ target: String) {
        borrow(target) { portal_terminal_changed($0) }
    }

    /// The shared links script, started in its world with a report function
    /// that posts to that world's script message HANDLER. This glue is the
    /// only part that names WebKit's transport.
    static func linksScript(handler: String) -> String {
        "(\n\(String(copying: portal_web_links_script()))\n)((value) => window.webkit.messageHandlers.\(handler).postMessage(value));\n"
    }
}

/// Call the core back from the main run loop, Emacs's thread.
@_cdecl("portal_timer_start")
public func portalTimerStart(_ token: UInt64, _ milliseconds: UInt64) {
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds))) {
        portal_timer_fired(token)
    }
}
