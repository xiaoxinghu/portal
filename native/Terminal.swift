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
/// the pane's top-left as a local terminal's, or at its bottom-left while
/// another client sizes the block, so a shell's prompt and cursor stay in
/// view; the rest of the pane is the theme's background
/// (`portal_terminal_place`).
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

/// The frame a fed terminal showed when the core began holding it, over
/// the terminal, which is hidden meanwhile, until the core lets it go
/// (`portal_terminal_hold_frame`). It shows Ghostty's own surface, which
/// the renderer never draws into again once the terminal's size changes:
/// a frame of another size goes into a new one. It stays where the
/// terminal was, from the pane's top or bottom as the terminal hangs, and
/// the pointer goes through it to the terminal.
@MainActor
private final class FrameStill: NSView {
    init(frame: NSRect, contents: Any, scale: CGFloat, fromBottom: Bool) {
        super.init(frame: frame)
        let still = CALayer()
        still.contents = contents
        still.contentsScale = scale
        still.contentsGravity = .topLeft
        still.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        // Layer-hosting, as Ghostty's own view is: AppKit leaves it alone.
        layer = still
        wantsLayer = true
        autoresizingMask = fromBottom ? [.maxYMargin] : [.minYMargin]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    /// A fed terminal's target, which what it tells the core's rules for it
    /// names; nil for any other terminal.
    private let fedTarget: String?
    /// The core has placed a fed terminal in its pane. Until then it fills
    /// the pane: Ghostty makes no surface for a view of no size, and the
    /// core places it only once the view is created.
    var placed = false
    /// The core hangs a fed terminal's grid from its pane's bottom-left.
    var fromBottom = false
    /// The frame shown while the core holds it, or nil.
    private var still: FrameStill?
    /// A fed terminal's pane, which Portal places; nil for any other. The
    /// pane holds the terminal as its subview, and its session holds the
    /// pane, so the terminal's reference is weak: neither keeps the other.
    private weak var pane: FedPane?
    /// The padding Ghostty leaves inside a terminal on each side, in points,
    /// set rather than left to Ghostty's default, as the core's geometry of a
    /// fed terminal counts on it: portal.h's, for every terminal.
    private static let padding = Int(PORTAL_TERMINAL_PADDING)

    init(directory: String?, command: String?, theme: TerminalTheme, points: Double, opacity: Double,
         fed: InMemoryTerminalSession? = nil, target: String? = nil, pane: FedPane? = nil) {
        self.fed = fed
        fedTarget = target
        self.pane = pane
        super.init(frame: .zero)
        delegate = self
        if let fed, let pane {
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

    /// The background a fed terminal's pane draws in its appearance now, the
    /// theme's for it, as "rrggbb" in sRGB, or nil.
    var paneBackground: String? {
        guard let pane else { return nil }
        var color: CGColor?
        pane.effectiveAppearance.performAsCurrentDrawingAppearance { color = pane.background.cgColor }
        return color.flatMap(Self.hex)
    }

    private static func hex(_ color: CGColor) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        return components.prefix(3).map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

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

    // A fed terminal's grid and its pane's, which the core's rules work
    // out from what the terminal tells them.

    /// Show the frame on the screen now in place of the terminal while
    /// HOLD, and the terminal again, as Ghostty last drew it, once not.
    /// Nothing is held before Ghostty has drawn.
    func holdFrame(_ hold: Bool) {
        guard let pane else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if hold {
            guard still == nil, let contents = layer?.contents else { return }
            let view = FrameStill(frame: frame, contents: contents, scale: layer?.contentsScale ?? 1,
                                  fromBottom: fromBottom)
            pane.addSubview(view, positioned: .above, relativeTo: self)
            alphaValue = 0
            still = view
        } else if let view = still {
            alphaValue = 1
            view.removeFromSuperview()
            still = nil
        }
    }
    var holdsFrame: Bool { still != nil }

    /// The pane's size or scale changed: the core places the terminal and
    /// works out the pane's grid. Ghostty counts 72 points to the inch here,
    /// so its padding is the padding's points times the scale, in pixels.
    func fitInPane() {
        guard let pane, let fedTarget else { return }
        if !placed { frame = pane.bounds }
        let scale = Double(pane.convertToBacking(NSSize(width: 1, height: 1)).width)
        Core.terminalPane(fedTarget, width: Double(pane.bounds.width), height: Double(pane.bounds.height),
                          scale: scale, padding: Double(Self.padding) * scale)
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
        if let fedTarget {
            Core.terminalCell(fedTarget, width: Double(size.cellWidthPixels),
                              height: Double(size.cellHeightPixels))
        }
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
        // A dark theme comes only with a light one (portal.h).
        let light = try options.string("theme"), dark = try options.string("dark-theme") ?? light
        let theme = try Terminals.theme(light: light, dark: dark)
        let points = portal_terminal_points(try options.number("points") ?? Double(PORTAL_TERMINAL_POINTS))
        let opacity = try options.number("opacity") ?? 1
        self.target = target
        let terminal: HostedTerminal
        if options.flag("fed") {
            // Its program runs elsewhere: what it writes, and each grid it
            // takes, go to the core, in order, on Emacs's thread, as the
            // core requires.
            let session = InMemoryTerminalSession(
                write: { bytes in
                    DispatchQueue.main.async { MainActor.assumeIsolated { Core.terminalInput(target, bytes) } }
                },
                resize: { viewport in
                    let columns = UInt32(viewport.columns), rows = UInt32(viewport.rows)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { Core.terminalTookGrid(target, columns: columns, rows: rows) }
                    }
                },
                suppressesTerminalResponses: true)
            // The session says when its unparsed output crosses the core's
            // marks, on whichever thread crossed one, after its lock is
            // released: the core reads the count itself, on the main thread.
            session.setOutputBacklogHandler(highWater: Int(PORTAL_TERMINAL_BACKLOG),
                                            lowWater: Int(PORTAL_TERMINAL_BACKLOG_LOW)) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Core.terminalBacklog(target) } }
            }
            let pane = FedPane()
            terminal = HostedTerminal(directory: directory, command: nil, theme: theme, points: points,
                                      opacity: opacity, fed: session, target: target, pane: pane)
            self.pane = pane
            terminal.setBackground(try Terminals.background(light: light, dark: dark))
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

    /// Destroying the view ends its process, and nothing is left sampling
    /// it. A fed terminal's rules are the core's, which forgets them.
    func close() {
        terminal.stopSamplingProgram()
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
         // Diagnostics: Ghostty's own background opacity, and a fed pane's
         // opacity and background.
         ("ghostty-opacity", .number(terminal.configuredOpacity))]
            + (terminal.paneOpacity.map { [("pane-opacity", .number($0))] } ?? [])
            + (terminal.fed != nil ? [("frame-held", .flag(terminal.holdsFrame))] : [])
            + (terminal.paneBackground.map { [("pane-background", .string($0))] } ?? [])
    }

