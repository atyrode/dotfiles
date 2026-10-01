#!/usr/bin/env python3
"""Exercise the configured preview vhost through Caddy, without any live service."""
import base64
import hashlib
import http.client
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "preview.manifold.tyrode.dev"


def backend(label, port=0):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def respond(self):
            if self.headers.get("Upgrade", "").lower() == "websocket":
                key = self.headers["Sec-WebSocket-Key"]
                accept = base64.b64encode(hashlib.sha1(
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                ).digest()).decode()
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                protocol = self.headers.get("Sec-WebSocket-Protocol")
                if protocol:
                    self.send_header("Sec-WebSocket-Protocol", protocol)
                self.end_headers()
                payload = f"{label}:{self.path}".encode()
                self.connection.sendall(bytes([0x81, len(payload)]) + payload)
                self.close_connection = True
                return
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            payload = f"{label}:{self.command}:{self.path}".encode()
            self.send_response(418 if self.path == "/frontend-error" else 200)
            self.send_header("X-Fixture-Upstream", label)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)

        do_GET = do_HEAD = do_POST = respond

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def unused_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def rewrite_upstreams(value, ports):
    if isinstance(value, dict):
        if value.get("dial") in ports:
            value["dial"] = f"127.0.0.1:{ports[value['dial']]}"
        for child in value.values():
            rewrite_upstreams(child, ports)
    elif isinstance(value, list):
        for child in value:
            rewrite_upstreams(child, ports)


def http(port, path, upstream, method="GET", status=200):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=4)
    try:
        connection.request(method, path, headers={"Host": HOST})
        response = connection.getresponse()
        body = response.read().decode()
        assert response.status == status, (path, response.status, body)
        assert response.getheader("X-Fixture-Upstream") == upstream, (path, body)
        if method != "HEAD":
            assert body == f"{upstream}:{method}:{path}", body
    finally:
        connection.close()


def websocket(port, path, upstream, protocol=None):
    with socket.create_connection(("127.0.0.1", port), timeout=4) as connection:
        key = base64.b64encode(b"routing-fixture!").decode()
        headers = [
            f"GET {path} HTTP/1.1", f"Host: {HOST}", "Upgrade: websocket",
            "Connection: Upgrade", "Sec-WebSocket-Version: 13", f"Sec-WebSocket-Key: {key}",
        ]
        if protocol:
            headers.append(f"Sec-WebSocket-Protocol: {protocol}")
        connection.sendall(("\r\n".join(headers) + "\r\n\r\n").encode())
        response = b""
        while not response.endswith(b"\r\n\r\n"):
            chunk = connection.recv(1)
            assert chunk, response
            response += chunk
        assert response.startswith(b"HTTP/1.1 101 "), response
        expected_accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
        ).digest())
        received_headers = {}
        for line in response.split(b"\r\n")[1:-2]:
            name, value = line.split(b":", 1)
            received_headers[name.lower()] = value.strip()
        assert received_headers.get(b"sec-websocket-accept") == expected_accept, response
        if protocol:
            assert received_headers.get(b"sec-websocket-protocol") == protocol.encode(), response
        frame = b""
        while len(frame) < 2:
            chunk = connection.recv(2 - len(frame))
            assert chunk, frame
            frame += chunk
        assert frame[0] == 0x81, frame
        payload = b""
        while len(payload) < frame[1]:
            chunk = connection.recv(frame[1] - len(payload))
            assert chunk, payload
            payload += chunk
        assert payload.decode() == f"{upstream}:{path}", payload


hub = backend("hub")
frontend = None
frontend_port = unused_port()
proxy_port = unused_port()
process = None
try:
    adapted = subprocess.run(
        ["caddy", "adapt", "--config", sys.argv[1], "--adapter", "caddyfile"],
        check=True, capture_output=True, text=True,
    )
    config = json.loads(adapted.stdout)
    config["admin"] = {"disabled": True}
    config["apps"].pop("tls", None)
    servers = config["apps"]["http"]["servers"]
    assert len(servers) == 1, servers
    server = next(iter(servers.values()))
    server["listen"] = [f"127.0.0.1:{proxy_port}"]
    server.pop("tls_connection_policies", None)
    server["automatic_https"] = {"disable": True}
    rewrite_upstreams(config, {
        "127.0.0.1:7912": hub.server_port,
        "127.0.0.1:7913": frontend_port,
    })
    with tempfile.TemporaryDirectory(prefix="manifold-routing-") as directory:
        file = Path(directory) / "caddy.json"
        file.write_text(json.dumps(config))
        with (Path(directory) / "caddy.log").open("w+") as log:
            process = subprocess.Popen(["caddy", "run", "--config", str(file)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                while True:
                    try:
                        with socket.create_connection(("127.0.0.1", proxy_port), timeout=0.1):
                            break
                    except OSError:
                        assert process.poll() is None, "Caddy exited before readiness"
                        if time.monotonic() >= deadline:
                            raise AssertionError("Caddy did not become ready")
                        time.sleep(0.05)
                # Absence on initial start must serve the same hub's installed frontend.
                http(proxy_port, "/", "hub")
                http(proxy_port, "/installed-asset.js", "hub")
                frontend = backend("frontend", frontend_port)
                # Let the intentionally failed primary's bounded passive-health window expire.
                time.sleep(1.1)
                for path in ["/", "/@vite/client", "/src/panel.tsx", "/apian", "/auth-other", "/ws-other"]:
                    http(proxy_port, path, "frontend")
                http(proxy_port, "/", "frontend", method="HEAD")
                http(proxy_port, "/frontend-error", "frontend", status=418)
                for path in ["/api", "/api/protocol", "/auth", "/auth/preview/callback", "/ws", "/ws/machine", "/healthz", "/healthz/detail"]:
                    http(proxy_port, path, "hub")
                http(proxy_port, "/api/actions/example", "hub", method="POST")
                websocket(proxy_port, "/ws", "hub")
                websocket(proxy_port, "/ws/machine", "hub")
                websocket(proxy_port, "/", "frontend", protocol="vite-hmr")
                websocket(proxy_port, "/ws-other", "frontend", protocol="vite-hmr")
                frontend.shutdown()
                frontend.server_close()
                frontend = None
                http(proxy_port, "/", "hub")
                http(proxy_port, "/installed-asset.js", "hub")
                http(proxy_port, "/auth/preview/callback", "hub")
                websocket(proxy_port, "/ws", "hub")
                print("Caddy: frontend preference, installed fallback, exact hub namespaces and distinct hub/HMR WebSockets passed")
            except BaseException:
                log.flush()
                log.seek(0)
                sys.stderr.write(log.read())
                raise
            finally:
                process.terminate()
                process.wait(timeout=5)
                process = None
finally:
    if process is not None:
        process.kill()
        process.wait(timeout=5)
    if frontend is not None:
        frontend.shutdown()
        frontend.server_close()
    hub.shutdown()
    hub.server_close()
