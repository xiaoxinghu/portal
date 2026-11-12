#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A fake Rex server for tests: Rex's control protocol on a Unix socket.

    python3 test/fake-rex-server.py SOCKET

It listens on SOCKET, a path it creates and removes, and speaks WebSocket by
hand, so a test can make it break the framing as well as the protocol. Tests
of any tier start it as a subprocess and script it: one JSON object per line
on standard input, and it reports one JSON object per line on standard
output. It exits when standard input closes, so it never outlives its test.
test/portal-fake-rex.el drives it from Emacs.

What it does unasked, as the real server (0.1.0-preview.14, API revision 12)
was seen to:

- Upgrades a GET for /api/control that asks for rex.control.v1.
- Answers a client's hello with a welcome.
- Answers server.version, session.list and session.attach_all, the last two
  with its sessions, and any other method with method_not_found.
- Gives each response the seq of the last event it sent that client.

Reports, on standard output:

    {"listening": SOCKET}                 once, when it accepts connections
    {"connected": N}                      client N finished the upgrade
    {"hello": {...}, "client": N}         client N's hello
    {"request": {...}, "client": N}       each request, as received
    {"message": TEXT, "client": N}        any other text message
    {"pong": N}                           client N answered a ping
    {"disconnected": N, "code": CODE}     client N left; CODE is its close
                                          frame's, or null without one
    {"problem": TEXT}                     a command it could not run

Commands, on standard input:

    {"sessions": [{"session_id": ..., "label": ...}, ...]}
        What session.list and session.attach_all return from now on.
    {"result": METHOD, "payload": {...}}
        Answer METHOD with this payload from now on.
    {"error": METHOD, "code": CODE, "message": TEXT, "status": 400}
        Answer METHOD with this error from now on.
    {"silent": METHOD}
        Never answer METHOD.
    {"hold": METHOD}
        Keep the answers to METHOD back until {"release": METHOD}, which
        sends them: for events that overtake a response.
    {"stamp": METHOD}
        Give the answers held for METHOD the seq of the last event sent, as
        a server that takes its snapshot now.
    {"after": METHOD, "then": [COMMAND, ...]}
        Run these commands once, when the next request for METHOD has been
        answered, held or passed over in silence: for what must happen
        while a client waits.
    {"event": {"type": ..., "payload": {...}}}
        Send every client that called session.attach_all this event, with
        that client's next seq.
    {"send": TEXT}
        Send every client TEXT as a message, whatever it is.
    {"binary": TEXT}
        Send every client TEXT as a binary message.
    {"fragment": BYTES}
        Send each later message in frames of at most BYTES; 0 for one frame.
    {"ping": true}
        Ping every client.
    {"close": CODE, "reason": TEXT}
        Close every client's connection with a close frame.
    {"drop": true}
        Drop every client's connection without one, as a crash would.
    {"welcome": false}
        Do not answer later hellos; true answers them again.
    {"upgrade": "refuse" | "no-protocol" | "bad-accept" | "silent" | "ok"}
        How to answer later upgrades: 400, no subprotocol, a wrong accept
        key, nothing at all, or properly.
