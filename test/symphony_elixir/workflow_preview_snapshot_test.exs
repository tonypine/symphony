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

  test "the preview states the walkthrough routing rule, with dark mode and the status-bar menu as QA steps" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @repo_workflow, agent_kind: "claude", repo_key: "app")
    flat = String.replace(prompt, ~r/\s+/, " ")

    assert flat =~ "Write the walkthrough end to end, in plain words from the user's seat, and name no test and no check in it."
    assert flat =~ "copy its numbered steps and expected results into that criterion verbatim, with any `Proved by:` line a step has"
    assert flat =~ "Each walkthrough step is proved in one place, and you name it"
    assert flat =~ "record the proof of every step an automated test in this PR covers, before the handoff push: call `linear_record_walkthrough_proofs`"
    assert flat =~ "Name only tests in this PR, and never a check name: the repo's `proof_check` in WORKFLOW.md is the check that runs them"
    assert flat =~ "record the step's proof again with `linear_record_walkthrough_proofs`"
    refute flat =~ "<check> › <test>` or `Proved by: QA`"

    assert flat =~
             "a walkthrough step that judges the macOS app by sight in dark mode, or judges the look of the status-bar menu, is a `Proved by: QA` step"

    assert flat =~
             "QA walks it with TP-1045's tools: `qa_launch_app`'s `appearance` argument launches the app in light and in dark"

    assert flat =~ "`qa_open_status_menu` with a `qa_screenshot` of the menu shows how it looks"

    refute flat =~ "Until TP-1045 lands"
    refute flat =~ "asks QA for light mode only"
  end

  test "the preview names none of the retired states, checks or tickets" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @repo_workflow, agent_kind: "claude", repo_key: "app")

    for word <- @retired, do: refute(prompt =~ word, "the prompt still says #{inspect(word)}")

    for part <- ["`Code Review`", "`QA`", "`CI Fix`", "`Plan Review`", "`Epic Review`", "`Needs Decision`", "`Blocked`", "That push is the handoff signal"] do
      assert prompt =~ part
    end
  end
end
