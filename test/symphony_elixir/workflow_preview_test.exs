defmodule SymphonyElixir.WorkflowPreviewTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkflowPreview

  defp write!(contents) do
    path = Path.join(System.tmp_dir!(), "workflow_preview_#{System.unique_integer([:positive])}.md")
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "renders the base-issue prompt with managed context, expanded partials, and sample data" do
    path =
      write!("""
      ---
      prompts: {}
      ---
      You are working on `{{ issue.identifier }}`

      {% render "default_posture" %}
      """)

    assert {:ok, prompt} = WorkflowPreview.render(file: path, agent_kind: "codex")
    assert prompt =~ "Symphony runtime context:"
    assert prompt =~ "You are working on `ABC-123`"
    refute prompt =~ "{% render"
  end

  test "uses the repo key it is given" do
    path =
      write!("""
      ---
      prompts: {}
      ---
      repo={{ repo_key }}
      """)

    assert {:ok, prompt} = WorkflowPreview.render(file: path, repo_key: "api")
    assert prompt =~ "repo=api"
  end

  test "returns a friendly error for an unknown render partial" do
    path =
      write!("""
      ---
      prompts: {}
      ---
      {% render "not_a_real_partial" %}
      """)

    assert {:error, message} = WorkflowPreview.render(file: path)
    assert message =~ "not_a_real_partial"
  end

  test "returns a friendly error when the file is missing" do
    assert {:error, message} = WorkflowPreview.render(file: "/no/such/WORKFLOW.md")
    assert message =~ "/no/such/WORKFLOW.md"
    # `:file.format_error(:enoent)` renders the POSIX reason in plain English.
    assert message =~ "no such file or directory"
    # The message must be human-readable, not a raw error tuple dump.
    refute message =~ "missing_workflow_file"
  end

  test "returns a friendly error when the front matter is malformed YAML" do
    path = write!("---\nkey: [unclosed\n---\nbody\n")

    assert {:error, message} = WorkflowPreview.render(file: path)
    assert message =~ "Could not parse front matter"
    assert message =~ path
  end

  test "returns a friendly error when the front matter is not a map" do
    path = write!("---\njust a scalar string\n---\nbody\n")

    assert {:error, message} = WorkflowPreview.render(file: path)
    assert message =~ "Could not load workflow file"
    assert message =~ path
  end
end

defmodule SymphonyElixir.WorkflowPreviewLedgerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TicketEvents.Brief
  alias SymphonyElixir.WorkflowPreview

  setup do
    :ok = RunStore.clear()
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "You are working on `{{ issue.identifier }}`")
    %{workflow: Workflow.workflow_file_path()}
  end

  test "carries the sample ticket's history summary, with every decision, open finding and note in full", %{workflow: file} do
    assert {:ok, prompt} = WorkflowPreview.render(file: file)
    brief = Brief.build(WorkflowPreview.sample_ticket_state(), WorkflowPreview.sample_ticket_events())

    assert %{runs: 3, open_findings: 12, decisions: 2, notes: 3} = brief
    assert prompt =~ "Ticket state:\n\n- Phase: Rework"
    refute prompt =~ "Recent signals:"
    assert prompt =~ "<ticket_ledger>\n" <> String.replace(brief.text, "&", "&amp;") <> "\n</ticket_ledger>"
    assert prompt =~ "Open findings (12):\n- clipped (5):"
    assert prompt =~ "- truncated (4):"
    assert prompt =~ "- state missing (3):"
    assert prompt =~ "the Director (Sam): The export button stays where it is: users know it there."
    assert prompt =~ "- Rework run 1 (latest): running in Rework"
    assert RunStore.list_ticket_events("your-repo", "issue_sample_0001", []) == []
  end

  test "turned off, the prompt is the one rendered without a ticket state", %{workflow: file} do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> "ledger:\n  prompt_brief_enabled: false\n")
    Cache.clear()

    assert {:ok, prompt} = WorkflowPreview.render(file: file)
    {:ok, workflow} = Workflow.load(file)

    opts = [workflow: workflow, prompt_mode: :issue, agent_kind: "codex", repo_key: nil]

    assert prompt == PromptBuilder.build_prompt(WorkflowPreview.sample_issue(), opts)
    refute prompt =~ "Ticket history"
    refute prompt =~ "Ticket state:"
  end
end
