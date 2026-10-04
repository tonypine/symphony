defmodule SymphonyElixir.PlaybookTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Playbook
  alias SymphonyElixir.Playbook.FileSystem

  @expected_names ~w(
    ci_triage
    completion_bar
    continuation_context
    default_posture
    dependency_guardrail
    escape_hatches
    guardrails
    issue_context
    out_of_scope_backlog
    parent_tickets
    pr_feedback_sweep
    reproduce_and_blast_radius
    scoped_tools
    status_map
    workpad_bootstrap
    workpad_template
  )

  test "names/0 lists the embedded playbook partials, sorted" do
    assert Playbook.names() == @expected_names
  end

  test "every partial is non-empty, parses as Solid, and declares a matching name header" do
    for name <- Playbook.names() do
      assert {:ok, body} = Playbook.fetch(name)
      assert byte_size(body) > 0
      assert {:ok, _template} = Solid.parse(body)
      assert body =~ "name: #{name}\n"
    end
  end

  test "parent_tickets ends a breakdown run in In Review and leaves the approval to a human" do
    assert {:ok, body} = Playbook.fetch("parent_tickets")

    assert body =~ "move the\n   parent to `In Review` with `linear_update_state`, and end the turn."
    assert body =~ "Never move the parent to `Waiting on sub-tickets` yourself"
    assert body =~ "Symphony\n  then moves every sub-ticket still in `Backlog` to `Todo` in one batch"
    assert body =~ "In `Rework` (a re-plan run)"
    refute body =~ "A human\n   promotes the sub-tickets to `Todo`."
  end

  test "parent_tickets resumes a stopped plan and revises one under review without re-planning" do
    assert {:ok, body} = Playbook.fetch("parent_tickets")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "**Resume:** the parent is in `Todo` or `In Progress`, has sub-tickets in `Backlog` only"
    assert flat =~ "keep every artifact comment and sub-ticket already made"
    assert flat =~ "never file a sub-ticket a second time"
    assert flat =~ "### Plan revision run (a person commented on the plan under review)"
    assert flat =~ "Edit the existing artifact comments (use cases, features, journeys and so on) with `linear_update_comment`"
    assert flat =~ "Leave every sub-ticket outside `Backlog` as it is."
    assert flat =~ "Reply under each comment with `linear_add_comment` and its `parent_id`"
    assert flat =~ "Never move it to `Waiting on sub-tickets` and never promote a sub-ticket"
    assert flat =~ "**Re-plan:** the parent is in `Rework`."
  end

  test "fetch/1 returns :error for an unknown partial" do
    assert Playbook.fetch("does_not_exist") == :error
  end

  test "FileSystem serves known partials and errors on unknown names" do
    assert {:ok, body} = FileSystem.read_template_file("pr_feedback_sweep", nil)
    assert body =~ "PR feedback sweep protocol"

    assert {:error, %Solid.FileSystem.Error{reason: reason}} =
             FileSystem.read_template_file("nope", nil)

    assert reason =~ "unknown playbook partial `nope`"
  end
end
