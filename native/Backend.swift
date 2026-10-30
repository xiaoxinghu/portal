// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PortalCore

// The macOS backend of the operations in native/Core/include/portal.h, whose
// comments define ownership. The core calls each one synchronously; it
// copies its arguments, runs on the main actor, and returns memory the core
// frees. A `portal_view` is a retained `NativeView`, which the core owns from
// create to destroy. Nothing here sees an Emacs value or environment. The
// timer primitive is in CoreCalls.swift, which the standalone checks share.

/// Uninitialized memory for COUNT values, allocated for the bindings to free.
private func allocate<T>(_ type: T.Type, _ count: Int) -> UnsafeMutablePointer<T> {
    malloc(max(count, 1) * MemoryLayout<T>.stride)!.bindMemory(to: type, capacity: max(count, 1))
}

/// VALUE's UTF-8, allocated for the bindings to free.
private func owned(_ value: String) -> portal_text {
    var value = value
    return value.withUTF8 { bytes in
        let data = allocate(CChar.self, bytes.count)
        if let base = bytes.baseAddress { memcpy(data, base, bytes.count) }
        return portal_text(data: data, length: bytes.count)
    }
}

/// Run BODY on the main actor, Emacs's thread, or describe its failure in FAILURE.
private func perform<T: Sendable>(_ failure: UnsafeMutablePointer<portal_text>,
                                  _ body: @MainActor () throws -> T) -> T? {
    do {
        guard Thread.isMainThread else { throw NativeError.message("Native calls require Emacs's main thread") }
        return try MainActor.assumeIsolated(body)
    } catch {
        let message = if case NativeError.message(let text) = error { text } else { error.localizedDescription }
        failure.pointee = owned(message)
        return nil
    }
}

/// Run BODY as above, then store the text it returns in OUTPUT.
private func perform(_ failure: UnsafeMutablePointer<portal_text>, into output: UnsafeMutablePointer<portal_text>,
                     _ body: @MainActor () throws -> String) -> Bool {
    guard let text = perform(failure, body) else { return false }
    output.pointee = owned(text)
    return true
}

/// VALUE as JSON text.
private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
           as: UTF8.self)
}

@_cdecl("portal_launcher_attach")
public func portalLauncherAttach(_ title: portal_string, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let title = String(copying: title)
    return perform(error) { try NativeLauncher.attach(title: title) } != nil
}

@_cdecl("portal_launcher_show")
public func portalLauncherShow(_ width: Int64, _ height: Int64, _ dx: Int64, _ dy: Int64,
                               _ screen: Int64, _ shadow: Bool, _ radius: Int64,
                               _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    return perform(error) {
        guard let launcher = NativeLauncher.attached else { throw NativeError.message("Portal launcher is not attached") }
        try launcher.place(.init(width: width, height: height, dx: dx, dy: dy,
                                 screen: screen, shadow: shadow, radius: radius))
    } != nil
}

@_cdecl("portal_launcher_fit")
public func portalLauncherFit(_ session: UInt64, _ height: Int64,
                              _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error) { try NativeLauncher.attached?.fit(session: session, height: height) } != nil
}

@_cdecl("portal_launcher_prepare")
public func portalLauncherPrepare(_ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error) { NativeLauncher.prepare() } != nil
}

@_cdecl("portal_launcher_hide")
public func portalLauncherHide(_ restoreFocus: Bool, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error) { NativeLauncher.attached?.hide(restoreFocus: restoreFocus) } != nil
}

@_cdecl("portal_launcher_detach")
public func portalLauncherDetach(_ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error) { NativeLauncher.detach() } != nil
}

@_cdecl("portal_launcher_describe")
public func portalLauncherDescribe(_ state: UnsafeMutablePointer<portal_text>,
                                   _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error, into: state) { try json(NativeLauncher.describe()) }
}

@_cdecl("portal_hotkey_register")
public func portalHotkeyRegister(_ hotkey: UInt64, _ key: UInt32, _ modifiers: UInt32,
                                 _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error) { try Hotkeys.register(hotkey, key: key, modifiers: modifiers) } != nil
}

