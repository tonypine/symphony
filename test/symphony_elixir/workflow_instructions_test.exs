defmodule SymphonyElixir.WorkflowInstructionsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentSandboxConfig, Workflow, WorkflowPreview, WorkflowStore}

  @repo_root Path.expand("../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "workflow-instructions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "the symphony repo renders the same prompt with its instructions inline or in .symphony/instructions", %{dir: dir} do
    workflow = Path.join(@repo_root, "WORKFLOW.md")
    File.write!(Path.join(dir, "WORKFLOW.md"), playbook_only(File.read!(workflow)))
    File.cp_r!(Path.join(@repo_root, ".symphony"), Path.join(dir, ".symphony"))

    assert {:ok, inline} = WorkflowPreview.render(file: workflow)
    assert {:ok, assembled} = WorkflowPreview.render(file: Path.join(dir, "WORKFLOW.md"))
    assert assembled == inline
    assert assembled =~ "## Command and output hygiene"
    assert assembled =~ "## Step 4: Rework handling"
    assert Workflow.load(Path.join(dir, "WORKFLOW.md")) == Workflow.load(workflow)
  end

  test "a WORKFLOW.md with its instructions inline renders as before", %{dir: dir} do
    content = """
    ---
    prompts: {}
    ---

    You are working on `{{ issue.identifier }}`

    {% render "default_posture" %}

    ## Repo rules

    - Keep it inline.
    """

    path = write!(dir, "WORKFLOW.md", content)
    write!(dir, ".symphony/instructions/010-ignored.md", "Not part of an inline workflow.")

    assert Workflow.assemble(content, Workflow.instructions_on_disk(dir)) == {:ok, content}
    assert {:ok, %{prompt: prompt}} = Workflow.load(path)
    assert prompt == content |> String.split("---\n", parts: 3) |> List.last() |> String.trim()
    assert {:ok, preview} = WorkflowPreview.render(file: path)
    refute preview =~ "Not part of an inline workflow."
  end

  test "workflow preview shows the instruction files around the playbook partials", %{dir: dir} do
    path =
      write!(dir, "agents/WORKFLOW.md", """
      ---
      playbook:
        instructions: prompt
      ---
      {% render "playbook" %}
      """)

    write!(dir, "agents/prompt/045-repo-rules.md", "## Repo rules for `{{ issue.identifier }}`\n")

    assert {:ok, preview} = WorkflowPreview.render(file: path)
    assert preview =~ ~r/## Prerequisite: scoped Linear and GitHub tools.*## Repo rules for `ABC-123`.*## Status map/s
    refute preview =~ "Dependency-change guardrail"
  end

  test "a WORKFLOW.md without front matter can use the playbook line, and a missing directory has no files", %{dir: dir} do
    path = write!(dir, "WORKFLOW.md", "Intro\n{% render \"playbook\" %}\n")

    assert {:ok, %{prompt: prompt, config: %{}}} = Workflow.load(path)
    assert prompt =~ ~s(Intro\n{% render "continuation_context", attempt: attempt %})
  end

  test "an unreadable instructions directory or file fails the load", %{dir: dir} do
    path = write!(dir, "WORKFLOW.md", "---\nplaybook:\n  instructions: rules\n---\n{% render \"playbook\" %}\n")

    write!(dir, "rules", "a file, not a directory")
    assert Workflow.load(path) == {:error, {:workflow_instructions_error, "rules", :enotdir}}

    File.rm!(Path.join(dir, "rules"))
    write!(dir, "rules/010-rules.md", "Rules\n")
    # Listable but not searchable: the files cannot be looked up.
    File.chmod!(Path.join(dir, "rules"), 0o644)
    on_exit(fn -> File.chmod(Path.join(dir, "rules"), 0o755) end)

    assert Workflow.load(path) == {:error, {:workflow_instructions_error, "rules", {"010-rules.md", :eacces}}}
    assert Workflow.instructions_stamp(Path.join(dir, "rules")) == [{"010-rules.md", :eacces}]
  end

  test "only regular files are instruction files on disk, as on a git ref", %{dir: dir} do
    path = write!(dir, "WORKFLOW.md", "{% render \"playbook\" %}\n")
    secret = write!(dir, "host-secret.txt", "Host secret\n")
    write!(dir, ".symphony/instructions/010-rules.md", "## Repo rules\n")
    File.ln_s!(secret, Path.join(dir, ".symphony/instructions/020-link.md"))
    File.mkdir_p!(Path.join(dir, ".symphony/instructions/030-dir.md"))

    assert {:ok, %{prompt: prompt}} = Workflow.load(path)
    assert prompt =~ "## Repo rules"
    refute prompt =~ "Host secret"
    assert {:ok, preview} = WorkflowPreview.render(file: path)
    refute preview =~ "Host secret"
  end

  test "the workflow store reloads when only an instruction file changes", %{dir: dir} do
    path = write!(dir, "WORKFLOW.md", "Intro\n{% render \"playbook\" %}\n")
    rules = write!(dir, ".symphony/instructions/045-rules.md", "## First rules\n")
    store = start_supervised!({WorkflowStore, name: nil, path: path})

    assert {:ok, %{prompt: prompt}} = WorkflowStore.current(store)
    assert prompt =~ "## First rules"

    File.write!(rules, "## Second, longer rules\n")
    assert {:ok, %{prompt: prompt}} = WorkflowStore.current(store)
    assert prompt =~ "## Second, longer rules"

    write!(dir, ".symphony/instructions/046-more.md", "## More rules\n")
    assert {:ok, %{prompt: prompt}} = WorkflowStore.current(store)
    assert prompt =~ ~r/## Second, longer rules.*## More rules/s
  end

  test "an instructions stamp is nil without a playbook line or a valid instructions directory", %{dir: dir} do
    assert Workflow.instructions_path(Path.join(dir, "WORKFLOW.md"), "Inline prompt\n") == nil
    assert Workflow.instructions_path(Path.join(dir, "WORKFLOW.md"), "---\nplaybook:\n  instructions: 1\n---\n{% render \"playbook\" %}\n") == nil
    assert Workflow.instructions_path(Path.join(dir, "WORKFLOW.md"), "{% render \"playbook\" %}\n") == Path.join(dir, ".symphony/instructions")
    assert Workflow.instructions_stamp(nil) == nil
    assert Workflow.instructions_stamp(Path.join(dir, "missing")) == {:error, :enoent}
  end

  test "invalid front matter fails before any instruction file is read" do
    reader = fn _dir -> flunk("read instruction files for an invalid workflow") end

    assert {:error, {:invalid_repo_workflow_config, message}} =
             Workflow.parse_repo_workflow("---\nplaybook:\n  lockfile: 1\n---\n{% render \"playbook\" %}\n", reader)

    assert message =~ "playbook.lockfile"
    assert Workflow.parse_repo_workflow("---\n- list\n---\n{% render \"playbook\" %}\n", reader) == {:error, :workflow_front_matter_not_a_map}
  end

  test "an unterminated front matter has no body to expand" do
    assert Workflow.assemble("---\nprompts: {}\n{% render \"playbook\" %}", fn _dir -> {:ok, []} end) ==
             {:ok, "---\nprompts: {}\n{% render \"playbook\" %}"}
  end

  test "the protected paths still cover WORKFLOW.md, the skills and config files, but not the instruction files" do
    protected = AgentSandboxConfig.workspace_protected_paths()

    for path <- ~w(WORKFLOW.md .ai/skills .claude/skills .claude/hooks .claude/settings.json mise.toml config/settings_ui_exempt.yml) do
      assert path in protected
    end

    refute Enum.any?(protected, &String.starts_with?(&1, ".symphony"))
  end

  # The symphony repo's WORKFLOW.md with its body replaced by the playbook line.
  defp playbook_only(content) do
    ["", front_matter, _body] = String.split(content, ~r/^---$/m, parts: 3)

    front_matter =
      if front_matter =~ ~r/^playbook:/m,
        do: front_matter,
        else: "\nplaybook:\n  lockfile: mix.lock" <> front_matter

    "---" <> front_matter <> "---\n\n{% render \"playbook\" %}\n"
  end

  defp write!(dir, name, content) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end
end
