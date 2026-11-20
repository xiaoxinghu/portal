// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import GhosttyTerminal
import GhosttyTheme
import PortalCore
import PortalShared

/// Start programs through the same kind of shell as an ordinary terminal.
/// The shell owns startup files, PATH and executable lookup; Lisp supplies argv.
private func terminalCommand(_ options: ViewOptions, directory: String) throws -> String? {
    let command = try options.string("command")
    guard let json = try options.string("argv") else { return command }
    guard command == nil,
          let argv = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String],
          let program = argv.first, !program.isEmpty,
          argv.allSatisfy({ !$0.contains("\0") }) else {
        throw NativeError.message("Terminal :argv must contain a program and literal arguments, without :command")
    }
    // Match Ghostty's default shell lookup: native SHELL, then the user record.
    // This never consults Emacs's Lisp environment or exec-path.
    let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 }
        ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }
        ?? "/bin/sh"
    let name = URL(fileURLWithPath: shell).lastPathComponent
    guard ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(name) else {
        throw NativeError.message("Program launches need a POSIX-compatible shell or fish; found \(shell)")
    }
    // Startup files may cd elsewhere; the program still starts in this directory.
    let script = "cd " + terminalQuote(directory) + " && exec " + argv.map(terminalQuote).joined(separator: " ")
    return [shell, "-l", "-i", "-c", script].map(terminalQuote).joined(separator: " ")
}

/// Single-quoted literals for POSIX shells and fish. Backslashes stay outside
/// quotes because fish interprets them inside single quotes, unlike POSIX sh.
private func terminalQuote(_ value: String) -> String {
    "'" + value.map { character in
        switch character {
        case "'": return "'\\''"
        case "\\": return "'\\\\'"
        default: return String(character)
        }
    }.joined() + "'"
}

/// A fed terminal's pane: the view Portal places, which clips the terminal
/// inside it. The terminal holds the grid its output is laid out for, at
/// the pane's bottom-left, so a shell's prompt and cursor stay in view; the
/// rest of the pane is the theme's background (`portal_terminal_hold_grid`).
/// Below an opacity of 1 the pane alone draws that background, at the
/// opacity, and the terminal's own is clear: drawn by both, the grid would
/// show as a darker box (`portal_terminal_set_opacity`).
@MainActor
private final class FedPane: NSView {
    weak var terminal: HostedTerminal?
    /// The theme's background, for the light and the dark appearance.
    var background: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
    /// The terminal's opacity, from 0 to 1, which the background is drawn at.
    var opacity = 1.0 { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = background.cgColor.copy(alpha: CGFloat(opacity))
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        terminal?.fitInPane()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        terminal?.fitInPane()
    }
    /// A click beside the terminal gives it the keyboard, as one on it does.
    override func mouseDown(with event: NSEvent) {
        if let terminal { window?.makeFirstResponder(terminal) }
    }
    /// Beside the grid, the pointer is the terminal's too.
    override func resetCursorRects() {
        guard let terminal else { return super.resetCursorRects() }
        addCursorRect(visibleRect, cursor: terminal.pointer)
    }
}

/// A fed terminal's rules, native/Shared/fed-terminal.c, which the Linux
/// backend follows too: the order of its output and grids, the geometry of
/// its pane, and its backlog. What is the Mac's stays here: the package's
/// in-memory session, which parses the output off the main thread, the
/// timers, and the terminal's frame in its pane.
@MainActor
private final class FedRules {
    /// Nil once closed.
    private var rules: OpaquePointer?
    let session: InMemoryTerminalSession
    weak var terminal: HostedTerminal?
    /// The rules' two timers, by portal_fed_timer.
    private var timers: [Timer?] = [nil, nil]

