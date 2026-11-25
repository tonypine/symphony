defmodule SymphonyElixir.CoreAgentRunnerTurnsTest do
  use SymphonyElixir.TestSupport

  defmodule TerminalGuardDependencyAudit do
    @spec audit(Path.t(), keyword()) :: {:ok, []} | {:hold, [map()]} | {:error, term()}
    def audit(workspace, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :terminal_guard_audit_recipient), {:dependency_audit, workspace})
      Application.fetch_env!(:symphony_elixir, :terminal_guard_audit_result)
    end
  end

  defmodule MergingCiGitHub do
    # Stands in for GitHub.PullRequest.fetch_ci_status/2 for a landing run; reports
    # the call and returns the configured CI status.
    def fetch_ci_status(pr_url, opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :merging_ci_github_recipient)
      send(recipient, {:merging_ci_status_fetched, pr_url, opts})
      Application.fetch_env!(:symphony_elixir, :merging_ci_github_result)
    end
  end

  defmodule McpRestartAgent do
    # Coding-agent stand-in that replays scripted `run_turn` results per call and
    # reports session starts/stops.
    def start_session(workspace, opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :mcp_restart_agent_recipient)
      count = Application.get_env(:symphony_elixir, :mcp_restart_agent_sessions, 0) + 1
      Application.put_env(:symphony_elixir, :mcp_restart_agent_sessions, count)
      send(recipient, {:mcp_restart_start_session, count, workspace, opts})
      {:ok, %{session: count}}
    end

    def run_turn(session, prompt, _issue, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :mcp_restart_agent_recipient)
      count = Application.get_env(:symphony_elixir, :mcp_restart_agent_turns, 0) + 1
      Application.put_env(:symphony_elixir, :mcp_restart_agent_turns, count)
      send(recipient, {:mcp_restart_run_turn, count, session, prompt})

      results = Application.fetch_env!(:symphony_elixir, :mcp_restart_agent_turn_results)
      Enum.at(results, count - 1) || {:ok, %{session_id: "sess-#{count}"}}
    end

    def stop_session(session) do
      recipient = Application.fetch_env!(:symphony_elixir, :mcp_restart_agent_recipient)
      send(recipient, {:mcp_restart_stop_session, session})
      :ok
    end
  end

  defp no_op_issue_enricher do
    fn issue -> {:ok, issue} end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        agent_command: "#{codex_binary} app-server",
        max_turns: 3,
        prompt:
          "First prompt {{ issue.identifier }}{% for comment in issue.comments %} comment={{ comment.body }}{% endfor %}{% for link in issue.linked_issues %} link={{ link.identifier }}{% endfor %}"
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      issue_enricher = fn issue ->
        send(parent, {:issue_enriched, issue.identifier})

        {:ok,
         %{
           issue
           | comments: [%{author: "Codex", body: "Prior workpad", created_at: ~U[2026-05-05 02:00:00Z]}],
             linked_issues: [%{relation: "related", identifier: "MT-248", title: "Related", state: "Todo"}]
         }}
      end

      assert :ok =
               RunStore.put_pr_review(%{
                 repo_key: "default",
                 issue_id: "issue-continue",
                 issue_identifier: "MT-247",
                 pr_url: "https://github.com/example/repo/pull/247",
                 workspace_path: workspace_root,
                 status: "rework_requested",
                 pending_last_addressed_comment_id: "comment-247",
                 pending_reviewer_comments: [
                   %{
                     id: "comment-247",
                     kind: "inline_comment",
                     author: "Reviewer",
                     body: "Please tighten this branch.",
                     path: "lib/example.ex",
                     line: 42
                   }
                 ],
                 updated_at: ~U[2026-05-05 02:00:00Z]
               })

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: state_fetcher,
                 issue_enricher: issue_enricher
               )

      assert_receive {:issue_enriched, "MT-247"}
      refute_receive {:issue_enriched, "MT-247"}, 50
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "First prompt MT-247"
      assert Enum.at(turn_texts, 0) =~ "## Symphony Workpad"
      assert Enum.at(turn_texts, 0) =~ "comment=<linear_issue_comment_body>\nPrior workpad"
      assert Enum.at(turn_texts, 0) =~ "link=MT-248"
      assert Enum.at(turn_texts, 0) =~ "Unaddressed reviewer comments:"
      assert Enum.at(turn_texts, 0) =~ "lib/example.ex:42"
      assert Enum.at(turn_texts, 0) =~ "<linear_reviewer_comment_body>\nPlease tighten this branch."
      assert Enum.at(turn_texts, 0) =~ "Please tighten this branch."
      refute Enum.at(turn_texts, 1) =~ "First prompt MT-247"
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "previous Codex turn completed"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner ends a landing run on pending checks and reports the head to wait on" do
    pr_url = "https://github.com/example/repo/pull/232"
    pending = {:ok, %{commit_sha: "sha-pending", checks: [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]}}

    assert run_merging_landing_turns(pending) == 1
    assert_received {:merging_ci_status_fetched, ^pr_url, [cwd: _workspace, required_checks: true]}
    assert_received {:merging_ci_wait, "issue-merging-continue", %{commit_sha: "sha-pending", pr_url: ^pr_url}}
  end

  test "agent runner keeps a landing run going when checks are settled or unreadable" do
    green = {:ok, %{commit_sha: "sha-green", checks: [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]}}

    assert run_merging_landing_turns(green) == 2
    refute_received {:merging_ci_wait, _issue_id, _wait}

    assert run_merging_landing_turns({:error, :gh_unavailable}) == 2
    refute_received {:merging_ci_wait, _issue_id, _wait}
  end

  test "agent runner keeps a landing run going once every check the base branch requires passed" do
    checks = [
      %{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"},
      %{name: "deploy preview", status: "QUEUED", conclusion: nil}
    ]

    assert run_merging_landing_turns({:ok, %{commit_sha: "sha-ready", checks: checks, required_checks: ["make-all"]}}) == 2
    refute_received {:merging_ci_wait, _issue_id, _wait}

    # Without required checks, the queued check holds it until it finishes.
    assert run_merging_landing_turns({:ok, %{commit_sha: "sha-ready", checks: checks, required_checks: []}}) == 1
    assert_received {:merging_ci_wait, "issue-merging-continue", %{commit_sha: "sha-ready"}}
  end

  defp run_merging_landing_turns(ci_status_result) do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-agent-runner-merging-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merging"}}}'
            ;;
          4|5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merging","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      Application.put_env(:symphony_elixir, :merging_ci_github_recipient, self())
      Application.put_env(:symphony_elixir, :merging_ci_github_result, ci_status_result)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :merging_ci_github_recipient)
        Application.delete_env(:symphony_elixir, :merging_ci_github_result)
      end)

      issue = %Issue{
        id: "issue-merging-continue",
        identifier: "MT-232",
        title: "Land after CI",
        state: "Merging",
        url: "https://example.org/issues/MT-232",
        labels: []
      }

      :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, "https://github.com/example/repo/pull/232", nil)

      Process.delete(:merging_fetch_count)

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:merging_fetch_count, 0) + 1
        Process.put(:merging_fetch_count, attempt)
        {:ok, [%Issue{issue | state: if(attempt == 1, do: "Merging", else: "Done")}]}
      end

      assert :ok =
               AgentRunner.run(issue, self(),
                 issue_state_fetcher: state_fetcher,
                 issue_enricher: &{:ok, &1},
                 github: MergingCiGitHub
               )

      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))
      |> Enum.count(&(&1["method"] == "turn/start"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner holds dependency approval before starting a continuation turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-dependency-hold-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-DEP-HOLD")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace)

      File.write!(Path.join(workspace, "mix.exs"), """
      defmodule Demo.MixProject do
        use Mix.Project
        def project, do: []
        def application, do: []
        defp deps, do: [{:jason, "~> 1.4"}]
      end
      """)

      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "mix.exs"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "base"])
      System.cmd("git", ["-C", workspace, "update-ref", "refs/remotes/origin/main", "HEAD"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dep-hold"}}}'
            ;;
          4)
            cat > mix.exs <<'MIX'
      defmodule Demo.MixProject do
        use Mix.Project
        def project, do: []
        def application, do: []
        defp deps, do: [{:jason, "~> 1.4"}, {:helper, git: "https://github.com/attacker/helper.git"}]
      end
      MIX
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dep-hold-1","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf 'UNEXPECTED_SECOND_TURN\\n' >> "$trace_file"
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dep-hold-2","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      assert :ok = SymphonyElixir.Notifications.subscribe()

      issue = %Issue{
        id: "issue-dep-hold",
        identifier: "MT-DEP-HOLD",
        title: "Dependency hold",
        description: "Hold risky dependency",
        state: "In Progress",
        repo_key: Config.repo_key!()
      }

      RunStore.delete_ticket_state("issue-dep-hold")

      # The Needs Decision label is the pause projector's to write.
      Application.put_env(:symphony_elixir, :pause_projector, true)
      on_exit(fn -> Application.put_env(:symphony_elixir, :pause_projector, false) end)

      test_pid = self()

      state_fetcher = fn ids ->
        send(test_pid, {:issue_state_fetch, ids})
        {:ok, [issue]}
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 workspace_path: workspace,
                 issue_state_fetcher: state_fetcher,
                 issue_enricher: no_op_issue_enricher()
               )

      assert_receive {:issue_state_fetch, ["issue-dep-hold"]}
      refute_receive {:issue_state_fetch, _ids}, 50
      assert_receive {:memory_tracker_label_added, "issue-dep-hold", "Needs Decision"}, 5_000
      refute_received {:memory_tracker_state_update, "issue-dep-hold", _state}

      assert [%{name: "decision requested", details: %{question: true, reason: "dependency_source_requires_approval"}}] =
               ticket_signals("issue-dep-hold")

      assert_receive {:notification_event,
                      %SymphonyElixir.Notifications.Event{
                        event: "dependency_pending_approval",
                        metadata: %{dependency_changes: [%{package: "helper", reason: "untrusted_git_source"}]}
                      }},
                     500

      refute File.read!(trace_file) =~ "UNEXPECTED_SECOND_TURN"
    after
      File.rm_rf(test_root)
    end
  end

  describe "agent runner dependency audit after the issue lands" do
    setup do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-agent-runner-terminal-guard-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join([test_root, "workspaces", "MT-TERMINAL-GUARD"])
      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :terminal_guard_audit_recipient, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
        Application.delete_env(:symphony_elixir, :terminal_guard_audit_recipient)
        Application.delete_env(:symphony_elixir, :terminal_guard_audit_result)
        File.rm_rf(test_root)
      end)

      issue = %Issue{
        id: "issue-terminal-guard",
        identifier: "MT-TERMINAL-GUARD",
        title: "Terminal guard",
        description: "Agent merges its PR during the turn",
        state: "Merging"
      }

      %{test_root: test_root, workspace: workspace, issue: issue}
    end

    test "skips the audit when cleanup removed the workspace mid-turn", context do
      write_terminal_guard_workflow!(context.test_root, ~s(rm -rf "#{context.workspace}"))
      Application.put_env(:symphony_elixir, :terminal_guard_audit_result, {:hold, [%{package: "base_ref"}]})

      assert :ok = run_terminal_guard_issue(context.issue, context.workspace)

      refute File.exists?(context.workspace)
      refute_received {:dependency_audit, _workspace}
      refute_received {:memory_tracker_state_update, "issue-terminal-guard", _state}
    end

    test "does not move a terminal issue when the audit holds", context do
      write_terminal_guard_workflow!(context.test_root)
      Application.put_env(:symphony_elixir, :terminal_guard_audit_result, {:hold, [%{package: "helper"}]})
      assert :ok = SymphonyElixir.Notifications.subscribe()

      assert :ok = run_terminal_guard_issue(context.issue, context.workspace)

      assert_received {:dependency_audit, _workspace}
      refute_received {:memory_tracker_state_update, "issue-terminal-guard", _state}
      refute_received {:notification_event, %SymphonyElixir.Notifications.Event{event: "dependency_pending_approval"}}
    end

    test "does not fail the run for a terminal issue when the audit errors", context do
      write_terminal_guard_workflow!(context.test_root)
      Application.put_env(:symphony_elixir, :terminal_guard_audit_result, {:error, :base_ref_unavailable})

      assert :ok = run_terminal_guard_issue(context.issue, context.workspace)

      assert_received {:dependency_audit, _workspace}
      refute_received {:memory_tracker_state_update, "issue-terminal-guard", _state}
    end

    test "still fails the run for an active issue when the audit errors", context do
      write_terminal_guard_workflow!(context.test_root)
      Application.put_env(:symphony_elixir, :terminal_guard_audit_result, {:error, :base_ref_unavailable})

      assert_raise RuntimeError, ~r/dependency_audit_failed/, fn ->
        run_terminal_guard_issue(context.issue, context.workspace, "In Progress")
      end
    end
  end

  defp write_terminal_guard_workflow!(test_root, turn_command \\ ":") do
    codex_binary = Path.join(test_root, "fake-codex")

    File.write!(codex_binary, """
    #!/bin/sh
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-terminal-guard"}}}'
          ;;
        4)
          #{turn_command}
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-terminal-guard","status":"inProgress","items":[]}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(test_root, "workspaces"),
      agent_command: "#{codex_binary} app-server",
      max_turns: 1
    )
  end

  defp run_terminal_guard_issue(issue, workspace, refreshed_state \\ "Done") do
    AgentRunner.run(issue, nil,
      workspace_path: workspace,
      issue_state_fetcher: fn _ids -> {:ok, [%{issue | state: refreshed_state}]} end,
      issue_enricher: no_op_issue_enricher(),
      dependency_audit_module: TerminalGuardDependencyAudit
    )
  end

  test "agent runner fails the run when a continuation turn fails, without starting a new session" do
    run_mcp_restart_issue!(
      [{:ok, %{session_id: "sess-1"}}, {:error, {:turn_failed, "boom"}}],
      fn result ->
        assert {:raise, %RuntimeError{message: message}} = result
        assert message =~ "boom"
        refute_receive {:mcp_restart_start_session, 2, _workspace, _opts}, 50
      end
    )
  end

  for {label, transient_error} <- [
        rate_limit: {:linear_rate_limited, 1_791_000_030_000},
        timeout: {:linear_api_request, %Req.TransportError{reason: :timeout}}
      ] do
    test "agent runner waits out a Linear #{label} on the post-turn refresh and continues in the same session" do
      transient_error = unquote(Macro.escape(transient_error))
      now_ms = 1_791_000_000_000
      parent = self()

      fetcher = fn _ids ->
        fetches = Process.get(:linear_wait_fetches, 0) + 1
        Process.put(:linear_wait_fetches, fetches)

        case fetches do
          1 -> {:error, transient_error}
          2 -> {:ok, [%Issue{id: "issue-mcp-restart", identifier: "MT-MCP-RESTART", state: "In Progress"}]}
          _later -> {:ok, [%Issue{id: "issue-mcp-restart", identifier: "MT-MCP-RESTART", state: "Done"}]}
        end
      end

      log =
        capture_log(fn ->
          run_mcp_restart_issue!(
            [{:ok, %{session_id: "sess-1"}}, {:ok, %{session_id: "sess-1"}}],
            fn result ->
              assert result == :ok
              assert_receive {:mcp_restart_start_session, 1, _workspace, _opts}
              assert_receive {:mcp_restart_run_turn, 1, %{session: 1}, _first_prompt}
              assert_receive {:linear_wait_slept, delay_ms}
              assert delay_ms == if(unquote(label) == :rate_limit, do: 30_000, else: 5_000)
              # The orchestrator hears of the wait, so its watchdogs hold off until it ends.
              assert_receive {:linear_wait, "issue-mcp-restart", ^delay_ms}
              assert_receive {:mcp_restart_run_turn, 2, %{session: 1}, _continuation_prompt}
              refute_receive {:mcp_restart_start_session, 2, _workspace, _opts}, 50
            end,
            issue_state_fetcher: fetcher,
            runner_opts: [
              linear_retry_opts: [now_ms_fun: fn -> now_ms end, sleep_fun: &send(parent, {:linear_wait_slept, &1})]
            ]
          )
        end)

      assert log =~ "Linear refresh after turn failed for issue_id=issue-mcp-restart"
      assert log =~ "in the same session"
      refute log =~ "Agent run failed"
    end
  end

  test "agent runner fails the run on a post-turn refresh error that is not transient" do
    run_mcp_restart_issue!(
      [{:ok, %{session_id: "sess-1"}}],
      fn result ->
        assert {:raise, %RuntimeError{message: message}} = result
        assert message =~ "issue_state_refresh_failed"
        refute_receive {:mcp_restart_run_turn, 2, _session, _prompt}, 50
      end,
      issue_state_fetcher: fn _ids -> {:error, :missing_linear_api_token} end
    )
  end

  defp run_mcp_restart_issue!(turn_results, assertions, opts \\ []) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-mcp-restart-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:symphony_elixir, :mcp_restart_agent_recipient, self())
    Application.put_env(:symphony_elixir, :mcp_restart_agent_turn_results, turn_results)

    try do
      workspace = Path.join(test_root, "MT-MCP-RESTART")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        max_turns: 3
      )

      issue = %Issue{id: "issue-mcp-restart", identifier: "MT-MCP-RESTART", title: "MCP restart", state: "In Progress"}

      default_fetcher = fn _ids ->
        state = if Process.get(:mcp_restart_fetches, 0) >= 1, do: "Done", else: "In Progress"
        Process.put(:mcp_restart_fetches, Process.get(:mcp_restart_fetches, 0) + 1)
        {:ok, [%{issue | state: state}]}
      end

      result =
        try do
          AgentRunner.run(
            issue,
            self(),
            [
              workspace_path: workspace,
              agent_module: McpRestartAgent,
              issue_state_fetcher: Keyword.get(opts, :issue_state_fetcher, default_fetcher),
              issue_enricher: no_op_issue_enricher()
            ] ++ Keyword.get(opts, :runner_opts, [])
          )
        rescue
          error -> {:raise, error}
        catch
          :exit, reason -> {:exit, reason}
        end

      assertions.(result)
    after
      for key <- [
            :mcp_restart_agent_recipient,
            :mcp_restart_agent_turn_results,
            :mcp_restart_agent_sessions,
            :mcp_restart_agent_turns
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        agent_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: state_fetcher,
                 issue_enricher: no_op_issue_enricher()
               )

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once a breakdown parent has open sub-issues" do
    open_sub_issues = [%{id: "child-1", identifier: "MT-250", state: "Todo"}]

    # The breakdown run ends with the parent In Progress (state missing) or parked in the waiting
    # state; anything else in the waiting state is held too.
    for {refreshed_state, labels, sub_issues} <- [
          {"In Progress", ["breakdown"], open_sub_issues},
          {"Waiting on sub-tickets", ["breakdown"], open_sub_issues},
          {"Waiting on sub-tickets", ["feature"], []}
        ] do
      assert_agent_runner_stops_after_one_turn(refreshed_state, labels, sub_issues)
    end
  end

  test "agent runner keeps a breakdown run going while its plan's sub-issues are all in Backlog" do
    # The plan is not handed over yet: a resumed run keeps filing sub-tickets until it moves the
    # parent to In Review (max_turns ends this one).
    backlog = [%{id: "child-1", identifier: "MT-250", state: "Backlog"}]
    assert_agent_runner_stops_after_one_turn("In Progress", ["breakdown"], backlog, [], 2)
  end

  test "agent runner stops continuing once a final verification parks itself in Todo behind its gaps" do
    gap = %{id: "gap-1", identifier: "MT-260", state: "Backlog"}
    assert_agent_runner_stops_after_one_turn("Todo", [], [gap], [gap])
  end

  # `depends_on`: the tickets the parent depends on, stored by Symphony (`RunStore.add_dependency/3`).
  defp assert_agent_runner_stops_after_one_turn(refreshed_state, labels, sub_issues, depends_on \\ [], turns \\ 1) do
    :ok = RunStore.clear()

    if depends_on != [] do
      :ok = RunStore.put_ticket_state(SymphonyElixir.TicketState.new("default", "issue-parent-hold", %{issue_identifier: "MT-249", phase: refreshed_state}))

      for %{id: id, identifier: identifier, state: state} <- depends_on do
        :ok = RunStore.put_ticket_state(SymphonyElixir.TicketState.new("default", id, %{issue_identifier: identifier, phase: state}))
        :ok = RunStore.add_dependency("issue-parent-hold", id, :done)
      end
    end

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-parent-hold-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        agent_command: "#{codex_binary} app-server",
        max_turns: if(turns == 1, do: 3, else: turns)
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-parent-hold",
             identifier: "MT-249",
             title: "Groom into sub-tickets",
             description: "Still active",
             state: refreshed_state,
             labels: labels,
             sub_issues: sub_issues
           }
         ]}
      end

      issue = %Issue{
        id: "issue-parent-hold",
        identifier: "MT-249",
        title: "Groom into sub-tickets",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-249",
        labels: ["breakdown"]
      }

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: state_fetcher,
                 issue_enricher: no_op_issue_enricher()
               )

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == turns
    after
      RunStore.clear()
      File.rm_rf(test_root)
    end
  end
end
