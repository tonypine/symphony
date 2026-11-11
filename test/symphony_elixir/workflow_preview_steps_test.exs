defmodule SymphonyElixir.WorkflowPreviewStepsTest do
  # `symphony workflow preview` for a run kind: the step list the run follows, above the prompt,
  # read from `symphony.yml`'s `phases.<kind>.steps` as Symphony loads it.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.TestSupport.Snapshot
  alias SymphonyElixir.WorkflowPreview

  setup do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path)
    %{workflow: path}
  end

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  defp preview_cli(args) do
    ExUnit.CaptureIO.capture_io(fn -> assert {:halt, 0} = CLI.evaluate(["workflow", "preview" | args], %{}) end)
  end

  defp preview!(workflow, kind) do
    assert {:ok, preview} = WorkflowPreview.render(file: workflow, run_kind: kind)
    preview
  end

  test "an implementation run lists the five default steps with their commands and what each returns to", %{workflow: workflow} do
    preview = preview!(workflow, "implementation")
    [steps, prompt] = String.split(preview, "\n---\n\n", parts: 2)

    assert steps =~ "An implementation run follows these steps (the default list, `phases.implementation.steps`):"
    assert steps =~ "1. `code` Write the code · delegated\n"

    assert steps =~
             "2. `build` Build · machine · times out after 15 min · on failure returns to `code`\n" <>
               "   - when macos/ changed: `cd macos && make guarded-build`\n" <>
               "   - when Elixir files changed: `mix compile --warnings-as-errors`\n"

    assert steps =~
             "3. `checks` Format, specs and credo · machine · when Elixir files changed · times out after 10 min · on failure returns to `code`\n" <>
               "   - `mix format --check-formatted && mix specs.check && mix credo --strict $SYMPHONY_CHANGED_ELIXIR_FILES`\n"

    assert steps =~ "4. `tests` Tests and coverage · machine · times out after 30 min · on failure returns to `code`\n"
    assert steps =~ "   - when Elixir files changed: `mix test $SYMPHONY_CHANGED_TEST_FILES && mix cover.changed`\n"
    assert steps =~ "   - when macos/ changed: `cd macos && swift test --filter \"$SYMPHONY_CHANGED_SWIFT_TEST_FILTER\"`\n"
    assert steps =~ "5. `handoff` Hand off: push and open the pull request · delegated\n"
    assert prompt =~ "Symphony runtime context:"
  end

  test "every run kind's preview names both ticket tools and what that kind records; only the step list's run is told to run no checks",
       %{workflow: workflow} do
    sections =
      Enum.map_join(Phases.kinds(), "\n", fn kind ->
        [_steps, prompt] = workflow |> preview!(kind) |> String.split("\n---\n\n", parts: 2)
        [_before, section] = String.split(prompt, "\n\nTicket tools:\n\n", parts: 2)
        [section | _rest] = String.split(section, "\n\n", parts: 2)
        assert section =~ "`ticket_events` reads this ticket's history", kind
        assert section =~ "`ticket_record` adds an event to it", kind
        "## #{kind}\n\n#{section}\n"
      end)

    Snapshot.assert_snapshot!(Path.join("workflow_preview", "ticket_tools.md"), sections)
    assert sections =~ "## implementation\n\n" <> "- `ticket_events`"
    assert [_implementation, _rework] = Regex.scan(~r/This run follows a step list: Symphony runs its build, checks and tests itself/, sections)
  end

  test "removing a step from symphony.yml changes the next preview", %{workflow: workflow} do
    assert preview!(workflow, "implementation") =~ "`checks`"

    append_symphony_yml!("""
    phases:
      implementation:
        steps:
          - {id: code, title: Write the code, mode: delegated}
          - {id: build, mode: machine, command: mix compile, on_fail: code, timeout_ms: 1500}
          - id: review
            mode: orchestrated
            prompt: |
              Review the diff.
              Say what is missing.
          - {id: handoff, mode: delegated}
    """)

    preview = preview!(workflow, "implementation")

    refute preview =~ "`checks`"
    assert preview =~ "follows these steps (symphony.yml, `phases.implementation.steps`)"
    assert preview =~ "2. `build` build · machine · times out after 1500 ms · on failure returns to `code`\n   - `mix compile`\n"
    assert preview =~ "3. `review` review · orchestrated · on failure ends the run\n   - prompt:\n     > Review the diff.\n     > Say what is missing.\n"
    assert preview =~ "4. `handoff` handoff · delegated\n"
  end

  test "an invalid list is refused, naming the step", %{workflow: workflow} do
    append_symphony_yml!("""
    phases:
      implementation:
        steps:
          - {id: code, mode: delegated}
          - {id: build, mode: machine, command: mix compile, on_fail: cod}
    """)

    assert {:error, message} = WorkflowPreview.render(file: workflow, run_kind: "implementation")
    assert message =~ "Invalid symphony.yml config: phases.implementation.steps has no step `cod`, which step `build` returns to on failure"
  end

  test "a kind with no step list says its run is one agent session", %{workflow: workflow} do
    assert preview!(workflow, "qa") =~ "## Steps\n\nA qa run follows no step list (the default list): it is one agent session.\n"
  end

  test "an unknown run kind is refused with the kinds there are", %{workflow: workflow} do
    assert {:error, message} = WorkflowPreview.render(file: workflow, run_kind: "deploy")
    assert message =~ "Unknown run kind `deploy`; one of: implementation, breakdown, rework"
  end

  test "with no symphony.yml the preview shows the default list", %{workflow: workflow} do
    previous = Application.get_env(:symphony_elixir, :symphony_file_path)
    Workflow.set_symphony_file_path(Path.join(System.tmp_dir!(), "no_such_#{System.unique_integer([:positive])}/symphony.yml"))
    on_exit(fn -> Workflow.set_symphony_file_path(previous) end)
    Cache.clear()

    assert {:ok, steps} = WorkflowPreview.render_steps("implementation")
    assert steps =~ "(the default list, `phases.implementation.steps`)"
    assert steps =~ "5. `handoff`"
    assert {:ok, ""} = WorkflowPreview.render_steps(nil)
    assert {:error, _message} = WorkflowPreview.render(file: workflow, run_kind: "deploy")
  end

  # The Director's Settings › Phases writes these files (PhaseSettingsTests checks that it writes
  # `reordered.yml` and draws each preview); Symphony must load them and preview the same lists.
  @phase_fixtures "macos/Tests/SymphonyBarCoreTests/Fixtures/phases"

  test "the default list previews as the Director's Phases preview draws it", %{workflow: workflow} do
    [steps, _prompt] = String.split(preview!(workflow, "implementation"), "\n---\n\n", parts: 2)
    assert steps == File.read!(Path.join(@phase_fixtures, "default.preview.txt"))
  end

  test "a list the Director saved, tests moved above checks, previews in the new order as the Director draws it", %{workflow: workflow} do
    append_symphony_yml!(File.read!(Path.join(@phase_fixtures, "reordered.yml")))

    [steps, _prompt] = String.split(preview!(workflow, "implementation"), "\n---\n\n", parts: 2)
    assert steps == File.read!(Path.join(@phase_fixtures, "reordered.preview.txt"))
    assert steps =~ ~r/3\. `tests`.*\n(.*\n)*4\. `checks`/
  end

  test "the CLI previews an implementation run unless --kind names another", %{workflow: workflow} do
    output = preview_cli(["--file", workflow])
    assert output =~ "An implementation run follows these steps"

    output = preview_cli(["--file", workflow, "--kind", "ci_fix"])
    assert output =~ "A ci_fix run follows no step list"

    output = preview_cli(["--file", workflow, "--kind", "rework"])
    assert output =~ "A rework run follows these steps (the default list, `phases.rework.steps`):"
    assert output =~ "1. `findings` Read the open findings · machine · times out after 1 min · on failure returns to `code`\n   - `symphony:findings`\n"
    assert output =~ "2. `code` Write the code · delegated\n"

    assert {:error, message} = CLI.evaluate(["workflow", "preview", "--file", workflow, "--kind", "deploy"], %{})
    assert message =~ "Unknown run kind `deploy`"
  end
end
