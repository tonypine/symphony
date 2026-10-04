defmodule SymphonyElixir.AcceptanceGateTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AcceptanceGate, QaAgent}
  alias SymphonyElixir.AcceptanceGate.Report
  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config.Schema

  @sha "feedface00112233445566778899aabbccddeeff"
  @merged "abcabc00112233445566778899aabbccddeeff00"

  defmodule FakeContext do
    def build(issue, record, sha, settings, opts) do
      send(self(), {:context_build, issue, record, sha, settings, opts})
      Process.get(:gate_context)
    end
  end

  defmodule FakeSession do
    def start_session(worktree, opts) do
      send(self(), {:gate_session_started, worktree, opts})
      Process.get(:gate_start_result, {:ok, %{worktree: worktree}})
    end

    # `:gate_turn_results` answers successive turns; the last answer repeats.
    def run_turn(session, prompt, issue, opts) do
      send(self(), {:gate_turn, session, prompt, issue, opts})
      Enum.each(Process.get(:gate_messages, []), Keyword.fetch!(opts, :on_message))

      case Process.get(:gate_turn_results, [{:ok, %{result: answer_json()}}]) do
        [result | [_ | _] = rest] ->
          Process.put(:gate_turn_results, rest)
          result

        [result] ->
          result
      end
    end

    def stop_session(session) do
      send(self(), {:gate_session_stopped, session})
      :ok
    end

    def answer_json(attrs \\ %{}) do
      Jason.encode!(
        Map.merge(
          %{
            verdict: "approve",
            summary: "Every criterion is met.",
            criteria: [
              %{id: "C1", criterion: "Adds the command", status: "met", evidence: "lib/app.ex:3 defines `check/0`"},
              %{id: "C2", criterion: "Documents it", status: "unclear", evidence: "no doc change"}
            ],
            overlaps: [%{pr_url: "https://github.com/org/app/pull/2", detail: "both change `alpha/1`"}],
            scope: [%{kind: "unrelated", detail: "reformats README"}],
            escalation_reasons: [],
            follow_ups: [%{title: "Add a --json flag", detail: "out of scope here"}]
          },
          attrs
        )
      )
    end
  end

  defmodule FailingStore do
    def put_run(_record), do: {:error, :disk_full}
    def update_run(_repo_key, _run_id, _attrs), do: {:error, :disk_full}
    def update_ci_check(_repo_key, _issue_id, _attrs), do: {:error, :disk_full}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "acceptance-gate-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true},
      auto_review: %{enabled: true}
    )

    settings = Config.settings!()
    settings = put_in(settings.workspace.root, root)
    settings = put_in(settings.auto_review.acceptance_gate.mode, "shadow")

    Process.put(:gate_context, {:ok, context()})
    Process.put(:gate_root, root)
    File.mkdir_p!(Path.join(root, "tmp"))
    %{settings: settings, root: root}
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-gate",
        identifier: "TP-950",
        title: "Add `app check`",
        description: "Adds a check command.\n\n## Acceptance\n\n- [ ] Adds the command\n- [x] Documents it\n\n## Notes\n\n- [ ] not a criterion\n",
        state: "Auto Review",
        url: "https://linear.test/TP-950",
        labels: []
      },
      attrs
    )
  end

  defp record(attrs \\ %{}) do
    Map.merge(%{repo_key: "default", issue_id: "issue-gate", pr_url: "https://github.com/org/app/pull/1", workspace_path: "/tmp/workspaces/TP-950", worker_host: nil}, attrs)
  end

  defp context(attrs \\ %{}) do
    Map.merge(
      %{
        base_branch: "main",
        base_sha: "base0000112233445566778899aabbccddeeff00",
        merged_sha: @merged,
        diff: "diff --git a/lib/app.ex b/lib/app.ex\n+  def check, do: :ok\n",
        diff_truncated?: false,
        numstat: [%{path: "lib/app.ex", additions: 1, deletions: 0}],
        diff_summary: %{files: [%{path: "lib/app.ex", additions: 1, deletions: 0, added_lines: ["  def check, do: :ok"]}]},
        busy_files: ["lib/app.ex"],
        overlaps: [%{pr_url: "https://github.com/org/app/pull/2", issue_identifier: "TP-2", files: ["lib/app.ex"], functions: [%{path: "lib/app.ex", name: "def alpha"}]}]
      },
      attrs
    )
  end

  defp audit_events(root) do
    {:ok, events} = SymphonyElixir.AuditLog.query(event_type: "acceptance_gate_verdict", issue_id: "issue-gate", dir: Path.join(root, "audit"))
    Enum.to_list(events)
  end

  defp untracked_overlap, do: %{pr_url: "https://github.com/org/app/pull/9", issue_identifier: nil, files: ["a.ex"], functions: []}

  defp job(attrs \\ %{}), do: Map.merge(%{issue: issue(), record: record(), sha: @sha, qa: %{verdict: :pass}}, attrs)

  defp git(test_pid \\ self()) do
    fn args, cwd ->
      send(test_pid, {:git, args, cwd})
      {"", 0}
    end
  end

  defp run_opts(extra \\ []) do
    defaults = [
      context: FakeContext,
      gate_agent_module: FakeSession,
      git: git(),
      leftover_processes: [table: fn -> {:ok, []} end],
      tmp_bases: [Path.join(Process.get(:gate_root), "tmp")]
    ]

    Keyword.merge(defaults, extra)
  end

  describe "the gate session" do
    test "runs read-only in a worktree at the merge result, with no write tool", %{settings: settings, root: root} do
      result = AcceptanceGate.run(job(), settings, run_opts())

      worktree = AcceptanceGate.worktree_path(settings, "default", "TP-950", @sha)
      assert_received {:git, ["worktree", "add", "--detach", ^worktree, @merged], "/tmp/workspaces/TP-950"}
      assert_received {:gate_session_started, ^worktree, opts}
      assert_received {:gate_session_stopped, _session}
      assert_received {:git, ["worktree", "remove", "--force", ^worktree], "/tmp/workspaces/TP-950"}

      assert opts[:tool_scope] == :read_only
      assert opts[:read_only] == true
      assert opts[:worker_host] == nil
      assert %{kind: :acceptance_gate} = opts[:run_profile]
      gate_settings = opts[:settings]
      assert gate_settings.agent.thread_sandbox == "read-only"
      assert gate_settings.agent.turn_sandbox_policy == %{"type" => "readOnly"}
      assert gate_settings.agent.max_turns == settings.auto_review.acceptance_gate.max_turns
      assert gate_settings.agent.turn_timeout_ms == settings.auto_review.acceptance_gate.timeout_ms

      # Its own temp folder is its `$TMPDIR` and its only writable path; it is removed afterwards.
      [tmp_dir] = AcceptanceGate.tmp_dirs(worktree, [Path.join(root, "tmp")])
      assert opts[:extra_env] == %{"TMPDIR" => tmp_dir}
      assert List.last(gate_settings.workspace.sandbox.allow_write_paths) == tmp_dir
      refute File.exists?(tmp_dir)

      # The `:read_only` scope lists only the Linear and GitHub read tools.
      names = DynamicTool.tool_specs(:read_only) |> Enum.map(& &1["name"]) |> Enum.sort()

      assert names ==
               Enum.sort(~w(linear_get_current_issue linear_get_subissues linear_get_parent_issue linear_get_comments linear_get_related_issues
                     github_get_pull_request github_get_pr_checks github_list_pr_comments github_list_pr_review_comments github_list_pr_reviews
                     github_get_failed_run_log))

      # Codex runs the turn under a read-only sandbox policy.
      assert {:ok, %{"type" => "readOnly"}} = Schema.resolve_runtime_turn_sandbox_policy(gate_settings, worktree)

      # Claude gets no file-editing tool, can't write its working directory, and still can't push.
      claude = ClaudeAppServer.build_claude_settings(gate_settings.agent.network_access, [], [], [], opts[:read_only])
      assert ["Edit", "Write", "NotebookEdit"] -- claude["permissions"]["deny"] == []
      assert "Bash(git push:*)" in claude["permissions"]["deny"]
      assert "Bash(gh:*)" in claude["permissions"]["deny"]
      assert "." in claude["sandbox"]["filesystem"]["denyWrite"]
      default = ClaudeAppServer.build_claude_settings(gate_settings.agent.network_access, [], [])
      refute "Edit" in default["permissions"]["deny"]
      refute "." in default["sandbox"]["filesystem"]["denyWrite"]

      assert {:answer, %{verdict: "approve", criteria: [%{id: "C1", status: "met"}, %{id: "C2", status: "unclear"}]}} = result.outcome
      assert result.reasons == []
      assert result.criteria == [%{id: "C1", criterion: "Adds the command"}, %{id: "C2", criterion: "Documents it"}]
      assert result.follow_up_turns == 0
    end

    test "the prompt carries the criteria, the QA verdict, the overlaps and the escalation reasons", %{settings: settings} do
      AcceptanceGate.run(job(%{issue: issue(%{labels: ["needs-human"]}), qa: %{verdict: :blocked, reason: "no simulator"}}), settings, run_opts())

      assert_received {:gate_turn, _session, prompt, _issue, _opts}
      assert prompt =~ "- C1: "
      assert prompt =~ "Adds the command"
      refute prompt =~ "- C3:"
      assert prompt =~ "QA verdict: blocked (no simulator)"
      assert prompt =~ "https://github.com/org/app/pull/2 (TP-2): files lib/app.ex; functions lib/app.ex def alpha"
      assert prompt =~ "- label: the issue is labelled `needs-human`"
      assert prompt =~ "- qa_blocked: QA was blocked: no simulator"
      assert prompt =~ "Busy files on `main`: lib/app.ex"
      assert prompt =~ "- lib/app.ex +1 -0"
      assert prompt =~ "+  def check, do: :ok"
      refute prompt =~ "cut at 120 KB"
    end

    test "the prompt leaves code style and bugs to the pre-push reviewer unless one makes a criterion unmet", %{settings: settings} do
      AcceptanceGate.run(job(), settings, run_opts())

      assert_received {:gate_turn, _session, prompt, _issue, _opts}
      assert prompt =~ "Do not review code style or look for bugs: the pre-push reviewer did."
      assert prompt =~ "A bug counts only when it\nmakes an acceptance criterion unmet."
    end

    test "a bare context and a ticket without criteria get placeholders in the prompt", %{settings: settings} do
      Process.put(
        :gate_context,
        {:ok, context(%{overlaps: [untracked_overlap()], busy_files: [], numstat: [], diff_truncated?: true})}
      )

      AcceptanceGate.run(job(%{issue: issue(%{description: nil}), qa: nil}), settings, run_opts())

      assert_received {:gate_turn, _session, prompt, _issue, _opts}
      assert prompt =~ "none found under an Acceptance heading"
      assert prompt =~ "QA verdict: unknown"
      assert prompt =~ "https://github.com/org/app/pull/9 (untracked): files a.ex\n"
      assert prompt =~ "Busy files on `main`: (none)"
      assert prompt =~ "cut at 120 KB"

      Process.put(:gate_context, {:ok, context(%{overlaps: []})})
      AcceptanceGate.run(job(%{qa: %{verdict: :skip}}), settings, run_opts())
      assert_received {:gate_turn, _session, prompt, _issue, _opts}
      assert prompt =~ "Open PRs that change the same files:\n(none)"
      assert prompt =~ "QA verdict: skip\n"
    end

    test "records the session's tokens and stops at the per-issue token limit", %{settings: settings} do
      Process.put(:gate_messages, [%{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 300, "output_tokens" => 50, "total_tokens" => 350}}}])

      assert %{tokens: %{total_tokens: 350}, outcome: {:answer, _answer}} = AcceptanceGate.run(job(), settings, run_opts())

      assert %{outcome: {:inconclusive, {:gate_token_limit, 350, 100}}, tokens: %{total_tokens: 350}} =
               AcceptanceGate.run(job(%{token_limit: 100}), settings, run_opts())

      assert_received {:gate_session_stopped, _session}
    end

    test "a malformed answer gets one follow-up turn in the same session", %{settings: settings} do
      Process.put(:gate_messages, [{:session_started, "claude-session-1"}])
      Process.put(:gate_turn_results, [{:ok, %{result: "I looked at the diff."}}, {:ok, %{result: FakeSession.answer_json()}}])

      assert %{outcome: {:answer, %{verdict: "approve"}}, follow_up_turns: 1} = AcceptanceGate.run(job(), settings, run_opts())
      assert_received {:gate_turn, _session, _prompt, _issue, _opts}
      assert_received {:gate_turn, _session, follow_up, _issue, opts}
      assert follow_up == AcceptanceGate.follow_up_prompt()
      assert opts[:resume_session_id] == "claude-session-1"
    end

    test "a second malformed answer is inconclusive", %{settings: settings} do
      Process.put(:gate_turn_results, [{:ok, %{result: ~s({"verdict": "ship it"})}}])

      assert %{outcome: {:inconclusive, {:malformed_gate_response, :invalid_verdict}}, follow_up_turns: 1} =
               AcceptanceGate.run(job(), settings, run_opts())

      Process.put(:gate_turn_results, [{:ok, %{result: ""}}])
      assert %{outcome: {:inconclusive, {:malformed_gate_response, :empty_response}}} = AcceptanceGate.run(job(), settings, run_opts())
    end

    test "agent and worktree failures are inconclusive", %{settings: settings} do
      Process.put(:gate_turn_results, [{:error, :port_exit}])
      assert %{outcome: {:inconclusive, {:gate_agent_failed, :port_exit}}} = AcceptanceGate.run(job(), settings, run_opts())

      Process.put(:gate_start_result, {:error, :no_claude})
      assert %{outcome: {:inconclusive, {:gate_agent_failed, :no_claude}}} = AcceptanceGate.run(job(), settings, run_opts())

      failing_git = fn
        ["worktree", "add" | _rest], _cwd -> {"fatal: bad object", 128}
        _args, _cwd -> {"", 0}
      end

      assert %{outcome: {:inconclusive, {:gate_worktree_failed, 128, "fatal: bad object"}}} =
               AcceptanceGate.run(job(), settings, run_opts(git: failing_git))

      not_a_repo = Path.join(Process.get(:gate_root), "not-a-repo")
      File.mkdir_p!(not_a_repo)

      assert %{outcome: {:inconclusive, {:gate_worktree_failed, 128, _output}}} =
               AcceptanceGate.run(job(%{record: record(%{workspace_path: not_a_repo})}), settings, Keyword.delete(run_opts(), :git))

      unsupported = put_in(settings.auto_review.acceptance_gate.kind, "gpt")

      assert %{outcome: {:inconclusive, {:unsupported_qa_agent_kind, "gpt"}}} =
               AcceptanceGate.run(job(), unsupported, Keyword.delete(run_opts(), :gate_agent_module))

      assert %{outcome: {:inconclusive, {:gate_tmp_dir_failed, [_path]}}} =
               AcceptanceGate.run(job(), settings, run_opts(tmp_bases: ["/nonexistent-symphony-test-dir"]))

      assert %{outcome: {:inconclusive, {:remote_worker_unsupported, "worker-1"}}} =
               AcceptanceGate.run(job(%{record: record(%{worker_host: "worker-1"})}), settings, run_opts())
    end

    test "a conflict or a failed context skips the agent and still checks the ticket rules", %{settings: settings} do
      Process.put(:gate_context, {:conflict, ["README.md"]})
      issue = issue(%{labels: ["needs-human"]})

      assert %{outcome: {:conflict, ["README.md"]}, reasons: [%{rule: "label"}]} = AcceptanceGate.run(job(%{issue: issue}), settings, run_opts())

      Process.put(:gate_context, {:error, :missing_workspace_path})

      log =
        capture_log(fn ->
          assert %{outcome: {:inconclusive, {:context_failed, :missing_workspace_path}}, reasons: []} = AcceptanceGate.run(job(), settings, run_opts())
        end)

      assert log =~ "Acceptance gate context failed for TP-950"
      refute_received {:gate_session_started, _worktree, _opts}
    end

    test "the diff summary feeds the escalation rules", %{settings: settings} do
      files = [%{path: "lib/app/auth.ex", additions: 2, deletions: 0, added_lines: ["rm -rf /"]}]
      Process.put(:gate_context, {:ok, context(%{diff_summary: %{files: files}})})

      assert %{reasons: [%{rule: "path"}, %{rule: "diff_pattern"}]} = AcceptanceGate.run(job(), settings, run_opts())
    end
  end

  describe "decide/4" do
    defp result(outcome, reasons \\ []), do: %{outcome: outcome, reasons: reasons}

    test "keeps the agent's verdict unless a deterministic reason escalates", %{settings: settings} do
      answer = {:answer, %{verdict: "approve"}}
      label = %{rule: "label", detail: "needs-human"}

      assert %{verdict: "approve", agent_verdict: "approve", reasons: []} = AcceptanceGate.decide(result(answer), %{}, @sha, settings)
      assert %{verdict: "escalate", agent_verdict: "approve", reasons: [^label]} = AcceptanceGate.decide(result(answer, [label]), %{}, @sha, settings)
    end

    test "a conflict is rework, or escalate with a deterministic reason", %{settings: settings} do
      assert %{verdict: "rework", agent_verdict: nil, reasons: [%{rule: "conflict", detail: detail}]} =
               AcceptanceGate.decide(result({:conflict, ["a.ex", "b.ex"]}), %{}, @sha, settings)

      assert detail == "the PR conflicts with current main in a.ex, b.ex"
      label = %{rule: "label", detail: "needs-human"}
      assert %{verdict: "escalate", reasons: [^label, %{rule: "conflict"}]} = AcceptanceGate.decide(result({:conflict, ["a.ex"]}, [label]), %{}, @sha, settings)
    end

    test "counts inconclusive passes per SHA up to the limit", %{settings: settings} do
      inconclusive = result({:inconclusive, :timeout})

      assert %{verdict: nil, agent_verdict: "inconclusive", inconclusive: 1} = AcceptanceGate.decide(inconclusive, %{}, @sha, settings)
      # Another SHA's count doesn't carry over.
      assert %{verdict: nil, inconclusive: 1} = AcceptanceGate.decide(inconclusive, %{gate_sha: "other", gate_inconclusive: 1}, @sha, settings)

      assert %{verdict: "escalate", reasons: [%{rule: "inconclusive", detail: detail}], inconclusive: 2} =
               AcceptanceGate.decide(inconclusive, %{gate_sha: @sha, gate_inconclusive: 1}, @sha, settings)

      assert detail == "2 inconclusive gate passes on this SHA (inconclusive_limit 2)"

      label = %{rule: "label", detail: "needs-human"}
      assert %{verdict: "escalate", reasons: [^label], inconclusive: 1} = AcceptanceGate.decide(result({:inconclusive, :timeout}, [label]), %{gate_sha: @sha}, @sha, settings)
    end
  end

  describe "parse_response/1" do
    test "reads the answer and defaults the optional lists" do
      assert {:ok, answer} = AcceptanceGate.parse_response(~s(Here it is: {"verdict": "rework", "escalation_reasons": "not a list"}))
      assert %{verdict: "rework", summary: "", criteria: [], overlaps: [], scope: []} = answer
      assert %{escalation_reasons: [], follow_ups: []} = answer

      assert {:ok, %{criteria: [%{id: nil, criterion: "Adds it"}], escalation_reasons: ["decide the copy"], follow_ups: [_later]}} =
               AcceptanceGate.parse_response(
                 Jason.encode!(%{
                   verdict: "escalate",
                   criteria: [%{criterion: " Adds it ", status: "met"}],
                   escalation_reasons: ["decide the copy", " "],
                   follow_ups: [%{title: "Later"}]
                 })
               )
    end

    test "rejects a missing or malformed verdict object" do
      assert {:error, {:malformed_gate_response, :empty_response}} = AcceptanceGate.parse_response(nil)
      assert {:error, {:malformed_gate_response, :no_verdict_object}} = AcceptanceGate.parse_response(~s({"result": "approve"}))

      for {field, value, reason} <- [
            {:criteria, [%{status: "met"}], :invalid_criteria},
            {:criteria, [%{id: "C1", status: "done"}], :invalid_criteria},
            {:overlaps, [%{pr_url: "x"}], :invalid_overlaps},
            {:scope, [%{kind: "style", detail: "x"}], :invalid_scope},
            {:follow_ups, [%{detail: "x"}], :invalid_follow_ups},
            {:criteria, "all met", :invalid_criteria}
          ] do
        assert {:error, {:malformed_gate_response, ^reason}} = AcceptanceGate.parse_response(Jason.encode!(Map.put(%{verdict: "approve"}, field, value)))
      end
    end
  end

  describe "criteria/3" do
    test "reads the ticket's Acceptance checklists and the workpad's, without duplicates", %{settings: settings} do
      settings = put_in(settings.tracker.kind, "linear")

      description = """
      ## Change

      - [ ] not a criterion

      ### Acceptance Criteria:

      * [ ] With mode `off`, nothing changes
      + [X] A test covers it
      plain text
      #### Other
      - [ ] also not one
      """

      workpad = """
      ## Symphony Workpad

      ### Plan

      - [ ] plan item

      ### Acceptance Criteria

      - [ ] With mode `off`,   nothing changes
      - [ ] Derived from the Linear issue description and comments.
      - [ ] The workpad adds one

      ### Validation
      """

      linear_client = fn _query, _variables, _opts ->
        {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => [%{"id" => "c2", "body" => workpad}, %{"id" => "c1", "body" => "## Symphony QA Report"}, %{"id" => "c0"}]}}}}}
      end

      assert AcceptanceGate.criteria(issue(%{description: description}), settings, linear_client: linear_client) == [
               %{id: "C1", criterion: "With mode `off`, nothing changes"},
               %{id: "C2", criterion: "A test covers it"},
               %{id: "C3", criterion: "The workpad adds one"}
             ]

      failing = fn _query, _variables, _opts -> {:error, :linear_down} end

      issue = issue(%{description: "# Acceptance\n- [ ] one"})
      log = capture_log(fn -> assert [_c1] = AcceptanceGate.criteria(issue, settings, linear_client: failing) end)
      assert log =~ "Acceptance gate could not read the workpad for TP-950"
    end

    test "checklist/2 reads nothing from a missing description" do
      assert AcceptanceGate.checklist(nil, ~r/acceptance/i) == []
    end
  end

  describe "judge/2" do
    defp judge_job(settings, attrs \\ %{}), do: Map.merge(job(%{settings: settings}), attrs)

    test "records the verdict on the CI check record, the run, the comment and the audit log", %{settings: settings, root: root} do
      :ok = RunStore.put_ci_check(Map.put(record(), :status, "green"))
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      assert {:ok, %{verdict: "approve", agent_verdict: "approve"}} = AcceptanceGate.judge(judge_job(settings), run_opts(dir: Path.join(root, "audit")))

      stored = Enum.find(RunStore.list_ci_checks(), &(&1.issue_id == "issue-gate"))
      assert %{gate_sha: @sha, gate_verdict: "approve", gate_agent_verdict: "approve", gate_reasons: [], gate_mode: "shadow"} = stored
      assert "gate-TP-950-" <> _rest = stored.gate_run_id

      assert [%{kind: "acceptance_gate", run_kind: "acceptance_gate", status: "gate_approve", head_sha: @sha, mode: "shadow"}] = RunStore.list_runs("default", :all)
      assert_received {:memory_tracker_comment, "issue-gate", body}
      assert body =~ "## Symphony Acceptance Gate"
      assert [%{"verdict" => "approve"}] = audit_events(root)
    end

    test "an inconclusive pass below the limit records no verdict and no audit event", %{settings: settings, root: root} do
      :ok = RunStore.put_ci_check(record())
      Process.put(:gate_turn_results, [{:error, :port_exit}])

      assert {:ok, %{verdict: nil, inconclusive: 1}} = AcceptanceGate.judge(judge_job(settings), run_opts(dir: Path.join(root, "audit")))
      assert %{gate_verdict: nil, gate_inconclusive: 1} = Enum.find(RunStore.list_ci_checks(), &(&1.issue_id == "issue-gate"))
      assert [%{status: "gate_inconclusive", error: "{:gate_agent_failed, :port_exit}"}] = RunStore.list_runs("default", :all)
      assert audit_events(root) == []
    end

    test "logs a failed store, report or audit write and still decides", %{settings: settings, root: root} do
      settings = put_in(settings.tracker.kind, "linear")
      not_a_dir = Path.join(root, "audit-file")
      File.mkdir_p!(root)
      File.write!(not_a_dir, "")
      failing = fn _query, _variables, _opts -> {:error, :linear_down} end

      log =
        capture_log(fn ->
          assert {:ok, %{verdict: "approve"}} =
                   AcceptanceGate.judge(judge_job(settings), run_opts(run_store: FailingStore, linear_client: failing, dir: not_a_dir))
        end)

      assert log =~ "Failed to store the acceptance gate run run_id=gate-TP-950-"
      assert log =~ "Failed to update the acceptance gate run"
      assert log =~ "Failed to store the acceptance gate verdict issue_id=issue-gate"
      assert log =~ "Failed to publish the acceptance gate report for TP-950"
      assert log =~ "Failed to audit the acceptance gate verdict for TP-950"
    end
  end

  describe "Report" do
    defp report(attrs) do
      Map.merge(
        %{
          outcome: {:answer, elem(AcceptanceGate.parse_response(FakeSession.answer_json()), 1)},
          reasons: [],
          criteria: [%{id: "C1", criterion: "Adds the command"}, %{id: "C3", criterion: "Has | a pipe\nand a newline"}],
          context: context(),
          tokens: %{QaAgent.empty_tokens() | total_tokens: 4_200},
          follow_up_turns: 1,
          decision: %{verdict: "escalate", agent_verdict: "approve", reasons: [%{rule: "label", detail: "the issue is labelled `needs-human`"}], inconclusive: 0},
          sha: @sha,
          mode: "shadow",
          runtime_seconds: 125,
          limit: 2
        },
        attrs
      )
    end

    test "shows the mode, both verdicts, one row per criterion and the findings" do
      body = Report.render(report(%{}))

      assert body =~ "## Symphony Acceptance Gate\n"
      assert body =~ "**Mode:** shadow. This verdict is advisory"
      assert body =~ "**Verdict:** escalate · **Agent verdict:** approve"
      assert body =~ "**PR head:** `feedface0011` merged onto `main` (`base00001122`) · 2m 5s · 4200 tokens · verdict after 1 follow-up"
      assert body =~ "Every criterion is met."
      assert body =~ "| Adds the command | met | lib/app.ex:3 defines `check/0` |"
      assert body =~ "| Has \\| a pipe and a newline | unclear | not judged by the gate agent |"
      assert body =~ "https://github.com/org/app/pull/2 (TP-2): `lib/app.ex`; functions `def alpha` (lib/app.ex)"
      assert body =~ "- agent: https://github.com/org/app/pull/2 both change `alpha/1`"
      assert body =~ "- unrelated: reformats README"
      assert body =~ "- `label`: the issue is labelled `needs-human`"
      assert body =~ "### Proposed follow-ups (not filed)\n\n- **Add a --json flag**: out of scope here"
    end

    test "renders an inconclusive pass, a conflict, enforce mode and an untracked overlap" do
      inconclusive =
        report(%{
          outcome: {:inconclusive, :timeout},
          context: nil,
          tokens: QaAgent.empty_tokens(),
          follow_up_turns: 0,
          runtime_seconds: 0,
          decision: %{verdict: nil, agent_verdict: "inconclusive", reasons: [], inconclusive: 1}
        })

      body = Report.render(inconclusive)
      assert body =~ "**Verdict:** inconclusive (1 of 2); Symphony runs the gate again on the next green CI poll"
      assert body =~ "**PR head:** `feedface0011`\n"
      assert body =~ "The gate pass was inconclusive: :timeout"
      assert body =~ "| Adds the command | unclear | not judged by the gate agent |"
      refute body =~ "### Overlaps"

      conflict =
        report(%{
          outcome: {:conflict, ["README.md"]},
          mode: "enforce",
          criteria: [],
          context: context(%{overlaps: [%{pr_url: "https://github.com/org/app/pull/9", issue_identifier: nil, files: ["a.ex"], functions: []}]}),
          decision: %{verdict: "rework", agent_verdict: nil, reasons: [%{rule: "conflict", detail: "conflicts"}], inconclusive: 0}
        })

      body = Report.render(conflict)
      assert body =~ "**Mode:** enforce. Symphony doesn't apply gate verdicts yet"
      assert body =~ "**Agent verdict:** none (the agent didn't run)"
      assert body =~ "The PR conflicts with current main, so the gate agent didn't run."
      assert body =~ "- https://github.com/org/app/pull/9: `a.ex`\n"
      refute body =~ "### Acceptance criteria"
    end

    test "uses the agent's criteria when Symphony listed none, and cuts long cells" do
      long = String.duplicate("x", 400)
      criteria = [%{id: "C1", criterion: long, status: "met"}]
      json = FakeSession.answer_json(%{summary: "", criteria: criteria, follow_ups: [%{title: "Later"}]})
      {:ok, answer} = AcceptanceGate.parse_response(json)

      body = Report.render(report(%{outcome: {:answer, answer}, criteria: []}))
      assert body =~ "| #{String.duplicate("x", 297)}... | met |  |"
      assert body =~ "- **Later**\n"
      refute body =~ "Every criterion is met."
    end

    test "publishes under its own heading" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      assert :ok = Report.publish(issue(), "## Symphony Acceptance Gate\n")
      assert_received {:memory_tracker_comment, "issue-gate", "## Symphony Acceptance Gate\n"}
      assert Report.heading() == "## Symphony Acceptance Gate"
    end
  end

  test "mode, enabled? and the usage profile follow the gate settings", %{settings: settings} do
    assert AcceptanceGate.mode(settings) == "shadow"
    assert AcceptanceGate.enabled?(settings)
    refute AcceptanceGate.enabled?(put_in(settings.auto_review.acceptance_gate.mode, "off"))

    codex = put_in(settings.auto_review.acceptance_gate.kind, "codex")
    assert %{kind: :acceptance_gate, provider: "openai"} = AcceptanceGate.usage_profile(codex)
  end
end
