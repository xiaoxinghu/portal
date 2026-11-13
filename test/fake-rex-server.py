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
was seen to, and as its documentation of data connections says:

- Upgrades a GET for /api/control that asks for rex.control.v1, and one for
  /api/data that asks for rex.data.terminal.v1.
- Answers a client's hello with a welcome.
- Answers server.version, session.list and session.attach_all, the last two
  with its sessions; session.list_blocks with a session's blocks, or
  session_not_found for a session it does not have; and any other method
  with method_not_found, but those of showing a block, below.
- Gives each response the seq of the last event it sent that client.
- Changes its sessions and blocks as a real server does, sending the
  events of each change before its answer: session.create (with the label
  given, or one it chooses), session.set_label, session.destroy (closing
  the session's blocks), session.new_window (one window of one block of
  the flavor com.superlogical.terminal.shell, called shell or the label
  given) and session.set_block_label (an event only for a block in a
  window).  A label is trimmed, and refused with bad_request when longer
  than 128 characters or with a control character.
- Shows a block as a real server does: session.attach joins a session;
  session.own_block, which needs that, claims the block, "take" making the
  client its owner and "request" only if it has none, and sends
  block_owner_changed to the clients attached to its session when the
  owner changes; com.superlogical.terminal.resize keeps the size a client
  asks for and sets the block's grid to it when that client owns the block
  or nobody does, and a new owner's size applies the moment it owns the
  block, and com.superlogical.terminal.size says the block's grid, its
  owner and the size each client asked for; a block whose owner leaves
  passes to the client in line that claimed it most recently, a take
  ahead of every request; client.inspect describes a connected client as
  its hello did, or one a claim command made up, and fails with not_found
  for any other;
  data.connect, which needs it too, gives a ticket of 16 bytes for one data
  connection; com.superlogical.terminal.format gives the block's screen,
  in parts read with com.superlogical.terminal.blob_read when it is longer
  than the paint part; com.superlogical.terminal.write and block.event
  answer, writing nothing anywhere.
- Answers a terminal's com.superlogical.terminal.title, .pwd, .process and
  .input_mode from what it knows of the block: no title, no directory, no
  process and cooked input until a terminal command or a block event says
  otherwise.
- Closes a block on block.close, by its block_id or its window's
  window_id: block_closed, then window_closed and session_view_changed
  for a block that had a window, before its answer.
- On a data connection, answers a HELLO with the ticket's WELCOME, a nonce
  of its own, then a snapshot of two records and a Rex resize message with
  the block's grid; or with a REJECT, reason 0x01, and a close, for a
  ticket it did not give or gave already.  Each later resize of the block
  sends its streams a resize message too.
- Keeps a stream whose data connection drops, and what is written to it
  meanwhile, until the client closes it with 1000 or the server ends it:
  a RESUME with the latest WELCOME's token and the count of bytes taken
  gets a WELCOME with a new token and the same nonce, then the stream from
  that byte on; one with a token it does not know, or a count past what
  it sent, gets a REJECT (0x01, 0x05) and a close.
- Gives each control client a reconnect token, a new one in each welcome.
  A client whose connection drops is kept: a hello with its token
  continues it, "resumed" true, with its ID, its sessions attached and its
  blocks; any other token starts a new client.

Reports, on standard output:

    {"listening": SOCKET}                 once, when it accepts connections
    {"connected": N}                      client N finished the upgrade
    {"hello": {...}, "client": N}         client N's hello
    {"request": {...}, "client": N}       each request, as received
    {"message": TEXT, "client": N}        any other text message
    {"pong": N}                           client N answered a ping
    {"stream": BLOCK, "client": N}        client N's data connection to
                                          BLOCK has had its WELCOME
    {"resumed": BLOCK, "client": N,       client N resumed BLOCK's stream
     "from": COUNT}                       from byte COUNT
    {"disconnected": N, "code": CODE}     client N left; CODE is its close
                                          frame's, its own or its answer to
                                          the server's, or null without one
    {"problem": TEXT}                     a command it could not run
    {"done": N}                           it has finished with the Nth line
                                          of standard input, so what a
                                          client sends next meets it

