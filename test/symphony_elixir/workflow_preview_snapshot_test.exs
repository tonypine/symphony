defmodule SymphonyElixir.WorkflowPreviewSnapshotTest do
  # Pins `symphony workflow preview` of this repository's own `WORKFLOW.md`: the prompt must read as
  # one contract. A deliberate prompt change updates the fixture with
  # `UPDATE_SNAPSHOTS=1 mix test test/symphony_elixir/workflow_preview_snapshot_test.exs`.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TestSupport.Snapshot
  alias SymphonyElixir.WorkflowPreview

  @repo_workflow Path.expand("../../WORKFLOW.md", __DIR__)

  # The words of the retired legacy machine: none of them may reach a prompt.
  @retired ["Auto Review", "In Review", "Human Review", "Supervisor check", "supervisor check", "Final verification"]

  setup do
    path = Workflow.workflow_file_path()

    write_workflow_file!(path,
      repos: [%{"name" => "app", "path" => Path.dirname(path), "workflow" => Path.basename(path), "team" => "Test"}]
    )

    :ok
  end

  test "the preview matches its snapshot" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @repo_workflow, agent_kind: "claude", repo_key: "app")
    Snapshot.assert_snapshot!(Path.join("workflow_preview", "prompt.md"), prompt)
  end

  test "the preview names none of the retired states, checks or tickets" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @repo_workflow, agent_kind: "claude", repo_key: "app")

    for word <- @retired, do: refute(prompt =~ word, "the prompt still says #{inspect(word)}")

    for part <- ["`Code Review`", "`QA`", "`CI Fix`", "`Plan Review`", "`Epic Review`", "`Needs Decision`", "`Blocked`", "That push is the handoff signal"] do
      assert prompt =~ part
    end
  end
end
