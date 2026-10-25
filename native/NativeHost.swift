// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum NativeError: Error { case message(String) }

/// Where a key event goes: a view, or the view whose handoff Emacs is handling.
@MainActor
protocol NativeInputHandler: AnyObject {
    func handleKeyEvent(_ event: NSEvent) -> Bool
}

/// Feature views keep their own rendering, input policy and session lifetime.
@MainActor
protocol NativeSurface: NativeInputHandler {
    var nativeView: NSView { get }
    var input: NativeInput? { get }
}

extension NativeSurface {
    var input: NativeInput? { nil }
}

@MainActor
private final class WeakSurface {
    weak var value: (any NativeSurface)?
    init(_ value: any NativeSurface) { self.value = value }
}

/// Shared AppKit ownership for one Emacs frame. No WebKit or Ghostty dependency.
@MainActor
final class NativeHost: NSObject {
    private static let frames = NSMapTable<NSWindow, NativeHost>(
        keyOptions: .weakMemory, valueOptions: .weakMemory)
    private static var keyMonitor: Any?
    /// Where a key was pressed: its window, and the view whose key it was.
    private struct KeyOwner: Equatable {
        let window: Int
        let view: ObjectIdentifier?
    }
    // WebKit re-sends unhandled key-downs through NSApplication asynchronously.
    // Once delivered to a guest, they must not become Emacs commands later.
    private static let deliveredKeys = NSHashTable<NSEvent>(options: [.weakMemory, .objectPointerPersonality])
    private static var pressedKeys: [UInt16: KeyOwner] = [:]

    weak var view: NSView?
    private weak var editor: NSResponder?
    private var surfaces: [ObjectIdentifier: WeakSurface] = [:]