@_cdecl("portal_hotkey_unregister")
public func portalHotkeyUnregister(_ hotkey: UInt64, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error) { try Hotkeys.unregister(hotkey) } != nil
}

@_cdecl("portal_key_post")
public func portalKeyPost(_ key: UInt32, _ modifiers: UInt32, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error) { try KeyPost.post(key: key, modifiers: modifiers) } != nil
}

@_cdecl("portal_screens")
public func portalScreens(_ screens: UnsafeMutablePointer<UnsafeMutablePointer<portal_screen>?>,
                          _ count: UnsafeMutablePointer<Int>, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    guard let found = perform(error, { StatusPanel.screens() }) else { return false }
    guard !found.isEmpty else {
        error.pointee = owned("macOS reports no screen")
        return false
    }
    let copy = allocate(portal_screen.self, found.count)
    copy.initialize(from: found, count: found.count)
    screens.pointee = copy
    count.pointee = found.count
    return true
}

@_cdecl("portal_status_measure")
public func portalStatusMeasure(_ text: portal_string, _ tone: portal_status_tone, _ width: Int64, _ lines: Int64,
                                _ fittedWidth: UnsafeMutablePointer<Int64>, _ height: UnsafeMutablePointer<Int64>,
                                _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let text = String(copying: text)
    guard let size = perform(error, { StatusPanel.measure(text, tone: tone, width: width, lines: lines) }) else {
        return false
    }
    fittedWidth.pointee = size.0
    height.pointee = size.1
    return true
}

@_cdecl("portal_status_show")
public func portalStatusShow(_ text: portal_string, _ tone: portal_status_tone, _ rect: portal_rect, _ lines: Int64,
                             _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let text = String(copying: text)
    return perform(error) { StatusPanel.show(text, tone: tone, rect: rect, lines: lines) } != nil
}

@_cdecl("portal_status_hide")
public func portalStatusHide(_ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error) { StatusPanel.hide() } != nil
}

/// The `NativeView` the core holds as VIEW.
private func native(_ view: OpaquePointer) -> NativeView {
    Unmanaged<NativeView>.fromOpaque(UnsafeRawPointer(view)).takeUnretainedValue()
}

/// VIEW's session, which the core has checked is of KIND.
@MainActor
private func session<Kind: PortalView>(_ view: NativeView, as kind: Kind.Type) throws -> Kind {
    guard let session = view.kind as? Kind else {
        throw NativeError.message("The core passed a view of another kind")
    }
    return session
}

@_cdecl("portal_view_create")
public func portalViewCreate(_ kind: portal_kind, _ target: portal_string,
                             _ options: UnsafePointer<portal_option>?, _ count: Int,
                             _ view: UnsafeMutablePointer<OpaquePointer?>,
                             _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target)
    var values: [String: ViewOption] = [:]
    for option in UnsafeBufferPointer(start: options, count: count) {
        values[String(copying: option.name)] = option.is_string ? .string(String(copying: option.string))
            : .flag(option.flag)
    }
    let options = ViewOptions(values: values)
    let type: any PortalView.Type = kind == PORTAL_TERMINAL ? TerminalSession.self : WebSession.self
    guard let created = perform(error, { try NativeView(type, target: target, options: options) }) else {
        return false
    }
    view.pointee = OpaquePointer(Unmanaged.passRetained(created).toOpaque())
    return true
}

@_cdecl("portal_view_destroy")
public func portalViewDestroy(_ view: OpaquePointer, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let native = native(view)
    guard perform(error, { native.close() }) != nil else { return false }
    Unmanaged<NativeView>.fromOpaque(UnsafeRawPointer(view)).release()
    return true
}

