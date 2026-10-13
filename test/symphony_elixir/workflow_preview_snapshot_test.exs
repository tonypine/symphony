defmodule SymphonyElixir.WorkflowPreviewSnapshotTest do
  # Pins `symphony workflow preview` of this repository's own `WORKFLOW.md` for a repo on each
  # state-machine version: the legacy prompt must not move while the designed one is written, and
  # the designed one must read as one contract. A deliberate prompt change updates the fixtures with
  # `UPDATE_SNAPSHOTS=1 mix test test/symphony_elixir/workflow_preview_snapshot_test.exs`.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TestSupport.Snapshot
  alias SymphonyElixir.WorkflowPreview

  @repo_workflow Path.expand("../../WORKFLOW.md", __DIR__)

  # The words of the machine the designed one retires: none of them may reach a designed prompt.
  @retired ["Auto Review", "In Review", "Human Review", "Supervisor check", "supervisor check", "Final verification"]

  setup do
    path = Workflow.workflow_file_path()

    write_workflow_file!(path,
      repos: [
        %{"name" => "legacy", "path" => Path.dirname(path), "workflow" => Path.basename(path), "team" => "Test", "labels" => ["legacy"]},
        %{"name" => "designed", "path" => Path.dirname(path), "workflow" => Path.basename(path), "team" => "Test", "labels" => ["designed"], "state_machine" => "designed"}
      ]
    )

    :ok
  end

  for version <- ["legacy", "designed"] do
    test "the #{version} preview matches its snapshot" do
      assert {:ok, prompt} = WorkflowPreview.render(file: @repo_workflow, agent_kind: "claude", repo_key: unquote(version))
      Snapshot.assert_snapshot!(Path.join("workflow_preview", unquote(version) <> ".prompt.md"), prompt)
    end
  end

  test "the designed preview names none of the retired states, checks or tickets" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @repo_workflow, agent_kind: "claude", repo_key: "designed")

    for word <- @retired, do: refute(prompt =~ word, "the designed prompt still says #{inspect(word)}")

    for part <- ["`Code Review`", "`QA`", "`CI Fix`", "`Plan Review`", "`Epic Review`", "`Needs Decision`", "`Blocked`", "That push is the handoff signal"] do
      assert prompt =~ part
    end
  end

  test "the legacy preview keeps today's states, without the retired Auto Review and acceptance gate" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @repo_workflow, agent_kind: "claude", repo_key: "legacy")

    for word <- ["In Review", "Human Review", "Final verification:"], do: assert(prompt =~ word)
    refute prompt =~ "`Code Review`"
    refute prompt =~ "Auto Review"
    refute prompt =~ "acceptance gate"
  end
end
