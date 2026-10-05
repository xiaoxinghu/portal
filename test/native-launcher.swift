// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// These stand in for the validated port's ObjC selectors. The GUI suite uses
// the real EmacsView; here attachment failure and display arrangements can be
// driven deterministically without reaching into a private Emacs frame struct.
@objc(EmacsView)
final class LauncherTestEditor: NSView, NSWindowDelegate {
    var acceptsFocus = true
    override var acceptsFirstResponder: Bool { acceptsFocus }
    override func becomeFirstResponder() -> Bool { acceptsFocus }
}

@objc(EmacsWindow)
final class LauncherTestWindow: NSWindow {
    @objc(setAppearance) func emacsAppearance() { appearance = NSAppearance(named: .darkAqua) }
}

@main
struct LauncherChecks {
    @MainActor static func main() {
        runChecks {
            _ = NSApplication.shared
            // The same C notification pipe used by Emacs, with no Portal views.
            var descriptors: [Int32] = [0, 0]
            check(pipe(&descriptors) == 0)
            check(fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0)
            check(portal_channel_connect(descriptors[1]))
            defer { portal_channel_connect(-1); close(descriptors[0]) }
            func records() -> String {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(descriptors[0], &bytes, bytes.count)
                return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
            }
            func placement(_ width: Int64 = 713, _ height: Int64 = 407,
                           _ dx: Int64 = 0, _ dy: Int64 = 0) -> NativeLauncher.Placement {
                .init(width: width, height: height, dx: dx, dy: dy, screen: -1, shadow: true, radius: 14)
            }
            func rejected(file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
                do { try body(); fail("Accepted invalid launcher operation", file: file, line: line) }
                catch NativeError.message { }
                catch { fail("Unexpected error: \(error)") }
            }
            rejected { try NativeLauncher.attach(title: "missing") }
            let donor = LauncherTestWindow(contentRect: NSRect(x: 50, y: 80, width: 720, height: 420),
                                           styleMask: .borderless, backing: .buffered, defer: false)
            donor.isReleasedWhenClosed = false
            donor.title = "launcher-native-checks"
            let editor = LauncherTestEditor(frame: donor.frame)
            donor.contentView = editor
            donor.delegate = editor
            donor.orderFront(nil)
            rejected { try NativeLauncher.attach(title: donor.title) }
            donor.orderOut(nil)
            // Refusing first responder after the view move rolls it back.
            editor.acceptsFocus = false
            autoreleasepool { rejected { try NativeLauncher.attach(title: donor.title) } }
            check(editor.window === donor && donor.delegate === editor)
            check(NativeLauncher.attached == nil)
            editor.acceptsFocus = true
            // Routine runs attach twice; the stress suite passes a larger count.
            let cycles = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 2 : 2
            for _ in 0..<cycles {
                try autoreleasepool {
                    try NativeLauncher.attach(title: donor.title)
                    let launcher = require(NativeLauncher.attached)
                    check(editor.window === launcher.panel)
                    check(donor.delegate === editor)
                    rejected { try NativeLauncher.attach(title: donor.title) }
                    let oldSession = NativeLauncher.session
                    try launcher.place(placement())
                    check(NativeLauncher.describe()["watchingFocus"] as? Bool == true)
                    check(NativeLauncher.session > oldSession)
                    check(launcher.panel.frame == NativeLauncher.rectangle(placement(), in: require(launcher.panel.screen).visibleFrame))
                    check(launcher.panel.styleMask.contains(.nonactivatingPanel))
                    check(launcher.panel.canBecomeKey && !launcher.panel.canBecomeMain)
                    launcher.panel.applyEmacsAppearance()
                    check(launcher.panel.appearance?.name == .darkAqua)
                    // Reapply after the system reports a changed arrangement,
                    // without a new presentation/focus request.
                    launcher.panel.setFrameOrigin(NSPoint(x: -100000, y: -100000))
                    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                    check(NSScreen.screens.contains { $0.visibleFrame.contains(launcher.panel.frame) })
                    rejected { try launcher.place(placement(199, 407)) }
                    // Fitting is layout only: the session, focus watching and
                    // first responder stay, as do the left, width and top edges.
                    let session = NativeLauncher.session
                    try launcher.place(placement(713, 100), present: false)
                    let placed = launcher.panel.frame
                    let area = require(launcher.panel.screen).visibleFrame
                    for height: Int64 in [164, 100, 407, 100000, 120] {
                        try launcher.fit(session: session, height: height)
                        check(launcher.panel.frame == NativeLauncher.fitted(placed, height: height, in: area))
                        check(NativeLauncher.session == session)
                        check(launcher.panel.firstResponder === editor)
                        check(NativeLauncher.describe()["watchingFocus"] as? Bool == true)
                    }
                    check(launcher.panel.frame.maxY == placed.maxY && launcher.panel.frame.height == 120)
                    rejected { try launcher.fit(session: session, height: 99) }
                    try launcher.fit(session: session + 1, height: 300)
                    check(launcher.panel.frame.height == 120, "A stale session resized the panel")
                    // A display change centers the fitted height again, and
                    // later fits keep that new top edge.
                    launcher.panel.setFrameOrigin(NSPoint(x: -100000, y: -100000))
                    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                    let replaced = launcher.panel.frame
                    check(replaced.height == 120)
                    check(replaced == NativeLauncher.rectangle(placement(713, 120), in: require(launcher.panel.screen).visibleFrame))
                    try launcher.fit(session: session, height: 300)
                    check(launcher.panel.frame.maxY == replaced.maxY && launcher.panel.frame.height == 300)
                    // Panel notifications carry the current presentation,
                    // and explicit hide/detach never emit a new dismissal.
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: launcher.panel)
                    check(records() == "launcher-blur \(NativeLauncher.session)\n")
                    // Fitting keeps the recorded focus loss, so it stays coalesced.
                    try launcher.fit(session: session, height: 164)
                    check(NativeLauncher.session == session)
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: launcher.panel)
                    check(records().isEmpty, "Duplicate focus loss was not coalesced")
                    launcher.hide()
                    check(!launcher.panel.isVisible)
                    check(NativeLauncher.describe()["watchingFocus"] as? Bool == false)
                    // A late fit cannot resize or reveal a hidden panel.
                    let hidden = launcher.panel.frame
                    try launcher.fit(session: NativeLauncher.session, height: 300)
                    check(!launcher.panel.isVisible && launcher.panel.frame == hidden)
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: launcher.panel)
                    check(records().isEmpty)
                    NativeLauncher.detach()
                    NativeLauncher.detach()
                    check(editor.window === donor && donor.delegate === editor)
                    check(NativeLauncher.attached == nil)
                }
            }
            donor.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            check(NSApp.windows.allSatisfy { !($0 is LauncherPanel) }, "Closed panels remain: \(NSApp.windows)")
            print("Launcher native checks passed: placement, fitting, rollback, ownership, focus-loss pipe delivery, \(cycles) attach/detach cycles")
        }
    }
}
