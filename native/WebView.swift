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

    /// What an ordinary page adds to WebKit's user agent: Safari's own
    /// suffix, as the installed Safari, which ships with the system's
    /// WebKit, names its version. Google refuses to sign in to a page whose
    /// user agent lacks it. Without Safari, it claims Safari 26.0.
    private static let safari: String = {
        let version = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        return "Version/\(version ?? "26.0") Safari/605.1.15"
    }()

    /// The page is made from CONFIGURATION. An inspectable page lets Safari's
    /// Web Inspector attach to it.
    init(target: String, configuration: WKWebViewConfiguration, hosted: Bool, inspectable: Bool) {
        self.target = target
        if hosted {
            configuration.websiteDataStore = .nonPersistent()
        } else {
            configuration.applicationNameForUserAgent = Self.safari
        }
        super.init(frame: .zero, configuration: configuration)
        if #available(macOS 13.3, *) { isInspectable = inspectable }
        if hosted { PageMessages.install(in: self) }
        KeyReports.install(in: self)
        navigationDelegate = self
        uiDelegate = self
    }

    /// Follows the system's appearance while the page shows it.
    private var system: NSKeyValueObservation?
    /// The appearance the page shows, which windows it opens start in.
    private(set) var choice = PORTAL_APPEARANCE_SYSTEM

    /// Show the page in APPEARANCE, which WebKit gives it as
    /// prefers-color-scheme. The view's own appearance overrides its
    /// window's, which an Emacs frame may force, so even the system's is set
    /// here, and again whenever it changes.
    func show(_ choice: portal_appearance) {
        self.choice = choice
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

    /// The page asks for a new window, once `decidePolicyFor` has allowed
    /// its URL. The core decides whether it gets one, which WebKit then loads.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let request = WindowRequest(configuration: configuration)
        return Core.window(target, request: request) ? request.page : nil
    }

    /// The page closed its window, as window.close does in a window a script opened.
    func webViewDidClose(_ webView: WKWebView) {
        Core.closed(target)
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

    /// The JavaScript dialog the page waits on: WebKit asks for one at a time.
    private var dialog: PageDialog?
    /// The frame's window the page is shown in, while it is.
    private weak var shownIn: NSWindow?
    /// Whether the view has closed, so no dialog can show.
    private var closed = false

    /// The page is shown in WINDOW, or, with nil, about to be parked: its
    /// dialog follows it, and waits while it is hidden.
    func shown(in window: NSWindow?) {
        shownIn = window
        if let window { dialog?.show(on: window) } else { dialog?.hide() }
    }

    /// Show NEXT, the page's dialog, as a sheet on the page's frame, now or
    /// once the page is shown.
    private func ask(_ next: PageDialog) {
        guard !closed else { return next.answer(false) }
        dialog?.answer(false)
        dialog = next
        next.done = { [weak self, weak next] in
            if let self, self.dialog === next { self.dialog = nil }
        }
        if let shownIn { next.show(on: shownIn) }
    }

    /// The view is closing: answer its dialogs as if dismissed, from now on.
    /// WebKit requires an answer to every one.
    func dismissDialogs() {
        closed = true
        dialog?.answer(false)
    }

    /// Who is speaking in FRAME's dialog: its host, as browsers name it.
    private func speaker(_ frame: WKFrameInfo) -> String {
        frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        ask(PageDialog(title: speaker(frame), message: message, buttons: ["OK"]) { _, _ in
            completionHandler()
        })
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        ask(PageDialog(title: speaker(frame), message: message, buttons: ["OK", "Cancel"]) { ok, _ in
            completionHandler(ok)
        })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        ask(PageDialog(title: speaker(frame), message: prompt, buttons: ["OK", "Cancel"],
                       text: defaultText ?? "") { ok, text in
            completionHandler(ok ? text : nil)
        })
    }

    /// A page with a `beforeunload` handler asks before it is left, by any
    /// navigation or reload. WebKit offers this only to the private delegate
    /// method; without it, every page is left without asking. Pages no longer
    /// choose the question, so its message goes unused, as in Safari.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        ask(PageDialog(title: "Leave this page?", message: "Changes you made may not be saved.",
                       buttons: ["Leave Page", "Stay on Page"]) { leave, _ in
            completionHandler(leave)
        })
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

