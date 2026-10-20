"""The Linear stand-in: its committed answers by operation name, unknown operations, its log lines, its CLI."""

import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

SUPPORT = Path(__file__).resolve().parents[1]
REPO = SUPPORT.parents[1]
sys.path.insert(0, str(SUPPORT))

from stubs import linear  # noqa: E402
from stubs.linear import LinearStub, LinearStubError  # noqa: E402

LINEAR_API = REPO / "macos" / "Sources" / "SymphonyBarCore" / "LinearAPI.swift"
PAGE_INFO = {"hasNextPage": False, "endCursor": None}
COMMITTED = {
    "SymphonyBarProjects": {"data": {"projects": {"nodes": [{"id": "p1", "name": "QA Project"}],
                                                  "pageInfo": PAGE_INFO}}},
    "SymphonyBarProjectTeams": {"data": {"project": {"teams": {"nodes": [{"id": "t1", "key": "QA"}], "pageInfo": PAGE_INFO}}}},
    "SymphonyBarLabels": {"data": {"issueLabels": {"nodes": [{"id": "l1", "name": "macos", "isGroup": False}],
                                                   "pageInfo": PAGE_INFO}}},
}


def app_queries():
    """The app's GraphQL queries (LinearAPI.swift's `static let …Query`), by operation name."""
    source = LINEAR_API.read_text()
    queries = re.findall(r'static let \w+Query = """\n(.*?)"""', source, re.DOTALL)
    return {re.search(r"query (\w+)", query).group(1): query for query in queries}


