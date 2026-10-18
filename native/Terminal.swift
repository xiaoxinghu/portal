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

@MainActor
private final class HostedTerminal: TerminalView, TerminalSurfaceTitleDelegate,
    TerminalSurfacePwdDelegate, TerminalSurfaceGridResizeDelegate, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceCloseDelegate, TerminalSurfaceOpenURLDelegate, TerminalSurfaceProgressReportDelegate, NativeSurface {
    var nativeView: NSView { self }
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

    init(directory: String, command: String?, theme: TerminalTheme) {
        super.init(frame: .zero)
        delegate = self
        configuration = TerminalSurfaceOptions(
            workingDirectory: directory,
            envVars: ["INSIDE_EMACS": "portal-ghostty"],
            command: command,
            // Ghostty then reports the exit at once, as a close request,
            // which leaves the view and its last output.
            waitAfterCommand: false)
        controller = TerminalController(theme: theme) { builder in
            builder.withFontThicken(false)
            // Every exit takes that path: none counts as a failed launch.
            builder.withCustom("abnormal-command-exit-runtime", "0")
            builder.withFontSize(Float(PORTAL_TERMINAL_POINTS))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        progress = "\(state)"
        session?.changed()
    }
    func terminalDidChangeTitle(_ title: String) {
        guard title != terminalTitle else { return }
        terminalTitle = title
        session?.changed()
    }
    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard path != workingDirectory else { return }
        workingDirectory = path
        session?.changed()
    }
    func terminalDidResize(_ size: TerminalGridMetrics) { grid = size }
    func terminalDidAttachSurface(_ surface: TerminalSurface) { terminalSurface = surface }
    func terminalDidDetachSurface() { terminalSurface = nil }
    /// Ghostty asks to close the surface when its process ends, at each key
    /// press after that, and when a close is requested while the process
    /// still runs. Portal keeps the view: the end is reported, and a key
    /// after it returns the keyboard to Emacs.
    func terminalDidClose(processAlive: Bool) {
        if !processAlive && !exited {
            exited = true
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

/// The terminal view kind: one Ghostty session. Its shell starts in the parking
/// window when the view opens, and keeps running while the view is hidden.
/// The core owns Portal's terminal rules (native/Core/terminals.c): it checks
/// the options and theme names, and calls the primitives below on one session.
@MainActor
final class TerminalSession: PortalView {
    let target: String
    private let terminal: HostedTerminal
    var surface: any NativeSurface { terminal }
    let input: NativeInput

    init(target: String, options: ViewOptions) throws {
        guard let directory = try options.string("directory") else {
            throw NativeError.message("The core passed a terminal without a :directory")
        }
        self.target = target
        let terminal = HostedTerminal(directory: directory, command: try terminalCommand(options, directory: directory),
                                      theme: try Terminals.theme(named: options.string("theme")))
        if let issue = terminal.controller?.lastConfigurationIssue { throw NativeError.message(issue) }
        self.terminal = terminal
        input = NativeInput(target: target, view: terminal, host: NativeView.parking) { [weak terminal] in
            guard let terminal, !terminal.isHidden else { return false }
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

    func describe() -> [(String, ViewValue)] {
        [("ready", .flag(terminal.terminalSurface != nil)),
         ("title", .string(terminal.terminalTitle)),
         ("pwd", .string(terminal.workingDirectory)),
         ("exited", .flag(terminal.exited)),
         ("progress", .string(terminal.progress)),
         ("columns", .integer(Int(terminal.grid?.columns ?? 0))),
         ("rows", .integer(Int(terminal.grid?.rows ?? 0))),
         ("layer", .string(terminal.layer.map { NSStringFromClass(type(of: $0)) } ?? ""))]
    }

    // The terminal primitives of native/Core/include/portal.h.

    func applyTheme(_ name: String?) throws {
        let theme = try Terminals.theme(named: name)
        guard let controller = terminal.controller, controller.theme != theme else { return }
        guard controller.setTheme(theme) else {
            throw NativeError.message(controller.lastConfigurationIssue ?? "Could not apply terminal theme")
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

    /// Its title, working directory or exit changed; the core tells Emacs.
    func changed() { Core.terminalChanged(target) }

    /// The core decides what each key does, including text size shortcuts.
    /// Ghostty gets the rest, which never includes a Super chord: the core
    /// hands those to Emacs or to the view's shortcuts.
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
}