    /// The rules of the terminal TARGET, fed through SESSION.
    init(target: String, session: InMemoryTerminalSession) throws {
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        rules = target.withCString {
            portal_fed_terminal_new(portal_string(data: $0, length: target.utf8.count), Self.backend, context)
        }
        guard rules != nil else { throw NativeError.message("Portal is out of memory") }
        // The session says when its unparsed output crosses the rules'
        // marks, on whichever thread crossed one, after its lock is
        // released: the rules read the count themselves, on the main thread.
        session.setOutputBacklogHandler(highWater: Int(PORTAL_FED_HIGH_MARK),
                                        lowWater: Int(PORTAL_FED_LOW_MARK)) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.backlog() } }
        }
    }

    /// Forget the rules, stopping their timers: nothing waiting is fed.
    func close() {
        guard let rules else { return }
        portal_fed_terminal_free(rules)
        self.rules = nil
    }

    // What the terminal hears, told to the rules.

    func feed(_ output: Data) throws {
        try call { rules, error in
            output.withUnsafeBytes {
                portal_fed_terminal_feed(rules, $0.bindMemory(to: CChar.self).baseAddress, $0.count, error)
            }
        }
    }

    func holdGrid(columns: UInt32, rows: UInt32) throws {
        try call { portal_fed_terminal_hold_grid($0, columns, rows, $1) }
    }

    /// The package's session says its terminal has this grid now.
    func tookGrid(columns: UInt32, rows: UInt32) {
        if let rules { portal_fed_terminal_took_grid(rules, columns, rows) }
    }

    func pane(width: Double, height: Double, scale: Double) {
        if let rules { portal_fed_terminal_pane(rules, width, height, scale) }
    }

    func cell(width: Double, height: Double) {
        if let rules { portal_fed_terminal_cell(rules, width, height) }
    }

    private func backlog() {
        if let rules { portal_fed_terminal_backlog(rules) }
    }

    /// BODY with the rules and a place for their error, which it throws.
    private func call(_ body: (OpaquePointer, UnsafeMutablePointer<portal_text>) -> Bool) throws {
        guard let rules else { throw NativeError.message("The terminal is closed") }
        var error = portal_text(data: nil, length: 0)
        guard !body(rules, &error) else { return }
        defer { free(error.data) }
        let message = error.data.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: error.length), as: UTF8.self)
        }
        throw NativeError.message(message ?? "Portal is out of memory")
    }

    // What the rules ask of the Mac, on the main thread.

    private nonisolated static func of(_ context: UnsafeMutableRawPointer?) -> FedRules {
        Unmanaged<FedRules>.fromOpaque(context!).takeUnretainedValue()
    }

    private static let backend: UnsafePointer<portal_fed_backend> = {
        let table = UnsafeMutablePointer<portal_fed_backend>.allocate(capacity: 1)
        table.initialize(to: portal_fed_backend(
            feed: { context, bytes, length in
                let rules = of(context), output = Data(bytes: bytes!, count: length)
                MainActor.assumeIsolated { rules.session.receive(output) }
            },
            drain: { context in
                let rules = of(context)
                MainActor.assumeIsolated { _ = rules.session.waitForPendingOutput() }
            },
            pending: { context in
                let rules = of(context)
                return MainActor.assumeIsolated { max(0, rules.session.pendingOutputByteCount) }
            },
            start_timer: { context, timer, milliseconds in
                let rules = of(context)
                MainActor.assumeIsolated { rules.start(timer, milliseconds) }
            },
            stop_timer: { context, timer in
                let rules = of(context)
                MainActor.assumeIsolated { rules.stop(timer) }
            },
            place: { context, rect in
                let rules = of(context)
                let frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                MainActor.assumeIsolated {
                    guard let terminal = rules.terminal, terminal.frame != frame else { return }
                    terminal.frame = frame
                }
            }))
        return UnsafePointer(table)
    }()

    private func start(_ timer: portal_fed_timer, _ milliseconds: UInt32) {
        timers[Int(timer.rawValue)] = Timer.scheduledTimer(
            withTimeInterval: Double(milliseconds) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let rules = self.rules else { return }
                self.timers[Int(timer.rawValue)] = nil
                portal_fed_terminal_timer(rules, timer)
            }
        }
    }

    private func stop(_ timer: portal_fed_timer) {
        timers[Int(timer.rawValue)]?.invalidate()
        timers[Int(timer.rawValue)] = nil
    }
}

/// Where a fed terminal's in-memory session reports the grid its terminal
/// has taken, from Ghostty's thread: its rules, made after the session.
@MainActor
private final class GridWatch {
    weak var rules: FedRules?
}

