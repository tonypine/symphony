defmodule SymphonyElixir.ConductorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Conductor, TicketEvents, TicketState}
  alias SymphonyElixir.Conductor.{Answer, Facts, Steer}
  alias SymphonyElixir.Config.Schema

  @on %Schema.Conductor{enabled: true}

  defmodule FakeAgent do
    @moduledoc false
    def start_session(workspace, opts) do
      %{pid: pid} = config = Application.fetch_env!(:symphony_elixir, :conductor_fake_agent)
      send(pid, {:session, workspace, File.dir?(workspace), opts})
      Map.get(config, :session, {:ok, %{workspace: workspace}})
    end

    def run_turn(_session, prompt, _issue, opts) do
      %{pid: pid} = config = Application.fetch_env!(:symphony_elixir, :conductor_fake_agent)
      send(pid, {:turn, prompt, opts})
      opts[:on_message].(%{"tokenUsage" => %{"total" => %{"total_tokens" => 321}}})
      Map.fetch!(config, :turn)
    end

    def stop_session(_session), do: :ok
  end

  # The filer a ticket route files through (`SelfHeal.file_ticket/3`): it files TP-2000.
  defmodule FakeFixer do
    @moduledoc false
    def create(attrs, _opts) do
      Process.put(:conductor_filed, attrs)
      {:ok, %{id: "filed-#{System.unique_integer([:positive])}", identifier: "TP-2000", url: "https://linear.app/t/TP-2000"}}
    end

    def block(_issue, _ticket, _opts), do: :ok
    def relate(_issue, _ticket, _opts), do: :ok
  end

  setup do
    n = System.unique_integer([:positive])
    issue_id = "issue-conductor-#{n}"
    identifier = "COND-#{n}"
    record = %{repo_key: "default", issue_id: issue_id, issue_identifier: identifier, phase: "Code Review", title: "Fix login", description: "## Problem\nBroken."}
    :ok = RunStore.put_ticket_state(record)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :conductor_fake_agent) end)
    issue = %Issue{id: issue_id, identifier: identifier, title: "Fix login", state: "Code Review", repo_key: "default"}
    %{issue: issue, record: record, issue_id: issue_id}
  end

  defp record!(issue_id, type, payload, opts \\ []) do
    {:ok, event} = TicketEvents.record("default", issue_id, type, payload, opts)
    event
  end

  defp ran!(issue_id, kind, opts \\ []) do
    run_id = "run-#{System.unique_integer([:positive])}"
    record!(issue_id, "run.started", %{run_id: run_id, run_kind: kind}, run_id: run_id)
    record!(issue_id, "run.ended", Map.merge(%{run_id: run_id, run_kind: kind, exit: "normal"}, Map.new(opts)), run_id: run_id)
  end

  defp plan(ctx, attrs \\ %{}) do
    Map.merge(
      %{junction: "after_coding", issue_id: ctx.issue_id, repo_key: "default", run_profile: Config.run(Config.settings_for_repo!("default"), :conductor), timeout_ms: 5_000},
      attrs
    )
  end

  # Another ticket in `phase`, with no question on it yet.
  defp fresh_ticket!(phase) do
    n = System.unique_integer([:positive])
    issue_id = "issue-conductor-#{n}"
    :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: issue_id, issue_identifier: "COND-#{n}", phase: phase, title: "Fix login"})
    %{issue_id: issue_id, issue: %Issue{id: issue_id, identifier: "COND-#{n}", title: "Fix login", state: phase, repo_key: "default"}}
  end

  defp acting_question do
    %{
      "title" => "QA cannot set up the failing request",
      "question" => "How should the ticket get past QA?",
      "why" => "QA stopped at the same step 7 times.",
      "if_unanswered" => "The ticket stays paused.",
      "recommendation_reason" => "The unit tests prove the step.",
      "options" => [
        %{"label" => "Accept without QA", "effect" => "It merges on its review and CI.", "recommended" => true, "action" => "accept_without_qa"},
        %{"label" => "Send it to Rework", "effect" => "It goes back to Rework.", "action" => "rework", "finding" => "Add a flag QA can set."},
        %{"label" => "Run QA again", "effect" => "QA runs once more.", "action" => "rerun"},
        %{"label" => "Cancel it", "effect" => "The ticket is cancelled.", "action" => "cancel"}
      ]
    }
  end

  defp answer(attrs \\ %{}), do: Jason.encode!(Map.merge(%{"instructions" => "Check the empty list first."}, attrs))

  defp turn(reply), do: fn _plan, _issue, _run_id, _prompt -> reply end

  defp routed(route, attrs \\ %{}), do: {:ok, [answer(Map.merge(%{"route" => route}, attrs))], 35_000}

  defp ticket_route(attrs \\ %{}) do
    Map.merge(
      %{
        "to" => "ticket",
        "relation" => "blocks",
        "repo" => "default",
        "title" => "The QA build runs the Mac app build on a repo with none",
        "problem" => "Cycle has no Mac app.",
        "wanted" => "QA builds the Mac app only where there is one.",
        "acceptance" => ["A Cycle QA pass starts its tests."],
        "walkthrough" => ["In the Director, a Cycle ticket's QA pass runs its steps."]
      },
      attrs
    )
  end

  defp events(issue_id, type), do: issue_id |> Facts.events() |> Enum.filter(&(&1.type == type))

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  describe "junctions" do
    test "the newest run that ended and the kind about to start name the junction", ctx do
      ran!(ctx.issue_id, "implementation")
      events = Facts.events(ctx.issue_id)
      assert Conductor.dispatch_junction(:code_review, events) == "after_coding"
      assert Conductor.dispatch_junction(:qa, events) == "after_coding"
      assert Conductor.dispatch_junction(:rework, events) == nil

      ran!(ctx.issue_id, "rework")
      assert Conductor.dispatch_junction("qa", Facts.events(ctx.issue_id)) == "after_rework"

      ran!(ctx.issue_id, "qa")
      assert Conductor.dispatch_junction(:rework, Facts.events(ctx.issue_id)) == nil
      record!(ctx.issue_id, "verdict.recorded", %{kind: "qa", outcome: "fail"})
      assert Conductor.dispatch_junction(:rework, Facts.events(ctx.issue_id)) == "after_qa_fail"
      assert Conductor.dispatch_junction(:landing, Facts.events(ctx.issue_id)) == "before_merge"
      assert Conductor.dispatch_junction(:implementation, Facts.events(ctx.issue_id)) == nil
      assert Conductor.dispatch_junction(:code_review, []) == nil
    end

    test "a Conductor turn since the last run ended means the junction is met", ctx do
      ran!(ctx.issue_id, "implementation")
      ran!(ctx.issue_id, "conductor", counted: false)
      assert Conductor.dispatch_junction(:code_review, Facts.events(ctx.issue_id)) == nil
    end

    test "a review run that left its ticket in Merging meets before_merge as it ends", ctx do
      ran!(ctx.issue_id, "qa")
      events = Facts.events(ctx.issue_id)
      assert Conductor.run_end_junction(:qa, %{ctx.record | phase: "Merging"}, events) == "before_merge"
      assert Conductor.run_end_junction("code_review", %{ctx.record | phase: "Merging"}, events) == "before_merge"
      assert Conductor.run_end_junction(:qa, ctx.record, events) == nil
      assert Conductor.run_end_junction(:rework, %{ctx.record | phase: "Merging"}, events) == nil
    end
  end

  describe "plan/4" do
    test "plans nothing while the Conductor is off, and reads nothing", ctx do
      ran!(ctx.issue_id, "implementation")
      assert Conductor.plan(ctx.issue, :code_review, "default") == nil
      assert Conductor.plan(ctx.issue, :code_review, "default", settings: %Schema.Conductor{}, events: :never_read) == nil
      refute Conductor.enabled?(%Schema.Conductor{})
      refute Conductor.enabled?(nil)
    end

    test "plans the junction's turn with the run kind's profile", ctx do
      ran!(ctx.issue_id, "implementation")

      assert %{junction: "after_coding", issue_id: issue_id, repo_key: "default", timeout_ms: 180_000, run_profile: %{kind: :conductor}} =
               Conductor.plan(ctx.issue, :code_review, "default", settings: @on)

      assert issue_id == ctx.issue_id
      assert Conductor.plan(ctx.issue, :code_review, "default", settings: %{@on | junctions: ["before_merge"]}) == nil
      assert Conductor.plan(ctx.issue, :code_review, nil, settings: @on) == nil
    end

    test "plans nothing when no provider can take the turn, or when planning fails", ctx do
      ran!(ctx.issue_id, "implementation")

      log = capture_log(fn -> assert Conductor.plan(ctx.issue, :code_review, "default", settings: @on, available?: fn _run -> false end) == nil end)
      assert log =~ "Conductor skipped issue_id=#{ctx.issue_id}"

      log = capture_log(fn -> assert Conductor.plan(ctx.issue, :code_review, "default", settings: @on, events: :not_a_list) == nil end)
      assert log =~ "Conductor could not plan a turn issue_id=#{ctx.issue_id}"
    end

    test "plan_after_run/4 plans before_merge for a review run that carried its ticket into Merging, unless dispatch is paused", ctx do
      ran!(ctx.issue_id, "qa")
      merging = %{ctx.record | phase: "Merging"}
      not_paused = fn _subject -> false end

      assert %{junction: "before_merge"} = Conductor.plan_after_run(ctx.issue, :qa, "default", settings: @on, record: merging, paused?: not_paused)
      assert Conductor.plan_after_run(ctx.issue, :qa, "default", settings: @on, record: merging, paused?: &(&1 == :symphony)) == nil
      assert Conductor.plan_after_run(ctx.issue, :qa, "default", settings: @on, record: merging, paused?: &(&1 == {:repository, "default"})) == nil
      assert Conductor.plan_after_run(ctx.issue, :implementation, "default", settings: @on, record: merging) == nil
      assert Conductor.plan_after_run(ctx.issue, :qa, "default", settings: @on) == nil
    end
  end

  describe "run/3" do
    test "nil runs nothing" do
      assert Conductor.run(nil, %Issue{}, []) == :ok
    end

    test "records its run, its instructions and its update with the refs the facts carry", ctx do
      verdict = record!(ctx.issue_id, "verdict.recorded", %{kind: "code_review", outcome: "approve"})
      facts = %{verdicts: [%{event_id: verdict.id}], last_run: %{started_event_id: "evt_started"}}
      reply = {:ok, ["prose", answer(%{"update" => "It handed off with every check green.", "refs" => [verdict.id, "evt_started", "evt_made_up"]})], 1_234}

      assert Conductor.run(plan(ctx), ctx.issue, turn: turn(reply), facts: facts) == :ok

      assert [%{payload: %{junction: "after_coding", text: "Check the empty list first."}, run_id: run_id}] = events(ctx.issue_id, "conductor.instructions")
      assert [%{payload: %{text: "It handed off with every check green.", refs: refs}}] = events(ctx.issue_id, "conductor.update")
      assert refs == [verdict.id, "evt_started"]
      assert [%{payload: junction_payload}] = events(ctx.issue_id, "conductor.update")
      refute Map.has_key?(junction_payload, :watch)
      assert [%{payload: %{run_kind: "conductor", run_number: 1, state: "Code Review"}}] = events(ctx.issue_id, "run.started")
      assert [%{payload: %{run_kind: "conductor", exit: "answered", tokens: 1_234, counted: false}}] = events(ctx.issue_id, "run.ended")

      assert [%{run_id: ^run_id, run_kind: "conductor", status: "completed", tokens: %{total_tokens: 1_234}}] =
               RunStore.list_issue_runs("default", ctx.issue_id)
    end

    test "asks the person through the decision path, which pauses the ticket and holds the next run", ctx do
      question = %{
        "title" => "Login failed three times",
        "question" => "Should the next rework start over, or wait for you?",
        "why" => "QA failed the same step three times.",
        "if_unanswered" => "The ticket stays paused.",
        "recommendation_reason" => "A fourth try would repeat the third.",
        "options" => [
          %{"label" => "Start over", "effect" => "The next rework starts from the ticket again.", "recommended" => true, "action" => "continue"},
          %{"label" => "Wait", "effect" => "Nothing runs until you say.", "action" => "continue"}
        ]
      }

      assert Conductor.run(plan(ctx), ctx.issue, turn: turn({:ok, [answer(%{"ask_person" => question})], 10}), facts: %{}) == :held
      assert [%{payload: %{title: "Login failed three times", asked_by: %{name: "Conductor"}}}] = events(ctx.issue_id, "question.asked")
      assert SymphonyElixir.Pauses.paused?({:ticket, "default", ctx.issue_id})

      # A question whose Linear comment could not be posted still stands, so it still holds the run.
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :linear_down})
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result) end)

      # A second question about the same stage is not asked: the ticket holds the one it has.
      other = %{question | "title" => "The budget is nearly spent", "question" => "Should the next run go on?"}
      log = capture_log(fn -> assert Conductor.run(plan(ctx), ctx.issue, turn: turn({:ok, [answer(%{"ask_person" => other})], 10}), facts: %{}) == :held end)
      assert log =~ ~s(the ticket already waits on "Login failed three times")
      assert [%{title: "Login failed three times"}] = SymphonyElixir.Questions.open({:ticket, "default", ctx.issue_id})

      fresh = fresh_ticket!("Code Review")
      log = capture_log(fn -> assert Conductor.run(plan(fresh), fresh.issue, turn: turn({:ok, [answer(%{"ask_person" => other})], 10}), facts: %{}) == :held end)
      assert log =~ "Failed to post the decision request"

      bad =
        Map.put(question, "options", [
          %{"label" => "A", "effect" => "x", "recommended" => true, "action" => "continue"},
          %{"label" => "B", "effect" => "y", "recommended" => true, "action" => "continue"}
        ])

      fresh = fresh_ticket!("Code Review")
      log = capture_log(fn -> assert Conductor.run(plan(fresh), fresh.issue, turn: turn({:ok, [answer(%{"ask_person" => bad})], 10}), facts: %{}) == :ok end)
      assert log =~ "Conductor's question was not asked"
    end

    test "each option carries the move its action makes once picked", _ctx do
      fresh = fresh_ticket!("QA")
      Conductor.run(plan(fresh), fresh.issue, turn: turn({:ok, [answer(%{"ask_person" => acting_question()})], 10}), facts: %{})

      assert [%{asked_by: %{name: "Conductor", run_id: run_id}, asked_in: "QA", options: options}] = SymphonyElixir.Questions.open({:ticket, "default", fresh.issue_id})
      assert [accept, rework, rerun, cancel] = options
      merging = SymphonyElixir.TransitionGuard.target(:qa_pass, %{settings: Config.settings_for_repo!("default")})
      assert %{to: ^merging, verdict: %{kind: "qa", outcome: "skip", head_sha: nil, reason: "skipped by decision"}} = accept.move
      assert rework.move == %{to: "Rework", finding: %{description: "Add a flag QA can set.", run_id: run_id, run_kind: "conductor"}}
      assert cancel.move == %{to: "Canceled"}
      refute Map.has_key?(rerun, :move)
      refute Enum.any?(options, &(Map.has_key?(&1, :action) or Map.has_key?(&1, :finding)))
    end

    test "every turn's prompt says it may move its ticket to a stage, and how to write the move (TP-1656)", _ctx do
      junctions = ~w(grooming message child_message sub_ticket_ended final_check after_coding after_qa_fail after_qa_blocked after_rework before_merge during_run)

      for junction <- junctions do
        prompt = Conductor.prompt(junction, %{})
        assert prompt =~ ~s("move": null or {"stage": "<one of the facts' stages), junction
        assert prompt =~ ~s(add `"move": {"stage": "<a stage>",), junction
        assert prompt =~ "one of the facts' `stages`", junction
        assert prompt =~ "same path and checks as a person's move", junction
        assert prompt =~ "is dropped", junction
      end
    end

    test "both prompts name the option actions, the one-question rule and the steps proved by a test", _ctx do
      for junction <- ["after_rework", "during_run"] do
        prompt = Conductor.prompt(junction, %{})
        for action <- Answer.actions(), do: assert(prompt =~ "`#{action}`")
        assert prompt =~ "`ticket.proved_steps`"
        assert prompt =~ "QA does not walk the"
        assert prompt =~ "A ticket waits on one question about its stage"
      end
    end

    test "a question with an action the ticket's phase can't take is not asked", _ctx do
      [_accept, rework | rest] = acting_question()["options"]
      no_accept = %{acting_question() | "options" => [Map.put(rework, "recommended", true) | rest]}

      for {phase, question, why} <- [
            {"Code Review", acting_question(), "accepts the change without QA, but the ticket is in Code Review, not QA"},
            {"Rework", no_accept, "sends the ticket to Rework, where it already is"}
          ] do
        fresh = fresh_ticket!(phase)
        log = capture_log(fn -> assert Conductor.run(plan(fresh), fresh.issue, turn: turn({:ok, [answer(%{"ask_person" => question})], 10}), facts: %{}) == :ok end)
        assert log =~ "Conductor's question was not asked"
        assert log =~ why
        assert SymphonyElixir.Questions.open({:ticket, "default", fresh.issue_id}) == []
        assert [%{payload: %{text: "Check the empty list first."}}] = events(fresh.issue_id, "conductor.instructions")
      end
    end

    test "a turn that fails, answers outside the schema, crashes or runs over writes nothing for the person", ctx do
      cases = [
        {turn({:error, :usage_limited, 5}), %{}, "failed"},
        {turn({:ok, ["no answer here"], 7}), %{}, "unreadable answer: the answer holds no JSON object"},
        {fn _plan, _issue, _run_id, _prompt -> raise "boom" end, %{}, "failed"},
        {fn _plan, _issue, _run_id, _prompt -> Process.sleep(1_000) end, %{timeout_ms: 20}, "timed out"}
      ]

      for {turn, attrs, exit} <- cases do
        log = capture_log(fn -> assert Conductor.run(plan(ctx, attrs), ctx.issue, turn: turn, facts: %{}) == :ok end)
        assert log =~ "Conductor turn wrote nothing"
        assert %{payload: %{exit: ^exit}} = List.last(events(ctx.issue_id, "run.ended"))
      end

      assert events(ctx.issue_id, "conductor.instructions") == []
      assert events(ctx.issue_id, "conductor.update") == []
      assert Enum.all?(RunStore.list_issue_runs("default", ctx.issue_id), &(&1.status == "failed"))
    end

    test "a turn that cannot be recorded or prompted is logged, never raised", ctx do
      log = capture_log(fn -> assert Conductor.run(plan(ctx, %{junction: "whenever", repo_key: nil}), ctx.issue, turn: turn({:ok, [answer()], 1}), facts: %{}) == :ok end)
      assert log =~ "Conductor could not record conductor.instructions"
      assert log =~ "Conductor could not record its run"

      log = capture_log(fn -> assert Conductor.run(plan(ctx), ctx.issue, turn: turn({:ok, [answer()], 1}), facts: %{bad: {:not, :json}}) == :ok end)
      assert log =~ "Conductor turn failed"
    end

    test "runs a harness session of runs.conductor in an empty folder with read-only tools", ctx do
      reply = {:ok, %{result: answer(%{"update" => "Ready for review."})}}
      Application.put_env(:symphony_elixir, :conductor_fake_agent, %{pid: self(), turn: reply})

      assert Conductor.run(plan(ctx), ctx.issue, agent_module: FakeAgent, facts: %{ticket: %{title: "Fix login"}}) == :ok
      assert_received {:session, folder, true, session_opts}
      assert session_opts[:tool_scope] == :read_only and session_opts[:read_only] == true
      refute Keyword.has_key?(session_opts, :issue)
      refute File.exists?(folder)
      assert_received {:turn, prompt, turn_opts}
      assert prompt =~ "The junction now: after_coding"
      assert prompt =~ ~s("title": "Fix login")
      assert turn_opts[:run_kind] == "conductor"
      assert [%{payload: %{text: "Ready for review."}}] = events(ctx.issue_id, "conductor.update")
      assert [%{payload: %{tokens: 321}}] = events(ctx.issue_id, "run.ended")

      Application.put_env(:symphony_elixir, :conductor_fake_agent, %{pid: self(), turn: {:error, :turn_failed}})
      capture_log(fn -> Conductor.run(plan(ctx), ctx.issue, agent_module: FakeAgent, facts: %{}) end)
      assert %{payload: %{exit: "failed", tokens: 321}} = List.last(events(ctx.issue_id, "run.ended"))

      no_session = %{pid: self(), session: {:error, :no_harness}, turn: nil}
      Application.put_env(:symphony_elixir, :conductor_fake_agent, no_session)
      log = capture_log(fn -> Conductor.run(plan(ctx), ctx.issue, agent_module: FakeAgent, facts: %{}) end)
      assert log =~ "session_failed"
    end
  end

  describe "route_blocked_qa/3" do
    defp blocked!(issue_id, head \\ "aaa"), do: record!(issue_id, "verdict.recorded", %{kind: "qa", outcome: "blocked", head: head, details: %{reason: "QA cannot fail the request"}})

    defp rework_route, do: %{"to" => "rework", "finding" => "Add a flag QA can set to make the state request fail."}

    test "nothing runs or is recorded while the Conductor is off or lacks the junction", ctx do
      blocked!(ctx.issue_id)
      never = fn _plan, _issue, _run_id, _prompt -> flunk("no turn runs") end

      assert Conductor.route_blocked_qa(ctx.issue, "default", turn: never) == :none
      assert Conductor.route_blocked_qa(ctx.issue, "default", turn: never, settings: %{@on | junctions: ["after_qa_fail"]}) == :none
      assert Conductor.route_blocked_qa(ctx.issue, nil, turn: never, settings: @on) == :none
      assert events(ctx.issue_id, "run.started") == []
    end

    test "a rework route within its bound is taken: the instructions record it, and the facts name the open routes", ctx do
      blocked!(ctx.issue_id)
      test = self()

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        routed(rework_route())
      end

      assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn, settings: @on) == {:rework, "Add a flag QA can set to make the state request fail."}
      assert_received {:prompt, prompt}
      assert prompt =~ "The junction now: after_qa_blocked (QA could not judge the change; you decide how the ticket gets a real QA result)"
      assert prompt =~ ~s("routes": [\n    "rerun",\n    "rework"\n  ])
      assert prompt =~ ~s("qa_passes": [)
      assert [%{payload: %{junction: "after_qa_blocked", route: "rework", text: "Check the empty list first."}}] = events(ctx.issue_id, "conductor.instructions")
      assert [%{payload: %{run_kind: "conductor", exit: "answered", tokens: 35_000}}] = events(ctx.issue_id, "run.ended")
    end

    test "a rerun route is taken while fewer than 3 passes in a row reached no result", ctx do
      blocked!(ctx.issue_id, "aaa")
      assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(%{"to" => "rerun"})), settings: @on) == :rerun

      # Main merged into the pull request: a new head, the same change, so the passes count on.
      blocked!(ctx.issue_id, "bbb")
      blocked!(ctx.issue_id, "ccc")

      log = capture_log(fn -> assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(%{"to" => "rerun"})), settings: @on) == :none end)
      assert log =~ "Conductor's route rerun dropped"
      assert log =~ "Symphony takes rework now"
      assert [%{payload: %{route: "rerun"}}, %{payload: dropped}] = events(ctx.issue_id, "conductor.instructions")
      refute Map.has_key?(dropped, :route)

      # A rework run ended: a new change, and a new count.
      ran!(ctx.issue_id, "rework")
      blocked!(ctx.issue_id, "ddd")
      assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(%{"to" => "rerun"})), settings: @on) == :rerun
    end

    test "a move decides where the ticket goes: a rerun given beside it is dropped, and the pass is told it moved (TP-1656)", ctx do
      blocked!(ctx.issue_id)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [ctx.issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      move = %{"stage" => "In Progress", "reason" => "QA cannot fail the request until a flag exists."}

      log = capture_log(fn -> assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(%{"to" => "rerun"}, %{"move" => move})), settings: @on) == :moved end)

      assert log =~ "Conductor's route rerun dropped"
      assert log =~ "the turn moves the ticket to In Progress"
      assert log =~ "Conductor moved the ticket from Code Review to In Progress"
      assert_received {:memory_tracker_state_update, _id, "In Progress"}
      assert %{phase: "In Progress"} = RunStore.get_ticket_state(ctx.issue_id)
      assert [%{payload: instructions}] = events(ctx.issue_id, "conductor.instructions")
      refute Map.has_key?(instructions, :route)
    end

    test "at most 2 routes to rework per ticket", ctx do
      for head <- ["aaa", "bbb"] do
        blocked!(ctx.issue_id, head)
        assert {:rework, _finding} = Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(rework_route())), settings: @on)
        ran!(ctx.issue_id, "rework")
      end

      blocked!(ctx.issue_id, "ccc")
      assert Conductor.open_routes(Facts.events(ctx.issue_id)) == ["rerun"]
      log = capture_log(fn -> assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(rework_route())), settings: @on) == :none end)
      assert log =~ "Conductor's route rework dropped"

      for head <- ["ddd", "eee"], do: blocked!(ctx.issue_id, head)
      assert Conductor.open_routes(Facts.events(ctx.issue_id)) == []
      log = capture_log(fn -> assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(%{"to" => "rerun"})), settings: @on) == :none end)
      assert log =~ "Symphony takes no route now"
    end

    test "a question holds the ticket, and a route given with it is dropped: the person decides", ctx do
      blocked!(ctx.issue_id)

      question = %{
        "title" => "QA needs a signing key",
        "question" => "Can you add the signing key to the QA host?",
        "why" => "Every pass stops at the signing step.",
        "if_unanswered" => "The ticket stays paused.",
        "recommendation_reason" => "Only you have the key.",
        "options" => [
          %{"label" => "I added it", "effect" => "QA runs again with the key.", "recommended" => true, "action" => "continue"},
          %{"label" => "Merge without it", "effect" => "You decide on the review alone.", "action" => "continue"}
        ]
      }

      log = capture_log(fn -> assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(rework_route(), %{"ask_person" => question})), settings: @on) == :held end)
      assert log =~ "Conductor's route rework dropped"
      assert [%{payload: %{title: "QA needs a signing key", asked_by: %{name: "Conductor"}}}] = events(ctx.issue_id, "question.asked")
      assert [%{payload: payload}] = events(ctx.issue_id, "conductor.instructions")
      refute Map.has_key?(payload, :route)
      assert Conductor.open_routes(Facts.events(ctx.issue_id)) == ["rerun", "rework"]
    end

    test "a turn that fails, answers no route or cannot be planned leaves QA as it would be without it", ctx do
      blocked!(ctx.issue_id)

      capture_log(fn -> assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn({:error, :usage_limited, 5}), settings: @on) == :none end)
      assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn({:ok, [answer()], 5}), settings: @on) == :none
      assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(nil)), settings: @on) == :none

      capture_log(fn -> assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(%{"to" => "merge"})), settings: @on) == :none end)
      assert %{payload: %{exit: "unreadable answer: `route` must be null" <> _rest}} = List.last(events(ctx.issue_id, "run.ended"))

      log = capture_log(fn -> assert Conductor.route_blocked_qa(ctx.issue, "default", settings: @on, available?: fn _run -> false end) == :none end)
      assert log =~ "no provider of runs.conductor can take a run now"

      log = capture_log(fn -> assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(rework_route())), settings: @on, events: :not_a_list) == :none end)
      assert log =~ "Conductor turn failed issue_id=#{ctx.issue_id}"
    end

    test "a route answered at another junction is never taken, and its facts name no routes", ctx do
      ran!(ctx.issue_id, "implementation")
      test = self()

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        routed(rework_route())
      end

      assert Conductor.run(plan(ctx), ctx.issue, turn: turn) == :ok
      assert_received {:prompt, prompt}
      refute prompt =~ ~s("routes":)
      # The budget counts the QA passes; only `after_qa_blocked` lists them.
      refute prompt =~ ~s("qa_passes": [)
      assert [%{payload: payload}] = events(ctx.issue_id, "conductor.instructions")
      refute Map.has_key?(payload, :route)
    end

    test "a ticket route that blocks files the ticket, holds the ticket on it and names it in the update", ctx do
      blocked!(ctx.issue_id)
      test = self()
      update = "QA could not build the app.\n\nNext: QA runs again once the build is fixed."

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        routed(ticket_route(), %{"update" => update})
      end

      assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn, settings: @on, filing: [fixer: FakeFixer]) == :held
      assert_received {:prompt, prompt}
      assert prompt =~ ~s("filings": {)
      assert prompt =~ ~s("left": 2)

      assert %{scope: "default", labels: ["tech debt"], title: "The QA build runs the Mac app build on a repo with none"} = Process.get(:conductor_filed)
      assert [%{payload: %{identifier: "TP-2000", kind: "split_off", by: "conductor"}}] = events(ctx.issue_id, "ticket.filed")
      assert [%{payload: %{route: "ticket"}}] = events(ctx.issue_id, "conductor.instructions")
      assert [%{payload: %{text: text}}] = events(ctx.issue_id, "conductor.update")

      assert text ==
               "QA could not build the app.\n\nI filed `TP-2000` as blocking this ticket: The QA build runs the Mac app build on a repo with none. " <>
                 "Cycle has no Mac app. This ticket waits for it to be Done, then continues where it stopped.\n\nNext: QA runs again once the build is fixed."

      assert [%{text: "Waiting for TP-2000 to finish" <> _rest}] = ctx.issue_id |> RunStore.get_ticket_state() |> TicketState.pause_reasons()
    end

    test "a blocking ticket filed whose hold cannot be set is named in the update and kept as the route, and the pass goes on", ctx do
      blocked!(ctx.issue_id)
      hold = fn _repo_key, _issue, _identifier -> {:error, :store_down} end
      answer = routed(ticket_route(), %{"update" => "QA could not build the app."})

      log =
        capture_log(fn ->
          assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(answer), settings: @on, filing: [fixer: FakeFixer, hold: hold]) == :none
        end)

      assert log =~ "Conductor filed TP-2000 (blocks)"
      assert log =~ "could not hold the ticket on it: :store_down"
      assert [%{payload: %{identifier: "TP-2000", by: "conductor"}}] = events(ctx.issue_id, "ticket.filed")
      assert [%{payload: %{route: "ticket"}}] = events(ctx.issue_id, "conductor.instructions")
      assert [%{payload: %{text: text}}] = events(ctx.issue_id, "conductor.update")
      assert text =~ "QA could not build the app.\n\nI filed `TP-2000` as blocking this ticket: "
      assert text =~ "This ticket could not be held on it (:store_down), so it goes on for now."
      assert ctx.issue_id |> RunStore.get_ticket_state() |> TicketState.pause_reasons() == []
    end

    test "a follow-up ticket route files it and leaves the pass going; a refused one is dropped and the message kept", ctx do
      blocked!(ctx.issue_id)
      follow_up = ticket_route(%{"relation" => "follow_up"})
      answer = routed(follow_up, %{"update" => "A Mac app build is missing."})
      assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(answer), settings: @on, filing: [fixer: FakeFixer]) == :none
      assert [%{payload: %{text: "A Mac app build is missing.\n\nI filed `TP-2000` as a follow-up: " <> _rest}}] = events(ctx.issue_id, "conductor.update")
      assert ctx.issue_id |> RunStore.get_ticket_state() |> TicketState.pause_reasons() == []

      elsewhere = ticket_route(%{"repo" => "nowhere"})

      log =
        capture_log(fn ->
          assert Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(elsewhere, %{"update" => "QA is stuck."})), settings: @on, filing: [fixer: FakeFixer]) ==
                   :none
        end)

      assert log =~ "Conductor's ticket route refused"
      assert log =~ ~s(names the repo "nowhere", which Symphony does not manage)
      assert [_follow_up, %{payload: %{text: "QA is stuck."}}] = events(ctx.issue_id, "conductor.update")
      assert [_follow_up, %{payload: refused}] = events(ctx.issue_id, "conductor.instructions")
      refute Map.has_key?(refused, :route)
    end

    test "the rework the route sends the ticket to meets no second turn before it starts", ctx do
      record!(ctx.issue_id, "run.started", %{run_id: "qa-1", run_kind: "qa"}, run_id: "qa-1")
      blocked!(ctx.issue_id)
      assert {:rework, _finding} = Conductor.route_blocked_qa(ctx.issue, "default", turn: turn(routed(rework_route())), settings: @on)
      record!(ctx.issue_id, "phase.entered", %{to: "Rework", from: "QA", via: "qa_blocked_rework", signal: "qa"})
      record!(ctx.issue_id, "run.ended", %{run_id: "qa-1", run_kind: "qa", exit: "normal"}, run_id: "qa-1")

      assert Conductor.dispatch_junction(:rework, Facts.events(ctx.issue_id)) == nil
      assert Conductor.plan(ctx.issue, :rework, "default", settings: @on) == nil

      # The rework run reads the turn's instructions.
      assert Conductor.prompt_section(ctx.issue_id, settings: @on) =~ "Check the empty list first."

      ran!(ctx.issue_id, "rework")
      assert Conductor.dispatch_junction(:qa, Facts.events(ctx.issue_id)) == "after_rework"
    end
  end

  describe "a ticket route at a dispatch junction" do
    test "after rework, a blocking ticket holds the run the turn came before", ctx do
      ran!(ctx.issue_id, "rework")
      plan = plan(ctx, %{junction: "after_rework"})
      assert Conductor.run(plan, ctx.issue, turn: turn(routed(ticket_route())), filing: [fixer: FakeFixer]) == :held
      assert [%{payload: %{junction: "after_rework", route: "ticket"}}] = events(ctx.issue_id, "conductor.instructions")
      # The answer had no update: the line naming the ticket is the update.
      assert [%{payload: %{text: "I filed `TP-2000` as blocking this ticket: " <> _rest}}] = events(ctx.issue_id, "conductor.update")
    end

    test "after coding, a ticket route is never read", ctx do
      ran!(ctx.issue_id, "implementation")
      assert Conductor.run(plan(ctx), ctx.issue, turn: turn(routed(ticket_route())), filing: [fixer: FakeFixer]) == :ok
      assert events(ctx.issue_id, "ticket.filed") == []
    end
  end

  describe "the next run's prompt" do
    test "carries the newest instructions only while the Conductor is on", ctx do
      assert Conductor.prompt_section(ctx.issue_id, settings: @on) == ""
      record!(ctx.issue_id, "conductor.instructions", %{junction: "after_coding", text: "Old advice."})
      record!(ctx.issue_id, "conductor.instructions", %{junction: "after_qa_fail", text: "Answer the login finding."})

      assert Conductor.prompt_section(ctx.issue_id) == ""
      assert Conductor.prompt_section(ctx.issue_id, settings: %Schema.Conductor{}) == ""
      assert Conductor.prompt_section(nil, settings: @on) == ""

      section = Conductor.prompt_section(ctx.issue_id, settings: @on)
      assert section =~ "\n\nAdvice from the Conductor"
      assert section =~ "<conductor_instructions>\nAnswer the login finding.\n</conductor_instructions>"
      refute section =~ "Old advice."

      off = PromptBuilder.build_prompt(ctx.issue)
      refute off =~ "Advice from the Conductor"

      append_symphony_yml!("conductor:\n  enabled: true\n")
      assert %Schema.Conductor{enabled: true, timeout_ms: 180_000} = Config.conductor_settings()
      assert PromptBuilder.build_prompt(ctx.issue) == off <> section
    end

    test "the Conductor's settings are its defaults while symphony.yml can't be read" do
      File.write!(Workflow.symphony_file_path(), "not: [valid")
      Cache.clear()
      assert Config.conductor_settings() == %Schema.Conductor{}
    end
  end

  test "the facts read the workspace's diff stat when it exists, and the repo's token cap", ctx do
    {:ok, workspace} = Workspace.local_path_for_issue(ctx.record.issue_identifier, "default")
    refute Map.has_key?(Facts.build(ctx.record, nil).last_run || %{}, :files_changed)
    File.mkdir_p!(workspace)
    git = fn args -> {_output, 0} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) end
    git.(["init", "-q"])
    git.(["-c", "user.email=t@e.st", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"])
    git.(["update-ref", "refs/remotes/origin/HEAD", "HEAD"])
    File.write!(Path.join(workspace, "b.txt"), "one\n")
    git.(["add", "b.txt"])
    git.(["-c", "user.email=t@e.st", "-c", "user.name=t", "commit", "-q", "-m", "change"])
    ran!(ctx.issue_id, "implementation")

    facts = Facts.build(ctx.record, "after_coding")
    assert facts.last_run.files_changed == [%{path: "b.txt", added: 1, removed: 0}]
    assert facts.budget.tokens_cap == Config.settings_for_repo!("default").execution.max_tokens_per_issue
  end

  test "plan_after_run/3 reads the Conductor's settings, off by default", ctx do
    ran!(ctx.issue_id, "qa")
    assert Conductor.plan_after_run(ctx.issue, :qa, "default") == nil
  end

  describe "waiving a check" do
    setup ctx do
      checks = [%{id: "c1", kind: "evidence", statement: "The export matches.", proof: "test"}, %{id: "c2", kind: "evidence", statement: "It signs in.", proof: "test"}]
      plan = %{shape: "single", layers: ["engine"], summary: "s", text: "t", checks: checks, size: %{tokens: 1, runs: 1}}
      {:ok, _plan} = SymphonyElixir.TicketPlan.write("default", ctx.issue_id, Map.merge(plan, %{reason: "Grooming", by: "grooming"}))
      :ok
    end

    test "a turn after coding waives a check nobody can prove, and drops one the plan does not hold", ctx do
      waive = [%{"check_id" => "c1", "reason" => "No test can reach the export."}, %{"check_id" => "c7", "reason" => "x"}]
      test = self()

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        {:ok, [answer(%{"waive" => waive})], 10}
      end

      log = capture_log(fn -> assert Conductor.run(plan(ctx), ctx.issue, turn: turn) == :ok end)

      assert log =~ "Conductor's waiver of c7 was dropped"
      assert [%{id: "c1", state: :waived, waived: %{reason: "No test can reach the export."}}, %{id: "c2", state: :open}] = SymphonyElixir.TicketChecks.list(ctx.issue_id)
      assert_received {:prompt, prompt}
      assert prompt =~ ~s("check_notes": [)
      assert prompt =~ "waive it"

      # A junction that may not waive reads none.
      no_waiver = plan(ctx, %{junction: "after_qa_fail"})
      assert Conductor.run(no_waiver, ctx.issue, turn: turn([answer(%{"waive" => [%{"check_id" => "c2", "reason" => "x"}]})] |> then(&{:ok, &1, 10}))) == :ok
      assert [_waived, %{id: "c2", state: :open}] = SymphonyElixir.TicketChecks.list(ctx.issue_id)
    end

    test "a watch turn may waive one too, and its prompt says so", ctx do
      run = %{issue_id: ctx.issue_id, run_id: "run-w-#{System.unique_integer([:positive])}", repo_key: "default", started_at: DateTime.utc_now()}
      test = self()

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        {:ok, [Jason.encode!(%{"instructions" => nil, "waive" => [%{"check_id" => "c2", "reason" => "The sign-in needs a live account."}]})], 5}
      end

      assert Conductor.watch(run, "step_failed_twice", turn: turn, settings: %{@on | watch: %{@on.watch | enabled: true}}) == :ok
      assert_received {:prompt, prompt}
      assert prompt =~ "`plan_checks`"
      assert prompt =~ ~s("waive": )
      assert [%{state: :open}, %{id: "c2", state: :waived}] = SymphonyElixir.TicketChecks.list(ctx.issue_id)
    end
  end

  describe "holding the merge (TP-1589)" do
    setup ctx do
      checks = [%{id: "c1", kind: "outcome", statement: "No marker is written.", proof: "test"}]
      plan = %{shape: "single", layers: ["logic"], summary: "s", text: "t", checks: checks, size: %{tokens: 1, runs: 1}}
      {:ok, _plan} = SymphonyElixir.TicketPlan.write("default", ctx.issue_id, Map.merge(plan, %{reason: "Grooming", by: "grooming"}))
      ran!(ctx.issue_id, "implementation")
      :ok
    end

    test "a turn before the merge holds it: the reason is the next run's instructions, and the code no longer stands for the ask", ctx do
      test = self()
      hold = %{"reason" => "The pull request merges the after-merge marker the person asked to remove."}

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        {:ok, [answer(%{"hold" => hold})], 10}
      end

      log = capture_log(fn -> assert Conductor.run(plan(ctx, %{junction: "before_merge"}), ctx.issue, turn: turn) == :ok end)

      assert log =~ "Conductor held the merge issue_id=#{ctx.issue_id}"
      assert SymphonyElixir.TicketJourney.outdated(ctx.issue_id) == :held
      assert [%{payload: %{route: "hold", junction: "before_merge", text: text}}] = events(ctx.issue_id, "conductor.instructions")
      assert text == "The pull request merges the after-merge marker the person asked to remove.\n\nCheck the empty list first."
      assert Conductor.prompt_section(ctx.issue_id, settings: @on) =~ "asked to remove"
      assert_received {:prompt, prompt}
      assert prompt =~ "The merge hold."
      assert prompt =~ ~s("hold": null or)
    end

    test "a hold alone is the instructions; a junction that may not hold reads none, and a failed turn holds nothing", ctx do
      hold = %{"reason" => "The plan changed under it."}

      capture_log(fn ->
        assert Conductor.run(plan(ctx, %{junction: "before_merge"}), ctx.issue, turn: turn({:ok, [Jason.encode!(%{"instructions" => nil, "hold" => hold})], 5})) == :ok
      end)

      assert [%{payload: %{route: "hold", text: "The plan changed under it."}}] = events(ctx.issue_id, "conductor.instructions")

      ran!(ctx.issue_id, "rework")
      assert Conductor.run(plan(ctx), ctx.issue, turn: turn({:ok, [answer(%{"hold" => hold})], 5})) == :ok
      assert SymphonyElixir.TicketJourney.outdated(ctx.issue_id) == nil

      capture_log(fn -> assert Conductor.run(plan(ctx, %{junction: "before_merge"}), ctx.issue, turn: turn({:error, :boom, 0})) == :ok end)
      assert SymphonyElixir.TicketJourney.outdated(ctx.issue_id) == nil
    end
  end

  describe "watch/3" do
    setup ctx do
      Steer.create_table()
      run = %{issue_id: ctx.issue_id, run_id: "run-watched-#{System.unique_integer([:positive])}", repo_key: "default", started_at: DateTime.utc_now()}
      %{run: Map.put(run, :run_profile, %{kind: :implementation, model: "m", harness: "claude"})}
    end

    defp watch_answer(attrs), do: {:ok, [Jason.encode!(Map.merge(%{"instructions" => nil}, attrs))], 5}

    defp steers(issue_id), do: events(issue_id, "conductor.steer")

    test "a steer for the next turn waits on the run, and its turn reads the run's live state", ctx do
      test = self()

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        watch_answer(%{"steer" => %{"message" => "Read the build error first.", "when" => "next_turn"}})
      end

      assert Conductor.watch(ctx.run, "step_failed", turn: turn, settings: %{@on | watch: %{@on.watch | enabled: true}}) == :ok
      assert_received {:prompt, prompt}
      assert prompt =~ "watching a run that is working on a ticket now"
      assert prompt =~ ~s("live": {)
      assert events(ctx.issue_id, "conductor.instructions") == []

      Steer.drop(ctx.run.run_id)
      assert [%{run_id: run_id, payload: %{text: "Read the build error first.", when: "next_turn", trigger: "step_failed"}}] = steers(ctx.issue_id)
      assert run_id == ctx.run.run_id
    end

    test "a watch update names the run, the trigger and whether the answer steered or stopped", ctx do
      steered = watch_answer(%{"update" => "I told the run to read the **build error** first.", "steer" => %{"message" => "Read it.", "when" => "now"}})
      assert Conductor.watch(ctx.run, "step_failed", turn: turn(steered), settings: @on) == :ok
      run_id = ctx.run.run_id

      assert [%{payload: %{text: "I told the run" <> _, watch: watch}}] = events(ctx.issue_id, "conductor.update")
      assert watch == %{run_id: run_id, trigger: "step_failed", steered: true, when: "now", stopped: false}

      Steer.drop(run_id)
      quiet = %{ctx.run | run_id: "run-quiet-#{System.unique_integer([:positive])}"}
      assert Conductor.watch(quiet, "run_minutes", turn: turn(watch_answer(%{"update" => "Thirty minutes in. I am leaving the run to work."})), settings: @on) == :ok

      assert [_first, %{payload: %{watch: quiet_watch}}] = events(ctx.issue_id, "conductor.update")
      assert quiet_watch == %{run_id: quiet.run_id, trigger: "run_minutes", steered: false, when: nil, stopped: false}
    end

    test "blocks are resolved from the records, the question block names the decision, and a block left empty is no key", ctx do
      record!(ctx.issue_id, "step.completed", %{step_id: "build", title: "Build", mode: "machine", outcome: "failed", returns_to: "code"}, run_id: ctx.run.run_id)

      question = %{
        "title" => "The run repeats the same failure",
        "question" => "Should the run end so you can look?",
        "why" => "It failed the same step three times.",
        "if_unanswered" => "The ticket stays paused.",
        "recommendation_reason" => "A fourth try would repeat the third.",
        "options" => [
          %{"label" => "End it", "effect" => "The run ends and waits for you.", "recommended" => true, "action" => "continue"},
          %{"label" => "Let it go on", "effect" => "The run goes on.", "action" => "continue"}
        ]
      }

      answer = watch_answer(%{"update" => "The build failed.", "blocks" => [%{"type" => "steps"}, %{"type" => "epic"}], "ask_person" => question})
      assert Conductor.watch(ctx.run, "step_failed", turn: turn(answer), settings: @on) == :ok

      assert [%{payload: %{blocks: [steps, asked]}}] = events(ctx.issue_id, "conductor.update")
      assert %{type: "steps", run_id: run_id, steps: [%{step_id: "build"}]} = steps
      assert %{type: "question", title: title, options: [%{label: "End it", recommended: true}, _other]} = asked

      assert run_id == ctx.run.run_id
      assert title == "The run repeats the same failure"

      Steer.drop(ctx.run.run_id)
      other = %{ctx.run | run_id: "run-other-#{System.unique_integer([:positive])}"}
      empty = watch_answer(%{"update" => "Nothing to draw.", "blocks" => [%{"type" => "epic"}]})
      capture_log(fn -> assert Conductor.watch(other, "run_minutes", turn: turn(empty), settings: @on) == :ok end)
      assert [_first, %{payload: payload}] = events(ctx.issue_id, "conductor.update")
      refute Map.has_key?(payload, :blocks)
    end

    test "a junction's blocks default to the last run", ctx do
      record!(ctx.issue_id, "run.started", %{run_id: "run-last", run_kind: "implementation"}, run_id: "run-last")
      record!(ctx.issue_id, "step.completed", %{step_id: "tests", title: "Tests", mode: "machine", outcome: "passed"}, run_id: "run-last")
      reply = {:ok, [answer(%{"update" => "Green.", "blocks" => [%{"type" => "steps"}]})], 5}
      facts = %{last_run: %{run_id: "run-last"}, budget: %{tokens_used: 0, tokens_cap: nil}}

      assert Conductor.run(plan(ctx), ctx.issue, turn: turn(reply), facts: facts) == :ok
      assert [%{payload: %{blocks: [%{type: "steps", run_id: "run-last", run_kind: "implementation"}]}}] = events(ctx.issue_id, "conductor.update")
    end

    test "a steer for now interrupts the run's live Claude turn", ctx do
      :ets.insert(:symphony_conductor_steer, {{:turn, ctx.run.run_id}, self()})
      turn = turn(watch_answer(%{"steer" => %{"message" => "Stop retrying; read the error.", "when" => "now"}}))

      assert Conductor.watch(ctx.run, "step_failed_twice", turn: turn) == :ok
      run_id = ctx.run.run_id
      assert_received {:conductor_interrupt, ^run_id, _sent_ms}

      # The orchestrator's running snapshot holds the profile as its struct.
      live = %{ctx.run | run_profile: %SymphonyElixir.Config.Runs.Run{kind: :implementation, harness: "claude", command: "claude", provider: "anthropic", model: "m"}}
      assert Conductor.watch(live, "step_failed_twice", turn: turn) == :ok
      assert_received {:conductor_interrupt, ^run_id, _sent_ms}

      other = %{ctx.run | run_profile: %{harness: "codex"}}
      assert Conductor.watch(other, "step_failed_twice", turn: turn) == :ok
      refute_received {:conductor_interrupt, _run_id, _sent_ms}

      assert Conductor.watch(%{ctx.run | run_profile: nil}, "step_failed_twice", turn: turn) == :ok
      refute_received {:conductor_interrupt, _run_id, _sent_ms}
      :ets.delete(:symphony_conductor_steer, {:turn, ctx.run.run_id})
    end

    test "a stop ends the run only when allowed and asked with a question, through the run-stop path", ctx do
      test = self()

      question = %{
        "title" => "The run repeats the same failure",
        "question" => "Should the run end so you can look?",
        "why" => "It failed the same step three times.",
        "if_unanswered" => "The ticket stays paused.",
        "recommendation_reason" => "A fourth try would repeat the third.",
        "options" => [
          %{"label" => "End it", "effect" => "The run ends and waits for you.", "recommended" => true, "action" => "continue"},
          %{"label" => "Let it go on", "effect" => "The run goes on.", "action" => "continue"}
        ]
      }

      stop = fn name -> tap({:ok, %{stopped: true}}, fn _ -> send(test, {:stopped, name}) end) end
      allowed = %{@on | watch: %{@on.watch | allow_stop: true}}
      answer = watch_answer(%{"stop" => %{"reason" => "It loops on the build."}, "ask_person" => question})

      assert Conductor.watch(Map.put(ctx.run, :identifier, "COND-1"), "step_failed_twice", turn: turn(answer), stop: stop, settings: allowed) == :ok
      assert_received {:stopped, "COND-1"}
      assert [%{payload: %{when: "stop", text: "It loops on the build.", delivered: %{how: "stopped"}}}] = steers(ctx.issue_id)

      log = capture_log(fn -> Conductor.watch(ctx.run, "run_minutes", turn: turn(answer), stop: fn _ -> :unavailable end, settings: allowed) end)
      assert log =~ "Conductor watch could not stop"

      no_question = watch_answer(%{"stop" => %{"reason" => "It loops."}})
      log = capture_log(fn -> Conductor.watch(ctx.run, "run_minutes", turn: turn(no_question), stop: stop, settings: allowed) end)
      assert log =~ "a stop needs conductor.watch.allow_stop and a question"
      refute_received {:stopped, _name}
    end
  end

  test "a turn's result reads as its text candidates and tokens" do
    assert Conductor.turn_result({:ok, %{result: "{}"}}, []) == {:ok, ["{}"], 0}
    # The Claude harness streams tuples: the deduplicated `token_usage` totals are the turn's tokens, not the result's.
    claude = [
      {:session_started, "s1"},
      {:token_usage, %{total_tokens: 12_000}},
      {:agent_text, "{}"},
      {:token_usage, %{total_tokens: 35_000}},
      {:turn_completed, %{total_tokens: 99_000}}
    ]

    assert {:ok, ["{}" | _], 35_000} = Conductor.turn_result({:ok, %{result: "{}"}}, claude)
    assert Conductor.turn_result({:ok, %{result: "{}"}}, [{:turn_completed, %{total_tokens: 7}}]) == {:ok, ["{}"], 7}
    assert Conductor.turn_result({:error, :boom}, [%{"tokenUsage" => %{"total" => %{"total_tokens" => 9}}}]) == {:error, :boom, 9}
  end
end
