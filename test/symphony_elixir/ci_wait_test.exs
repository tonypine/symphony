defmodule SymphonyElixir.CiWaitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CiWait

  @now ~U[2026-10-15 01:45:00Z]
  @sha "26758a2471558f89fc0411dcf1f81aa82c0e1dc4"

  defp signal(name, minutes_ago, details \\ %{}), do: %{name: name, details: details, at: DateTime.add(@now, -minutes_ago * 60, :second)}

  describe "since/2" do
    test "is when the newest wait on the commit started" do
      signals = [signal("handoff", 1), signal("ci_wait_started", 30, %{sha: @sha}), signal("ci_wait_started", 90, %{sha: @sha})]
      assert CiWait.since(signals, @sha) == DateTime.add(@now, -30 * 60, :second)
    end

    test "is nil when no wait was recorded" do
      assert CiWait.since([], @sha) == nil
      assert CiWait.since([signal("handoff", 1)], @sha) == nil
    end

    test "is nil when the newest wait was on another commit" do
      signals = [signal("ci_wait_started", 5, %{sha: "other"}), signal("ci_wait_started", 90, %{sha: @sha})]
      assert CiWait.since(signals, @sha) == nil
    end

    test "is nil once a wait past the limit paused the ticket after the wait started" do
      signals = [signal("ci_wait", 5, %{sha: @sha}), signal("ci_wait_started", 70, %{sha: @sha})]
      assert CiWait.since(signals, @sha) == nil
    end
  end

  describe "over?/2" do
    test "is true once the wait has lasted the limit" do
      assert CiWait.limit_ms() == 3_600_000
      refute CiWait.over?(DateTime.add(@now, -59 * 60, :second), @now)
      assert CiWait.over?(DateTime.add(@now, -60 * 60, :second), @now)
    end
  end

  describe "describe/3" do
    test "names the commit, the wait and the workflows still running" do
      runs = [%{workflow_name: "release", url: "https://github.com/acme/app/actions/runs/1"}, %{workflow_name: "macos", id: 2}, %{workflow_name: nil}]

      assert CiWait.describe(%{sha: @sha, runs: runs}, DateTime.add(@now, -61 * 60, :second), @now) ==
               "ci_wait: CI on 26758a247155 was still running after 61 minutes (waiting since 00:44 UTC), " <>
                 "so Symphony stopped starting the epic review. " <>
                 "Still running: release (https://github.com/acme/app/actions/runs/1), macos (2), a workflow"

      assert CiWait.signal() == "ci_wait"
    end

    test "says one minute in the singular" do
      assert CiWait.describe(%{sha: @sha, runs: []}, DateTime.add(@now, -60, :second), @now) =~ "still running after 1 minute (waiting since 01:44 UTC)"
    end

    test "names the run that waits when it is not the epic review" do
      assert CiWait.describe(%{sha: @sha, runs: [], run: "the QA pass"}, DateTime.add(@now, -61 * 60, :second), @now) =~ "so Symphony stopped starting the QA pass. "
    end
  end
end

