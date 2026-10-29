defmodule SymphonyElixir.ReviewAgentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.ReviewAgent
  alias SymphonyElixir.ReviewAgent.Context
  alias SymphonyElixir.TestSupport.Snapshot

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

  # Streams what a Claude reviewer streams: its session, a tool heartbeat, then its verdict.
  defmodule ClaudeStreamReviewer do
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(_session, _prompt, _issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)
      on_message.({:session_started, "sess-reviewer"})
      on_message.({:tool_progress, "Read"})
      {:ok, %{result: ~s({"verdict":"approve","comments":[]})}}
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
        {:tool_calls, calls, final} -> call_review_verdict(parent, count, calls, final, opts)
        {:error, reason} -> {:error, reason}
        response when is_binary(response) -> {:ok, %{result: response}}
      end
    end

    # The turn calls the `review_verdict` tool the way an agent's tool call reaches it, then ends
    # with `final`: its text, or a turn error.
    defp call_review_verdict(parent, count, calls, final, opts) do
      for args <- calls do
        response = DynamicTool.execute("review_verdict", args, Keyword.take(opts, [:tool_scope, :review_verdict_sink]))
        send(parent, {:review_agent_tool_response, count, Jason.decode!(response["output"])})
      end

      case final do
        {:error, reason} -> {:error, reason}
        text when is_binary(text) -> {:ok, %{result: text}}
      end
    end

    def stop_session(_session), do: :ok
  end

  # Records a verdict as its session stops, after the turn's verdict was read.
  defmodule LateVerdictReviewer do
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(_session, _prompt, _issue, _opts), do: {:ok, %{result: ~s({"verdict":"approve","comments":["first review"]})}}

    def stop_session(%{opts: opts}) do
      send(opts[:review_verdict_sink], {:review_verdict, %{verdict: :block, comments: [], reason: "late"}})
      :ok
    end
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

    test "keeps a block whose quote cannot be placed, with the finding as an unanchored comment" do
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

        assert {:ok, %{verdict: :block, findings: [], reason: "Unsafe to continue.", comments: [comment]}} =
                 ReviewAgent.validate_findings(result, source)

        assert comment ==
                 "[could not be placed] Handle remote guides. (feature.txt:1-1) Suggested fix: Keep the evidence-backed change."
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects a finding whose file is outside the diff and adjacent context" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-missing-file")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)

        result = %{verdict: :request_changes, comments: [], findings: [finding("grounded evidence line", "other.txt")]}

        assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, payload}}} =
                 ReviewAgent.validate_findings(result, source)

        assert %{failures: [%{reason: {:file_not_in_review_context, "other.txt"}}]} = payload
      after
        File.rm_rf(test_root)
      end
    end

    test "verifies a finding on a file the diff did not change but that exists at the reviewed head" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-unchanged-file")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)
        result = %{verdict: :request_changes, comments: [], findings: [finding("# review stream", "README.md")]}

        assert {:ok, %{verdict: :request_changes, findings: [%{file: "README.md", line_range: {1, 1}}]}} =
                 ReviewAgent.validate_findings(result, source)

        mismatch = %{result | findings: [finding("not in the readme", "README.md")]}

        assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, payload}}} =
                 ReviewAgent.validate_findings(mismatch, source)

        assert %{failures: [%{reason: :quoted_snippet_not_found}]} = payload
      after
        File.rm_rf(test_root)
      end
    end

    test "keeps a finding on a missing file as an unanchored comment and the verdict with the rest" do
      test_root = unique_tmp("symphony-elixir-review-agent-validate-partial")
      repo = git_repo_with_change!(test_root)

      try do
        source = source_for_repo!(repo)

        result = %{
          verdict: :request_changes,
          comments: [],
          findings: [finding("grounded evidence line", "missing.txt"), finding("# review stream", "README.md")]
        }

        assert {:ok, %{verdict: :request_changes, findings: [%{file: "README.md"}], comments: [grounded, unplaced]}} =
                 ReviewAgent.validate_findings(result, source)

        assert grounded =~ "(README.md:1-1)"
        assert unplaced == "[could not be placed] Handle remote guides. (missing.txt:1-1) Suggested fix: Keep the evidence-backed change."
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
        result = %{verdict: :request_changes, comments: [], findings: [finding]}

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
        result = %{verdict: :request_changes, comments: [], findings: [finding("@@ -0,0 +1 @@")]}

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
        result = %{verdict: :request_changes, comments: [], findings: [%{finding("not here") | line_range: {50, 51}}]}

        assert {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, %{failures: [failure]}}}} =
                 ReviewAgent.validate_findings(result, source)

        assert failure.reason == {:line_range_not_found, "feature.txt", {50, 51}}
      after
        File.rm_rf(test_root)
      end
    end

    test "keeps a block's own comments when it gave no findings" do
      result = %{verdict: :block, comments: ["Unsafe migration."], findings: [], reason: "Unsafe."}

      assert {:ok, ^result} = ReviewAgent.validate_findings(result, %{})
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

  test "evaluate forwards the reviewer's streamed events to the orchestrator as an implementation run does" do
    test_root = unique_tmp("symphony-elixir-review-agent-forward")

    try do
      repo = git_repo_with_change!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "claude", command: "claude"}
      )

      issue = %Issue{id: "issue-review-forward", identifier: "MT-FORWARD", title: "Forward", description: "Review it", state: "Code Review"}
      on_message = SymphonyElixir.AgentRunner.codex_message_handler(self(), issue)

      opts = [review_agent_module: ClaudeStreamReviewer, on_message: on_message]
      assert {:ok, %{verdict: :approve}} = ReviewAgent.evaluate(issue, repo, Config.settings!(), opts)

      assert_received {:codex_worker_update, "issue-review-forward", %{event: :session_started, session_id: "sess-reviewer", timestamp: %DateTime{}}}
      assert_received {:codex_worker_update, "issue-review-forward", %{event: :tool_progress, timestamp: %DateTime{}}}
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

  test "evaluate prompt reviews code quality and bugs, and the change against the ticket's acceptance criteria and scope" do
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
      assert prompt =~ "This is the pull request's Code Review, so also judge the change against the ticket"
      assert prompt =~ "You are the reviewer agent in Symphony's Code Review of a pull request."
      refute prompt =~ "Do not judge whether the diff meets the ticket's acceptance criteria"
      refute prompt =~ "executor"
      refute prompt =~ "Workflow review criteria"
      refute prompt =~ "Executor workflow"
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "the Code Review prompt carries the risk rules' findings in plain words, and the verdict returns their reasons" do
    test_root = unique_tmp("symphony-elixir-review-agent-rule-findings")

    try do
      repo = git_repo_with_change!(test_root)
      put_sequence_responses!([~s({"verdict":"approve","comments":[],"reason":"weighed the size"})])

      write_workflow_file!(Workflow.workflow_file_path(), review_agent: %{enabled: true, kind: "codex", command: "codex app-server"})

      size = %{rule: :size, detail: "adds 300, changes 50, removes 2,100 lines outside docs and tests: 2,450 in all, over the limit of 1,500"}
      label = %{rule: :label, detail: "the issue is labelled `needs-human`"}

      check = fn source ->
        send(self(), {:rule_check, source})
        [label, size]
      end

      opts = [review_agent_module: SequenceReviewer, escalation_rules: check]

      assert {:ok, %{verdict: :approve, escalation_reasons: [^label, ^size]}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), opts)

      # The check reads the diff context the reviewer judges, before the reviewer starts.
      assert_received {:rule_check, %{changed_file_inventory: [%{path: "feature.txt"} | _]}}
      assert_receive {:review_agent_sequence_call, 1, prompt, _opts}
      assert prompt =~ "What Symphony's risk rules found in this change."
      assert prompt =~ "say in your verdict's `reason` how it weighed"
      assert prompt =~ "- Size: adds 300, changes 50, removes 2,100 lines outside docs and tests"
      refute prompt =~ "needs-human"
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "the prompt says nothing about rules when none matched" do
    test_root = unique_tmp("symphony-elixir-review-agent-no-rule-findings")

    try do
      repo = git_repo_with_change!(test_root)
      put_sequence_responses!([~s({"verdict":"approve","comments":[]})])

      write_workflow_file!(Workflow.workflow_file_path(), review_agent: %{enabled: true, kind: "codex", command: "codex app-server"})

      opts = [review_agent_module: SequenceReviewer, escalation_rules: fn _source -> [] end]

      assert {:ok, %{verdict: :approve, escalation_reasons: []}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), opts)

      assert_receive {:review_agent_sequence_call, 1, prompt, _opts}
      refute prompt =~ "risk rules"
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  describe "recorded decisions" do
    # TP-892: a person deferred the legacy partials to TP-891, and the reviewer flagged them anyway.
    defp decided_issue do
      decision =
        SymphonyElixir.Decisions.entry(
          "comment-1",
          ~D[2026-10-13],
          "Keep the legacy prompt partials",
          "Remove the legacy prompt partials here, or leave them for TP-891?",
          "Defer to TP-891: don't make that change."
        )

      {:ok, description} = SymphonyElixir.Decisions.put("Reviewer findings need quoted evidence.", [decision])
      # Its own ticket: the store keeps a ticket's decisions once they are recorded.
      %{issue() | id: "issue-review-decided", description: description}
    end

    defp decided_finding(summary, decision) do
      %{summary: summary, file: "feature.txt", line_range: {1, 1}, quoted_snippet: "grounded evidence line", suggested_fix: "Remove it."}
      |> then(&if(decision, do: Map.put(&1, :decision, decision), else: &1))
    end

    test "the Code Review prompt carries the ticket's recorded decisions and the rule that a finding against one is no finding" do
      test_root = unique_tmp("symphony-elixir-review-agent-decisions-prompt")

      try do
        repo = git_repo_with_change!(test_root)
        put_sequence_responses!([~s({"verdict":"approve","comments":[]})])
        write_workflow_file!(Workflow.workflow_file_path(), review_agent: %{enabled: true, kind: "codex", command: "codex app-server"})

        opts = [review_agent_module: SequenceReviewer]
        assert {:ok, %{verdict: :approve}} = ReviewAgent.evaluate(decided_issue(), repo, Config.settings!(), opts)

        assert_receive {:review_agent_sequence_call, 1, prompt, _opts}
        [_intro, issue_part] = String.split(prompt, "Issue (context for what the diff is for):\n", parts: 2)
        [issue_part, _criteria] = String.split(issue_part, "Review criteria.", parts: 2)

        Snapshot.assert_snapshot!(Path.join("review_agent", "decisions_prompt.md"), issue_part)
      after
        clear_sequence_responses!()
        File.rm_rf(test_root)
      end
    end

    # Answers the description read with the node's description and sends the write back.
    defmodule RulingTracker do
      def fetch_issue_description(_issue_id), do: {:ok, "Reviewer findings need quoted evidence."}

      def update_issue_description(issue_id, description) do
        send(self(), {:description_written, issue_id, description})
        :ok
      end
    end

    test "TP-892's 05:48 ruling, given in a plain comment, reaches the Code Review prompt" do
      test_root = unique_tmp("symphony-elixir-review-agent-ruling-prompt")

      try do
        ruling = "Decision: don't make that change. The legacy prompt partials stay for TP-891, which removes them."

        node = %{
          "id" => issue().id,
          "description" => "Reviewer findings need quoted evidence.",
          "comments" => %{
            "nodes" => [
              %{"id" => "workpad", "body" => "## Symphony Workpad\n\nRemoving the legacy prompt partials.", "createdAt" => "2026-10-13T05:30:00Z", "parent" => nil},
              %{"id" => "comment-0548", "body" => ruling, "createdAt" => "2026-10-13T05:48:00Z", "parent" => nil}
            ]
          }
        }

        assert :ok = SymphonyElixir.Decisions.sync(node, tracker: RulingTracker)
        assert_received {:description_written, _issue_id, description}
        assert [%{id: "D1"}] = SymphonyElixir.Decisions.recorded(description)

        repo = git_repo_with_change!(test_root)
        put_sequence_responses!([~s({"verdict":"approve","comments":[]})])
        write_workflow_file!(Workflow.workflow_file_path(), review_agent: %{enabled: true, kind: "codex", command: "codex app-server"})

        opts = [review_agent_module: SequenceReviewer]
        # The issue the reviewer gets has no section: the prompt reads the store, not Linear.
        assert {:ok, %{verdict: :approve}} = ReviewAgent.evaluate(issue(), repo, Config.settings!(), opts)

        assert_receive {:review_agent_sequence_call, 1, prompt, _opts}

        assert prompt =~
                 "D1: Ruling given in a comment. Answer: don't make that change. The legacy prompt partials stay for TP-891, which removes them. Scope: As answered."

        assert prompt =~ "A finding that contradicts a recorded decision is not a finding"
      after
        clear_sequence_responses!()
        File.rm_rf(test_root)
      end
    end

    test "a change request whose only findings name a recorded decision approves, keeping them as notes" do
      test_root = unique_tmp("symphony-elixir-review-agent-decisions-approve")

      try do
        repo = git_repo_with_change!(test_root)

        put_sequence_responses!([
          ~s({"verdict":"request_changes","findings":[{"summary":"The legacy partials are still here.","file":"feature.txt","line_range":[1,1],"quoted_snippet":"grounded evidence line","suggested_fix":"Remove them.","decision":" d1 "}]})
        ])

        write_workflow_file!(Workflow.workflow_file_path(), review_agent: %{enabled: true, kind: "codex", command: "codex app-server"})

        opts = [review_agent_module: SequenceReviewer]

        assert {:ok, %{verdict: :approve, findings: [], comments: [note]}} =
                 ReviewAgent.evaluate(decided_issue(), repo, Config.settings!(), opts)

        assert note =~ "Against decision D1, so a note, not a change request: The legacy partials are still here. (feature.txt:1-1)"
        # No self-check turn: nothing is left to check.
        assert_receive {:review_agent_sequence_call, 1, _prompt, _opts}
        refute_receive {:review_agent_sequence_call, 2, _prompt, _opts}
      after
        clear_sequence_responses!()
        File.rm_rf(test_root)
      end
    end

    test "honour_decisions/2 keeps a finding that names no recorded decision" do
      findings = [decided_finding("Decided.", "D1"), decided_finding("Unknown decision.", "D9"), decided_finding("Plain.", nil)]
      result = %{verdict: :request_changes, comments: ["raw"], findings: findings}

      honoured = ReviewAgent.honour_decisions(result, decided_issue())

      assert %{verdict: :request_changes, findings: [%{summary: "Unknown decision."}, %{summary: "Plain."}]} = honoured
      assert %{comments: comments} = honoured

      # The decided finding is dropped: what is left asks for changes.
      assert comments == ["Unknown decision. (feature.txt:1-1) Suggested fix: Remove it.", "Plain. (feature.txt:1-1) Suggested fix: Remove it."]
    end

    test "honour_decisions/2 leaves a verdict alone when no finding names a recorded decision" do
      result = %{verdict: :request_changes, comments: ["raw"], findings: [decided_finding("Plain.", nil)]}

      assert ReviewAgent.honour_decisions(result, decided_issue()) == result
      # Without a recorded decision, a finding that names one stays a finding.
      undecided = %{result | findings: [decided_finding("Decided.", "D1")]}
      assert ReviewAgent.honour_decisions(undecided, issue()) == undecided

      approved = %{verdict: :approve, comments: []}
      assert ReviewAgent.honour_decisions(approved, decided_issue()) == approved
    end

    test "a blank decision on a finding is no decision" do
      assert {:ok, %{findings: [finding]}} =
               ReviewAgent.parse_response(~s({"verdict":"request_changes","findings":[{"summary":"s","file":"f","line_range":[1,1],"quoted_snippet":"q","suggested_fix":"x","decision":" "}]}))

      refute Map.has_key?(finding, :decision)

      assert {:ok, %{findings: [finding]}} =
               ReviewAgent.parse_response(~s({"verdict":"request_changes","findings":[{"summary":"s","file":"f","line_range":[1,1],"quoted_snippet":"q","suggested_fix":"x","decision":3}]}))

      refute Map.has_key?(finding, :decision)
    end
  end

  test "evaluate gives the reviewer its run's temp folder as its $TMPDIR" do
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
      unverifiable = request_changes_response([bad_quote, outside, past_end])
      put_sequence_responses!([unverifiable, unverifiable, request_changes_response([finding_json()])])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert {:ok, %{verdict: :request_changes, findings: [finding]}} =
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
      assert requote_prompt =~ "(file does not exist at the reviewed head)"
      assert requote_prompt =~ "- feature.txt:40-41: Past the end."
      assert requote_prompt =~ "(no lines at this range in the diff or the changed file)"
      assert requote_prompt =~ "Previous JSON:"
      assert requote_prompt =~ "Call the `review_verdict` tool once with the corrected verdict"

      assert requote_prompt =~ ~r/your final message must be only the corrected JSON object, with no prose before or after it.\n\z/
    after
      clear_sequence_responses!()
      File.rm_rf(test_root)
    end
  end

  test "evaluate stays unverifiable when the re-quoted findings still do not match" do
    test_root = unique_tmp("symphony-elixir-review-agent-requote-still-bad")

    try do
      repo = git_repo_with_change!(test_root)
      unverifiable = request_changes_response([finding_json(%{"quoted_snippet" => "a misremembered line"})])
      requoted = request_changes_response([finding_json(%{"quoted_snippet" => "another wrong line"})])
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
      unverifiable = request_changes_response([finding_json(%{"quoted_snippet" => "a misremembered line"})])
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
      unverifiable = request_changes_response([finding_json(%{"quoted_snippet" => "a misremembered line"})])

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

  describe "a reviewer that ends in prose" do
    setup do
      test_root = unique_tmp("symphony-elixir-review-agent-json-nudge")
      repo = git_repo_with_change!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      on_exit(fn ->
        clear_sequence_responses!()
        File.rm_rf(test_root)
      end)

      %{repo: repo}
    end

    test "gets one JSON nudge in the same session and its verdict counts", %{repo: repo} do
      put_sequence_responses!(["The diff looks fine to me.", ~s({"verdict":"approve","comments":[]})])

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_receive :review_agent_sequence_session_started
      refute_receive :review_agent_sequence_session_started
      assert_receive {:review_agent_sequence_call, 2, nudge, nudge_opts}
      assert nudge =~ "Symphony could not read your verdict: the reply had no review_verdict call and no JSON object."
      assert nudge =~ "call the `review_verdict` tool once with it"
      assert nudge =~ ~s("verdict": "approve" | "request_changes" | "block")
      assert nudge_opts[:max_iterations] == 4
    end

    test "a prose self-check reply gets one JSON nudge and its findings stand", %{repo: repo} do
      readme = finding_json(%{"file" => "README.md", "quoted_snippet" => "# review stream", "summary" => "Missed file."})
      response = block_response([readme])
      put_sequence_responses!([response, "The finding holds, so I kept it.", response])

      assert {:error, {:review_agent_blocked, %{findings: [%{file: "README.md"}]}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_receive {:review_agent_sequence_call, 2, self_check_prompt, _opts}
      assert self_check_prompt =~ ~r/your final message must be only the corrected JSON object, with no prose before or after it.\n\z/
      assert_receive {:review_agent_sequence_call, 3, nudge, nudge_opts}
      assert nudge =~ "Symphony could not read your verdict"
      assert nudge_opts[:max_iterations] == 4
    end

    test "a prose re-quote reply gets one JSON nudge", %{repo: repo} do
      unverifiable = request_changes_response([finding_json(%{"quoted_snippet" => "a misremembered line"})])
      put_sequence_responses!([unverifiable, unverifiable, "The finding holds, so I kept it.", request_changes_response([finding_json()])])

      assert {:ok, %{verdict: :request_changes, findings: [%{quoted_snippet: "grounded evidence line"}]}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_receive {:review_agent_sequence_call, 4, nudge, _opts}
      assert nudge =~ "Symphony could not read your verdict: the reply had no review_verdict call and no JSON object."
    end

    test "a self-check that stays prose after the nudge is inconclusive", %{repo: repo} do
      put_sequence_responses!([block_response([finding_json()]), "Prose.", "Still prose."])

      assert {:error, {:review_agent_inconclusive, {:malformed_review_agent_response, :no_json_object}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      refute_receive {:review_agent_sequence_call, 4, _prompt, _opts}
    end

    test "stays inconclusive when the nudge is prose too", %{repo: repo} do
      put_sequence_responses!(["Prose.", "Still prose."])

      assert {:error, {:review_agent_inconclusive, {:malformed_review_agent_response, :no_json_object}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      refute_receive {:review_agent_sequence_call, 3, _prompt, _opts}
    end

    test "reports an unreachable model API on the nudge as unreachable", %{repo: repo} do
      put_sequence_responses!(["Prose.", {:error, {:model_api_unreachable, %{reason: :econnrefused}}}])

      assert {:error, {:model_api_unreachable, %{reason: :econnrefused}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)
    end
  end

  describe "the review_verdict tool" do
    setup do
      test_root = unique_tmp("symphony-elixir-review-agent-verdict-tool")
      repo = git_repo_with_change!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      on_exit(fn ->
        clear_sequence_responses!()
        File.rm_rf(test_root)
      end)

      %{repo: repo}
    end

    test "a verdict recorded with the tool is the verdict, whatever the final message says", %{repo: repo} do
      put_sequence_responses!([{:tool_calls, [%{"verdict" => "approve", "comments" => ["Clean."]}], "Done: see the tool call."}])

      assert {:ok, %{verdict: :approve, comments: ["Clean."]}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_received {:review_agent_sequence_session_opts, session_opts}
      assert session_opts[:review_verdict_sink] == self()
      assert session_opts[:tool_scope] == :read_only
      assert_received {:review_agent_sequence_call, 1, prompt, turn_opts}
      assert turn_opts[:review_verdict_sink] == self()
      assert prompt =~ "call the `review_verdict` tool once with your verdict, then end your turn"
      assert Application.fetch_env!(:symphony_elixir, :review_agent_sequence_count) == 1
    end

    test "the tool refuses a verdict it cannot read, and the corrected call in the same turn counts", %{repo: repo} do
      put_sequence_responses!([{:tool_calls, [%{"verdict" => "looks good"}, %{"verdict" => "approve"}], ""}])

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_received {:review_agent_tool_response, 1, %{"error" => %{"code" => "invalid_review_verdict"}}}
      assert_received {:review_agent_tool_response, 1, %{"recorded" => true}}
      assert Application.fetch_env!(:symphony_elixir, :review_agent_sequence_count) == 1
    end

    test "the last verdict a turn recorded wins", %{repo: repo} do
      calls = [%{"verdict" => "approve", "comments" => ["first"]}, %{"verdict" => "approve", "comments" => ["second"]}]
      put_sequence_responses!([{:tool_calls, calls, ""}])

      assert {:ok, %{verdict: :approve, comments: ["second"]}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)
    end

    test "a verdict recorded after the last turn's read does not reach the next review", %{repo: repo} do
      assert {:ok, %{verdict: :approve, comments: ["first review"]}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: LateVerdictReviewer)

      refute_received {:review_verdict, _verdict}
    end

    test "a verdict recorded before the turn failed still counts", %{repo: repo} do
      put_sequence_responses!([{:tool_calls, [%{"verdict" => "approve"}], {:error, {:turn_failed, "max_iterations reached"}}}])

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)
    end

    test "the self-check reads its corrected verdict from the tool too", %{repo: repo} do
      response = request_changes_response([finding_json()])
      put_sequence_responses!([response, {:tool_calls, [%{"verdict" => "request_changes", "findings" => [finding_json()]}], "Kept it."}])

      assert {:ok, %{verdict: :request_changes, findings: [%{file: "feature.txt"}]}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_received {:review_agent_sequence_call, 2, self_check_prompt, _opts}
      assert self_check_prompt =~ "Call the `review_verdict` tool once with the corrected verdict"
    end
  end

  # TP-1120: each of the slips that cost a Code Review run on 2026-10-19/20 is read in the same
  # session, and only the repair turn is spent on it.
  describe "a formatting slip costs no second run" do
    setup do
      test_root = unique_tmp("symphony-elixir-review-agent-slips")

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      on_exit(fn ->
        clear_sequence_responses!()
        File.rm_rf(test_root)
      end)

      %{test_root: test_root}
    end

    test "a verdict word in another case", %{test_root: test_root} do
      repo = git_repo_with_change!(test_root)
      put_sequence_responses!([~s({"verdict":"Approved","comments":[]})])

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_turns(1)
    end

    test "a line range written as a span of text", %{test_root: test_root} do
      original = numbered_lines(1..40)
      repo = git_repo_with_file_change!(test_root, original, changed_line(original, 13))

      finding =
        finding_json(%{"line_range" => "12-15", "quoted_snippet" => "line 12\nchanged line 13\nline 14\nline 15", "summary" => "Line 13 changed."})

      response = request_changes_response([finding])
      put_sequence_responses!([response, response])

      assert {:ok, %{verdict: :request_changes, findings: [%{line_range: {12, 15}}]}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      # The review turn and its self-check.
      assert_turns(2)
    end

    test "a prose answer", %{test_root: test_root} do
      repo = git_repo_with_change!(test_root)
      put_sequence_responses!(["I reviewed it and it is fine.", ~s({"verdict":"approve"})])

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      # The review turn and the repair turn.
      assert_turns(2)
    end

    test "a paraphrased snippet", %{test_root: test_root} do
      repo = git_repo_with_change!(test_root)
      paraphrased = finding_json(%{"quoted_snippet" => "the grounded line of evidence", "summary" => "Paraphrased."})
      response = request_changes_response([finding_json(), paraphrased])
      put_sequence_responses!([response, response])

      assert {:ok, %{verdict: :request_changes, findings: [%{summary: "Handle remote guides."}], comments: [_grounded, unplaced]}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert unplaced =~ "[could not be placed] Paraphrased. (feature.txt:1-1)"
      # The review turn and its self-check: no re-quote turn.
      assert_turns(2)
    end

    test "a block whose only quote is paraphrased stands", %{test_root: test_root} do
      repo = git_repo_with_change!(test_root)
      response = block_response([finding_json(%{"quoted_snippet" => "the grounded line of evidence"})])
      put_sequence_responses!([response, response])

      assert {:error, {:review_agent_blocked, %{reason: "Unsafe to continue.", findings: [], comments: ["[could not be placed] " <> _rest]}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_turns(2)
    end
  end

  describe "the repair turn" do
    setup do
      test_root = unique_tmp("symphony-elixir-review-agent-repair")
      repo = git_repo_with_change!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      on_exit(fn ->
        clear_sequence_responses!()
        File.rm_rf(test_root)
      end)

      %{repo: repo}
    end

    test "carries the parser's error and the contract, and its verdict counts", %{repo: repo} do
      put_sequence_responses!([~s({"verdict":"looks good"}), ~s({"verdict":"approve"})])

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_received {:review_agent_sequence_call, 2, repair, _opts}
      assert repair =~ "Symphony could not read your verdict: `verdict` must be one of approve, request_changes or block."
      assert repair =~ "Do not review again."
      assert repair =~ ~s("line_range": [1, 2])
      assert_turns(2)
    end

    test "reads a verdict the repair turn records with the tool", %{repo: repo} do
      put_sequence_responses!([~s({"verdict":"approve","findings":[{"summary":"x"}]}), {:tool_calls, [%{"verdict" => "approve"}], ""}])

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_received {:review_agent_sequence_call, 2, repair, _opts}
      assert repair =~ "each finding needs a non-empty `file`."
      assert_turns(2)
    end

    test "a verdict that fails even after it is the only path to inconclusive", %{repo: repo} do
      put_sequence_responses!([~s({"verdict":"looks good"}), ~s({"verdict":"still unsure"})])

      assert {:error, {:review_agent_inconclusive, {:malformed_review_agent_response, :invalid_verdict}}} =
               ReviewAgent.evaluate(issue(), repo, Config.settings!(), review_agent_module: SequenceReviewer)

      assert_turns(2)
      assert_received :review_agent_sequence_session_started
      refute_received :review_agent_sequence_session_started
    end
  end

  test "inconclusive_cause/1 labels each inconclusive cause" do
    {:error, decode_error} = Jason.decode("{")

    assert ReviewAgent.inconclusive_cause({:malformed_review_agent_response, :invalid_verdict}) == "invalid_verdict"
    assert ReviewAgent.inconclusive_cause({:malformed_review_agent_response, :no_json_object}) == "no_json_object"
    assert ReviewAgent.inconclusive_cause({:malformed_review_agent_response, {:invalid_json, decode_error}}) == "invalid_json"
    assert ReviewAgent.inconclusive_cause({:review_agent_unverifiable, %{failures: []}}) == "review_agent_unverifiable"
    assert ReviewAgent.inconclusive_cause({:max_iterations, {:turn_failed, "max_iterations"}}) == "max_iterations"
    assert ReviewAgent.inconclusive_cause(:self_check_retracted_all_findings) == "self_check_retracted_all_findings"
    assert ReviewAgent.inconclusive_cause("odd") == "other"
  end

  test "the assembled reviewer prompt ends with the JSON rule, after the project conventions" do
    test_root = unique_tmp("symphony-elixir-review-agent-contract-last")

    try do
      repo = git_repo_with_change!(test_root)
      File.write!(Path.join(repo, "CLAUDE.md"), "Project rule body\n")
      put_sequence_responses!([~s({"verdict":"approve","comments":[]})])

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      settings = Config.settings!()

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue(), repo, settings, review_agent_module: SequenceReviewer)

      assert_receive {:review_agent_sequence_call, 1, prompt, _opts}
      assert {:ok, assembled} = SymphonyElixir.ProjectGuides.append_to_prompt(prompt, repo, settings, :claude)

      [before_contract, contract] = String.split(assembled, "call the `review_verdict` tool once with your verdict")
      assert before_contract =~ "## Project conventions"
      assert before_contract =~ "Project rule body"
      refute contract =~ "## Project conventions"
      refute assembled =~ SymphonyElixir.ProjectGuides.output_contract_marker()
      assert String.trim_trailing(contract) =~ ~r/your final message must be only this JSON object, with no prose before or after it\.$/
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

  defp assert_turns(count) do
    assert Application.fetch_env!(:symphony_elixir, :review_agent_sequence_count) == count
  end

  defp request_changes_response(findings) do
    Jason.encode!(%{"verdict" => "request_changes", "findings" => findings})
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
