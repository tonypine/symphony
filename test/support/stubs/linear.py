#!/usr/bin/env python3
"""The Linear stand-in: answers GraphQL queries by operation name from a committed answers file.

In QA the menu bar app sends its Linear queries (the Add Repo sheet's projects, teams and labels) to
http://localhost:<port>/graphql when qa_launch_app's `linear_stub_port` is set (SYMPHONY_QA_LINEAR_URL). This server
answers `POST /graphql` with the answer the answers file has for the query's operation name; an operation it has no
answer for is a GraphQL error that names it, which the app shows. Any API key works.

Usage:
  python3 -B test/support/stubs/linear.py --port 8125 --log linear.log
  python3 -B test/support/stubs/linear.py --answers my-answers.json --port 8125 --log linear.log

See test/support/README.md.
"""

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from stubs._server import StandIn, StubHandler, serve_cli  # noqa: E402

ANSWERS = Path(__file__).resolve().parent / "answers" / "linear.json"
GRAPHQL_ROUTE = "/graphql"
OPERATION = re.compile(r"\A\s*(?:query|mutation|subscription)\s+([_A-Za-z][_0-9A-Za-z]*)")


class LinearStubError(Exception):
    pass


def load_answers(path):
    """The answers in the JSON file at `path`: `{"answers": {"<operation name>": <the response body>}}`."""
    try:
        document = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise LinearStubError(f"can't read the answers file {path}: {error}") from error
    answers = document.get("answers") if isinstance(document, dict) else None
    if not isinstance(answers, dict) or not all(isinstance(body, dict) for body in answers.values()):
        raise LinearStubError(f"the answers file {path} has no `answers` object of operation name to response body")
    return answers


def error_body(message, code):
    """A GraphQL error as Linear words one: the app shows `userPresentableMessage`."""
    return {"errors": [{"message": message, "extensions": {"code": code, "userPresentableMessage": message}}]}


def read_request(body):
    """(operation name or None, variables) of a GraphQL POST body; raises LinearStubError when it isn't one."""
    try:
        request = json.loads(body)
    except ValueError:
        request = None
    if not isinstance(request, dict) or not isinstance(request.get("query"), str):
        raise LinearStubError("the body is not a GraphQL request: a JSON object with a `query` string")
    variables = request.get("variables")
    name = request.get("operationName")
    if not isinstance(name, str) or not name:
        found = OPERATION.match(request["query"])
        name = found.group(1) if found else None
    return name, variables


class LinearStub(StandIn):
    """The Linear stand-in, answering from the answers file at `answers` (the committed one by default)."""

    def __init__(self, answers=ANSWERS, *, port=0, log=None):
        self.answers_path = Path(answers)
        self.answers = load_answers(self.answers_path)
        super().__init__(_handler(self), port=port, log=log)

    @property
    def graphql_url(self):
        return f"{self.url}{GRAPHQL_ROUTE}"

    def answer(self, operation):
        """(status, body) for an operation: its committed answer, or a 400 GraphQL error that names it."""
        if operation in self.answers:
            return 200, self.answers[operation]
        known = ", ".join(sorted(self.answers)) or "none"
        if operation is None:
            message = "Linear stub: the query has no operation name, so it has no committed answer"
        else:
            message = f"Linear stub: no committed answer for the operation {operation}"
        return 400, error_body(f"{message} (answers for: {known}; answers file {self.answers_path})",
                               "STUB_UNKNOWN_OPERATION")


def _handler(stub):
    class Handler(StubHandler):
        def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler's name
            body = self.request_body().decode(errors="replace")
            if self.route != GRAPHQL_ROUTE:
                return self.not_found(sent=body)
            try:
                operation, variables = read_request(body)
            except LinearStubError as error:
                return self.respond(400, error_body(f"Linear stub: {error}", "STUB_BAD_REQUEST"), sent=body)
            status, answer = stub.answer(operation)
            # The log keeps the call, never the request's Authorization header.
            return self.respond(status, answer, fields={"operation": operation, "variables": variables})

        def do_GET(self):  # noqa: N802
            return self.not_found()

        do_HEAD = do_GET  # noqa: N815

        def not_found(self, sent=None):
            return self.respond(404, error_body(f"Linear stub: only POST {GRAPHQL_ROUTE} is answered",
                                                "STUB_NOT_FOUND"), sent=sent)

    return Handler


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--answers", type=Path, default=ANSWERS,
                        help="the answers file (default: the committed test/support/stubs/answers/linear.json)")
    parser.add_argument("--port", type=int, default=0, help="the port on 127.0.0.1 (default: a free one)")
    parser.add_argument("--log", type=Path, help="append one JSON line per request to this file")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        stub = LinearStub(args.answers, port=args.port, log=args.log)
    except (LinearStubError, OSError) as error:
        print(f"linear stub: {error}", file=sys.stderr)
        return 2
    serve_cli(stub.server, f"Linear stub on {stub.graphql_url} ({len(stub.answers)} answers from {args.answers}, "
              f"log {args.log or 'none'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
