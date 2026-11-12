// SPDX-License-Identifier: GPL-3.0-or-later
// Stands in for the terminal kind, so the standalone AppKit checks build without Ghostty.
import AppKit

@MainActor
final class TerminalSession: PortalView {
    init(target: String, options: ViewOptions) throws {
        throw NativeError.message("The standalone checks have no terminals")
    }
    var surface: any NativeSurface { fail("The standalone checks have no terminals") }
    var input: NativeInput { fail("The standalone checks have no terminals") }
    func describe() -> [(String, ViewValue)] { [] }
    func applyTheme(_ name: String?) throws {}
    func paste(_ text: String) throws {}
    func pressEnter() throws {}
    func text() throws -> String { "" }
    func feed(_ output: Data) throws {}
    func setTextSize(_ points: Double) throws {}
    func copy() throws {}
    func paste() throws {}
}

@MainActor
enum Terminals {
    static func themeNames() -> [String] { [] }
}