Commands, on standard input:

    {"sessions": [{"session_id": ..., "label": ...}, ...]}
        What session.list and session.attach_all return from now on.
    {"blocks": {SESSION_ID: [{"block_id": ..., "label": ...}, ...], ...}}
        What session.list_blocks returns for each of these sessions from
        now on, as given: a real server adds a placement and more, and
        sorts by block_id. A session without any has no blocks.
    {"result": METHOD, "payload": {...}}
        Answer METHOD with this payload from now on, if silent before.
    {"error": METHOD, "code": CODE, "message": TEXT, "status": 400}
        Answer METHOD with this error from now on, if silent before.
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
    {"drop_control": true}
        Drop every control connection without a close frame, as a lost
        line would, and leave the data connections as they are.
    {"restart": {"sessions": [...], "blocks": {...}}}
        Come back as a server that restarted: drop every connection,
        forget every client and stream, so no token or RESUME is known,
        and have these sessions and blocks from now on.
    {"welcome": false}
        Do not answer later hellos; true answers them again.
    {"upgrade": "refuse" | "no-protocol" | "bad-accept" | "silent" | "ok"}
        How to answer later upgrades: 400, no subprotocol, a wrong accept
        key, nothing at all, or properly.
    {"screen": {BLOCK: TEXT, ...}}
        What format gives for each of these blocks from now on: the screen
        as escape sequences, "" for a block without one.
    {"paint_part": BYTES}
        Give format's content, and each blob_read, in parts of at most BYTES
        bytes of UTF-8; 0, the start, for one part.
    {"output": BLOCK, "data": TEXT, "split": BYTES}
        Send TEXT, as UTF-8, on every data connection of BLOCK, as the
        program's output, in messages of at most BYTES when split is given.
    {"flood": BLOCK, "lines": N, "prefix": TEXT}
        Send "TEXT1" to "TEXTN", TEXT "line " unless given, each ending
        in CR LF, on BLOCK's
        streams, in messages of 64 KiB, from a thread of its own, at the
        pace the client reads; report {"flooded": BLOCK} when all are out.
    {"rex": BLOCK, "message": {...}}
        Send every data connection of BLOCK this Rex message, with its nonce.
    {"end_stream": BLOCK, "code": CODE, "reason": TEXT}
        Close every data connection of BLOCK with this close frame, and
        end its streams.
    {"drop_stream": BLOCK}
        Drop every data connection of BLOCK without a close frame, keeping
        its streams for a RESUME.
    {"lose_stream": BLOCK}
        Drop BLOCK's data connections and forget their streams, as a
        server that could hold no more: a RESUME of one is refused.
    {"terminal": BLOCK, "title": TEXT, "pwd": TEXT, "process": {...},
     "input_mode": {...}}
        What BLOCK's terminal methods answer from now on, each given
        replacing what it had: "process" as com.superlogical.terminal.process
        returns it, with "child", "foreground", "ancestors" and "last_exit",
        and "input_mode" as com.superlogical.terminal.input_mode does, with
        "echo", "canonical" and "signals".
    {"claim": BLOCK, "client": ID, "mode": "take" | "request", "name": NAME,
     "columns": C, "rows": R}
        Claim BLOCK as the client ID, which no connection is, as another
        app such as Rex.app does: with a size of C by R, if given, and a
        name that client.inspect gives, if given.
    {"block_event": BLOCK, "name": NAME, "payload": {...}}
        Send the terminal event NAME of BLOCK, such as "title_changed", to
        every client that attached to BLOCK's session with session.attach,
        as a session_event wrapping a block_event; and take what it says
        into what BLOCK's terminal methods answer.
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
DATA_PROTOCOL = "rex.data.terminal.v1"
DATA_RESOURCE = "/api/data"
API_REVISION = 12
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

