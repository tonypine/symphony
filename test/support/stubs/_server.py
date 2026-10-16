"""What every HTTP stand-in shares: a server bound to 127.0.0.1 only, and one JSON line per request in a log file.

A stand-in subclasses `StubHandler`, answers with `respond`, and runs in a `StubServer`: in a background thread
(`start`, `stop`) from a test, or in the foreground (`serve_cli`) from its command line.
"""

import http.server
import json
import signal
import sys
import threading
import time
import urllib.parse

HOST = "127.0.0.1"


class RequestLog:
    """Appends one JSON object per request to `path`; keeps nothing when `path` is None."""

    def __init__(self, path=None):
        self.path = path
        self._lock = threading.Lock()

    def write(self, entry):
        if self.path is None:
            return
        line = json.dumps(entry, sort_keys=True) + "\n"
        with self._lock, open(self.path, "a", encoding="utf-8") as file:
            file.write(line)

    def entries(self):
        """Every logged request, oldest first."""
        if self.path is None:
            return []
        try:
            with open(self.path, encoding="utf-8") as file:
                return [json.loads(line) for line in file if line.strip()]
        except FileNotFoundError:
            return []


class StubHandler(http.server.BaseHTTPRequestHandler):
    """Answers through `respond`, which logs the request. Subclasses define `do_GET`, `do_POST` and so on."""

    server_version = "SymphonyStub/1"

    def log_message(self, format, *args):  # noqa: A002 - BaseHTTPRequestHandler's signature
        pass

    @property
    def route(self):
        """The request's path without its query string, unquoted."""
        return urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)

    def request_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def respond(self, status, body=b"", content_type="application/json", file=None, length=None, sent=None):
        """Sends `body` (bytes, or a dict/list sent as JSON), or `length` bytes of the open `file`, and logs the request.

        `sent` is what the log records as the request's body, such as a POST's payload.
        """
        if isinstance(body, (dict, list)):
            body = (json.dumps(body, sort_keys=True) + "\n").encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length if file is not None else len(body)))
        self.end_headers()
        if self.command != "HEAD":
            if file is not None:
                while True:
                    chunk = file.read(1 << 20)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            else:
                self.wfile.write(body)
        entry = {
            "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "method": self.command,
            "path": self.path,
            "status": status,
        }
        if sent is not None:
            entry["body"] = sent
        self.server.request_log.write(entry)


class StubServer(http.server.ThreadingHTTPServer):
    """A threading HTTP server on 127.0.0.1 only; port 0 picks a free one."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, handler, port=0, log_path=None):
        super().__init__((HOST, port), handler)
        self.request_log = RequestLog(log_path)
        self._thread = None

    @property
    def port(self):
        return self.server_address[1]

    @property
    def url(self):
        return f"http://{HOST}:{self.port}"

    def start(self):
        """Serves in a background thread; returns self."""
        self._thread = threading.Thread(target=self.serve_forever, daemon=True)
        self._thread.start()
        return self

    def stop(self):
        self.shutdown()
        self.server_close()
        if self._thread:
            self._thread.join(5)


def serve_cli(server, banner):
    """Serves `server` in the foreground until SIGINT or SIGTERM, after printing `banner` (one line) to stdout."""

    def stop(_signum, _frame):
        # shutdown() waits for serve_forever, which runs on this thread: hand it to another.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(banner, flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    sys.stdout.flush()
