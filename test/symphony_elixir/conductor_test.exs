defmodule SymphonyElixir.ConductorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Conductor, TicketEvents}
  alias SymphonyElixir.Conductor.{Facts, Steer}
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

  defp answer(attrs \\ %{}), do: Jason.encode!(Map.merge(%{"instructions" => "Check the empty list first."}, attrs))

  defp turn(reply), do: fn _plan, _issue, _run_id, _prompt -> reply end

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
          %{"label" => "Start over", "effect" => "The next rework starts from the ticket again.", "recommended" => true},
          %{"label" => "Wait", "effect" => "Nothing runs until you say."}
        ]
      }

      assert Conductor.run(plan(ctx), ctx.issue, turn: turn({:ok, [answer(%{"ask_person" => question})], 10}), facts: %{}) == :held
      assert [%{payload: %{title: "Login failed three times", asked_by: %{name: "Conductor"}}}] = events(ctx.issue_id, "question.asked")
      assert SymphonyElixir.Pauses.paused?({:ticket, "default", ctx.issue_id})

      # A question whose Linear comment could not be posted still stands, so it still holds the run.
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :linear_down})
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result) end)

      other = %{question | "title" => "The budget is nearly spent", "question" => "Should the next run go on?"}
      log = capture_log(fn -> assert Conductor.run(plan(ctx), ctx.issue, turn: turn({:ok, [answer(%{"ask_person" => other})], 10}), facts: %{}) == :held end)
      assert log =~ "Failed to post the decision request"

      bad = Map.put(question, "options", [%{"label" => "A", "effect" => "x", "recommended" => true}, %{"label" => "B", "effect" => "y", "recommended" => true}])
      log = capture_log(fn -> assert Conductor.run(plan(ctx), ctx.issue, turn: turn({:ok, [answer(%{"ask_person" => bad})], 10}), facts: %{}) == :ok end)
      assert log =~ "Conductor's question was not asked"
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
          %{"label" => "End it", "effect" => "The run ends and waits for you.", "recommended" => true},
          %{"label" => "Let it go on", "effect" => "The run goes on."}
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
          %{"label" => "End it", "effect" => "The run ends and waits for you.", "recommended" => true},
          %{"label" => "Let it go on", "effect" => "The run goes on."}
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
