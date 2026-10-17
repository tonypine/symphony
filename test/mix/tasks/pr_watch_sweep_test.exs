defmodule Mix.Tasks.PrWatch.SweepTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.PrWatch.Sweep, as: SweepTask

  @sample Path.expand("../../fixtures/pr_watch/sample.log", __DIR__)

  defmodule FakeControlClient do
    def state(_opts), do: Application.fetch_env!(:symphony_elixir, :pr_watch_sweep_test_state)
  end

  setup do
    Mix.Task.reenable("pr_watch.sweep")
    root = Path.join(System.tmp_dir!(), "pr-watch-sweep-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:symphony_elixir, :logs_root_override)
    Application.put_env(:symphony_elixir, :control_client, FakeControlClient)

    on_exit(fn ->
      File.rm_rf(root)
      Application.delete_env(:symphony_elixir, :control_client)
      Application.delete_env(:symphony_elixir, :pr_watch_sweep_test_state)

      if previous_root,
        do: Application.put_env(:symphony_elixir, :logs_root_override, previous_root),
        else: Application.delete_env(:symphony_elixir, :logs_root_override)
    end)

    %{root: root}
  end

  defp sweep(args) do
    Mix.Task.reenable("pr_watch.sweep")
    capture_io(fn -> SweepTask.run(args) end)
  end

  test "the sample log: one line per rule with its counts, and no rule: 0" do
    assert sweep(["--log", @sample]) ==
             """
             PR watch sweep of sample.log: 14 skipped dispatches, 2 silent waits
             R14a:                      2 (skipped 2, silent 0)
             R24:                       2 (skipped 2, silent 0)
             R27:                       1 (skipped 0, silent 1)
             R32:                       2 (skipped 1, silent 1)
             gate: Linear rate limit:   1 (skipped 1, silent 0)
             gate: blocked by a ticket: 1 (skipped 1, silent 0)
             gate: hold:                1 (skipped 1, silent 0)
             gate: paused:              1 (skipped 1, silent 0)
             gate: priority filter:     1 (skipped 1, silent 0)
             gate: run active:          1 (skipped 1, silent 0)
             gate: usage limit:         1 (skipped 1, silent 0)
             landing rows (R28-R33):    1 (skipped 1, silent 0)
             watcher: first read:       1 (skipped 1, silent 0)
             no rule: 0
             """
  end

  test "--since counts the recent lines only, and a line no rule covers is listed", %{root: root} do
    path = Path.join(root, "saved.log")
    recent = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    old = DateTime.utc_now() |> DateTime.add(-8 * 86_400, :second) |> DateTime.to_iso8601()

    File.write!(path, """
    #{old} debug: Skipping dispatch: issue_id=a1 issue_identifier=TP-1 state="Todo"; already running
    #{recent} debug: Skipping dispatch: issue_id=a2 issue_identifier=TP-2 state="QA"; something new
    """)

    output = sweep(["--log", path, "--since", "7d"])
    assert output =~ "PR watch sweep of saved.log since "
    assert output =~ ": 1 skipped dispatches, 0 silent waits"
    refute output =~ "gate: run active"
    assert output =~ "no rule: 1\n  Skipping dispatch: issue_id=a2 issue_identifier=TP-2 state=\"QA\"; something new\n"

    for since <- ["12h", "30m"], do: assert(sweep(["--log", path, "--since", since]) =~ "no rule: 1")
  end

  test "without --log it sweeps this host's log files, rotated ones and a release's, and the silent waits listed now", %{root: root} do
    Application.put_env(:symphony_elixir, :logs_root_override, root)
    File.mkdir_p!(Path.join(root, "release"))
    File.write!(Path.join(root, "symphony.log.1"), "2026-10-15T10:00:00Z debug: Skipping dispatch: issue_id=a1 issue_identifier=TP-1 state=\"Todo\"; already running\n")
    File.write!(Path.join([root, "release", "symphony.log"]), "2026-10-15T10:00:00Z debug: Skipping dispatch: issue_id=a2 issue_identifier=TP-2 state=\"Todo\"; already running\n")
    File.write!(Path.join(root, "symphony.log.idx"), "binary index")

    Application.put_env(
      :symphony_elixir,
      :pr_watch_sweep_test_state,
      {:ok, %{"silent_waits" => [%{"identifier" => "TP-3", "since" => "2026-10-16T09:00:00Z", "rule" => "R27"}]}}
    )

    output = sweep([])
    assert output =~ "PR watch sweep of symphony.log.1, symphony.log and the running Symphony's run store: 2 skipped dispatches, 1 silent waits"
    assert output =~ "gate: run active: 2"
    assert output =~ "R27:              1 (skipped 0, silent 1)"

    # A state with no silent waits lists none.
    Application.put_env(:symphony_elixir, :pr_watch_sweep_test_state, {:ok, %{}})
    assert sweep([]) =~ "2 skipped dispatches, 0 silent waits"
  end

  test "without a log or a running Symphony it says so and counts nothing", %{root: root} do
    Application.put_env(:symphony_elixir, :logs_root_override, root)
    Application.put_env(:symphony_elixir, :pr_watch_sweep_test_state, {:error, {:connection_failed, :econnrefused}})

    output = sweep([])
    assert output =~ "No Symphony log under #{root}"
    assert output =~ "The running Symphony's run store couldn't be read ({:error, {:connection_failed, :econnrefused}}): silent waits come from the log only"
    assert output =~ "PR watch sweep of no log: 0 skipped dispatches, 0 silent waits\nno rule: 0\n"
  end

  test "prints help, and refuses an invalid option, --since or log file" do
    assert sweep(["--help"]) =~ "mix pr_watch.sweep [--since 7d] [--log PATH]..."
    assert_raise Mix.Error, ~r/Invalid option/, fn -> sweep(["--wat"]) end
    assert_raise Mix.Error, ~r/Invalid --since "7w"/, fn -> sweep(["--log", @sample, "--since", "7w"]) end
    assert_raise Mix.Error, ~r/No log file at nowhere.log/, fn -> sweep(["--log", "nowhere.log"]) end
  end
end
