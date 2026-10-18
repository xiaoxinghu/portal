// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore
import WebKit

/// One WebKit page. It loads what the core decides and reports what the page
/// does: its navigations, commits, loads, history and failures, and a hosted
/// app's messages.
@MainActor
private final class WebPage: WKWebView, WKNavigationDelegate, WKUIDelegate, NativeSurface {
    var nativeView: NSView { self }
    weak var input: NativeInput?

    /// The core decides what each key does: the page gets typing, and is
    /// offered each chord (`offer`), which Emacs gets if the page does not
    /// use it.
    func handleKeyEvent(_ event: NSEvent) -> Bool { input?.handleKeyEvent(event) == true }

    /// A page focusing an element, as autofocus does, makes WebKit ask the
    /// window to make the page first responder, even while Emacs or another
    /// view has the keyboard. The page gets it only from its input: from
    /// Emacs, the core, or the user's click.
    override func becomeFirstResponder() -> Bool {
        guard input?.mayTakeKeyboard == true else { return false }
        return super.becomeFirstResponder()
    }

    /// The press offered to the page, until it answers, and whether the key
    /// script has seen it reach the page.
    private var offered: NSEvent?
    private var seen = false
    private var offerTimer: Timer?

    /// Give the page EVENT, a key press the core offers it, and tell the input
    /// whether the page used it. WebKit hands back a press the page did not
    /// use, which the input sees again. It is known to have used one once the
    /// key script (`KeyReports`) reports the press reached the page, and
    /// WebKit has then finished with every key it had: typed into editable
    /// content, a press reaches WebKit's queue only after the input method
    /// is done with it. A page that never answers used the press if it saw
    /// it, as when the page hangs in its handler; if not, as when the view
    /// has no page yet, the press was never the page's.
    func offer(_ event: NSEvent) {
        offered = event
        seen = false
        offerTimer?.invalidate()
        offerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let event = self.offered else { return }
                self.answer(event, used: self.seen)
            }
        }
        keyDown(with: event)
    }

    /// The key script saw a press with these modifiers reach the page.
    fileprivate func saw(control: Bool, option: Bool, command: Bool) {
        guard let event = offered, !seen else { return }
        let flags = event.modifierFlags
        guard flags.contains(.control) == control, flags.contains(.option) == option,
              flags.contains(.command) == command else { return }
        seen = true
        let selector = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")
        guard responds(to: selector) else { return answer(event, used: true) }
        let done: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.answer(event, used: true) }
        }
        perform(selector, with: unsafeBitCast(done, to: AnyObject.self))
    }

    /// The page USED EVENT, or not, unless WebKit already handed it back.
    private func answer(_ event: NSEvent, used: Bool) {
        guard offered === event else { return }
        offered = nil
        offerTimer?.invalidate()
        offerTimer = nil
        input?.settle(event, used: used)
    }

    var loadError: String?
    /// The view's target, which names it in every call to the core.
    let target: String

    init(target: String, hosted: Bool) {
        self.target = target
        let configuration = WKWebViewConfiguration()
        if hosted { configuration.websiteDataStore = .nonPersistent() }
        super.init(frame: .zero, configuration: configuration)
        if hosted { PageMessages.install(in: self) }
        KeyReports.install(in: self)
        navigationDelegate = self
        uiDelegate = self
    }

    /// Follows the system's appearance while the page shows it.
    private var system: NSKeyValueObservation?

    /// Show the page in APPEARANCE, which WebKit gives it as
    /// prefers-color-scheme. The view's own appearance overrides its
    /// window's, which an Emacs frame may force, so even the system's is set
    /// here, and again whenever it changes.
    func show(_ choice: portal_appearance) {
        system = nil
        switch choice {
        case PORTAL_APPEARANCE_LIGHT: appearance = NSAppearance(named: .aqua)
        case PORTAL_APPEARANCE_DARK: appearance = NSAppearance(named: .darkAqua)
        default:
            showSystem()
            system = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.showSystem() }
            }
        }
    }

    /// NSApp's appearance is the system's: Emacs sets only its windows'.
    private func showSystem() {
        appearance = NSAppearance(named: NSApp.effectiveAppearance.isDark ? .darkAqua : .aqua)
    }

    required init?(coder: NSCoder) { nil }

    /// Load URL as a new document; a local file may read its directory.
    func open(_ url: URL) {
        loadError = nil
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }

    func go(_ step: portal_history) {
        switch step {
        case PORTAL_BACK: goBack()
        case PORTAL_FORWARD: goForward()
        default:
            loadError = nil
            reload()
        }
    }

    /// Pass MESSAGE, a JSON object, to the page's `portalBridge.receive` as
    /// data. A failure reaches the core with TOKEN, which tells it apart from
    /// failures on a later page.
    func post(_ json: String, token: UInt64) throws {
        guard let message = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NativeError.message("A bridge message must be a JSON object")
        }
        callAsyncJavaScript("return await window.portalBridge.receive(message)",
                            arguments: ["message": message], in: nil, in: .page) { [target] result in
            if case .failure(let error) = result {
                Core.failed(target, token: token, message: error.localizedDescription)
            }
        }
    }

    /// Ask the core whether the page may go to URL, and act on its answer:
    /// true to go on. It hands local files to Emacs itself.
    func mayNavigate(to url: URL, mainFrame: Bool) -> Bool {
        switch Core.navigating(target, url: url.absoluteString, mainFrame: mainFrame) {
        case .allow: return true
        case .external: WebSession.openInBrowser(url)
        case .emacs: break
        }
        return false
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        // A request for a new window counts as the main frame.
        decisionHandler(mayNavigate(to: url, mainFrame: action.targetFrame?.isMainFrame ?? true) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    /// Every page the view commits, including after back and forward.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url { Core.committed(target, url: url.absoluteString) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let offered { answer(offered, used: seen) }
        Core.failed(target, token: 0, message: "The page's web process stopped.")
    }

    // File inputs, such as inserting an image, use the native file picker.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    private func record(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            loadError = error.localizedDescription
            Core.failed(target, token: 0, message: error.localizedDescription)
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// The key script, in every frame of every page, in its own world out of the
/// page's reach. It reports each real key press with Control, Option or
/// Command that reaches the page, before the page's own handlers see it, so
/// a page knows when a press offered to it has arrived (`WebPage.offer`).
@MainActor
private final class KeyReports: NSObject, WKScriptMessageHandler {
    private static let script = """
        addEventListener("keydown", (event) => {
          if (event.isTrusted && (event.ctrlKey || event.altKey || event.metaKey)
              && !["Control", "Alt", "Meta", "Shift", "CapsLock", "Fn", "AltGraph"].includes(event.key))
            window.webkit.messageHandlers.key.postMessage([event.ctrlKey, event.altKey, event.metaKey]);
        }, true);
        """
    private weak var page: WebPage?

    static func install(in page: WebPage) {
        let reports = KeyReports()
        reports.page = page
        let world = WKContentWorld.world(name: "portal-keys")
        let controller = page.configuration.userContentController
        controller.add(reports, contentWorld: world, name: "key")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let flags = message.body as? [Bool], flags.count == 3 else { return }
        page?.saw(control: flags[0], option: flags[1], command: flags[2])
    }
}

/// A hosted app's two script message handlers. The page's world gets the
/// bridge: bootstrap glue defines `portalBridge.postMessage`, the one place
/// a hosted app's messages meet WebKit's transport. An isolated world, out
/// of the page's reach, runs the core's shared links script, which reports
/// clicks on links to local files: WebKit never lets a page on the app host
/// navigate to a file: URL, and does not ask the navigation delegate either.
/// The core judges both by what WebKit says about the sending frame.
@MainActor
private final class PageMessages: NSObject, WKScriptMessageHandler {
    private static let bridge = """
        window.portalBridge = {
          postMessage: (message) => window.webkit.messageHandlers.portal.postMessage(message),
        };
        """
    private weak var page: WebPage?

    static func install(in page: WebPage) {
        let messages = PageMessages()
        messages.page = page
        let controller = page.configuration.userContentController
        controller.add(messages, contentWorld: .page, name: "portal")
        controller.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        // The core's links script runs in its own world, out of the page's reach.
        let links = WKContentWorld.world(name: "Portal links")
        controller.add(messages, contentWorld: links, name: "follow")
        controller.addUserScript(WKUserScript(source: Core.linksScript(handler: "follow"),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                              in: links))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let page else { return }
        let mainFrame = message.frameInfo.isMainFrame
        if message.name == "follow" {
            guard let text = message.body as? String, let url = URL(string: text) else { return }
            // The script cancelled the click, so an allowed link loads here.
            if page.mayNavigate(to: url, mainFrame: mainFrame) { page.open(url) }
        } else if let body = message.body as? [String: Any], JSONSerialization.isValidJSONObject(body),
                  let json = try? JSONSerialization.data(withJSONObject: body) {
            Core.posted(page.target, mainFrame: mainFrame,
                        url: message.frameInfo.request.url?.absoluteString ?? "",
                        type: body["type"] as? String ?? "", json: String(decoding: json, as: UTF8.self))
        }
    }
}

/// The web view kind: one WebKit page with its own browsing state. The page
/// stays loaded while the view is hidden. The core decides what it loads and
/// where it may go, and keeps a hosted app's bridge (native/Core/web.c).
@MainActor
final class WebSession: PortalView {
    /// Where a hosted app's links to other sites go. Checks replace it.
    static var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private let page: WebPage
    var surface: any NativeSurface { page }
    let input: NativeInput

    /// With `:hosted`, the page keeps no data between sessions and gets the
    /// bridge's scripts. It starts in its `:appearance`, which the core has
    /// checked.
    init(target: String, options: ViewOptions) throws {
        let hosted = options.flag("hosted")
        let page = WebPage(target: target, hosted: hosted)
        let appearance = switch try options.string("appearance") {
        case "light": PORTAL_APPEARANCE_LIGHT
        case "dark": PORTAL_APPEARANCE_DARK
        default: PORTAL_APPEARANCE_SYSTEM
        }
        page.show(appearance)
        self.page = page
        input = NativeInput(target: target, view: page, host: NativeView.parking) { [weak page] in
            guard let page, !page.isHidden else { return false }
            return page.window?.makeFirstResponder(page) ?? false
        }
        page.input = input
        input.offer = { [weak page] event in page?.offer(event) }
    }

    func close() {
        page.configuration.userContentController.removeAllScriptMessageHandlers()
        page.stopLoading()
    }

    func load(_ address: String) throws {
        guard let url = URL(string: address) else { throw NativeError.message("WebKit cannot parse the URL \(address)") }
        page.open(url)
    }

    func go(_ step: portal_history) { page.go(step) }

    func post(_ json: String, token: UInt64) throws { try page.post(json, token: token) }

    func copy() throws { NSApp.sendAction(#selector(NSText.copy(_:)), to: keyboard, from: nil) }

    func paste() throws { NSApp.sendAction(#selector(NSText.paste(_:)), to: keyboard, from: nil) }

    /// Where the view's keyboard input goes: the responder in the page, or the page.
    private var keyboard: NSResponder {
        input.host.ownsFocus(page) ? page.window?.firstResponder ?? page : page
    }

    func show(_ appearance: portal_appearance) { page.show(appearance) }

    func describe() -> [(String, ViewValue)] {
        var state: [(String, ViewValue)] = [("loading", .flag(page.isLoading)),
                                            ("dark", .flag(page.effectiveAppearance.isDark))]
        if let url = page.url { state.append(("url", .string(url.absoluteString))) }
        if let title = page.title { state.append(("title", .string(title))) }
        if let error = page.loadError { state.append(("error", .string(error))) }
        return state
    }
}
