// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import PortalCore

// Message sockets, the primitives of native/Core/include/portal.h: text
// messages to and from a server on a Unix socket, as a WebSocket (RFC 6455)
// framed by hand. Neither system client reaches a Unix socket:
// URLSessionWebSocketTask cannot name one, and Network.framework's WebSocket
// aborts on a `.unix` endpoint before any request leaves. Nothing here knows
// what the messages mean.

/// One connection. A thread of its own dials, upgrades and reads; a serial
/// queue writes; the module thread only queues and takes, except in `wait`.
final class MessageSocket: @unchecked Sendable {
    /// The largest message a server may send, fragments together.
    static let largestMessage = 16 << 20

    private enum Phase { case connecting, open, ended }

    private let id: UInt64
    private let path: String
    private let resource: String
    private let subprotocol: String
    private let writes: DispatchQueue

    /// Guards every property below, and wakes `wait`.
    private let state = NSCondition()
    private var phase = Phase.connecting
    /// The connected descriptor, or -1 before the dial and once the reader
    /// has taken it back to close it.
    private var descriptor: Int32 = -1
    /// Frames sent before the connection was up, oldest first.
    private var waiting: [Data] = []
    /// Messages the core has not read, oldest first.
    private var arrived: [String] = []
    /// Why the connection ended, once it has.
    private var reason: String?
    /// The core closed the socket: report nothing more.
    private var closed = false

    init(id: UInt64, path: String, resource: String, subprotocol: String) throws {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < capacity else {
            throw NativeError.message(
                "A socket's path is at most \(capacity - 1) bytes, and this one is \(path.utf8.count): \(path)")
        }
        self.id = id
        self.path = path
        self.resource = resource
        self.subprotocol = subprotocol
        writes = DispatchQueue(label: "portal.socket.\(id).writes")
        let reader = Thread { [self] in run() }
        reader.name = "portal.socket.\(id)"
        reader.start()
    }

    // MARK: The module thread

    func send(_ text: String) {
        let frame = Self.frame(opcode: 0x1, payload: Data(text.utf8))
        state.lock()
        defer { state.unlock() }
        switch phase {
        case .connecting: waiting.append(frame)
        case .open: writes.async { [self] in write(frame) }
        case .ended: break
        }
    }

    /// The messages that arrived since the last read, and why the connection
    /// ended, once it has.
    func read() -> (messages: [String], reason: String?) {
        state.lock()
        defer { state.unlock() }
        let messages = arrived
        arrived = []
        return (messages, reason)
    }

