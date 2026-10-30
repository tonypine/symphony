defmodule SymphonyElixir.PrWatch.SweepTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrWatch.Sweep

  @stamp "2026-10-15T10:00:00.000000+00:00"

  defp skipped(reason, state \\ "Code Review"), do: ~s(Skipping dispatch: issue_id=a1 issue_identifier=TP-1 state="#{state}"; #{reason})

  describe "parse/1" do
    test "reads the handler's time and level, with or without an offset, a T or a level" do
      assert {~U[2026-10-15 10:00:00.000000Z], "Skipping dispatch: x"} = Sweep.parse("#{@stamp} debug: Skipping dispatch: x\n")
      assert {~U[2026-10-15 08:00:00Z], "message"} = Sweep.parse("2026-10-15T10:00:00+02:00 [info] message")
      assert {~U[2026-10-15 10:00:00Z], "no level here"} = Sweep.parse("2026-10-15 10:00:00 no level here")
      assert {nil, "Skipping dispatch: no time"} = Sweep.parse("Skipping dispatch: no time")
      assert {nil, "2026-13-45T10:00:00Z info: bad"} = Sweep.parse("2026-13-45T10:00:00Z info: bad")
    end
  end

  describe "classify/2" do
    test "the watcher's reason names its rule; a line about something else is nothing" do
      assert Sweep.classify(skipped("the PR watcher (R21): The `specs` check failed")) == {:skipped, "R21"}
      assert Sweep.classify(skipped("the PR watcher (R14a): Lands after TP-2")) == {:skipped, "R14a"}
      assert Sweep.classify("Dispatching issue_id=a1 issue_identifier=TP-1") == nil
    end

    test "every orchestrator gate that is no PR case has its label" do
      gates = %{
        "blocked by TP-2" => "gate: blocked by a ticket",
        "Waiting for TP-2 to finish; Waiting for TP-3 to finish" => "gate: blocked by a ticket",
        "Waiting for TP-2 to land: it changes the same files" => "gate: blocked by a ticket",
        "Waiting for PR #12 (Bump deps) to land: it changes the same files" => "gate: blocked by a ticket",
        "Waiting for CI on 0123456789ab to finish" => "gate: hold",
        "The QA machine is not reachable" => "gate: hold",
        "The QA machine cannot start the project's dev server" => "gate: hold",
        "The QA environment has no playbook for this change" => "gate: hold",
        "The QA environment cannot run the specs check" => "gate: hold",
        "The QA environment is not ready" => "gate: hold",
        "Waiting for your answer: The run on TP-2 cannot continue on its own" => "gate: hold",
        "on a Needs Decision and Blocked hold" => "gate: hold",
        "Waiting for you to unblock it" => "gate: hold",
        "Stopped by you at 2026-10-20 08:41:25 UTC. Unblock runs it again; Restart starts it over from main." => "gate: hold",
        "Waiting for the environment to be ready" => "gate: hold",
        "ci_wait: CI on abc was still running after 30 minutes" => "gate: hold",
        "Waiting for Symphony version 0.0.1.731, which has the fix" => "gate: app update",
        "Waiting for a Symphony build with the fix" => "gate: app update",
        "waiting on its sub-tickets" => "gate: sub-tickets",
        "waiting for an app update: TP-2 merged" => "gate: app update",
        "Waiting for a Symphony update that includes TP-2's fix" => "gate: app update",
        "its plan waits to be replaced before it runs again" => "gate: re-plan",
        "the reviewer is turned off for its repo" => "gate: reviewer off",
        "held in Merging until CI settles on abc" => "gate: Merging CI wait",
        "already running" => "gate: run active",
        "waiting for the QA host's dev server port: 8090 on admin@qa-vm is held by TP-1124's QA pass" => "gate: QA dev server port",
        "claimed by a retry or a Linear update in flight" => "gate: claimed",
        "its token budget is spent (agent.max_tokens_per_issue)" => "gate: token budget",
        "the daily token budget is spent (agent.max_tokens_per_day)" => "gate: token budget",
        "workspace setup failed in Todo; it waits for the ticket to change state" => "gate: workspace setup failed",
        "priority High is not in tickets.priorities (Urgent)" => "gate: priority filter",
        "not assigned to this Symphony's worker" => "gate: another worker",
        "Done is a terminal state" => "gate: not active",
        ~s("Backlog" is not an active state) => "gate: not active",
        "Linear returned it without an id, identifier or title" => "gate: Linear read",
        "not started: the issue read again before dispatch was no longer dispatchable, or no worker was free" => "gate: no free worker",
        "it has no repo key and several repos are configured, so its holds can't be read" => "gate: no repo key",
        "dispatch is paused by the operator" => "gate: paused",
        "new dispatch is paused: the workspace quota is full" => "gate: paused",
        "Claude 5-hour limit reached" => "gate: usage limit",
        "Claude weekly limit headroom: holding new runs" => "gate: usage limit",
        "OpenRouter API unreachable" => "gate: usage limit",
        "the PR watcher hasn't decided on its PR yet" => "watcher: first read"
      }

      for {reason, label} <- gates, do: assert(Sweep.classify(skipped(reason)) == {:skipped, label}, reason)

      lines = %{
        "Skipping dispatch; the PR watcher lands issue_id=a1 issue_identifier=TP-1" => "landing rows (R28-R33)",
        "Skipping dispatch; issue no longer active or visible: issue_id=a1 issue_identifier=TP-1" => "gate: not active",
        "Skipping dispatch; issue refresh failed for issue_id=a1 issue_identifier=TP-1: :timeout" => "gate: Linear read",
        "Skipping dispatch; Linear is rate-limited for issue_id=a1 issue_identifier=TP-1" => "gate: Linear rate limit",
        "Skipping dispatch; usage limit holds provider=anthropic scope=all for issue_id=a1 issue_identifier=TP-1" => "gate: usage limit",
        "Skipping dispatch after quality gate task failure: :boom" => "gate: quality gate failed",
        "Skipping dispatch after readiness task failure: :boom" => "gate: readiness failed",
        "Skipping dispatch; an agent from a previous Symphony may still be running for issue_id=a1 issue_identifier=TP-1: pid 9" => "gate: leftover agent",
        "Not dispatching issues in workspace=/w: an agent left running by a previous Symphony could not be confirmed stopped: pid 9" => "gate: leftover agent",
        "Not dispatching the reviewer for issue_id=a1 issue_identifier=TP-1: review_agent.enabled is false for its repo" => "gate: reviewer off"
      }

      for {line, label} <- lines, do: assert(Sweep.classify(line) == {:skipped, label}, line)
      assert Enum.sort(Sweep.labels()) == Enum.sort(Enum.uniq(Map.values(gates) ++ Map.values(lines) ++ [Sweep.no_rule()]))
    end

    test "a reviewer or QA run held on its head takes the watcher's last rule for the ticket, else its head's status" do
      held = fn status -> "Not dispatching QA for issue_id=a1 issue_identifier=TP-1: its head is #{status}" end

      assert Sweep.classify(held.("green"), %{"TP-1" => "R14a"}) == {:skipped, "R14a"}
      assert Sweep.classify(held.("running")) == {:skipped, "R24"}
      assert Sweep.classify(held.("pending")) == {:skipped, "R24"}
      assert Sweep.classify(held.("red")) == {:skipped, "R21"}
      assert Sweep.classify(held.("unknown")) == {:skipped, "no rule"}
    end

    test "a silent wait maps to the watcher's last rule; one with none is no rule" do
      silent = "pr_watch.silent_wait issue_id=a1 issue_identifier=TP-1 repo_key=s phase=qa since=2026-10-15T10:00:00Z"

      assert Sweep.classify(silent <> " rule=R27 bound=none reason=\"quiet\"") == {:silent, "R27"}
      assert Sweep.classify(silent <> " rule=none bound=none reason=\"the watcher has no decision on it\"") == {:silent, "no rule"}
      assert Sweep.classify(silent) == {:silent, "no rule"}
    end

    test "a skipped dispatch nothing explains is no rule" do
      assert Sweep.classify(skipped("something new")) == {:skipped, "no rule"}
    end
  end

  describe "sweep/2" do
    test "counts each label per kind, and carries the watcher's rule to the held-head line after it" do
      lines = [
        "#{@stamp} debug: #{skipped("the PR watcher (R14a): Lands after TP-2", "QA")}",
        "#{@stamp} info: Not dispatching QA for issue_id=a1 issue_identifier=TP-1: its head is green",
        "#{@stamp} warning: pr_watch.silent_wait issue_identifier=TP-3 since=2026-10-15T09:00:00Z rule=R14a bound=none",
        "#{@stamp} debug: #{skipped("blocked by TP-2", "Todo")}",
        "#{@stamp} info: unrelated"
      ]

      assert %{counts: counts, findings: [first | _rest] = findings} = Sweep.sweep(lines)
      assert counts == %{"R14a" => %{skipped: 2, silent: 1}, "gate: blocked by a ticket" => %{skipped: 1, silent: 0}}
      assert length(findings) == 4
      assert %{at: ~U[2026-10-15 10:00:00.000000Z], kind: :skipped, issue: "TP-1"} = first
    end

    test "--since leaves out older lines and lines without a time" do
      lines = [
        "2026-10-08T10:00:00Z debug: #{skipped("already running")}",
        "#{@stamp} debug: #{skipped("already running")}",
        skipped("already running")
      ]

      assert %{counts: %{"gate: run active" => %{skipped: 1}}} = Sweep.sweep(lines, since: ~U[2026-10-10 00:00:00Z])
      assert %{counts: %{"gate: run active" => %{skipped: 3}}} = Sweep.sweep(lines)
    end

    test "a silent wait listed now counts once, unless the log already listed it, and within --since" do
      lines = ["#{@stamp} warning: pr_watch.silent_wait issue_identifier=TP-1 since=2026-10-15T09:00:00Z rule=R27 bound=none"]

      now = [
        %{"identifier" => "TP-1", "since" => "2026-10-15T09:00:00Z", "rule" => "R27"},
        %{identifier: "TP-2", since: "2026-10-15T09:30:00Z", rule: nil, reason: "the watcher has no decision on it"},
        %{"identifier" => "TP-3", "since" => "2026-10-01T09:30:00Z", "rule" => "R24"},
        %{"identifier" => "TP-4", "since" => "not a time", "rule" => "R24"},
        %{"identifier" => "TP-5", "since" => nil}
      ]

      assert %{counts: counts, findings: findings} = Sweep.sweep(lines, silent_now: now, since: ~U[2026-10-10 00:00:00Z])
      assert counts == %{"R27" => %{skipped: 0, silent: 1}, "no rule" => %{skipped: 0, silent: 1}}

      assert %{line: ~s(silent now: TP-2 since=2026-10-15T09:30:00Z rule=none reason="the watcher has no decision on it")} = List.last(findings)
    end
  end

  describe "format/2" do
    test "one line per rule in table order, then the gates, then no rule and each line it covers" do
      lines = [
        skipped("the PR watcher (R4): A Blocked hold pauses the ticket"),
        skipped("the PR watcher (R14a): Lands after TP-2"),
        skipped("the PR watcher (R14): conflicts"),
        skipped("already running"),
        skipped("something new")
      ]

      assert Sweep.format(Sweep.sweep(lines), "a.log") == [
               "PR watch sweep of a.log: 5 skipped dispatches, 0 silent waits",
               "R4:               1 (skipped 1, silent 0)",
               "R14:              1 (skipped 1, silent 0)",
               "R14a:             1 (skipped 1, silent 0)",
               "gate: run active: 1 (skipped 1, silent 0)",
               "no rule: 1",
               "  " <> skipped("something new")
             ]
    end
  end
end
