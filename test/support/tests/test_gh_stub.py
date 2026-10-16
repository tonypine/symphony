"""The gh stand-in: its committed answers, through Symphony's own fake gh, unknown calls, its log lines, its CLI."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SUPPORT = Path(__file__).resolve().parents[1]
REPO = SUPPORT.parents[1]
sys.path.insert(0, str(SUPPORT))

from stubs import gh  # noqa: E402
from stubs.gh import GhStub, GhStubError  # noqa: E402

BRANCH = "symphony/add-workflow"
TITLE = "Add WORKFLOW.md for Symphony"
SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# Each call the Add Repo sheet makes for acme/widgets (macos/Sources/SymphonyBarCore/WorkflowSetup.swift), and the
# start of what the fake gh prints for it.
COMMITTED_CALLS = [
    (["api", "repos/acme/widgets", "--jq", ".default_branch"], "main\n"),
    (["api", "repos/acme/widgets/contents?ref=main", "--jq", ".[].name"], "README.md\nmix.exs\nmix.lock\n"),
    (["api", "repos/acme/widgets/contents/mix.exs?ref=main", "-H", "Accept: application/vnd.github.raw"],
     "defmodule Widgets.MixProject do\n"),
    (["api", "repos/acme/widgets/git/ref/heads/main", "--jq", ".object.sha"], SHA + "\n"),
    (["api", "-X", "POST", "repos/acme/widgets/git/refs", "-f", f"ref=refs/heads/{BRANCH}", "-f", f"sha={SHA}"],
     '{"ref": "refs/heads/symphony/add-workflow"'),
    (["api", "-X", "PUT", "repos/acme/widgets/contents/WORKFLOW.md", "-f", f"message={TITLE}",
      "-f", "content=LS0tCmhvb2tzOiB7fQo=", "-f", f"branch={BRANCH}"], '{"content": {"name": "WORKFLOW.md"'),
    (["pr", "create", "--repo", "acme/widgets", "--base", "main", "--head", BRANCH, "--title", TITLE,
      "--body", "Symphony's Add Repo sheet drafted this `WORKFLOW.md`…\n\nSymphony reads `WORKFLOW.md` from `main`."],
     "https://github.com/acme/widgets/pull/1\n"),
    (["api", "-X", "DELETE", f"repos/acme/widgets/git/refs/heads/{BRANCH}"], ""),
]


def fake_gh_script():
    """Symphony's fake gh, as qa_launch_app installs it for the app (`@fake_gh` in lib/symphony_elixir/qa_driver.ex)."""
    source = (REPO / "lib" / "symphony_elixir" / "qa_driver.ex").read_text()
    body = re.search(r'^  @fake_gh """\n(.*?)^  """$', source, re.DOTALL | re.MULTILINE).group(1)
    return textwrap.dedent(body).replace("\\\\", "\\")


def post(url, body):
    """(status, text) of a POST of `body` (bytes)."""
    request = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def form(args):
    """The fake gh's form body for a call."""
    return urllib.parse.urlencode([("argc", str(len(args)))] + [("arg", arg) for arg in args]).encode()


class GhStubTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.log = self.tmp / "gh.log"

    def start(self, answers=gh.ANSWERS):
        stub = GhStub(answers, log=self.log).start()
        self.addCleanup(stub.stop)
        return stub

    def write_answers(self, document):
        path = self.tmp / "answers.json"
        path.write_text(json.dumps(document))
        return path


