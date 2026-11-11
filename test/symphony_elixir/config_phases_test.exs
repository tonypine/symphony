defmodule SymphonyElixir.ConfigPhasesTest do
  # `symphony.yml`'s `phases.<kind>.steps` (`Config.Schema.Phases`): the step list a run follows.
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.Config.Schema.Phases.{Phase, Step}
  alias SymphonyElixir.Config.Schema.Phases.Step.Command
  alias SymphonyElixir.Config.SystemSchema

  defp symphony(sections) do
    Map.merge(
      %{
        "issues" => %{"provider" => "memory"},
        "agent" => %{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"},
        "repositories" => [%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}]
      },
      sections
    )
  end

  defp parse(phases), do: SystemSchema.parse(symphony(%{"phases" => phases}))

  defp steps!(steps, kind \\ "implementation") do
    assert {:ok, system} = parse(%{kind => %{"steps" => steps}})
    Phases.steps(system.phases, String.to_existing_atom(kind))
  end

  defp refused(phases) do
    assert {:error, {:invalid_symphony_config, message}} = parse(phases)
    message
  end

  defp refused_steps(steps), do: refused(%{"implementation" => %{"steps" => steps}})

  defp code, do: %{"id" => "code", "mode" => "delegated"}
  defp machine(id, fields \\ %{}), do: Map.merge(%{"id" => id, "mode" => "machine", "command" => "make #{id}"}, fields)

  describe "the default list" do
    test "a symphony.yml with no phases key follows decision 2's five implementation steps" do
      assert {:ok, system} = SystemSchema.parse(symphony(%{}))
      steps = Phases.steps(system.phases, :implementation)

      assert Enum.map(steps, &{&1.id, &1.mode, &1.on_fail}) == [
               {"code", "delegated", nil},
               {"build", "machine", "code"},
               {"checks", "machine", "code"},
               {"tests", "machine", "code"},
               {"handoff", "delegated", nil}
             ]

      [_code, build, checks, tests, _handoff] = steps

      assert [%Command{run: "cd macos && make guarded-build", when: "macos_changed"}, %Command{run: "mix compile --warnings-as-errors", when: "elixir_changed"}] =
               build.command

      assert [%Command{run: "mix format --check-formatted && mix specs.check && mix credo --strict" <> _, when: "always"}] = checks.command
      assert checks.when == "elixir_changed"
      assert [%Command{run: "mix test " <> elixir_tests}, %Command{run: "cd macos && swift test --filter" <> _, when: "macos_changed"}] = tests.command
      assert elixir_tests =~ "mix cover.changed"
      assert Enum.all?(steps, &(&1.no_result_limit == 2))
    end

    test "rework reads the open findings first, then follows the implementation list" do
      assert [findings | rest] = Phases.default_steps(:rework)
      assert %Step{id: "findings", mode: "machine", on_fail: "code", timeout_ms: 60_000} = findings

      assert [%Command{run: "symphony:findings", when: "always"}] = findings.command
      assert Phases.findings_command() == "symphony:findings"
      assert Enum.map(rest, & &1.id) == ["code", "build", "checks", "tests", "handoff"]
      assert rest == Phases.default_steps(:implementation)
    end

    test "every other kind has none, and a kind the file doesn't set keeps its default" do
      assert {:ok, system} = parse(%{"rework" => %{"steps" => [code()]}})

      assert [%Step{id: "code"}] = Phases.steps(system.phases, :rework)
      assert length(Phases.steps(system.phases, :implementation)) == 5
      assert Phases.steps(system.phases, :qa) == []
      assert Phases.default_steps(:code_review) == []
    end

    test "names the kinds phases takes, without the retired close_out" do
      assert "implementation" in Phases.kinds()
      refute "close_out" in Phases.kinds()
      assert Phases.kind("rework") == :rework
      assert Phases.kind(:qa) == :qa
      assert Phases.kind("close_out") == nil
      assert Phases.kind(42) == nil
    end
  end

  describe "a list the file sets" do
    test "replaces the default: removing a step removes it from the list" do
      steps = steps!([code(), machine("build", %{"on_fail" => "code"}), %{"id" => "handoff", "mode" => "delegated", "title" => "Hand off"}])

      assert Enum.map(steps, & &1.id) == ["code", "build", "handoff"]

      assert [%Step{title: "code"}, %Step{title: "build", timeout_ms: 600_000, when: "always"}, %Step{title: "Hand off", timeout_ms: nil}] =
               steps

      assert [%Command{run: "make build", when: "always"}] = Enum.at(steps, 1).command
    end

    test "an empty list means no steps: the run is one agent session" do
      assert steps!([]) == []
    end

    test "an orchestrated step carries its prompt, a step its own timeout and no-result limit" do
      steps =
        steps!([
          code(),
          %{"id" => "review", "mode" => "orchestrated", "prompt" => "Review the diff.", "timeout_ms" => 1_000, "no_result_limit" => 3, "on_fail" => "code"}
        ])

      assert [_, %Step{prompt: "Review the diff.", timeout_ms: 1_000, no_result_limit: 3, on_fail: "code", command: []}] = steps
    end

    test "an orchestrated step carries the answer its agent gives, each field with its type" do
      steps =
        steps!([
          code(),
          %{"id" => "layout", "mode" => "orchestrated", "prompt" => "Pick a layout.", "answer" => %{"layout" => "string", "columns" => "number"}}
        ])

      assert [%Step{answer: %{}}, %Step{answer: %{"layout" => "string", "columns" => "number"}}] = steps
    end

    test "a machine step may loop through a delegated step" do
      assert [_, _, _] = steps!([code(), machine("build", %{"on_fail" => "code"}), machine("tests", %{"on_fail" => "code"})])
    end

    test "a forward on_fail is no loop" do
      assert [_, _, _] = steps!([machine("build", %{"on_fail" => "report"}), code(), %{"id" => "report", "mode" => "delegated"}])
    end
  end

  describe "an invalid list is refused at load, naming the step" do
    test "an on_fail naming a step not in the list" do
      message = refused_steps([code(), machine("build", %{"on_fail" => "cod"})])
      assert message =~ "phases.implementation.steps has no step `cod`, which step `build` returns to on failure"
    end

    test "a loop with no delegated step" do
      message = refused_steps([code(), machine("build"), machine("tests", %{"on_fail" => "build"})])
      assert message =~ "phases.implementation.steps loop `build` → `tests` → `build` has no delegated step"

      assert refused_steps([machine("build", %{"on_fail" => "build"})]) =~ "loop `build` → `build` has no delegated step"
    end

    test "a machine step with no command" do
      assert refused_steps([code(), %{"id" => "build", "mode" => "machine"}]) =~
               "phases.implementation.steps.command is required for machine step `build`"

      assert refused_steps([%{"id" => "build", "mode" => "machine", "command" => []}]) =~ "is required for machine step `build`"
    end

    test "an orchestrated step with no prompt" do
      assert refused_steps([%{"id" => "review", "mode" => "orchestrated", "prompt" => " "}]) =~
               "phases.implementation.steps.prompt is required for orchestrated step `review`"
    end

    test "a command, prompt or when on a step of another mode" do
      assert refused_steps([%{"id" => "code", "mode" => "delegated", "command" => "make"}]) =~
               "steps.command is only for a machine step; step `code` is delegated"

      assert refused_steps([machine("build", %{"prompt" => "Build it."})]) =~
               "steps.prompt is only for an orchestrated step; step `build` is machine"

      assert refused_steps([%{"id" => "code", "mode" => "delegated", "when" => "always"}]) =~
               "steps.when is only for a machine step; step `code` is delegated"

      assert refused_steps([%{"id" => "code", "mode" => "delegated", "answer" => %{"layout" => "string"}}]) =~
               "steps.answer is only for an orchestrated step; step `code` is delegated"
    end

    test "an answer field with a bad name or type" do
      step = &%{"id" => "layout", "mode" => "orchestrated", "prompt" => "Pick.", "answer" => &1}

      assert refused_steps([step.(%{"layout" => "text"})]) =~
               "steps.answer field `layout` of step `layout` must be a lowercase name with a type: string, number, boolean, list, object"

      assert refused_steps([step.(%{"Layout" => "string"})]) =~ "field `Layout` of step `layout`"
    end

    test "a missing or unknown mode, a missing or malformed id, and duplicate ids" do
      assert refused_steps([%{"id" => "build"}]) =~ "steps.mode is required for step `build`"
      assert refused_steps([%{"id" => "build", "mode" => "manual"}]) =~ "steps.mode of step `build` must be one of: machine, orchestrated, delegated"
      assert refused_steps([%{"mode" => "delegated"}]) =~ "steps.id is required for every step"
      assert refused_steps([%{"id" => "Build it", "mode" => "delegated"}]) =~ "steps.id `Build it` must be lowercase letters"
      assert refused_steps([code(), code()]) =~ "phases.implementation.steps has two steps with the id `code`"
    end

    test "a bad when, timeout or no-result limit" do
      assert refused_steps([machine("build", %{"when" => "sometimes"})]) =~
               "steps.when of step `build` must be one of: always, macos_changed, elixir_changed"

      assert refused_steps([machine("build", %{"timeout_ms" => 0})]) =~ "steps.timeout_ms of step `build` must be greater than 0"
      assert refused_steps([machine("build", %{"no_result_limit" => 0})]) =~ "steps.no_result_limit of step `build` must be greater than 0"
    end

    test "a command entry with no command or a bad when" do
      assert refused_steps([machine("build", %{"command" => [%{"when" => "macos_changed"}]})]) =~
               "steps.command.run of step `build` has an entry with no command"

      assert refused_steps([machine("build", %{"command" => [%{"run" => "make", "when" => "never"}]})]) =~
               "steps.command.when of step `build` must be one of: always, macos_changed, elixir_changed"
    end

    test "an unknown key on a step or a command entry" do
      assert refused_steps([machine("build", %{"retries" => 3})]) =~ "step `build` has an unknown key `retries`"
      assert refused_steps([machine("build", %{"command" => [%{"run" => "make", "if" => "x"}]})]) =~ "step `build` has an unknown key `if`"
      assert refused_steps([%{"mode" => "delegated", "x" => 1, "id" => ""}]) =~ "step `(no id)` has an unknown key `x`"
    end

    test "an unknown kind, an unknown key under a kind, and a kind without a list of steps" do
      assert refused(%{"deploy" => %{"steps" => []}}) =~ "unknown symphony.yml key `phases.deploy`"
      assert refused(%{"implementation" => %{"steps" => [], "parallel" => true}}) =~ "unknown symphony.yml key `phases.implementation.parallel`"
      assert refused(%{"implementation" => nil}) =~ "`phases.implementation.steps` is required; remove `phases.implementation` to follow the default list"
      assert refused(%{"implementation" => %{"steps" => "code"}}) =~ "`phases.implementation.steps` must be a list of steps, each an object"
      assert refused(%{"implementation" => %{"steps" => ["code"]}}) =~ "`phases.implementation.steps` must be a list of steps, each an object"
      assert refused(%{"implementation" => "code"}) =~ "`phases.implementation` must be an object"
      assert refused(["implementation"]) =~ "`phases` must be an object"
    end
  end

  test "each kind's steps are one setting of symphony.yml" do
    paths = SystemSchema.operator_key_paths()

    assert "phases.implementation.steps" in paths
    assert "phases.rework.steps" in paths
    refute "phases.close_out.steps" in paths
  end

  test "the step model's modes and conditions" do
    assert Step.modes() == ~w(machine orchestrated delegated)
    assert Step.conditions() == ~w(always macos_changed elixir_changed)
    assert Step.answer_types() == ~w(string number boolean list object)
    assert %Phase{steps: []} = %Phase{}
  end
end
