defmodule SymphonyElixir.AutoReviewGateTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AcceptanceGate, AutoReview, CiPoller, PromptBuilder, QaAgent}
  alias SymphonyElixir.AcceptanceGate.Agreement

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

  defmodule FakeQaRunner do
    def request(job, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :gate_flow_recipient), {:qa_request, job})
      :started
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

  # The run store, except that marking a gate run fails.
  defmodule MarkFailingStore do
    defdelegate put_run(record), to: SymphonyElixir.RunStore
    defdelegate list_ci_checks(repo_key), to: SymphonyElixir.RunStore
    defdelegate update_ci_check(repo_key, issue_id, attrs), to: SymphonyElixir.RunStore

    def update_run(_repo_key, _run_id, %{moved_by_gate: _state}), do: {:error, :disk_full}
    def update_run(repo_key, run_id, attrs), do: SymphonyElixir.RunStore.update_run(repo_key, run_id, attrs)
  end

  defmodule FailingTracker do
    def update_issue_state(_issue_id, _state), do: {:error, :linear_down}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
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
      keys = ~w(gate_flow_recipient gate_flow_qa_result gate_flow_runner_result gate_flow_turn_result memory_tracker_issues)a

      for key <- keys do
        Application.delete_env(:symphony_elixir, key)
      end

      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    %{root: root}
  end

  # `AutoReview.run_qa/2` re-reads the repo's workflow before QA, so the mode goes in the file.
  defp settings(mode, root) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      workspace_root: root,
      ci: %{enabled: true},
      auto_review: %{enabled: true, max_fix_attempts: 2, acceptance_gate: %{mode: mode}}
    )

    Config.settings!()
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
        tmp_bases: [root],
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

    test "a verdict that comes after the issue left Auto Review or its PR moved on is kept but moves nothing", %{root: root} do
      settings = settings("shadow", root)

      for {issue_state, record_attrs, reason} <- [
            {"Merging", %{}, "the issue moved to Merging"},
            {"Auto Review", %{pr_state: "MERGED"}, "the PR is merged"},
            {"Auto Review", %{pr_state: "OPEN", last_observed_sha: "0123456789abcdef0123"}, "the PR head moved to `0123456789ab`"}
          ] do
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{state: issue_state})])
        record = put_record(Map.merge(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review"}, record_attrs))

        log =
          capture_log([level: :info], fn ->
            assert {:auto_review_gate_not_applied, "issue-gate-flow", "approve", ^reason} =
                     AutoReview.run_gate(gate_job(record, settings), gate_opts(root))
          end)

        assert log =~ "Acceptance gate outcome not applied: #{reason} issue_id=issue-gate-flow issue_identifier=TP-960 verdict=approve"
        assert_receive {:memory_tracker_comment, "issue-gate-flow", body}
        assert body =~ "## Symphony Acceptance Gate"
        refute_received {:memory_tracker_state_update, _issue_id, _state}
        assert %{gate_sha: @sha, gate_verdict: "approve"} = stored_record()
      end
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

    test "a pass whose agent can't reach the model API records nothing and waits for the hold, then runs again", %{root: root} do
      settings = settings("shadow", root)
      on_exit(fn -> RunStore.put_usage_limits(%{}) end)
      info = %{provider: "anthropic", scope: :all, window: nil, resets_at: nil, source: :api_unreachable, error: "ENOTFOUND"}
      Application.put_env(:symphony_elixir, :gate_flow_turn_result, {:error, {:model_api_unreachable, info}})
      put_record(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review"})
      test_pid = self()
      provider = Map.get(AcceptanceGate.usage_profile(settings), :provider, "anthropic")

      hold = fn held_info, identifier ->
        send(test_pid, {:usage_limit_hold, held_info, identifier})
        entry = %{provider: provider, scope: :all, reason: "model_api_unreachable", resume_at: DateTime.add(DateTime.utc_now(), 60)}
        :ok = RunStore.put_usage_limits(%{{provider, :all} => entry})
        {:ok, entry}
      end

      log =
        capture_log(fn ->
          assert {:gate_waiting, "issue-gate-flow", :model_api_unreachable} =
                   AutoReview.run_gate(gate_job(stored_record(), settings), gate_opts(root, usage_limit_hold: hold))
        end)

      assert_receive {:usage_limit_hold, ^info, "TP-960"}
      assert log =~ "Acceptance gate agent could not reach the model API (ENOTFOUND) for TP-960 sha=#{@sha}; no verdict"

      # No verdict, no inconclusive pass counted, no comment, no audit event, no move.
      record = stored_record()
      refute Map.get(record, :gate_verdict)
      refute Map.get(record, :gate_inconclusive)
      refute Map.get(record, :gate_sha)
      refute_received {:memory_tracker_comment, _issue_id, _body}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert audit_events(root) == []
      assert [%{status: "gate_unavailable", error: "model API unreachable (ENOTFOUND)"}] = Enum.filter(RunStore.list_runs(:all), &(&1.kind == "acceptance_gate"))

      # While the hold lasts the runner turns the request away; once it lifts, the pass runs again.
      assert :usage_limited = AcceptanceGate.Runner.request(gate_job(record, settings), [])
      :ok = RunStore.put_usage_limits(%{})
      assert {:gate_started, "issue-gate-flow", @sha} = green_poll(record, settings)
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

  describe "mode enforce" do
    defp rework_answer do
      Jason.encode!(%{
        verdict: "rework",
        summary: "The docs are missing.",
        criteria: [
          %{id: "C1", criterion: "Adds the command", status: "met", evidence: "lib/app.ex:3"},
          %{id: "C2", criterion: "Documents it", status: "unmet", evidence: "README.md unchanged"}
        ]
      })
    end

    # Drops the comments earlier passes posted, so the next assertion reads the latest one.
    defp flush_comments do
      receive do
        {:memory_tracker_comment, _issue_id, _body} -> flush_comments()
      after
        0 -> :ok
      end
    end

    defp judged(attrs \\ %{}), do: put_record(Map.merge(%{qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review", qa_applied: false}, attrs))

    test "an approve moves the issue to Merging, and the move isn't counted as a human approval", %{root: root} do
      settings = settings("enforce", root)

      # Without the mark on the gate run the issue stays in Auto Review, so no CI poll can read the
      # gate's own move as a human approval; the next green poll tries again.
      log =
        capture_log(fn ->
          assert {:state_transition_error, "issue-gate-flow", :acceptance_gate, :disk_full} =
                   AutoReview.run_gate(gate_job(judged(), settings), gate_opts(root, run_store: MarkFailingStore))
        end)

      assert log =~ "Acceptance gate left TP-960 in place: the gate run could not be marked before the move to Merging: :disk_full"
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert %{gate_target_state: "Merging", gate_applied: false} = stored_record()
      assert [unmarked] = RunStore.list_runs(@repo_key, :all)
      refute Map.has_key?(unmarked, :moved_by_gate)
      assert Agreement.observe(@repo_key, [issue()], [unmarked], [], tracker: SymphonyElixir.Tracker.Memory) == []

      assert {:auto_review_gate, "issue-gate-flow", "approve", "Merging"} = green_poll(stored_record(), settings)
      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "Merging"}
      assert [%{moved_by_gate: "Merging"}] = RunStore.list_runs(@repo_key, :all)
      flush_comments()

      assert {:auto_review_gate, "issue-gate-flow", "approve", "Merging"} = AutoReview.run_gate(gate_job(judged(), settings), gate_opts(root))

      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "Merging"}
      assert_receive {:memory_tracker_comment, "issue-gate-flow", body}
      assert body =~ "**Mode:** enforce. Symphony applies this verdict: the issue moves to Merging"
      assert body =~ "- not filed (:tracker_not_linear): **Add a --json flag**"

      assert %{gate_verdict: "approve", gate_target_state: "Merging", gate_applied: true, qa_fix_attempts: 0} = stored_record()
      assert %{qa_applied: true} = stored_record()
      assert %{moved_by_gate: "Merging"} = run = Enum.find(RunStore.list_runs(@repo_key, :all), &(&1.run_id == stored_record().gate_run_id))

      # The CI poller's agreement watch sees the issue in Merging and records no human decision.
      merging = issue(%{state: "Merging"})
      assert Agreement.observe(@repo_key, [merging], [run], [], tracker: SymphonyElixir.Tracker.Memory) == []

      assert Agreement.observe(@repo_key, [merging], [Map.delete(run, :moved_by_gate)], [], tracker: SymphonyElixir.Tracker.Memory, audit_dir: Path.join(root, "audit")) == [
               {"issue-gate-flow", "approve"}
             ]
    end

    test "a rework goes back to In Progress with the unmet criteria, sharing the fix count with QA fails", %{root: root} do
      settings = settings("enforce", root)
      Application.put_env(:symphony_elixir, :gate_flow_turn_result, {:ok, %{result: rework_answer()}})

      assert {:auto_review_gate, "issue-gate-flow", "rework", "In Progress"} = AutoReview.run_gate(gate_job(judged(), settings), gate_opts(root))

      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Progress"}
      assert %{qa_fix_attempts: 1, gate_target_state: "In Progress", gate_applied: true} = stored_record()
      assert [%{moved_by_gate: "In Progress"}] = RunStore.list_runs(@repo_key, :all)

      # The fix run gets the unmet criteria as continuation context, like a QA fail.
      failure = CiPoller.pending_qa_failure("issue-gate-flow")
      assert %{source: "acceptance_gate", commit_sha: @sha} = failure
      assert "Criterion unmet: Documents it (README.md unchanged)" in failure.findings

      prompt = PromptBuilder.build_prompt(issue(%{state: "In Progress"}), qa_failure: failure)
      assert prompt =~ "Auto Review acceptance gate rework:"
      assert prompt =~ "The acceptance gate judged commit #{@sha} against the ticket and sent it back"
      assert prompt =~ "- Criterion unmet: Documents it (README.md unchanged)"
      refute prompt =~ "Auto Review QA failure:"

      # The next QA pass keeps the count: only the gate's verdict ends the fix loop.
      Application.put_env(:symphony_elixir, :gate_flow_qa_result, qa_pass())
      assert {:gate_started, "issue-gate-flow", @sha} = AutoReview.run_qa(qa_job(stored_record(), settings), qa_opts(["lib/symphony_elixir/cli.ex"]))
      assert %{qa_fix_attempts: 1, qa_passed: true} = stored_record()

      # The rework past `max_fix_attempts` (2) escalates to In Review instead.
      record = judged(%{qa_fix_attempts: 2})
      flush_comments()

      assert {:auto_review_gate, "issue-gate-flow", "rework", "In Review"} = AutoReview.run_gate(gate_job(record, settings), gate_opts(root))
      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}
      assert_receive {:memory_tracker_comment, "issue-gate-flow", body}
      assert body =~ "The fix attempts are used up (2 of 2), so this rework goes to a person: the issue moves to In Review."
      assert %{qa_fix_attempts: 2, qa_failure: nil, gate_target_state: "In Review"} = stored_record()
    end

    test "a failed move is retried without counting, and a rework back without a commit counts again", %{root: root} do
      settings = settings("enforce", root)
      Application.put_env(:symphony_elixir, :gate_flow_turn_result, {:ok, %{result: rework_answer()}})

      log =
        capture_log(fn ->
          assert {:state_transition_error, "issue-gate-flow", :acceptance_gate, :linear_down} =
                   AutoReview.run_gate(gate_job(judged(), settings), gate_opts(root, tracker: FailingTracker))
        end)

      assert log =~ "Failed to move TP-960 to In Progress after the acceptance gate: :linear_down"
      assert %{qa_fix_attempts: 1, gate_target_state: "In Progress", gate_applied: false} = stored_record()

      assert {:auto_review_gate, "issue-gate-flow", "rework", "In Progress"} = green_poll(stored_record(), settings)
      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Progress"}
      assert %{qa_fix_attempts: 1, gate_applied: true} = stored_record()

      # Back in Auto Review on the same SHA: the fix run pushed nothing.
      assert {:auto_review_gate, "issue-gate-flow", "rework", "In Progress"} = green_poll(stored_record(), settings)
      assert %{qa_fix_attempts: 2, qa_failure: %{findings: [returned | _rest]}} = stored_record()
      assert returned =~ "The fix run ended without pushing a commit"
      refute_received {:gate_request, _job, _opts}

      # The third time is past the limit.
      assert {:auto_review_gate, "issue-gate-flow", "rework", "In Review"} = green_poll(stored_record(), settings)
    end

    test "an escalate moves the issue to In Review, and the comment opens with the reasons", %{root: root} do
      settings = settings("enforce", root)
      job = gate_job(judged(%{qa_fix_attempts: 1}), settings, %{issue: issue(%{labels: ["needs-human"]})})

      assert {:auto_review_gate, "issue-gate-flow", "escalate", "In Review"} = AutoReview.run_gate(job, gate_opts(root))

      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}
      assert_receive {:memory_tracker_comment, "issue-gate-flow", body}
      assert String.starts_with?(body, "## Symphony Acceptance Gate\n\n### Escalation reasons\n\n- `label`: the issue is labelled `needs-human`\n")
      assert body =~ "**Mode:** enforce. Symphony applies this verdict: the issue moves to In Review for a person to decide."
      assert %{qa_fix_attempts: 0, gate_applied: true} = stored_record()
      assert [run] = RunStore.list_runs(@repo_key, :all)
      refute Map.has_key?(run, :moved_by_gate)
    end

    test "an issue back in Auto Review after an infrastructure block gets a fresh QA pass before the gate", %{root: root} do
      settings = settings("enforce", root)
      crash = {:error, {:qa_agent_failed, :port_exit}, QaAgent.empty_tokens()}
      Application.put_env(:symphony_elixir, :gate_flow_qa_result, crash)

      assert {:gate_started, "issue-gate-flow", @sha} = AutoReview.run_qa(qa_job(put_record(), settings), qa_opts(["lib/symphony_elixir/cli.ex"]))
      assert_receive {:gate_request, %{qa: %{verdict: :blocked}} = job, _opts}
      assert %{qa_verdict: "blocked", qa_infra_blocked: true} = stored_record()

      # The gate escalates on the block, and the issue goes to In Review.
      assert {:auto_review_gate, "issue-gate-flow", "escalate", "In Review"} = AutoReview.run_gate(job, gate_opts(root))
      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}
      assert %{qa_applied: true, gate_sha: @sha, gate_verdict: "escalate"} = stored_record()

      # A person moves it back to Auto Review on the same head: QA runs again, the old verdicts go.
      poll_opts = [gate_runner: FakeGateRunner, qa_runner: FakeQaRunner]

      log =
        capture_log(fn ->
          assert {:qa_started, "issue-gate-flow", @sha} =
                   AutoReview.on_green(issue(), stored_record(), %{commit_sha: @sha}, settings, poll_opts)
        end)

      assert log =~ "QA pass runs again: TP-960 came back to Auto Review after an infrastructure block"
      assert_receive {:qa_request, %{sha: @sha, record: rerun_record}}
      refute_received {:gate_request, _job, _opts}
      assert %{qa_sha: nil, qa_verdict: nil, gate_sha: nil, gate_verdict: nil} = stored_record()

      # The fresh pass reaches the gate with its own verdict.
      Application.put_env(:symphony_elixir, :gate_flow_qa_result, qa_pass())
      assert {:gate_started, "issue-gate-flow", @sha} = AutoReview.run_qa(qa_job(rerun_record, settings), qa_opts(["lib/symphony_elixir/cli.ex"]))
      assert_receive {:gate_request, %{qa: %{verdict: :pass}}, _opts}
      assert %{qa_verdict: "pass", qa_infra_blocked: false} = stored_record()
    end

    test "the gate never moves a breakdown parent or a Final verification ticket", %{root: root} do
      settings = settings("enforce", root)
      job = gate_job(judged(), settings, %{issue: issue(%{title: "Final verification: Add `app check`"})})

      assert {:auto_review_gate, "issue-gate-flow", "approve", "In Review"} = AutoReview.run_gate(job, gate_opts(root))
      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}
      assert_receive {:memory_tracker_comment, "issue-gate-flow", body}
      assert body =~ "**Mode:** enforce, but the gate never moves a `breakdown` parent"
      refute_received {:memory_tracker_state_update, _issue_id, "Merging"}
    end

    test "a repository in enforce and one in shadow behave differently in the same process", %{root: root} do
      workflow = Workflow.workflow_file_path()

      repo = fn key, mode ->
        %{
          "name" => key,
          "path" => Path.dirname(workflow),
          "workflow" => Path.basename(workflow),
          "team" => "Test",
          "labels" => [key],
          "acceptance_gate" => %{"mode" => mode}
        }
      end

      write_workflow_file!(workflow,
        tracker_kind: "memory",
        pr_review_mode: "polling",
        workspace_root: root,
        ci: %{enabled: true},
        auto_review: %{enabled: true, max_fix_attempts: 2},
        repos: [repo.("app", "enforce"), repo.("web", "shadow")]
      )

      for {repo_key, target} <- [{"app", "Merging"}, {"web", "In Review"}] do
        issue_id = "issue-#{repo_key}"
        record = judged(%{repo_key: repo_key, issue_id: issue_id})
        job = gate_job(record, Config.settings_for_repo!(repo_key), %{issue: issue(%{id: issue_id})})

        assert {:auto_review_gate, ^issue_id, "approve", ^target} = AutoReview.run_gate(job, gate_opts(root))
        assert_receive {:memory_tracker_state_update, ^issue_id, ^target}
      end
    end

    test "switching the mode back stops the moves on the next poll, without a restart", %{root: root} do
      settings = settings("enforce", root)

      capture_log(fn ->
        assert {:state_transition_error, "issue-gate-flow", :acceptance_gate, :linear_down} =
                 AutoReview.run_gate(gate_job(judged(), settings), gate_opts(root, tracker: FailingTracker))
      end)

      assert %{gate_target_state: "Merging", gate_applied: false} = stored_record()

      # The workflow reload turns the gate to shadow: the next green poll moves the issue where QA sent it.
      settings = settings("shadow", root)
      assert {:auto_review_gate, "issue-gate-flow", "approve", "In Review"} = green_poll(stored_record(), settings)
      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}
      refute_received {:memory_tracker_state_update, _issue_id, "Merging"}

      # A pass requested in enforce mode that ends after the switch to off applies nothing either.
      enforce = settings("enforce", root)
      settings("off", root)
      flush_comments()

      assert {:auto_review_gate, "issue-gate-flow", "approve", "In Review"} = AutoReview.run_gate(gate_job(judged(), enforce), gate_opts(root))
      assert_receive {:memory_tracker_comment, "issue-gate-flow", body}
      assert body =~ "**Mode:** off. The gate was turned off during this pass"
      assert_receive {:memory_tracker_state_update, "issue-gate-flow", "In Review"}

      # Settings that can't be read again keep the job's.
      record = put_record(%{repo_key: "gone", qa_sha: @sha, qa_verdict: "pass", qa_target_state: "In Review"})

      capture_log(fn ->
        assert {:auto_review_gate, "issue-gate-flow", "approve", "Merging"} = AutoReview.run_gate(gate_job(record, enforce), gate_opts(root))
      end)
    end
  end
end