lock = threading.RLock()
clients = {}
state = {
    "sessions": [{"session_id": "session:fake-1", "label": "fake"}],
    "blocks": {
        "session:fake-1": [
            {"block_id": "block:fake-1", "label": "shell", "placement": "placed"}
        ]
    },
    "results": {},
    "errors": {},
    "silent": set(),
    "held": {},
    "after": {},
    "fragment": 0,
    "welcome": True,
    "upgrade": "ok",
    "last": 0,
    "screens": {},
    "paint_part": 0,
    "blobs": {},
    "grids": {},
    "tickets": {},
    "streams": {},
    "made": 0,
    "chosen": {},
    "revision": 1,
    "terminals": {},
    "desired": {},
    "others": {},
    "line": {},
    "kept": {},
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
        self.closing = False
        self.buffer = b""
        self.data = False  # A data connection, not a control one.
        self.joined = set()  # Sessions it attached to.
        self.info = {}  # What its hello said of it.
        self.name = "client:fake-%d" % number  # Its ID, kept across a resume.
        self.token = None  # Its latest reconnect token.
        self.stream = None  # A data connection's stream.
        # Sends on this connection, one at a time: not the global lock, as a
        # client that reads slowly holds a send up.
        self.sending = threading.Lock()

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
        with self.sending:
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
        self.data = lines[0] == "GET %s HTTP/1.1" % DATA_RESOURCE
        protocol = DATA_PROTOCOL if self.data else PROTOCOL
        wrong = (
            lines[0] not in ("GET %s HTTP/1.1" % RESOURCE, "GET %s HTTP/1.1" % DATA_RESOURCE)
            or protocol not in asked
        )
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
            answer += "Sec-Websocket-Protocol: %s\r\n" % protocol
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
                if not self.closing:
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
            elif method == "session.list_blocks":
                session = payload.get("session_id")
                if any(known["session_id"] == session for known in state["sessions"]):
                    response["payload"] = {"blocks": state["blocks"].get(session, [])}
                else:
                    response["error"] = {
                        "code": "session_not_found",
                        "message": "session %s not found" % session,
                        "status": 404,
                    }
            elif method in SHOWING or method in CHANGING:
                result = (SHOWING.get(method) or CHANGING[method])(self, payload)
                if "code" in result:
                    response["error"] = result
                else:
                    response["payload"] = result
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

    def reject(self, reason):
        self.frame(2, b"\x82" + bytes([reason]))
        self.closing = True
        self.frame(0x8, struct.pack(">H", 1008) + b"data handshake rejected")

    def stream_connection(self):
        """A data connection: a HELLO or a RESUME, then the block's stream
        until the connection ends."""
        kind, hello = self.receive()
        with lock:
            if kind == 2 and hello[:1] == b"\x02" and len(hello) >= 25:
                found = next((stream for streams in state["streams"].values()
                              for stream in streams if stream.token == bytes(hello[1:17])), None)
                (count,) = struct.unpack("<Q", hello[17:25])
                if not found:
                    return self.reject(0x01)
                if count > len(found.sent):
                    return self.reject(0x05)
                if found.connection:
                    found.connection.stream = None
                found.connection, self.stream = self, found
                self.frame(2, found.welcome())
                if count < len(found.sent):
                    self.frame(2, bytes(found.sent[count:]))
                report(resumed=found.block, client=self.number, **{"from": count})
            else:
                ticket = bytes(hello[1:17])
                found = state["tickets"].pop(ticket, None) if kind == 2 and hello[:1] == b"\x01" else None
                if not found:
                    return self.reject(0x01)
                self.stream = Stream(found["block"], self)
                self.frame(2, self.stream.welcome())
                snapshot = b"GHOSTSNP\x01\x00"
                for tag, body in ((1, b"fake screen"), (6, b"")):
                    snapshot += struct.pack("<HIxxxx", tag, len(body)) + body
                self.stream.write(snapshot)
                self.stream.rex(resize_message(self.stream.block))
                state["streams"].setdefault(self.stream.block, []).append(self.stream)
                report(stream=self.stream.block, client=self.number)
        while True:
            self.receive()

    def serve(self):
        try:
            if not self.upgrade():
                if state["upgrade"] == "silent":
                    self.connection.recv(1)
                return
            report(connected=self.number)
            if self.data:
                return self.stream_connection()
            while True:
                kind, payload = self.receive()
                text = payload.decode("utf-8", "replace")
                try:
                    value = json.loads(text)
                except ValueError:
                    value = None
                if isinstance(value, dict) and value.get("type") == "hello":
                    report(hello=value, client=self.number)
                    self.info = value.get("client") or {}
                    if state["welcome"]:
                        with lock:
                            kept = state["kept"].pop(value.get("reconnect_token"), None)
                            if kept:
                                self.name, self.joined, self.attached = kept
                            self.token = "fake-token-%s" % os.urandom(8).hex()
                        self.send(
                            {
                                "type": "welcome",
                                "protocol": PROTOCOL,
                                "limits": {"max_message_bytes": 1048576},
                                "client": {
                                    "id": self.name,
                                    "reconnect_token": self.token,
                                    "resumed": bool(kept),
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
                stream = self.stream
                if stream and stream.connection is self:
                    stream.connection = None
                    # The client's 1000 ends the stream; a drop keeps it.
                    if self.code == 1000 or self.closing:
                        stream.end()
                # A control client that dropped is kept for its token.
                if not self.data and self.code is None and self.token:
                    state["kept"][self.token] = (self.name, self.joined, self.attached)
                # One that left for good gives up its blocks.
                elif not self.data:
                    leave(identity(self))
            try:
                self.connection.close()
            except OSError:
                pass
            report(disconnected=self.number, code=self.code)


class Stream:
    """A block's stream, which may outlive its data connection."""

    def __init__(self, block, connection):
        self.block = block
        self.connection = connection
        self.nonce = int.from_bytes(os.urandom(8), "little") or 1
        self.token = None
        self.sent = bytearray()  # Every byte after the WELCOME.

    def welcome(self):
        """A WELCOME, with a new token."""
        self.token = os.urandom(16)
        return (b"\x81" + self.token + b"\0\0\0" + struct.pack("<I", 10000)
                + struct.pack("<Q", self.nonce))

    def write(self, data):
        """Send DATA as the stream's next bytes, or keep it for a RESUME."""
        self.sent += data
        if self.connection:
            self.connection.frame(2, data)

    def rex(self, message):
        """Send one of Rex's own messages on this stream."""
        body = json.dumps(message, separators=(",", ":"))
        self.write(b"\x1b_rex1;%d;%s\x1b\\" % (self.nonce, body.encode()))

    def end(self):
        streams = state["streams"].get(self.block, [])
        if self in streams:
            streams.remove(self)


def error(code, message, status):
    return {"code": code, "message": message, "status": status}


def find_block(payload):
    """The session and block a block method names, or an error."""
    session, block = payload.get("session_id"), payload.get("block_id")
    if not any(known["session_id"] == session for known in state["sessions"]):
        return None, error("session_not_found", "session %s not found" % session, 404)
    if not any(known.get("block_id") == block for known in state["blocks"].get(session, [])):
        return None, error("not_found", "block %s is not in the session" % block, 404)
    return block, None


def resize_message(block):
    columns, rows, width, height, owner = state["grids"].get(block, (80, 24, 0, 0, None))
    return {"type": "resize", "cols": columns, "rows": rows, "cell_width_px": width,
            "cell_height_px": height, "owner": owner}


def attach(client, payload):
    session = payload.get("session_id")
    if not any(known["session_id"] == session for known in state["sessions"]):
        return error("session_not_found", "session %s not found" % session, 404)
    client.joined.add(session)
    return {"client_id": client.name, "view": {"revision": 1}}


def identity(client):
    return client.name


def owner_of(block):
    return state["grids"].get(block, (80, 24, 0, 0, None))[4]


def set_grid(block, size):
    """Give BLOCK the grid SIZE, (columns, rows, cell width, cell height),
    and tell its streams."""
    state["grids"][block] = tuple(size) + (owner_of(block),)
    for stream in list(state["streams"].get(block, [])):
        stream.rex(resize_message(block))


def set_owner(block, owner, reason):
    """Make OWNER, a client ID or None, BLOCK's owner, telling the clients
    attached to its session; the block takes the size OWNER asked for."""
    previous = owner_of(block)
    columns, rows, width, height, _ = state["grids"].get(block, (80, 24, 0, 0, None))
    state["grids"][block] = (columns, rows, width, height, owner)
    fields = {"block_id": block, "previous": previous, "reason": reason}
    if owner:
        fields["owner"] = owner
    session = session_of(block)
    event = {"type": "session_event", "payload": {
        "session_id": session, "event": {"type": "block_owner_changed", "payload": fields}}}
    for client in list(clients.values()):
        if session in client.joined or client.attached:
            client.seq += 1
            client.send({"type": "event", "seq": client.seq, "payload": event})
    wanted = state["desired"].get(block, {}).get(owner)
    if wanted and wanted != state["grids"][block][:4]:
        set_grid(block, wanted)


def connected(who):
    return who in state["others"] or any(identity(known) == who for known in clients.values())


def leave(who):
    """The client WHO has gone: each block it owns passes to the client in
    line that claimed it most recently, a take ahead of every request, or
    to nobody."""
    for block, line in state["line"].items():
        line[:] = [entry for entry in line if entry[0] != who]
        if owner_of(block) == who:
            waiting = [entry for entry in line if connected(entry[0])]
            takes = [entry for entry in waiting if entry[1] == "take"]
            following = (takes or waiting or [(None, None)])[-1][0]
            set_owner(block, following, "disconnect")


def claim(who, session, blocks, mode):
    """Claim BLOCKS of SESSION for the client WHO in MODE, as own_block does."""
    if mode not in ("take", "request"):
        return error("bad_request", "session.own_block: mode must be take or request", 400)
    owners = []
    for block in blocks:
        _, problem = find_block({"session_id": session, "block_id": block})
        if problem:
            return error("bad_request", "block %s is not in the session" % block, 400)
        line = state["line"].setdefault(block, [])
        line[:] = [entry for entry in line if entry[0] != who] + [(who, mode)]
        owner = owner_of(block)
        if owner != who and (mode == "take" or owner is None):
            set_owner(block, who, mode)
        entry = {"block_id": block}
        if owner_of(block):
            entry["owner"] = owner_of(block)
        owners.append(entry)
    return {"blocks": owners}


def own_block(client, payload):
    session = payload.get("session_id")
    if session not in client.joined:
        return error("bad_request", "session.own_block: attach to the session first", 400)
    return claim(identity(client), session, payload.get("block_ids") or [],
                 payload.get("mode") or "take")


def resize(client, payload):
    block, problem = find_block(payload)
    if problem:
        return problem
    args = payload.get("args") or {}
    size = (args.get("columns", 80), args.get("rows", 24),
            args.get("cell_width_px") or 0, args.get("cell_height_px") or 0)
    state["desired"].setdefault(block, {})[identity(client)] = size
    if owner_of(block) in (None, identity(client)):
        set_grid(block, size)
    return {}


def size(client, payload):
    block, problem = find_block(payload)
    if problem:
        return problem
    columns, rows, width, height, owner = state["grids"].get(block, (80, 24, 0, 0, None))
    answer = {"columns": columns, "rows": rows, "cell_width_px": width, "cell_height_px": height,
              "desired": [{"client_id": who, "columns": wanted[0], "rows": wanted[1]}
                          for who, wanted in state["desired"].get(block, {}).items()]}
    if owner:
        answer["owner"] = owner
    return answer


def inspect(client, payload):
    who = payload.get("client_id")
    info = state["others"].get(who)
    if info is None:
        info = next((known.info for known in clients.values() if identity(known) == who), None)
    if info is None:
        return error("not_found", "client %s not found" % who, 404)
    return {"client": {"client_id": who, "info": info, "connection_state": "connected"}}


def connect(client, payload):
    block, problem = find_block(payload)
    if problem:
        return problem
    if payload.get("session_id") not in client.joined:
        return error("conflict", "data.connect: the connection is not attached to the session", 409)
    ticket = os.urandom(16)
    state["tickets"][ticket] = {"block": block, "client": client.number}
    return {"ticket": base64.urlsafe_b64encode(ticket).decode().rstrip("="), "expires_in_ms": 30000}


def part(text, offset, most=0):
    """The part of TEXT's UTF-8 from OFFSET, ending on a whole character: at
    most MOST bytes, as a request's max_bytes asks, and the paint part."""
    data = text.encode()
    size = min(size for size in (state["paint_part"], most, len(data) or 1) if size)
    end = min(len(data), offset + size)
    while end < len(data) and (data[end] & 0xC0) == 0x80:
        end -= 1
    return data[offset:end].decode(), end >= len(data), len(data)


def paint(client, payload):
    block, problem = find_block(payload)
    if problem:
        return problem
    content = state["screens"].get(block, "")
    first, whole, total = part(content, 0, (payload.get("args") or {}).get("max_bytes") or 0)
    if whole:
        return {"content": content}
    identifier = len(state["blobs"]) + 1
    state["blobs"][identifier] = content
    return {"content": first, "id": identifier, "total": total, "eof": False}


def blob_read(client, payload):
    _, problem = find_block(payload)
    if problem:
        return problem
    args = payload.get("args") or {}
    content = state["blobs"].get(args.get("id"))
    if content is None:
        return error("not_found", "no such result", 404)
    data, eof, total = part(content, args.get("offset", 0), args.get("max_bytes") or 0)
    return {"id": args.get("id"), "data": data, "total": total, "eof": eof}


def terminal(block):
    return state["terminals"].setdefault(block, {
        "title": "", "process": {"last_exit": None},
        "input_mode": {"echo": True, "canonical": True, "signals": True}})


def title(client, payload):
    block, problem = find_block(payload)
    return problem or {"title": terminal(block)["title"]}


def pwd(client, payload):
    block, problem = find_block(payload)
    if problem:
        return problem
    known = terminal(block)
    return {"pwd": known["pwd"]} if "pwd" in known else {}


def process(client, payload):
    block, problem = find_block(payload)
    return problem or terminal(block)["process"]


def input_mode(client, payload):
    block, problem = find_block(payload)
    return problem or terminal(block)["input_mode"]


def session_of(block):
    for session, blocks in state["blocks"].items():
        if any(known.get("block_id") == block for known in blocks):
            return session
    return None


def answer_block(client, payload):
    _, problem = find_block(payload)
    if problem:
        return problem
    data = (payload.get("args") or {}).get("data")
    return {"bytes_written": len(data.encode())} if data is not None else {}


def broadcast(event):
    """Send every client that called session.attach_all this event."""
    for client in list(clients.values()):
        if client.attached:
            client.seq += 1
            client.send({"type": "event", "seq": client.seq, "payload": event})


def session_event(session, kind, **fields):
    broadcast({"type": "session_event",
               "payload": {"session_id": session, "event": {"type": kind, "payload": fields}}})


def find_session(session):
    return next((known for known in state["sessions"] if known["session_id"] == session), None)


def check_label(method, label):
    """The label trimmed, or an error, as the server checks one."""
    label = (label or "").strip()
    if len(label) > 128 or any(ord(c) < 32 or ord(c) == 127 for c in label):
        return None, error("bad_request", "%s: label must be at most 128 characters "
                           "without control characters" % method, 400)
    return label, None


def made(kind):
    state["made"] += 1
    return "%s:made-%d" % (kind, state["made"])


def create_session(client, payload):
    label, problem = check_label("session.create", payload.get("label"))
    if problem:
        return problem
    session = made("session")
    chosen = "fake-meadow-%d" % state["made"]
    state["chosen"][session] = chosen
    state["sessions"].append({"session_id": session, "label": label or chosen})
    state["blocks"][session] = []
    broadcast({"type": "session_created",
               "payload": {"session": {"session_id": session, "label": label or chosen}}})
    return {"session_id": session}


def set_label(client, payload):
    session = find_session(payload.get("session_id"))
    if not session:
        return error("session_not_found", "session %s not found" % payload.get("session_id"), 404)
    label, problem = check_label("session.set_label", payload.get("label"))
    if problem:
        return problem
    label = label or state["chosen"].get(session["session_id"], session["label"])
    if label != session["label"]:
        session["label"] = label
        state["revision"] += 1
        session_event(session["session_id"], "session_label_changed", label=label)
        session_event(session["session_id"], "session_view_changed", revision=state["revision"])
    return {"revision": state["revision"]}


def destroy(client, payload):
    session = find_session(payload.get("session_id"))
    if not session:
        return error("session_not_found", "session %s not found" % payload.get("session_id"), 404)
    if not client.attached and session["session_id"] not in client.joined:
        return error("conflict", "session.destroy: attach to the session first", 409)
    for block in state["blocks"].pop(session["session_id"], []):
        session_event(session["session_id"], "block_closed", block_id=block["block_id"])
    state["sessions"].remove(session)
    broadcast({"type": "session_destroyed", "payload": {"session_id": session["session_id"]}})
    return {}


def new_window(client, payload):
    session = find_session(payload.get("session_id"))
    if not session:
        return error("session_not_found", "session %s not found" % payload.get("session_id"), 404)
    node = (payload.get("layout") or {}).get("block")
    if not isinstance(node, dict) or not node.get("flavor"):
        return error("bad_request", "session.new_window: layout must hold a block with a flavor", 400)
    if node["flavor"] != "com.superlogical.terminal.shell":
        return error("not_found", "no creator provides flavor %s" % node["flavor"], 404)
    label, problem = check_label("session.new_window", node.get("label"))
    if problem:
        return problem
    window, block = made("window"), made("block")
    state["blocks"].setdefault(session["session_id"], []).append(
        {"block_id": block, "label": label or "shell", "placement": "placed", "window_id": window})
    state["revision"] += 1
    session_event(session["session_id"], "block_created", block_id=block)
    session_event(session["session_id"], "window_created", window_id=window)
    session_event(session["session_id"], "session_view_changed", revision=state["revision"])
    return {"window_id": window, "block_ids": [block], "revision": state["revision"]}


def set_block_label(client, payload):
    session = find_session(payload.get("session_id"))
    if not session:
        return error("session_not_found", "session %s not found" % payload.get("session_id"), 404)
    found = next((block for block in state["blocks"].get(session["session_id"], [])
                  if block.get("block_id") == payload.get("block_id")), None)
    if not found:
        return error("not_found", "block %s is not in the session" % payload.get("block_id"), 404)
    label, problem = check_label("session.set_block_label", payload.get("label"))
    if problem:
        return problem
    label = label or "Block %s" % found["block_id"].split(":")[-1][:8]
    if label != found["label"]:
        found["label"] = label
        if found.get("placement") != "detached":
            state["revision"] += 1
            session_event(session["session_id"], "session_view_changed",
                          revision=state["revision"])
    return {"revision": state["revision"]}


def close_block(client, payload):
    session = find_session(payload.get("session_id"))
    if not session:
        return error("session_not_found", "session %s not found" % payload.get("session_id"), 404)
    block, window = payload.get("block_id"), payload.get("window_id")
    if bool(block) == bool(window):
        return error("bad_request", "block.close: send exactly one of block_id and window_id", 400)
    blocks = state["blocks"].get(session["session_id"], [])
    found = next((known for known in blocks
                  if (block and known.get("block_id") == block)
                  or (window and known.get("window_id") == window)), None)
    if not found:
        return error("not_found", "%s is not in the session" % (block or window), 404)
    blocks.remove(found)
    session_event(session["session_id"], "block_closed", block_id=found["block_id"])
    if found.get("window_id") and found.get("placement") != "detached":
        state["revision"] += 1
        session_event(session["session_id"], "window_closed", window_id=found["window_id"])
        session_event(session["session_id"], "session_view_changed", revision=state["revision"])
    return {}


# The methods that change what the server has, and send their events
# before their answer, as a real server does.
CHANGING = {
    "session.create": create_session,
    "session.set_label": set_label,
    "session.destroy": destroy,
    "session.new_window": new_window,
    "session.set_block_label": set_block_label,
    "block.close": close_block,
}


SHOWING = {
    "session.attach": attach,
    "session.own_block": own_block,
    "client.inspect": inspect,
    "com.superlogical.terminal.size": size,
    "com.superlogical.terminal.resize": resize,
    "data.connect": connect,
    "com.superlogical.terminal.format": paint,
    "com.superlogical.terminal.blob_read": blob_read,
    "com.superlogical.terminal.write": answer_block,
    "block.event": answer_block,
    "com.superlogical.terminal.title": title,
    "com.superlogical.terminal.pwd": pwd,
    "com.superlogical.terminal.process": process,
    "com.superlogical.terminal.input_mode": input_mode,
}


def command(value):
    with lock:
        everyone = list(clients.values())
        if "sessions" in value:
            state["sessions"] = value["sessions"]
        elif "blocks" in value:
            state["blocks"].update(value["blocks"])
        elif "result" in value:
            state["silent"].discard(value["result"])
            state["errors"].pop(value["result"], None)
            state["results"][value["result"]] = value.get("payload", {})
        elif "error" in value:
            state["silent"].discard(value["error"])
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
            broadcast(value["event"])
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
                client.closing = True
                client.frame(0x8, struct.pack(">H", int(value["close"])) + reason)
        elif "drop" in value:
            for client in everyone:
                drop(client)
        elif "welcome" in value:
            state["welcome"] = bool(value["welcome"])
        elif "upgrade" in value:
            state["upgrade"] = value["upgrade"]
        elif "screen" in value:
            state["screens"].update(value["screen"])
        elif "paint_part" in value:
            state["paint_part"] = int(value["paint_part"])
        elif "output" in value:
            data = value.get("data", "").encode()
            size = int(value.get("split") or 0) or len(data) or 1
            for stream in list(state["streams"].get(value["output"], [])):
                for start in range(0, len(data), size):
                    stream.write(data[start : start + size])
        elif "flood" in value:
            threading.Thread(target=flood, args=(value["flood"], int(value.get("lines", 0)),
                                                 value.get("prefix", "line ").encode()),
                             daemon=True).start()
        elif "rex" in value:
            for stream in list(state["streams"].get(value["rex"], [])):
                stream.rex(value["message"])
        elif "terminal" in value:
            known = terminal(value["terminal"])
            for key in ("title", "pwd", "process", "input_mode"):
                if key in value:
                    known[key] = value[key]
        elif "claim" in value:
            block, who = value["claim"], value.get("client", "client:other")
            if "name" in value:
                state["others"][who] = {"kind": "app", "name": value["name"]}
            state["others"].setdefault(who, {})
            if "columns" in value:
                state["desired"].setdefault(block, {})[who] = (
                    value["columns"], value.get("rows", 24), 0, 0)
            result = claim(who, session_of(block), [block], value.get("mode", "take"))
            if "code" in result:
                report(problem=result["message"])
        elif "block_event" in value:
            block, name = value["block_event"], value.get("name", "")
            fields = value.get("payload", {})
            known = terminal(block)
            if name == "title_changed":
                known["title"] = fields.get("title", "")
            elif name == "pwd_changed":
                known["pwd"] = fields.get("pwd", "")
            elif name == "process_changed":
                known["process"] = dict(known["process"], foreground=fields.get("foreground"))
            elif name == "child_exited":
                known["process"] = dict(known["process"], last_exit=fields)
            session = session_of(block)
            event = {"type": "session_event", "payload": {
                "session_id": session,
                "event": {"type": "block_event", "payload": {
                    "block_id": block, "creator_name": "com.superlogical.terminal",
                    "name": name, "payload": fields}}}}
            for client in everyone:
                if session in client.joined:
                    client.seq += 1
                    client.send({"type": "event", "seq": client.seq, "payload": event})
        elif "end_stream" in value:
            for stream in list(state["streams"].get(value["end_stream"], [])):
                stream.end()
                if stream.connection:
                    stream.connection.closing = True
                    reason = value.get("reason", "").encode()
                    stream.connection.frame(
                        0x8, struct.pack(">H", int(value.get("code", 1000))) + reason)
        elif "drop_stream" in value:
            for stream in list(state["streams"].get(value["drop_stream"], [])):
                if stream.connection:
                    drop(stream.connection)
        elif "lose_stream" in value:
            for stream in list(state["streams"].get(value["lose_stream"], [])):
                stream.end()
                stream.token = None
                if stream.connection:
                    drop(stream.connection)
        elif "drop_control" in value:
            for client in everyone:
                if not client.data:
                    drop(client)
        elif "restart" in value:
            for client in everyone:
                client.token = None
                drop(client)
            state["kept"].clear()
            state["streams"].clear()
            state["tickets"].clear()
            state["grids"].clear()
            state["line"].clear()
            state["desired"].clear()
            state["sessions"] = value["restart"].get("sessions", [])
            state["blocks"] = value["restart"].get("blocks", {})
        else:
            report(problem="unknown command: %s" % json.dumps(value))


def flood(block, lines, prefix):
    """Send BLOCK's streams LINES numbered lines, as fast as they are read."""
    chunk = bytearray()
    for number in range(1, lines + 1):
        chunk += b"%s%d\r\n" % (prefix, number)
        if len(chunk) >= 65536 or number == lines:
            for stream in list(state["streams"].get(block, [])):
                stream.write(bytes(chunk))
            chunk = bytearray()
    report(flooded=block)


def drop(client):
    """End CLIENT's connection without a close frame, as a crash would."""
    try:
        client.connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


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
        for count, line in enumerate(sys.stdin, 1):
            if line.strip():
                try:
                    value = json.loads(line)
                    if not isinstance(value, dict):
                        raise ValueError("not an object")
                    command(value)
                except (ValueError, KeyError, TypeError) as problem:
                    report(problem="%s: %s" % (problem, line.strip()))
            report(done=count)
    finally:
        listener.close()
        try:
            os.unlink(path)
        except OSError:
            pass


if __name__ == "__main__":
    main()
