defmodule SymphonyElixir.Conductor.GroomingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Conductor, Questions, SubIssueWait, TicketChecks, TicketEvents, TicketPlan, Workspace}
  alias SymphonyElixir.Conductor.{Facts, Grooming}
  alias SymphonyElixir.Config.Schema

  @on %Schema.Conductor{enabled: true}

  @description """
  The ticket list forgets my filter when I reload. Keep it.

  <!-- symphony:decisions:start -->
  ## Decisions
  - **D1** · 2026-11-18 · Only the list <!-- symphony:decision:k1 -->
  <!-- symphony:decisions:end -->
  """

  defmodule FakeAgent do
    @moduledoc false
    def start_session(workspace, opts) do
      send(Application.fetch_env!(:symphony_elixir, :grooming_fake_agent).pid, {:session, workspace, opts})
      {:ok, %{workspace: workspace}}
    end

    def run_turn(_session, prompt, _issue, _opts) do
      %{pid: pid, turn: turn} = Application.fetch_env!(:symphony_elixir, :grooming_fake_agent)
      send(pid, {:turn, prompt})
      turn
    end

    def stop_session(_session), do: :ok
  end

  defmodule NoWaitingState do
    @moduledoc false
    def workflow_state_exists?(_state, _teams), do: {:ok, false}
  end

  # A tracker that takes a label off, or refuses to.
  defmodule Labels do
    @moduledoc false
    def remove_issue_label(issue_id, "breakdown"), do: {:error, {:refused, issue_id}}

    def remove_issue_label(issue_id, label) do
      send(self(), {:label_removed, issue_id, label})
      :ok
    end
  end

  setup do
    n = System.unique_integer([:positive])
    issue_id = "issue-grooming-#{n}"
    identifier = "GROOM-#{n}"
    ticket = %{repo_key: "default", issue_id: issue_id, issue_identifier: identifier, phase: "Todo"}
    record = Map.merge(ticket, %{title: "Keep the list's filter", description: @description})
    :ok = RunStore.put_ticket_state(record)
    issue = %Issue{id: issue_id, identifier: identifier, title: record.title, description: @description, state: "Todo", repo_key: "default", labels: []}
    %{issue: issue, record: record, issue_id: issue_id}
  end

  defp record!(issue_id, type, payload, run_id) do
    {:ok, event} = TicketEvents.record("default", issue_id, type, payload, run_id: run_id)
    event
  end

  defp events(issue_id, type), do: issue_id |> Facts.events() |> Enum.filter(&(&1.type == type))
  defp status_notes(issue_id), do: for(%{payload: %{status: true, text: text}} <- events(issue_id, "note"), do: text)

  defp plan(ctx, attrs \\ %{}) do
    Map.merge(
      %{junction: "grooming", issue_id: ctx.issue_id, repo_key: "default", run_profile: Config.run(Config.settings_for_repo!("default"), :conductor), timeout_ms: 5_000},
      attrs
    )
  end

  defp written(attrs \\ %{}) do
    Map.merge(
      %{
        "shape" => "single",
        "layers" => ["screen"],
        "summary" => "The ticket list remembers its filter.",
        "text" => "Approach: store the filter with the view state.",
        "checks" => [
          %{"kind" => "outcome", "statement" => "The filter is applied after a reload.", "proof" => "test"},
          %{"kind" => "qa", "statement" => "The list is still filtered.", "proof" => "qa", "state" => "2 states", "action" => "Reload", "expect" => "Filtered"}
        ],
        "size" => %{"tokens" => 3_000_000, "runs" => 3}
      },
      attrs
    )
  end

  defp subs, do: [%{"title" => "The API", "ask" => "Add the filter."}, %{"title" => "The list", "ask" => "Read it.", "after" => ["s1"]}]

  defp answer(attrs), do: Jason.encode!(attrs)
  defp planned(attrs \\ %{}), do: {:ok, [answer(%{"plan" => written(attrs), "update" => "I read this as one small change.\n\nNext: one coding run."})], 9_000}
  defp turn(reply), do: fn _plan, _issue, _run_id, _prompt -> reply end
  # No checkout: these turns plan from the facts.
  defp groom(ctx, reply, opts \\ []), do: Conductor.run(plan(ctx), ctx.issue, [turn: turn(reply), worker_host: "elsewhere"] ++ opts)

  defp question(action) do
    %{
      "title" => "Which list?",
      "question" => "Is it the ticket list or the run list?",
      "why" => "The ask names no list.",
      "if_unanswered" => "The ticket stays paused.",
      "recommendation_reason" => "The ticket list has the filter.",
      "options" => [
        %{"label" => "The ticket list", "effect" => "Grooming runs again with this answer.", "recommended" => true, "action" => action},
        %{"label" => "Cancel it", "effect" => "The ticket is cancelled.", "action" => "cancel"}
      ]
    }
  end

  describe "the junction" do
    test "is due before a ticket's first run, while it has no plan and no run of its own", ctx do
      assert Grooming.due?(:implementation, [])
      assert Grooming.due?("breakdown", [])
      refute Grooming.due?(:code_review, [])
      refute Grooming.due?(:rework, [])
      assert Conductor.dispatch_junction(:implementation, []) == "grooming"
      assert Conductor.dispatch_junction(:qa, []) == nil

      # The Conductor's own turn is no run of the ticket's.
      record!(ctx.issue_id, "run.started", %{run_id: "conductor-1", run_kind: "conductor"}, "conductor-1")
      record!(ctx.issue_id, "run.ended", %{run_id: "conductor-1", run_kind: "conductor", exit: "failed"}, "conductor-1")
      assert Conductor.dispatch_junction(:implementation, Facts.events(ctx.issue_id)) == "grooming"
    end

    test "a ticket with runs but no plan is never groomed", ctx do
      started = record!(ctx.issue_id, "run.started", %{run_id: "run-1", run_kind: "implementation"}, "run-1")
      refute Grooming.due?(:implementation, [started])

      ended = record!(ctx.issue_id, "run.ended", %{run_id: "run-1", exit: "normal"}, "run-1")
      refute Grooming.due?(:implementation, [ended])
      assert Conductor.dispatch_junction(:implementation, Facts.events(ctx.issue_id)) == nil
      assert Conductor.plan(ctx.issue, :implementation, "default", settings: @on) == nil
    end

    test "a ticket with a plan is not groomed again", ctx do
      assert groom(ctx, planned()) == :ok
      refute Grooming.due?(:implementation, Facts.events(ctx.issue_id))
      assert Conductor.plan(ctx.issue, :implementation, "default", settings: @on) == nil
    end

    test "is planned for ten minutes, and not at all with the Conductor or the junction off", ctx do
      assert %{junction: "grooming", timeout_ms: 600_000, run_profile: %{kind: :conductor}} = Conductor.plan(ctx.issue, :implementation, "default", settings: @on)
      assert %{timeout_ms: 1_000} = Conductor.plan(ctx.issue, :breakdown, "default", settings: %{@on | grooming_timeout_ms: 1_000})

      assert Conductor.plan(ctx.issue, :implementation, "default", settings: %Schema.Conductor{}, events: :never_read) == nil
      assert Conductor.plan(ctx.issue, :implementation, "default") == nil
      assert Conductor.plan(ctx.issue, :implementation, "default", settings: %{@on | junctions: Schema.Conductor.junctions() -- ["grooming"]}) == nil
      assert Facts.events(ctx.issue_id) == []
    end

    test "a ledger that can't be read grooms nothing, and counts no try" do
      # No issue id is a read the store refuses.
      assert {:error, :invalid_issue_id} = Facts.read_events(nil)
      assert Facts.events(nil) == []
      refute Grooming.due?(:implementation, Facts.read_events(nil))
      assert Grooming.due?(:implementation, {:ok, []})

      log = capture_log(fn -> assert Grooming.failed("default", nil, "the turn failed") == :give_up end)
      assert log =~ "Grooming could not read the ticket's events"
    end

    test "a turn no provider can take is planned as a try that failed", ctx do
      log = capture_log(fn -> send(self(), Conductor.plan(ctx.issue, :implementation, "default", settings: @on, available?: fn _run -> false end)) end)
      assert_received %{junction: "grooming", unavailable: provider} = plan
      assert is_binary(provider)
      refute Map.has_key?(plan, :run_profile)
      assert log =~ "Conductor skipped issue_id=#{ctx.issue_id}"
    end
  end

  describe "a turn that writes a plan" do
    test "records the ask once, the plan and the update, and the run goes on", ctx do
      test = self()

      turn = fn _plan, _issue, run_id, prompt ->
        send(test, {:prompt, run_id, prompt})
        planned()
      end

      assert Conductor.run(plan(ctx), ctx.issue, turn: turn, worker_host: "elsewhere") == :ok

      assert [%{text: "The ticket list forgets my filter when I reload. Keep it.", source: "linear"}] = TicketPlan.ask(ctx.issue_id)
      assert_received {:prompt, run_id, prompt}
      assert prompt =~ "this turn is Grooming"
      assert prompt =~ "The ticket list forgets my filter when I reload. Keep it."
      refute prompt =~ "symphony:decisions"
      refute prompt =~ "{{"
      assert prompt =~ "No checkout of the repository is available to this turn."

      current = TicketPlan.current(ctx.issue_id)
      assert %{version: 1, by: "grooming", reason: "Grooming", shape: "single", layers: ["screen"]} = current
      assert current.size == %{tokens: 3_000_000, runs: 3}
      assert [%{run_id: ^run_id}] = events(ctx.issue_id, "plan.written")
      assert [%{id: "c1", kind: "outcome", state: :open}, %{id: "c2", kind: "qa", needs: "2 states", state: :open}] = TicketChecks.list(ctx.issue_id)
      assert [%{payload: %{junction: "grooming", text: "I read this as one small change." <> _rest}}] = events(ctx.issue_id, "conductor.update")
      assert events(ctx.issue_id, "conductor.instructions") == []
      assert [%{payload: %{run_kind: "conductor", state: "Todo"}}] = events(ctx.issue_id, "run.started")
      assert [%{payload: %{run_kind: "conductor", exit: "answered", tokens: 9_000, counted: false}}] = events(ctx.issue_id, "run.ended")
      assert status_notes(ctx.issue_id) == []

      # The ask is never recorded twice.
      assert Grooming.record_ask("default", ctx.issue, ctx.record, Facts.events(ctx.issue_id)) == :ok
      assert length(TicketPlan.ask(ctx.issue_id)) == 1
    end

    test "a plan whose layers Symphony does not know, or that names none, is recorded with its checks", ctx do
      assert groom(ctx, planned(%{"layers" => ["android", "tests", "unit-tests"]})) == :ok
      assert %{layers: ["tests"]} = TicketPlan.current(ctx.issue_id)
      assert [%{id: "c1", kind: "outcome"}, %{id: "c2"}] = TicketChecks.list(ctx.issue_id)
      assert status_notes(ctx.issue_id) == []
    end

    test "a plan written with a move moves the ticket as the Conductor's, and the run it came before does not start (TP-1656)", ctx do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [ctx.issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      move = %{"stage" => "In Progress", "reason" => "The plan is written; the first run starts."}
      reply = {:ok, [answer(%{"plan" => written(), "update" => "I read this as one small change.", "move" => move})], 9_000}

      assert groom(ctx, reply) == :again

      assert %{version: 1} = TicketPlan.current(ctx.issue_id)
      assert_received {:memory_tracker_state_update, issue_id, "In Progress"}
      assert issue_id == ctx.issue_id
      assert %{phase: "In Progress"} = RunStore.get_ticket_state(ctx.issue_id)
      assert [%{actor: %{kind: :agent, run_kind: "conductor"}, payload: %{from: "Todo", to: "In Progress", note: "The plan is written; the first run starts."}}] = events(ctx.issue_id, "ticket.moved")
    end

    test "a plan with an empty list of layers is recorded with its checks", ctx do
      assert groom(ctx, planned(%{"layers" => []})) == :ok
      assert %{layers: []} = TicketPlan.current(ctx.issue_id)
      assert [%{id: "c1", kind: "outcome"}, %{id: "c2"}] = TicketChecks.list(ctx.issue_id)
    end

    test "a ticket with no description asks its title, and an ask that can't be recorded is logged", ctx do
      bare = %{ctx.issue | description: nil}
      assert Grooming.record_ask("default", bare, %{ctx.record | description: "  "}, []) == :ok
      assert [%{text: "Keep the list's filter"}] = TicketPlan.ask(ctx.issue_id)

      other = "issue-grooming-other-#{System.unique_integer([:positive])}"
      assert Grooming.record_ask("default", %Issue{id: other}, %{}, []) == :ok
      assert TicketPlan.ask(other) == []

      # A store that refuses the ask stops the turn: its plan would overwrite words nobody holds.
      unasked = %{bare | id: other}
      log = capture_log(fn -> assert {:error, :invalid_repo_key} = Grooming.record_ask(nil, unasked, %{}, []) end)
      assert log =~ "Grooming could not record the ask issue_id=#{other}"
    end

    test "an ask too long to record is never cut: the ticket starts without a plan, with one note", ctx do
      long = %{ctx.issue | description: String.duplicate("x", TicketPlan.ask_max() + 1)}
      assert Grooming.record_ask("default", long, ctx.record, []) == {:error, :ask_too_long}
      assert Grooming.record_ask("default", long, ctx.record, []) == {:error, :ask_too_long}
      assert TicketPlan.ask(ctx.issue_id) == []
      assert [note] = status_notes(ctx.issue_id)
      assert note =~ "longer than 100000 characters"

      refute Grooming.due?(:implementation, Facts.read_events(ctx.issue_id))
      assert Grooming.failed("default", ctx.issue_id, "the turn failed") == :give_up
      assert [_one] = status_notes(ctx.issue_id)

      at_the_limit = %{ctx.issue | description: String.duplicate("x", TicketPlan.ask_max())}
      assert Grooming.record_ask("default", at_the_limit, ctx.record, []) == :ok
    end

    test "where the waiting state is off, a split is recorded as a single ticket's plan", ctx do
      settings = Config.settings!()
      capture_log(fn -> assert :disabled = SubIssueWait.check_tracker_state(settings, [], tracker: NoWaitingState) end)
      on_exit(fn -> SubIssueWait.reset_for_test("Waiting on sub-tickets") end)

      log = capture_log(fn -> assert groom(ctx, planned(%{"shape" => "split", "sub_tickets" => subs()})) == :ok end)

      assert log =~ "Grooming planned a split issue_id=#{ctx.issue_id}"
      assert log =~ "sub_tickets=2"
      plan = TicketPlan.current(ctx.issue_id)
      assert plan.shape == "single"
      refute Map.has_key?(plan, :sub_tickets)
      refute Grooming.split_due?(:implementation, Facts.events(ctx.issue_id))
    end

    test "a ticket labelled plan loses the label, and its first coding run is left to the next dispatch", ctx do
      labelled = %{ctx.issue | labels: ["Plan", "type:bug", "breakdown"]}
      :ok = RunStore.put_ticket_state(Map.put(ctx.record, :labels, labelled.labels))

      log = capture_log(fn -> assert Conductor.run(plan(ctx), labelled, turn: turn(planned()), worker_host: "elsewhere", tracker: Labels) == :again end)

      assert_received {:label_removed, _issue_id, "Plan"}
      assert log =~ "Grooming could not take the label off issue_id=#{ctx.issue_id}"
      assert log =~ "label=breakdown"
      assert RunStore.get_ticket_state(ctx.issue_id).labels == ["type:bug"]
      assert [note] = status_notes(ctx.issue_id)
      assert note =~ "took the Plan and breakdown label off"
      assert TicketPlan.groomed?(ctx.issue_id)
      assert Grooming.take_over("default", ctx.issue) == :unchanged
    end
  end

  describe "a turn that writes a split" do
    setup ctx do
      SubIssueWait.reset_for_test("Waiting on sub-tickets")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      issue = %{ctx.issue | team: %{key: "MT"}, assignee_id: "user-1"}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_create_issue_result) end)
      %{issue: issue}
    end

    defp no_turn, do: fn _plan, _issue, _run_id, _prompt -> flunk("a split runs no turn") end

    test "creates the sub-tickets and parks the ticket, whose run does not start", ctx do
      assert groom(ctx, planned(%{"shape" => "split", "sub_tickets" => subs()})) == :again

      assert_received {:memory_tracker_issue_created, "memory-issue-2", %{title: "The API", state: "Todo", parent_id: _parent}}
      assert_received {:memory_tracker_issue_created, "memory-issue-3", %{title: "The list", state: "Backlog"}}
      assert_received {:memory_tracker_state_update, parent_id, "Waiting on sub-tickets"}
      assert parent_id == ctx.issue_id
      assert %{version: 2, shape: "split", sub_tickets: sub_tickets} = TicketPlan.current(ctx.issue_id)
      assert [%{identifier: "MT-9002"}, %{identifier: "MT-9003"}] = sub_tickets
      assert [%{payload: %{junction: "grooming"}}] = events(ctx.issue_id, "conductor.update")

      # A first run about to start on it again (a person moved it back) meets the split, never a turn.
      events = Facts.events(ctx.issue_id)
      refute Grooming.due?(:implementation, events)
      assert Grooming.split_due?(:implementation, events)
      refute Grooming.split_due?(:qa, events)
      assert Conductor.dispatch_junction(:implementation, events) == "grooming"
      assert Conductor.run(plan(ctx), ctx.issue, turn: no_turn()) == :again
      assert Conductor.run(plan(ctx, %{unavailable: "anthropic"}), ctx.issue, turn: no_turn()) == :again
      refute_received {:memory_tracker_issue_created, _id, _attrs}
    end

    test "a ticket labelled plan is split too, and its label is taken off", ctx do
      labelled = %{ctx.issue | labels: ["plan"]}
      :ok = RunStore.put_ticket_state(Map.put(ctx.record, :labels, labelled.labels))

      assert Conductor.run(plan(ctx), labelled, turn: turn(planned(%{"shape" => "split", "sub_tickets" => subs()})), worker_host: "elsewhere") == :again

      assert RunStore.get_ticket_state(ctx.issue_id).labels == []
      assert_received {:memory_tracker_state_update, _parent, "Waiting on sub-tickets"}
    end

    test "a split that keeps failing is tried again, then the person is asked", ctx do
      Application.put_env(:symphony_elixir, :memory_tracker_create_issue_result, {:error, :linear_down})
      split = planned(%{"shape" => "split", "sub_tickets" => subs()})

      log = capture_log(fn -> assert groom(ctx, split) == :again end)
      assert log =~ "Grooming could not split the ticket issue_id=#{ctx.issue_id}"
      assert log =~ "sub-ticket s1 could not be created: :linear_down"
      assert Questions.open({:ticket, "default", ctx.issue_id}) == []

      capture_log(fn -> assert Conductor.run(plan(ctx), ctx.issue, turn: no_turn()) == :again end)
      capture_log(fn -> assert Conductor.run(plan(ctx), ctx.issue, turn: no_turn()) == :held end)

      assert [%{title: "The sub-tickets could not be created"}] = Questions.open({:ticket, "default", ctx.issue_id})
      assert length(status_notes(ctx.issue_id)) == 3
      refute_received {:memory_tracker_state_update, _parent, "Waiting on sub-tickets"}

      # Once Linear answers, the next dispatch finishes the split.
      Application.delete_env(:symphony_elixir, :memory_tracker_create_issue_result)
      assert Conductor.run(plan(ctx), ctx.issue, turn: no_turn()) == :again
      assert_received {:memory_tracker_state_update, _parent, "Waiting on sub-tickets"}
    end

    test "a split Symphony refuses is an answer it can't read, and the try is counted", ctx do
      adopt = [%{"title" => "The API", "ask" => "Add the filter.", "identifier" => "MT-404"}]
      log = capture_log(fn -> assert groom(ctx, planned(%{"shape" => "split", "sub_tickets" => adopt})) == :again end)

      assert log =~ "sub-ticket s1 names MT-404, which is not a sub-ticket of this ticket"
      refute TicketPlan.groomed?(ctx.issue_id)
      assert Grooming.tries(Facts.events(ctx.issue_id)) == 1
    end
  end

  describe "a ticket that already has sub-tickets" do
    setup ctx do
      SubIssueWait.reset_for_test("Waiting on sub-tickets")
      by_hand = [%{id: "h1", identifier: "MT-51", state: "Todo"}, %{id: "h2", identifier: "MT-52", state: "Done"}, %{id: "h3", identifier: "MT-53"}]
      :ok = RunStore.update_ticket_state(ctx.issue_id, %{sub_issues: [%{id: "h4", identifier: "MT-54", state: "Backlog"}]})
      %{issue: %{ctx.issue | sub_issues: by_hand}}
    end

    test "a split names every one that has not ended, or it is refused with the ones it left out", ctx do
      checks = [%{kind: "outcome", statement: "x", proof: "test"}]
      base = %{shape: "split", layers: ["api"], summary: "s", text: "t", checks: checks, size: %{tokens: 1, runs: 1}}
      plan = fn entries -> Map.put(base, :sub_tickets, entries) end
      entry = fn key, identifier -> %{key: key, title: "Part #{key}", ask: "Build it.", after: [], identifier: identifier} end
      new = %{key: "s9", title: "The rest", ask: "Build it.", after: []}

      assert {:error, why} = Grooming.write_plan("default", ctx.issue, plan.([new, entry.("s1", "MT-51")]))
      assert why =~ "its plan was refused: its split leaves out MT-53, MT-54, which the ticket already has as sub-tickets"
      refute TicketPlan.groomed?(ctx.issue_id)

      # The one that ended needs no entry, and a single plan names none.
      named = [new, entry.("s1", "MT-51"), entry.("s2", "MT-53"), entry.("s3", "MT-54")]
      assert {:ok, _event} = Grooming.write_plan("default", ctx.issue, plan.(named))
      assert {:ok, _event} = Grooming.write_plan("default", ctx.issue, %{base | shape: "single"}, new_ask: true)
    end
  end

  describe "a turn that writes no plan" do
    test "is tried once more at the next dispatch, then the ticket starts without a plan, with a note", ctx do
      log = capture_log(fn -> assert groom(ctx, {:ok, ["no answer here"], 7}) == :again end)
      assert log =~ "the ticket is groomed again at its next dispatch"
      assert [first] = status_notes(ctx.issue_id)
      assert first == "Grooming did not finish: unreadable answer: the answer holds no JSON object. Symphony tries once more before the first run."
      assert Grooming.tries(Facts.events(ctx.issue_id)) == 1
      assert %{junction: "grooming"} = Conductor.plan(ctx.issue, :implementation, "default", settings: @on)

      log = capture_log(fn -> assert groom(ctx, {:error, :usage_limited, 5}) == :ok end)
      assert log =~ "the ticket starts without a plan"
      assert [^first, last] = status_notes(ctx.issue_id)
      assert last == "Grooming did not finish, 2 times: the turn failed. This ticket starts without a plan."

      refute TicketPlan.groomed?(ctx.issue_id)
      assert Conductor.plan(ctx.issue, :implementation, "default", settings: @on) == nil
      assert events(ctx.issue_id, "conductor.update") == []
      assert [_ask] = TicketPlan.ask(ctx.issue_id)
      assert Grooming.max_tries() == 2
    end

    test "the next try reads in its facts why the earlier answer was refused", ctx do
      refused = answer(%{"plan" => written(%{"checks" => [%{"kind" => "evidence", "statement" => "A screenshot.", "proof" => "attached"}]})})
      capture_log(fn -> assert groom(ctx, {:ok, [refused], 7}) == :again end)

      test = self()

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        planned()
      end

      assert Conductor.run(plan(ctx), ctx.issue, turn: turn, worker_host: "elsewhere") == :ok
      assert_received {:prompt, prompt}
      assert prompt =~ "earlier_tries"
      assert prompt =~ "`plan.checks` holds no check of kind `outcome`"
      assert TicketPlan.groomed?(ctx.issue_id)
    end

    test "a provider that can take no run follows the same bound, and runs no turn", ctx do
      unavailable = plan(ctx, %{unavailable: "anthropic"}) |> Map.delete(:run_profile)

      capture_log(fn ->
        assert Conductor.run(unavailable, ctx.issue, []) == :again
        assert Conductor.run(unavailable, ctx.issue, []) == :ok
      end)

      assert [first, _last] = status_notes(ctx.issue_id)
      assert first =~ "no provider of runs.conductor can take a run now (anthropic)"
      assert events(ctx.issue_id, "run.started") == []
      assert TicketPlan.ask(ctx.issue_id) == []
      refute Grooming.due?(:implementation, Facts.events(ctx.issue_id))
    end

    test "a turn that runs over, a plan Symphony refuses and a question that can't be asked are tries that failed", ctx do
      refused = written(%{"shape" => "split", "sub_tickets" => [%{"title" => "The API", "ask" => "Add the filter.", "after" => ["s9"]}]})

      cases = [
        {fn _plan, _issue, _run_id, _prompt -> Process.sleep(1_000) end, %{timeout_ms: 20}, "the turn ran past its time limit"},
        {turn({:ok, [answer(%{"plan" => refused, "update" => "Planned."})], 3}), %{}, "its plan was refused: sub-ticket s1 waits after s9"},
        {turn({:ok, [answer(%{"ask_person" => question("accept_without_qa")})], 3}), %{}, "its question could not be asked"}
      ]

      for {turn, attrs, why} <- cases do
        fresh = fresh!(ctx)
        capture_log(fn -> assert Conductor.run(plan(fresh, attrs), fresh.issue, turn: turn, worker_host: "elsewhere") == :again end)
        assert [note] = status_notes(fresh.issue_id)
        assert note =~ why
        assert events(fresh.issue_id, "plan.written") == []
        assert events(fresh.issue_id, "conductor.update") == []
      end
    end

    test "a turn Symphony itself fails, and a try it can't count, never hold the ticket for good", ctx do
      log = capture_log(fn -> assert Conductor.run(plan(ctx), ctx.issue, turn: turn(planned()), facts: %{bad: {:not, :json}}, worker_host: "elsewhere") == :again end)
      assert log =~ "Grooming failed issue_id=#{ctx.issue_id}"
      assert [note] = status_notes(ctx.issue_id)
      assert note =~ "Symphony could not run the turn"

      log = capture_log(fn -> assert Grooming.failed(nil, "issue-grooming-nowhere", "the turn failed") == :give_up end)
      assert log =~ "Grooming could not count its try"
    end

    test "a plan that can't be recorded says so" do
      issue = %Issue{id: "issue-grooming-unrecorded", identifier: "GROOM-0"}
      checks = [%{id: "c1", kind: "outcome", statement: "x", proof: "test"}]
      plan = %{shape: "single", layers: ["docs"], summary: "s", text: "t", checks: checks, size: %{tokens: 1, runs: 1}}
      assert {:error, "its plan could not be recorded: " <> _why} = Grooming.write_plan(nil, issue, plan)
    end
  end

  test "a question holds the ticket, writes no plan and counts no try", ctx do
    reply = {:ok, [answer(%{"plan" => written(), "ask_person" => question("continue")})], 4}

    assert groom(ctx, reply) == :held

    assert [%{title: "Which list?"}] = Questions.open({:ticket, "default", ctx.issue_id})
    refute TicketPlan.groomed?(ctx.issue_id)
    assert Grooming.tries(Facts.events(ctx.issue_id)) == 0
    assert status_notes(ctx.issue_id) == []
    # Once answered, the ticket is groomed again: the junction is still due.
    assert Grooming.due?(:implementation, Facts.events(ctx.issue_id))
  end

  describe "the turn's session" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :grooming_fake_agent) end)
      reply = {:ok, %{result: answer(%{"plan" => written()})}}
      Application.put_env(:symphony_elixir, :grooming_fake_agent, %{pid: self(), turn: reply})
    end

    test "runs in the ticket's workspace, which is kept, with read-only tools and more than one model turn", ctx do
      test = self()
      {:ok, workspace} = Workspace.local_path_for_issue(ctx.issue.identifier, "default")
      on_exit(fn -> File.rm_rf(workspace) end)

      create = fn issue, host, repo_key, opts ->
        send(test, {:created, issue.identifier, host, repo_key, opts})
        File.mkdir_p!(workspace)
        {:ok, workspace}
      end

      assert Conductor.run(plan(ctx, %{timeout_ms: 4_321}), ctx.issue, agent_module: FakeAgent, create_workspace: create, active_workspace_identifiers: ["GROOM-0"]) == :ok

      assert_received {:created, identifier, nil, "default", [active_workspace_identifiers: ["GROOM-0"]]}
      assert identifier == ctx.issue.identifier
      assert_received {:session, ^workspace, session_opts}
      assert session_opts[:tool_scope] == :read_only and session_opts[:read_only] == true
      assert session_opts[:settings].execution.max_turns > 1
      assert session_opts[:settings].execution.turn_timeout_ms == 4_321
      assert File.dir?(workspace)
      assert_received {:turn, prompt}
      assert prompt =~ "The repository is checked out in your working directory."
      assert TicketPlan.groomed?(ctx.issue_id)
    end

    test "plans without the code when the workspace can't be made, in a folder that is removed", ctx do
      create = fn _issue, _host, _repo_key, _opts -> {:error, :disk_full} end

      log = capture_log(fn -> assert Conductor.run(plan(ctx), ctx.issue, agent_module: FakeAgent, create_workspace: create) == :ok end)

      assert log =~ "Grooming has no workspace issue_id=#{ctx.issue_id}"
      assert_received {:session, folder, _session_opts}
      assert folder =~ ".conductor"
      refute File.exists?(folder)
      assert Grooming.workspace(ctx.issue, "default", worker_host: "elsewhere") == {:error, {:remote_worker, "elsewhere"}}
    end
  end

  defp fresh!(ctx) do
    n = System.unique_integer([:positive])
    record = %{ctx.record | issue_id: "issue-grooming-#{n}", issue_identifier: "GROOM-#{n}"}
    :ok = RunStore.put_ticket_state(record)
    %{issue_id: record.issue_id, record: record, issue: %{ctx.issue | id: record.issue_id, identifier: record.issue_identifier}}
  end

  describe "what the turn needs before it runs" do
    test "a read of the ticket's events that failed plans no turn", ctx do
      failed = fn _issue_id -> {:error, :store_down} end
      assert Conductor.plan(ctx.issue, :implementation, "default", settings: @on, read: failed) == nil
      assert %{junction: "grooming"} = Conductor.plan(ctx.issue, :implementation, "default", settings: @on, read: &Facts.read_events/1)
    end

    test "an ask too long to record starts the run without a plan, and one the store refuses is a failed try", ctx do
      long = %{ctx.issue | description: String.duplicate("x", TicketPlan.ask_max() + 1)}
      assert Conductor.run(plan(ctx), long, turn: no_turn()) == :ok
      assert TicketPlan.ask(ctx.issue_id) == []
      refute TicketPlan.groomed?(ctx.issue_id)

      other = %{ctx.issue | id: "groom-unasked-#{System.unique_integer([:positive])}"}
      unrecorded = %{plan(ctx) | issue_id: other.id, repo_key: nil}
      log = capture_log(fn -> assert Conductor.run(unrecorded, other, turn: no_turn(), record: %{}) in [:ok, :again] end)
      assert log =~ "Grooming wrote no plan"
      assert log =~ "what was asked could not be recorded"
    end
  end
end