    /// Whether there is something to read, after waiting at most
    /// MILLISECONDS for it.
    func wait(milliseconds: UInt64) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(min(milliseconds, 3_600_000)) / 1000)
        state.lock()
        defer { state.unlock() }
        while arrived.isEmpty && reason == nil {
            guard state.wait(until: deadline) else { break }
        }
        return !arrived.isEmpty || reason != nil
    }

    /// End the connection: say goodbye if it is up, then hang up, at once
    /// when the goodbye cannot go out.
    func close() {
        state.lock()
        closed = true
        let open = phase == .open
        state.unlock()
        guard open else { return hangUp() }
        writes.async { [self] in
            write(Self.frame(opcode: 0x8, payload: Data([0x03, 0xe8])))
            hangUp()
        }
        // A server that has stopped reading would hold the goodbye forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in hangUp() }
    }

    // MARK: Writing

    /// A client frame: final, masked, as every client frame must be.
    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count < 65536 {
            frame.append(contentsOf: [0x80 | 126, UInt8(count >> 8), UInt8(count & 0xff)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(count) >> (UInt64($0) * 8)) & 0xff) })
        }
        var mask = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&mask, 4)
        frame.append(contentsOf: mask)
        var index = 0
        frame.append(contentsOf: payload.map { byte in
            defer { index += 1 }
            return byte ^ mask[index & 3]
        })
        return frame
    }

    /// Write all of DATA, on the writes queue or, before the connection is
    /// up, on the reader's thread. A failure hangs up, which the reader
    /// then reports.
    @discardableResult
    private func write(_ data: Data) -> Bool {
        state.lock()
        let descriptor = self.descriptor
        state.unlock()
        guard descriptor >= 0 else { return false }
        let written = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count == 0 || errno != EINTR {
                    return false
                }
            }
            return true
        }
        if !written { hangUp() }
        return written
    }

    /// Stop both directions, which ends the reader's read and any write.
    private func hangUp() {
        state.lock()
        defer { state.unlock() }
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
    }

    // MARK: The reader's thread

    private var buffer: [UInt8] = []
    private var consumed = 0

    private func run() {
        let reason = connect() ?? receive()
        // The reader owns the descriptor's end: no write may be running, or
        // start, once it is closed and its number can name another file.
        state.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        phase = .ended
        waiting = []
        state.unlock()
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            writes.sync {}
            Darwin.close(descriptor)
        }
        state.lock()
        self.reason = reason
        let report = arrived.isEmpty && !closed
        state.broadcast()
        state.unlock()
        if report { reportReady() }
    }

    /// Tell the core, from the main run loop, that there is something to read.
    private func reportReady() {
        let id = id
        DispatchQueue.main.async { portal_socket_ready(id) }
    }

    /// Dial and upgrade; nil once the connection is up, or why it is not.
    private func connect() -> String? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return "Cannot make a socket: \(String(cString: strerror(errno)))" }
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // A server that accepts and then says nothing must not hold a thread
        // forever; once the connection is up, silence is normal.
        var patience = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        state.lock()
        self.descriptor = descriptor
        let closedAlready = closed
        state.unlock()
        if closedAlready { return "Closed" }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path.utf8)
            bytes[path.utf8.count] = 0
        }
        let dialed = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard dialed == 0 else {
            return errno == ENOENT || errno == ECONNREFUSED
                ? "Nothing is listening on that socket"
                : "Cannot connect: \(String(cString: strerror(errno)))"
        }

        var keyBytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&keyBytes, 16)
        let key = Data(keyBytes).base64EncodedString()
        let request = "GET \(resource) HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Protocol: \(subprotocol)\r\n\r\n"
        guard write(Data(request.utf8)) else { return "The connection to the server was lost" }
        if let refusal = readUpgrade(key: key) { return refusal }

        var forever = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        // What was sent meanwhile goes first, in order, ahead of any send
        // that finds the connection open. A close that found it still
        // connecting only hung up, perhaps before there was a line to hang
        // up: it must not be left open.
        state.lock()
        defer { state.unlock() }
        if closed { return "Closed" }
        phase = .open
        for frame in waiting { writes.async { [self] in write(frame) } }
        waiting = []
        return nil
    }

    /// Read the server's answer to the upgrade; nil if it agreed.
    private func readUpgrade(key: String) -> String? {
        let end: [UInt8] = [13, 10, 13, 10]
        var head = 0
        while true {
            if let found = buffer.indices.dropLast(3).first(where: { buffer[$0...].starts(with: end) }) {
                head = found
                break
            }
            guard buffer.count < 16384 else { return "The server's answer is not a WebSocket's" }
            if let failure = fill(buffer.count + 1) { return failure }
        }
        let lines = String(decoding: buffer[..<head], as: UTF8.self).components(separatedBy: "\r\n")
        consumed = head + 4
        guard lines[0].hasPrefix("HTTP/1.1 101") else { return "The server refused the connection: \(lines[0])" }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        guard headers["sec-websocket-accept"] == accept else { return "The server's answer is not a WebSocket's" }
        guard headers["sec-websocket-protocol"] == subprotocol else {
            return "The server does not speak \(subprotocol)"
        }
        return nil
    }

    /// Read until at least COUNT unconsumed bytes are buffered; nil once
    /// they are, or why they never will be.
    private func fill(_ count: Int) -> String? {
        if consumed > 65536 && consumed > buffer.count / 2 {
            buffer.removeFirst(consumed)
            consumed = 0
        }
        state.lock()
        let descriptor = self.descriptor
        state.unlock()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while buffer.count - consumed < count {
            let length = Darwin.read(descriptor, &chunk, chunk.count)
            if length > 0 {
                buffer.append(contentsOf: chunk[..<length])
            } else if length == 0 || errno != EINTR {
                return length < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
                    ? "The server did not answer" : "The connection to the server was lost"
            }
        }
        return nil
    }

    private func take(_ count: Int) -> ArraySlice<UInt8> {
        defer { consumed += count }
        return buffer[consumed..<(consumed + count)]
    }

    /// Read messages until the connection ends; return why it did.
    private func receive() -> String {
        let broken = "The server broke the WebSocket protocol"
        var message: [UInt8]?
        while true {
            if let failure = fill(2) { return failure }
            let header = Array(take(2))
            let last = header[0] & 0x80 != 0, opcode = header[0] & 0x0f
            // No extension was asked for, and a server never masks.
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { return broken }
            var length = UInt64(header[1] & 0x7f)
            if length >= 126 {
                let bytes = length == 126 ? 2 : 8
                if let failure = fill(bytes) { return failure }
                length = take(bytes).reduce(0) { $0 << 8 | UInt64($1) }
            }
            let control = opcode >= 0x8
            guard !control || (last && length < 126) else { return broken }
            guard length <= UInt64(Self.largestMessage) else { return "The server sent a message that is too large" }
            if let failure = fill(Int(length)) { return failure }
            let payload = take(Int(length))
            switch opcode {
            case 0x9:
                let pong = Self.frame(opcode: 0xA, payload: Data(payload))
                writes.async { [self] in write(pong) }
            case 0xA:
                break
            case 0x8:
                return goodbye(Array(payload))
            case 0x0, 0x1:
                // A message starts with a text frame and continues with
                // continuation frames, never the other way around.
                guard (opcode == 0x1) == (message == nil) else { return broken }
                guard (message?.count ?? 0) + payload.count <= Self.largestMessage else {
                    return "The server sent a message that is too large"
                }
                message = (message ?? []) + payload
                if last, let whole = message {
                    deliver(String(decoding: whole, as: UTF8.self))
                    message = nil
                }
            case 0x2:
                return "The server sent a message that is not text"
            default:
                return broken
            }
        }
    }

    /// The server is closing the connection with PAYLOAD: answer, and say why.
    private func goodbye(_ payload: [UInt8]) -> String {
        writes.async { [self] in write(Self.frame(opcode: 0x8, payload: Data(payload.prefix(2)))) }
        guard payload.count >= 2 else { return "The server closed the connection" }
        let code = Int(payload[0]) << 8 | Int(payload[1])
        let why = String(decoding: payload.dropFirst(2), as: UTF8.self)
        return "The server closed the connection (\(code)\(why.isEmpty ? "" : ": \(why)"))"
    }

    private func deliver(_ text: String) {
        state.lock()
        let report = arrived.isEmpty && !closed
        arrived.append(text)
        state.broadcast()
        state.unlock()
        if report { reportReady() }
    }
}

/// The open message sockets, by the core's name for each.
@MainActor
enum MessageSockets {
    private static var sockets: [UInt64: MessageSocket] = [:]

    static func open(_ id: UInt64, path: String, resource: String, subprotocol: String) throws {
        guard id != 0, sockets[id] == nil else { throw NativeError.message("Message socket \(id) is already open") }
        sockets[id] = try MessageSocket(id: id, path: path, resource: resource, subprotocol: subprotocol)
    }

    static func socket(_ id: UInt64) throws -> MessageSocket {
        guard let socket = sockets[id] else { throw NativeError.message("No message socket \(id)") }
        return socket
    }

    static func close(_ id: UInt64) throws {
        try socket(id).close()
        sockets[id] = nil
    }
}
