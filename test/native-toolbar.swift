// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone AppKit/WebKit integration test: ./test.sh gui --suite native-toolbar --allow-gui.
// The core owns every toolbar's state (native/Core/toolbar.c); these checks
// click real buttons, type into the real field and read what AppKit shows.
import AppKit
import WebKit

@main
struct CheckToolbar {
    @MainActor
    static func wait(_ description: String, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        check(predicate(), description)
    }

    @MainActor
    static func main() {
        runChecks { try run() }
    }

    @MainActor
    static func key(_ window: NSWindow, _ characters: String, ignoring: String? = nil, code: UInt16,
                    flags: NSEvent.ModifierFlags = []) -> NSEvent {
        require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false,
                                 keyCode: code))
    }

    /// Press a key as the event loop delivers a real one, which makes it the
    /// current event: the find field reads Shift from there.
    @MainActor
    static func press(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: false)
        NSApp.sendEvent(require(NSApp.nextEvent(matching: .keyDown, until: .distantFuture, inMode: .default,
                                                dequeue: true)))
    }

    @MainActor
    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Portal toolbar check"
        let editor = NSTextView(frame: require(window.contentView).bounds)
        require(window.contentView).addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        let target = try Views.open(kind: "web", options: ViewOptions(values: ["toolbar": .string("contents")]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        try Views.load(target, "data:text/html,<title>Toolbar test</title><h1>Heading</h1><p>needle one needle two needle three</p>")
        var container = require(require(window.contentView).subviews.compactMap { $0 as? NativeContainer }.first)
        let web = require(container.content as? WKWebView)
        func state() throws -> [String: Any] { try Views.toolbar(target, "state") }
        func flag(_ name: String) -> Bool { (try? state())?[name] as? Bool ?? false }
        wait("page did not load") { web.title == "Toolbar test" && !web.isLoading && flag("headings") }
        check(web.frame.height == 452 && require(container.toolbar).frame.height == 28)
        func button(_ tooltip: String) -> NSButton {
            require(require(container.toolbar).subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == tooltip }, "Missing toolbar button: \(tooltip)")
        }
        func dot() -> NSButton {
            require(require(container.toolbar).subviews.compactMap { $0 as? NSButton }.first { $0.frame.minX == 5 && !$0.isHidden },
                    "Missing ownership dot")
        }
        let field = require(require(container.toolbar).subviews.compactMap { $0 as? NSSearchField }.first)
        check(field.isHidden && container.state.owner == .emacs)
        // Previews go back and forward like pages; only Markdown ones open in Emacs.
        check(!button("Back").isHidden && !button("Back").isEnabled && !button("Forward").isEnabled)
        check(button("Open in Emacs").isHidden && button("Table of contents").isEnabled)
        try Views.load(target, "data:text/html,<title>Second page</title>")
        wait("second page did not load") { web.title == "Second page" && button("Back").isEnabled }
        check(!button("Table of contents").isEnabled, "A page without headings offers its contents")
        button("Back").performClick(nil)
        wait("back did not return") { web.title == "Toolbar test" && !web.isLoading && flag("headings") }
        check(button("Forward").isEnabled && !button("Back").isEnabled && window.firstResponder === editor)
        button("Zoom in").performClick(nil)
        check(web.pageZoom == 1.1 && window.firstResponder === editor && button("Reset to 100%").title == "110%")
        _ = try Views.toolbar(target, "increase")
        check(web.pageZoom == 1.25)
        for _ in 0..<20 { _ = try Views.toolbar(target, "increase") }
        check(web.pageZoom == 3 && !button("Zoom in").isEnabled)
        for _ in 0..<20 { button("Zoom out").performClick(nil) }
        check(web.pageZoom == 0.5 && !button("Zoom out").isEnabled && button("Zoom in").isEnabled)
        button("Reset to 100%").performClick(nil)
        check(web.pageZoom == 1 && button("Reset to 100%").title == "100%")
        button("Table of contents").performClick(nil)
        check(flag("toc") && button("Table of contents").accessibilityValue() as? Int == 1)
        var tocVisible = false
        web.evaluateJavaScript("!!document.querySelector('nav[aria-label=\"Table of contents\"]:not([hidden])')") { value, _ in tocVisible = value as? Bool ?? false }
        wait("TOC missing") { tocVisible }
        // The dot moves the keyboard, and buttons never take it.
        dot().performClick(nil)
        check(container.state.owner == .view && Views.owner(target) == PORTAL_OWNER_VIEW)
        check(dot().toolTip == "Click to return to Emacs · ⌘⎋")
        let responder = window.firstResponder
        button("Zoom in").performClick(nil)
        check(window.firstResponder === responder)
        dot().performClick(nil)
        check(window.firstResponder === editor && container.state.owner == .emacs)
        // Find: the real field takes the keyboard and edits natively.
        _ = try Views.toolbar(target, "find")
        check(!field.isHidden && container.state.owner == .view, "find did not own the keyboard")
        check(window.firstResponder !== web && field.currentEditor() != nil)
        require(field.currentEditor()).insertText("needle")
        wait("find count") { container.state.matches == 3 && container.state.match == 1 }
        check(container.state.query == "needle" && field.stringValue == "needle")
        press(key(window, "\r", code: 36))
        wait("find next") { container.state.match == 2 }
        press(key(window, "\r", code: 36, flags: .shift))
        wait("find previous") { container.state.match == 1 }
        press(key(window, "\r", code: 36))
        press(key(window, "\r", code: 36))
        wait("rapid find next") { container.state.match == 3 }
        button("Next match").performClick(nil)
        wait("find wraps") { container.state.match == 1 }
        press(key(window, "\u{1b}", code: 53))
        check(!container.state.finding && field.isHidden && container.state.owner == .view)
        check(window.firstResponder === web || (window.firstResponder as? NSView)?.isDescendant(of: web) == true,
              "Closing find did not return the keyboard to the page")
        // The page does not use Command-F, so the toolbar's shortcut gets it.
        let commandF = key(window, "f", code: 3, flags: .command)
        press(commandF)
        wait("Command-F did not open find") { container.state.finding && window.firstResponder !== web }
        wait("find query was not retained") { container.state.matches == 3 }
        _ = try Views.input(target, action: "unfocus")
        _ = try Views.toolbar(target, "find")
        check(container.state.owner == .view, "Repeated find must focus its field")
        // Closing find after the user moved to Emacs leaves Emacs the keyboard.
        window.makeFirstResponder(editor)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        check(container.state.owner == .emacs)
        _ = try Views.toolbar(target, "close-find")
        check(window.firstResponder === editor && !container.state.finding, "Closing find took the keyboard")
        // Visibility is live, and the view keeps its state.
        Views.showToolbars(false)
        check(container.toolbar == nil && web.frame.height == 480)
        Views.showToolbars(true)
        check(container.toolbar != nil && web.frame.height == 452 && web.pageZoom == 1.1)
        try Views.hide(target)
        check(web.window !== window && web.isHiddenOrHasHiddenAncestor && window.firstResponder === editor)
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        container = require(require(window.contentView).subviews.compactMap { $0 as? NativeContainer }.first)
        check(container.content === web && !container.isHidden && flag("toc") && web.pageZoom == 1.1)
        check(button("Reset to 100%").title == "110%" && container.state.query == "needle")
        button("Reload").performClick(nil)
        wait("reload") { !web.isLoading }
        tocVisible = false
        web.evaluateJavaScript("!!document.querySelector('nav[aria-label=\"Table of contents\"]:not([hidden])')") { value, _ in tocVisible = value as? Bool ?? false }
        wait("TOC not kept across reload") { tocVisible }
        check(web.pageZoom == 1.1 && flag("toc"))
        // Command-R reloads as the button does, while the view has the keyboard.
        dot().performClick(nil)
        var marked = false
        web.evaluateJavaScript("window.marked = true") { _, _ in marked = true }
        wait("page was not marked") { marked }
        press(key(window, "r", code: 15, flags: .command))
        wait("Command-R did not reload") {
            web.evaluateJavaScript("window.marked === undefined") { value, _ in marked = !(value as? Bool ?? false) }
            return !marked && !web.isLoading
        }
        dot().performClick(nil)
        check(container.state.owner == .emacs)
        // Colors are the core's; the strip draws them.
        var colors = portal_colors()
        colors.success = portal_color(set: true, red: 0, green: 1, blue: 0)
        colors.background = portal_color(set: true, red: 0.1, green: 0.2, blue: 0.3)
        Views.paintToolbars(colors)
        check(container.state.color("success") == NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        check(require(container.toolbar).state.color("background") == NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        Views.paintToolbars(portal_colors())
        check(container.state.color("success") == .systemGreen)
        try Views.close(target)
        check(require(window.contentView).subviews.count == 1)
        try checkWithoutToolbar(window: window)
        try checkMarkdown(window: window, editor: editor)
        print("Toolbar layout, focus, zoom limits, TOC, find, back, forward, theme and retained state passed")
    }

    /// A view without a toolbar fills its pane, even while toolbars show.
    @MainActor
    static func checkWithoutToolbar(window: NSWindow) throws {
        let target = try Views.open(kind: "web", options: ViewOptions(values: [
            "toolbar": .string("none"), "hosted": .flag(true)]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        let container = require(require(window.contentView).subviews.compactMap { $0 as? NativeContainer }.first)
        check(container.toolbar == nil && container.content.frame.height == 480)
        Views.showToolbars(false)
        Views.showToolbars(true)
        check(container.toolbar == nil && container.content.frame.height == 480)
        try Views.close(target)
        print("Views without a toolbar fill their pane")
    }

    /// A hosted Markdown preview's Open in Emacs gives Emacs the keyboard and
    /// asks it, over the bridge, to open the file.
    @MainActor
    static func checkMarkdown(window: NSWindow, editor: NSView) throws {
        var fds: [Int32] = [0, 0]
        check(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        check(portal_channel_connect(fds[1]))
        defer { _ = portal_channel_connect(-1); close(fds[0]) }
        func container() -> NativeContainer {
            require(require(window.contentView).subviews.compactMap { $0 as? NativeContainer }.first)
        }
        func edit(hosted: Bool) throws -> (String, NSButton) {
            let target = try Views.open(kind: "web", options: ViewOptions(values: [
                "toolbar": .string("markdown"), "hosted": .flag(hosted)]))
            try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
            check(!require(container().toolbar).subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "Table of contents" }!.isHidden)
            return (target, require(require(container().toolbar).subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "Open in Emacs" }, "Missing Open in Emacs button"))
        }
        // Without a bridge there is no way to ask Emacs, so no button.
        let (plain, hidden) = try edit(hosted: false)
        check(hidden.isHidden, "A preview without a bridge offers Open in Emacs")
        try Views.close(plain)
        let (target, button) = try edit(hosted: true)
        check(!button.isHidden)
        let focused = try Views.input(target, action: "focus")
        check(focused && window.firstResponder !== editor)
        // Clicking while Emacs reads a key sequence ends that read first, so
        // Emacs runs the edit instead of taking it for the sequence's next
        // key. The page does not use C-x, so Emacs reads from it.
        NSApp.sendEvent(key(window, "\u{18}", ignoring: "x", code: 7, flags: .control))
        wait("The chord did not reach Emacs") { container().state.owner == .pending }
        button.performClick(nil)
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = read(fds[0], &buffer, buffer.count)
        let records = count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        let kinds = records.split(separator: "\n").map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        check(kinds == ["key \(target)", "escape \(target)", "bridge \(target)"],
                     "Open in Emacs did not end the key sequence and notify Emacs: \(records)")
        let messages = try Views.receive(target)
        check(messages == #"[{"type":"edit"}]"#, "Open in Emacs did not ask Emacs to edit")
        check(window.firstResponder === editor, "Open in Emacs left the keyboard in the view")
        check(container().state.owner == .emacs)
        try Views.close(target)
        print("Markdown previews open their file in Emacs from the toolbar")
    }
}