defmodule SymphonyElixir.CiWaitPauseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CiWait, Pauses}

  @sha "26758a2471558f89fc0411dcf1f81aa82c0e1dc4"
  @ticket {:ticket, "default", "issue-1"}
  @director %{kind: :person, name: "Director"}

  describe "the pause of a wait for CI past the limit" do
    test "waits for CI on the commit, once however often it is set, and the Director may release it" do
      assert CiWait.reason(@sha) == %{
               kind: :environment,
               waits_on: %{condition: "ci_wait:26758a247155"},
               text: "Waiting for CI on 26758a247155 to finish",
               releasable: true
             }

      assert {:ok, _pause} = CiWait.pause("default", "issue-1", @sha)
      assert {:ok, _pause} = CiWait.pause("default", "issue-1", @sha)

      assert {:ok, %{reasons: [%{set_by: %{kind: :rule, name: "CI wait"}, releasable: true} = reason]}} = Pauses.get(@ticket)
      assert Pauses.why(@ticket) == ["Waiting for CI on 26758a247155 to finish"]
      assert CiWait.reason?(reason)
    end

    test "tells its live reason from the backfill's and from any other" do
      refute CiWait.reason?(%{kind: :environment, waits_on: %{condition: "ci_wait: CI on 26758a247155 was still running after 61 minutes"}})
      refute CiWait.reason?(%{kind: :environment, waits_on: %{condition: "self_heal:worker_host"}})
      refute CiWait.reason?(Pauses.ticket_reason(:dependency, "TP-1"))
    end

    test "CI settling clears its reasons, the backfill's too, by who says so, and leaves every other reason" do
      backfilled = %{kind: :environment, waits_on: %{condition: "ci_wait: CI on abc was still running"}, text: "ci_wait: CI on abc was still running", releasable: true}
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-9"))
      {:ok, _pause} = Pauses.set(@ticket, backfilled, backfilled: true)
      {:ok, _pause} = CiWait.pause("default", "issue-1", @sha)
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :environment, waits_on: %{condition: "self_heal:worker_host"}})

      assert :ok = CiWait.clear_pause("default", "issue-1", @director)
      assert {:ok, %{reasons: [%{kind: :ticket}, %{waits_on: %{condition: "self_heal:worker_host"}}]}} = Pauses.get(@ticket)

      cleared = RunStore.list_ticket_events("issue-1", types: ["pause.reason_cleared"])
      assert [%{payload: %{by: @director}}, %{payload: %{by: @director}}] = cleared
    end

    test "clears the pause with its last reason, and changes nothing on a ticket not paused or with no repo" do
      {:ok, _pause} = CiWait.pause("default", "issue-1", @sha)

      assert :ok = CiWait.clear_pause("default", "issue-1")
      assert {:ok, nil} = Pauses.get(@ticket)
      assert [%{payload: %{by: %{kind: :symphony}}}] = RunStore.list_ticket_events("issue-1", types: ["pause.cleared"])

      assert :ok = CiWait.clear_pause("default", "issue-1")
      assert :ok = CiWait.clear_pause(nil, "issue-1")
    end
  end

  defmodule DownStore do
    def list_all_ticket_states, do: {:error, :store_down}
  end

  defmodule StillRunning do
    def settled?(sha, repo_key, _opts) do
      send(self(), {:settled?, sha, repo_key})
      false
    end
  end

  defmodule AllDone do
    def settled?(_sha, _repo_key, _opts), do: true
  end

  defmodule RefusingPauses do
    def clear_reasons(_subject, _match, _opts), do: {:error, :store_down}
  end

  describe "finished/2: CI completing on the commit lifts the pause (TP-1376)" do
    test "lifts the CI wait of every ticket paused on the commit, by the CI-wait rule, and frees it to dispatch" do
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()
      {:ok, _pause} = CiWait.pause("default", "issue-1", @sha)
      {:ok, _pause} = CiWait.pause("other", "issue-2", @sha)
      {:ok, _pause} = Pauses.set({:ticket, "other", "issue-2"}, Pauses.ticket_reason(:dependency, "TP-9"))
      assert_receive {:ticket_record, "default", "issue-1", :changed, [:pause]}

      assert Enum.sort(CiWait.finished(String.upcase(@sha))) == ["issue-1", "issue-2"]

      assert {:ok, nil} = Pauses.get(@ticket)
      assert_receive {:ticket_record, "default", "issue-1", :changed, [:pause]}
      assert [%{payload: %{by: %{kind: :rule, name: "CI wait"}}}] = RunStore.list_ticket_events("issue-1", types: ["pause.cleared"])
      assert {:ok, %{reasons: [%{kind: :ticket}]}} = Pauses.get({:ticket, "other", "issue-2"})
    end

    test "a completion on another commit changes nothing" do
      {:ok, _pause} = CiWait.pause("default", "issue-1", @sha)
      backfilled = %{kind: :environment, waits_on: %{condition: "ci_wait: CI on 26758a247155 was still running"}, text: "ci_wait: CI on 26758a247155 was still running", releasable: true}
      {:ok, _pause} = Pauses.set({:ticket, "default", "issue-3"}, backfilled, backfilled: true)

      assert CiWait.finished("080052c11496888fa903ce619291821de45eaa7a2") == []
      assert CiWait.finished(@sha) == ["issue-1"]
      assert Pauses.paused?({:ticket, "default", "issue-3"})
      assert CiWait.finished(nil) == []
      assert CiWait.finished("") == []
    end

    test "Unblock still lifts it before CI completes" do
      {:ok, _pause} = CiWait.pause("default", "issue-1", @sha)
      assert :ok = CiWait.clear_pause("default", "issue-1", @director)
      assert {:ok, nil} = Pauses.get(@ticket)
      assert CiWait.finished(@sha) == []
    end

    test "an epic waiting before dispatch is lifted only once no workflow run on the commit is still going (TP-1476)" do
      reason = SymphonyElixir.EpicReview.MainCi.reason("main", @sha, [%{workflow_name: "release"}])
      {:ok, _pause} = Pauses.set(@ticket, reason, set_by: %{kind: :rule, name: "CI wait"})

      assert CiWait.finished(@sha, main_ci: StillRunning) == []
      assert_received {:settled?, @sha, "default"}
      assert Pauses.paused?(@ticket)

      assert CiWait.finished(@sha, main_ci: AllDone) == ["issue-1"]
      assert {:ok, nil} = Pauses.get(@ticket)
    end

    test "a store that can't be read lifts nothing, and a pause that can't be cleared is logged" do
      assert CiWait.finished(@sha, run_store: DownStore) == []

      {:ok, _pause} = CiWait.pause("default", "issue-1", @sha)
      log = ExUnit.CaptureLog.capture_log(fn -> assert CiWait.finished(@sha, pauses: RefusingPauses) == [] end)
      assert log =~ "the CI wait of issue_id=issue-1 could not be lifted: :store_down"
      assert Pauses.paused?(@ticket)
    end
  end
end
