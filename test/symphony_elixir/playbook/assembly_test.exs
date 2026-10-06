defmodule SymphonyElixir.Playbook.AssemblyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Playbook
  alias SymphonyElixir.Playbook.Assembly

  defp files(files), do: fn _dir -> {:ok, files} end

  defp expand!(body, settings, read_instructions, aggregate \\ Playbook.aggregate()) do
    assert {:ok, lines} = Assembly.expand(String.split(body, "\n"), settings, read_instructions, aggregate)
    Enum.join(lines, "\n")
  end

  test "a body without the playbook line is left as it is, without reading instruction files" do
    body = "Intro\n\n{% render \"status_map\" %}"
    reader = fn _dir -> flunk("read instruction files without a playbook line") end

    assert expand!(body, %{}, reader) == body
  end

  test "the playbook line becomes the canonical partials with the instruction files between them by number" do
    files = [
      {"121-priority.md", "## Priority\n\nBody.\n"},
      {"005-intro.md", "\nYou are working on `{{ issue.identifier }}`\n"},
      {"041-hygiene.md", "## Hygiene"},
      {"010-after-continuation.md", "Same slot as a partial: after it."},
      {"README.md", "Not an instruction file."},
      {"notes.txt", "Neither."}
    ]

    expanded = expand!("Before\n  {% render \"playbook\" %}  \nAfter", %{"lockfile" => "mix.lock"}, files(files))

    assert expanded ==
             Enum.join(
               [
                 "Before\nYou are working on `{{ issue.identifier }}`",
                 ~s({% render "continuation_context", attempt: attempt %}),
                 "Same slot as a partial: after it.",
                 ~s({% render "issue_context", issue: issue %}),
                 ~s({% render "default_posture" %}),
                 ~s({% render "scoped_tools" %}),
                 "## Hygiene",
                 ~s({% render "status_map" %}),
                 ~s({% render "pr_feedback_sweep" %}),
                 ~s({% render "ci_triage" %}),
                 ~s({% render "escape_hatches" %}),
                 ~s({% render "parent_tickets" %}),
                 ~s({% render "review_brief" %}),
                 ~s({% render "completion_bar" %}),
                 ~s({% render "guardrails" %}),
                 ~s({% render "out_of_scope_backlog" %}),
                 "## Priority\n\nBody.",
                 ~s({% render "dependency_guardrail", lockfile: "mix.lock" %}),
                 ~s({% render "workpad_template", agent: agent %}\nAfter)
               ],
               "\n\n"
             )
  end

  test "front matter settings move, add and drop partials and leave out dependency_guardrail without a lock file" do
    settings = %{
      "instructions" => "prompt",
      "partials" => %{"status_map" => 45, "workpad_bootstrap" => 47, "ci_triage" => false}
    }

    reader = fn "prompt" -> {:ok, [{"046-after-status-map.md", "Routing."}]} end
    expanded = expand!(~s({% render "playbook" %}), settings, reader)

    assert expanded =~ ~s({% render "scoped_tools" %}\n\n{% render "status_map" %}\n\nRouting.\n\n{% render "workpad_bootstrap", agent: agent %})
    refute expanded =~ "ci_triage"
    refute expanded =~ "dependency_guardrail"
  end

  test "a failed read and a playbook line inside an instruction file are errors" do
    assert Assembly.expand([Assembly.directive()], %{}, fn _dir -> {:error, :eacces} end) ==
             {:error, {:workflow_instructions_error, ".symphony/instructions", :eacces}}

    nested = files([{"001-loop.md", "Text\r\n{% render \"playbook\" %}\n"}])

    assert Assembly.expand([Assembly.directive()], %{}, nested) ==
             {:error, {:workflow_instructions_error, ".symphony/instructions", {:playbook_line_in_instruction_file, "001-loop.md"}}}
  end

  test "a partial added to the aggregate reaches the rendered prompt with no WORKFLOW.md change" do
    workflow_body = ~s(Intro\n\n{% render "playbook" %})
    # Drop every shipped partial but completion_bar and review_brief, to keep the prompt short.
    without_brief = List.keydelete(Playbook.aggregate(), "review_brief", 0)
    settings = %{"partials" => Map.new(without_brief, fn {name, _slot} -> {name, false} end)}
    settings = put_in(settings, ["partials", "completion_bar"], 100)
    instructions = files([{"101-repo-bar.md", "- Repo bar item."}])

    render = fn aggregate ->
      template = expand!(workflow_body, settings, instructions, aggregate)
      {:ok, result, []} = Solid.render(Solid.parse!(template), %{}, file_system: {Playbook.FileSystem, nil}, strict_variables: true)
      IO.iodata_to_binary(result)
    end

    before = render.(without_brief)
    refute before =~ "## Review brief"

    prompt = render.(Playbook.aggregate())
    assert prompt =~ "## Review brief\n\nThe workpad is the agent's log"
    assert prompt =~ ~r/## Review brief.*## Completion bar.*- Repo bar item\./s
  end

  test "instructions_dir, instruction_file? and directive?" do
    assert Assembly.instructions_dir(%{}) == ".symphony/instructions"
    assert Assembly.instructions_dir(%{"instructions" => "docs/agent"}) == "docs/agent"
    assert Assembly.instruction_file?("010-a-b.md")
    refute Assembly.instruction_file?("a-010.md")
    refute Assembly.instruction_file?("010-a.txt")
    assert Assembly.directive?("  {% render \"playbook\" %}\t")
    refute Assembly.directive?(~s({% render "playbook", issue: issue %}))
  end

  describe "validate_settings/1" do
    test "accepts no settings and valid settings" do
      assert Assembly.validate_settings(nil) == :ok

      assert Assembly.validate_settings(%{
               "instructions" => "docs/agent",
               "lockfile" => "pnpm-lock.yaml",
               "partials" => %{"ci_triage" => false, "workpad_bootstrap" => 0}
             }) == :ok
    end

    test "names the first problem" do
      for {settings, message} <- [
            {"x", "playbook must be a map"},
            {%{"order" => []}, "not `order`"},
            {%{"instructions" => 1}, "playbook.instructions must be a string"},
            {%{"instructions" => " "}, "inside the repo"},
            {%{"instructions" => "/etc"}, "inside the repo"},
            {%{"instructions" => "../other"}, "inside the repo"},
            {%{"lockfile" => 1}, "playbook.lockfile must be a string"},
            {%{"lockfile" => ~s(a"b)}, "without quotes or braces"},
            {%{"lockfile" => ""}, "without quotes or braces"},
            {%{"partials" => []}, "playbook.partials must be a map"},
            {%{"partials" => %{"nope" => 1}}, "unknown partial `nope`"},
            {%{"partials" => %{"ci_triage" => -1}}, "playbook.partials.ci_triage must be a slot number or false"},
            {%{"partials" => %{"ci_triage" => true}}, "playbook.partials.ci_triage must be a slot number or false"}
          ] do
        assert {:error, error} = Assembly.validate_settings(settings)
        assert error =~ message
      end
    end
  end
end
