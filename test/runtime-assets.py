#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Release assets for the runtime installer's tests, served over HTTPS.

    python3 -B test/runtime-assets.py certs DIRECTORY
    python3 -B test/runtime-assets.py serve CERTS {trusted,untrusted,other-name,same-name} ROOT
    python3 -B test/runtime-assets.py variant KIND MANIFEST OUT

`certs` makes a test certificate authority, ca.pem, and four server
certificates for 127.0.0.1: one it signed; one signed by itself; one it
signed for another name; and one it signed that bears its own name, which
GnuTLS accepts and Emacs's Network Security Manager takes as self-signed.
It needs openssl.

`serve` serves ROOT on 127.0.0.1 with one of them, on a port of its own
choosing.  It prints {"port": N}, then {"path": P} for each request, one
JSON object a line.  A path's first part may ask for a misbehaving server:

    /redirect/REST            302 to https://127.0.0.1:N/REST
    /relative-redirect/REST   302 to /REST
    /plain-redirect/REST      302 to http://127.0.0.1:N/REST
    /chunked/REST             REST with chunked transfer encoding
    /tiny-chunks/REST         the same in chunks of 4 bytes, framing more than data
    /truncate/REST            half of REST if an archive, then the connection closes
    /stall/REST               half of REST if an archive, then nothing