    private init(view: NSView) {
        self.view = view
        editor = view.window?.firstResponder
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated),
                                              name: NSWindow.didUpdateNotification, object: view.window)
    }

    static func bind(title: String) -> NativeHost? {
        guard let window = NSApp?.windows.first(where: { $0.title == title }) else { return nil }
        return bind(window: window)
    }

    static func bind(window: NSWindow) -> NativeHost? {
        guard let view = window.contentView else { return nil }
        if let host = frames.object(forKey: window), host.view === view { return host }
        let host = NativeHost(view: view)
        frames.setObject(host, forKey: window)
        return host
    }

    private var focusedSurface: (any NativeSurface)? {
        surfaces.values.compactMap(\.value).first { ownsFocus($0.nativeView) }
    }

    /// The view whose handoff Emacs is handling, or whose app has not answered
    /// a key press offered to it: key events in this window are its own.
    private var inputCapture: NativeInput? {
        surfaces.values.compactMap(\.value?.input).first { $0.trigger != nil }
    }

    @objc private func windowUpdated() {
        reclaimKeyboard()
        refreshOwnership()
    }

    /// Tell the core which views gained or lost the keyboard; it tells Emacs.
    func refreshOwnership() {
        for surface in surfaces.values.compactMap(\.value) { surface.input?.observe() }
    }

    func ownsFocus(_ surface: NSView) -> Bool {
        guard let responder = view?.window?.firstResponder as? NSView else { return false }
        return responder === surface || responder.isDescendant(of: surface)
    }

    func returnFocus(from surface: NSView) {
        if ownsFocus(surface) { view?.window?.makeFirstResponder(editor) }
        refreshOwnership()
    }

    /// Give the window's keyboard to Emacs if nothing in the window has it:
    /// as when a view took it to a window of its own, or a page asked for it
    /// on its way back and was refused, after Emacs's view had resigned.
    func reclaimKeyboard() {
        guard let window = view?.window, window.firstResponder === window, let editor else { return }
        window.makeFirstResponder(editor)
    }

    /// Show SURFACE at RECTANGLE, in Emacs's frame pixels from the top left.
    /// Callers check that the frame still has its `view` first.
    func place(_ surface: any NativeSurface, rectangle: CGRect) {
        guard let view else { return }
        _ = surface.input // Register shared input before the first focus or key event.
        let child = surface.nativeView
        var frame = rectangle
        frame.origin.x += view.bounds.minX
        frame.origin.y = view.isFlipped
            ? view.bounds.minY + rectangle.minY : view.bounds.maxY - rectangle.maxY
        if child.frame != frame { child.frame = frame }
        surfaces[ObjectIdentifier(surface)] = WeakSurface(surface)
        if child.superview !== view { view.addSubview(child) }
        child.isHidden = false
        child.layoutSubtreeIfNeeded()
        refreshOwnership()
        Self.startMonitoring()
    }

    /// Hiding deliberately retains the view. Features decide whether to remove it.
    func hide(_ surface: any NativeSurface) {
        returnFocus(from: surface.nativeView)
        surface.nativeView.isHidden = true
    }

    func remove(_ surface: any NativeSurface) {
        returnFocus(from: surface.nativeView)
        surfaces[ObjectIdentifier(surface)] = nil
        surface.nativeView.removeFromSuperview()
        let hosts = Self.frames.objectEnumerator()?.allObjects as? [NativeHost] ?? []
        if hosts.allSatisfy({ $0.surfaces.values.allSatisfy { $0.value == nil } }) {
            if let monitor = Self.keyMonitor { NSEvent.removeMonitor(monitor) }
            Self.keyMonitor = nil
            Self.pressedKeys.removeAll()
        }
    }

    private static func startMonitoring() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown]) { event in
            let handled = MainActor.assumeIsolated { event.type == .leftMouseDown ? clicked(event) : route(event) }
            return handled ? nil : event
        }
    }

    /// A click that gives a view the keyboard asks Emacs to select the view's
    /// pane, so the two agree. The click itself still reaches the view.
    private static func clicked(_ event: NSEvent) -> Bool {
        guard let window = event.window, let host = frames.object(forKey: window) else { return false }
        for surface in host.surfaces.values.compactMap(\.value) {
            let view = surface.nativeView
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { continue }
            if !host.ownsFocus(view), let input = surface.input {
                // First, as it abandons a handoff whose keys Emacs may be reading.
                input.claim()
                Core.notify("select", target: input.target)
            }
            break
        }
        return false
    }

    /// A guest has had EVENT, a key press, whatever it did with it: never
    /// take a later re-send of it for a new press.
    static func delivered(_ event: NSEvent) { deliveredKeys.add(event) }

    static func deliverLiteral(_ down: NSEvent, up: NSEvent, in view: NSView) {
        guard let responder = view.window?.firstResponder else { return }
        deliveredKeys.add(down)
        responder.keyDown(with: down)
        responder.keyUp(with: up)
    }

    private static func route(_ event: NSEvent) -> Bool {
        if deliveredKeys.contains(event) { return true }
        guard let window = event.window ?? NSApp.keyWindow else { return false }
        let host = frames.object(forKey: window)
        let handler: (any NativeInputHandler)? = host?.inputCapture ?? host?.focusedSurface
        let view = host?.inputCapture?.view ?? host?.focusedSurface?.nativeView
        let owner = KeyOwner(window: window.windowNumber, view: view.map(ObjectIdentifier.init))
        if event.type == .keyUp, let pressed = pressedKeys.removeValue(forKey: event.keyCode), pressed != owner {
            // A command can move focus before its release. Never deliver that
            // unmatched release to the newly focused terminal or web page.
            return true
        }
        if event.type == .keyDown { pressedKeys[event.keyCode] = owner }
        let handled = handler?.handleKeyEvent(event) ?? false
        host?.refreshOwnership()
        // A key in a view's own window, as a fullscreen page's, is the view's.
        let guest = handler is any NativeSurface || (host == nil && isAway(window))
        if !handled, guest, event.type == .keyDown { deliveredKeys.add(event) }
        return handled
    }

    /// Whether WINDOW is a view's own, out of its host's (`NativeInput.moved`).
    private static func isAway(_ window: NSWindow) -> Bool {
        let hosts = frames.objectEnumerator()?.allObjects as? [NativeHost] ?? []
        return hosts.contains { host in
            host.surfaces.values.contains { $0.value?.input?.away == true && $0.value?.nativeView.window === window }
        }
    }
}
