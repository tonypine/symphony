defmodule SymphonyElixir.AutoReviewGateTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AutoReview, QaAgent}

  @sha "feedface00112233445566778899aabbccddeeff"
  @repo_key "default"
  @workspace "/tmp/workspaces/TP-960"

  defmodule FakeQaAgent do
    def run(_job, _settings, _opts), do: Application.fetch_env!(:symphony_elixir, :gate_flow_qa_result)
  end

  defmodule FakeGateRunner do
    def request(job, opts) do
      send(Application.fetch_env!(:symphony_elixir, :gate_flow_recipient), {:gate_request, job, opts})
      Application.get_env(:symphony_elixir, :gate_flow_runner_result, :started)
    end
  end

  defmodule FakeContext do
    def build(_issue, _record, _sha, _settings, _opts) do
      {:ok,
       %{
         base_branch: "main",
         base_sha: "base0000112233445566778899aabbccddeeff00",
         merged_sha: "abcabc00112233445566778899aabbccddeeff00",
         diff: "diff --git a/lib/app.ex b/lib/app.ex\n+  def check, do: :ok\n",
         diff_truncated?: false,
         numstat: [%{path: "lib/app.ex", additions: 1, deletions: 0}],
         diff_summary: %{files: [%{path: "lib/app.ex", additions: 1, deletions: 0, added_lines: ["  def check, do: :ok"]}]},
         busy_files: [],
         overlaps: []
       }}
    end
  end

  defmodule FakeSession do
    def start_session(worktree, opts) do
      send(Application.fetch_env!(:symphony_elixir, :gate_flow_recipient), {:gate_session_started, worktree, opts})
      {:ok, %{worktree: worktree}}
    end

    def run_turn(_session, _prompt, _issue, opts) do
      Enum.each([%{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 900, "output_tokens" => 100, "total_tokens" => 1_000}}}], opts[:on_message])
      Application.get_env(:symphony_elixir, :gate_flow_turn_result, {:ok, %{result: answer("approve")}})
    end

    def stop_session(_session), do: :ok

    def answer(verdict) do
      Jason.encode!(%{
        verdict: verdict,
        summary: "The command exists and is documented.",
        criteria: [
          %{id: "C1", criterion: "Adds the command", status: "met", evidence: "lib/app.ex:3"},
          %{id: "C2", criterion: "Documents it", status: "met", evidence: "README.md:12"}
        ],
        follow_ups: [%{title: "Add a --json flag", detail: "not asked for here"}]
      })
    end
  end

  defmodule FailingTracker do
    def update_issue_state(_issue_id, _state), do: {:error, :linear_down}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true},
      auto_review: %{enabled: true, max_fix_attempts: 2}
    )

    root = Path.join(System.tmp_dir!(), "auto-review-gate-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    Application.put_env(:symphony_elixir, :gate_flow_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      for key <- [:gate_flow_recipient, :gate_flow_qa_result, :gate_flow_runner_result, :gate_flow_turn_result] do
        Application.delete_env(:symphony_elixir, key)
      end

      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    %{root: root}
  end

  defp settings(mode, root) do
    settings = Config.settings!()
    settings = put_in(settings.workspace.root, root)
    put_in(settings.auto_review.acceptance_gate.mode, mode)
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-gate-flow",
        identifier: "TP-960",
        title: "Add `app check`",
        description: "Adds a check command.\n\n## Acceptance\n\n- [ ] Adds the command\n- [ ] Documents it\n",
        state: "Auto Review",
        url: "https://linear.test/TP-960",
        labels: []
      },
      attrs
    )
  end

  defp put_record(attrs \\ %{}) do
    record =
      Map.merge(
        %{
          repo_key: @repo_key,
          issue_id: "issue-gate-flow",
          issue_identifier: "TP-960",
          pr_url: "https://github.com/example/repo/pull/960",
          workspace_path: @workspace,
          worker_host: nil,
          status: "green"
        },
        attrs
      )

    :ok = RunStore.put_ci_check(record)
    record
  end

  defp stored_record, do: Enum.find(RunStore.list_ci_checks(), &(&1.issue_id == "issue-gate-flow"))

  defp git_with_paths(paths) do
    fn
      ["merge-base", "origin/" <> _base, @sha], @workspace -> {"base123\n", 0}
      ["diff", "--name-only", "base123", @sha], @workspace -> {Enum.join(paths, "\n") <> "\n", 0}
      _args, _cwd -> {"", 0}
    end
  end

  defp qa_job(record, settings), do: %{issue: issue(), record: record, sha: @sha, pr_url: record.pr_url, settings: settings}

  defp qa_opts(paths, extra \\ []), do: [git: git_with_paths(paths), qa_agent: FakeQaAgent, gate_runner: FakeGateRunner] ++ extra

  defp qa_pass do
    step = %{name: "app check", status: "pass", details: "exit 0", evidence: []}

    {:ok,
     %{
       result: %{verdict: :pass, summary: "Works.", steps: [step], findings: []},
       tokens: QaAgent.empty_tokens()
     }}
  end

  defp gate_opts(root, extra \\ []) do
    Keyword.merge(
      [
        context: FakeContext,
        gate_agent_module: FakeSession,
        git: git_with_paths([]),
        leftover_processes: [table: fn -> {:ok, []} end],
        dir: Path.join(root, "audit")
      ],
      extra
    )
  end

  defp gate_job(record, settings, attrs \\ %{}) do
    Map.merge(%{issue: issue(), record: record, sha: @sha, settings: settings, qa: %{verdict: :pass}}, attrs)
  end

  defp green_poll(record, settings), do: AutoReview.on_green(issue(), record, %{commit_sha: @sha}, settings, gate_runner: FakeGateRunner)

  defp audit_events(root) do
    {:ok, events} = SymphonyElixir.AuditLog.query(event_type: "acceptance_gate_verdict", issue_id: "issue-gate-flow", dir: Path.join(root, "audit"))
    Enum.to_list(events)
  end

  describe "mode off" do
    test "QA moves the issue to In Review as before, and no gate is requested", %{root: root} do
      settings = settings("off", root)
      record = put_record()
      Application.put_env(:symphony_elixir, :gate_flow_qa_result, qa_pass())

      assert {:auto_review_qa, "issue-gate-flow", :pass, "In Review"} =
               AutoReview.run_qa(qa_job(record, settings), qa_opts(["lib/symphony_elixir/cli.ex"]))

      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}

      record = put_record(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review", qa_applied: true})

      assert {:auto_review_qa, "issue-gate-flow", :pass, "In Review"} =
               AutoReview.on_green(issue(), record, %{commit_sha: @sha}, settings, gate_runner: FakeGateRunner)

      refute_received {:gate_request, _job, _opts}
    end
  end

  describe "mode shadow" do
    test "a QA pass, skip or blocked asks for a gate pass instead of moving the issue", %{root: root} do
      settings = settings("shadow", root)
      record = put_record()
      Application.put_env(:symphony_elixir, :gate_flow_qa_result, qa_pass())

      assert {:gate_started, "issue-gate-flow", @sha} =
               AutoReview.run_qa(qa_job(record, settings),
                 git: git_with_paths(["lib/symphony_elixir/cli.ex"]),
                 qa_agent: FakeQaAgent,
                 gate_runner: FakeGateRunner,
                 tracker: SymphonyElixir.Tracker.Memory
               )

      assert_receive {:memory_tracker_comment, "issue-gate-flow", qa_report}
      assert qa_report =~ "## Symphony QA Report"
      assert_receive {:gate_request, %{sha: @sha, qa: %{verdict: :pass}, forced: false} = gate_job, gate_opts}
      assert gate_job.record.qa_verdict == "pass"
      assert gate_opts == [tracker: SymphonyElixir.Tracker.Memory]
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert %{qa_verdict: "pass", qa_applied: false} = stored_record()

      # A docs-only change skips QA and still goes through the gate.
      assert {:gate_started, "issue-gate-flow", @sha} =
               AutoReview.run_qa(qa_job(put_record(), settings), git: git_with_paths(["README.md"]), gate_runner: FakeGateRunner)

      assert_receive {:gate_request, %{qa: %{verdict: :skip}}, _opts}

      Application.put_env(:symphony_elixir, :gate_flow_qa_result, {:error, :port_exit, QaAgent.empty_tokens()})

      assert {:gate_started, "issue-gate-flow", @sha} =
               AutoReview.run_qa(qa_job(put_record(), settings), qa_opts(["lib/symphony_elixir/cli.ex"]))

      assert_receive {:gate_request, %{qa: %{verdict: :blocked, reason: "the QA agent could not finish: :port_exit"}}, _opts}
    end

    test "a QA fail goes back to In Progress without a gate pass", %{root: root} do
      settings = settings("shadow", root)
      record = put_record()

      Application.put_env(
        :symphony_elixir,
        :gate_flow_qa_result,
        {:ok, %{result: %{verdict: :fail, summary: "Broken.", steps: [], findings: ["exits 0 on a bad config"]}, tokens: QaAgent.empty_tokens()}}
      )

      assert {:auto_review_qa, "issue-gate-flow", :fail, "In Progress"} =
               AutoReview.run_qa(qa_job(record, settings), qa_opts(["lib/symphony_elixir/cli.ex"]))

      refute_received {:gate_request, _job, _opts}
    end

    test "reports what the gate runner answered", %{root: root} do
      settings = settings("shadow", root)
      record = put_record(%{qa_sha: @sha, qa_verdict: "blocked", qa_reason: "no simulator", qa_target_state: "In Review", qa_applied: false})

      for {reply, result} <- [
            running: {:gate_running, "issue-gate-flow"},
            busy: {:gate_queued, "issue-gate-flow"},
            usage_limited: {:gate_waiting, "issue-gate-flow", :usage_limited},
            error: {:gate_request_error, "issue-gate-flow", :gate_runner_unavailable}
          ] do
        reply = if reply == :error, do: {:error, :gate_runner_unavailable}, else: reply
        Application.put_env(:symphony_elixir, :gate_flow_runner_result, reply)
        assert ^result = green_poll(record, settings)
        assert_receive {:gate_request, %{qa: %{verdict: :blocked, reason: "no simulator"}}, _opts}
      end
    end

    test "a gate pass writes the advisory comment, one row per criterion, then moves the issue to In Review", %{root: root} do
      settings = settings("shadow", root)
      record = put_record(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review", qa_applied: false})

      assert {:auto_review_gate, "issue-gate-flow", "approve", "In Review"} = AutoReview.run_gate(gate_job(record, settings), gate_opts(root))

      assert_receive {:gate_session_started, _worktree, session_opts}
      assert session_opts[:tool_scope] == :read_only
      assert_receive {:memory_tracker_comment, "issue-gate-flow", body}
      assert body =~ "## Symphony Acceptance Gate"
      assert body =~ "This verdict is advisory"
      assert body =~ "**Verdict:** approve · **Agent verdict:** approve"
      assert body =~ "| Adds the command | met | lib/app.ex:3 |"
      assert body =~ "| Documents it | met | README.md:12 |"
      # The header, its separator and one row per acceptance criterion.
      assert body |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "| ")) == 2 + 2
      assert body =~ "- **Add a --json flag**: not asked for here"
      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}

      assert %{gate_sha: @sha, gate_verdict: "approve", gate_agent_verdict: "approve", qa_applied: true} = stored_record()
      assert [%{kind: "acceptance_gate", status: "gate_approve", tokens: %{total_tokens: 1_000}}] = RunStore.list_runs(@repo_key, :all)
    end

    test "a needs-human label escalates over the agent's approve, and both verdicts are recorded and audited", %{root: root} do
      settings = settings("shadow", root)
      record = put_record(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review"})
      job = gate_job(record, settings, %{issue: issue(%{labels: ["needs-human"]})})

      assert {:auto_review_gate, "issue-gate-flow", "escalate", "In Review"} = AutoReview.run_gate(job, gate_opts(root))

      assert %{gate_verdict: "escalate", gate_agent_verdict: "approve", gate_reasons: [%{rule: "label", detail: "the issue is labelled `needs-human`"}], gate_run_id: run_id} =
               stored_record()

      assert_receive {:memory_tracker_comment, "issue-gate-flow", body}
      assert body =~ "**Verdict:** escalate · **Agent verdict:** approve"
      assert body =~ "- `label`: the issue is labelled `needs-human`"

      assert [event] = audit_events(root)

      assert %{
               "event_type" => "acceptance_gate_verdict",
               "issue_id" => "issue-gate-flow",
               "issue_identifier" => "TP-960",
               "sha" => @sha,
               "mode" => "shadow",
               "verdict" => "escalate",
               "agent_verdict" => "approve",
               "reasons" => [%{"rule" => "label", "detail" => "the issue is labelled `needs-human`"}],
               "run_id" => ^run_id,
               "tokens" => %{"total_tokens" => 1_000}
             } = event
    end

    test "two inconclusive passes on the same SHA escalate with reason inconclusive", %{root: root} do
      settings = settings("shadow", root)
      Application.put_env(:symphony_elixir, :gate_flow_turn_result, {:ok, %{result: "no JSON here"}})
      put_record(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review"})

      assert {:gate_inconclusive, "issue-gate-flow", @sha} = AutoReview.run_gate(gate_job(stored_record(), settings), gate_opts(root))
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert %{gate_sha: @sha, gate_verdict: nil, gate_inconclusive: 1} = stored_record()
      assert audit_events(root) == []
      assert_receive {:memory_tracker_comment, "issue-gate-flow", body}
      assert body =~ "inconclusive (1 of 2)"

      # The next green poll finds no verdict for the SHA and asks for another pass.
      assert {:gate_started, "issue-gate-flow", @sha} = green_poll(stored_record(), settings)
      assert_receive {:gate_request, _job, _opts}

      assert {:auto_review_gate, "issue-gate-flow", "escalate", "In Review"} = AutoReview.run_gate(gate_job(stored_record(), settings), gate_opts(root))
      assert %{gate_verdict: "escalate", gate_agent_verdict: "inconclusive", gate_inconclusive: 2} = stored_record()
      assert [%{rule: "inconclusive"}] = stored_record().gate_reasons
      assert [%{"verdict" => "escalate", "reasons" => [%{"rule" => "inconclusive"}]}] = audit_events(root)
      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}
    end

    test "a repeat green poll on a judged SHA reapplies the verdict without a new run", %{root: root} do
      settings = settings("shadow", root)

      record =
        put_record(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review", gate_sha: @sha, gate_verdict: "approve"})

      assert {:auto_review_gate, "issue-gate-flow", "approve", "In Review"} =
               AutoReview.on_green(issue(), record, %{commit_sha: @sha}, settings, gate_runner: FakeGateRunner)

      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}
      refute_received {:gate_request, _job, _opts}
      assert RunStore.list_runs(@repo_key, :all) == []

      # A verdict for an older SHA doesn't count.
      record = put_record(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review", gate_sha: "older", gate_verdict: "approve"})
      assert {:gate_started, "issue-gate-flow", @sha} = green_poll(record, settings)
    end

    test "a failed move after the verdict is reported", %{root: root} do
      settings = settings("shadow", root)
      record = put_record(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review", gate_sha: @sha, gate_verdict: "approve"})

      log =
        capture_log(fn ->
          assert {:state_transition_error, "issue-gate-flow", :auto_review, :linear_down} =
                   AutoReview.on_green(issue(), record, %{commit_sha: @sha}, settings, tracker: FailingTracker)
        end)

      assert log =~ "Failed to move TP-960 to In Review after QA"
    end
  end
end
