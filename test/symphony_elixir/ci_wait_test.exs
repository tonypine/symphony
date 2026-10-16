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
