#!/usr/bin/env python3
"""One stdlib-only P8 runtime provider, bound to an explicit loopback address."""

import argparse
import ipaddress
import json
import os
import signal
import socket
import stat
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class IPv6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def loopback_url(value):
    url = urllib.parse.urlsplit(value)
    if url.scheme not in ("http", "https") or not url.hostname:
        raise ValueError("host must be a loopback HTTP(S) URL")
    try:
        local = ipaddress.ip_address(url.hostname).is_loopback
    except ValueError:
        local = url.hostname == "localhost"
    if not local or "@" in url.netloc or url.query or url.fragment:
        raise ValueError("host must be loopback, without credentials, query, or fragment")
    return value.rstrip("/")


def read_private_token(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "r", encoding="utf-8") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError(f"token file must be a private regular file: {path}")
        token = source.read().strip()
    if not token:
        raise ValueError(f"token file is empty: {path}")
    return token


def write_private_token(path, token):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".provider-token-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(token + "\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def descriptor(provider_id):
    name = f"{provider_id}-service_echo"
    return {
        "name": name,
        "description": "Echo text supplied by the caller; a reference runtime provider verb.",
        "input_schema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Text to echo unchanged."}
            },
            "required": ["text"],
            "additionalProperties": False,
        },
        "output_schema": {
            "type": "object",
            "properties": {
                "echo": {"type": "string", "description": "The unchanged text."}
            },
            "required": ["echo"],
            "additionalProperties": False,
        },
        "safety": {"class": "read-only", "idempotent": True},
        "since": "0.1.0",
        "examples": [
            {"name": "echoes-text", "args": {"text": "hello"}, "expect": {"echo": "hello"}}
        ],
    }


def make_handler(verb_name, token_state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            # Neither bearer tokens nor bodies belong in the server log.
            pass

        def answer(self, status, body):
            encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def refusal(self, status, code, message):
            self.answer(
                status,
                {"ok": False, "wire_version": 1, "code": code, "message": message},
            )

        def do_GET(self):
            if self.path == "/health":
                self.answer(200, {"ok": True})
            else:
                self.refusal(404, "not-found", "unknown path")

        def do_POST(self):
            if self.path != f"/verb/{verb_name}":
                self.refusal(404, "not-found", "unknown verb")
                return
            if self.headers.get("Authorization") != f"Bearer {token_state['token']}":
                self.refusal(401, "invalid-argument", "invalid provider token")
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if size < 0 or size > 1_048_576:
                    raise ValueError("body size")
                args = json.loads(self.rfile.read(size))
                if not isinstance(args, dict) or set(args) != {"text"}:
                    raise ValueError("argument shape")
                text = args["text"]
                if not isinstance(text, str):
                    raise ValueError("text type")
            except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                self.refusal(422, "invalid-argument", "text must be a string")
                return
            self.answer(200, {"echo": text})

    return Handler


def register(host, host_token, provider_id, endpoint, prior_token):
    provider = {
        "id": provider_id,
        "language": "python",
        "version": "0.1.0",
        "endpoint": endpoint,
    }
    if prior_token:
        provider["token"] = prior_token
    body = json.dumps({"provider": provider, "verbs": [descriptor(provider_id)]}).encode("utf-8")
    request = urllib.request.Request(
        host + "/api/providers/register",
        data=body,
        headers={"Authorization": f"Bearer {host_token}", "Content-Type": "application/json"},
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=5) as response:
            receipt = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"host registration refused with HTTP {error.code}") from None
    if isinstance(receipt, dict) and isinstance(receipt.get("result"), dict):
        receipt = receipt["result"]
    if not isinstance(receipt, dict) or receipt.get("provider_id") != provider_id:
        raise RuntimeError("host returned an invalid provider receipt")
    token = receipt.get("token")
    if not isinstance(token, str) or not token or token == prior_token:
        raise RuntimeError("host did not issue a rotated provider token")
    return token


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="isolated host base URL")
    parser.add_argument("--host-token-file", required=True, type=Path)
    parser.add_argument("--token-file", required=True, type=Path, help="private provider token path")
    parser.add_argument("--provider-id", default="python-reference")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="owned port; 0 selects a free port")
    args = parser.parse_args()
    try:
        host = loopback_url(args.host)
        if not ipaddress.ip_address(args.listen_host).is_loopback:
            raise ValueError("listen host must be a loopback IP address")
        if not args.provider_id or any(
            not word or not all(char.isascii() and (char.islower() or char.isdigit()) for char in word)
            for word in args.provider_id.split("-")
        ):
            raise ValueError("provider id must be kebab-case")
        host_token = read_private_token(args.host_token_file)
        if not host_token:
            raise ValueError("host token file is missing")
        prior_token = read_private_token(args.token_file)
        token_state = {"token": prior_token}
        verb_name = f"{args.provider_id}-service_echo"
        server_type = IPv6Server if ":" in args.listen_host else ThreadingHTTPServer
        with server_type((args.listen_host, args.port), make_handler(verb_name, token_state)) as server:
            host_for_url = f"[{args.listen_host}]" if ":" in args.listen_host else args.listen_host
            endpoint = f"http://{host_for_url}:{server.server_port}"
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                token_state["token"] = register(host, host_token, args.provider_id, endpoint, prior_token)
                write_private_token(args.token_file, token_state["token"])
                print(f"registered {verb_name} at {endpoint}", flush=True)
                signal.signal(signal.SIGTERM, lambda *_: server.shutdown())
                thread.join()
            finally:
                server.shutdown()
                thread.join()
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        parser.exit(1, f"runtime provider: {error}\n")


if __name__ == "__main__":
    main()
