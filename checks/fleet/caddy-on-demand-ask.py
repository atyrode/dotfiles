#!/usr/bin/env python3
"""Exercise the deployed on-demand TLS ask dispatcher through real Caddy.

argv: Caddyfile (global options + dispatcher site), JSON {zone: "127.0.0.1:port"}.
Each zone's router is replaced by a fixture that records the question it got.
"""
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

caddyfile, zones = sys.argv[1], json.loads(sys.argv[2])
assert zones, zones


def router(zone):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            payload = f"{zone}:{self.path}".encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
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


adapted = json.loads(subprocess.run(
    ["caddy", "adapt", "--config", caddyfile, "--adapter", "caddyfile"],
    check=True, capture_output=True, text=True,
).stdout)
# The global gate must be this dispatcher and nothing else.
permission = adapted["apps"]["tls"]["automation"]["on_demand"]["permission"]
assert permission == {"endpoint": "http://127.0.0.1:7899/__preview/ask", "module": "http"}, permission
servers = adapted["apps"]["http"]["servers"]
assert len(servers) == 1, servers
server = next(iter(servers.values()))
assert server["listen"] == ["127.0.0.1:7899"], server["listen"]

routers = {zone: router(zone) for zone in zones}
port = unused_port()
config = {"admin": {"disabled": True}, "apps": {"http": {"servers": {"ask": server}}}}
server["listen"] = [f"127.0.0.1:{port}"]
server["automatic_https"] = {"disable": True}
rewrite_upstreams(config, {upstream: routers[zone].server_port for zone, upstream in zones.items()})


def ask(domain):
    connection = HTTPConnection("127.0.0.1", port, timeout=4)
    try:
        connection.request("GET", f"/__preview/ask?domain={domain}")
        response = connection.getresponse()
        return response.status, response.read().decode()
    finally:
        connection.close()


with tempfile.TemporaryDirectory(prefix="on-demand-ask-") as directory:
    file = Path(directory) / "caddy.json"
    file.write_text(json.dumps(config))
    with (Path(directory) / "caddy.log").open("w+") as log:
        process = subprocess.Popen(["caddy", "run", "--config", str(file)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    assert process.poll() is None, "Caddy exited before readiness"
                    assert time.monotonic() < deadline, "Caddy did not become ready"
                    time.sleep(0.05)
            for zone in zones:
                for label in ["preview", "283", "pr-1464"]:
                    domain = f"{label}.{zone}"
                    # The router receives the question unchanged.
                    assert ask(domain) == (200, f"{zone}:/__preview/ask?domain={domain}"), domain
                # Deeper, outside and look-alike names never reach a router.
                for domain in [zone, f"a.b.{zone}", f"x.{zone}.attacker.example", f"x{zone}", f"X.{zone}"]:
                    assert ask(domain)[0] == 404, domain
            assert ask("auth.myparcelle.tyrode.dev")[0] == 404
            print(f"Caddy: on-demand ask dispatched exactly one label deep for {sorted(zones)}; everything else refused")
        except BaseException:
            log.flush()
            log.seek(0)
            sys.stderr.write(log.read())
            raise
        finally:
            process.terminate()
            process.wait(timeout=5)
