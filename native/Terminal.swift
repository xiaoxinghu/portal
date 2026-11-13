// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import GhosttyTerminal
import GhosttyTheme
import PortalCore

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
@MainActor
private final class FedPane: NSView {
    weak var terminal: HostedTerminal?
    /// The theme's background, for the light and the dark appearance.
    var background: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }

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
            layer?.backgroundColor = background.cgColor
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
}

/// Where a fed terminal's in-memory session reports the grid its terminal
/// has taken, from Ghostty's thread.
@MainActor
private final class GridWatch {
    weak var terminal: HostedTerminal?
}

@MainActor
private final class HostedTerminal: TerminalView, TerminalSurfaceTitleDelegate,
    TerminalSurfacePwdDelegate, TerminalSurfaceGridResizeDelegate, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceCloseDelegate, TerminalSurfaceOpenURLDelegate, TerminalSurfaceProgressReportDelegate, NativeSurface {
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
    /// A fed terminal's session: its output comes from the core and what it
    /// writes goes to the core. Nil for a terminal with its own pty.
    let fed: InMemoryTerminalSession?
    /// A fed terminal's pane, which Portal places; nil for any other. The
    /// pane holds the terminal as its subview, and its session holds the
    /// pane, so the terminal's reference is weak: neither keeps the other.
    private weak var pane: FedPane?
    /// The padding Ghostty leaves inside a terminal on each side, in points,
    /// set rather than left to Ghostty's default, as the grids below count on it.
    private static let padding = 2.0
    /// The grid the core gave a fed terminal, which it holds whatever its
    /// pane's size; nil until the core gives one, while it fills its pane.
    private var heldGrid: (columns: UInt32, rows: UInt32)?
    /// The grid the in-memory session last said its terminal has.
    private var takenGrid: (columns: UInt32, rows: UInt32)?
    /// What the core gave a fed terminal, in order, that waits while it
    /// takes a grid: output, and grids.
    private enum Fed { case output(Data), grid(UInt32, UInt32) }
    private var waiting: [Fed] = []
    private var takingGrid: Timer?
    /// The pane's grid and cell size, as last reported to the core.
    private var reportedPane: [UInt32] = []

    init(directory: String?, command: String?, theme: TerminalTheme, points: Double,
         fed: InMemoryTerminalSession? = nil, pane: FedPane? = nil) {
        self.fed = fed
        self.pane = pane
        super.init(frame: .zero)
        delegate = self
        if let fed, let pane {
            configuration = TerminalSurfaceOptions(backend: .inMemory(fed))
            pane.terminal = self
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
            builder.withCustom("window-padding-x", "\(Int(Self.padding))")
            builder.withCustom("window-padding-y", "\(Int(Self.padding))")
            builder.withCustom("window-padding-balance", "false")
            builder.withFontSize(Float(points))
        }
    }

    /// The theme's background beside a fed terminal's grid.
    func setBackground(_ color: NSColor) { pane?.background = color }

    // A fed terminal's grid and its pane's.

    /// The size of a cell in pixels, and pixels per point, once known.
    private var cell: (width: Double, height: Double, scale: Double)? {
        guard let grid, grid.cellWidthPixels > 0, grid.cellHeightPixels > 0 else { return nil }
        let scale = Double(convertToBacking(NSSize(width: 1, height: 1)).width)
        guard scale > 0 else { return nil }
        return (Double(grid.cellWidthPixels), Double(grid.cellHeightPixels), scale)
    }

    /// Size the terminal to the grid it holds, at its pane's bottom-left, or
    /// to its pane until it holds one; then report the pane's grid.
    func fitInPane() {
        guard let pane else { return }
        var frame = pane.bounds
        if let held = heldGrid, let cell {
            // The grid, Ghostty's padding, and half a cell to spare, so that
            // rounding never loses a row or a column. Ghostty leaves the
            // spare below the grid and to its right, so the view hangs that
            // much below the pane: the grid's last row sits at the pane's
            // bottom, and a grid that fits the pane is never clipped.
            let padding = 2 * Self.padding * cell.scale
            frame = CGRect(x: 0, y: -cell.height / 2 / cell.scale,
                           width: (Double(held.columns) * cell.width + padding + cell.width / 2) / cell.scale,
                           height: (Double(held.rows) * cell.height + padding + cell.height / 2) / cell.scale)
        }
        if self.frame != frame { self.frame = frame }
        reportPane()
    }

    /// Tell the core the grid the pane would hold, whatever grid the
    /// terminal holds: the size Emacs gives the block when it owns it.
    private func reportPane() {
        guard let pane, let cell, let target = session?.target else { return }
        let padding = 2 * Self.padding * cell.scale
        let columns = max(0, (Double(pane.bounds.width) * cell.scale - padding) / cell.width)
        let rows = max(0, (Double(pane.bounds.height) * cell.scale - padding) / cell.height)
        let values = [UInt32(columns), UInt32(rows), UInt32(cell.width), UInt32(cell.height)]
        guard values[0] > 0, values[1] > 0, values != reportedPane else { return }
        reportedPane = values
        Core.terminalGrid(target, columns: values[0], rows: values[1],
                          cellWidth: values[2], cellHeight: values[3])
    }

    /// The core's output and grids, in order: a grid waits for the output
    /// before it to be parsed, and holds the output after it until the
    /// terminal has taken it, for at most a quarter of a second.
    private func flush() {
        while takingGrid == nil, !waiting.isEmpty {
            switch waiting.removeFirst() {
            case let .output(data):
                fed?.receive(data)
            case let .grid(columns, rows):
                fed?.waitForPendingOutput()
                heldGrid = (columns, rows)
                fitInPane()
                if takenGrid.map({ $0 != (columns, rows) }) ?? true {
                    takingGrid = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.tookGrid() }
                    }
                }
            }
        }
    }

    private func tookGrid() {
        takingGrid?.invalidate()
        takingGrid = nil
        flush()
    }

    /// The in-memory session says its terminal has this grid now.
    func viewportResized(columns: UInt32, rows: UInt32) {
        takenGrid = (columns, rows)
        if takingGrid != nil, let held = heldGrid, held == (columns, rows) { tookGrid() }
    }

    func holdGrid(columns: UInt32, rows: UInt32) {
        waiting.append(.grid(columns, rows))
        flush()
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
        fitInPane()
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
        takingGrid?.invalidate()
        takingGrid = nil
    }

    /// A fed terminal's output: parsed in order off the main thread, with
    /// the replies to its queries dropped (the session's
    /// suppressesTerminalResponses), and held until the surface exists, or
    /// while the terminal takes a grid.
    func feed(_ output: Data) {
        waiting.append(.output(output))
        flush()
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
    func terminalDidRequestOpenURL(_ text: String, kind: TerminalOpenURLKind) {
        guard let url = URL(string: text),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A fed terminal's backlog, told to the core on Emacs's thread. The
/// session's handler only says when to look: it runs on whichever thread
/// crossed a mark, after the session's lock is released, so two calls can
/// arrive in the other order than their crossings. So the main thread reads
/// how much is unparsed itself, and while the core is told to wait, reads
/// again every 10 ms until it is down to the low mark: a crossing whose
/// call came first can leave nothing waiting.
@MainActor
private final class FedBacklog {
    private let target: String
    private weak var session: InMemoryTerminalSession?
    /// What the core was last told.
    private var waiting = false
    private var timer: Timer?

    init(target: String, session: InMemoryTerminalSession) {
        self.target = target
        self.session = session
    }

    nonisolated func crossed() {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { look() } }
    }

    private func look() {
        let pending = session?.pendingOutputByteCount ?? 0
        let backlogged = pending > Int(PORTAL_TERMINAL_BACKLOG) / 4
        if backlogged != waiting {
            waiting = backlogged
            Core.terminalBacklog(target, backlogged)
        }
        timer?.invalidate()
        timer = nil
        if backlogged {
            timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
        }
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
                        MainActor.assumeIsolated { watch.terminal?.viewportResized(columns: columns, rows: rows) }
                    }
                },
                suppressesTerminalResponses: true)
            // The core stops feeding it while it has too much to parse.
            let backlog = FedBacklog(target: target, session: session)
            session.setOutputBacklogHandler(highWater: Int(PORTAL_TERMINAL_BACKLOG),
                                            lowWater: Int(PORTAL_TERMINAL_BACKLOG) / 4) { _ in
                backlog.crossed()
            }
            let pane = FedPane()
            terminal = HostedTerminal(directory: directory, command: nil, theme: theme, points: points,
                                      fed: session, pane: pane)
            self.pane = pane
            watch.terminal = terminal
            terminal.setBackground(try Terminals.background(named: options.string("theme")))
        } else {
            guard let directory else {
                throw NativeError.message("The core passed a terminal without a :directory")
            }
            terminal = HostedTerminal(directory: directory, command: try terminalCommand(options, directory: directory),
                                      theme: theme, points: points)
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

    /// Destroying the view ends its process; nothing is left sampling it.
    func close() { terminal.stopSamplingProgram() }

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
         ("layer", .string(terminal.layer.map { NSStringFromClass(type(of: $0)) } ?? ""))]
    }

    // The terminal primitives of native/Core/include/portal.h.

    func feed(_ output: Data) throws {
        guard terminal.fed != nil else { throw NativeError.message("Only a fed terminal is fed its output") }
        terminal.feed(output)
    }

    func holdGrid(columns: UInt32, rows: UInt32) throws {
        guard terminal.fed != nil else { throw NativeError.message("Only a fed terminal holds a grid") }
        guard columns > 0, rows > 0, columns <= UInt32(UInt16.max), rows <= UInt32(UInt16.max) else {
            throw NativeError.message("A terminal's grid has at least one cell each way")
        }
        terminal.holdGrid(columns: columns, rows: rows)
    }

    func applyTheme(_ name: String?) throws {
        let theme = try Terminals.theme(named: name)
        if terminal.fed != nil { terminal.setBackground(try Terminals.background(named: name)) }
        guard let controller = terminal.controller, controller.theme != theme else { return }
        guard controller.setTheme(theme) else {
            throw NativeError.message(controller.lastConfigurationIssue ?? "Could not apply terminal theme")
        }
    }

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
