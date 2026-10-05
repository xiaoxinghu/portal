// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone AppKit check: ./test.sh gui --suite native-focus --allow-gui.
import AppKit
import WebKit

@main
struct CheckFocus {
    @MainActor
    static func main() {
        runChecks { try run() }
    }

    @MainActor
    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Portal focus check"
        let editor = NSTextView(frame: require(window.contentView).bounds)
        require(window.contentView).addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        let target = try Views.open(kind: "web", options: ViewOptions(values: ["toolbar": .string("navigation")]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        try Views.load(target, "data:text/html,<input autofocus><title>Focus</title>")
        let web = require(require(window.contentView).subviews.compactMap { ($0 as? NativeContainer)?.content as? WKWebView }.first)
        // A responder nested below the webview exercises the same ancestry test
        // as WebKit's internal text input views.
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        web.addSubview(input)
        // A chord such as C-g is the page's only if it uses it (portal-input-gui-tests.el).
        for (code, flags, characters) in [(UInt16(53), NSEvent.ModifierFlags(), "\u{1b}"),
                                          (UInt16(53), .command, "\u{1b}")] {
            check(window.makeFirstResponder(input))
            let event = require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: flags, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: code))
            app.sendEvent(event)
            if flags == .command {
                check(window.firstResponder === editor, "Command-Escape did not return focus")
            } else {
                check(window.firstResponder === input, "Guest key unexpectedly left the app")
            }
        }
        check(window.makeFirstResponder(input))
        try Views.hide(target)
        check(window.firstResponder === editor, "Hiding did not restore focus")
        try Views.close(target)
        print("Guest Escape retains focus; Command-Escape and hiding restore Emacs focus")
        try checkHosted(window: window)
        try checkBridge(window: window)
        try checkLinks(window: window, editor: editor)
        try checkChannel()
    }

    /// A full pipe delays records, without losing or reordering them: the
    /// core retries it on this platform's timer. test/portal-channel-tests.c
    /// covers the core's other cases. Records name an open view: the core
    /// drops the others.
    @MainActor
    static func checkChannel() throws {
        let web = try Views.open(kind: "web", options: ViewOptions(values: ["toolbar": .string("none")]))
        var fds: [Int32] = [0, 0]
        check(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        check(portal_channel_connect(fds[1]))
        defer { _ = portal_channel_connect(-1); close(fds[0]) }
        check(!Core.notify("two words", target: web), "A malformed record was accepted")
        // Fill the pipe, as an Emacs busy with a long command leaves it.
        let filler = [UInt8](repeating: UInt8(ascii: "."), count: 512)
        var filled = 0
        while case let count = write(fds[1], filler, filler.count), count > 0 { filled += count }
        check(Core.notify("escape", target: web, fields: ["2", "0"])
                     && Core.notify("bridge", target: web), "A full pipe refused records")
        let expected = "escape \(web) 2 0\nbridge \(web)\n"
        var received: [UInt8] = []
        let deadline = Date(timeIntervalSinceNow: 5)
        while received.count < filled + expected.utf8.count && Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fds[0], &buffer, buffer.count)
            if count > 0 { received += buffer[..<count] }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        let records = String(decoding: received.dropFirst(filled), as: UTF8.self)
        check(records == expected, "Records were lost or reordered: \(records)")

        // Records waiting when Emacs replaces its pipe go to the new one, in order.
        while write(fds[1], filler, filler.count) > 0 {}
        while write(fds[1], filler, 1) > 0 {}
        check(Core.notify("escape", target: web, fields: ["3", "0"])
                     && Core.notify("bridge", target: web), "A full pipe refused records")
        close(fds[0])
        check(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        check(portal_channel_connect(fds[1]))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fds[0], &buffer, buffer.count)
        let moved = count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        check(moved == "escape \(web) 3 0\nbridge \(web)\n", "Replacing the pipe lost records: \(moved)")
        // A late record, for a closed view, never reaches Emacs.
        try Views.close(web)
        check(!Core.notify("bridge", target: web), "A closed view's record was accepted")
        print("A full pipe delays records in order, and loses none, even when Emacs replaces it")
    }

    /// A pipe standing in for Emacs's end of the core's record pipe.
    @MainActor
    static func connectRecords() -> (read: () -> String, close: () -> Void) {
        var fds: [Int32] = [0, 0]
        check(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        check(portal_channel_connect(fds[1]))
        return ({
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fds[0], &buffer, buffer.count)
            return count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        }, { _ = portal_channel_connect(-1); close(fds[0]) })
    }

    /// A hosted app reports each page it commits over its bridge. Clicking it
    /// asks Emacs to select its pane, and its links to local files go to Emacs,
    /// with the keyboard, over the bridge too, however long their paths.
    @MainActor
    static func checkLinks(window: NSWindow, editor: NSView) throws {
        let (records, disconnect) = connectRecords()
        defer { disconnect() }
        let target = try Views.open(kind: "web", options: ViewOptions(values: [
            "toolbar": .string("none"), "hosted": .flag(true)]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        var received = ""
        /// Wait for RECORD, then return the bridge's messages as [type, url] pairs.
        func wait(for record: String) -> [[String]] {
            let deadline = Date(timeIntervalSinceNow: 10)
            while !received.contains(record) && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                received += records()
            }
            check(received.contains(record), "Expected \(record), got \(received)")
            received = ""
            let messages = require(try JSONSerialization.jsonObject(with: Data(Views.receive(target).utf8)) as? [[String: Any]])
            return messages.map { [require($0["type"] as? String), $0["url"] as? String ?? ""] }
        }
        let file = "file:///tmp/" + String(repeating: "r%C3%A9sum%C3%A9%20", count: 40) + "notes.ts#L4"
        let page = "<title>Links</title><a style='display:block;height:80px' href='\(file)'>code</a>"
        let app = "data:text/html;base64," + Data(page.utf8).base64EncodedString()
        let first = "data:text/html,%3Ctitle%3EFirst%3C/title%3E"
        let web = require(require(window.contentView).subviews.compactMap { ($0 as? NativeContainer)?.content as? WKWebView }.first)
        // Every committed page is reported, including after going back.
        try Views.load(target, first)
        check(wait(for: "bridge \(target)\n") == [["page", first]])
        try Views.load(target, app)
        check(wait(for: "bridge \(target)\n") == [["page", app]])
        web.goBack()
        check(wait(for: "bridge \(target)\n") == [["page", first]])
        web.goForward()
        check(wait(for: "bridge \(target)\n") == [["page", app]])
        // Loading the page on screen again reloads it, without a new history entry.
        try Views.load(target, app + "#top")
        check(wait(for: "bridge \(target)\n") == [["page", app]])
        check(web.backForwardList.backList.count == 1 && web.backForwardList.forwardList.isEmpty,
              "Loading the page on screen again changed the history")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        check(window.makeFirstResponder(editor))
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 440), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // This process cannot activate, so AppKit swallows a click in its window
        // after the monitor sees it; the page gets the same events directly.
        let down = mouse(.leftMouseDown)
        NSApp.sendEvent(down)
        web.mouseDown(with: down)
        web.mouseUp(with: mouse(.leftMouseUp))
        check(file.utf8.count > Int(PIPE_BUF))
        check(wait(for: "select \(target)\nbridge \(target)\n") == [["follow", file]],
                     "The link did not reach Emacs")
        check(window.firstResponder === editor, "Following a link left the keyboard in the view")
        check(web.url?.scheme == "data" && !web.isLoading, "Following a local link left the page")
        try Views.close(target)
        print("Hosted apps report their pages, clicks select their pane, and local links go to Emacs")
    }

    /// A hosted app keeps no data between sessions, and a page it leaves the
    /// app host for opens in the browser while the app stays.
    @MainActor
    static func checkHosted(window: NSWindow) throws {
        let (_, disconnect) = connectRecords()
        defer { disconnect() }
        var opened: [URL] = []
        WebSession.openInBrowser = { opened.append($0) }
        let target = try Views.open(kind: "web", options: ViewOptions(values: [
            "toolbar": .string("none"), "hosted": .flag(true)]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        let app = "data:text/html,<title>App</title><script>onload=()=>location.href='https://example.com/'</script>"
        try Views.load(target, app)
        let web = require(require(window.contentView).subviews.compactMap { ($0 as? NativeContainer)?.content as? WKWebView }.first)
        check(!web.configuration.websiteDataStore.isPersistent, "A hosted app keeps its data")
        let deadline = Date(timeIntervalSinceNow: 10)
        while opened.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        check(opened == [require(URL(string: "https://example.com/"))], "The link did not open in the browser")
        check(web.url?.scheme == "data" && web.title == "App", "The hosted app left its page")
        // WebKit reports a URL with its host and port as parsed, which is the
        // app's own origin however Emacs spelled it. Nothing listens on port 9,
        // so each load fails, but none may go to the browser.
        for spelling in ["http://%31%32%37.0.0.1:9/app", "http://127.0.0.1:09/app", "http://[::1]:09/app"] {
            opened = []
            try Views.load(target, spelling)
            let deadline = Date(timeIntervalSinceNow: 1)
            while Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            check(opened.isEmpty, "Loading \(spelling) sent the app to the browser")
        }
        try Views.close(target)
        print("Hosted apps keep no data, and open other sites in the browser")
    }

    /// Only a hosted app has a bridge, and only its main frame may post. One
    /// record announces queued messages until Emacs receives them, in order.
    @MainActor
    static func checkBridge(window: NSWindow) throws {
        var fds: [Int32] = [0, 0]
        check(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        check(portal_channel_connect(fds[1]))
        defer { _ = portal_channel_connect(-1); close(fds[0]) }
        func records() -> String {
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = read(fds[0], &buffer, buffer.count)
            return count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        }
        func wait(until done: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 10)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        }
        func types(_ target: String) -> [String] {
            let messages = require(try JSONSerialization.jsonObject(with: Data(Views.receive(target).utf8)) as? [[String: Any]])
            return messages.map { require($0["type"] as? String) }
        }

        // A frame reaches WebKit's handler, but the core hears it came from a
        // frame. The app cannot post the core's own types.
        let page = """
            <iframe srcdoc="<script>webkit.messageHandlers.portal.postMessage({type:'frame'})</script>"
              onload="portalBridge.postMessage({type:'second'})"></iframe>
            <script>
            portalBridge.receive = async (m) => portalBridge.postMessage({type: 'echo-' + m.type});
            portalBridge.postMessage({type: 'follow', url: 'file:///etc/passwd'});
            portalBridge.postMessage({type: 'first'});
            </script>
            """
        let app = "data:text/html;base64," + Data(page.utf8).base64EncodedString()
        let hosted = try Views.open(kind: "web", options: ViewOptions(values: [
            "toolbar": .string("none"), "hosted": .flag(true)]))
        try Views.place(hosted, edges: [0, 0, 640, 480], title: window.title)
        try Views.load(hosted, app)
        var received = ""
        wait { received += records(); return received.contains("\n") }
        check(received == "bridge \(hosted)\n", "Expected one bridge record, got \(received)")
        // Let the frame load and post too.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        check(records().isEmpty, "A second record went out before Emacs received the first")
        check(types(hosted) == ["page", "first", "second"], "The bridge lost, reordered or accepted a frame's or reserved message")
        check(types(hosted).isEmpty, "Receiving did not drain the bridge")
        try Views.send(hosted, #"{"type":"ping"}"#)
        received = ""
        wait { received += records(); return received.contains("\n") }
        check(received == "bridge \(hosted)\n", "Receiving did not re-arm the bridge record")
        check(types(hosted) == ["echo-ping"], "The app did not receive Emacs's message")
        // A reload runs the bridge's script again before the page's own.
        try Views.load(hosted, app)
        received = ""
        wait { received += records(); return received.contains("\n") }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        check(types(hosted) == ["page", "first", "second"], "The reloaded app could not use the bridge")
        // A page that cannot receive reports that to Emacs.
        let deaf = "data:text/html,%3Ctitle%3EDeaf%3C/title%3E"
        try Views.load(hosted, deaf)
        received = ""
        wait { received += records(); return received.contains("\n") }
        check(types(hosted) == ["page"])
        try Views.send(hosted, #"{"type":"ping"}"#)
        received = ""
        wait { received += records(); return received.contains("\n") }
        check(types(hosted) == ["error"], "A failed delivery did not reach Emacs")
        // A URL spelled raw, as a user may type it, is still the app's own page
        // once WebKit has parsed it: the app can post, and loading it again
        // reloads it.
        let spaced = "data:text/html,<title>A b</title><script>portalBridge.postMessage({type: 'spaced'})</script>"
        let hostedPage = require(require(window.contentView).subviews.compactMap { ($0 as? NativeContainer)?.content as? WKWebView }.first)
        var history: [Int] = []
        for _ in 0..<2 {
            try Views.load(hosted, spaced)
            received = ""
            wait { received += records(); return received.contains("\n") }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            check(types(hosted) == ["page", "spaced"], "A raw URL's app could not post")
            history.append(hostedPage.backForwardList.backList.count)
        }
        check(history[0] == history[1], "Loading a raw URL again added a history entry")
        try Views.close(hosted)

        let plain = try Views.open(kind: "web", options: ViewOptions(values: ["toolbar": .string("none")]))
        try Views.place(plain, edges: [0, 0, 640, 480], title: window.title)
        try Views.load(plain, app)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        check(records().isEmpty, "A page that is not a hosted app reached the bridge")
        let web = require(require(window.contentView).subviews.compactMap { ($0 as? NativeContainer)?.content as? WKWebView }.first)
        var bridgeType = ""
        web.evaluateJavaScript("typeof portalBridge") { value, _ in bridgeType = value as? String ?? "" }
        wait { !bridgeType.isEmpty }
        check(bridgeType == "undefined", "A page that is not a hosted app has portalBridge")
        for use in [{ try Views.send(plain, "{}") }, { _ = try Views.receive(plain) }] {
            do { try use(); fail("A page that is not a hosted app has a bridge") } catch {}
        }
        try Views.close(plain)
        print("Only a hosted app's main frame uses the bridge, which announces its messages once until received")
    }
}
