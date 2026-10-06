defmodule SymphonyElixir.PlaybookTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Playbook
  alias SymphonyElixir.Playbook.FileSystem
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowPreview

  @workflow_path Path.expand(Path.join([__DIR__, "..", "..", "WORKFLOW.md"]))
  @ticket_types_tag ~s({%- render "ticket_types", issue: issue %})
  @ticket_types_anchor "The `Todo` -> `In Progress` transition and the workpad still apply.\n"
  @render_opts [strict_variables: true, file_system: {FileSystem, nil}]

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
    ticket_types
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

    assert flat =~
             "the move ends the run shortly after: first push your committed work (open or update the PR if the rest of the ticket is done) and record the blocker in the workpad, then call it, so the person finds the PR waiting with the ticket."

    assert flat =~ "Never add a label to say a person must act."
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

  test "the playbook aggregate renders review_brief between the repo's Step 4 and the completion bar" do
    assert {"review_brief", 95} in Playbook.aggregate()

    slots = Map.new(Playbook.aggregate())
    assert slots["parent_tickets"] < slots["review_brief"] and slots["review_brief"] < slots["completion_bar"]
  end

  test "the repo WORKFLOW.md renders the review brief and asks for it at every handoff" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @workflow_path, agent_kind: "claude")
    flat = String.replace(prompt, ~r/\s+/, " ")

    # The brief's own section, with the plan's brief covering every artifact, decision and sub-ticket.
    assert prompt =~ "\n## Review brief\n\nThe workpad is the agent's log"
    assert flat =~ "link every artifact (each document or artifact comment, the HTML screens), list every sub-ticket"
    assert flat =~ "put every decision the plan leaves open under `Decisions needed`"

    # Plan to In Review / Human Review: the plan run, a resumed plan and a re-plan.
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

  test "scoped_tools lists the document tools for a ticket's long-lived artifacts" do
    assert {:ok, body} = Playbook.fetch("scoped_tools")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "`linear_create_document(title, content)` creates one in the issue's project, titled `<identifier> · <title>`, and attaches it to the issue"
    assert flat =~ "`linear_update_document(document_id, content, title?)` replaces its content"
    assert flat =~ "`linear_get_document(document_id?)` lists the issue's documents"
  end

  describe "ticket_types" do
    test "an untyped ticket renders the same WORKFLOW.md prompt as before the partial" do
      {without_tag, with_tag} = workflow_bodies()

      for labels <- [[], ["bug", "feature", "type:other", "needs-human"]] do
        assert render(with_tag, labels) == render(without_tag, labels)
      end
    end

    test "a typed ticket gets its section between Step 0 and Step 1 of WORKFLOW.md" do
      {_without_tag, with_tag} = workflow_bodies()
      prompt = render(with_tag, ["type:bug"])

      assert prompt =~ "still apply.\n\n## Ticket type: bug\n"
      assert prompt =~ ~r/as the regression test\.\n4\. Name the root cause[^\n]*\n\n## Step 1: /
    end

    test "a bug checks Observed, Expected and Steps to reproduce, then starts with a failing test" do
      prompt = render_ticket_types(["type:bug"])

      assert prompt =~ "## Ticket type: bug"
      assert prompt =~ "### Readiness check"
      assert prompt =~ "each required section with text of the operator's own: `Observed`, `Expected` and `Steps to reproduce`"
      assert prompt =~ "A section is missing when its heading is absent, or when it is empty or holds only the template's italic hint."
      assert prompt =~ "`Where` and `Evidence` help but are not required."
      assert_sends_back(prompt)
      assert prompt =~ "First, write a test that reproduces the bug"
      assert prompt =~ "fails on the current code the way `Observed` describes"
      assert prompt =~ "record the failing command and its output in the workpad `Notes` as the reproduction signal, before changing the code under test"
      assert prompt =~ "The same test now passes and stays in the PR"
      refute prompt =~ "## Ticket type: feature"
      refute prompt =~ "## Ticket type: plan"
    end

    test "a feature checks Goal and Acceptance criteria, then delivers one PR that meets every criterion" do
      prompt = render_ticket_types(["type:feature"])

      assert prompt =~ "## Ticket type: feature"
      assert prompt =~ "each required section with text of the operator's own: `Goal` and `Acceptance criteria` (at least one criterion)"
      assert prompt =~ "`Context`, `User walkthrough` and `Out of scope` help but are not required."
      assert_sends_back(prompt)
      assert prompt =~ "One PR that meets every item under `Acceptance criteria`."
      assert prompt =~ "every step works end to end as written"
      assert prompt =~ "Nothing listed under `Out of scope`."
      refute prompt =~ "## Ticket type: bug"
    end

    test "a plan is never sent back and turns open questions into decisions with a recommended default" do
      for label <- ["plan", "breakdown"] do
        prompt = render_ticket_types([label])

        assert prompt =~ "## Ticket type: plan"
        assert prompt =~ "Every run on it follows the plan pipeline in `Parent tickets`."
        assert prompt =~ "A plan ticket is never sent back for missing input and has no readiness check."
        assert prompt =~ "Do not use the clarification escape hatch for a thin or unclear description, even one with only a `Vision`."
        assert prompt =~ "Turn each open question into a decision: the options, the default you recommend and why."
        assert prompt =~ "list every decision under a `Decisions` heading where the plan is handed over for review"
        assert prompt =~ "With no box checked under `Artifacts wanted`, or no such section, the plan is a plain split into sub-tickets."
        refute prompt =~ "### Readiness check"
      end
    end

    test "plan wins over bug, and bug over feature, when a ticket has several type labels" do
      plan = render_ticket_types(["type:bug", "type:feature", "plan"])
      assert plan =~ "## Ticket type: plan"
      refute plan =~ "## Ticket type: bug"
      refute plan =~ "## Ticket type: feature"

      bug = render_ticket_types(["type:feature", "type:bug"])
      assert bug =~ "## Ticket type: bug"
      refute bug =~ "## Ticket type: feature"
    end
  end

  test "the ticket templates name their label and sections" do
    templates = Path.expand(Path.join([__DIR__, "..", "..", "docs", "ticket-templates"]))

    for {file, label, sections} <- [
          {"bug.md", "type:bug", ["Observed", "Expected", "Steps to reproduce", "Where", "Evidence"]},
          {"feature.md", "type:feature", ["Goal", "Context", "Acceptance criteria", "User walkthrough", "Out of scope"]},
          {"plan.md", "plan", ["Vision", "Context", "Constraints", "Quality bar", "Artifacts wanted", "Done when"]}
        ] do
      body = File.read!(Path.join(templates, file))
      assert body =~ "- **Label:** `#{label}`"
      for section <- sections, do: assert(body =~ "\n## #{section}\n")
    end

    plan = File.read!(Path.join(templates, "plan.md"))

    for artifact <- ["Domain brief", "User journeys", "Kano feature map", "Screens", "Decisions"] do
      assert plan =~ "- [ ] #{artifact}\n"
    end

    assert File.read!(Path.join(templates, "README.md")) =~ "**Settings → Teams → _team_ → Templates**"
  end

  defp assert_sends_back(prompt) do
    assert prompt =~
             "When a required section is missing, do not guess: use the in-execution clarification escape hatch with one comment that names every missing section"

    assert prompt =~ "move the ticket to `Backlog` and stop, without a branch, a commit or a PR."
    assert prompt =~ "Skip the check when a PR is already attached to the ticket."
  end

  defp render_ticket_types(labels) do
    ~s({% render "ticket_types", issue: issue %})
    |> render(labels)
    |> String.replace(~r/\s+/, " ")
  end

  # WORKFLOW.md's prompt body, its instruction files expanded, without the ticket_types render and
  # with it right after Step 0.
  defp workflow_bodies do
    {:ok, %{prompt_template: body}} = Workflow.load(@workflow_path)
    without_tag = String.replace(body, @ticket_types_tag <> "\n", "")
    assert without_tag =~ @ticket_types_anchor

    {without_tag, String.replace(without_tag, @ticket_types_anchor, @ticket_types_anchor <> @ticket_types_tag <> "\n")}
  end

  defp render(source, labels) do
    issue = %{
      "identifier" => "TP-1",
      "title" => "Title",
      "state" => "Todo",
      "labels" => labels,
      "url" => "https://linear.app/x/issue/TP-1",
      "description" => "Description",
      "comments" => [],
      "linked_issues" => [],
      "sub_issues" => []
    }

    assigns = %{"issue" => issue, "attempt" => nil, "agent" => %{"workpad_heading" => "## Symphony Workpad"}}
    assert {:ok, rendered, []} = Solid.render(Solid.parse!(source), assigns, @render_opts)
    IO.iodata_to_binary(rendered)
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
