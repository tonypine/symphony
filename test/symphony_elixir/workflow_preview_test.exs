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
