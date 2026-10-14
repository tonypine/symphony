# A verification dev server for the tests: serves its working folder over HTTP on
# $SYMPHONY_VERIFICATION_SOCKET when Symphony gives it one (macOS, where its sandbox allows no TCP
# listener), and on 127.0.0.1:$SYMPHONY_VERIFICATION_PORT otherwise.
import http.server
import os
import socketserver


class Handler(http.server.SimpleHTTPRequestHandler):
    # A unix socket's peer has no address to log.
    def address_string(self):
        return "client"


socket_path = os.environ.get("SYMPHONY_VERIFICATION_SOCKET")

if socket_path:
    server = socketserver.UnixStreamServer(socket_path, Handler)
else:
    server = http.server.HTTPServer(("127.0.0.1", int(os.environ["SYMPHONY_VERIFICATION_PORT"])), Handler)

server.serve_forever()
