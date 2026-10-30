defmodule SymphonyElixir.CiWaitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{CiWait, Hold}

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

    test "is nil once a CI-wait hold was set after the wait started" do
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

  describe "hold_attrs/3" do
    test "names the commit, the wait and the workflows still running, lifted by Unblock" do
      runs = [%{workflow_name: "release", url: "https://github.com/acme/app/actions/runs/1"}, %{workflow_name: "macos", id: 2}, %{workflow_name: nil}]
      attrs = CiWait.hold_attrs(%{sha: @sha, runs: runs}, DateTime.add(@now, -61 * 60, :second), @now)

      assert attrs.reason ==
               "ci_wait: CI on 26758a247155 was still running after 61 minutes (waiting since 00:44 UTC), " <>
                 "so Symphony stopped starting the epic review. " <>
                 "Still running: release (https://github.com/acme/app/actions/runs/1), macos (2), a workflow"

      assert attrs.clearing_condition == "when a person unblocks it"
      assert attrs.waits_on == %{type: CiWait.hold_type(), keys: [@sha]}
      assert Hold.unblockable?(attrs)
    end

    test "says one minute in the singular" do
      attrs = CiWait.hold_attrs(%{sha: @sha, runs: []}, DateTime.add(@now, -60, :second), @now)
      assert attrs.reason =~ "still running after 1 minute (waiting since 01:44 UTC)"
    end

    test "names the run that waits when it is not the epic review" do
      attrs = CiWait.hold_attrs(%{sha: @sha, runs: [], run: "the QA pass"}, DateTime.add(@now, -61 * 60, :second), @now)
      assert attrs.reason =~ "so Symphony stopped starting the QA pass. "
    end
  end
end

defmodule SymphonyElixir.CiWaitPauseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CiWait, Pauses}

  @sha "26758a2471558f89fc0411dcf1f81aa82c0e1dc4"
  @ticket {:ticket, "default", "issue-1"}
  @director %{kind: :person, name: "Director"}

  describe "the pause beside a CI-wait hold" do
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

      cleared = RunStore.list_ticket_events("default", "issue-1", types: ["pause.reason_cleared"])
      assert [%{payload: %{by: @director}}, %{payload: %{by: @director}}] = cleared
    end

    test "clears the pause with its last reason, and changes nothing on a ticket not paused or with no repo" do
      {:ok, _pause} = CiWait.pause("default", "issue-1", @sha)

      assert :ok = CiWait.clear_pause("default", "issue-1")
      assert {:ok, nil} = Pauses.get(@ticket)
      assert [%{payload: %{by: %{kind: :symphony}}}] = RunStore.list_ticket_events("default", "issue-1", types: ["pause.cleared"])

      assert :ok = CiWait.clear_pause("default", "issue-1")
      assert :ok = CiWait.clear_pause(nil, "issue-1")
    end
  end
end
