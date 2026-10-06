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

  test "the rendered prompt names the `plan` label, with `breakdown` as its older name" do
    template = Solid.parse!(~s({% render "status_map" %}\n{% render "parent_tickets" %}))
    {:ok, rendered, []} = Solid.render(template, %{}, file_system: {FileSystem, nil})
    prompt = rendered |> IO.iodata_to_binary() |> String.replace(~r/\s+/, " ")

    assert prompt =~ "The `plan` label is a human's signal that a ticket is a plan ticket"
    assert prompt =~ "`breakdown` is the label's older name and is still accepted"
    assert prompt =~ "when the ticket has the `plan` label, and when its title starts with `Final verification:`"
    assert prompt =~ "`Waiting on sub-tickets` -> a plan ticket (label `plan`, or `breakdown`, its older name)"
    assert prompt =~ "### Plan run (no `Sub-issues` in the issue context"
    refute prompt =~ "The `breakdown` label is"
  end

  test "parent_tickets resumes a stopped plan and revises one under review without re-planning" do
    assert {:ok, body} = Playbook.fetch("parent_tickets")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "**Resume:** the parent is in `Todo` or `In Progress`, has sub-tickets in `Backlog` only"
    assert flat =~ "keep every artifact comment and sub-ticket already made"
    assert flat =~ "never file a sub-ticket a second time"
    assert flat =~ "### Plan revision run (a person commented on the plan under review)"
    assert flat =~ "State: only `In Review`. A comment on a parent in `Human Review` starts nothing"
    assert flat =~ "a comment starting with `Supervisor review:` or `Supervisor note:` never triggers a run, in any state"
    assert flat =~ "Edit the existing artifact comments (use cases, features, journeys and so on) with `linear_update_comment`"
    assert flat =~ "Leave every sub-ticket outside `Backlog` as it is."
    assert flat =~ "Reply under each comment with `linear_add_comment` and its `parent_id`"
    assert flat =~ "Never move it to `Waiting on sub-tickets` and never promote a sub-ticket"
    assert flat =~ "**Re-plan:** the parent is in `Rework`."
  end

  test "escape_hatches checks a CI job's UTC age before asking a human, and withdraws a request not needed" do
    assert {:ok, body} = Playbook.fetch("escape_hatches")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "Before requesting a human action for slow or stuck CI, compute the job's age from the API's UTC timestamps"
    assert flat =~ "against the current UTC time (`date -u`), never against local time"
    assert flat =~ "When the job is under 30 minutes old, wait for the CI poller's flaky re-run instead of asking a human."
    assert flat =~ "withdraw it with `linear_withdraw_human_action`"
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
