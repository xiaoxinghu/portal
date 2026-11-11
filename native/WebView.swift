// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore
import SecurityInterface
import WebKit

/// One WebKit page. It loads what the core decides and reports what the page
/// does: its navigations, commits, loads, history and failures, its
/// downloads, and a hosted app's messages.
@MainActor
private final class WebPage: WKWebView, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
    NativeSurface {
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

    /// For fullscreen, WebKit moves the page to a window of its own, and
    /// back to its pane on the way out. The page is back once WebKit is
    /// done leaving fullscreen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        input?.moved()
    }

    private var fullscreen: NSKeyValueObservation?
    /// WebKit's window for the page in fullscreen, until it hides it.
    private weak var fullscreenWindow: NSWindow?

    /// WebKit says the page left fullscreen before it is done: once the
    /// page has drawn in its pane, WebKit hides its own window and brings
    /// the page's to the front. The page is back after that, so that a
    /// page Emacs hid meanwhile brings Emacs's frame, not the parking window.
    private func fullscreenChanged() {
        switch fullscreenState {
        case .enteringFullscreen: fullscreenWindow = window
        case .notInFullscreen:
            guard let shown = fullscreenWindow, shown.isVisible else { return comeBack() }
            NotificationCenter.default.addObserver(self, selector: #selector(fullscreenWindowChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: shown)
        default: break
        }
    }

    @objc private func fullscreenWindowChanged(_ notification: Notification) {
        guard let shown = notification.object as? NSWindow, !shown.isVisible else { return }
        comeBack()
    }

    /// The page is out of fullscreen, and WebKit has done with its window.
    private func comeBack() {
        if let shown = fullscreenWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                      object: shown)
        }
        fullscreenWindow = nil
        // After WebKit, which hides its window just before it orders the page's.
        Task { @MainActor [weak self] in self?.input?.back() }
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
    /// Whether the page is a hosted app's, which keeps nothing between sessions.
    private let hosted: Bool

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
        self.hosted = hosted
        if hosted {
            configuration.websiteDataStore = .nonPersistent()
        } else {
            configuration.applicationNameForUserAgent = Self.safari
        }
        // A page may go fullscreen, as a video player's button does.
        configuration.preferences.isElementFullscreenEnabled = true
        super.init(frame: .zero, configuration: configuration)
        if #available(macOS 13.3, *) { isInspectable = inspectable }
        fullscreen = observe(\.fullscreenState) { page, _ in
            MainActor.assumeIsolated { page.fullscreenChanged() }
        }
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
        policy(for: url, mainFrame: mainFrame, download: false) == .allow
    }

    /// Ask the core what the page does with URL, which it asks to DOWNLOAD
    /// or to load, and act on its answer.
    private func policy(for url: URL, mainFrame: Bool, download: Bool) -> WKNavigationActionPolicy {
        switch Core.navigating(target, url: url.absoluteString, mainFrame: mainFrame, download: download) {
        case .allow: return .allow
        case .download: return .download
        case .external: WebSession.openInBrowser(url)
        case .emacs: break
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        // A request for a new window counts as the main frame.
        decisionHandler(policy(for: url, mainFrame: action.targetFrame?.isMainFrame ?? true,
                               download: action.shouldPerformDownload))
    }

    /// A response WebKit cannot show, or one its server marks as an
    /// attachment, downloads if the core says so.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let attachment = disposition?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "attachment"
        let decision = Core.responding(target, show: response.canShowMIMEType, attachment: attachment)
        decisionHandler(decision == .download ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        begin(download, url: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        begin(download, url: navigationResponse.response.url)
    }

    /// The running downloads, with the core's number for each and its file
    /// once the core has chosen it.
    private var downloads: [ObjectIdentifier: (download: WKDownload, number: UInt64, file: URL?)] = [:]

    /// Tell the core about DOWNLOAD, of URL, from its start, so that even a
    /// failure before its response reaches Emacs.
    private func begin(_ download: WKDownload, url: URL?) {
        guard let number = Core.downloadStarted(target, url: url?.absoluteString ?? "") else {
            return download.cancel()
        }
        download.delegate = self
        downloads[ObjectIdentifier(download)] = (download, number, nil)
    }

    /// The file the core chose, or nil, which cancels the download.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let key = ObjectIdentifier(download)
        guard let running = downloads[key] else { return nil }
        guard let file = Core.downloadDestination(running.number, name: suggestedFilename) else {
            downloads[key] = nil
            return nil
        }
        downloads[key]?.file = file
        return file
    }

    func downloadDidFinish(_ download: WKDownload) { end(download, error: nil) }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        end(download, error: error.localizedDescription)
    }

    private func end(_ download: WKDownload, error: String?) {
        guard let running = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Self.ended(download, number: running.number, file: running.file, error: error)
    }

    /// Tell the core DOWNLOAD ended, once WebKit has stopped writing. A
    /// failed download leaves no partial file: its file was new, so it is
    /// WebKit's once WebKit has written to it.
    private static func ended(_ download: WKDownload, number: UInt64, file: URL?, error: String?) {
        if error != nil, let file, download.progress.completedUnitCount > 0 {
            try? FileManager.default.removeItem(at: file)
        }
        Core.downloadFinished(number, error: error)
    }

    /// Cancel every download. Each ends once WebKit has stopped it, even
    /// after the page is gone.
    func cancelDownloads() {
        let running = downloads.values
        downloads = [:]
        for (download, number, file) in running {
            download.cancel { _ in
                MainActor.assumeIsolated {
                    Self.ended(download, number: number, file: file, error: "The download was cancelled.")
                }
            }
        }
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

    /// Every page the view commits, including after back and forward, and
    /// one restored from WebKit's page cache.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        finding += 1
        keepSelection()
        if let url { Core.committed(target, url: url.absoluteString) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let offered { answer(offered, used: seen) }
        // Finds that were waiting on the page get no answer.
        finding += 1
        running = 0
        runNext()
        Core.failed(target, token: 0, message: "The page's web process stopped.")
    }

    /// WebKit's `WKPageSetMaintainsInactiveSelection`, an exported C call of
    /// its WKPage API, if this WebKit has it.
    private static let maintainsInactiveSelection: (@convention(c) (OpaquePointer, Bool) -> Void)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "WKPageSetMaintainsInactiveSelection")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (OpaquePointer, Bool) -> Void).self)
    }()

    /// The page keeps its selection when it gives up the keyboard
    /// (docs/adr/0004). WebKit clears it then, unless the page maintains an
    /// inactive selection, and with the page holding the keyboard every
    /// command Emacs runs from it, Command-G included, passes the keyboard
    /// to Emacs and back: since a find starts after the selection, each one
    /// found the first match again. The setting is lost on navigation, so
    /// each commit sets it. Without WebKit's calls, the page loses its
    /// selection as before.
    private func keepSelection() {
        let pageRef = NSSelectorFromString("_pageRefForTransitionToWKWebView")
        guard let set = Self.maintainsInactiveSelection, responds(to: pageRef) else { return }
        typealias PageRef = @convention(c) (AnyObject, Selector) -> OpaquePointer?
        guard let page = unsafeBitCast(method(for: pageRef), to: PageRef.self)(self, pageRef) else { return }
        set(page, true)
    }

    /// Which finding a find belongs to: each commit and each end of finding
    /// starts another, so a find still waiting for its start never runs on
    /// a new page, or lights the matches again once finding is done.
    private var finding: UInt64 = 0

    /// The world of the scripts that find with, out of the page's reach.
    private static let findWorld = WKContentWorld.world(name: "portal-find")

    /// Where a find starts, as isearch's point is always on screen: from a
    /// selection that is in view, collapsed to its end going forward or its
    /// start going backward; otherwise from a caret at the start of the
    /// first line of text in view, or the end of the last going backward.
    /// A selection inside an image's Live Text shows the page a range in
    /// the image's figure with no rects: it stays as it is while the figure
    /// is in view, and WebKit goes on from it.
    private static let startInView = """
        const selection = getSelection(), width = innerWidth, height = innerHeight;
        const shown = (rect) => rect.bottom > 0 && rect.top < height && rect.right > 0 && rect.left < width;
        if (selection.rangeCount) {
          const range = selection.getRangeAt(0);
          if (range.getClientRects().length) {
            if (shown(range.getBoundingClientRect())) {
              backward ? selection.collapseToStart() : selection.collapseToEnd();
              return;
            }
          } else if (!range.collapsed) {
            const node = range.commonAncestorContainer;
            const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
            if (element && element !== document.body && element !== document.documentElement
                && shown(element.getBoundingClientRect()))
              return;
          }
        }
        for (let y = backward ? height - 2 : 2; y > 0 && y < height; y += backward ? -8 : 8) {
          const caret = document.caretRangeFromPoint(width / 2, y);
          if (!caret || caret.startContainer.nodeType !== Node.TEXT_NODE) continue;
          const rect = caret.getBoundingClientRect();
          if (!rect.height || rect.bottom <= 0 || rect.top >= height) continue;
          selection.removeAllRanges();
          selection.addRange(caret);
          selection.modify("move", backward ? "forward" : "backward", "lineboundary");
          return;
        }
        """

    /// The selection's rect in the document, in CSS pixels from its top
    /// left, or null when the main frame has none with rects: a selection
    /// in a subframe is that frame's, and one in Live Text has no rects.
    private static let selectionRect = """
        const selection = getSelection();
        if (!selection.rangeCount || selection.isCollapsed) return null;
        const range = selection.getRangeAt(0);
        if (!range.getClientRects().length) return null;
        const rect = range.getBoundingClientRect();
        return [rect.left + scrollX, rect.top + scrollY, rect.width, rect.height];
        """

    /// Find TEXT as WebKit's own find in page does, which Safari's find bar
    /// uses: from what is on screen (`startInView`), it selects the match,
    /// lights every match until finding is done (`findDone`), shows its find
    /// indicator, and leaves the keyboard where it is. Then it reports how
    /// many matches the page has, and which one is selected when it can
    /// tell (`report`). Without WebKit's calls for it, the public find,
    /// which says only whether it matched. A page that runs no scripts, as
    /// a PDF, finds from its selection.
    func find(_ text: String, backward: Bool, caseSensitive: Bool, token: UInt64) {
        // WKWebViewPrivate.h, with _WKFindOptions.h's values.
        let findString = NSSelectorFromString("_findString:options:maxCount:")
        guard responds(to: findString), responds(to: Self.findMatches) else {
            let configuration = WKFindConfiguration()
            configuration.backwards = backward
            configuration.caseSensitive = caseSensitive
            configuration.wraps = true
            return find(text, configuration: configuration) { [target = target] result in
                Core.found(target, token: token, index: 0, count: result.matchFound ? -1 : 0)
            }
        }
        let caseInsensitive: UInt = 1 << 0, backwards: UInt = 1 << 3, wrapAround: UInt = 1 << 4
        let showFindIndicator: UInt = 1 << 6, showHighlight: UInt = 1 << 7
        var options = wrapAround | showFindIndicator | showHighlight
        if !caseSensitive { options |= caseInsensitive }
        if backward { options |= backwards }
        let finding = finding
        queue { [weak self] done in
            guard let self, self.finding == finding else { return done() }
            callAsyncJavaScript(Self.startInView, arguments: ["backward": backward], in: nil,
                                in: Self.findWorld) { [weak self] _ in
                guard let self, self.finding == finding else { return done() }
                typealias FindString = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
                unsafeBitCast(self.method(for: findString), to: FindString.self)(
                    self, findString, text as NSString, options, UInt(PORTAL_WEB_FIND_MAX))
                self.report(text, caseSensitive: caseSensitive, token: token, done: done)
            }
        }
    }

    /// The finds waiting their turn, oldest first, and the one running, by
    /// its number, or 0. A find runs whole, from its start to its report,
    /// before the next one starts: the list of one asked for while another's
    /// find is on its way would take that find's answer.
    private var waiting: [(@escaping () -> Void) -> Void] = []
    private var running: UInt64 = 0
    private var runs: UInt64 = 0

    /// Run FIND in its turn; it calls the function it is given when done.
    private func queue(_ find: @escaping (@escaping () -> Void) -> Void) {
        waiting.append(find)
        runNext()
    }

    private func runNext() {
        guard running == 0, !waiting.isEmpty else { return }
        runs += 1
        let run = runs
        running = run
        waiting.removeFirst()({ [weak self] in
            guard let self, self.running == run else { return }
            self.running = 0
            self.runNext()
        })
    }

    /// The system find bar's client call, NSTextFinderClient's, that lists
    /// a page's matches.
    private static let findMatches =
        NSSelectorFromString("findMatchesForString:relativeToMatch:findOptions:maxResults:resultCollector:")

    /// Report the find of TEXT that `find` just started: how many matches
    /// the page has, and where the selected one is among them, in WebKit's
    /// order, which is the order finding goes in: the main frame's in the
    /// document's order, then each subframe's. WebKit's own match index is a
    /// counter, not the selection's place, so the place comes from the list
    /// of matches, located by the selection's rect: only a main frame's
    /// match is found that way, and for any other, as one in a subframe or
    /// in Live Text, the place is unknown.
    ///
    /// WebKit runs the page's calls in the order asked, so the script that
    /// reads the selection answers once the find is done. Only then is the
    /// list asked for: asked while the find's own answer is on its way, the
    /// list takes that answer, the selected match alone. Asking for the list
    /// ends WebKit's reports to a find delegate for the view's life, so
    /// finding never relies on those.
    private func report(_ text: String, caseSensitive: Bool, token: UInt64, done: @escaping () -> Void) {
        callAsyncJavaScript(Self.selectionRect, in: nil, in: Self.findWorld) { [weak self] result in
            guard let self else { return done() }
            var selected: NSRect?
            if case .success(let value) = result, let rect = value as? [Double], rect.count == 4 {
                let zoom = pageZoom
                selected = NSRect(x: rect[0] * zoom, y: rect[1] * zoom, width: rect[2] * zoom,
                                  height: rect[3] * zoom)
            }
            matches(text, caseSensitive: caseSensitive) { [weak self] rects in
                defer { done() }
                guard let self else { return }
                // WebKit lists no more than the most the core counts, so a
                // full list may be longer.
                let max = Int(PORTAL_WEB_FIND_MAX)
                if rects.count >= max {
                    return Core.found(target, token: token, index: 0, count: Int64(max) + 1)
                }
                let tolerance = Swift.max(2, 2 * pageZoom)
                let at = selected.map { selected in
                    rects.indices.filter { rects[$0].insetBy(dx: -tolerance, dy: -tolerance).contains(selected) }
                } ?? []
                Core.found(target, token: token, index: at.count == 1 ? Int64(at[0]) + 1 : 0,
                           count: Int64(rects.count))
            }
        }
    }

    /// The rects of the page's matches of TEXT, each the union of its line
    /// rects, in view points from the document's top left, in WebKit's
    /// order.
    private func matches(_ text: String, caseSensitive: Bool, _ done: @escaping @MainActor ([NSRect]) -> Void) {
        var answered = false
        typealias Collector = @convention(block) (NSArray, Bool) -> Void
        let collector: Collector = { matches, _ in
            MainActor.assumeIsolated {
                // Once: the system find bar's client may answer again.
                guard !answered else { return }
                answered = true
                done(matches.map { match in
                    let rects = ((match as AnyObject).value(forKey: "textRects") as? [NSValue] ?? []).map(\.rectValue)
                    return rects.dropFirst().reduce(rects.first ?? .null) { $0.union($1) }
                })
            }
        }
        // findOptions: 4 ignores case.
        typealias FindMatches = @convention(c) (AnyObject, Selector, NSString, AnyObject?, UInt, UInt, AnyObject) -> Void
        unsafeBitCast(method(for: Self.findMatches), to: FindMatches.self)(
            self, Self.findMatches, text as NSString, nil, caseSensitive ? 0 : 4, UInt(PORTAL_WEB_FIND_MAX),
            collector as AnyObject)
    }

    /// Finding is done for now: the matches go dark and WebKit's find
    /// indicator goes, and the selection stays for the next find.
    func findDone() {
        finding += 1
        let hide = NSSelectorFromString("_hideFindUI")
        if responds(to: hide) { perform(hide) }
    }

    /// The questions the page waits on, in the order it asked: JavaScript's
    /// dialogs, one at a time, its requests for the camera and microphone,
    /// and its servers' for the user's name and password or certificate.
    private var dialogs: [any PageQuestion] = []
    /// The frame's window the page is shown in, while it is.
    private weak var shownIn: NSWindow?
    /// Whether the view has closed, so no dialog can show.
    private var closed = false
    /// The print panel the page last showed, which hiding or closing it
    /// cancels if it still shows.
    fileprivate weak var printing: PrintJob?

    /// The page is shown in WINDOW, or, with nil, about to be parked: its
    /// dialog follows it, and waits while it is hidden.
    func shown(in window: NSWindow?) {
        shownIn = window
        if let window { dialogs.first?.show(on: window) } else { dialogs.first?.hide() }
        if window == nil { printing?.cancel() }
    }

    /// Show NEXT, the page's dialog, as a sheet on the page's frame, now or
    /// once the page is shown and has answered those before it.
    private func ask(_ next: any PageQuestion) {
        guard !closed else { return next.answer(false) }
        dialogs.append(next)
        next.done = { [weak self, weak next] in
            guard let self else { return }
            self.dialogs.removeAll { $0 === next }
            self.showDialog()
        }
        showDialog()
    }

    /// Show the first dialog, unless it no longer needs asking.
    private func showDialog() {
        guard !closed, let first = dialogs.first else { return }
        if first.settled?() == true { return first.answer(true) }
        if let shownIn { first.show(on: shownIn) }
    }

    /// The view is closing: answer its dialogs as if dismissed, from now on.
    /// WebKit requires an answer to every one.
    func dismissDialogs() {
        closed = true
        printing?.cancel()
        for dialog in dialogs { dialog.answer(false) }
    }

    /// Who is speaking in FRAME's dialog: its host, as browsers name it.
    private func speaker(_ frame: WKFrameInfo) -> String {
        frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        ask(PageDialog(title: speaker(frame), message: message, buttons: ["OK"]) { _ in
            completionHandler()
        })
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        ask(PageDialog(title: speaker(frame), message: message, buttons: ["OK", "Cancel"]) { answer in
            completionHandler(answer.chosen)
        })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        ask(PageDialog(title: speaker(frame), message: prompt, buttons: ["OK", "Cancel"],
                       fields: [.init(text: defaultText ?? "")]) { answer in
            completionHandler(answer.chosen ? answer.texts[0] : nil)
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
                       buttons: ["Leave Page", "Stay on Page"]) { answer in
            completionHandler(answer.chosen)
        })
    }

    /// A page asks to use the camera or microphone, and the core decides
    /// whether it may. When the core leaves it to the user, a sheet asks, as
    /// the page's own dialogs do, and the core keeps a grant. One the user
    /// granted while this one waited needs no asking. macOS asks for itself,
    /// once, whether Emacs may use the device.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let (devices, what): (Int, String) = switch type {
        case .camera: (PORTAL_MEDIA_CAMERA, "camera")
        case .microphone: (PORTAL_MEDIA_MICROPHONE, "microphone")
        default: (PORTAL_MEDIA_CAMERA | PORTAL_MEDIA_MICROPHONE, "camera and microphone")
        }
        let page = Self.spell(origin), asking = Self.spell(frame.securityOrigin)
        let decide = { [target] in
            Core.media(target, origin: page, frame: asking, devices: UInt32(devices))
        }
        switch decide() {
        case .grant: return decisionHandler(.grant)
        case .deny: return decisionHandler(.deny)
        case .ask: break
        }
        var who = Self.name(frame.securityOrigin)
        if asking != page { who += " in \(Self.name(origin))" }
        let dialog = PageDialog(title: "Allow \(who) to use your \(what)?",
                                message: "It may use it again until Emacs quits.",
                                buttons: ["Allow", "Don’t Allow"]) { [target] answer in
            if answer.chosen { Core.mediaGranted(target, origin: page, frame: asking, devices: UInt32(devices)) }
            decisionHandler(answer.chosen ? .grant : .deny)
        }
        dialog.settled = { decide() == .grant }
        ask(dialog)
    }

    /// ORIGIN as a URL, scheme://host or scheme://host:port.
    private static func spell(_ origin: WKSecurityOrigin) -> String {
        "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
    }

    /// ORIGIN as the user knows it: its host, in quotes.
    private static func name(_ origin: WKSecurityOrigin) -> String {
        origin.host.isEmpty ? "this page" : "“\(origin.host)”"
    }

    /// A server, or a proxy, asks who the user is. A sheet asks for a user
    /// name and password, as the page's dialogs do; WebKit then sends them
    /// for the rest of the session without asking. Ordinary pages may
    /// remember them in the login keychain, where they are then used without
    /// asking until they fail; hosted apps keep nothing. A request for a
    /// certificate gets the system's identity picker. A server's own
    /// certificate is the system's to trust: one it does not fails the load.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition,
                                                          URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            askPassword(for: challenge, reply: completionHandler)
        case NSURLAuthenticationMethodClientCertificate:
            chooseIdentity(for: challenge, reply: completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func askPassword(for challenge: URLAuthenticationChallenge,
                             reply: @escaping @MainActor (URLSession.AuthChallengeDisposition,
                                                          URLCredential?) -> Void) {
        let space = challenge.protectionSpace, store = URLCredentialStorage.shared
        let kept = hosted ? nil : store.defaultCredential(for: space)
        if challenge.previousFailureCount == 0, let kept, let user = kept.user, let password = kept.password {
            return reply(.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
        }
        let usual = space.protocol == "https" ? 443 : 80
        let host = space.port == usual ? space.host : "\(space.host):\(space.port)"
        var message = challenge.previousFailureCount > 0 ? "The user name or password was incorrect. " : ""
        if let realm = space.realm, !realm.isEmpty {
            message += "“\(realm)” asks for a user name and password."
        } else {
            message += "It asks for a user name and password."
        }
        if !space.receivesCredentialSecurely { message += " The password will be sent unencrypted." }
        let user = challenge.proposedCredential?.user ?? kept?.user ?? ""
        ask(PageDialog(title: space.isProxy() ? "Log in to the proxy “\(host)”" : "Log in to “\(host)”",
                       message: message, buttons: ["Log In", "Cancel"],
                       fields: [.init(placeholder: "User Name", text: user),
                                .init(placeholder: "Password", text: "", secure: true)],
                       check: hosted ? nil : "Remember this password", checked: kept != nil) { [hosted] answer in
            // Cancelled, the page shows what the server sends without them.
            guard answer.chosen else { return reply(.rejectProtectionSpace, nil) }
            let (user, password) = (answer.texts[0], answer.texts[1])
            if answer.checked {
                store.setDefaultCredential(URLCredential(user: user, password: password, persistence: .permanent),
                                           for: space)
            } else if !hosted {
                for credential in store.credentials(for: space)?.values ?? [:].values {
                    store.remove(credential, for: space)
                }
            }
            reply(.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
        })
    }

    /// The identity the host prefers, or one the user picks from those in
    /// the keychain the server accepts. Without one, or when the user
    /// cancels, the page goes on without a certificate.
    private func chooseIdentity(for challenge: URLAuthenticationChallenge,
                                reply: @escaping @MainActor (URLSession.AuthChallengeDisposition,
                                                             URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let issuers = space.distinguishedNames ?? []
        let use = { (identity: SecIdentity) in
            reply(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        }
        if let preferred = SecIdentityCopyPreferred(space.host as CFString, nil, issuers as CFArray) {
            return use(preferred)
        }
        var query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll,
                                      kSecReturnRef: true]
        if !issuers.isEmpty { query[kSecMatchIssuers] = issuers }
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let identities = found as? [SecIdentity], !identities.isEmpty else {
            return reply(.rejectProtectionSpace, nil)
        }
        ask(IdentityDialog(host: space.host, identities: identities) { identity in
            if let identity { use(identity) } else { reply(.rejectProtectionSpace, nil) }
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
        let error = error as NSError
        // A navigation that became a download ends with WebKit's "frame load
        // interrupted", WebKitErrorFrameLoadInterruptedByPolicyChange.
        if error.code != NSURLErrorCancelled && !(error.domain == "WebKitErrorDomain" && error.code == 102) {
            loadError = error.localizedDescription
            Core.failed(target, token: 0, message: error.localizedDescription)
        }
    }
}

/// A question the page waits on, as a sheet on the frame the page is shown
/// in. Hiding the page takes the sheet down and showing it again puts it
/// back, as a background tab's dialog waits, so a parked page's question is
/// never lost offscreen.
@MainActor
private protocol PageQuestion: AnyObject {
    /// Called once, after the answer.
    var done: (() -> Void)? { get set }
    /// Whether the question needs no asking any more, when its turn comes:
    /// it is then answered as chosen.
    var settled: (() -> Bool)? { get }
    /// Show the sheet on WINDOW, moving it there if it is on another.
    func show(on window: NSWindow)
    /// Take the sheet down, keeping the question unanswered.
    func hide()
    /// Answer the page, once: as chosen, or as dismissed.
    func answer(_ chosen: Bool)
}

/// A dialog, which the page waits on until it has an answer: its first
/// button, or any other, the text in its fields, and whether its checkbox is
/// ticked.
@MainActor
private final class PageDialog: PageQuestion {
    /// A text field: what it says while empty, its text as last shown, and
    /// whether it hides what is typed, as a password's does.
    struct Field {
        var placeholder = ""
        var text: String
        var secure = false
    }

    struct Answer {
        /// Whether the first button was chosen.
        let chosen: Bool
        /// The fields' texts, in order.
        let texts: [String]
        /// Whether the checkbox was ticked.
        let checked: Bool
    }

    private let title: String
    private let message: String
    private let buttons: [String]
    private var fields: [Field]
    /// The checkbox's title, if the dialog has one, and its state as last shown.
    private let check: String?
    private var checked: Bool
    private var reply: (@MainActor (Answer) -> Void)?
    var done: (() -> Void)?
    var settled: (() -> Bool)?
    private var sheet: NSAlert?
    private var fieldViews: [NSTextField] = []
    private var checkbox: NSButton?
    private weak var window: NSWindow?

    init(title: String, message: String, buttons: [String], fields: [Field] = [],
         check: String? = nil, checked: Bool = false, reply: @escaping @MainActor (Answer) -> Void) {
        self.title = title
        self.message = message
        self.buttons = buttons
        self.fields = fields
        self.check = check
        self.checked = checked
        self.reply = reply
    }

    func show(on window: NSWindow) {
        guard sheet == nil || self.window !== window else { return }
        hide()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        // Escape chooses the second button, as it does Cancel.
        if alert.buttons.count > 1, alert.buttons[1].keyEquivalent.isEmpty {
            alert.buttons[1].keyEquivalent = "\u{1b}"
        }
        fieldViews = fields.map { field in
            let view = field.secure ? NSSecureTextField(string: field.text) : NSTextField(string: field.text)
            if !field.placeholder.isEmpty { view.placeholderString = field.placeholder }
            return view
        }
        checkbox = check.map { title in
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = checked ? .on : .off
            return box
        }
        let controls: [NSView] = fieldViews + (checkbox.map { [$0] } ?? [])
        if !controls.isEmpty {
            alert.accessoryView = Self.stack(controls)
            for (view, next) in zip(controls, controls.dropFirst() + controls.prefix(1)) {
                view.nextKeyView = next
            }
            // The first empty field, as a password's once its user is known.
            alert.window.initialFirstResponder = fieldViews.first { $0.stringValue.isEmpty } ?? fieldViews.first
        }
        sheet = alert
        self.window = window
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                // A sheet taken down by `hide` has no answer.
                guard let self, self.sheet === alert else { return }
                self.keep()
                self.sheet = nil
                self.window = nil
                Self.returnKeyboard(to: window)
                self.answer(response == .alertFirstButtonReturn)
            }
        }
    }

    /// CONTROLS one above another, as wide as a prompt's field.
    private static func stack(_ controls: [NSView]) -> NSView {
        let width: CGFloat = 300, gap: CGFloat = 8
        let heights = controls.map { $0 is NSTextField ? 24 : $0.fittingSize.height }
        let height = heights.reduce(0, +) + gap * CGFloat(controls.count - 1)
        let stack = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        var top = height
        for (control, size) in zip(controls, heights) {
            top -= size
            control.frame = CGRect(x: 0, y: top, width: width, height: size)
            stack.addSubview(control)
            top -= gap
        }
        return stack
    }

    /// Keep what the sheet's fields and checkbox show, for the answer or the
    /// next time it shows.
    private func keep() {
        for (index, view) in fieldViews.enumerated() { fields[index].text = view.stringValue }
        if let checkbox { checked = checkbox.state == .on }
    }

    func hide() {
        guard let alert = sheet else { return }
        keep()
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
    static func returnKeyboard(to window: NSWindow) {
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
        reply(Answer(chosen: chosen, texts: fields.map(\.text), checked: checked))
        done?()
    }
}

/// The system's identity picker, for a server that asks for a certificate
/// of the user's: the identities in the keychain it accepts. The choice
/// becomes the host's identity preference in the keychain.
@MainActor
private final class IdentityDialog: NSObject, PageQuestion {
    private let host: String
    private let identities: [SecIdentity]
    private var chosen: SecIdentity?
    private var reply: (@MainActor (SecIdentity?) -> Void)?
    var done: (() -> Void)?
    let settled: (() -> Bool)? = nil
    private var sheet: SFChooseIdentityPanel?
    private weak var window: NSWindow?

    init(host: String, identities: [SecIdentity], reply: @escaping @MainActor (SecIdentity?) -> Void) {
        self.host = host
        self.identities = identities
        self.reply = reply
    }

    func show(on window: NSWindow) {
        guard sheet == nil || self.window !== window else { return }
        hide()
        let panel = SFChooseIdentityPanel()
        panel.setDomain(host)
        sheet = panel
        self.window = window
        panel.beginSheet(for: window, modalDelegate: self,
                         didEnd: #selector(ended(_:returnCode:contextInfo:)), contextInfo: nil,
                         identities: identities,
                         message: "“\(host)” asks for a certificate to identify you.")
    }

    @objc private func ended(_ panel: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        // A sheet taken down by `hide` has no answer.
        guard let sheet, sheet === panel, let window else { return }
        chosen = returnCode == NSApplication.ModalResponse.OK.rawValue
            ? sheet.identity()?.takeUnretainedValue() : nil
        self.sheet = nil
        self.window = nil
        PageDialog.returnKeyboard(to: window)
        answer(chosen != nil)
    }

    func hide() {
        guard let panel = sheet else { return }
        sheet = nil
        if let window {
            window.endSheet(panel)
            PageDialog.returnKeyboard(to: window)
        }
        window = nil
    }

    /// Answer the page, once: with the chosen identity, or none.
    func answer(_ chosen: Bool) {
        hide()
        guard let reply else { return }
        self.reply = nil
        reply(chosen ? self.chosen : nil)
        done?()
    }
}

/// Printing a page: in the system's print panel, as a sheet on the page's
/// frame, as a browser prints, or to a PDF file with no panel. AppKit lays
/// the page out on paper and prints it. A job lives until AppKit says it
/// ran.
@MainActor
private final class PrintJob: NSObject {
    private static var running: Set<PrintJob> = []
    private let target: String
    /// The PDF printed to, or nil for the panel's choice.
    private let file: URL?
    /// The panel's sheet, and the frame it is on, while it shows.
    private weak var panel: NSWindow?
    private weak var window: NSWindow?

    private init(target: String, file: URL?) {
        self.target = target
        self.file = file
    }

    /// Show the print panel for PAGE on its frame's window, keeping the
    /// user's printer and settings from one print to the next.
    static func panel(for page: WebPage) throws -> PrintJob {
        guard let window = page.window else { throw NativeError.message("The page is in no window") }
        guard window.attachedSheet == nil else { throw NativeError.message("Close the frame's sheet to print") }
        let operation = page.printOperation(with: NSPrintInfo.shared)
        operation.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize,
                                                .showsOrientation, .showsScaling, .showsPreview])
        let job = PrintJob(target: page.target, file: nil)
        job.run(operation, page: page, window: window)
        job.window = window
        job.panel = window.attachedSheet
        return job
    }

    /// Print PAGE to FILE as a PDF, without panels.
    static func run(_ page: WebPage, to file: URL) throws {
        guard let window = page.window else { throw NativeError.message("The page is in no window") }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
        let operation = page.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        PrintJob(target: page.target, file: file).run(operation, page: page, window: window)
    }

    private func run(_ operation: NSPrintOperation, page: WebPage, window: NSWindow) {
        if let title = page.title, !title.isEmpty { operation.jobTitle = title }
        // WebKit's printing view keeps a zero frame otherwise, and AppKit
        // stops on it (developer.apple.com/forums/thread/811901).
        operation.view?.frame = page.bounds.isEmpty ? operation.printInfo.imageablePageBounds : page.bounds
        PrintJob.running.insert(self)
        // Run without a window, WebKit is reported to print blank pages or
        // none. Without a panel, AppKit runs it on a thread of its own.
        operation.runModal(for: window, delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    /// Take the panel down, if it still shows, as if cancelled.
    func cancel() {
        guard let panel, let window, window.attachedSheet === panel else { return }
        window.endSheet(panel, returnCode: .cancel)
    }

    /// AppKit says so on the thread it printed on, its own without a panel.
    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                                        contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ran(success: success) } }
    }

    private func ran(success: Bool) {
        PrintJob.running.remove(self)
        panel = nil
        if let window { PageDialog.returnKeyboard(to: window) }
        // The panel shows the user how printing went.
        guard let file else { return }
        let saved = success && FileManager.default.fileExists(atPath: file.path)
        Core.printed(target, file: file.path, error: saved ? nil : "Printing the page failed")
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

    /// A fullscreen page leaves fullscreen: WebKit then gives it back
    /// (`NativeView.close`).
    func close() {
        page.dismissDialogs()
        page.configuration.userContentController.removeAllScriptMessageHandlers()
        page.stopLoading()
        page.cancelDownloads()
        if page.fullscreenState != .notInFullscreen { page.closeAllMediaPresentations {} }
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

    func find(_ text: String, backward: Bool, caseSensitive: Bool, token: UInt64) {
        page.find(text, backward: backward, caseSensitive: caseSensitive, token: token)
    }

    func findDone() { page.findDone() }

    func zoom(_ factor: Double) { page.pageZoom = factor }

    /// Print the page in the print panel, or to FILE as a PDF.
    func printPage(to file: String?) throws {
        guard let file else { return page.printing = try PrintJob.panel(for: page) }
        try PrintJob.run(page, to: URL(fileURLWithPath: file))
    }

    func describe() -> [(String, ViewValue)] {
        var state: [(String, ViewValue)] = [("loading", .flag(page.isLoading)),
                                            ("dark", .flag(page.effectiveAppearance.isDark)),
                                            ("zoom", .integer(Int((page.pageZoom * 100).rounded())))]
        // Out of its pane, the page is entering, in or exiting fullscreen.
        switch page.fullscreenState {
        case .enteringFullscreen: state.append(("fullscreen", .string("entering")))
        case .inFullscreen: state.append(("fullscreen", .string("in")))
        case .exitingFullscreen: state.append(("fullscreen", .string("exiting")))
        default: break
        }
        if let url = page.url { state.append(("url", .string(url.absoluteString))) }
        if let title = page.title { state.append(("title", .string(title))) }
        if let error = page.loadError { state.append(("error", .string(error))) }
        if #available(macOS 13.3, *) { state.append(("inspectable", .flag(page.isInspectable))) }
        return state
    }
}