    // The terminal primitives of native/Core/include/portal.h.

    // A fed terminal's primitives, for the core's rules. Its output is
    // parsed in order off the main thread by the package's in-memory
    // session, with the replies to its queries dropped (the session's
    // suppressesTerminalResponses), and held until the surface exists.

    private func fedSession() throws -> InMemoryTerminalSession {
        guard let fed = terminal.fed else { throw NativeError.message("Only a fed terminal is fed its output") }
        return fed
    }

    func parse(_ output: Data) throws { try fedSession().receive(output) }

    func drain() throws { _ = try fedSession().waitForPendingOutput() }

    func pending() throws -> Int { max(0, try fedSession().pendingOutputByteCount) }

    /// The terminal's frame in its clipping pane, hung from its top-left or
    /// bottom-left corner.
    func place(_ frame: CGRect, fromBottom: Bool) throws {
        _ = try fedSession()
        terminal.placed = true
        terminal.fromBottom = fromBottom
        if terminal.frame != frame { terminal.frame = frame }
    }

    func holdFrame(_ hold: Bool) throws {
        _ = try fedSession()
        terminal.holdFrame(hold)
    }

    func applyTheme(light: String?, dark: String?) throws {
        let theme = try Terminals.theme(light: light, dark: dark)
        if terminal.fed != nil { terminal.setBackground(try Terminals.background(light: light, dark: dark)) }
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

    /// The theme LIGHT in the light appearance and DARK in the dark one,
    /// names the core has checked, the same for a theme fixed in both; or
    /// the default for nil, which follows the appearance too. The package's
    /// view picks the side as its appearance changes.
    static func theme(light: String?, dark: String?) throws -> TerminalTheme {
        guard let light else { return .default }
        let dark = dark ?? light
        let configuration = try definition(light).toTerminalConfiguration()
        return TerminalTheme(light: configuration,
                             dark: dark == light ? configuration : try definition(dark).toTerminalConfiguration())
    }

    /// The background of the theme LIGHT in the light appearance and DARK in
    /// the dark one, or of the default theme for nil, which is Alabaster's
    /// in the light appearance and Afterglow's in the dark one.
    static func background(light: String?, dark: String?) throws -> NSColor {
        guard let light else { return try background(light: "Alabaster", dark: "Afterglow") }
        let dark = dark ?? light
        let lightColor = color(try definition(light).background)
        guard dark != light else { return lightColor }
        let darkColor = color(try definition(dark).background)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    private static func definition(_ name: String) throws -> GhosttyThemeDefinition {
        guard let theme = GhosttyThemeCatalog.theme(named: name) else {
            throw NativeError.message("Unknown terminal theme: \(name)")
        }
        return theme
    }

    /// The color of HEX, a theme's "#rrggbb".
    private static func color(_ hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count >= 6, let value = UInt32(digits.prefix(6), radix: 16) else {
            return .textBackgroundColor
        }
        return NSColor(srgbRed: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
