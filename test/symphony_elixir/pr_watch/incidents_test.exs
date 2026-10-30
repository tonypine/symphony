defmodule SymphonyElixir.PrWatch.IncidentsTest do
  @moduledoc """
  Every ticket the old pollers parked in an active phase until a person noticed (TP-922's
  incidents), replayed as facts through the parity harness (`SymphonyElixir.PrWatchParity`), once
  by polling only and once by GitHub's deliveries: both runs make the same calls in the same order
  and leave every ticket the same way. Each one ends in an action Symphony carries out, a wait
  with an owner, a hold that clears by itself or a person's decision, never a silent wait, and no
  person moves a ticket on the way: the only moves are the watcher's and the runs' own handoffs.

  Two more fixtures replay the cases the plan's decisions added: two tickets racing for the same
  files (D14) and a check that keeps failing (D15 (c)).
  """

  use SymphonyElixir.TestSupport

  import SymphonyElixir.PrWatchParity,
    only: [check_failed: 2, check_passed: 2, fix_run: 3, fix_run: 4, synchronize: 2, merged: 1, push: 0, red: 0, red: 1]

  alias SymphonyElixir.PrDecision.Action
  alias SymphonyElixir.PrWatchParity, as: Parity

  setup do
    start_supervised!(Parity)

    write_workflow_file!(Workflow.workflow_file_path(),
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 20}
    )

    :ok
  end

  @merging_armed [ci: :pending, mergeable: :blocked, auto_merge: :armed]
  @pending [ci: :pending, failing_check: nil, failed_checks: []]

  @fixtures [
    {:tp_896, "TP-896: a red, armed Merging PR sat skipped as \"auto-merge landing\"",
     %{
       tickets: [{"1", "Merging", @merging_armed}],
       steps:
         [
           {:github, [check_failed("1", "head-1-1")], [{"1", red()}]},
           {:github, [check_failed("1", "head-1-1")], []}
         ] ++
           fix_run("1", "head-1-2", "Merging") ++
           [{:github, [merged("1")], [{"1", pr: :merged}]}]
     }},
    {:tp_920, "TP-920/TP-892: a red head in Code Review waited for green forever",
     %{
       tickets: [{"1", "Code Review", []}],
       steps:
         [
           {:github, [synchronize("1", "head-1-2")], [{"1", head_sha: "head-1-2", ci: :pending}]},
           {:github, [check_failed("1", "head-1-2")], [{"1", red()}]},
           {:github, [check_failed("1", "head-1-2")], []}
         ] ++
           fix_run("1", "head-1-3", "Code Review", @pending) ++
           [{:github, [check_passed("1", "head-1-3")], [{"1", ci: :green}]}]
     }},
    {:tp_921, "TP-921/TP-891: a push to main made a Merging PR conflict, and auto-merge flapped for 2 h",
     %{
       tickets: [{"1", "Merging", @merging_armed}, {"2", "QA", []}],
       running: ["2"],
       steps:
         [
           {:github, [push()], [{"1", mergeable: :dirty}]},
           {:github, [push()], []}
         ] ++
           fix_run("1", "head-1-2", "Merging") ++
           [{:github, [merged("1")], [{"1", pr: :merged}]}]
     }},
    {:tp_886, "TP-886: another Merging PR's merge moved main, with no push delivery, and made this one conflict",
     %{
       tickets: [{"1", "Merging", @merging_armed}, {"2", "Merging", @merging_armed}],
       steps:
         [
           {:github, [check_passed("1", "head-1-1")], [{"1", ci: :green, mergeable: :clean}]},
           {:github, [merged("1")], [{"1", pr: :merged}, {"2", mergeable: :dirty}]}
         ] ++
           fix_run("2", "head-2-2", "Merging") ++
           [{:github, [merged("2")], [{"2", pr: :merged}]}]
     }},
    {:tp_903, "TP-903: two Merging PRs changed docs/configuration.md and SPEC.md, and the one that conflicted sat",
     %{
       tickets: [{"1", "Merging", @merging_armed}, {"2", "Merging", @merging_armed}],
       files: %{"1" => ["SPEC.md", "docs/configuration.md"], "2" => ["docs/configuration.md"]},
       steps:
         [
           {:github, [push()], [{"2", mergeable: :dirty}]},
           {:github, [check_passed("1", "head-1-1")], [{"1", ci: :green, mergeable: :clean}]},
           {:github, [merged("1")], [{"1", pr: :merged}]}
         ] ++
           fix_run("2", "head-2-2", "Merging") ++
           [{:github, [merged("2")], [{"2", pr: :merged}]}]
     }},
    {:tp_917, "TP-917: the conflict came back after its fix run, as main moved again",
     %{
       tickets: [{"1", "Merging", @merging_armed}],
       steps:
         [{:github, [push()], [{"1", mergeable: :dirty}]}] ++
           fix_run("1", "head-1-2", "Merging") ++
           [{:github, [push()], [{"1", mergeable: :dirty}]}] ++
           fix_run("1", "head-1-3", "Merging") ++
           [{:github, [merged("1")], [{"1", pr: :merged}]}]
     }},
    {:racing, "two tickets racing for SPEC.md (D14): B waits on A, A lands, one CI Fix resolves B",
     %{
       tickets: [{"1", "QA", []}, {"2", "Merging", @merging_armed}],
       files: %{"1" => ["SPEC.md"], "2" => ["SPEC.md", "lib/b.ex"]},
       steps:
         [
           {:github, [push()], [{"2", mergeable: :dirty}]},
           {:github, [push()], []},
           {:run, "1", "QA", "Merging"},
           {:github, [merged("1")], [{"1", pr: :merged}]}
         ] ++
           fix_run("2", "head-2-2", "Merging") ++
           [{:github, [merged("2")], [{"2", pr: :merged}]}]
     }},
    {:failing_check, "a check that keeps failing (D15 (c)): a fix ticket for CI, C held on it until it lands, then QA",
     %{
       tickets: [{"1", "Code Review", red("test")}],
       # Each CI Fix run: the red head's first read reruns `test`, the rerun fails the same way, the
       # run pushes the next head and hands C back, and that head fails `test` the same way too.
       # The hold clears and the counts restart: the red head is rerun once, fails, and gets one more CI Fix run.
       steps:
         Enum.flat_map(1..3, fn run ->
           {head, next} = {"head-1-#{run}", "head-1-#{run + 1}"}

           [{:github, [check_failed("1", head)], []}] ++
             fix_run("1", next, "Code Review", @pending) ++
             [{:github, [check_failed("1", next)], [{"1", red("test")}]}]
         end) ++
           [{:fix_ticket_lands, "TP-FIX1"}, {:github, [check_failed("1", "head-1-4")], []}] ++
           fix_run("1", "head-1-5", "Code Review", @pending) ++
           [
             {:github, [check_passed("1", "head-1-5")], [{"1", ci: :green}]},
             {:run, "1", "Code Review", "QA"}
           ]
     }}
  ]

  for {key, name, fixture} <- @fixtures do
    @key key
    @name name
    @fixture fixture
    test name do
      polled = Parity.run(@fixture, :poll)
      polled_fix_tickets = Parity.fix_tickets()
      Parity.reset!()
      delivered = Parity.run(@fixture, :webhook)

      # Webhooks change how soon the watcher acts, never what it does.
      assert polled.actions != []
      assert delivered.actions == polled.actions
      assert delivered.tickets == polled.tickets
      assert Parity.fix_tickets() == polled_fix_tickets
      assert Enum.all?(delivered.elapsed_ms, &(&1 < 5_000))
      assert Enum.all?(polled.elapsed_ms, &(&1 == 30_000))

      # No person moves a ticket: every step is GitHub's, a run's handoff or a fix ticket landing.
      assert Enum.all?(@fixture.steps, &(elem(&1, 0) in [:github, :run, :fix_ticket_lands]))

      for {id, ending} <- polled.tickets, do: assert_handled!(id, ending)
      expect(@key, polled)

      label = @name |> String.split(":") |> hd()
      IO.puts("#{label}, by poll and by webhook (#{length(polled.actions)} actions): " <> Enum.map_join(Enum.sort(polled.tickets), "; ", &describe/1))
    end
  end

  # Done, an action Symphony carries out, a wait with an owner, a hold that clears by itself, or a
  # decision for a person; never a silent wait.
  defp assert_handled!(_id, %{state: "Done", holds: []}), do: :done

  defp assert_handled!(id, %{decision: %{kind: kind, owner: owner}, silent: false} = ending) do
    cond do
      kind not in Action.waiting_kinds() -> :acted
      :blocked in ending.holds -> assert owner == :symphony, "TP-#{id} waits on a Blocked hold nobody clears: #{inspect(ending)}"
      owner == :person -> assert :needs_decision in ending.holds, "TP-#{id} waits on a person without a decision: #{inspect(ending)}"
      true -> assert owner in Action.owners(), "TP-#{id} waits on nobody: #{inspect(ending)}"
    end
  end

  defp assert_handled!(id, ending), do: flunk("TP-#{id} ended in a silent wait or with no decision: #{inspect(ending)}")

  defp describe({id, %{state: "Done"}}), do: "TP-#{id} closed out (Done)"
  defp describe({id, %{state: state, decision: decision}}), do: "TP-#{id} #{state}, #{decision.rule} #{decision.kind}"

  defp moves(actions, id), do: for({:move, {issue_id, state}} <- actions, issue_id == Parity.issue_id(id), do: state)
  defp calls(actions, name), do: for({^name, args} <- actions, do: args)
  defp index(actions, action), do: Enum.find_index(actions, &(&1 == action))

  defp expect(:tp_896, %{actions: actions, tickets: tickets}) do
    assert %{"1" => %{state: "Done"}} = tickets
    assert moves(actions, "1") == ["CI Fix", "Done"]
    assert calls(actions, :disarm) == [Parity.pr_url("1")]
    assert calls(actions, :arm) == [{Parity.pr_url("1"), "head-1-2"}]
  end

  defp expect(:tp_920, %{actions: actions, tickets: tickets}) do
    assert %{"1" => %{state: "Code Review", decision: %{rule: "R27", kind: :dispatch}}} = tickets
    assert calls(actions, :rerun) == ["77"]
    assert moves(actions, "1") == ["CI Fix"]
  end

  defp expect(:tp_921, %{actions: actions, tickets: tickets}) do
    assert %{"1" => %{state: "Done"}, "2" => %{state: "QA", decision: %{rule: "R9", owner: :agent}}} = tickets
    assert moves(actions, "1") == ["CI Fix", "Done"]
    # Auto-merge goes off once for the conflict and on once for the fixed head: no flapping.
    assert calls(actions, :disarm) == [Parity.pr_url("1")]
    assert calls(actions, :arm) == [{Parity.pr_url("1"), "head-1-2"}]
  end

  defp expect(:tp_886, %{actions: actions, tickets: tickets}) do
    assert %{"1" => %{state: "Done"}, "2" => %{state: "Done"}} = tickets
    assert calls(actions, :merge) == [{Parity.pr_url("1"), "head-1-1"}]
    assert moves(actions, "2") == ["CI Fix", "Done"]
    assert calls(actions, :disarm) == [Parity.pr_url("2")]
  end

  defp expect(:tp_903, %{actions: actions, tickets: tickets}) do
    assert %{"1" => %{state: "Done"}, "2" => %{state: "Done"}} = tickets
    # The conflicting PR waits on the one ahead instead of spending a CI Fix run, then gets one.
    assert calls(actions, :link) == [{"TP-1", Parity.issue_id("2")}]
    assert moves(actions, "2") == ["CI Fix", "Done"]
    assert index(actions, {:move, {Parity.issue_id("2"), "CI Fix"}}) > index(actions, {:move, {Parity.issue_id("1"), "Done"}})
  end

  defp expect(:tp_917, %{actions: actions, tickets: tickets}) do
    assert %{"1" => %{state: "Done"}} = tickets
    assert moves(actions, "1") == ["CI Fix", "CI Fix", "Done"]
    # One disarm per conflict and one arm per fixed head.
    assert calls(actions, :disarm) == List.duplicate(Parity.pr_url("1"), 2)
    assert calls(actions, :arm) == [{Parity.pr_url("1"), "head-1-2"}, {Parity.pr_url("1"), "head-1-3"}]
  end

  defp expect(:racing, %{actions: actions, tickets: tickets}) do
    assert %{"1" => %{state: "Done"}, "2" => %{state: "Done"}} = tickets
    a_lands = index(actions, {:move, {Parity.issue_id("1"), "Done"}})

    # B waits on A as a blocked-by link and a Blocked hold, with auto-merge off, until A lands.
    assert calls(actions, :link) == [{"TP-1", Parity.issue_id("2")}]
    assert index(actions, {:link, {"TP-1", Parity.issue_id("2")}}) < a_lands
    assert {:label, {Parity.issue_id("2"), "Blocked"}} in Enum.take(actions, a_lands)
    assert calls(actions, :disarm) == [Parity.pr_url("2")]
    assert Parity.blockers("2") == ["TP-1"]

    # No CI Fix run while A is open, then exactly one.
    assert moves(actions, "2") == ["CI Fix", "Done"]
    assert index(actions, {:move, {Parity.issue_id("2"), "CI Fix"}}) > a_lands
  end

  defp expect(:failing_check, %{actions: actions, tickets: tickets}) do
    assert %{"1" => %{state: "QA", decision: %{rule: "R27", kind: :dispatch}, holds: []}} = tickets

    # One fix ticket for `test`, linked as C's blocker, and C held on it until it landed.
    assert [%{component: "ci:test"}] = calls(actions, :fix_ticket)
    assert calls(actions, :blocked_by) == [{Parity.issue_id("1"), "TP-FIX1"}]
    assert Parity.fix_tickets() == %{"TP-FIX1" => "Done"}
    refute {:label, {Parity.issue_id("1"), "Needs Decision"}} in actions

    # Three CI Fix runs, then one more after the counts restarted, which turned the head green.
    assert moves(actions, "1") == List.duplicate("CI Fix", 4)
  end
end