@MainActor
private final class HostedTerminal: TerminalView, TerminalSurfaceTitleDelegate,
    TerminalSurfacePwdDelegate, TerminalSurfaceGridResizeDelegate, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceCloseDelegate, TerminalSurfaceOpenURLDelegate, TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceMouseShapeDelegate, NativeSurface {
    var nativeView: NSView { pane ?? self }
    var input: NativeInput? { session?.input }
    weak var session: TerminalSession?
    func handleKeyEvent(_ event: NSEvent) -> Bool { session?.handleKeyEvent(event) ?? false }
    /// What the running program reported, "" until it does. Ghostty passes
    /// on only working directories reported from this host (OSC 7).
    var terminalTitle = ""
    var workingDirectory = ""
    var grid: TerminalGridMetrics?
    var terminalSurface: TerminalSurface?
    /// The process has ended. The view stays, showing its last output.
    var exited = false
    var progress = ""
    /// The executable of the process group in the foreground of its pty: the
    /// shell at a prompt, the program while one runs; "" until known and once
    /// the process has ended. Nothing announces that the shell started a
    /// program, so it is sampled at each report and about once a second.
    var program = ""
    private var programTimer: Timer?
    /// The pointer Ghostty last asked for: the hand over a link it would
    /// open, the I-beam over text, the arrow while a program has the mouse.
    private var mouseShape: TerminalMouseShape = .text
    /// A fed terminal's session: its output comes from the core and what it
    /// writes goes to the core. Nil for a terminal with its own pty.
    let fed: InMemoryTerminalSession?
    /// A fed terminal's rules; nil for any other.
    let rules: FedRules?
    /// A fed terminal's pane, which Portal places; nil for any other. The
    /// pane holds the terminal as its subview, and its session holds the
    /// pane, so the terminal's reference is weak: neither keeps the other.
    private weak var pane: FedPane?
    /// The padding Ghostty leaves inside a terminal on each side, in points,
    /// set rather than left to Ghostty's default, as a fed terminal's rules
    /// count on it: theirs, for every terminal.
    private static let padding = Int(PORTAL_FED_PADDING)

    init(directory: String?, command: String?, theme: TerminalTheme, points: Double, opacity: Double,
         fed: InMemoryTerminalSession? = nil, rules: FedRules? = nil, pane: FedPane? = nil) {
        self.fed = fed
        self.rules = rules
        self.pane = pane
        super.init(frame: .zero)
        delegate = self
        if let fed, let pane {
            rules?.terminal = self
            configuration = TerminalSurfaceOptions(backend: .inMemory(fed))
            pane.terminal = self
            pane.opacity = opacity
            pane.addSubview(self)
        } else {
            configuration = TerminalSurfaceOptions(
                workingDirectory: directory,
                envVars: ["INSIDE_EMACS": "portal-ghostty"],
                command: command,
                // Ghostty then reports the exit at once, as a close request,
                // which leaves the view and its last output.
                waitAfterCommand: false)
        }
        controller = TerminalController(theme: theme) { builder in
            builder.withFontThicken(false)
            // Every exit takes that path: none counts as a failed launch.
            builder.withCustom("abnormal-command-exit-runtime", "0")
            builder.withCustom("window-padding-x", "\(Self.padding)")
            builder.withCustom("window-padding-y", "\(Self.padding)")
            builder.withCustom("window-padding-balance", "false")
            builder.withFontSize(Float(points))
            builder.withCustom("background-opacity", Self.configLiteral(Self.ownOpacity(opacity, fed: fed != nil)))
        }
    }

    /// The theme's background beside a fed terminal's grid.
    func setBackground(_ color: NSColor) { pane?.background = color }

    /// The opacity Ghostty draws a terminal's own background at, for the
    /// terminal's OPACITY: a fed terminal's pane draws it below 1.
    static func ownOpacity(_ opacity: Double, fed: Bool) -> Double { fed && opacity < 1 ? 0 : opacity }

    /// A number as Ghostty's configuration reads it, without an exponent.
    private static func configLiteral(_ value: Double) -> String { String(format: "%.3f", value) }

    /// The background opacity of the configuration Ghostty last took: its
    /// last `background-opacity` line, or 1, Ghostty's default, without one.
    var configuredOpacity: Double {
        let entries = (controller?.renderedConfig.split(separator: "\n") ?? []).map {
            $0.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let value = entries.last { $0.count == 2 && $0[0] == "background-opacity" }?[1]
        return value.flatMap(Double.init) ?? 1
    }

    /// The opacity a fed terminal's pane draws its background at, or nil.
    var paneOpacity: Double? { pane?.opacity }

    /// Show the background at OPACITY from now on. A running terminal takes
    /// it as the controller's per-session override, which outlasts later
    /// themes and text sizes; only a new surface reads the configuration's line.
    func setOpacity(_ opacity: Double) throws {
        pane?.opacity = opacity
        guard let controller else { return }
        let own = TerminalConfiguration { $0.withBackgroundOpacity(Self.ownOpacity(opacity, fed: fed != nil)) }
        guard controller.terminalConfiguration != own else { return }
        guard controller.setTerminalConfiguration(own) else {
            throw NativeError.message(controller.lastConfigurationIssue ?? "Could not change the terminal's opacity")
        }
    }

    // A fed terminal's grid and its pane's, which its rules work out.

    /// The pane's size or scale changed: the rules size the terminal and
    /// report the pane's grid.
    func fitInPane() {
        guard let pane else { return }
        rules?.pane(width: Double(pane.bounds.width), height: Double(pane.bounds.height),
                    scale: Double(pane.convertToBacking(NSSize(width: 1, height: 1)).width))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        progress = "\(state)"
        refreshProgram()
        session?.changed()
    }
    // A fed terminal's title and directory are the core's to describe,
    // from its program's own reports (portal.h).
    func terminalDidChangeTitle(_ title: String) {
        guard fed == nil, title != terminalTitle else { return }
        terminalTitle = title
        refreshProgram()
        session?.changed()
    }
    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard fed == nil, path != workingDirectory else { return }
        workingDirectory = path
        refreshProgram()
        session?.changed()
    }
    func terminalDidResize(_ size: TerminalGridMetrics) {
        guard size != grid else { return }
        grid = size
        // A new cell size changes the frame that holds the grid, and the
        // pane's grid.
        rules?.cell(width: Double(size.cellWidthPixels), height: Double(size.cellHeightPixels))
    }
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        terminalSurface = surface
        programTimer?.invalidate()
        // A fed terminal has no pty, so no program to sample.
        guard fed == nil else { return }
        programTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.refreshProgram() else { return }
                self.session?.changed()
            }
        }
    }
    func terminalDidDetachSurface() {
        terminalSurface = nil
        stopSamplingProgram()
    }

    /// Note the foreground program now; true when it is not the one noted.
    @discardableResult
    private func refreshProgram() -> Bool {
        let current = exited ? "" : foregroundProgram()
        guard current != program else { return false }
        program = current
        return true
    }

    /// The executable of the pty's foreground process group, "" when there is
    /// none or it cannot be read.
    private func foregroundProgram() -> String {
        guard let pid = foregroundPid else { return "" }
        var path = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return "" }
        return String(decoding: path.prefix(Int(length)), as: UTF8.self)
    }

    /// The run loop keeps a scheduled timer whatever happens to its owner, so
    /// the session also stops it when the view closes while the shell runs:
    /// Ghostty frees the surface only once this view is gone, when its
    /// detach callback has nobody to reach.
    func stopSamplingProgram() {
        programTimer?.invalidate()
        programTimer = nil
    }

    /// Ghostty asks to close the surface when its process ends, at each key
    /// press after that, and when a close is requested while the process
    /// still runs. Portal keeps the view: the end is reported, and a key
    /// after it returns the keyboard to Emacs.
    func terminalDidClose(processAlive: Bool) {
        if !processAlive && !exited {
            exited = true
            program = ""
            stopSamplingProgram()
            session?.changed()
        } else {
            session?.returnFocus()
        }
    }
    /// Ghostty's pointer, held in the terminal's own cursor rectangle,
    /// which wins over the one Emacs keeps over its whole frame and holds
    /// through Emacs redoing its own. Ghostty reports again at each move
    /// over a link; only a new shape redoes the rectangles.
    func terminalDidChangeMouseShape(_ shape: TerminalMouseShape) {
        guard shape != mouseShape else { return }
        mouseShape = shape
        window?.invalidateCursorRects(for: self)
        if let pane { window?.invalidateCursorRects(for: pane) }
    }

    var pointer: NSCursor {
        switch mouseShape {
        case .pointer: .pointingHand
        case .text: .iBeam
        case .notAllowed: .operationNotAllowed
        case .default, .other: .arrow
        }
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: pointer)
    }

    func terminalDidRequestOpenURL(_ text: String, kind: TerminalOpenURLKind) {
        guard let url = URL(string: text),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The terminal view kind: one Ghostty session. Its shell starts in the parking
/// window when the view opens, and keeps running while the view is hidden.
/// The core owns Portal's terminal rules (native/Core/terminals.c): it checks
/// the options and theme names, and calls the primitives below on one session.
@MainActor
final class TerminalSession: PortalView {
    let target: String
    private let terminal: HostedTerminal
    /// A fed terminal's pane, the view Portal places, which holds the terminal.
    private let pane: NSView?
    var surface: any NativeSurface { terminal }
    let input: NativeInput

    init(target: String, options: ViewOptions) throws {
        let directory = try options.string("directory")
        let theme = try Terminals.theme(named: options.string("theme"))
        let points = portal_terminal_points(try options.number("points") ?? Double(PORTAL_TERMINAL_POINTS))
        let opacity = try options.number("opacity") ?? 1
        self.target = target
        let terminal: HostedTerminal
        if options.flag("fed") {
            // Its program runs elsewhere: what it writes goes to the core,
            // in order, on Emacs's thread, as the core requires.
            let watch = GridWatch()
            let session = InMemoryTerminalSession(
                write: { bytes in
                    DispatchQueue.main.async { MainActor.assumeIsolated { Core.terminalInput(target, bytes) } }
                },
                resize: { viewport in
                    let columns = UInt32(viewport.columns), rows = UInt32(viewport.rows)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { watch.rules?.tookGrid(columns: columns, rows: rows) }
                    }
                },
                suppressesTerminalResponses: true)
            let rules = try FedRules(target: target, session: session)
            let pane = FedPane()
            terminal = HostedTerminal(directory: directory, command: nil, theme: theme, points: points,
                                      opacity: opacity, fed: session, rules: rules, pane: pane)
            self.pane = pane
            watch.rules = rules
            terminal.setBackground(try Terminals.background(named: options.string("theme")))
        } else {
            guard let directory else {
                throw NativeError.message("The core passed a terminal without a :directory")
            }
            terminal = HostedTerminal(directory: directory, command: try terminalCommand(options, directory: directory),
                                      theme: theme, points: points, opacity: opacity)
            pane = nil
        }
        if let issue = terminal.controller?.lastConfigurationIssue { throw NativeError.message(issue) }
        self.terminal = terminal
        input = NativeInput(target: target, view: terminal, host: NativeView.parking) { [weak terminal] in
            guard let terminal, !terminal.isHiddenOrHasHiddenAncestor else { return false }
            return terminal.acquireProgrammaticFocus()
        }
        terminal.session = self
    }

    /// Ghostty makes its surface once the view is in a window.
    func opened() throws {
        terminal.fitToSize()
        guard terminal.terminalSurface != nil else {
            throw NativeError.message("Ghostty could not create a Metal terminal surface")
        }
    }

    func attached() {
        terminal.setSurfaceVisible(true)
        terminal.fitToSize()
    }

    /// Parking keeps the last size, so hiding never resizes the shell's grid.
    func detaching() { terminal.setSurfaceVisible(false) }

    /// Destroying the view ends its process; nothing is left sampling it,
    /// and a fed terminal's rules, with their timers, go: what waits is
    /// never fed. A surface Ghostty makes again keeps them.
    func close() {
        terminal.stopSamplingProgram()
        terminal.rules?.close()
    }

    func describe() -> [(String, ViewValue)] {
        // A fed terminal's program runs elsewhere: the core describes it.
        let program: [(String, ViewValue)] = terminal.fed != nil ? [] :
            [("title", .string(terminal.terminalTitle)),
             ("pwd", .string(terminal.workingDirectory)),
             ("program", .string(terminal.program)),
             ("exited", .flag(terminal.exited))]
        return [("ready", .flag(terminal.terminalSurface != nil))] + program + [
         ("progress", .string(terminal.progress)),
         ("columns", .integer(Int(terminal.grid?.columns ?? 0))),
         ("rows", .integer(Int(terminal.grid?.rows ?? 0))),
         // Ghostty keeps a size as a Float; hundredths are what Lisp sent.
         ("points", .number((Double(terminal.fontSize ?? 0) * 100).rounded() / 100)),
         ("layer", .string(terminal.layer.map { NSStringFromClass(type(of: $0)) } ?? "")),
         // Diagnostics: Ghostty's own background opacity, and a fed pane's.
         ("ghostty-opacity", .number(terminal.configuredOpacity))]
            + (terminal.paneOpacity.map { [("pane-opacity", .number($0))] } ?? [])
    }

    // The terminal primitives of native/Core/include/portal.h.

    // A fed terminal's output is parsed in order off the main thread, with
    // the replies to its queries dropped (the session's
    // suppressesTerminalResponses), and held until the surface exists, or
    // while the terminal takes a grid: its rules say what the two do.

    func feed(_ output: Data) throws {
        guard let rules = terminal.rules else { throw NativeError.message("Only a fed terminal is fed its output") }
        try rules.feed(output)
    }

    func holdGrid(columns: UInt32, rows: UInt32) throws {
        guard let rules = terminal.rules else { throw NativeError.message("Only a fed terminal holds a grid") }
        try rules.holdGrid(columns: columns, rows: rows)
    }

    func applyTheme(_ name: String?) throws {
        let theme = try Terminals.theme(named: name)
        if terminal.fed != nil { terminal.setBackground(try Terminals.background(named: name)) }
        guard let controller = terminal.controller, controller.theme != theme else { return }
        guard controller.setTheme(theme) else {
            throw NativeError.message(controller.lastConfigurationIssue ?? "Could not apply terminal theme")
        }
    }

    func setOpacity(_ opacity: Double) throws { try terminal.setOpacity(opacity) }

    /// Ghostty's own size binding, which marks the size as chosen, so a
    /// later theme, which reloads the configuration, keeps it.
    func setTextSize(_ points: Double) throws {
        guard terminal.performBindingAction("set_font_size:" + String(format: "%g", points)) else {
            throw NativeError.message("No terminal accepting text size changes")
        }
    }

    func paste(_ text: String) throws {
        guard terminal.paste(text: text) else { throw NativeError.message("No terminal accepting input") }
    }

    /// Ghostty copies only a selection, and does nothing without one.
    func copy() throws { terminal.performBindingAction("copy_to_clipboard") }

    func paste() throws {
        guard terminal.performBindingAction("paste_from_clipboard") else {
            throw NativeError.message("No terminal accepting input")
        }
    }

    func pressEnter() throws {
        guard terminal.sendKey(.enter) else { throw NativeError.message("No terminal accepting input") }
    }

    /// Select all and read the selection, which stays active.
    func text() throws -> String {
        guard let surface = terminal.terminalSurface else {
            throw NativeError.message("No terminal surface to copy")
        }
        guard surface.performBindingAction("select_all") else {
            throw NativeError.message("Ghostty could not select terminal text")
        }
        return surface.readSelection() ?? ""
    }

    func returnFocus() { input.host.returnFocus(from: terminal) }

    /// Its title, working directory, program or exit changed; the core tells Emacs.
    func changed() { Core.terminalChanged(target) }

    /// The core decides what each key does. Ghostty gets the rest, which
    /// never includes a Super chord: the core hands those to Emacs, where
    /// Command-= is `text-scale-adjust` in this buffer, or to the view's
    /// shortcuts.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if input.handleKeyEvent(event) { return true }
        switch event.type {
        case .keyDown: terminal.keyDown(with: event)
        case .keyUp: terminal.keyUp(with: event)
        case .flagsChanged: terminal.flagsChanged(with: event)
        default: break
        }
        return true
    }
}