"""

import base64
import hashlib
import json
import os
import queue
import socket
import struct
import sys
import threading

PROTOCOL = "rex.control.v1"
RESOURCE = "/api/control"
API_REVISION = 12
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

lock = threading.RLock()
clients = {}
state = {
    "sessions": [{"session_id": "session:fake-1", "label": "fake"}],
    "results": {},
    "errors": {},
    "silent": set(),
    "held": {},
    "after": {},
    "fragment": 0,
    "welcome": True,
    "upgrade": "ok",
    "last": 0,
}


reports = queue.Queue()


def report(**fields):
    reports.put(json.dumps(fields) + "\n")


def write_reports():
    """Write reports from a thread of their own: a test that is waiting on its
    client reads none, and a full pipe must not stop the server answering."""
    while True:
        sys.stdout.write(reports.get())
        sys.stdout.flush()


class Client:
    def __init__(self, connection, number):
        self.connection = connection
        self.number = number
        self.attached = False
        self.seq = 0
        self.code = None
        self.buffer = b""

    def read(self, count):
        while len(self.buffer) < count:
            chunk = self.connection.recv(65536)
            if not chunk:
                raise EOFError
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def frame(self, opcode, payload, final=True):
        head = bytes([(0x80 if final else 0) | opcode])
        if len(payload) < 126:
            head += bytes([len(payload)])
        elif len(payload) < 65536:
            head += bytes([126]) + struct.pack(">H", len(payload))
        else:
            head += bytes([127]) + struct.pack(">Q", len(payload))
        with lock:
            try:
                self.connection.sendall(head + payload)
            except OSError:
                pass

    def message(self, payload, opcode=1):
        size = state["fragment"]
        if not size or len(payload) <= size:
            return self.frame(opcode, payload)
        pieces = [payload[i : i + size] for i in range(0, len(payload), size)]
        for index, piece in enumerate(pieces):
            self.frame(opcode if index == 0 else 0, piece, index == len(pieces) - 1)

    def send(self, value):
        self.message(json.dumps(value, separators=(",", ":")).encode())

    def upgrade(self):
        head = b""
        while not head.endswith(b"\r\n\r\n"):
            head += self.read(1)
        lines = head.decode("latin-1").split("\r\n")
        headers = {}
        for line in lines[1:]:
            name, colon, value = line.partition(":")
            if colon:
                headers[name.strip().lower()] = value.strip()
        how = state["upgrade"]
        asked = [word.strip() for word in headers.get("sec-websocket-protocol", "").split(",")]
        wrong = lines[0] != "GET %s HTTP/1.1" % RESOURCE or PROTOCOL not in asked
        if how == "silent":
            return False
        if how == "refuse" or wrong:
            self.connection.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return False
        key = "wrong" if how == "bad-accept" else headers.get("sec-websocket-key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        answer = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
        answer += "Sec-Websocket-Accept: %s\r\n" % accept
        if how != "no-protocol":
            answer += "Sec-Websocket-Protocol: %s\r\n" % PROTOCOL
        self.connection.sendall((answer + "\r\n").encode())
        return True

    def receive(self):
        """The next whole message as (opcode, payload); pings and pongs are handled here."""
        message, kind = b"", None
        while True:
            first, second = self.read(2)
            opcode, length = first & 0x0F, second & 0x7F
            if length == 126:
                (length,) = struct.unpack(">H", self.read(2))
            elif length == 127:
                (length,) = struct.unpack(">Q", self.read(8))
            mask = self.read(4) if second & 0x80 else b"\0\0\0\0"
            payload = bytes(byte ^ mask[i & 3] for i, byte in enumerate(self.read(length)))
            if opcode == 0x8:
                self.code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else 1005
                self.frame(0x8, payload[:2])
                raise EOFError
            if opcode == 0x9:
                self.frame(0xA, payload)
            elif opcode == 0xA:
                report(pong=self.number)
            else:
                kind = opcode if opcode else kind
                message += payload
                if first & 0x80:
                    return kind, message

    def respond(self, request):
        method, identifier = request.get("method"), request.get("id")
        payload = request.get("payload") or {}
        with lock:
            response = {"type": "response", "id": identifier, "seq": self.seq}
            if method in state["errors"]:
                response["error"] = state["errors"][method]
            elif method in state["results"]:
                response["payload"] = state["results"][method]
            elif method == "server.version":
                response["payload"] = {
                    "rex_version": "0.0.0-fake",
                    "platform": "fake",
                    "api_revision": API_REVISION,
                }
            elif method == "session.list":
                response["payload"] = {"sessions": state["sessions"]}
            elif method == "session.attach_all":
                if payload.get("event_scope") in ("session", "all"):
                    self.attached = True
                    response["payload"] = {"sessions": state["sessions"]}
                else:
                    response["error"] = {
                        "code": "bad_request",
                        "message": 'session.attach_all request: event_scope must be "all" or "session"',
                        "status": 400,
                    }
            else:
                response["error"] = {
                    "code": "method_not_found",
                    "message": 'netapi: no handler for method "%s"' % method,
                    "status": 404,
                }
            if method in state["held"]:
                state["held"][method].append((self, response))
            elif method not in state["silent"]:
                self.send(response)
            for value in state["after"].pop(method, []):
                command(value)

    def serve(self):
        try:
            if not self.upgrade():
                if state["upgrade"] == "silent":
                    self.connection.recv(1)
                return
            report(connected=self.number)
            while True:
                kind, payload = self.receive()
                text = payload.decode("utf-8", "replace")
                try:
                    value = json.loads(text)
                except ValueError:
                    value = None
                if isinstance(value, dict) and value.get("type") == "hello":
                    report(hello=value, client=self.number)
                    if state["welcome"]:
                        self.send(
                            {
                                "type": "welcome",
                                "protocol": PROTOCOL,
                                "limits": {"max_message_bytes": 1048576},
                                "client": {
                                    "id": "client:fake-%d" % self.number,
                                    "reconnect_token": "fake",
                                },
                                "api_revision": value.get("api_revision", 0),
                                "api_server_revision": API_REVISION,
                            }
                        )
                elif isinstance(value, dict) and value.get("type") == "request":
                    report(request=value, client=self.number)
                    self.respond(value)
                else:
                    report(message=text, client=self.number)
        except (EOFError, OSError):
            pass
        finally:
            with lock:
                clients.pop(self.number, None)
            try:
                self.connection.close()
            except OSError:
                pass
            report(disconnected=self.number, code=self.code)


def command(value):
    with lock:
        everyone = list(clients.values())
        if "sessions" in value:
            state["sessions"] = value["sessions"]
        elif "result" in value:
            state["errors"].pop(value["result"], None)
            state["results"][value["result"]] = value.get("payload", {})
        elif "error" in value:
            state["results"].pop(value["error"], None)
            state["errors"][value["error"]] = {
                "code": value.get("code", "bad_request"),
                "message": value.get("message", "fake error"),
                "status": value.get("status", 400),
            }
        elif "silent" in value:
            state["silent"].add(value["silent"])
        elif "hold" in value:
            state["held"].setdefault(value["hold"], [])
        elif "release" in value:
            for client, response in state["held"].pop(value["release"], []):
                client.send(response)
        elif "stamp" in value:
            for client, response in state["held"].get(value["stamp"], []):
                response["seq"] = client.seq
        elif "after" in value:
            state["after"][value["after"]] = value.get("then", [])
        elif "event" in value:
            for client in everyone:
                if client.attached:
                    client.seq += 1
                    client.send({"type": "event", "seq": client.seq, "payload": value["event"]})
        elif "send" in value:
            for client in everyone:
                client.message(value["send"].encode())
        elif "binary" in value:
            for client in everyone:
                client.message(value["binary"].encode(), 2)
        elif "fragment" in value:
            state["fragment"] = int(value["fragment"])
        elif "ping" in value:
            for client in everyone:
                client.frame(0x9, b"fake")
        elif "close" in value:
            for client in everyone:
                reason = value.get("reason", "").encode()
                client.frame(0x8, struct.pack(">H", int(value["close"])) + reason)
        elif "drop" in value:
            for client in everyone:
                try:
                    client.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        elif "welcome" in value:
            state["welcome"] = bool(value["welcome"])
        elif "upgrade" in value:
            state["upgrade"] = value["upgrade"]
        else:
            report(problem="unknown command: %s" % json.dumps(value))


def accept(listener):
    while True:
        try:
            connection, _ = listener.accept()
        except OSError:
            return
        with lock:
            state["last"] += 1
            client = Client(connection, state["last"])
            clients[client.number] = client
        threading.Thread(target=client.serve, daemon=True).start()


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: fake-rex-server.py SOCKET")
    path = sys.argv[1]
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(16)
    try:
        threading.Thread(target=write_reports, daemon=True).start()
        threading.Thread(target=accept, args=(listener,), daemon=True).start()
        report(listening=path)
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise ValueError("not an object")
                command(value)
            except (ValueError, KeyError, TypeError) as problem:
                report(problem="%s: %s" % (problem, line.strip()))
    finally:
        listener.close()
        try:
            os.unlink(path)
        except OSError:
            pass


if __name__ == "__main__":
    main()