/// A JavaScript dialog, which the page waits on until it has an answer: its
/// first button, or any other, and the text in its field if it has one. It is
/// a sheet on the frame the page is shown in. Hiding the page takes the sheet
/// down and showing it again puts it back, as a background tab's dialog
/// waits, so a parked page's dialog is never lost offscreen.
@MainActor
private final class PageDialog {
    private let title: String
    private let message: String
    private let buttons: [String]
    /// A prompt's text, as last shown.
    private var text: String?
    private var reply: (@MainActor (Bool, String?) -> Void)?
    /// Called once, after the answer.
    var done: (() -> Void)?
    private var sheet: NSAlert?
    private weak var window: NSWindow?

    init(title: String, message: String, buttons: [String], text: String? = nil,
         reply: @escaping @MainActor (Bool, String?) -> Void) {
        self.title = title
        self.message = message
        self.buttons = buttons
        self.text = text
        self.reply = reply
    }

    /// Show the dialog as a sheet on WINDOW, moving it there if it is on another.
    func show(on window: NSWindow) {
        guard sheet == nil || self.window !== window else { return }
        hide()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        if let text {
            let field = NSTextField(string: text)
            field.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
        }
        sheet = alert
        self.window = window
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                // A sheet taken down by `hide` has no answer.
                guard let self, self.sheet === alert else { return }
                self.text = (alert.accessoryView as? NSTextField)?.stringValue ?? self.text
                self.sheet = nil
                self.window = nil
                Self.returnKeyboard(to: window)
                self.answer(response == .alertFirstButtonReturn)
            }
        }
    }

    /// Take the sheet down, keeping the dialog unanswered.
    func hide() {
        guard let alert = sheet else { return }
        text = (alert.accessoryView as? NSTextField)?.stringValue ?? text
        sheet = nil
        if let window {
            window.endSheet(alert.window)
            Self.returnKeyboard(to: window)
        }
        window = nil
    }

    /// AppKit leaves no window key once a sheet on an Emacs frame ends, so
    /// the next key would reach nothing and the next click only make the
    /// frame key. Give WINDOW the keyboard back, unless another window took it.
    private static func returnKeyboard(to window: NSWindow) {
        Task { @MainActor in
            guard NSApp.isActive, NSApp.keyWindow == nil, window.attachedSheet == nil,
                  window.isVisible else { return }
            window.makeKey()
        }
    }

    /// Answer the page, once: with the first button when CHOSEN.
    func answer(_ chosen: Bool) {
        hide()
        guard let reply else { return }
        self.reply = nil
        reply(chosen, text)
        done?()
    }
}

/// A page's request for a new window: WebKit's configuration for it, and the
/// page made from it once the core opens the window (`portal_web_create_window`).
@MainActor
final class WindowRequest {
    let configuration: WKWebViewConfiguration
    fileprivate var page: WebPage?

    init(configuration: WKWebViewConfiguration) {
        self.configuration = configuration
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
    /// bridge's scripts. With `:inspectable`, Safari's Web Inspector may
    /// attach to it. It starts in its `:appearance`, which the core has
    /// checked.
    convenience init(target: String, options: ViewOptions) throws {
        let appearance = switch try options.string("appearance") {
        case "light": PORTAL_APPEARANCE_LIGHT
        case "dark": PORTAL_APPEARANCE_DARK
        default: PORTAL_APPEARANCE_SYSTEM
        }
        self.init(page: WebPage(target: target, configuration: WKWebViewConfiguration(),
                                hosted: options.flag("hosted"), inspectable: options.flag("inspectable")),
                  appearance: appearance)
    }

    /// The window the page in OPENER asked for. WebKit requires the page be
    /// made from its configuration, which keeps the opener's data store and
    /// makes the opener the new page's. The new page gets its own scripts,
    /// and Web Inspector attaches to it when it does to the opener.
    convenience init(target: String, opener: WebSession, request: WindowRequest) {
        request.configuration.userContentController = WKUserContentController()
        var inspectable = false
        if #available(macOS 13.3, *) { inspectable = opener.page.isInspectable }
        let page = WebPage(target: target, configuration: request.configuration, hosted: false,
                           inspectable: inspectable)
        self.init(page: page, appearance: opener.page.choice)
        request.page = page
    }

    private init(page: WebPage, appearance: portal_appearance) {
        page.show(appearance)
        self.page = page
        input = NativeInput(target: page.target, view: page, host: NativeView.parking) { [weak page] in
            guard let page, !page.isHidden else { return false }
            return page.window?.makeFirstResponder(page) ?? false
        }
        page.input = input
        input.offer = { [weak page] event in page?.offer(event) }
    }

    func attached() { page.shown(in: page.window) }

    func detaching() { page.shown(in: nil) }

    func close() {
        page.dismissDialogs()
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
        if #available(macOS 13.3, *) { state.append(("inspectable", .flag(page.isInspectable))) }
        return state
    }
}