class AnswersTest(GhStubTestCase):
    def test_answers_each_committed_call_and_logs_it(self):
        stub = self.start()
        for args, output in COMMITTED_CALLS:
            with self.subTest(args=args[:4]):
                status, text = post(stub.url, form(args))
                self.assertEqual(status, 200)
                self.assertTrue(text.startswith(output), text)
        entries = stub.requests
        self.assertEqual([entry["args"] for entry in entries], [args for args, _ in COMMITTED_CALLS])
        self.assertEqual({(entry["method"], entry["path"], entry["status"]) for entry in entries}, {("POST", "/", 200)})
        for entry in entries:
            self.assertRegex(entry["time"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")

    def test_an_unknown_call_is_a_404_that_names_it(self):
        stub = self.start()
        status, text = post(stub.url, form(["api", "repos/acme/other", "--jq", ".default_branch"]))
        self.assertEqual(status, 404)
        self.assertIn("gh stub: no committed answer for: gh api repos/acme/other --jq .default_branch", text)
        self.assertIn(str(gh.ANSWERS), text)
        # A call is matched argument by argument: one more argument is another call.
        status, _ = post(stub.url, form(["api", "repos/acme/widgets", "--jq", ".default_branch", "--paginate"]))
        self.assertEqual(status, 404)
        self.assertEqual([entry["status"] for entry in stub.requests], [404, 404])
        self.assertEqual(stub.requests[0]["args"], ["api", "repos/acme/other", "--jq", ".default_branch"])

    def test_a_star_matches_any_text_inside_one_argument(self):
        stub = self.start(self.write_answers({"answers": [
            {"args": ["pr", "view", "*"], "output": "first\n"},
            {"args": ["pr", "view", "1", "--json", "body=*!"], "status": 422, "output": "Validation Failed\n"},
            {"args": ["pr", "view", "1", "--json", "*"], "output": "second\n"},
            {"args": ["[x]", ".[].name"], "output": "literal\n"},
        ]}))
        self.assertEqual(post(stub.url, form(["pr", "view", "two\nlines"])), (200, "first\n"))
        self.assertEqual(post(stub.url, form(["pr", "view", "1", "--json", "body=a*b\n!"])),
                         (422, "Validation Failed\n"))
        self.assertEqual(post(stub.url, form(["pr", "view", "1", "--json", "body=a"])), (200, "second\n"))
        self.assertEqual(post(stub.url, form(["[x]", ".[].name"])), (200, "literal\n"))
        self.assertEqual(post(stub.url, form(["x", ".[].name"]))[0], 404)

    def test_a_body_that_is_not_a_gh_call_is_a_400(self):
        stub = self.start()
        for body, reason in [
            (b"", "it must start with argc"),
            (b"arg=api", "it must start with argc"),
            (b"argc=two&arg=api", "it must start with argc"),
            (b"argc=2&arg=api", "argc is 2 but it has 1 more fields"),
            (b"argc=1&arg=api&flag=x", "argc is 1 but it has 2 more fields"),
        ]:
            with self.subTest(body=body):
                status, text = post(stub.url, body)
                self.assertEqual(status, 400)
                self.assertIn(reason, text)
        self.assertEqual(stub.requests[-1]["body"], "argc=1&arg=api&flag=x")

    def test_answers_only_post_to_the_root(self):
        stub = self.start()
        self.assertEqual(post(f"{stub.url}/graphql", form(["auth", "status"])),
                         (404, "gh stub: POST each call to /\n"))
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(stub.url, timeout=10)
        self.assertEqual(raised.exception.code, 404)
        raised.exception.close()
        self.assertEqual([(entry["method"], entry["status"]) for entry in stub.requests], [("POST", 404), ("GET", 404)])

    def test_an_empty_argument_is_kept(self):
        stub = self.start(self.write_answers({"answers": [{"args": ["api", ""], "output": "empty\n"}]}))
        self.assertEqual(post(stub.url, form(["api", ""])), (200, "empty\n"))

    def test_binds_127_0_0_1_only(self):
        stub = self.start()
        self.assertEqual(stub.server.server_address[0], "127.0.0.1")
        self.assertTrue(stub.url.startswith("http://127.0.0.1:"))


class AnswersFileTest(GhStubTestCase):
    def test_the_committed_answers_load(self):
        self.assertEqual(len(gh.load_answers(gh.ANSWERS)), len(COMMITTED_CALLS))

    def test_a_bad_answers_file_is_refused(self):
        cases = [
            ("not json", "can't read the answers file"),
            ([], "has no `answers` list"),
            ({"answers": {}}, "has no `answers` list"),
            ({"answers": ["api"]}, "an answer must be an object"),
            ({"answers": [{"args": "api"}]}, "args must be a list of strings"),
            ({"answers": [{"args": [1]}]}, "args must be a list of strings"),
            ({"answers": [{"args": ["api"], "status": 99}]}, "not an HTTP status"),
            ({"answers": [{"args": ["api"], "status": True}]}, "not an HTTP status"),
            ({"answers": [{"args": ["api"], "output": 1}]}, "not a string"),
        ]
        for document, message in cases:
            with self.subTest(document=document):
                path = self.tmp / "answers.json"
                path.write_text(document if isinstance(document, str) else json.dumps(document))
                with self.assertRaisesRegex(GhStubError, re.escape(message)):
                    gh.load_answers(path)
        with self.assertRaisesRegex(GhStubError, "can't read the answers file"):
            gh.load_answers(self.tmp / "missing.json")


@unittest.skipUnless(shutil.which("curl"), "Symphony's fake gh needs curl")
class FakeGhTest(GhStubTestCase):
    """The stub answers the calls the app makes through the fake gh qa_launch_app installs."""

    def run_fake_gh(self, stub, args):
        script = self.tmp / "gh"
        if not script.exists():
            script.write_text(fake_gh_script())
            script.chmod(0o700)
        env = dict(os.environ, SYMPHONY_QA_GH_URL=stub.url, TMPDIR=str(self.tmp))
        return subprocess.run(["/bin/sh", str(script)] + args, capture_output=True, text=True, env=env, timeout=60)

    def test_the_fake_gh_prints_each_committed_answer_and_the_unknown_calls_error(self):
        stub = self.start()
        for args, output in COMMITTED_CALLS:
            with self.subTest(args=args[:4]):
                result = self.run_fake_gh(stub, args)
                self.assertEqual((result.returncode, result.stderr), (0, ""))
                self.assertTrue(result.stdout.startswith(output), result.stdout)
        unknown = self.run_fake_gh(stub, ["auth", "status"])
        self.assertEqual((unknown.returncode, unknown.stdout), (1, ""))
        self.assertIn("gh stub: no committed answer for: gh auth status", unknown.stderr)
        self.assertEqual([entry["args"] for entry in stub.requests],
                         [args for args, _ in COMMITTED_CALLS] + [["auth", "status"]])


class CommandLineTest(GhStubTestCase):
    def test_serves_and_logs_from_the_command_line(self):
        process = subprocess.Popen(
            [sys.executable, "-B", str(SUPPORT / "stubs" / "gh.py"), "--log", str(self.log)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.wait, 10)
        self.addCleanup(process.terminate)
        banner = process.stdout.readline()
        self.assertRegex(banner, rf"^gh stub on http://127\.0\.0\.1:\d+ \({len(COMMITTED_CALLS)} answers from ")
        url = banner.split(" on ", 1)[1].split()[0]
        self.assertEqual(post(url, form(COMMITTED_CALLS[0][0])), (200, "main\n"))
        self.assertEqual(post(url, form(["auth", "status"]))[0], 404)
        process.terminate()
        self.assertEqual(process.wait(10), 0)
        self.assertEqual([json.loads(line)["status"] for line in self.log.read_text().splitlines()], [200, 404])

    def test_parse_args(self):
        args = gh.parse_args([])
        self.assertEqual((args.answers, args.port, args.log), (gh.ANSWERS, 0, None))
        args = gh.parse_args(["--answers", "a.json", "--port", "8124", "--log", "gh.log"])
        self.assertEqual((args.answers, args.port, args.log), (Path("a.json"), 8124, Path("gh.log")))

    def test_exits_2_on_a_bad_answers_file(self):
        result = subprocess.run([sys.executable, "-B", str(SUPPORT / "stubs" / "gh.py"), "--answers",
                                 str(self.tmp / "missing.json")], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2)
        self.assertIn("gh stub: can't read the answers file", result.stderr)


if __name__ == "__main__":
    unittest.main()
