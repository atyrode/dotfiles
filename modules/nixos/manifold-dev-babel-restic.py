"""Answer Babel's restic storage request for the Manifold owner, one connection at a time.

systemd listens on loopback, accepts each connection and starts this program for it
with the connected socket as descriptor 3. The bearer, the placed storage document and
the repository password arrive as this unit's credentials, loaded for this connection
alone, so a regenerated document is served on the next request. The only answer that
carries anything is GET /storage with the exact bearer, and it carries only the four
fields Babel's machine half reads. No value is ever logged; a refusal names the field.
"""

import hmac
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler

CREDENTIALS = os.environ.get("CREDENTIALS_DIRECTORY", "")
# The password file the placed document must name. The unit loads that file as the
# `repository-password` credential, so a document naming any other file is refused
# rather than answered with a password it did not name.
PASSWORD_FILE = sys.argv[1] if len(sys.argv) == 2 else ""
# restic reads a --password-file through Go's strings.TrimSpace, and the archive has
# always been opened that way. RESTIC_PASSWORD is taken verbatim, so the document
# carries the password exactly as restic derived it from the file.
GO_SPACE = "\t\n\v\f\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"


class Refusal(Exception):
    """The placed document cannot answer; the message names a field, never a value."""


def credential(name):
    with open(os.path.join(CREDENTIALS, name), "rb") as source:
        return source.read()


def text(value, field):
    if not isinstance(value, str) or value.strip(GO_SPACE) == "":
        raise Refusal(f"{field} is not a non-empty string")
    return value


def document():
    try:
        storage = json.loads(credential("storage.json"))
    except (OSError, ValueError):
        raise Refusal("storage.json is not a readable JSON document") from None
    if not isinstance(storage, dict):
        raise Refusal("storage.json is not an object")
    repository = text(storage.get("repository"), "repository")
    if storage.get("password_file") != PASSWORD_FILE:
        raise Refusal("password_file does not name the loaded repository password")
    try:
        password = credential("repository-password").decode("utf-8-sig").strip(GO_SPACE)
    except (OSError, UnicodeDecodeError):
        raise Refusal("the repository password is not readable UTF-8") from None
    if password == "":
        raise Refusal("the repository password is empty")
    answer = {"repository": repository, "password": password}
    store = storage.get("repository_store")
    if store is not None:
        if not isinstance(store, dict):
            raise Refusal("repository_store is not an object")
        key_id = store.get("access_key_id")
        secret = store.get("secret_access_key")
        if (key_id in (None, "")) != (secret in (None, "")):
            raise Refusal("repository_store holds half an object-store credential")
        if key_id not in (None, ""):
            answer["accessKeyId"] = text(key_id, "repository_store.access_key_id")
            answer["secretAccessKey"] = text(secret, "repository_store.secret_access_key")
    return answer


def authorized(values):
    try:
        bearer = credential("bearer").decode("ascii")
    except (OSError, UnicodeDecodeError):
        return False
    # The same framing the owner reads its credential with: one terminal line ending.
    bearer = bearer.removesuffix("\n").removesuffix("\r")
    if bearer == "" or len(values) != 1:
        return False
    return hmac.compare_digest(values[0].encode("latin-1"), f"Bearer {bearer}".encode("ascii"))


class Storage(BaseHTTPRequestHandler):
    server_version = "babel-restic-storage"
    timeout = 10

    def version_string(self):
        return self.server_version

    def log_message(self, format, *args):
        sys.stderr.write(format % args + "\n")

    def reply(self, status, body, headers=()):
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path != "/storage":
            self.reply(404, {"error": "not_found"})
        elif not authorized(self.headers.get_all("Authorization") or []):
            self.reply(401, {"error": "unauthorized"}, [("WWW-Authenticate", "Bearer")])
        else:
            try:
                answer = document()
            except Refusal as refusal:
                self.log_message("storage document refused: %s", refusal)
                self.reply(503, {"error": "storage_document_invalid"})
            else:
                self.reply(200, answer)


def main():
    if os.environ.get("LISTEN_PID") != str(os.getpid()) or os.environ.get("LISTEN_FDS") != "1":
        sys.exit("babel-restic-storage: expects exactly one connection from its systemd socket")
    if CREDENTIALS == "" or PASSWORD_FILE == "":
        sys.exit("babel-restic-storage: expects its credentials and the password file it loads")
    connection = socket.socket(fileno=3)
    try:
        Storage(connection, connection.getpeername(), None)
    finally:
        connection.close()


if __name__ == "__main__":
    main()
