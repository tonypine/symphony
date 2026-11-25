defmodule SymphonyElixir.QaAgent.PlanCheckTest do
  # Symphony's own check of a stepped QA pass's plan (`SymphonyElixir.QaAgent.PlanCheck`), and the
  # one status word a step the pass cannot do carries everywhere.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.QaAgent.{PlanCheck, Report, Steps, Verdict}
  alias SymphonyElixir.QaDriver
  alias SymphonyElixir.TicketEvents

  setup do
    worktree = Path.join(System.tmp_dir!(), "plan-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(worktree, "macos/Tests/Fixtures/director-app/running"))
    on_exit(fn -> File.rm_rf(worktree) end)
    %{facts: %{tools: ["qa_launch_app", "qa_click"], live: false, live_reason: "no QA check of the plan is set to the live server", worktree: worktree}}
  end

  defp target(number, setting \\ nil) do
    Map.merge(%{number: number, text: "Step #{number}.", proof: %{by: :qa}}, if(setting, do: %{setting: setting}, else: %{}))
  end

  @live %{source: "live", fixture: nil, page: "Home", window: %{width: 1440, height: 900}, appearance: "dark"}

  defp fixture(path), do: %{source: "fixture", fixture: path, page: "Inbox", window: %{width: 1440, height: 900}, appearance: "dark"}

  describe "settings/2" do
    test "marks a step set to the live server on a pass without one, from its setting alone, with what it needed", %{facts: facts} do
      targets = [target(1, @live), target(2, fixture("macos/Tests/Fixtures/director-app/running")), target(3)]

      assert {[%{number: 2}, %{number: 3}], [%{number: 1, needs: [needed]}]} = PlanCheck.settings(targets, facts)
      assert needed == "the live server, which this pass does not run (no QA check of the plan is set to the live server)"

      # A pass that runs the server keeps it.
      assert {[_, _, _], []} = PlanCheck.settings(targets, %{facts | live: true})
      assert {[], [%{needs: ["the live server, which this pass does not run"]}]} = PlanCheck.settings([target(1, @live)], %{facts | live_reason: nil})
    end

    test "marks a step whose fixture directory the worktree does not hold", %{facts: facts} do
      assert {[], [%{number: 4, needs: [needed]}]} = PlanCheck.settings([target(4, fixture("macos/Tests/Fixtures/gone/"))], facts)
      assert needed == "the fixture `macos/Tests/Fixtures/gone`, which this pass's worktree does not hold"
    end
  end

  describe "needs_shape/1" do
    test "takes no needs, or a list of needs in the fixed shapes, and refuses anything else" do
      assert PlanCheck.needs_shape(%{"step" => 1}) == :ok

      assert PlanCheck.needs_shape(%{
               "needs" => [
                 %{"kind" => "tool", "name" => "qa_drag"},
                 %{"kind" => "fixture_page", "fixture" => "f", "page" => "Inbox"},
                 %{"kind" => "fixture_page", "fixture" => "f"},
                 %{"kind" => "server"}
               ]
             }) == :ok

      for needs <- [
            "the drag tool",
            [%{"kind" => "tool"}],
            [%{"kind" => "tool", "name" => " "}],
            [%{"kind" => "fixture_page", "fixture" => "f", "page" => 3}],
            [%{"kind" => "magic"}],
            ["server"]
          ] do
        assert {:error, why} = PlanCheck.needs_shape(%{"needs" => needs})
        assert why =~ "each brief's `needs` must be a list of objects"
      end

      assert {:error, _why} = PlanCheck.needs_shape("a brief")
      assert PlanCheck.kinds() == ~w(tool fixture_page server)
    end
  end

  describe "briefs/3" do
    test "marks a step whose brief needs a tool, a fixture page or the server the pass lacks, and keeps the rest", %{facts: facts} do
      targets = Enum.map(1..5, &target/1)

      briefs = [
        %{"step" => 1, "needs" => [%{"kind" => "tool", "name" => "qa_drag"}]},
        %{"step" => "2", "needs" => [%{"kind" => "fixture_page", "fixture" => "macos/Tests/Fixtures/absent", "page" => "Queue"}, %{"kind" => "server"}]},
        %{"step" => 3, "needs" => [%{"kind" => "tool", "name" => "qa_click"}, %{"kind" => "fixture_page", "fixture" => "macos/Tests/Fixtures/director-app/running"}]},
        %{"step" => "four", "needs" => [%{"kind" => "server"}]},
        %{"step" => 5, "needs" => "not a list"},
        # A brief that names no step marks none.
        %{"needs" => [%{"kind" => "server"}]}
      ]

      assert {kept, [one, two]} = PlanCheck.briefs(targets, briefs, facts)
      assert Enum.map(kept, & &1.number) == [3, 4, 5]
      assert one == %{number: 1, target: target(1), needs: ["the QA tool `qa_drag`, which the QA driver does not have"]}

      assert two.needs == [
               "the fixture `macos/Tests/Fixtures/absent` (page Queue), which this pass's worktree does not hold",
               "the live server, which this pass does not run (no QA check of the plan is set to the live server)"
             ]

      # A fixture named by its directory's name, as the QA rules and docs name one, is found among
      # the state fixtures; a bare name that is not one of them is still absent.
      by_name = [
        %{"step" => 1, "needs" => [%{"kind" => "fixture_page", "fixture" => "running", "page" => "Home"}]},
        %{"step" => 2, "needs" => [%{"kind" => "fixture_page", "fixture" => "update-paused", "page" => "Home"}]}
      ]

      assert {[%{number: 1}], [%{number: 2, needs: [absent]}]} = PlanCheck.briefs([target(1), target(2)], by_name, facts)
      assert absent == "the fixture `update-paused` (page Home), which this pass's worktree does not hold"
      assert {[%{number: 1}], []} = PlanCheck.settings([target(1, fixture("running"))], facts)

      # The server is met on a pass that runs it.
      assert {[_], []} = PlanCheck.briefs([target(1)], [%{"step" => 1, "needs" => [%{"kind" => "server"}]}], %{facts | live: true})
    end
  end

  describe "verdict_step/1" do
    test "is unprovable, says what it needed, and carries its needs" do
      marked = %{number: 2, target: Map.put(target(2), :check_id, "c3"), needs: ["the live server", "the QA tool `qa_drag`"]}

      assert PlanCheck.verdict_step(marked) == %{
               name: "Walkthrough step 2 (check c3)",
               status: "unprovable",
               details: "Symphony marked it before any session: it needs the live server; and the QA tool `qa_drag`.",
               evidence: [],
               needs: ["the live server", "the QA tool `qa_drag`"]
             }

      assert PlanCheck.step_name(target(1)) == "Walkthrough step 1"
    end
  end

  describe "names_step?/2" do
    test "is true for Symphony's name and any name that opens with the walkthrough step's number" do
      target = Map.put(target(1), :check_id, "c3")

      for name <- ["Walkthrough step 1 (check c3)", " walkthrough STEP 1 (check c3) ", "Step 1", "step 1: open the board", "Walkthrough step 1: drag", "Step #1"],
          do: assert(PlanCheck.names_step?(name, target), name)

      for name <- ["Step 12", "Step 2", "Design check: Home", "The step 1 of the board", nil],
          do: refute(PlanCheck.names_step?(name, target), inspect(name))
    end
  end

  describe "the one status word" do
    @word "unprovable"

    test "is the status of a step the pass cannot do in the step rules, the step answers, the verdict, the report and the ticket's record" do
      assert PlanCheck.status() == @word

      # The QA plan rules and the walk, design check and review prompts.
      for name <- ~w(plan walk design_check review) do
        text = File.read!(Path.join(:code.priv_dir(:symphony_elixir), "qa_steps/macos_app/#{name}.md"))
        assert text =~ "`#{@word}`", "#{name}.md does not name `#{@word}`"
        refute text =~ ~r/marks it `blocked`/, "#{name}.md still marks a step the pass cannot do `blocked`"
      end

      assert @word in Steps.statuses()

      # The verdict reads it as it is, and offers it.
      assert {:ok, %{steps: [%{status: @word}]}} = Verdict.from_map(%{"verdict" => "pass", "steps" => [%{"name" => "Step 1", "status" => @word}]})
      assert @word in get_in(Verdict.tool_spec(), ["inputSchema", "properties", "steps", "items", "properties", "status", "enum"])

      # The report prints it as it is.
      report =
        Report.render(%{
          verdict: :pass,
          sha: String.duplicate("a", 40),
          target_state: "Merging",
          summary: "",
          steps: [%{name: "Walkthrough step 1", status: @word, details: "it needs the live server", evidence: []}],
          findings: []
        })

      assert report =~ "- **#{@word}** Walkthrough step 1"

      # The ticket's record takes it on a step's evidence and on a walk step's answer.
      :ok = RunStore.clear()

      assert {:ok, _event} =
               TicketEvents.record("default", "issue-word", "evidence", %{caption: "Walkthrough step 1: unprovable", step: "Walkthrough step 1", result: %{status: @word}},
                 actor: {:agent, "run-1", "qa"}
               )

      assert {:ok, _event} =
               TicketEvents.record(
                 "default",
                 "issue-word",
                 "step.completed",
                 %{step_id: "walk_1", title: "Walk 1", mode: "orchestrated", outcome: "passed", result: %{status: @word, expected: "the round trip", actual: "it needs the live server"}},
                 run_id: "run-1"
               )
    end
  end

  describe "the playbook's settings keys" do
    test "are as they were, less the server's two old descriptions (TP-1663): a configuration that loaded before loads the same" do
      playbooks = %{
        "macos_app" => %{
          "build" => "make app",
          "app" => "build/App.app",
          "appearance" => "dark",
          "window_width" => 2560,
          "window_height" => 1440,
          "dev_server_port" => 8090,
          "launch_env" => %{"HUB_OWNER_TOKEN" => "abc"}
        }
      }

      config = %{
        "issues" => %{"provider" => "memory"},
        "repositories" => [%{"key" => "web"}],
        "execution" => %{"harnesses" => %{"codex" => %{"command" => "codex app-server"}}},
        "runs" => %{"default" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-test"}},
        "auto_review" => %{"playbooks" => playbooks},
        "phases" => %{"qa" => %{"stepped" => true}}
      }

      assert {:ok, system} = SystemSchema.parse(config)
      assert system.auto_review.playbooks == playbooks
      assert system.phases.qa.stepped == true

      assert Enum.filter(SystemSchema.operator_key_paths(), &String.starts_with?(&1, "auto_review.playbooks.")) ==
               ~w(auto_review.playbooks.macos_app.appearance auto_review.playbooks.macos_app.dev_server_port
                  auto_review.playbooks.macos_app.launch_env auto_review.playbooks.macos_app.window_height auto_review.playbooks.macos_app.window_width)

      # The driver's tools the check reads are the driver's own list.
      assert "qa_launch_app" in QaDriver.tools()
    end
  end
end