`variant` writes, in OUT, a copy of MANIFEST's archive changed as KIND
says and a manifest whose size and SHA-256 match it, so that only the
installer's own checks of the archive's contents can refuse it.
"""
from __future__ import annotations

import hashlib
import http.server
import io
import json
import socketserver
import ssl
import subprocess
import sys
import tarfile
import time
from pathlib import Path

CONFIG = """\
[req]
distinguished_name = dn
prompt = no
[dn]
CN = Portal test
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[trusted]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1
[other-name]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:other.invalid
[same-name]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1
"""
AUTHORITY = "/CN=Portal test authority"
SERVER = "/CN=Portal test server"


def certs(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "openssl.cnf").write_text(CONFIG)

    def openssl(*arguments):
        subprocess.run(["openssl", *arguments], cwd=directory, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    key = ["-newkey", "rsa:2048", "-nodes", "-days", "2", "-config", "openssl.cnf"]
    openssl("req", "-x509", *key, "-subj", AUTHORITY, "-extensions", "ca",
            "-keyout", "ca.key", "-out", "ca.pem")
    for serial, name in enumerate(("trusted", "other-name", "same-name"), 2):
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-config", "openssl.cnf",
                "-subj", AUTHORITY if name == "same-name" else SERVER,
                "-keyout", f"{name}.key", "-out", f"{name}.csr")
        openssl("x509", "-req", "-in", f"{name}.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
                "-set_serial", str(serial), "-days", "2",
                "-extfile", "openssl.cnf", "-extensions", name, "-out", f"{name}.pem")
    openssl("req", "-x509", *key, "-subj", SERVER, "-extensions", "trusted",
            "-keyout", "untrusted.key", "-out", "untrusted.pem")


class Assets(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    root: Path

    def log_message(self, *arguments):
        pass

    def answer(self, status, headers, body=b""):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        print(json.dumps({"path": self.path}), flush=True)
        mode, _, rest = self.path.lstrip("/").partition("/")
        port = self.server.server_address[1]
        if mode == "redirect":
            return self.answer(302, [("Location", f"https://127.0.0.1:{port}/{rest}"),
                                     ("Content-Length", "0")])
        if mode == "relative-redirect":
            return self.answer(302, [("Location", f"/{rest}"), ("Content-Length", "0")])
        if mode == "plain-redirect":
            return self.answer(302, [("Location", f"http://127.0.0.1:{port}/{rest}"),
                                     ("Content-Length", "0")])
        if mode not in ("chunked", "tiny-chunks", "truncate", "stall"):
            mode, rest = "", self.path.lstrip("/")
        path = (self.root / rest).resolve()
        if self.root not in path.parents or not path.is_file():
            return self.answer(404, [("Content-Length", "0")])
        data = path.read_bytes()
        if mode in ("chunked", "tiny-chunks"):
            size = 4096 if mode == "chunked" else 4
            body = b"".join(b"%x\r\n%s\r\n" % (len(data[at:at + size]), data[at:at + size])
                            for at in range(0, len(data), size)) + b"0\r\n\r\n"
            return self.answer(200, [("Transfer-Encoding", "chunked")], body)
        if mode in ("truncate", "stall") and rest.endswith(".tar.gz"):
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data[:len(data) // 2])
            self.wfile.flush()
            if mode == "stall":
                time.sleep(3600)
            self.close_connection = True
            return
        self.answer(200, [("Content-Length", str(len(data)))], data)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def serve(certificates: Path, name: str, root: Path) -> None:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificates / f"{name}.pem", certificates / f"{name}.key")
    Assets.root = root.resolve()
    server = Server(("127.0.0.1", 0), Assets)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(json.dumps({"port": server.server_address[1]}), flush=True)
    server.serve_forever()


# Variants of an archive, each refused by a different rule.

def member(name, data=b"", kind=tarfile.REGTYPE, link=""):
    info = tarfile.TarInfo(name)
    info.type = kind
    info.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
    info.linkname = link
    info.size = len(data) if kind == tarfile.REGTYPE else 0
    return info, io.BytesIO(data) if kind == tarfile.REGTYPE else None


VARIANTS = {
    # Escapes by name.
    "parent": lambda: [member("licenses/../../escaped", b"out")],
    "absolute": lambda: [member("/tmp/portal-runtime-escaped", b"out")],
    "foreign": lambda: [member("extra", b"not of the runtime")],
    "duplicate": lambda: [member("licenses/LICENSE", b"twice")],
    # Escapes by link: out of the runtime, absolute, or to write through.
    "link-out": lambda: [member("licenses/out", kind=tarfile.SYMTYPE, link="../../../outside")],
    "link-absolute": lambda: [member("licenses/out", kind=tarfile.SYMTYPE, link="/etc")],
    "through-link": lambda: [member("licenses/via", kind=tarfile.SYMTYPE, link=".."),
                             member("licenses/via/escaped", b"out")],
    # What no runtime holds.
    "hardlink": lambda: [member("licenses/hard", kind=tarfile.LNKTYPE, link="licenses/LICENSE")],
    "fifo": lambda: [member("licenses/fifo", kind=tarfile.FIFOTYPE)],
}


def variant(kind: str, manifest_path: Path, out: Path) -> None:
    manifest = json.loads(manifest_path.read_text())
    entry = manifest["archives"][0]
    source = manifest_path.with_name(entry["name"])
    out.mkdir(parents=True, exist_ok=True)
    target = out / entry["name"]
    with tarfile.open(source, "r:gz") as old, \
            tarfile.open(target, "w:gz", format=tarfile.PAX_FORMAT) as new:
        for info in old.getmembers():
            if kind == "record" and info.name == "portal-build.eld":
                data = old.extractfile(info).read().replace(
                    manifest["identity"].encode(), b"0" * 64)
                info.size = len(data)
                new.addfile(info, io.BytesIO(data))
            elif kind == "missing" and info.name == "portal-host":
                continue
            else:
                new.addfile(info, old.extractfile(info) if info.isfile() else None)
        for info, data in VARIANTS.get(kind, list)():
            new.addfile(info, data)
    entry["size"] = target.stat().st_size
    entry["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
    (out / manifest_path.name).write_text(json.dumps(manifest, indent=2) + "\n")


def main(arguments: list) -> int:
    command, *rest = arguments
    if command == "certs":
        certs(Path(rest[0]))
    elif command == "serve":
        serve(Path(rest[0]), rest[1], Path(rest[2]))
    elif command == "variant":
        variant(rest[0], Path(rest[1]), Path(rest[2]))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
