#!/usr/bin/env python3
"""The gh stand-in: answers the calls Symphony's fake `gh` sends it from a committed answers file.

In QA the menu bar app runs Symphony's fake `gh` (qa_launch_app's `gh_stub_port` sets SYMPHONY_BAR_GH), which POSTs
each call to http://localhost:<port> as a form body, `argc` then one `arg` per argument, and prints the answer: a 200
on stdout with exit status 0, anything else on stderr with exit status 1. This server gives the answer of the first
entry in the answers file whose `args` match the call; a call no entry matches is a 404 that names it.

Usage:
  python3 -B test/support/stubs/gh.py --port 8124 --log gh.log
  python3 -B test/support/stubs/gh.py --answers my-answers.json --port 8124 --log gh.log

See test/support/README.md.
"""

import argparse
import json
import re
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from stubs._server import StandIn, StubHandler, serve_cli  # noqa: E402

ANSWERS = Path(__file__).resolve().parent / "answers" / "gh.json"


class GhStubError(Exception):
    pass


def argument_pattern(pattern):
    """A matcher for one argument: `*` matches any text (newlines too), everything else only itself."""
    if "*" not in pattern:
        return lambda arg: arg == pattern
    regex = re.compile(".*".join(re.escape(part) for part in pattern.split("*")), re.DOTALL)
    return lambda arg: regex.fullmatch(arg) is not None


class Answer:
    """One entry of the answers file: the call's `args` and what the stub answers, `status` (200 by default) and
    `output` (what the fake gh prints: stdout for a 200, stderr otherwise)."""

    def __init__(self, entry):
        if not isinstance(entry, dict):
            raise GhStubError(f"an answer must be an object, got {entry!r}")
        args, status, output = entry.get("args"), entry.get("status", 200), entry.get("output", "")
        if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
            raise GhStubError(f"an answer's args must be a list of strings, got {args!r}")
        if not isinstance(status, int) or isinstance(status, bool) or not 100 <= status <= 599:
            raise GhStubError(f"the answer to {args!r} has status {status!r}, not an HTTP status")
        if not isinstance(output, str):
            raise GhStubError(f"the answer to {args!r} has output {output!r}, not a string")
        self.args, self.status, self.output = args, status, output
        self._matchers = [argument_pattern(arg) for arg in args]

    def matches(self, args):
        return len(args) == len(self._matchers) and all(match(arg) for match, arg in zip(self._matchers, args))


def load_answers(path):
    """The answers in the JSON file at `path`: `{"answers": [{"args": [...], "status": 200, "output": "..."}]}`."""
    try:
        document = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise GhStubError(f"can't read the answers file {path}: {error}") from error
    entries = document.get("answers") if isinstance(document, dict) else None
    if not isinstance(entries, list):
        raise GhStubError(f"the answers file {path} has no `answers` list")
    return [Answer(entry) for entry in entries]


def read_call(body):
    """The call's arguments, in order, from the fake gh's form body; raises GhStubError when it isn't one."""
    fields = urllib.parse.parse_qsl(body, keep_blank_values=True)
    if not fields or fields[0][0] != "argc" or not fields[0][1].isdigit():
        raise GhStubError("the body is not a gh call: it must start with argc, then one arg field per argument")
    args = [value for name, value in fields[1:] if name == "arg"]
    if len(args) != len(fields) - 1 or len(args) != int(fields[0][1]):
        raise GhStubError(f"the call's argc is {fields[0][1]} but it has {len(fields) - 1} more fields")
    return args


def command_line(args):
    return " ".join(["gh"] + [arg if re.fullmatch(r"[\w./:=?@%+,-]+", arg) else json.dumps(arg) for arg in args])


class GhStub(StandIn):
    """The gh stand-in, answering from the answers file at `answers` (the committed one by default)."""

    def __init__(self, answers=ANSWERS, *, port=0, log=None):
        self.answers_path = Path(answers)
        self.answers = load_answers(self.answers_path)
        super().__init__(_handler(self), port=port, log=log)

    def answer(self, args):
        """(status, text) for a call: the first matching answer's, or a 404 that names the call."""
        for answer in self.answers:
            if answer.matches(args):
                return answer.status, answer.output
        return 404, (f"gh stub: no committed answer for: {command_line(args)}\n"
                     f"(answers file {self.answers_path}; add one there)\n")


def _handler(stub):
    class Handler(StubHandler):
        def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler's name
            body = self.request_body().decode(errors="replace")
            if self.route != "/":
                return self.respond(404, "gh stub: POST each call to /\n", content_type="text/plain", sent=body)
            try:
                args = read_call(body)
            except GhStubError as error:
                return self.respond(400, f"gh stub: {error}\n", content_type="text/plain", sent=body)
            status, output = stub.answer(args)
            return self.respond(status, output, content_type="text/plain", fields={"args": args})

        def do_GET(self):  # noqa: N802
            return self.respond(404, "gh stub: POST each call to /\n", content_type="text/plain")

        do_HEAD = do_GET  # noqa: N815

    return Handler


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--answers", type=Path, default=ANSWERS,
                        help="the answers file (default: the committed test/support/stubs/answers/gh.json)")
    parser.add_argument("--port", type=int, default=0, help="the port on 127.0.0.1 (default: a free one)")
    parser.add_argument("--log", type=Path, help="append one JSON line per request to this file")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        stub = GhStub(args.answers, port=args.port, log=args.log)
    except (GhStubError, OSError) as error:
        print(f"gh stub: {error}", file=sys.stderr)
        return 2
    serve_cli(stub.server, f"gh stub on {stub.url} ({len(stub.answers)} answers from {args.answers}, "
              f"log {args.log or 'none'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