/// The Ghostty theme catalog.
@MainActor
enum Terminals {
    static func themeNames() -> [String] { GhosttyThemeCatalog.allThemes.map(\.name) }

    /// The theme NAME, which the core has checked, or the default for nil,
    /// which follows the system's appearance.
    static func theme(named name: String?) throws -> TerminalTheme {
        guard let name else { return .default }
        guard let theme = GhosttyThemeCatalog.theme(named: name) else {
            throw NativeError.message("Unknown terminal theme: \(name)")
        }
        return theme.toTerminalTheme()
    }

    /// The background of the theme NAME, or of the default theme for nil,
    /// which is Alabaster's in the light appearance and Afterglow's in the
    /// dark one.
    static func background(named name: String?) throws -> NSColor {
        func color(_ theme: String) -> NSColor {
            let hex = GhosttyThemeCatalog.theme(named: theme)?.background ?? ""
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count >= 6, let value = UInt32(digits.prefix(6), radix: 16) else {
                return .textBackgroundColor
            }
            return NSColor(srgbRed: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
                           blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
        guard let name else {
            let light = color("Alabaster"), dark = color("Afterglow")
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }
        guard GhosttyThemeCatalog.theme(named: name) != nil else {
            throw NativeError.message("Unknown terminal theme: \(name)")
        }
        return color(name)
    }
}
