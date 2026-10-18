// SPDX-License-Identifier: GPL-3.0-or-later
// The standalone checks' way to Portal views: the real core's registry,
// native/Core/views.c, and the real platform primitives in Backend.swift,
// called as native/Core/emacs.c calls them for Emacs.
import AppKit
import PortalCore

@MainActor
enum Views {
    static func open(kind: String, options: ViewOptions) throws -> String {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func borrow(_ text: String) -> portal_string {
            let copy = strdup(text)!
            strings.append(copy)
            return portal_string(data: copy, length: strlen(copy))
        }
        let items = options.values.map { name, value in
            switch value {
            case .string(let text):
                portal_option(name: borrow(name), is_string: true, string: borrow(text), flag: false)
            case .flag(let flag):
                portal_option(name: borrow(name), is_string: false, string: borrow(""), flag: flag)
            }
        }
        let kind = borrow(kind)
        var target = portal_text()
        try call { portal_views_open(kind, items, items.count, &target, $0) }
        return take(&target)
    }

    /// Place TARGET at EDGES in the window titled TITLE, as `portal--place` does.
    static func place(_ target: String, edges: [Int], title: String) throws {
        let edges = portal_edges(left: Int64(edges[0]), top: Int64(edges[1]),
                                 right: Int64(edges[2]), bottom: Int64(edges[3]))
        try with(target) { target in
            try with(title) { title in try call { portal_views_place(target, edges, title, $0) } }
        }
    }

    static func hide(_ target: String) throws {
        try with(target) { target in try call { portal_views_hide(target, $0) } }
    }

    static func close(_ target: String) throws {
        try with(target) { target in try call { portal_views_close(target, $0) } }
    }

    /// Load URL in web view TARGET, as `portal--web-load` does.
    static func load(_ target: String, _ url: String) throws {
        try with(target) { target in try with(url) { url in try call { portal_web_views_load(target, url, $0) } } }
    }

    /// Send JSON to hosted web view TARGET's app, as `portal--web-send` does.
    static func send(_ target: String, _ json: String) throws {
        try with(target) { target in try with(json) { json in try call { portal_web_views_send(target, json, $0) } } }
    }

    /// Receive hosted web view TARGET's waiting messages, as `portal--web-receive` does.
    static func receive(_ target: String) throws -> String {
        var json = portal_text()
        try with(target) { target in try call { portal_web_views_receive(target, &json, $0) } }
        return take(&json)
    }

    /// Who has TARGET's keyboard.
    static func owner(_ target: String) -> portal_owner {
        with(target) { portal_input_owner($0) }
    }

    /// TARGET's session, which must be of KIND.
    static func view<Kind: PortalView>(_ target: String, as kind: Kind.Type) throws -> Kind {
        guard let session = try native(target).kind as? Kind else {
            throw NativeError.message("Wrong kind: \(target)")
        }
        return session
    }

    /// Perform input ACTION on TARGET, as `portal--input` does without a serial.
    static func input(_ target: String, action: String) throws -> Bool {
        var performed = false
        try with(target) { target in
            try with(action) { action in try call { portal_input_perform(target, action, 0, &performed, $0) } }
        }
        return performed
    }

    private static func native(_ target: String) throws -> NativeView {
        var error = portal_text()
        let view = with(target) { portal_views_find($0, Int32(PORTAL_ANY_KIND), &error) }
        guard let view else { throw NativeError.message(take(&error)) }
        return Unmanaged<NativeView>.fromOpaque(UnsafeRawPointer(view)).takeUnretainedValue()
    }

    private static func with<T>(_ text: String, _ body: (portal_string) throws -> T) rethrows -> T {
        try text.withCString { try body(portal_string(data: $0, length: text.utf8.count)) }
    }

    /// Run a core call, throwing its error.
    private static func call(_ body: (UnsafeMutablePointer<portal_text>) -> Bool) throws {
        var error = portal_text()
        guard body(&error) else { throw NativeError.message(take(&error)) }
    }

    private static func take(_ text: inout portal_text) -> String {
        defer { free(text.data); text = portal_text() }
        guard let data = text.data else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: data, count: text.length), as: UTF8.self)
    }
}