/// Find the frame by its temporary title on every call; nothing is cached.
@_cdecl("portal_view_attach")
public func portalViewAttach(_ view: OpaquePointer, _ frame: portal_string, _ rect: portal_rect,
                             _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let view = native(view), title = String(copying: frame)
    let content = CGRect(x: Int(rect.x), y: Int(rect.y), width: Int(rect.width), height: Int(rect.height))
    return perform(error) {
        guard let host = NativeHost.bind(title: title) else {
            throw NativeError.message("Cannot find the requested native Emacs frame")
        }
        try view.attach(to: host, rectangle: content)
    } != nil
}

@_cdecl("portal_view_detach")
public func portalViewDetach(_ view: OpaquePointer, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let view = native(view)
    return perform(error) { view.detach() } != nil
}

@_cdecl("portal_view_describe")
public func portalViewDescribe(_ view: OpaquePointer, _ state: UnsafeMutablePointer<portal_text>,
                               _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let view = native(view)
    return perform(error, into: state) {
        var object: [String: Any] = [:]
        for (name, value) in view.describe() {
            switch value {
            case .flag(let flag): object[name] = flag
            case .integer(let integer): object[name] = integer
            case .integers(let integers): object[name] = integers
            case .string(let text): object[name] = text
            }
        }
        return try json(object)
    }
}

/// Foundation's parser, which `WebSession.load` uses too, in the spelling
/// WebKit reports URLs in: percent-encoded, with its host as parsed, such as
/// `example.com` for `%65xample.com` and punycode for a Unicode host, and its
/// port as a number, such as 80 for `080`. `absoluteString` alone keeps the
/// host and port as written.
@_cdecl("portal_web_parse_url")
public func portalWebParseURL(_ url: portal_string, _ parsed: UnsafeMutablePointer<portal_text>,
                              _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let url = String(copying: url)
    return perform(error, into: parsed) {
        guard let parsed = URL(string: url) else { throw NativeError.message("WebKit cannot parse the URL \(url)") }
        if var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false), components.host != nil {
            components.port = parsed.port
            // An IPv6 host cannot be set unbracketed, so it stays as written.
            var host = components
            host.host = parsed.host(percentEncoded: false)
            if let spelled = host.url ?? components.url { return spelled.absoluteString }
        }
        return parsed.absoluteString
    }
}

@_cdecl("portal_web_load")
public func portalWebLoad(_ web: OpaquePointer, _ url: portal_string,
                          _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let web = native(web), url = String(copying: url)
    return perform(error) { try session(web, as: WebSession.self).load(url) } != nil
}

@_cdecl("portal_web_go")
public func portalWebGo(_ web: OpaquePointer, _ step: portal_history,
                        _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let web = native(web)
    return perform(error) { try session(web, as: WebSession.self).go(step) } != nil
}

@_cdecl("portal_web_post")
public func portalWebPost(_ web: OpaquePointer, _ json: portal_string, _ token: UInt64,
                          _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let web = native(web), json = String(copying: json)
    return perform(error) { try session(web, as: WebSession.self).post(json, token: token) } != nil
}

@_cdecl("portal_web_set_appearance")
public func portalWebSetAppearance(_ web: OpaquePointer, _ appearance: portal_appearance,
                                   _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let web = native(web)
    return perform(error) { try session(web, as: WebSession.self).show(appearance) } != nil
}

/// REQUEST is the `WindowRequest` that `Core.window` passed the core.
@_cdecl("portal_web_create_window")
public func portalWebCreateWindow(_ opener: OpaquePointer, _ target: portal_string,
                                  _ request: UnsafeMutableRawPointer?,
                                  _ view: UnsafeMutablePointer<OpaquePointer?>,
                                  _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let opener = native(opener), target = String(copying: target)
    guard let request else {
        error.pointee = owned("The core passed no window request")
        return false
    }
    let window = Unmanaged<WindowRequest>.fromOpaque(request).takeUnretainedValue()
    guard let created = perform(error, {
        try NativeView(WebSession(target: target, opener: session(opener, as: WebSession.self), request: window))
    }) else { return false }
    view.pointee = OpaquePointer(Unmanaged.passRetained(created).toOpaque())
    return true
}