def post(url, body, headers=None):
    """(status, parsed JSON) of a POST of `body` (bytes)."""
    request = urllib.request.Request(url, data=body, method="POST", headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        with error:
            return error.code, json.loads(error.read())


def graphql(query, variables=None, **extra):
    return json.dumps(dict({"query": query, "variables": variables or {"first": 50}}, **extra)).encode()


def error_message(answer):
    error = answer["errors"][0]
    assert error["message"] == error["extensions"]["userPresentableMessage"]
    return error["message"]


class LinearStubTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.log = self.tmp / "linear.log"

    def start(self, answers=linear.ANSWERS):
        stub = LinearStub(answers, log=self.log).start()
        self.addCleanup(stub.stop)
        return stub


class AnswersTest(LinearStubTestCase):
    def test_answers_each_of_the_apps_queries_and_logs_it(self):
        stub = self.start()
        queries = app_queries()
        self.assertEqual(sorted(queries), sorted(COMMITTED))
        variables = {"first": 50, "projectId": "p1"}
        for name, query in queries.items():
            with self.subTest(operation=name):
                self.assertEqual(post(stub.graphql_url, graphql(query, variables),
                                      headers={"Authorization": "lin_api_made_up", "Content-Type": "application/json"}),
                                 (200, COMMITTED[name]))
        entries = stub.requests
        self.assertEqual([entry["operation"] for entry in entries], list(queries))
        self.assertEqual({(entry["method"], entry["path"], entry["status"]) for entry in entries},
                         {("POST", "/graphql", 200)})
        for entry in entries:
            self.assertEqual(entry["variables"], variables)
            self.assertRegex(entry["time"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertNotIn("lin_api_made_up", self.log.read_text())

    def test_the_operation_name_comes_from_operation_name_first(self):
        stub = self.start()
        status, answer = post(stub.graphql_url, graphql("{ viewer { id } }", operationName="SymphonyBarLabels"))
        self.assertEqual((status, answer), (200, COMMITTED["SymphonyBarLabels"]))
        status, answer = post(stub.graphql_url, graphql("  mutation SymphonyBarProjects { x }", operationName=""))
        self.assertEqual((status, answer), (200, COMMITTED["SymphonyBarProjects"]))

    def test_an_unknown_operation_is_a_graphql_error_that_names_it(self):
        stub = self.start()
        status, answer = post(stub.graphql_url, graphql("query SymphonyBarIssues { issues { nodes { id } } }"))
        self.assertEqual(status, 400)
        message = error_message(answer)
        self.assertIn("Linear stub: no committed answer for the operation SymphonyBarIssues", message)
        self.assertIn("answers for: SymphonyBarLabels, SymphonyBarProjectTeams, SymphonyBarProjects", message)
        self.assertEqual(answer["errors"][0]["extensions"]["code"], "STUB_UNKNOWN_OPERATION")
        status, answer = post(stub.graphql_url, graphql("{ viewer { id } }"))
        self.assertEqual(status, 400)
        self.assertIn("the query has no operation name", error_message(answer))
        self.assertEqual([(entry["operation"], entry["status"]) for entry in stub.requests],
                         [("SymphonyBarIssues", 400), (None, 400)])

    def test_a_body_that_is_not_graphql_is_a_400(self):
        stub = self.start()
        for body in (b"", b"not json", b"[]", b'{"variables": {}}', b'{"query": 1}'):
            with self.subTest(body=body):
                status, answer = post(stub.graphql_url, body)
                self.assertEqual(status, 400)
                self.assertIn("the body is not a GraphQL request", error_message(answer))
                self.assertEqual(answer["errors"][0]["extensions"]["code"], "STUB_BAD_REQUEST")
        self.assertEqual(stub.requests[-1]["body"], '{"query": 1}')

    def test_answers_only_post_to_graphql(self):
        stub = self.start()
        status, answer = post(f"{stub.url}/", graphql("query SymphonyBarProjects { x }"))
        self.assertEqual(status, 404)
        self.assertEqual(error_message(answer), "Linear stub: only POST /graphql is answered")
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(stub.graphql_url, timeout=10)
        self.assertEqual(raised.exception.code, 404)
        raised.exception.close()
        self.assertEqual([(entry["method"], entry["status"]) for entry in stub.requests], [("POST", 404), ("GET", 404)])

    def test_with_no_answers_it_says_so(self):
        path = self.tmp / "answers.json"
        path.write_text(json.dumps({"answers": {}}))
        stub = self.start(path)
        self.assertIn("answers for: none", error_message(post(stub.graphql_url, graphql("query A { a }"))[1]))

    def test_binds_127_0_0_1_only(self):
        stub = self.start()
        self.assertEqual(stub.server.server_address[0], "127.0.0.1")
        self.assertTrue(stub.graphql_url.startswith("http://127.0.0.1:"))
        self.assertTrue(stub.graphql_url.endswith("/graphql"))


class AnswersFileTest(LinearStubTestCase):
    def test_the_committed_answers_are_the_ones_qa_expects(self):
        self.assertEqual(linear.load_answers(linear.ANSWERS), COMMITTED)

    def test_a_bad_answers_file_is_refused(self):
        for document, message in [
            ("not json", "can't read the answers file"),
            ([], "has no `answers` object"),
            ({"answers": []}, "has no `answers` object"),
            ({"answers": {"SymphonyBarProjects": []}}, "has no `answers` object"),
        ]:
            with self.subTest(document=document):
                path = self.tmp / "answers.json"
                path.write_text(document if isinstance(document, str) else json.dumps(document))
                with self.assertRaisesRegex(LinearStubError, re.escape(message)):
                    linear.load_answers(path)
        with self.assertRaisesRegex(LinearStubError, "can't read the answers file"):
            linear.load_answers(self.tmp / "missing.json")


class CommandLineTest(LinearStubTestCase):
    def test_serves_and_logs_from_the_command_line(self):
        process = subprocess.Popen(
            [sys.executable, "-B", str(SUPPORT / "stubs" / "linear.py"), "--log", str(self.log)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.wait, 10)
        self.addCleanup(process.terminate)
        banner = process.stdout.readline()
        self.assertRegex(banner, r"^Linear stub on http://127\.0\.0\.1:\d+/graphql \(3 answers from ")
        url = banner.split(" on ", 1)[1].split()[0]
        self.assertEqual(post(url, graphql(app_queries()["SymphonyBarProjects"])),
                         (200, COMMITTED["SymphonyBarProjects"]))
        self.assertEqual(post(url, graphql("query Other { x }"))[0], 400)
        process.terminate()
        self.assertEqual(process.wait(10), 0)
        self.assertEqual([json.loads(line)["status"] for line in self.log.read_text().splitlines()], [200, 400])

    def test_parse_args(self):
        args = linear.parse_args([])
        self.assertEqual((args.answers, args.port, args.log), (linear.ANSWERS, 0, None))
        args = linear.parse_args(["--answers", "a.json", "--port", "8125", "--log", "linear.log"])
        self.assertEqual((args.answers, args.port, args.log), (Path("a.json"), 8125, Path("linear.log")))

    def test_exits_2_on_a_bad_answers_file(self):
        result = subprocess.run([sys.executable, "-B", str(SUPPORT / "stubs" / "linear.py"), "--answers",
                                 str(self.tmp / "missing.json")], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2)
        self.assertIn("linear stub: can't read the answers file", result.stderr)


if __name__ == "__main__":
    unittest.main()
