defmodule SymphonyElixir.ReviewAgentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ReviewAgent
  alias SymphonyElixir.ReviewAgent.Context

  defmodule StreamingCodexReviewer do
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(_session, _prompt, _issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)

      [
        ~s({"ver),
        ~s(dict":"request_changes",),
        ~s("findings":[{"summary":"Handle remote guides.","file":"feature.txt","line_range":[1,1],),
        ~s("quoted_snippet":"grounded evidence line","suggested_fix":"Keep the evidence-backed change."}]})
      ]
      |> Enum.each(fn delta ->
        on_message.(%{
          event: :notification,
          payload: %{
            "method" => "item/agentMessage/delta",
            "params" => %{"delta" => delta}
          },
          raw: Jason.encode!(%{"method" => "item/agentMessage/delta", "params" => %{"delta" => delta}})
        })
      end)

      {:ok, %{input_tokens: 1, output_tokens: 1}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule SequenceReviewer do
    def start_session(workspace, opts) do
      parent = Application.fetch_env!(:symphony_elixir, :review_agent_sequence_parent)
      send(parent, :review_agent_sequence_session_started)
      send(parent, {:review_agent_sequence_session_opts, opts})
      {:ok, %{workspace: workspace, opts: opts}}
    end

    def run_turn(_session, prompt, _issue, opts) do
      parent = Application.fetch_env!(:symphony_elixir, :review_agent_sequence_parent)
      count = Application.get_env(:symphony_elixir, :review_agent_sequence_count, 0) + 1
      Application.put_env(:symphony_elixir, :review_agent_sequence_count, count)
      send(parent, {:review_agent_sequence_call, count, prompt, opts})

      responses = Application.fetch_env!(:symphony_elixir, :review_agent_sequence_responses)

      case Enum.at(responses, count - 1) do
        {:error, reason} -> {:error, reason}
        response when is_binary(response) -> {:ok, %{result: response}}
      end
    end

    def stop_session(_session), do: :ok
  end

  defmodule RuntimeTupleReviewer do
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(_session, _prompt, _issue, _opts) do
      {:ok, %{result: "{:error, {:turn_failed, reason}}"}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule RuntimeTupleWithStreamingReviewer do
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(_session, _prompt, _issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)

      on_message.(%{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => ~s({"verdict":"approve","comments":[]})}
        }
      })

      {:ok, %{result: "{:error, {:turn_failed, reason}}"}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule MaxIterationsWithPartialReviewer do
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(_session, _prompt, _issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)

      on_message.(%{
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "partial reviewer thought that must not become a block reason"}
        }
      })

      {:error, {:turn_failed, "max_iterations reached"}}
    end

    def stop_session(_session), do: :ok
  end

  describe "parse_response/1" do
    test "accepts approved verdict JSON inside surrounding text" do
      assert {:ok, %{verdict: :approve, comments: []}} =
               ReviewAgent.parse_response("""
               Review complete.
               ```json
               {"verdict":"approve","comments":[]}
               ```
               """)
    end

    test "accepts request_changes with actionable comments" do
      assert {:ok, %{verdict: :request_changes, comments: ["Add coverage."]}} =
               ReviewAgent.parse_response(~s({"verdict":"request_changes","comments":["Add coverage."]}))
    end

    test "accepts findings with required evidence fields" do
      assert {:ok,
              %{
                verdict: :block,
                findings: [
                  %{
                    summary: "Bad branch",
                    file: "lib/example.ex",
                    line_range: {10, 12},
                    quoted_snippet: "if unsafe?",
                    suggested_fix: "Guard the unsafe path."
                  }
                ],
                reason: "Unsafe to continue."
              }} =
               ReviewAgent.parse_response("""
               {
                 "verdict": "block",
                 "findings": [{
                   "summary": "Bad branch",
                   "file": "lib/example.ex",
                   "line_range": [10, 12],
                   "quoted_snippet": "if unsafe?",
                   "suggested_fix": "Guard the unsafe path."
                 }],
                 "reason": "Unsafe to continue."
               }
               """)
    end

    test "requires comments for request_changes" do
      assert {:error, {:malformed_review_agent_response, :missing_request_changes_comments}} =
               ReviewAgent.parse_response(~s({"verdict":"request_changes","comments":[]}))
    end

    test "requires a reason for block" do
      assert {:error, {:malformed_review_agent_response, :missing_block_reason}} =
               ReviewAgent.parse_response(~s({"verdict":"block","comments":[]}))
    end

    test "classifies an Elixir error tuple as reviewer runtime failure" do
      assert {:error, {:review_agent_runtime_error, "{:error, {:turn_failed, reason}}"}} =
               ReviewAgent.parse_response("{:error, {:turn_failed, reason}}")
    end

    test "skips non-JSON brace groups before reviewer verdict JSON" do
      assert {:ok, %{verdict: :approve, comments: []}} =
               ReviewAgent.parse_response("""
               finalize returns `{:ok, session}` and failed turns return
               `{:error, {:turn_failed, reason}}`.
               {"verdict":"approve","comments":[],"reason":""}
               """)
    end
  end

  describe "validate_findings/2" do
    test "keeps a block finding whose quoted snippet matches the diff line range" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-ok")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)
        result = %{verdict: :block, comments: [], findings: [finding()], reason: "Unsafe to continue."}

        assert {:ok, %{findings: [kept]}} = ReviewAgent.validate_findings(result, source)
        assert kept.summary == "Handle remote guides."
      after
        File.rm_rf(test_root)
      end
    end

    test "accepts a quoted snippet with a reviewer annotation header" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-annotation-header")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)
        snippet = "# feature.txt:1 - site of the bug\ngrounded evidence line"
        result = %{verdict: :block, comments: [], findings: [finding(snippet)], reason: "Unsafe to continue."}

        assert {:ok, %{findings: [kept]}} = ReviewAgent.validate_findings(result, source)
        assert kept.quoted_snippet == snippet
      after
        File.rm_rf(test_root)
      end
    end

    test "accepts a quoted snippet with diff prefixes" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-diff-prefix")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)
        result = %{verdict: :block, comments: [], findings: [finding("+grounded evidence line")], reason: "Unsafe to continue."}

        assert {:ok, %{findings: [kept]}} = ReviewAgent.validate_findings(result, source)
        assert kept.summary == "Handle remote guides."
      after
        File.rm_rf(test_root)
      end
    end

    test "accepts a quoted snippet formatted as a full git diff" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-full-diff")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)

        snippet = """
        diff --git a/feature.txt b/feature.txt
        index 0123456..789abcd 100644
        --- a/feature.txt
        +++ b/feature.txt
        @@ -0,0 +1 @@
        +grounded evidence line
        """

        result = %{verdict: :block, comments: [], findings: [finding(snippet)], reason: "Unsafe to continue."}

        assert {:ok, %{findings: [kept]}} = ReviewAgent.validate_findings(result, source)
        assert kept.quoted_snippet == snippet
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects a block finding whose quoted snippet does not match the cited range" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-bad-snippet")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)

        result = %{
          verdict: :block,
          comments: [],
          findings: [finding("missing text")],
          reason: "Unsafe to continue."
        }

        assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, payload}}} =
                 ReviewAgent.validate_findings(result, source)

        assert %{verdict: :block, failures: [_failure]} = payload
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects a finding whose file is outside the diff and adjacent context" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-missing-file")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)

        result = %{
          verdict: :block,
          comments: [],
          findings: [finding("grounded evidence line", "other.txt")],
          reason: "Unsafe."
        }

        assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, payload}}} =
                 ReviewAgent.validate_findings(result, source)

        assert %{failures: [%{reason: {:file_not_in_review_context, "other.txt"}}]} = payload
      after
        File.rm_rf(test_root)
      end
    end

    test "relocates a finding whose snippet is cited 1 to 10 lines off" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-relocate")
      repo = git_repo_with_file_change!(test_root, numbered_lines(1..40), changed_line(numbered_lines(1..40), 20))

      try do
        source = source_for_repo!(repo)

        for cited <- [{21, 21}, {10, 10}, {30, 30}, {25, 27}] do
          finding = %{finding("changed line 20") | line_range: cited}
          result = %{verdict: :request_changes, comments: [], findings: [finding]}

          assert {:ok, %{findings: [kept], comments: [comment]}} = ReviewAgent.validate_findings(result, source)
          assert kept.line_range == {20, 20}
          assert comment =~ "(feature.txt:20-20)"
        end
      after
        File.rm_rf(test_root)
      end
    end

    test "relocates a finding that cites the hunk but quotes unchanged lines of the file" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-unchanged")
      repo = git_repo_with_file_change!(test_root, numbered_lines(1..60), changed_line(numbered_lines(1..60), 20))

      try do
        source = source_for_repo!(repo)
        finding = %{finding("-line 45\n line 46") | line_range: {20, 20}}
        result = %{verdict: :block, comments: [], findings: [finding], reason: "Unsafe."}

        assert {:ok, %{findings: [kept]}} = ReviewAgent.validate_findings(result, source)
        assert kept.line_range == {45, 46}
      after
        File.rm_rf(test_root)
      end
    end

    test "moves a finding to the match nearest the cited range" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-nearest")
      original = numbered_lines(1..40)

      modified =
        original
        |> String.replace("line 5\n", "repeated line\n")
        |> String.replace("line 28\n", "repeated line\n")

      repo = git_repo_with_file_change!(test_root, original, modified)

      try do
        source = source_for_repo!(repo)
        result = %{verdict: :block, comments: [], findings: [%{finding("repeated line") | line_range: {24, 24}}], reason: "Unsafe."}

        assert {:ok, %{findings: [%{line_range: {28, 28}}]}} = ReviewAgent.validate_findings(result, source)
      after
        File.rm_rf(test_root)
      end
    end

    test "does not match a snippet across lines no evidence source covers" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-gap")
      original = numbered_lines(1..80)
      modified = original |> changed_line(10) |> changed_line(60)
      repo = git_repo_with_file_change!(test_root, original, modified)

      try do
        source = repo |> source_for_repo!() |> Map.put(:file_contents, %{})
        finding = %{finding("line 17\nline 54") | line_range: {10, 10}}
        result = %{verdict: :block, comments: [], findings: [finding], reason: "Unsafe."}

        assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, %{failures: [failure]}}}} =
                 ReviewAgent.validate_findings(result, source)

        assert %{reason: :quoted_snippet_not_found, evidence: %{text: "changed line 10"}} = failure
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects a snippet with nothing but diff headers" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-header-only")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)
        result = %{verdict: :block, comments: [], findings: [finding("@@ -0,0 +1 @@")], reason: "Unsafe."}

        assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, %{failures: [failure]}}}} =
                 ReviewAgent.validate_findings(result, source)

        assert failure.reason == :quoted_snippet_not_found
      after
        File.rm_rf(test_root)
      end
    end

    test "reports a missing line range when the snippet is nowhere in the file" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-missing-range")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)
        result = %{verdict: :block, comments: [], findings: [%{finding("not here") | line_range: {50, 51}}], reason: "Unsafe."}

        assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, %{failures: [failure]}}}} =
                 ReviewAgent.validate_findings(result, source)

        assert failure.reason == {:line_range_not_found, "feature.txt", {50, 51}}
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects request_changes when all findings fail validation" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-request-changes")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)
        result = %{verdict: :request_changes, comments: [], findings: [finding("wrong quote")]}

        assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, %{verdict: :request_changes}}}} =
                 ReviewAgent.validate_findings(result, source)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "unverified_notes/1" do
    test "lists each dropped finding as an unverified note" do
      payload = %{failures: [%{finding: finding("missing"), reason: :quoted_snippet_not_found}], comments: ["ignored"]}

      assert ReviewAgent.unverified_notes(payload) == [
               "[unverified] Handle remote guides. (feature.txt:1-1) Suggested fix: Keep the evidence-backed change."
             ]
    end

    test "falls back to the reviewer's comments when it gave no findings" do
      assert ReviewAgent.unverified_notes(%{failures: [], comments: ["Consider a test."]}) == ["Consider a test."]
      assert ReviewAgent.unverified_notes(%{failures: []}) == []
    end
  end

  describe "approval_prompt/2" do
    test "lists advisory notes without asking for code changes" do
      prompt = ReviewAgent.approval_prompt(%{verdict: :approve, comments: [], advisory_notes: ["[unverified] First.", "[unverified] Second."]})

      assert prompt =~ "Reviewer agent approved the committed diff."
      assert prompt =~ "advisory notes: do not change code for them before\nthe push"
      assert prompt =~ "1. [unverified] First.\n2. [unverified] Second."
      refute ReviewAgent.approval_prompt(%{verdict: :approve, comments: []}) =~ "advisory notes"
    end

    test "says the push goes ahead without reviewer approval when the reviewer stayed inconclusive" do
      inconclusive = %{verdict: :approve, comments: [], inconclusive: "reviewer did not converge: request-change limit reached"}
      prompt = ReviewAgent.approval_prompt(Map.put(inconclusive, :advisory_notes, ["Still not acceptable."]))

      assert prompt =~ "Reviewer agent stayed inconclusive twice on the committed diff (reviewer did not converge: request-change limit reached)."
      assert prompt =~ "CI, QA and the supervisor still\ngate the PR"
      assert prompt =~ "in the PR body that the pre-push reviewer"
      assert prompt =~ "The reviewer's last pass still raised the findings below"
      assert prompt =~ "1. Still not acceptable."
      refute prompt =~ "Reviewer agent approved the committed diff."
      refute prompt =~ "quoted lines could not be found"

      refute ReviewAgent.approval_prompt(inconclusive) =~ "advisory notes"
    end

    test "uses bare scoped GitHub tools for Codex executors" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")

      prompt =
        ReviewAgent.approval_prompt(%{verdict: :approve, comments: []},
          settings: Config.settings!()
        )

      assert prompt =~ "`github_get_pull_request`"
      assert prompt =~ "`github_push_branch`"
      assert prompt =~ "`github_create_pull_request`"
      assert prompt =~ "`linear_attach_url`"
      assert prompt =~ "`linear_update_comment`"
      assert prompt =~ "do not use `linear_add_comment`"
      assert prompt =~ "record the gap"
      assert prompt =~ "posting a summary comment"
      assert prompt =~ "If these scoped tools are not visible"
      assert prompt =~ "Avoid raw `gh` or `git push`"
    end

    test "uses prefixed Symphony MCP GitHub tools for Claude executors" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        agent_command: "claude --print"
      )

      prompt =
        ReviewAgent.approval_prompt(%{verdict: :approve, comments: []},
          settings: Config.settings!()
        )

      assert prompt =~ "`mcp__symphony__github_get_pull_request`"
      assert prompt =~ "`mcp__symphony__github_push_branch`"
      assert prompt =~ "`mcp__symphony__github_create_pull_request`"
      assert prompt =~ "`mcp__symphony__linear_attach_url`"
      assert prompt =~ "`mcp__symphony__linear_update_comment`"
      assert prompt =~ "do not use `mcp__symphony__linear_add_comment`"
      assert prompt =~ "record the gap"
      assert prompt =~ "posting a summary comment"
      assert prompt =~ "Do not search for these with ToolSearch"
      assert prompt =~ "Avoid raw"
      assert prompt =~ "`gh` or `git push`"
    end
  end

  test "evaluate parses Codex reviewer verdicts from streamed agent-message deltas" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-agent-streaming-codex-#{System.unique_integer([:positive])}"
      )

    try do
      repo = git_repo_with_change!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      issue = %Issue{
        id: "issue-review-streaming",
        identifier: "MT-STREAM",
        title: "Stream review verdict",
        description: "Review result is only available through item/agentMessage/delta chunks",
        state: "In Progress"
      }

      assert {:ok, %{verdict: :request_changes, comments: [comment], findings: [_finding]}} =
               ReviewAgent.evaluate(issue, repo, Config.settings!(), review_agent_module: StreamingCodexReviewer)

      assert comment =~ "Handle remote guides."
    after
      File.rm_rf(test_root)
    end
  end

  test "evaluate prompt includes discipline and evidence-backed findings schema" do
    test_root = unique_tmp("symphony-elixir-review-agent-prompt")

    try do
      repo = git_repo_with_change!(test_root)
      put_sequence_responses!([~s({"verdict":"approve","comments":[]})])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_receive {:review_agent_sequence_call, 1, prompt, _opts}
      assert prompt =~ "Discipline:"
      assert prompt =~ "Do not cite a function, file, or line you have not read"
      assert prompt =~ ~s("findings")
      assert prompt =~ ~s("line_range": [1, 2])
      assert prompt =~ ~s("quoted_snippet")
      assert prompt =~ "Review the diff by reading it."
      assert prompt =~ "Do not run the test suite, `make all`, coverage or static analysis such as Dialyzer"
      assert prompt =~ "CI runs them after the push."
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate on a worker host runs git through symphony_git with the repo's diff drivers off" do
    test_root = unique_tmp("symphony-elixir-review-agent-worker-git")
    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      repo = git_repo_with_change!(test_root)
      bin = Path.join(test_root, "bin")
      trace = Path.join(test_root, "ssh.trace")
      marker = Path.join(test_root, "diff-driver-ran")
      driver = Path.join(test_root, "diff-driver")
      File.mkdir_p!(bin)
      File.write!(driver, "#!/bin/sh\ntouch '#{marker}'\n")
      File.chmod!(driver, 0o755)
      git!(repo, ["config", "diff.external", driver])

      # Records the script `ssh` gets for `bash -lc` and runs it here, without a login shell.
      File.write!(Path.join(bin, "ssh"), """
      #!/bin/sh
      for last; do :; done
      eval "set -- $last"
      printf '%s\\n' "$3" >> '#{trace}'
      exec bash -c "$3"
      """)

      File.chmod!(Path.join(bin, "ssh"), 0o755)
      System.put_env("PATH", bin <> ":" <> (previous_path || ""))
      put_sequence_responses!([~s({"verdict":"approve","comments":[]})])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(),
                 review_agent_module: SequenceReviewer,
                 worker_host: "worker-01"
               )

      assert_receive {:review_agent_sequence_call, 1, prompt, _opts}
      assert prompt =~ "grounded evidence line"
      refute File.exists?(marker)

      script = File.read!(trace)
      assert script =~ "symphony_git_raw() {"
      assert script =~ "symphony_git '#{repo}' 'merge-base' 'origin/main' 'HEAD'"
      assert script =~ ~r/symphony_git '#{Regex.escape(repo)}' 'diff' '--no-ext-diff' '--no-textconv' '[0-9a-f]{40}\.\.HEAD'/
      assert script =~ "symphony_git '#{repo}' 'log' '--no-ext-diff' '--no-textconv' '--reverse'"
      refute script =~ "'git' '-C'"
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate prompt reviews code quality and bugs, not the ticket's acceptance criteria or scope" do
    test_root = unique_tmp("symphony-elixir-review-agent-rubric")

    try do
      repo = git_repo_with_change!(test_root)
      put_sequence_responses!([~s({"verdict":"approve","comments":[]})])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"},
        prompt: "Executor workflow: check every acceptance criterion and move the issue to In Review."
      )

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_receive {:review_agent_sequence_call, 1, prompt, _opts}
      assert prompt =~ "Correctness: bugs in the changed code"
      assert prompt =~ "Tests: each new branch, error path and edge case the diff adds has a test"
      assert prompt =~ "Error handling:"
      assert prompt =~ "The repo's code rules: read the repo's agent instructions (`AGENTS.md`, `CLAUDE.md`)"
      assert prompt =~ "Narrow scope is a code rule"
      assert prompt =~ "Do not judge whether the diff meets the ticket's acceptance criteria or matches the ticket's scope"
      refute prompt =~ "Workflow review criteria"
      refute prompt =~ "Executor workflow"
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate gives the reviewer the executor run's temp folder as its $TMPDIR" do
    test_root = unique_tmp("symphony-elixir-review-agent-tmp-dir")

    try do
      repo = git_repo_with_change!(test_root)
      put_sequence_responses!([~s({"verdict":"approve","comments":[]}), ~s({"verdict":"approve","comments":[]})])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(),
                 review_agent_module: SequenceReviewer,
                 agent_tmp_dir: "/tmp/symphony-run-0123456789ab"
               )

      assert_receive {:review_agent_sequence_session_opts, opts}
      assert opts[:extra_env] == %{"TMPDIR" => "/tmp/symphony-run-0123456789ab"}

      # A run without a temp folder of its own leaves the reviewer's runtime default.
      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_receive {:review_agent_sequence_session_opts, opts}
      assert opts[:extra_env] == %{}
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate uses origin HEAD when no base branch is configured" do
    test_root = unique_tmp("symphony-elixir-review-agent-origin-head")

    try do
      repo = git_repo_with_origin_head_change!(test_root, "trunk")
      put_sequence_responses!([~s({"verdict":"approve","comments":[]})])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_receive {:review_agent_sequence_call, 1, prompt, _opts}
      assert prompt =~ "feature.txt"
      assert prompt =~ "grounded evidence line"
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate returns a block error whose findings pass self-check and validation" do
    test_root = unique_tmp("symphony-elixir-review-agent-self-check-ok")

    try do
      repo = git_repo_with_change!(test_root)
      response = block_response([finding_json()])
      put_sequence_responses!([response, response])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:error, {:review_agent_blocked, %{reason: "Unsafe to continue.", findings: [finding]}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert finding.quoted_snippet == "grounded evidence line"
      assert_receive {:review_agent_sequence_call, 1, _prompt, _opts}
      assert_receive {:review_agent_sequence_call, 2, self_check_prompt, opts}
      assert self_check_prompt =~ "For each finding, paste the exact lines"
      assert opts[:max_iterations] == 4
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate keeps only validated findings in the block error after self-check" do
    test_root = unique_tmp("symphony-elixir-review-agent-self-check-filter")

    try do
      repo = git_repo_with_change!(test_root)
      good = finding_json()
      bad = finding_json(%{"quoted_snippet" => "not in the file"})
      put_sequence_responses!([block_response([good, bad]), block_response([good, bad])])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:error, {:review_agent_blocked, %{findings: [finding]}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert finding.quoted_snippet == "grounded evidence line"
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate re-quotes unverifiable findings in the same session and accepts a corrected quote" do
    test_root = unique_tmp("symphony-elixir-review-agent-requote-ok")

    try do
      repo = git_repo_with_change!(test_root)
      bad_quote = finding_json(%{"quoted_snippet" => "a misremembered line"})
      outside = finding_json(%{"file" => "other.txt", "summary" => "Outside the diff."})
      past_end = finding_json(%{"quoted_snippet" => "beyond the file", "line_range" => [40, 41], "summary" => "Past the end."})
      unverifiable = block_response([bad_quote, outside, past_end])
      put_sequence_responses!([unverifiable, unverifiable, block_response([finding_json()])])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:error, {:review_agent_blocked, %{findings: [finding]}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert finding.quoted_snippet == "grounded evidence line"
      assert_received :review_agent_sequence_session_started
      refute_received :review_agent_sequence_session_started

      assert_received {:review_agent_sequence_call, 3, requote_prompt, opts}
      assert opts[:max_iterations] == 4
      assert requote_prompt =~ "could not find the quoted snippet"
      assert requote_prompt =~ "- feature.txt:1-1: Handle remote guides.\n  Quoted snippet:\n    a misremembered line"
      assert requote_prompt =~ "  Text at the cited lines:\n    grounded evidence line"
      assert requote_prompt =~ "- other.txt:1-1: Outside the diff."
      assert requote_prompt =~ "(file is not in the diff or the review context)"
      assert requote_prompt =~ "- feature.txt:40-41: Past the end."
      assert requote_prompt =~ "(no lines at this range in the diff or the changed file)"
      assert requote_prompt =~ "Previous JSON:"
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate stays unverifiable when the re-quoted findings still do not match" do
    test_root = unique_tmp("symphony-elixir-review-agent-requote-still-bad")

    try do
      repo = git_repo_with_change!(test_root)
      unverifiable = block_response([finding_json(%{"quoted_snippet" => "a misremembered line"})])
      requoted = block_response([finding_json(%{"quoted_snippet" => "another wrong line"})])
      put_sequence_responses!([unverifiable, unverifiable, requoted])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, %{failures: [failure]}}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert failure.finding.quoted_snippet == "another wrong line"
      assert_received {:review_agent_sequence_call, 3, _prompt, _opts}
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate keeps the original unverifiable findings when the re-quote turn fails" do
    test_root = unique_tmp("symphony-elixir-review-agent-requote-failed")

    try do
      repo = git_repo_with_change!(test_root)
      unverifiable = block_response([finding_json(%{"quoted_snippet" => "a misremembered line"})])
      put_sequence_responses!([unverifiable, unverifiable, {:error, {:turn_failed, "max_iterations reached"}}])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, %{failures: [failure]}}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert failure.finding.quoted_snippet == "a misremembered line"
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  # An unreachable model API is the reviewer being unavailable: never inconclusive, never a
  # failed review, whichever turn it hits.
  test "evaluate reports an unreachable model API from the review, self-check or re-quote turn as it is" do
    test_root = unique_tmp("symphony-elixir-review-agent-api-unreachable")
    unreachable = {:error, {:model_api_unreachable, %{provider: "anthropic", source: :api_unreachable, error: "ENOTFOUND"}}}

    try do
      repo = git_repo_with_change!(test_root)
      unverifiable = block_response([finding_json(%{"quoted_snippet" => "a misremembered line"})])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      review = [unreachable]
      self_check = [block_response([finding_json()]), unreachable]
      requote = [unverifiable, unverifiable, unreachable]

      for responses <- [review, self_check, requote] do
        put_sequence_responses!(responses)

        result = ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)
        assert result == unreachable
        # The unreachable turn is the last one taken.
        assert Application.fetch_env!(:symphony_elixir, :review_agent_sequence_count) == length(responses)
      end
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate does not re-quote a verdict that gave no findings" do
    test_root = unique_tmp("symphony-elixir-review-agent-requote-no-findings")

    try do
      repo = git_repo_with_change!(test_root)
      comments_only = ~s({"verdict":"request_changes","comments":["Consider a regression test."]})
      put_sequence_responses!([comments_only, comments_only])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, payload}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert %{failures: [], comments: ["Consider a regression test."]} = payload
      assert_received {:review_agent_sequence_call, 2, _prompt, _opts}
      refute_received {:review_agent_sequence_call, 3, _prompt, _opts}
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate downgrades a block to inconclusive when self-check retracts all findings" do
    test_root = unique_tmp("symphony-elixir-review-agent-self-check-empty")

    try do
      repo = git_repo_with_change!(test_root)
      put_sequence_responses!([block_response([finding_json()]), block_response([])])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:error, {:review_agent_inconclusive, :self_check_retracted_all_findings}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate downgrades to inconclusive when self-check hits its iteration limit" do
    test_root = unique_tmp("symphony-elixir-review-agent-self-check-max")

    try do
      repo = git_repo_with_change!(test_root)
      put_sequence_responses!([block_response([finding_json()]), {:error, {:turn_failed, "max_iterations reached"}}])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:error, {:review_agent_inconclusive, {:self_check_max_iterations, {:turn_failed, "max_iterations reached"}}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate classifies reviewer turn-budget exhaustion as inconclusive without partial thought reason" do
    test_root = unique_tmp("symphony-elixir-review-agent-max-iterations")

    try do
      repo = git_repo_with_change!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      review_opts = [review_agent_module: MaxIterationsWithPartialReviewer]

      assert {:error, {:review_agent_inconclusive, reason}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_opts)

      assert {:max_iterations, {:turn_failed, "max_iterations reached"}} = reason

      refute inspect({:max_iterations, {:turn_failed, "max_iterations reached"}}) =~ "partial reviewer thought"
    after
      File.rm_rf(test_root)
    end
  end

  test "evaluate prefers streamed reviewer verdict over invalid primary result text" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-agent-streaming-primary-error-#{System.unique_integer([:positive])}"
      )

    try do
      repo = git_repo!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      issue = %Issue{
        id: "issue-review-streaming-primary-error",
        identifier: "MT-STREAM-PRIMARY",
        title: "Stream review verdict despite primary error",
        description: "Review result is available through streamed deltas",
        state: "In Progress"
      }

      review_opts = [review_agent_module: RuntimeTupleWithStreamingReviewer]

      assert {:ok, %{verdict: :approve, comments: []}} =
               ReviewAgent.evaluate(issue, repo, Config.settings!(), review_opts)
    after
      File.rm_rf(test_root)
    end
  end

  test "evaluate surfaces reviewer runtime tuple when no verdict text is available" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-agent-runtime-tuple-#{System.unique_integer([:positive])}"
      )

    try do
      repo = git_repo!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      issue = %Issue{
        id: "issue-review-runtime-tuple",
        identifier: "MT-RUNTIME-TUPLE",
        title: "Review runtime tuple",
        description: "Review result is a runtime error tuple",
        state: "In Progress"
      }

      assert {:error, {:review_agent_runtime_error, "{:error, {:turn_failed, reason}}"}} =
               ReviewAgent.evaluate(issue, repo, Config.settings!(), review_agent_module: RuntimeTupleReviewer)
    after
      File.rm_rf(test_root)
    end
  end

  defp git_repo!(test_root) do
    repo = Path.join(test_root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "# review stream\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    repo
  end

  defp git_repo_with_change!(test_root) do
    repo = git_repo!(test_root)
    File.write!(Path.join(repo, "feature.txt"), "grounded evidence line\n")
    git!(repo, ["add", "feature.txt"])
    git!(repo, ["commit", "-m", "feat: add grounded evidence"])
    repo
  end

  defp git_repo_with_file_change!(test_root, original, modified) do
    repo = git_repo!(test_root)
    File.write!(Path.join(repo, "feature.txt"), original)
    git!(repo, ["add", "feature.txt"])
    git!(repo, ["commit", "-m", "add feature"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    File.write!(Path.join(repo, "feature.txt"), modified)
    git!(repo, ["commit", "-am", "change feature"])
    repo
  end

  defp numbered_lines(range), do: Enum.map_join(range, "", &"line #{&1}\n")

  defp changed_line(text, number), do: String.replace(text, "line #{number}\n", "changed line #{number}\n")

  defp git_repo_with_origin_head_change!(test_root, branch) do
    repo = Path.join(test_root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", branch])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "# review stream\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["update-ref", "refs/remotes/origin/#{branch}", "HEAD"])
    git!(repo, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/#{branch}"])
    File.write!(Path.join(repo, "feature.txt"), "grounded evidence line\n")
    git!(repo, ["add", "feature.txt"])
    git!(repo, ["commit", "-m", "feat: add grounded evidence"])
    repo
  end

  defp source_for_repo!(repo) do
    assert {:ok, source} = Context.build(issue(), repo, "origin/main..HEAD", [], git_fun(repo))
    source
  end

  defp issue do
    %Issue{
      id: "issue-review-evidence",
      identifier: "MT-EVIDENCE",
      title: "Review evidence",
      description: "Reviewer findings need quoted evidence.",
      state: "In Progress"
    }
  end

  defp finding(quoted_snippet \\ "grounded evidence line", file \\ "feature.txt") do
    %{
      summary: "Handle remote guides.",
      file: file,
      line_range: {1, 1},
      quoted_snippet: quoted_snippet,
      suggested_fix: "Keep the evidence-backed change."
    }
  end

  defp finding_json(overrides \\ %{}) do
    Map.merge(
      %{
        "summary" => "Handle remote guides.",
        "file" => "feature.txt",
        "line_range" => [1, 1],
        "quoted_snippet" => "grounded evidence line",
        "suggested_fix" => "Keep the evidence-backed change."
      },
      overrides
    )
  end

  defp block_response(findings) do
    Jason.encode!(%{
      "verdict" => "block",
      "findings" => findings,
      "reason" => "Unsafe to continue."
    })
  end

  defp put_sequence_responses!(responses) do
    Application.put_env(:symphony_elixir, :review_agent_sequence_parent, self())
    Application.put_env(:symphony_elixir, :review_agent_sequence_count, 0)
    Application.put_env(:symphony_elixir, :review_agent_sequence_responses, responses)
  end

  defp clear_sequence_responses! do
    Application.delete_env(:symphony_elixir, :review_agent_sequence_parent)
    Application.delete_env(:symphony_elixir, :review_agent_sequence_count)
    Application.delete_env(:symphony_elixir, :review_agent_sequence_responses)
  end

  defp unique_tmp(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp git_fun(repo) do
    fn args ->
      case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, {:git_failed, status, output}}
      end
    end
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