@_cdecl("portal_web_find")
public func portalWebFind(_ web: OpaquePointer, _ text: portal_string, _ backward: Bool,
                          _ caseSensitive: Bool, _ token: UInt64,
                          _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let web = native(web), text = String(copying: text)
    return perform(error) {
        try session(web, as: WebSession.self).find(text, backward: backward, caseSensitive: caseSensitive,
                                                   token: token)
    } != nil
}

@_cdecl("portal_web_set_zoom")
public func portalWebSetZoom(_ web: OpaquePointer, _ factor: Double,
                             _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let web = native(web)
    return perform(error) { try session(web, as: WebSession.self).zoom(factor) } != nil
}

@_cdecl("portal_web_print")
public func portalWebPrint(_ web: OpaquePointer, _ file: UnsafePointer<portal_string>?,
                           _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let web = native(web), file = file.map { String(copying: $0.pointee) }
    return perform(error) { try session(web, as: WebSession.self).printPage(to: file) } != nil
}

@_cdecl("portal_terminal_list_themes")
public func portalTerminalListThemes(_ names: UnsafeMutablePointer<UnsafeMutablePointer<portal_text>?>,
                                     _ count: UnsafeMutablePointer<Int>,
                                     _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    guard let themes = perform(error, { Terminals.themeNames() }) else { return false }
    let array = allocate(portal_text.self, themes.count)
    for (index, name) in themes.enumerated() { (array + index).initialize(to: owned(name)) }
    names.pointee = array
    count.pointee = themes.count
    return true
}

@_cdecl("portal_terminal_apply_theme")
public func portalTerminalApplyTheme(_ terminal: OpaquePointer, _ name: UnsafePointer<portal_string>?,
                                     _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let terminal = native(terminal), name = name.map { String(copying: $0.pointee) }
    return perform(error) { try session(terminal, as: TerminalSession.self).applyTheme(name) } != nil
}

@_cdecl("portal_terminal_paste_text")
public func portalTerminalPasteText(_ terminal: OpaquePointer, _ text: portal_string,
                                    _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let terminal = native(terminal), text = String(copying: text)
    return perform(error) { try session(terminal, as: TerminalSession.self).paste(text) } != nil
}

@_cdecl("portal_terminal_press_enter")
public func portalTerminalPressEnter(_ terminal: OpaquePointer, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let terminal = native(terminal)
    return perform(error) { try session(terminal, as: TerminalSession.self).pressEnter() } != nil
}

@_cdecl("portal_terminal_read_text")
public func portalTerminalReadText(_ terminal: OpaquePointer, _ text: UnsafeMutablePointer<portal_text>,
                                   _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let terminal = native(terminal)
    return perform(error, into: text) { try session(terminal, as: TerminalSession.self).text() }
}

@_cdecl("portal_view_focus")
public func portalViewFocus(_ view: OpaquePointer, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let view = native(view)
    return perform(error) { view.kind.input.focus() } != nil
}

@_cdecl("portal_view_unfocus")
public func portalViewUnfocus(_ view: OpaquePointer, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let view = native(view)
    return perform(error) { view.kind.input.unfocus() } != nil
}

@_cdecl("portal_view_replay")
public func portalViewReplay(_ view: OpaquePointer, _ replay: Bool,
                             _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let view = native(view)
    return perform(error) { replay ? view.kind.input.replay() : view.kind.input.discard() } != nil
}

@_cdecl("portal_view_copy")
public func portalViewCopy(_ view: OpaquePointer, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let view = native(view)
    return perform(error) { try view.kind.copy() } != nil
}

@_cdecl("portal_view_paste")
public func portalViewPaste(_ view: OpaquePointer, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let view = native(view)
    return perform(error) { try view.kind.paste() } != nil
}

@_cdecl("portal_view_literal")
public func portalViewLiteral(_ view: OpaquePointer, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let view = native(view)
    return perform(error) { try view.kind.input.literal() } != nil
}
