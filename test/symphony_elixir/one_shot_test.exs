defmodule SymphonyElixir.OneShotTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.AppServer
  alias SymphonyElixir.OneShot

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok
  end

  test "successful one-shot run writes durable run-store record" do
    issue = memory_issue("issue-success", "ACME-SUCCESS")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    workspace = Path.join(System.tmp_dir!(), "symphony-success-#{System.unique_integer([:positive])}")

    deps =
      deps(%{
        start_agent_task: fn issue, recipient, _opts ->
          Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
            send(recipient, {:worker_runtime_info, issue.id, %{workspace_path: workspace}})
            :ok
          end)
        end
      })

    assert {:ok, %{status: "success"}} = OneShot.run("ACME-SUCCESS", deps: deps, no_retry: true)

    assert [%{status: "success", issue_id: "issue-success", issue_identifier: "ACME-SUCCESS", repo_key: "default"}] =
             RunStore.list_runs("default", :all)
  end

  test "the run record carries the ticket's PR from Symphony's record, and none once it closed" do
    pr_url = "https://github.com/example/repo/pull/1012"
    issue = memory_issue("issue-recorded-pr", "ACME-PR")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, pr_url, "auto/ACME-PR")

    assert {:ok, %{status: "success"}} = OneShot.run("ACME-PR", deps: deps(), no_retry: true)
    assert [%{issue_id: "issue-recorded-pr", pull_request_url: ^pr_url}] = RunStore.list_runs("default", :all)

    :ok = RunStore.clear()
    :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, pr_url, "auto/ACME-PR")
    :ok = SymphonyElixir.TicketPullRequest.mark_finished("default", pr_url, "closed")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, %{status: "success"}} = OneShot.run("ACME-PR", deps: deps(), no_retry: true)
    assert [%{issue_id: "issue-recorded-pr", pull_request_url: nil}] = RunStore.list_runs("default", :all)
  end

  test "tool progress heartbeats are not recorded in the run-store record" do
    issue = memory_issue("issue-heartbeat", "ACME-HEARTBEAT")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    deps =
      deps(%{
        start_agent_task: fn issue, recipient, _opts ->
          Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
            send(recipient, {:codex_worker_update, issue.id, AppServer.event_to_update({:tool_progress, "Bash"})})
            send(recipient, {:codex_worker_update, issue.id, AppServer.event_to_update({:agent_text, "working"})})
            send(recipient, {:codex_worker_update, issue.id, AppServer.event_to_update({:tool_progress, "Bash"})})
            :ok
          end)
        end
      })

    assert {:ok, %{status: "success", last_event: :agent_text}} =
             OneShot.run("ACME-HEARTBEAT", deps: deps, no_retry: true)

    assert [%{status: "success", last_event: :agent_text} = run] = RunStore.list_runs("default", :all)
    refute inspect(run) =~ "tool_progress"
  end

  test "tool progress heartbeats drained after a timeout are not recorded" do
    issue = memory_issue("issue-heartbeat-timeout", "ACME-HEARTBEAT-TIMEOUT")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    deps =
      deps(%{
        start_agent_task: fn _issue, _recipient, _opts ->
          Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
            Process.sleep(:infinity)
          end)
        end,
        shutdown_task: fn task, timeout ->
          send(self(), {:codex_worker_update, issue.id, AppServer.event_to_update({:agent_text, "working"})})
          send(self(), {:codex_worker_update, issue.id, AppServer.event_to_update({:tool_progress, "Bash"})})
          Task.shutdown(task, timeout)
        end
      })

    assert {:timeout, :timeout_exceeded} =
             OneShot.run("ACME-HEARTBEAT-TIMEOUT", deps: deps, timeout_ms: 10, no_retry: true)

    assert [%{status: "timeout", last_event: :agent_text} = run] = RunStore.list_runs("default", :all)
    refute inspect(run) =~ "tool_progress"
  end

  test "agent failure exhausts bounded retry attempts" do
    issue = memory_issue("issue-failure", "ACME-FAILURE")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    parent = self()

    deps =
      deps(%{
        start_agent_task: fn _issue, _recipient, opts ->
          send(parent, {:attempt, opts[:attempt]})

          Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
            {:error, :boom}
          end)
        end
      })

    assert {:error, :boom} =
             OneShot.run("ACME-FAILURE",
               deps: deps,
               max_attempts: 2,
               retry_delay_ms: 0
             )

    assert_received {:attempt, 1}
    assert_received {:attempt, 2}

    assert [
             %{status: "failure", issue_id: "issue-failure"},
             %{status: "failure", issue_id: "issue-failure"}
           ] = RunStore.list_runs("default", :all)
  end

  test "timeout kills the agent task, cleans up workspace, and records timeout" do
    issue = memory_issue("issue-timeout", "ACME-TIMEOUT")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    workspace = Path.join([Config.settings!().workspace.root, "default", "ACME-TIMEOUT"])
    File.mkdir_p!(workspace)

    deps =
      deps(%{
        start_agent_task: fn _issue, _recipient, _opts ->
          Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
            Process.sleep(:infinity)
          end)
        end,
        shutdown_task: fn task, timeout ->
          send(self(), {:worker_runtime_info, issue.id, %{workspace_path: workspace}})
          Task.shutdown(task, timeout)
        end
      })

    assert {:timeout, :timeout_exceeded} =
             OneShot.run("ACME-TIMEOUT",
               deps: deps,
               timeout_ms: 10,
               no_retry: true
             )

    refute File.exists?(workspace)
    assert [%{status: "timeout", issue_id: "issue-timeout", workspace_path: ^workspace}] = RunStore.list_runs("default", :all)
  end

  test "invalid timeout is a configuration error" do
    issue = memory_issue("issue-timeout-config", "ACME-TIMEOUT-CONFIG")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:config_error, :invalid_timeout} =
             OneShot.run("ACME-TIMEOUT-CONFIG",
               deps: deps(),
               timeout_ms: :invalid
             )
  end

  defp deps(overrides \\ %{}) do
    Map.merge(
      %{
        start_runtime: fn -> :ok end,
        fetch_issue: &Tracker.fetch_issue_by_identifier/1,
        repos: &Config.repos/0,
        settings_for_repo: &Config.settings_for_repo/1,
        ensure_verification_runtime: fn _repo_key -> :ok end,
        start_agent_task: fn _issue, _recipient, _opts ->
          Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> :ok end)
        end,
        shutdown_task: &Task.shutdown/2,
        run_store: RunStore,
        sleep: fn _ms -> :ok end,
        monotonic_time: fn -> System.monotonic_time(:millisecond) end
      },
      overrides
    )
  end

  defp memory_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "One shot #{identifier}",
      state: "Todo",
      team: %{key: "Test"},
      created_at: ~U[2026-05-20 00:00:00Z],
      updated_at: ~U[2026-05-20 00:00:00Z]
    }
  end
end
