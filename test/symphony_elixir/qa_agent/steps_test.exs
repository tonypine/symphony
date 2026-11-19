defmodule SymphonyElixir.QaAgent.StepsTest do
  # A stepped QA pass (`SymphonyElixir.QaAgent.Steps`): the walk of a QA playbook's step list.
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Conductor.Steer
  alias SymphonyElixir.Config.Runs.Run
  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.Config.Schema.Phases.Step
  alias SymphonyElixir.{QaAgent, TicketEvents}
  alias SymphonyElixir.QaAgent.{StepPrompts, Steps}

  @issue_id "issue-qa-steps"
  @answers :qa_steps_test_answers
  @recipient :qa_steps_test_recipient
  @tools :qa_steps_test_tools

  # Answers each turn from `:qa_steps_test_answers`: per step id (or the id before its `_<n>`), a
  # list of what the turn does, the last one repeating: `{:write, map}` writes the answer file,
  # `{:verdict, map}` calls `qa_verdict`, `{:raw, text}` writes text, `:nothing`, `{:error, reason}`
  # fails the turn, `{:messages, list}` sends those messages first, `{:record, outcome}` records the
  # step's end as the agent.
  defmodule FakeAgent do
    alias SymphonyElixir.Codex.DynamicTool

    def start_session(worktree, opts) do
      send(recipient(), {:session_started, worktree, opts})
      {:ok, %{opts: opts}}
    end

    def run_turn(session, prompt, _issue, opts) do
      [_, id] = Regex.run(~r/This turn is the `([a-z0-9_]+)` step/, prompt)
      send(recipient(), {:turn, id, prompt, session.opts, opts})
      act(next_action(id), id, session.opts, opts)
    end

    def stop_session(_session), do: :ok

    defp act({:write, answer}, id, session_opts, _opts), do: act({:raw, Jason.encode!(answer)}, id, session_opts, nil)

    defp act({:raw, text}, id, session_opts, _opts) do
      File.write!(Path.join(session_opts[:agent_tmp_dir], "symphony-step-answer-#{id}.json"), text)
      {:ok, %{session_id: "session-#{id}"}}
    end

    defp act({:verdict, verdict}, _id, session_opts, _opts) do
      response = DynamicTool.execute("qa_verdict", verdict, Keyword.take(session_opts, [:tool_scope, :qa_verdict_sink]))
      send(recipient(), {:verdict_response, response})
      {:ok, %{session_id: "session-review"}}
    end

    defp act({:messages, messages, then}, id, session_opts, opts) do
      Enum.each(messages, opts[:on_message])
      act(then, id, session_opts, opts)
    end

    defp act({:then_messages, first, messages}, id, session_opts, opts) do
      result = act(first, id, session_opts, opts)
      Enum.each(messages, opts[:on_message])
      result
    end

    defp act({:record, outcome}, id, session_opts, _opts) do
      {:ok, _event} =
        SymphonyElixir.TicketEvents.record(
          "default",
          "issue-qa-steps",
          "step.completed",
          Map.merge(%{step_id: id, title: id, mode: "delegated", outcome: outcome}, if(outcome == "failed", do: %{returns_to: id}, else: %{})),
          actor: {:agent, session_opts[:run_id], "qa"}
        )

      {:ok, %{session_id: nil}}
    end

    defp act(:nothing, _id, _session_opts, _opts), do: {:ok, %{}}
    defp act({:error, reason}, _id, _session_opts, _opts), do: {:error, reason}

    defp next_action(id) do
      answers = Application.get_env(:symphony_elixir, :qa_steps_test_answers, %{})
      key = Enum.find([id, String.replace(id, ~r/_\d+$/, ""), String.replace(id, ~r/^recheck_\d+_\d+$/, "recheck")], &Map.has_key?(answers, &1))

      case Map.get(answers, key, [{:write, pass_answer()}]) do
        [action | [_ | _] = rest] ->
          Application.put_env(:symphony_elixir, :qa_steps_test_answers, Map.put(answers, key, rest))
          action

        [action] ->
          action
      end
    end

    def pass_answer, do: %{status: "pass", expected: "It shows", actual: "It shows", details: "fixture: running", evidence: ["qa-evidence/step.png"]}

    defp recipient, do: Application.fetch_env!(:symphony_elixir, :qa_steps_test_recipient)
  end

  # The QA driver's calls, answered from `:qa_steps_test_tools` (a tool name to its result).
  defmodule FakeDriver do
    def call_tool(driver, tool, args) do
      send(Application.fetch_env!(:symphony_elixir, :qa_steps_test_recipient), {:tool, driver, tool, args})
      Map.get(Application.get_env(:symphony_elixir, :qa_steps_test_tools, %{}), tool, {:ok, %{}})
    end

    def launched_pids(_driver), do: [4242]
  end

  setup do
    :ok = RunStore.clear()
    Application.put_env(:symphony_elixir, @recipient, self())
    root = Path.join(System.tmp_dir!(), "qa-steps-#{System.unique_integer([:positive])}")
    worktree = Path.join(root, "worktree")
    tmp_dir = Path.join(root, "tmp")
    File.mkdir_p!(Path.join(worktree, "qa-evidence"))
    File.mkdir_p!(tmp_dir)

    Application.put_env(:symphony_elixir, @tools, %{
      "qa_build" => {:ok, %{"exit_status" => 0, "output" => "Symphony built this commit's app."}},
      "qa_launch_app" => {:ok, %{"pid" => 4242, "root" => 1, "environment" => "fixture"}},
      "qa_check_app" => {:ok, %{"healthy" => true}},
      "qa_quit_app" => {:ok, %{"quit" => true, "output" => "bye"}},
      "qa_gallery" => {:ok, %{"entries" => [%{"entry" => "button"}], "affected" => ["button"]}}
    })

    on_exit(fn ->
      Enum.each([@answers, @recipient, @tools], &Application.delete_env(:symphony_elixir, &1))
      File.rm_rf(root)
    end)

    %{worktree: worktree, tmp_dir: tmp_dir}
  end

  defp walkthrough(numbers), do: for(number <- numbers, do: %{number: number, text: "Step #{number}: open page #{number}.", proof: %{by: :qa}})

  defp job(attrs \\ %{}) do
    Map.merge(
      %{
        issue: %Issue{id: @issue_id, identifier: "TP-77", title: "A new page", description: "## User walkthrough\n1. Open it.", state: "QA"},
        sha: "abc123",
        repo_key: "default",
        run_id: "qa-steps-run",
        playbooks: [%{kind: "macos_app", prompt: "Intro.\nServers the app talks to: stand-ins.\nScreen rules here.\nQA does three things.\nSteps."}],
        journey: %{source: "the ticket", text: "1. Open it.", steps: walkthrough([1, 2])},
        proofs: [],
        token_limit: nil,
        run_profile: %Run{kind: :qa, harness: "claude", command: "claude", provider: "anthropic", model: "claude-big", effort: "medium", small_model: "claude-small"}
      },
      attrs
    )
  end

  defp run(ctx, attrs \\ %{}, opts \\ [], steps \\ Phases.default_qa_steps("macos_app")) do
    opts =
      Keyword.merge(
        [
          qa_tmp_dir: ctx.tmp_dir,
          qa_driver: self(),
          qa_driver_module: FakeDriver,
          qa_step_runner: fn _command, _env, _timeout -> {:ok, {"", 0}} end,
          qa_launch_settle_ms: 0,
          qa_parent: nil
        ],
        opts
      )

    steps = Enum.map(steps, &step/1)
    {result, _log} = with_log(fn -> Steps.run(FakeAgent, job(attrs), ctx.worktree, QaAgent.qa_settings(Config.settings!()), steps, opts) end)
    result
  end

  defp answers(map), do: Application.put_env(:symphony_elixir, @answers, map)

  defp plan(numbers, extra \\ %{}) do
    Map.merge(
      %{
        needs_app: true,
        walk: for(number <- numbers, do: %{step: number, where: "Page #{number}", do: "Open it", expect: "It shows", screenshots: ["page-#{number}"]}),
        gallery: [%{entry: "button", variations: ["primary"]}],
        notes: "Look at the button."
      },
      extra
    )
  end

  @pass %{"verdict" => "pass", "summary" => "Every step behaved.", "steps" => [%{"name" => "Step 1", "status" => "pass", "details" => "shown"}]}
  @fail %{"verdict" => "fail", "summary" => "It broke.", "findings" => ["The app crashed at launch."]}

  defp turns do
    receive_turns([])
  end

  defp receive_turns(acc) do
    receive do
      {:turn, id, prompt, session_opts, turn_opts} ->
        receive_turns([%{id: id, prompt: prompt, session: session_opts, turn: turn_opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp events(type), do: @issue_id |> TicketEvents.query(types: [type], limit: 500) |> Enum.sort_by(& &1.seq)

  describe "list/2" do
    test "walks a list only when the switch is on and the pass runs one playbook that has one" do
      steps = Phases.default_qa_steps("macos_app")
      phases = fn qa -> {:ok, %{phases: struct(Phases, qa: qa)}} end
      on = phases.(%Phases.QaPhase{stepped: true})

      assert Steps.list(job(), qa_system: on) == steps
      assert Steps.list(job(), qa_system: phases.(%Phases.QaPhase{stepped: false})) == []
      assert Steps.list(job(), qa_system: {:ok, %{phases: %Phases{}}}) == []
      assert Steps.list(job(%{playbooks: [%{kind: "cli"}]}), qa_system: on) == []
      assert Steps.list(job(%{playbooks: [%{kind: "macos_app"}, %{kind: "cli"}]}), qa_system: on) == []
      assert Steps.list(job(%{epic_review: true}), qa_system: on) == []
      assert Steps.list(job(), qa_system: {:error, :missing}) == []
      assert Steps.list(job(), qa_step_list: [:given]) == [:given]
      assert is_list(Steps.list(job(%{playbooks: []}), []))
    end
  end

  describe "the default macos_app list" do
    test "walks every step in order, recording each on the ticket under the pass's run, and gives the review's verdict", ctx do
      answers(%{"plan" => [{:write, plan([1, 2])}], "review" => [{:verdict, @pass}]})

      messages = [%{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}}}]
      answers(%{"plan" => [{:messages, messages, {:write, plan([1, 2])}}], "review" => [{:verdict, @pass}]})

      assert {:ok, %{result: %{verdict: :pass, summary: "Every step behaved."}, tokens: tokens, session_id: "session-review"}} = run(ctx)
      assert tokens.total_tokens == 15

      turns = turns()
      assert Enum.map(turns, & &1.id) == ["plan", "walk_1", "walk_2", "design_check", "wide_pass", "review"]

      completed = events("step.completed")

      assert Enum.map(completed, &{&1.payload.step_id, &1.payload.outcome}) == [
               {"pre_checks", "passed"},
               {"build", "passed"},
               {"plan", "passed"},
               {"launch", "passed"},
               {"walk_1", "passed"},
               {"walk_2", "passed"},
               {"design_check", "passed"},
               {"wide_pass", "passed"},
               {"quit", "passed"},
               {"attach", "passed"},
               {"review", "passed"}
             ]

      assert Enum.all?(completed, &(&1.run_id == "qa-steps-run"))

      started = Map.new(events("step.started"), &{&1.payload.step_id, &1.payload})
      assert %{model: "claude-big", effort: "high", session: "lead"} = started["plan"]
      assert %{model: "claude-small", effort: "medium", session: "fresh"} = started["walk_1"]

      # The answers ride on their steps' own `step.completed`; no note is written.
      assert events("note") == []
      by_step = Map.new(completed, &{&1.payload.step_id, &1.payload})

      assert %{
               checks: [%{title: "Step 1: Page 1", expect: "It shows"}, %{title: "Step 2: Page 2"}, %{title: "Gallery: button", expect: "primary"}],
               skips: [],
               summary: "QA plan. Needs the app: yes." <> _
             } = by_step["plan"].plan

      assert by_step["walk_1"].result == %{status: "pass", expected: "It shows", actual: "It shows"}
      assert %{result: %{status: "pass"}} = by_step["design_check"]
      assert by_step["review"].verdict_summary == "Every step behaved."
      refute Map.has_key?(by_step["build"], :result)

      [plan_turn, walk_1, _walk_2, design, _wide, review] = turns
      assert plan_turn.prompt =~ "You plan this QA pass"
      assert plan_turn.prompt =~ "Screen rules here."
      assert plan_turn.prompt =~ "- Step 2: Step 2: open page 2."
      assert plan_turn.prompt =~ ~s("affected")
      refute walk_1.prompt =~ "Screen rules here."
      assert walk_1.prompt =~ "Step 1: open page 1."
      assert walk_1.prompt =~ ~s("where": "Page 1")
      assert walk_1.prompt =~ "Symphony launched it as PID 4242"
      assert design.prompt =~ ~s("entry": "button")
      assert review.prompt =~ "Earlier steps of this run answered"
      assert review.prompt =~ "- `build` (Build the app): passed"
      assert walk_1.session[:run_profile].model == "claude-small"
      assert walk_1.session[:qa_verdict_sink] == nil
      assert review.session[:qa_verdict_sink] == self()
      assert review.turn[:resume_session_id] == "session-plan"
      refute Keyword.has_key?(walk_1.turn, :resume_session_id)

      assert_received {:tool, _driver, "qa_launch_app", %{}}
      assert_received {:tool, _driver, "qa_check_app", %{"pid" => 4242, "page" => "launch"}}
      assert_received {:tool, _driver, "qa_quit_app", %{"pid" => 4242}}
    end

    test "asks the plan again when it drops a walkthrough step, and walks each step's text with its brief", ctx do
      answers(%{"plan" => [{:write, plan([1])}, {:write, plan([1, 2])}], "review" => [{:verdict, @pass}]})

      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx)
      [first, second | _rest] = turns()
      assert {first.id, second.id} == {"plan", "plan"}
      assert second.prompt =~ "Your last answer was refused: the plan's `walk` has no brief for walkthrough step 2, which QA walks"
      assert second.turn[:resume_session_id] == "session-plan"
    end

    test "with nothing on screen to judge still launches and checks the app, skips the design check and wide pass, and passes with scope none",
         ctx do
      answers(%{"plan" => [{:write, plan([], %{needs_app: false, gallery: []})}], "review" => [{:verdict, @pass}]})

      assert {:ok, %{result: %{verdict: :pass, scope: :none}}} = run(ctx, %{journey: %{steps: []}})
      assert Enum.map(turns(), & &1.id) == ["plan", "review"]
      assert_received {:tool, _driver, "qa_launch_app", %{}}
      assert_received {:tool, _driver, "qa_check_app", %{"pid" => 4242, "page" => "launch"}}

      outcomes = Map.new(events("step.completed"), &{&1.payload.step_id, &1.payload})
      assert %{outcome: "passed"} = outcomes["launch"]
      assert outcomes["design_check"].reason =~ "the plan found nothing on screen to judge"
      assert outcomes["wide_pass"].reason =~ "the plan found nothing on screen to judge"

      # A fail stays a fail, with no scope.
      answers(%{"plan" => [{:write, plan([], %{needs_app: false, gallery: []})}], "review" => [{:verdict, @fail}]})
      :ok = RunStore.clear()
      assert {:ok, %{result: %{verdict: :fail} = failed}} = run(ctx, %{journey: %{steps: []}})
      refute Map.has_key?(failed, :scope)
    end

    test "a recheck the review asks for runs even when the plan found nothing on screen", ctx do
      answers(%{
        "plan" => [{:write, plan([], %{needs_app: false, gallery: []})}],
        "review" => [{:write, %{recheck: [%{where: "The menu"}]}}, {:verdict, @pass}]
      })

      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx, %{journey: %{steps: []}})
      assert Enum.map(turns(), & &1.id) == ["plan", "review", "recheck_1_1", "review"]
    end

    test "a build that failed goes to the quit, and the review sees it", ctx do
      tools = Application.get_env(:symphony_elixir, @tools)
      Application.put_env(:symphony_elixir, @tools, Map.put(tools, "qa_build", {:ok, %{"exit_status" => 2, "output" => "error: no such module"}}))
      answers(%{"review" => [{:verdict, @pass}]})

      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx)
      [review] = turns()
      assert review.prompt =~ "- `build` (Build the app): failed: $ symphony:qa_build\nerror: no such module"
      assert review.prompt =~ "(exit status 2)"
    end

    test "an app that is not healthy after its launch fails the launch, and the steps that drive it are skipped", ctx do
      tools = Application.get_env(:symphony_elixir, @tools)
      Application.put_env(:symphony_elixir, @tools, Map.put(tools, "qa_check_app", {:ok, %{"healthy" => false, "problems" => ["exited"]}}))
      answers(%{"plan" => [{:write, plan([1, 2])}], "review" => [{:verdict, @pass}]})

      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx)
      assert Enum.map(turns(), & &1.id) == ["plan", "review"]
    end

    test "a driver error is the machine step's output", ctx do
      Application.put_env(:symphony_elixir, @tools, %{
        "qa_build" => {:error, {:qa_tool, "qa_build_unavailable", "no build"}},
        "qa_launch_app" => {:error, :down},
        "qa_quit_app" => {:error, {:qa_tool, "qa_no_app", "gone"}},
        "qa_gallery" => {:error, {:qa_tool, "qa_no_build", "no gallery"}}
      })

      answers(%{"review" => [{:verdict, @pass}]})
      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx)
      [review] = turns()
      assert review.prompt =~ "qa_build_unavailable: no build"

      assert {:ok, %{result: %{verdict: :pass}}} =
               run(ctx, %{}, [], [
                 machine("launch", "symphony:qa_launch", %{"on_fail" => "quit"}),
                 machine("quit", "symphony:qa_quit"),
                 review()
               ])

      [review] = turns()
      assert review.prompt =~ ":down"
      assert review.prompt =~ "Quit 4242: qa_no_app: gone"
    end

    test "the plan reads the gallery's error, and a pass with no driver reads none", ctx do
      tools = Application.get_env(:symphony_elixir, @tools)
      Application.put_env(:symphony_elixir, @tools, Map.put(tools, "qa_gallery", {:error, {:qa_tool, "qa_no_build", "no gallery"}}))
      answers(%{"plan" => [{:write, plan([1, 2])}], "review" => [{:verdict, @pass}]})

      assert {:ok, _result} = run(ctx, %{}, [], [plan_step(), review()])
      [plan_turn, _review] = turns()
      assert plan_turn.prompt =~ "The Component Gallery could not be read: qa_no_build: no gallery"

      assert {:ok, _result} = run(ctx, %{playbooks: [%{kind: "macos_app"}]}, [qa_driver: nil], [plan_step(), review()])
      [plan_turn, _review] = turns()
      refute plan_turn.prompt =~ "Component Gallery"
    end
  end

  describe "the Conductor's steer" do
    test "a steer waiting for the pass opens its next step's prompt, recorded as delivered there", ctx do
      path = Workflow.symphony_file_path()
      File.write!(path, File.read!(path) <> "conductor:\n  enabled: true\n  watch:\n    enabled: true\n")
      Cache.clear()
      Steer.create_table()

      Steer.queue("qa-steps-run", %{
        text: "The plan missed step 2; walk it.",
        when: "next_turn",
        trigger: "qa_step_answer",
        repo_key: "default",
        issue_id: @issue_id
      })

      answers(%{"plan" => [{:write, plan([1, 2])}], "review" => [{:verdict, @pass}]})
      assert {:ok, _run} = run(ctx)

      [first | rest] = turns()
      assert first.prompt =~ ~r/\AGuidance from the Conductor/
      assert first.prompt =~ "The plan missed step 2; walk it."
      refute Enum.any?(rest, &(&1.prompt =~ "Guidance from the Conductor"))
      assert [%{run_id: "qa-steps-run", payload: %{delivered: %{how: "next_turn"}}}] = events("conductor.steer")
    end
  end

  describe "the review" do
    test "may ask for a recheck: the launch again, a fresh walk per brief, the quit and evidence, then the review again", ctx do
      recheck = %{recheck: [%{step: 2, where: "Page 2, scrolled", do: "Scroll", expect: "Row 9 shows"}]}
      answers(%{"plan" => [{:write, plan([1, 2])}], "review" => [{:write, recheck}, {:verdict, @pass}]})

      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx)
      ids = Enum.map(turns(), & &1.id)
      assert Enum.take(ids, -3) == ["review", "recheck_1_1", "review"]

      completed = Enum.map(events("step.completed"), & &1.payload.step_id)
      assert Enum.take(completed, -6) == ["review", "launch", "recheck_1_1", "quit", "attach", "review"]
      assert events("note") == []

      assert [%{payload: %{recheck: [%{title: "Step 2: Page 2, scrolled", do: ["Scroll"], expect: "Row 9 shows"}]}}] =
               Enum.filter(events("step.completed"), &Map.has_key?(&1.payload, :recheck))

      assert %{result: %{status: "pass"}} = events("step.completed") |> Enum.find(&(&1.payload.step_id == "recheck_1_1")) |> Map.fetch!(:payload)
    end

    test "a recheck turn walks its own brief and the walkthrough step it names", ctx do
      recheck = %{recheck: [%{step: "2", where: "Page 2, scrolled"}, %{where: "The menu"}]}
      answers(%{"plan" => [{:write, plan([1, 2])}], "review" => [{:write, recheck}, {:verdict, @pass}]})

      assert {:ok, _result} = run(ctx)
      [first, second] = Enum.filter(turns(), &String.starts_with?(&1.id, "recheck_"))
      assert first.prompt =~ "Page 2, scrolled"
      assert first.prompt =~ "Step 2: open page 2."
      assert second.prompt =~ "The menu"
      refute second.prompt =~ "The walkthrough step you walk"
    end

    test "is inconclusive past two rounds of recheck", ctx do
      answers(%{"plan" => [{:write, plan([1, 2])}], "review" => [{:write, %{recheck: [%{step: 1}]}}]})

      assert {:ok, %{result: %{verdict: :inconclusive, reason: reason}}} = run(ctx)
      assert reason =~ "after its 2 rounds of recheck"
      assert Enum.count(turns(), &(&1.id == "review")) == 3
    end

    test "a recheck the list cannot run, or a malformed one, is refused and asked again", ctx do
      answers(%{"review" => [{:write, %{recheck: [%{step: 1}]}}, {:verdict, @pass}]})
      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx, %{}, [], [review()])
      [_first, second] = turns()
      assert second.prompt =~ "has no `repeat: walkthrough` step to recheck with"

      answers(%{"plan" => [{:write, plan([1, 2])}], "review" => [{:write, %{recheck: [1, 2, 3, 4]}}, {:verdict, @pass}]})
      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx)
      assert List.last(turns()).prompt =~ "`recheck` must be a list of one to 3 briefs"
    end

    test "takes a verdict written to the answer file, and refuses one that does not read", ctx do
      answers(%{"review" => [{:raw, "not json"}, {:write, %{verdict: "maybe"}}]})
      assert {:error, {:malformed_qa_response, :no_verdict_object}, _tokens} = run(ctx, %{}, [], [review()])
      [first, second] = turns()
      assert first.prompt =~ "Write a recheck, or the verdict when `qa_verdict` is not available, to `"
      assert second.prompt =~ "the answer file does not hold a JSON object"

      answers(%{"review" => [{:write, %{verdict: "maybe"}}, {:write, @pass}]})
      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx, %{}, [], [review()])
      assert List.last(turns()).prompt =~ "the verdict in the answer file was refused: `verdict` must be one of pass, fail or blocked."

      answers(%{"review" => [:nothing]})
      assert {:error, {:malformed_qa_response, :no_verdict_object}, _tokens} = run(ctx, %{}, [], [review()])
      assert List.last(turns()).prompt =~ "no verdict was recorded with `qa_verdict`, and no answer was written to"
    end
  end

  describe "agent steps" do
    test "a judged answer with an unknown status is refused, and a step that answers nothing twice fails on to the next", ctx do
      answers(%{
        "look" => [{:write, %{FakeAgent.pass_answer() | status: "great"}}, :nothing],
        "review" => [{:verdict, @pass}]
      })

      steps = [orchestrated("look", %{"answer" => %{"status" => "string"}}), review()]
      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx, %{}, [], steps)

      [first, second, review_turn] = turns()
      assert {first.id, second.id} == {"look", "look"}
      assert second.prompt =~ "`status` must be one of pass, fail, blocked, plan_mismatch"
      assert review_turn.prompt =~ "- `look` (look): failed: no answer was written to"

      assert [%{payload: %{outcome: "failed", returns_to: "review", reason: reason}}, _review] = events("step.completed")
      assert reason =~ "gave no answer Symphony takes: no answer was written to"
      assert events("note") == []
    end

    test "a verdict with no summary puts none on the review's step", ctx do
      answers(%{"review" => [{:verdict, Map.delete(@pass, "summary")}]})
      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx, %{}, [], [review()])
      assert [%{payload: payload}] = events("step.completed")
      refute Map.has_key?(payload, :verdict_summary)
    end

    test "a step that could not judge answers blocked: the pass goes on and the review sees it, never as a pass", ctx do
      blocked = %{status: "blocked", expected: "Rows show", actual: "The page showed only its empty state; nothing was judged"}
      answers(%{"look" => [{:write, blocked}], "review" => [{:verdict, @pass}]})

      steps = [orchestrated("look", %{"answer" => %{"status" => "string"}}), review()]
      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx, %{}, [], steps)

      [look, review_turn] = turns()
      assert look.prompt =~ "`pass` only when every check in its brief was actually seen and judged"
      assert review_turn.prompt =~ "- `look` (look): passed"
      assert review_turn.prompt =~ "empty state; nothing was judged"
      assert review_turn.prompt =~ ~s("status":"blocked")

      assert [%{payload: %{outcome: "passed", result: %{status: "blocked", actual: "The page showed only" <> _}}}, _review] = events("step.completed")
    end

    test "a failed agent step with an on_fail goes there", ctx do
      answers(%{"look" => [:nothing], "review" => [{:verdict, @pass}]})
      steps = [orchestrated("look", %{"answer" => %{"x" => "string"}, "on_fail" => "review"}), orchestrated("skipped_over"), review()]

      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx, %{}, [], steps)
      assert Enum.map(turns(), & &1.id) == ["look", "look", "review"]
    end

    test "a delegated step ends with the step's end its agent records", ctx do
      answers(%{"work" => [:nothing, {:record, "passed"}], "review" => [{:verdict, @pass}]})
      steps = [%{"id" => "work", "mode" => "delegated"}, review()]

      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx, %{}, [], steps)
      [_first, second, _review] = turns()
      assert second.prompt =~ "Reminder: the last turn ended without recording `step.completed`"

      answers(%{"work" => [{:record, "failed"}], "review" => [{:verdict, @pass}]})
      :ok = RunStore.clear()
      assert {:ok, _result} = run(ctx, %{}, [], steps)
    end

    test "steps of one session continue it, a fresh one starts its own, and steps with none share the pass's", ctx do
      answers(%{"review" => [{:verdict, @pass}]})

      steps = [
        orchestrated("one"),
        orchestrated("two"),
        orchestrated("alone", %{"session" => "fresh"}),
        orchestrated("named", %{"session" => "lead"}),
        review()
      ]

      answers(%{
        "one" => [{:raw, "{}"}],
        "two" => [{:raw, "{}"}],
        "alone" => [{:raw, "{}"}],
        "named" => [{:raw, "{}"}],
        "review" => [{:verdict, @pass}]
      })

      assert {:ok, _result} = run(ctx, %{}, [], steps)
      resumes = Map.new(turns(), &{&1.id, &1.turn[:resume_session_id]})
      assert resumes["one"] == nil
      assert resumes["two"] == "session-one"
      assert resumes["alone"] == nil
      assert resumes["named"] == nil
      assert resumes["review"] == "session-two"
    end

    test "a run on a fallback provider keeps its model, and says so on the step's start", ctx do
      answers(%{"look" => [{:raw, "{}"}], "review" => [{:verdict, @pass}]})
      profile = %Run{kind: :qa, harness: "claude", command: "claude", provider: "openrouter", model: "fallback-model", fallback: 0}

      assert {:ok, _result} = run(ctx, %{run_profile: profile}, [], [orchestrated("look", %{"model" => "claude-big", "effort" => "low"}), review()])
      [look | _rest] = turns()
      assert look.session[:run_profile].model == "fallback-model"
      assert look.session[:run_profile].effort == "low"

      assert [%{payload: %{model: "fallback-model", model_ignored: "claude-big", model_ignored_reason: "the run started on a fallback provider"}}, _review] =
               events("step.started")
    end

    test "a pass with no run profile runs on the settings' own", ctx do
      answers(%{"review" => [{:verdict, @pass}]})
      assert {:ok, _result} = run(ctx, %{run_profile: nil}, [], [orchestrated("look", %{"model" => "x"}), review()])
    end

    test "a turn that fails ends the pass with the error, and one that cannot start too", ctx do
      answers(%{"look" => [{:error, :port_exit}]})
      assert {:error, {:qa_agent_failed, :port_exit}, _tokens} = run(ctx, %{}, [], [orchestrated("look"), review()])
      assert [%{payload: %{outcome: "failed", returns_to: "end"}}] = events("step.completed")

      defmodule NoStart do
        def start_session(_worktree, _opts), do: {:error, :no_cli}
      end

      {result, _log} =
        with_log(fn ->
          Steps.run(NoStart, job(), ctx.worktree, QaAgent.qa_settings(Config.settings!()), [review()],
            qa_tmp_dir: ctx.tmp_dir,
            qa_step_runner: fn _command, _env, _timeout -> {:ok, {"", 0}} end
          )
        end)

      assert {:error, {:qa_agent_failed, :no_cli}, _tokens} = result
    end

    test "the token limit stops the pass, and a verdict given before it stands", ctx do
      usage = %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 900, "output_tokens" => 200, "total_tokens" => 1_100}}}
      answers(%{"look" => [{:messages, [usage], {:raw, "{}"}}]})

      limited = run(ctx, %{token_limit: 1_000}, [], [orchestrated("look"), review()])
      assert {:error, {:qa_token_limit, 1_100, 1_000}, %{total_tokens: 1_100}} = limited

      answers(%{"review" => [{:then_messages, {:verdict, @pass}, [usage]}]})
      given = run(ctx, %{token_limit: 1_000}, [], [review()])
      assert {:ok, %{result: %{verdict: :pass}, tokens: %{total_tokens: 1_100}}} = given

      answers(%{"review" => [{:messages, [usage], {:verdict, @pass}}]})
      forwarded = self()

      assert {:ok, %{result: %{verdict: :pass}}} =
               run(ctx, %{token_limit: 2_000}, [on_message: &send(forwarded, {:forwarded, &1})], [review()])

      assert_received {:forwarded, _message}
    end
  end

  describe "the walk" do
    test "stops at the verdict, and reads a brief's step number however it is written", ctx do
      plan = plan([1, 2], %{walk: [%{step: "1"}, %{step: 2}, %{step: "two"}, "not a brief"]})
      answers(%{"plan" => [{:write, plan}], "review" => [{:verdict, @pass}]})

      assert {:ok, %{result: %{verdict: :pass}}} = run(ctx, %{}, [], [plan_step(), review(), orchestrated("after")])
      assert Enum.map(turns(), & &1.id) == ["plan", "review"]
    end

    test "a turn that fails before its on_fail step ends the pass there", ctx do
      answers(%{"look" => [{:error, :port_exit}]})
      steps = [orchestrated("look", %{"on_fail" => "review"}), review()]
      assert {:error, {:qa_agent_failed, :port_exit}, _tokens} = run(ctx, %{}, [], steps)
      assert Enum.map(turns(), & &1.id) == ["look"]
    end

    test "a launch that failed into a step that drives the app skips it", ctx do
      tools = Application.get_env(:symphony_elixir, @tools)
      Application.put_env(:symphony_elixir, @tools, Map.put(tools, "qa_check_app", {:ok, %{"healthy" => false}}))
      answers(%{"review" => [{:verdict, @pass}]})

      steps = [machine("launch", "symphony:qa_launch", %{"on_fail" => "look"}), orchestrated("look"), machine("quit", "symphony:qa_quit"), review()]
      assert {:ok, _result} = run(ctx, %{host_ports: [5001]}, [], steps)
      assert Enum.map(turns(), & &1.id) == ["review"]
      assert [%{payload: %{reason: "the app did not launch"}}] = Enum.filter(events("step.completed"), &(&1.payload.step_id == "look"))
    end

    test "a walk with no plan walks its step's text, and a session's id comes from its messages", ctx do
      started = {:session_started, "session-from-stream"}
      answers(%{"walk" => [{:messages, [started], {:write, FakeAgent.pass_answer()}}], "review" => [{:verdict, @pass}]})
      walk = Enum.find(Phases.default_qa_steps("macos_app"), &(&1.id == "walk"))

      assert {:ok, _result} = run(ctx, %{journey: %{steps: walkthrough([1])}}, [], [walk, review()])
      [walk_turn, _review] = turns()
      assert walk_turn.prompt =~ "The plan gave no brief for this step"
    end

    test "a pass whose settings resolve no run profile runs without one", ctx do
      answers(%{"look" => [{:raw, "{}"}], "review" => [{:verdict, @pass}]})
      settings = QaAgent.qa_settings(Config.settings!())
      settings = %{settings | execution: %{settings.execution | run: nil}}

      {result, _log} =
        with_log(fn ->
          Steps.run(FakeAgent, job(%{run_profile: nil}), ctx.worktree, settings, [orchestrated("look", %{"model" => "x"}), review()],
            qa_tmp_dir: ctx.tmp_dir,
            qa_step_runner: fn _command, _env, _timeout -> {:ok, {"", 0}} end
          )
        end)

      assert {:ok, _result} = result
      assert [%{session: session_opts} | _rest] = turns()
      assert session_opts[:run_profile] == nil
    end

    test "cuts a long output and a long fact to size", ctx do
      tools = Application.get_env(:symphony_elixir, @tools)
      long = String.duplicate("x", 30_000)

      Application.put_env(
        :symphony_elixir,
        @tools,
        Map.merge(tools, %{"qa_build" => {:ok, %{"exit_status" => 1, "output" => long}}, "qa_gallery" => {:ok, %{"entries" => long}}})
      )

      answers(%{"plan" => [{:write, plan([1, 2])}], "review" => [{:verdict, @pass}]})
      assert {:ok, _result} = run(ctx, %{}, [], [machine("build", "symphony:qa_build", %{"on_fail" => "plan"}), plan_step(), review()])
      [plan_turn, review_turn] = turns()
      assert plan_turn.prompt =~ "\n…"
      assert review_turn.prompt =~ "failed: …x"
    end
  end

  describe "machine steps" do
    test "a failed machine step with no on_fail ends the pass blocked with its output", ctx do
      runner = fn
        "make check", _env, _timeout -> {:ok, {"3 failures", 1}}
        _command, _env, _timeout -> {:ok, {"", 0}}
      end

      ended = run(ctx, %{}, [qa_step_runner: runner], [machine("check", "make check"), review()])
      assert {:ok, %{result: %{verdict: :blocked, reason: reason}}} = ended
      assert reason =~ "the check step failed"
      assert reason =~ "3 failures"
    end

    test "a step with no result is run again, then ends the pass on the person's question", ctx do
      runner = fn
        "make slow", _env, _timeout -> {:timeout, "still going"}
        _command, _env, _timeout -> {:ok, {"", 0}}
      end

      assert {:ok, %{result: %{verdict: :blocked, reason: reason}}} =
               run(ctx, %{}, [qa_step_runner: runner], [machine("slow", "make slow", %{"timeout_ms" => 1_000}), review()])

      assert reason =~ "the slow step gave no result 2 times, so Symphony asked a person about it"
    end

    test "a skipped step, the pre-checks' results and the evidence the steps wrote", ctx do
      File.write!(Path.join([ctx.worktree, "qa-evidence", "page-1.png"]), "png")
      answers(%{"look" => [{:write, %{FakeAgent.pass_answer() | evidence: ["qa-evidence/page-1.png", "qa-evidence/gone.png", "https://x"]}}], "review" => [{:verdict, @pass}]})

      proved = %{number: 3, text: "Saved", proof: %{by: :test, check: "make-all", test: "saves"}}
      proofs = [%{step: proved, status: :pass, detail: "passed", url: nil}]

      steps = [
        machine("only_mac", "make mac", %{"when" => "macos_changed"}),
        machine("pre_checks", "symphony:qa_pre_checks"),
        orchestrated("look", %{"answer" => %{"status" => "string"}}),
        machine("attach", "symphony:qa_attach"),
        review()
      ]

      assert {:ok, _result} = run(ctx, %{proofs: proofs}, [], steps)
      review_turn = List.last(turns())
      assert review_turn.prompt =~ "- `only_mac` (only_mac): skipped"
      assert review_turn.prompt =~ "- `pre_checks` (pre_checks): passed"

      outputs = for %{payload: %{step_id: id}, artifacts: [artifact | _]} <- events("step.completed"), into: %{}, do: {id, artifact}
      assert Map.has_key?(outputs, "attach")
      assert Map.has_key?(outputs, "pre_checks")

      assert {:ok, _result} = run(ctx, %{}, [], [machine("pre_checks", "symphony:qa_pre_checks"), review()])
    end

    test "the pass's commands with no build to report a status, and a quit with nothing running", ctx do
      Application.put_env(:symphony_elixir, @tools, %{"qa_build" => {:ok, %{"prebuilt" => true}}})

      defmodule NothingLaunched do
        defdelegate call_tool(driver, tool, args), to: SymphonyElixir.QaAgent.StepsTest.FakeDriver
        def launched_pids(_driver), do: []
      end

      answers(%{"review" => [{:verdict, @pass}]})

      assert {:ok, _result} =
               run(ctx, %{}, [qa_driver_module: NothingLaunched], [machine("build", "symphony:qa_build"), machine("quit", "symphony:qa_quit"), review()])

      review_turn = List.last(turns())
      assert review_turn.prompt =~ "- `build` (build): passed"
    end
  end

  describe "StepPrompts" do
    test "has a prompt for each agent step of the default list" do
      for %Step{mode: "orchestrated", id: id} <- Phases.default_qa_steps("macos_app"), do: assert(is_binary(StepPrompts.prompt("macos_app", id)))
      assert StepPrompts.prompt("cli", "plan") == nil
      assert {"macos_app", "walk"} in StepPrompts.known()
    end

    test "gives the plan the playbook's screen rules, and a playbook without them whole" do
      playbook = File.read!("priv/qa_playbooks/macos_app.md")
      rules = StepPrompts.screen_rules(playbook)

      assert rules =~ "Servers the app talks to"
      assert rules =~ "Home's two lists (TP-1499)"
      assert rules =~ "After an update: the signed release pair."
      refute rules =~ "QA does three things"
      refute rules =~ "`qa_ax_tree`: the app's accessibility tree"

      assert StepPrompts.screen_rules("Servers the app talks to: a\nQA does three things") == "Servers the app talks to: a"
      assert StepPrompts.screen_rules("Just my playbook.") == "Just my playbook."
    end
  end

  defp machine(id, command, extra \\ %{}), do: step(Map.merge(%{"id" => id, "mode" => "machine", "command" => command}, extra))
  defp orchestrated(id, extra \\ %{}), do: step(Map.merge(%{"id" => id, "mode" => "orchestrated", "prompt" => "Do #{id}."}, extra))
  defp plan_step, do: Enum.find(Phases.default_qa_steps("macos_app"), &(&1.id == "plan"))
  defp review, do: step(%{"id" => "review", "mode" => "orchestrated", "prompt" => "Give the verdict."})

  defp step(%Step{} = step), do: step
  defp step(attrs), do: attrs |> then(&Step.changeset(%Step{}, &1)) |> Ecto.Changeset.apply_action!(:validate)
end
