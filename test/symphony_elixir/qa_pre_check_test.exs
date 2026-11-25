defmodule SymphonyElixir.QaPreCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaPreCheck
  alias SymphonyElixir.TestSupport.ProofSteps
  alias SymphonyElixir.Walkthrough

  @tried "tried as a describe plus a test name, a test name, a describe name and a Swift class plus method"

  # Laid out as TP-1217's and TP-1273's test files are: a test inside a describe, its name on its own line.
  @director_moves_test """
  defmodule SymphonyElixir.DirectorMovesTest do
    describe "the Director's moves" do
      test "an approved plan's record is in the waiting state at once, and stays there when Linear refuses the move", %{opts: opts} do
        opts
      end

      test "the Inbox lists a quiet handoff, and Unblock lifts it, answering its question \\"Run it again\\"", %{opts: opts} do
        opts
      end

      test "\\"Run\\" runs it, \\"Stop\\" stops it" do
      end

      test "\\"Run\\" runs it, \\"Stop\\" stops \\"it\\"" do
      end
    end

    test "a quiet handoff stays when its question is answered \\"Keep it paused\\"" do
    end
  end
  """

  @orchestrator_status_test """
  defmodule SymphonyElixir.OrchestratorStatusTest do
    describe "the stall check and the no-progress watchdog" do
      setup do
        :ok
      end

      test "log an unobserved run once, whatever its kind, and never restart it" do
      end

      test "says \\"stalled\\" in the log" do
      end
    end

    test "outside any describe" do
    end

    test "a name that goes on
    over two lines" do
    end
  end
  """

  @timeline_keys_tests """
  import XCTest

  final class TimelineKeysTests: XCTestCase {
      func testAClickLeavesNoRowSelectedAndSoNoOutline() {
          XCTAssertTrue(true)
      }
  }
  """

  # A real checkout, so the named test is looked up the way recording a proof looks it up.
  setup do
    dir = Path.join(System.tmp_dir!(), "qa-pre-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "test/symphony_elixir"))
    File.mkdir_p!(Path.join(dir, ".github/workflows"))
    File.write!(Path.join(dir, "test/symphony_elixir/check_test.exs"), ~s(test "reports pass when the check passed" do\nend\ntest "handles a/b input" do\nend\n))
    File.write!(Path.join(dir, "test/symphony_elixir/other_test.exs"), ~s(test "only in the other file" do\nend\n# Walkthrough.steps\n))
    File.write!(Path.join(dir, ".github/workflows/macos-e2e.yml"), "jobs:\n  e2e:\n    name: update, restart and rollback\n")
    File.write!(Path.join(dir, "README.md"), "symphony_elixir names are listed here\n")
    # A missing test file's path in quotes, as text, which a quoted path must never be found as.
    File.write!(Path.join(dir, "paths.exs"), ~s(x = "test/symphony_elixir/gone_test.exs"\n))
    File.write!(Path.join(dir, "test/symphony_elixir/director_moves_test.exs"), @director_moves_test)
    File.write!(Path.join(dir, "test/symphony_elixir/orchestrator_status_test.exs"), @orchestrator_status_test)
    # Tests whose own names open with a tracked file, as `docs/playbook.md matches …` does in this repo.
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "docs/x.md"), "# Partials\n")
    File.write!(Path.join(dir, "symphony.yml"), "repos: []\n")

    File.write!(
      Path.join(dir, "test/symphony_elixir/playbook_catalog_test.exs"),
      ~s(test "docs/x.md matches the partials" do\nend\ntest "symphony.yml is required before children are built" do\nend\n)
    )

    # A Swift test whose class and method are declared on different lines, as XCTest writes them,
    # and a class and a method of the same names split across two files.
    File.mkdir_p!(Path.join(dir, "macos/Tests"))
    File.write!(Path.join(dir, "macos/Tests/TimelineKeysTests.swift"), @timeline_keys_tests)
    File.write!(Path.join(dir, "macos/Tests/SplitTests.swift"), "final class SplitTests: XCTestCase {}\n")
    File.write!(Path.join(dir, "macos/Tests/Other.swift"), "struct Other {\n    func testSplit() {}\n}\n")

    git!(dir, ["init", "-q"])
    git!(dir, ["add", "."])
    git!(dir, ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "-m", "first"])
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, workspace: dir}
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  defp steps(text), do: ProofSteps.steps(text)

  # What the checkout lacks of the test a `Proved by:` spec names, read as a recorded proof is.
  defp missing(spec, context, opts \\ []),
    do: spec |> String.replace("`", "") |> Walkthrough.proof_test() |> QaPreCheck.missing_test(context.workspace, opts)

  describe "proved/1 and report_checks/1" do
    test "a step a recorded test proves is proved as recorded, with nothing read from CI or the checkout" do
      text = """
      1. Open it. Proved by: QA
      2. Run it. Proved by: `test/symphony_elixir/check_test.exs`
      3. Close it.
      4. Fold it. Proved by: `make-all` › `test/nowhere_test.exs`
      """

      assert [%{number: 2, proof: %{by: :test, test: "test/symphony_elixir/check_test.exs"}}, %{number: 4, proof: %{test: "test/nowhere_test.exs"}}] =
               proved = QaPreCheck.proved(steps(text))

      assert QaPreCheck.proved(steps("1. Open it. Proved by: QA\n2. Close it.")) == []
      assert QaPreCheck.proved([]) == []

      assert QaPreCheck.report_checks(proved) == [
               %{name: "step 2", status: :proved, detail: "proved by `test/symphony_elixir/check_test.exs`, recorded on the ticket"},
               %{name: "step 4", status: :proved, detail: "proved by `test/nowhere_test.exs`, recorded on the ticket"}
             ]

      assert QaPreCheck.report_checks(steps("1. Open it. Proved by: QA")) == []
    end

    test "no report line says a check passed on the head or that the test is in the checkout" do
      lines = "1. Run it. Proved by: `make-all` › `test/symphony_elixir/check_test.exs`" |> steps() |> QaPreCheck.proved() |> QaPreCheck.report_checks()

      assert [%{detail: detail}] = lines
      refute detail =~ "passed"
      refute detail =~ "in the checkout"
      refute detail =~ "make-all"
    end
  end

  describe "missing_test/3" do
    test "a test name, a scenario name, a name with a slash or a bare file name is found in the checkout", context do
      for spec <- [
            ~s(`make-all` › "reports pass when the check passed"),
            "`macos-e2e` › update, restart and rollback",
            "`make-all` › `check_test.exs:2`",
            ~s(`make-all` › `test/symphony_elixir/check_test.exs` › "reports pass when the check passed"),
            "`make-all` › Walkthrough.steps",
            "`.github/workflows`",
            ~s(`make-all` › `test/symphony_elixir/check_test.exs` › "handles a/b input")
          ] do
        assert missing(spec, context) == nil, spec
      end
    end

    test "a test named as an implementer copies it, file and name or describe and name, is found", context do
      full = "the stall check and the no-progress watchdog log an unobserved run once, whatever its kind, and never restart it"
      moves = "test/symphony_elixir/director_moves_test.exs"
      status = "test/symphony_elixir/orchestrator_status_test.exs"
      approved = "an approved plan's record is in the waiting state at once, and stays there when Linear refuses the move"

      for spec <- [
            "make-all › #{moves}: #{approved}",
            "make-all › #{full}",
            "`#{full}`",
            "`#{status}: #{full}`",
            ~s(`#{moves}:3: "#{approved}"`),
            "`#{moves} #{approved}`",
            "`orchestrator_status_test.exs the stall check and the no-progress watchdog`",
            "`test #{full} (SymphonyElixir.OrchestratorStatusTest)`",
            "`test #{full} (2.1ms) [L#7]`",
            ~s(`the stall check and the no-progress watchdog says "stalled" in the log`),
            "`#{status}: outside any describe`",
            "`make-all` › `.github/workflows macos-e2e.yml`",
            "`symphony_elixir names are listed here`",
            "`docs/x.md matches the partials`",
            "make-all › symphony.yml is required before children are built",
            "`test/symphony_elixir/playbook_catalog_test.exs: docs/x.md matches the partials`"
          ] do
        assert missing(spec, context) == nil, spec
      end
    end

    # TP-1300: TP-1249's step named a test whose name ends in a quoted phrase, and lost its last quote.
    test "a test name that ends in a quoted phrase keeps its closing quote, in every form", context do
      moves = "test/symphony_elixir/director_moves_test.exs"
      handoff = ~s(the Inbox lists a quiet handoff, and Unblock lifts it, answering its question "Run it again")

      for spec <- [
            "`make-all` › #{moves}: #{handoff}",
            "`make-all` › the Director's moves › #{handoff}",
            "`the Director's moves #{handoff}`",
            ~s(make-all › #{moves}: "#{handoff}"),
            ~s(make-all › #{moves}: a quiet handoff stays when its question is answered "Keep it paused"),
            ~s(make-all › #{moves} › "Run" runs it, "Stop" stops it),
            ~s(make-all › #{moves} › "Run" runs it, "Stop" stops "it")
          ] do
        assert missing(spec, context) == nil, spec
      end
    end

    test "a test named nowhere is missing, naming the file it narrowed to and the forms it tried", context do
      status = "test/symphony_elixir/orchestrator_status_test.exs"

      specs = [
        "`test/symphony_elixir/check_test.exs: the stall check and the no-progress watchdog log an unobserved run once, whatever its kind, and never restart it`",
        "`#{status}: the stall check and the no-progress watchdog outside any describe`",
        "`#{status}: a name that goes on over two lines`",
        "`test/symphony_elixir/missing_test.exs: does it`",
        "`Walkthrough.steps parses it`",
        "`docs/x.md is nowhere`",
        ~s(make-all › "never "here""),
        ~s(make-all › "test/symphony_elixir/gone_test.exs"),
        "`make-all` › the QA pre-check's test file",
        ~s(`make-all` › `test/symphony_elixir/check_test.exs` › "only in the other file")
      ]

      assert Enum.map(specs, &missing(&1, context)) == [
               "`the stall check and the no-progress watchdog log an unobserved run once, whatever its kind, and never restart it` " <>
                 "is not in `test/symphony_elixir/check_test.exs` (#{@tried})",
               "`the stall check and the no-progress watchdog outside any describe` is not in `#{status}` (#{@tried})",
               "`a name that goes on over two lines` is not in `#{status}` (#{@tried})",
               "`test/symphony_elixir/missing_test.exs` is not in the checkout",
               "`Walkthrough.steps parses it` is not in the checkout (#{@tried})",
               "`is nowhere` is not in `docs/x.md` (#{@tried})",
               ~s(`never "here"` is not in the checkout \(#{@tried}\)),
               "`test/symphony_elixir/gone_test.exs` is not in the checkout",
               "`the QA pre-check's test file` is not in the checkout (#{@tried})",
               "`only in the other file` is not in `test/symphony_elixir/check_test.exs` (#{@tried})"
             ]
    end

    test "a checkout git cannot list has no named test in it", context do
      git = fn _args, _workspace -> {"fatal: not a git repository", 128} end

      assert missing("`check_test.exs`", context, git: git) == "`check_test.exs` is not in the checkout (#{@tried})"
    end

    test "the test name forms a refusal names" do
      assert QaPreCheck.test_name_forms() =~ "a Swift class plus method"
    end
  end

  describe "a Swift test named as class plus method" do
    test "it is found when the class and the method are on different lines of one Swift file", context do
      assert missing("`TimelineKeysTests testAClickLeavesNoRowSelectedAndSoNoOutline`", context) == nil
    end

    test "it is found as XCTest prints it too, and within the Swift file a path names", context do
      for test <- [
            "TimelineKeysTests.testAClickLeavesNoRowSelectedAndSoNoOutline",
            "TimelineKeysTests/testAClickLeavesNoRowSelectedAndSoNoOutline",
            "TimelineKeysTests testAClickLeavesNoRowSelectedAndSoNoOutline()",
            "macos/Tests/TimelineKeysTests.swift: TimelineKeysTests testAClickLeavesNoRowSelectedAndSoNoOutline"
          ] do
        assert QaPreCheck.missing_test(test, context.workspace) == nil, test
      end
    end

    test "the class and the method must be declared in the same file, within the scope a path names", context do
      assert QaPreCheck.missing_test("SplitTests testSplit", context.workspace) ==
               "`SplitTests testSplit` is not in the checkout (#{@tried})"

      assert QaPreCheck.missing_test("SplitTests/testSplit", context.workspace) == "`SplitTests/testSplit` is not in the checkout"
      assert QaPreCheck.missing_test("TimelineKeysTests testNothing", context.workspace) =~ "is not in the checkout"

      assert QaPreCheck.missing_test("test/symphony_elixir/check_test.exs: TimelineKeysTests testAClickLeavesNoRowSelectedAndSoNoOutline", context.workspace) =~
               "is not in `test/symphony_elixir/check_test.exs`"
    end

    test "a proof with no test names nothing missing", context do
      assert QaPreCheck.missing_test(nil, context.workspace) == nil
    end
  end
end
