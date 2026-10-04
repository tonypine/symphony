defmodule SymphonyElixir.AcceptanceGate.RunnerTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.AcceptanceGate
  alias SymphonyElixir.AcceptanceGate.{Context, Runner}

  @sha "feedface00112233445566778899aabbccddeeff"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true},
      auto_review: %{enabled: true}
    )

    settings = put_in(Config.settings!().auto_review.acceptance_gate.max_concurrent, 1)
    test_pid = self()

    run_fun = fn job, opts ->
      send(test_pid, {:gate_started, job.issue.id, self(), opts})

      receive do
        :finish -> :ok
        :crash -> exit(:boom)
      end
    end

    name = :"gate_runner_#{System.unique_integer([:positive])}"
    %{settings: settings, run_fun: run_fun, name: name}
  end

  defp job(settings, id, attrs \\ %{}) do
    Map.merge(
      %{
        issue: %{id: id, identifier: "TP-#{id}"},
        record: %{workspace_path: "/workspaces/symphony/#{id}", repo_key: "symphony"},
        sha: @sha,
        settings: settings
      },
      attrs
    )
  end

  test "runs one pass per issue up to max_concurrent and forgets finished passes", %{settings: settings, run_fun: run_fun, name: name} do
    start_supervised!({Runner, name: name, run_fun: run_fun})

    assert :started = Runner.request(job(settings, "a"), gate_runner_server: name, tracker: :fake)
    assert_receive {:gate_started, "a", pass_pid, [tracker: :fake]}
    assert :running = Runner.request(job(settings, "a"), gate_runner_server: name)
    assert :busy = Runner.request(job(settings, "b"), gate_runner_server: name)

    assert Runner.workspaces(name) == [
             "/workspaces/symphony/a",
             Context.worktree_path(settings, "symphony", "TP-a", @sha),
             AcceptanceGate.worktree_path(settings, "symphony", "TP-a", @sha)
           ]

    assert %{running: [running], queued: [%{issue_id: "b", forced: false}]} = Runner.snapshot(name)
    assert running == %{issue_id: "a", identifier: "TP-a", sha: @sha, forced: false}

    send(pass_pid, :finish)
    wait_until(fn -> Runner.snapshot(name).running == [] end)

    assert :started = Runner.request(job(settings, "b"), gate_runner_server: name)
    assert_receive {:gate_started, "b", crashing_pid, []}

    log =
      capture_log(fn ->
        send(crashing_pid, :crash)
        wait_until(fn -> Runner.snapshot(name).running == [] end)
      end)

    assert log =~ "Acceptance gate pass crashed issue_id=b sha=#{@sha}: :boom"
    send(name, :unrelated)
    send(name, {:DOWN, make_ref(), :process, self(), :normal})
    assert %{running: [], queued: []} = Runner.snapshot(name)
  end

  test "a queued forced request takes the next free slot", %{settings: settings, run_fun: run_fun, name: name} do
    start_supervised!({Runner, name: name, run_fun: run_fun})

    assert :started = Runner.request(job(settings, "a"), gate_runner_server: name)
    assert_receive {:gate_started, "a", pass_pid, _opts}
    assert :busy = Runner.request(job(settings, "normal"), gate_runner_server: name)
    assert :busy = Runner.request(job(settings, "forced", %{forced: true}), gate_runner_server: name)
    assert %{queued: [%{issue_id: "forced", forced: true}, %{issue_id: "normal"}]} = Runner.snapshot(name)

    send(pass_pid, :finish)
    wait_until(fn -> Runner.snapshot(name).running == [] end)

    # The free slot is held for the forced ticket, which takes it on its next request.
    assert :busy = Runner.request(job(settings, "normal"), gate_runner_server: name)
    assert :started = Runner.request(job(settings, "forced", %{forced: true}), gate_runner_server: name)
    assert %{running: [%{issue_id: "forced", forced: true}]} = Runner.snapshot(name)
  end

  test "a forced request that stopped asking and an expired queue entry hold nothing", %{settings: settings, run_fun: run_fun, name: name} do
    start_supervised!({Runner, name: name, run_fun: run_fun, forced_hold_ms: 0, queued_ttl_ms: 0})

    assert :started = Runner.request(job(settings, "a"), gate_runner_server: name)
    assert_receive {:gate_started, "a", pass_pid, _opts}
    assert :busy = Runner.request(job(settings, "forced", %{forced: true}), gate_runner_server: name)
    assert %{queued: []} = Runner.snapshot(name)
    send(pass_pid, :finish)
    wait_until(fn -> Runner.snapshot(name).running == [] end)

    assert :started = Runner.request(job(settings, "normal"), gate_runner_server: name)
  end

  test "the forced hold defaults to two CI poll intervals", %{settings: settings, run_fun: run_fun, name: name} do
    start_supervised!({Runner, name: name, run_fun: run_fun})
    settings = %{settings | ci: %{settings.ci | poll_interval_ms: nil}, pr_review: %{settings.pr_review | poll_interval_ms: nil}}

    assert :started = Runner.request(job(settings, "a"), gate_runner_server: name)
    assert_receive {:gate_started, "a", pass_pid, _opts}
    assert :busy = Runner.request(job(settings, "forced", %{forced: true}), gate_runner_server: name)
    send(pass_pid, :finish)
    wait_until(fn -> Runner.snapshot(name).running == [] end)
    assert :busy = Runner.request(job(settings, "normal"), gate_runner_server: name)
  end

  test "waits on the gate agent's usage limit, and reports a missing runner or a refused task", %{settings: settings, name: name} do
    on_exit(fn -> RunStore.put_usage_limits(%{}) end)
    resume_at = DateTime.add(DateTime.utc_now(), 3600)
    :ok = RunStore.put_usage_limits(%{{"anthropic", :all} => %{provider: "anthropic", scope: :all, resume_at: resume_at}})
    claude = put_in(settings.auto_review.acceptance_gate.kind, "claude")
    codex = put_in(settings.auto_review.acceptance_gate.kind, "codex")

    assert :usage_limited = Runner.request(job(claude, "a"), gate_runner_server: name)
    assert {:error, :gate_runner_unavailable} = Runner.request(job(codex, "a"), gate_runner_server: name)
    assert Runner.workspaces(name) == []
    assert Runner.snapshot(name) == %{running: [], queued: []}

    supervisor = start_supervised!({Task.Supervisor, max_children: 0})
    start_supervised!({Runner, name: name, task_supervisor: supervisor})
    assert {:error, :max_children} = Runner.request(job(codex, "a"), gate_runner_server: name)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      true ->
        flunk("condition not met")
    end
  end
end
