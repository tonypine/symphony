defmodule SymphonyElixir.PlaybookTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Playbook
  alias SymphonyElixir.Playbook.FileSystem
  alias SymphonyElixir.WorkflowPreview

  @workflow_path Path.expand(Path.join([__DIR__, "..", "..", "WORKFLOW.md"]))

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
    review_brief
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

    assert body =~ "Then move the parent to `In Review` with\n   `linear_update_state` and end the turn."
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

  test "review_brief keeps one brief per ticket, edited in place, with the fixed format and the moves for each kind" do
    assert {:ok, body} = Playbook.fetch("review_brief")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "The workpad is the agent's log, and the person reviewing never needs to read it."
    assert flat =~ "One brief per ticket."
    assert flat =~ "When one exists, edit it in place with `linear_update_comment`, never post a second brief."
    assert flat =~ "Only the first handoff creates it, with `linear_add_comment`."
    assert flat =~ "Write it before the state move that hands the ticket over."

    for section <- [
          "## Review brief",
          "**What to review:**",
          "**What changed since the last brief:**",
          "**Decisions needed:**",
          "- Options: <A>; <B>",
          "- Recommendation:",
          "**How to approve / change / reject:**"
        ] do
      assert body =~ section
    end

    assert flat =~
             "A plan's brief covers the whole plan in one review: link every artifact (each document or artifact comment, the HTML screens), " <>
               "list every sub-ticket with its identifier and one line on what it delivers (the `Final verification:` one too), " <>
               "and put every decision the plan leaves open under `Decisions needed`, so the person reviews everything at once."

    assert flat =~ "A PR's brief links the PR and says what to check"

    for kind <- ["**Plan review**", "**PR review**", "**Human Review**", "**Final verification**"] do
      assert body =~ kind
    end

    assert flat =~ "Approve: move the parent to `Waiting on sub-tickets`"
    assert flat =~ "Reject: move the parent to `Rework`; Symphony cancels its `Backlog` sub-tickets"
    assert flat =~ "Approve: move the ticket to `Merging`; Symphony merges the PR."
    assert flat =~ "Approve: do the steps in the `## Action needed:` comment, then move the ticket to `Todo`"
    assert flat =~ "Approve: move the ticket to `Done`; the parent's close-out run follows."
  end

  test "the repo WORKFLOW.md renders the review brief and asks for it at every handoff" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @workflow_path, agent_kind: "claude")
    flat = String.replace(prompt, ~r/\s+/, " ")

    # The brief's own section, with the plan's brief covering every artifact, decision and sub-ticket.
    assert prompt =~ "\n## Review brief\n\nThe workpad is the agent's log"
    assert flat =~ "link every artifact (each document or artifact comment, the HTML screens), list every sub-ticket"
    assert flat =~ "put every decision the plan leaves open under `Decisions needed`"

    # Plan to In Review / Human Review: the breakdown run, a resumed plan and a re-plan.
    assert flat =~
             "Leave the review brief (see `Review brief`): one brief for the whole plan, linking every artifact, " <>
               "listing every sub-ticket and every decision needed, with the moves that approve, change or reject it. " <>
               "Then move the parent to `In Review`"

    assert flat =~ "leave the review brief (see `Review brief`), and move the parent to `In Review`."
    assert flat =~ "Edit the existing review brief in place with `linear_update_comment`, with what the new plan changes"

    # A second handoff edits the brief instead of adding one: the plan revision run and the PR.
    assert flat =~
             "Edit the existing review brief in place with `linear_update_comment` (never post a second one): " <>
               "bring every part up to date and list under `What changed since the last brief` one line per change"

    assert flat =~ "When one exists, edit it in place with `linear_update_comment`, never post a second brief."

    # PR to In Review.
    assert flat =~
             "The review brief is left before the move (see `Review brief`): it links the PR and says what to check. " <>
               "On a later handoff (review comments addressed, a CI fix), the existing brief is edited in place with `linear_update_comment`"

    # Final verification and human-action handoffs.
    assert flat =~ "Before either move, leave the review brief (see `Review brief`): the requirements checked"
    assert flat =~ "After a `linear_request_human_action` request, leave the review brief (see `Review brief`) pointing to the request"

    # The brief is never read as a person's comment on the plan, and the workpad points to it.
    assert flat =~ "skip the workpad, the review brief, QA reports"
    assert flat =~ "The workpad is the agent's log: plan, checklist, validation evidence and notes."
    assert flat =~ "The person reviewing reads the `## Review brief` comment instead"
    assert flat =~ "The one comment written for the person is the review brief, edited in place at each handoff."
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
