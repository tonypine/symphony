defmodule SymphonyElixir.SetupTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Repo.FetchLog
  alias SymphonyElixir.RetiredStates
  alias SymphonyElixir.Routing.PollLog
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.{Checks, Problem, TeamCache}
  alias SymphonyElixir.SubIssueWait

  @t1 ~U[2026-10-19 09:00:00Z]
  @t2 ~U[2026-10-19 09:15:00Z]

  # A Linear-side check: reads the teams the test names through the team cache, twice, and reports
  # one problem per team it read. A failed read makes Linear unreachable for the run.
  defmodule LinearStub do
    @behaviour SymphonyElixir.Setup.Check

    def id, do: "linear_stub"
    def title, do: "Linear stub"
    def needs_linear?, do: true

    def run(context) do
      send(Application.get_env(:symphony_elixir, :setup_test_pid), {:ran, __MODULE__})
      teams = Application.get_env(:symphony_elixir, :setup_test_teams, ["TP"])

      Enum.reduce_while(teams, [], fn team, problems ->
        with {:ok, states} <- TeamCache.states(context.team_cache, team),
             {:ok, ^states} <- TeamCache.states(context.team_cache, team),
             {:ok, _labels} <- TeamCache.labels(context.team_cache, team) do
          {:cont, problems ++ [problem(team, states)]}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end

    defp problem(team, states) do
      Problem.new(
        id: "linear_stub:#{team}",
        severity: :warning,
        category: :statuses,
        title: "#{team} has #{length(states)} states",
        consequence: "None.",
        fix: Problem.linear("create_state", team, "QA", "started")
      )
    end
  end

  # A second Linear-side check reading the same teams: the cache answers it.
  defmodule OtherLinearStub do
    @behaviour SymphonyElixir.Setup.Check

    def id, do: "other_linear_stub"
    def title, do: "Other Linear stub"
    def needs_linear?, do: true

    def run(context) do
      for team <- Application.get_env(:symphony_elixir, :setup_test_teams, ["TP"]) do
        {:ok, _states} = TeamCache.states(context.team_cache, team)
        {:ok, _labels} = TeamCache.labels(context.team_cache, team)
      end

      []
    end
  end

  defmodule FailingStub do
    @behaviour SymphonyElixir.Setup.Check

    def id, do: "failing_stub"
    def title, do: "Failing stub"
    def needs_linear?, do: false
    def run(_context), do: {:error, :no_disk}
  end

  defmodule CrashingStub do
    @behaviour SymphonyElixir.Setup.Check

    def id, do: "crashing_stub"
    def title, do: "Crashing stub"
    def needs_linear?, do: false
    def run(_context), do: raise("boom")
  end

  # A local check that says when it ran.
  defmodule LocalStub do
    @behaviour SymphonyElixir.Setup.Check

    def id, do: "local_stub"
    def title, do: "Local stub"
    def needs_linear?, do: false

    def run(_context) do
      send(Application.get_env(:symphony_elixir, :setup_test_pid), {:ran, __MODULE__})
      []
    end
  end

  # Breaks the run itself, outside `run/1`.
  defmodule BrokenStub do
    def id, do: "broken_stub"
    def needs_linear?, do: raise("broken")
  end

  # Waits for the test's `:go` before it returns, so a test can hold a run open.
  defmodule BlockingStub do
    @behaviour SymphonyElixir.Setup.Check

    def id, do: "blocking_stub"
    def title, do: "Blocking stub"
    def needs_linear?, do: false

    def run(_context) do
      send(Application.get_env(:symphony_elixir, :setup_test_pid), {:blocked, self()})

      receive do
        :go -> []
      end
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    # Earlier tests may have left failed fetches of `default` in the shared fetch log, and polls in
    # the poll log.
    FetchLog.record("default", :ok)
    :ets.delete_all_objects(PollLog)
    # So may labels, a drain report or a turned-off waiting state: each would put a problem in a
    # healthy payload.
    Application.delete_env(:symphony_elixir, :memory_tracker_labels_list)
    RetiredStates.reset_for_test()
    SubIssueWait.reset_for_test("Waiting on sub-tickets")
    Application.put_env(:symphony_elixir, :setup_test_pid, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    # Labels another test seeded and left behind would make the labels check report missing ones.
    Application.delete_env(:symphony_elixir, :memory_tracker_labels_list)
    # A managed repo has the secrets check ask `gh` whether it is signed in.
    Application.put_env(:symphony_elixir, :setup_gh_runner, fn ["auth", "status"], _opts -> {"Logged in to github.com\n", 0} end)

    Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, [
      %{id: "s1", name: "Todo", team_id: "t1", team_key: "TP"},
      %{id: "s2", name: "Todo", team_id: "t2", team_key: "OPS"}
    ])

    on_exit(fn ->
      for key <- [
            :setup_test_pid,
            :setup_test_teams,
            :memory_tracker_recipient,
            :memory_tracker_workflow_states_list,
            :memory_tracker_labels_list,
            :setup_gh_runner
          ],
          do: Application.delete_env(:symphony_elixir, key)
    end)

    :ok
  end

  defp append_symphony!(lines) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> lines)
    bump_mtime!(path)
  end

  defp bump_mtime!(path), do: File.touch!(path, System.system_time(:second) + System.unique_integer([:positive, :monotonic]))

  defp start_setup!(opts) do
    name = Module.concat(__MODULE__, "Setup#{System.unique_integer([:positive])}")
    start_supervised!({Setup, Keyword.merge([name: name, now: fn -> @t1 end], opts)})
    name
  end

  describe "check/1" do
    test "a healthy config has no problems and nothing unchecked" do
      assert %{problems: [], not_checked: [], checked_at: checked_at, linear_checked_at: checked_at} = Setup.check(now: fn -> @t1 end)
      assert checked_at == "2026-10-19T09:00:00Z"
    end

    test "a deprecated key is one warning with its path, replacement, line and a remove fix" do
      append_symphony!("auto_review:\n  enabled: true\n  acceptance_gate:\n    mode: shadow\n")
      line = Workflow.symphony_file_path() |> File.read!() |> String.split("\n") |> Enum.find_index(&(&1 == "  enabled: true"))

      assert %{problems: [mode, enabled]} = Setup.check()

      assert enabled.id == "deprecated_key:auto_review.enabled"
      assert enabled.severity == "warning"
      assert enabled.category == "keys"
      assert enabled.title =~ "auto_review.enabled"

      assert enabled.details == [
               %{label: "Key", value: "auto_review.enabled"},
               %{label: "Replacement", value: "Auto Review is retired; QA runs in the QA state"},
               %{label: "Line", value: Integer.to_string(line + 1)}
             ]

      assert enabled.fix == %{kind: "config_edit", path: "auto_review.enabled", action: "remove", value: nil}

      # Still acts while deprecated: removing it would change the review mode.
      assert mode.id == "deprecated_key:auto_review.acceptance_gate.mode"
      assert mode.consequence =~ "still works"
      assert mode.fix == %{kind: "open", target: "symphony_yml", url: nil}
    end

    test "an unknown key keeps the last good config running until the file is fixed" do
      path = Workflow.symphony_file_path()
      good = File.read!(path)
      assert {:ok, _system} = Config.system()

      log =
        capture_log(fn ->
          append_symphony!("pull_request:\n  enabled: true\n")
          assert {:ok, _system} = Config.system()
          assert %{problems: [problem]} = Setup.check()

          assert problem.id == "failed_reload:#{Path.expand(path)}"
          assert problem.severity == "error"
          assert problem.title =~ "unknown symphony.yml key `pull_request`"
          assert problem.consequence =~ "still running the settings it loaded before"
          assert %{label: "Key", value: "pull_request"} in problem.details
          assert %{label: "Line", value: Integer.to_string(length(String.split(good, "\n")))} in problem.details
          assert Enum.any?(problem.details, &(&1.label == "Stale since"))
          assert problem.fix == %{kind: "open", target: "symphony_yml", url: nil}
        end)

      assert log =~ "keeping last known good value"

      File.write!(path, good)
      bump_mtime!(path)
      assert %{problems: []} = Setup.check()
    end

    test "a symphony.yml that no longer parses names its line" do
      assert {:ok, _system} = Config.system()

      capture_log(fn ->
        append_symphony!("broken: [x\n")
        assert %{problems: [problem]} = Setup.check()
        assert problem.title =~ "Failed to parse symphony.yml"
        assert Enum.any?(problem.details, &(&1.label == "Line"))
      end)
    end

    test "a removed symphony.yml keeps the last good config and says it can't be read" do
      path = Workflow.symphony_file_path()
      assert {:ok, _system} = Config.system()
      good = File.read!(path)
      File.rm!(path)

      capture_log(fn ->
        assert %{problems: [problem]} = Setup.check()
        assert problem.title =~ "the file can't be read"
        refute Enum.any?(problem.details, &(&1.label in ["Key", "Line"]))
      end)

      File.write!(path, good)
    end

    test "a repo WORKFLOW.md edit the schema rejects names the repo" do
      workflow = Workflow.workflow_file_path()
      assert {:ok, _workflow} = Config.workflow_for_repo("default")

      capture_log(fn ->
        File.write!(workflow, "---\nnot_a_key: 1\n---\nPrompt\n")
        bump_mtime!(workflow)
        assert {:ok, _workflow} = Config.workflow_for_repo("default")
        assert %{problems: [problem]} = Setup.check()
        assert problem.repos == ["default"]
        assert problem.title =~ "WORKFLOW.md of default"
        assert problem.fix.target == "repos"
      end)
    end

    test "a WORKFLOW.md that fails to load from its base ref is an error naming the repo" do
      workflow = Workflow.workflow_file_path()
      File.mkdir_p!(Path.join(Path.dirname(workflow), ".git"))
      ref_error = Path.join([SymphonyElixir.Paths.state_root(), "workflows", "default", "WORKFLOW.md.ref-error"])
      File.mkdir_p!(Path.dirname(ref_error))
      File.write!(ref_error, :erlang.term_to_binary({:workflow_ref_not_found, ["origin/main"]}))
      on_exit(fn -> File.rm_rf(Path.dirname(ref_error)) end)

      assert %{problems: [problem]} = Setup.check(checks: [Checks.WorkflowRef])
      assert problem.id == "#{Checks.WorkflowRef.id()}:default"
      assert problem.severity == "error"
      assert problem.repos == ["default"]
      assert %{label: "Reason", value: "no origin/main ref in the checkout"} in problem.details
    end

    test "a rejected edit names no key when the reason has none, and no line once the file is gone" do
      workflow = Workflow.workflow_file_path()
      assert {:ok, _workflow} = Config.workflow_for_repo("default")

      # A workflow no configured repo reads is not reported.
      other = Path.join(Path.dirname(workflow), "OTHER.md")
      File.write!(other, "Prompt\n")
      assert {:ok, _workflow} = Cache.get_workflow(other)

      capture_log(fn ->
        File.write!(other, "---\nnot_a_key: 1\n---\nPrompt\n")
        bump_mtime!(other)
        assert {:ok, _workflow, [stale: true]} = Cache.get_workflow(other)

        # A reason that names no key.
        symphony = Workflow.symphony_file_path()
        good = File.read!(symphony)
        File.write!(symphony, "repositories: []\n")
        bump_mtime!(symphony)
        assert %{problems: [problem]} = Setup.check()
        assert problem.title =~ "repositories can't be blank"
        refute Enum.any?(problem.details, &(&1.label == "Key"))
        File.write!(symphony, good)
        bump_mtime!(symphony)

        File.write!(workflow, "---\nnot_a_key: 1\n---\nPrompt\n")
        bump_mtime!(workflow)
        assert {:ok, _workflow, [stale: true]} = Cache.get_workflow(workflow)
        File.rm!(workflow)
        assert %{problems: [problem]} = Setup.check()
        assert Enum.any?(problem.details, &(&1.label == "Key"))
        refute Enum.any?(problem.details, &(&1.label == "Line"))
      end)
    end

    test "every check names itself, and only the routing, teams, labels and statuses checks read Linear" do
      # Each check's id starts each of its problems' ids.
      assert Enum.map(Setup.checks(), & &1.id()) == [
               "deprecated_key",
               "failed_reload",
               "workflow_ref",
               "workflow_fetch",
               "uncloned_repo",
               "routing",
               "secret",
               "teams",
               "labels",
               "deprecated_label",
               "hold_drift",
               "statuses",
               "status_use"
             ]

      for check <- Setup.checks() do
        assert is_binary(check.id()) and is_binary(check.title())
        assert check.needs_linear?() == check in [Checks.Routing, Checks.Teams, Checks.Labels, Checks.Statuses]
      end
    end

    test "a fetch that keeps failing is a warning" do
      failure = {:error, {:git_failed, ["fetch", "origin"], 128, "fatal: unreachable"}}

      FetchLog.record("default", failure, @t1)
      FetchLog.record("default", failure, @t2)
      assert %{problems: []} = Setup.check()

      FetchLog.record("default", failure, @t2)
      assert %{problems: [problem]} = Setup.check()
      assert problem.id == "#{Checks.WorkflowFetch.id()}:default"
      assert problem.severity == "warning"
      assert %{label: "Failed fetches in a row", value: "3"} in problem.details
      assert %{label: "Failing since", value: "2026-10-19T09:00:00Z"} in problem.details
      assert %{label: "Last error", value: "git fetch origin exited with status 128: fatal: unreachable"} in problem.details

      FetchLog.record("default", :ok)
      assert %{problems: []} = Setup.check()
    end

    test "a managed repo Symphony has not cloned yet is a warning" do
      path = Workflow.symphony_file_path()

      File.write!(
        path,
        String.replace(File.read!(path), ~r/^repositories: .*$/m, ~s(repositories: [{"key": "app", "route": {"team": "Test"}, "workspace": {"source": "acme/app"}}]))
      )

      Cache.clear()

      assert %{problems: [problem]} = Setup.check()
      assert problem.id == "uncloned_repo:app"
      assert problem.consequence =~ "Symphony clones acme/app into"
    end

    test "without a Linear API key the Linear-side checks are not checked, and the secrets check reports the key" do
      previous = System.get_env("LINEAR_API_KEY")
      System.delete_env("LINEAR_API_KEY")
      on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)
      write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

      assert %{problems: [%{id: "secret:LINEAR_API_KEY"}], not_checked: [not_checked, routing, %{id: "teams"}, %{id: "labels"}, %{id: "statuses"}]} =
               Setup.check(checks: [LinearStub | Setup.checks()])

      assert not_checked.id == "linear_stub"
      assert not_checked.reason =~ "No Linear API key"
      assert routing.id == "routing"
      refute_received {:ran, LinearStub}
    end

    test "a check that fails or crashes is listed as not checked" do
      capture_log(fn ->
        assert %{problems: [], not_checked: [failing, crashing]} = Setup.check(checks: [FailingStub, CrashingStub])
        assert failing.reason == "This check failed: :no_disk"
        assert crashing.reason == "This check failed: boom"
      end)
    end

    test "with Linear unreachable and no earlier run, the Linear-side checks are not checked" do
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, {:error, :timeout})

      assert %{problems: [], not_checked: [%{id: "linear_stub", reason: reason}], linear_checked_at: nil} =
               Setup.check(checks: [LinearStub])

      assert reason =~ "couldn't reach Linear"
    end

    test "a config that doesn't load gives the config checks nothing to read" do
      File.write!(Workflow.symphony_file_path(), "pull_request: 1\n")
      Cache.clear()

      # Nor the routing and teams checks: they have no repos to read.
      assert %{problems: [], not_checked: []} = Setup.check(linear_api_key?: true)
    end
  end

  describe "the server" do
    test "keeps the last Linear-side problems and their time when the tracker errors" do
      clock = start_supervised!({Agent, fn -> @t1 end})
      server = start_setup!(checks: [LinearStub], now: fn -> Agent.get(clock, & &1) end)

      assert %{problems: [%{id: "linear_stub:TP"}], linear_checked_at: "2026-10-19T09:00:00Z"} = Setup.refresh(server)

      Agent.update(clock, fn _t1 -> @t2 end)
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, {:error, :timeout})

      assert %{problems: [%{id: "linear_stub:TP"}], not_checked: [], checked_at: "2026-10-19T09:15:00Z", linear_checked_at: "2026-10-19T09:00:00Z"} =
               Setup.refresh(server)

      assert Setup.payload(server) == Setup.refresh(server)
    end

    test "a refresh asks the tracker once per team per run" do
      Application.put_env(:symphony_elixir, :setup_test_teams, ["TP", "OPS"])
      server = start_setup!(checks: [LinearStub, OtherLinearStub])

      for _run <- 1..2 do
        assert %{problems: [%{id: "linear_stub:TP"}, %{id: "linear_stub:OPS"}]} = Setup.refresh(server)
      end

      # The startup run and the two refreshes.
      for team <- ["TP", "OPS"], event <- [:memory_tracker_team_workflow_states, :memory_tracker_team_labels] do
        for _run <- 1..3, do: assert_received({^event, ^team})
        refute_received {^event, ^team}
      end
    end

    test "a run between refreshes reads the cached teams, and a fix empties the cache" do
      server = start_setup!(checks: [LinearStub], reload_debounce_ms: 0)
      Setup.refresh(server)
      flush_tracker_events()

      :telemetry.execute(Cache.reloaded_event(), %{count: 1}, %{path: Workflow.symphony_file_path()})
      assert_receive {:ran, LinearStub}
      await_idle(server, 1_000)
      refute_received {:memory_tracker_team_workflow_states, "TP"}

      assert :ok = Setup.invalidate_team_cache(server)
      Setup.refresh(server)
      assert_received {:memory_tracker_team_workflow_states, "TP"}
    end

    test "runs again every interval" do
      start_setup!(checks: [LinearStub], interval_ms: 1)

      for _run <- 1..3, do: assert_receive({:ran, LinearStub})
    end

    test "an edit a config read finds runs the checks again, with no file watcher" do
      # TestSupport runs the config cache without a watcher, as the escript does: only reads find edits.
      path = Workflow.symphony_file_path()
      good = File.read!(path)
      server = start_setup!(checks: [Checks.DeprecatedKeys, Checks.FailedReload, LocalStub], reload_debounce_ms: 0)
      assert_receive {:ran, LocalStub}
      await_idle(server, 1_000)
      assert %{problems: []} = Setup.payload(server)

      # The orchestrator's poll reads the config; here the test does.
      append_symphony!("auto_review:\n  enabled: true\n")
      assert {:ok, _system} = Config.system()
      assert_receive {:ran, LocalStub}
      await_idle(server, 1_000)
      assert %{problems: [%{id: "deprecated_key:auto_review.enabled"}]} = Setup.payload(server)

      File.write!(path, good)
      bump_mtime!(path)
      assert {:ok, _system} = Config.system()
      assert_receive {:ran, LocalStub}
      await_idle(server, 1_000)
      assert %{problems: []} = Setup.payload(server)

      capture_log(fn ->
        append_symphony!("pull_request:\n  enabled: true\n")
        assert {:ok, _system} = Config.system()
        assert_receive {:ran, LocalStub}
        await_idle(server, 1_000)
      end)

      assert %{problems: [%{id: "failed_reload:" <> _path, title: title}]} = Setup.payload(server)
      assert title =~ "pull_request"

      File.write!(path, good)
      bump_mtime!(path)
      assert {:ok, _system} = Config.system()
      assert_receive {:ran, LocalStub}
      await_idle(server, 1_000)
      assert %{problems: []} = Setup.payload(server)
    end

    test "a config reload runs the checks once, however many events it sends" do
      server = start_setup!(checks: [BlockingStub], reload_debounce_ms: 0)
      assert_receive {:blocked, task}
      send(task, :go)
      await_idle(server, 1_000)

      # Both events wait in the mailbox before the first one starts the debounce timer.
      :sys.suspend(server)
      send(server, {:config_reloaded, "a"})
      send(server, {:config_reloaded, "b"})
      :sys.resume(server)
      assert_receive {:blocked, task}
      send(task, :go)
      await_idle(server, 1_000)
      refute_received {:blocked, _task}
    end

    test "a refresh during a run waits for a run of its own" do
      server = start_setup!(checks: [BlockingStub])
      assert_receive {:blocked, first}
      assert %{checked_at: nil, problems: []} = Setup.payload(server)

      refresh = Task.async(fn -> Setup.refresh(server) end)
      wait_until_queued(server, 1_000)

      send(first, :go)
      assert_receive {:blocked, second}
      refute Task.yield(refresh, 0)
      send(second, :go)
      assert %{checked_at: "2026-10-19T09:00:00Z"} = Task.await(refresh)
    end

    test "a run that crashes keeps the last result and answers the refresh" do
      clock = start_supervised!({Agent, fn -> @t1 end})
      server = start_setup!(checks: [], now: fn -> Agent.get(clock, & &1) end)
      assert %{checked_at: "2026-10-19T09:00:00Z"} = Setup.refresh(server)

      :sys.replace_state(server, fn state -> put_in(state.opts[:checks], [BrokenStub]) end)
      Agent.update(clock, fn _t1 -> @t2 end)

      log = capture_log(fn -> assert %{checked_at: "2026-10-19T09:00:00Z"} = Setup.refresh(server) end)
      assert log =~ "Setup checks crashed"
    end

    test "ignores unknown messages and stops cleanly" do
      server = start_setup!(checks: [])
      send(server, :unknown)
      assert %{problems: []} = Setup.payload(server)
      assert :ok = stop_supervised(Setup)
    end

    test "without a server, payload and refresh run the checks here" do
      assert %{problems: [], checked_at: checked_at} = Setup.payload(:no_setup_server)
      assert is_binary(checked_at)
      assert %{problems: []} = Setup.refresh(:no_setup_server)
    end
  end

  defp flush_tracker_events do
    receive do
      {:memory_tracker_team_workflow_states, _team} -> flush_tracker_events()
      {:memory_tracker_team_labels, _team} -> flush_tracker_events()
      {:ran, _check} -> flush_tracker_events()
    after
      0 -> :ok
    end
  end

  # A run's task sends its result to the server before it exits, so once it is down the next state
  # read comes after the server took the result. A pending reload starts one more run.
  defp await_idle(server, attempts) when attempts > 0 do
    case :sys.get_state(server) do
      %{task: %Task{pid: pid}} ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        await_idle(server, attempts - 1)

      %{reload_timer: timer} when is_reference(timer) ->
        await_idle(server, attempts - 1)

      _idle ->
        :ok
    end
  end

  defp wait_until_queued(server, attempts) when attempts > 0 do
    if :sys.get_state(server).queued == [], do: wait_until_queued(server, attempts - 1), else: :ok
  end
end
