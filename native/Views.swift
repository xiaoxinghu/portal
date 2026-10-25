// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A value from the options plist passed to `portal--open`: a string, t or nil.
enum ViewOption: Sendable {
    case string(String)
    case flag(Bool)
}

struct ViewOptions: Sendable {
    let values: [String: ViewOption]

    /// A string option; nil when absent or nil.
    func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .flag(false): return nil
        case .string(let value): return value
        case .flag(true): throw NativeError.message("Option :\(key) must be a string")
        }
    }

    /// A flag option; any non-nil value is true, as in Lisp.
    func flag(_ key: String) -> Bool {
        switch values[key] {
        case nil, .flag(false): return false
        default: return true
        }
    }
}

/// A value in a view's description, which `portal--inspect` returns.
enum ViewValue: Sendable {
    case flag(Bool)
    case integer(Int)
    case integers([Int])
    case string(String)
}

/// One view kind: its rendering, input and session. The C core owns each
/// view's identity and lifetime (native/Core/views.c), and `NativeView`
/// attaches it to frames and parks it; the kind only reacts.
@MainActor
protocol PortalView: AnyObject {
    /// Make the view, in no window yet. Its input starts in the parking window.
    init(target: String, options: ViewOptions) throws
    var surface: any NativeSurface { get }
    var input: NativeInput { get }
    /// The view is in a window for the first time: the parking window.
    func opened() throws
    /// The view is now shown in a frame.
    func attached()
    /// The view is about to be parked.
    func detaching()
    /// End the page or session, before the view leaves its window.
    func close()
    /// What only the view knows; `NativeView` adds focus, and the core the rest.
    func describe() -> [(String, ViewValue)]
    /// Copy the app's selection, and paste the clipboard into it, as its own
    /// Copy and Paste commands do.
    func copy() throws
    func paste() throws
}

extension PortalView {
    func opened() throws {}
    func attached() {}
    func detaching() {}
    func close() {}
}

/// A Portal view as the core holds it, from `portal_view_create` to
/// `portal_view_destroy`: one kind's session, and the window it is in. A view
/// is always in a window: a frame's while it is attached, otherwise the
/// parking window. It moves between windows inside one call, so it is never
/// windowless, and Ghostty keeps draining its PTY.
@MainActor
final class NativeView {
    /// Detached views live in this offscreen window, which is never shown, so
    /// their sessions keep running whatever happens to Emacs frames.
    private static let parkingWindow: NSWindow = {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 960, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }()
    static let parking = NativeHost.bind(window: parkingWindow)!

    let kind: any PortalView
    private var host = NativeView.parking
    /// Where the view is in its window. Parking keeps it, so hiding never
    /// resizes the page or the shell's grid.
    private var rectangle: CGRect

    /// Make a view of TYPE, in the parking window with its session running.
    convenience init(_ type: any PortalView.Type, target: String, options: ViewOptions) throws {
        try self.init(type.init(target: target, options: options))
    }

    /// Hold KIND, a view made by other means, such as a page's new window.
    init(_ kind: any PortalView) throws {
        self.kind = kind
        rectangle = host.view?.bounds ?? .zero
        move(to: host)
        do { try kind.opened() } catch {
            close()
            throw error
        }
        detach()
    }

    /// Show the view in HOST at RECTANGLE. Checked before anything moves, so
    /// a failure leaves the view where it was.
    func attach(to next: NativeHost, rectangle: CGRect) throws {
        guard next.view != nil else { throw NativeError.message("The view's frame was deleted") }
        self.rectangle = rectangle
        move(to: next)
        kind.attached()
    }

    func detach() {
        kind.detaching()
        move(to: Self.parking)
        host.hide(kind.surface)
    }

    func close() {
        kind.close()
        host.remove(kind.surface)
    }

    func describe() -> [(String, ViewValue)] {
        [("focused", .flag(host.ownsFocus(kind.surface.nativeView)))] + kind.describe()
    }

    /// Remove the view from its current window and add it to NEXT's, in one step.
    private func move(to next: NativeHost) {
        if next !== host {
            host.remove(kind.surface)
            host = next
            kind.input.host = next
        }
        next.place(kind.surface, rectangle: rectangle)
    }
}
