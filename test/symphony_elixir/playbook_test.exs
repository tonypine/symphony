defmodule SymphonyElixir.PlaybookTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Playbook
  alias SymphonyElixir.Playbook.FileSystem
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowPreview

  @workflow_path Path.expand(Path.join([__DIR__, "..", "..", "WORKFLOW.md"]))
  @ticket_types_tag ~s({%- render "ticket_types", issue: issue %})
  @ticket_types_anchor "The `Todo` -> `In Progress` transition and the workpad still apply."
  @plan_pipeline_tag ~s({%- render "plan_pipeline", issue: issue %})
  @plan_description """
  ## Vision

  A plant care app.

  ## Artifacts wanted

  - [x] Domain brief
  - [ ] User journeys
  - [x] Kano feature map
  - [x] Screens
  - [ ] Decisions
  """
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
    plan_pipeline
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

  describe "the one machine's partials" do
    test "status_map names the phases and holds, and none of the retired states" do
      assert {:ok, body} = Playbook.fetch("status_map")

      assert body =~ "`Code Review`"
      assert body =~ "`Plan Review`"
      assert body =~ "`Blocked` and `Needs Decision` are labels, not states"
      refute body =~ "`Auto Review`"
      refute body =~ "In Review"
      refute body =~ "Human Review"
    end

    test "escape_hatches holds the ticket instead of moving it, and hands a person no check" do
      assert {:ok, body} = Playbook.fetch("escape_hatches")

      assert body =~ "The tool sets the `Needs Decision` hold and the `Needs Decision` label\n  and leaves the ticket exactly where it is"
      assert body =~ "Do not move the ticket"

      # No `## Supervisor check` for a person to run: a check an agent can't run is a coverage gap
      # (CI or a QA playbook), and the block that keeps it from running goes to the self-heal lane.
      assert body =~ "A check is never handed to a\n  person and never moves a ticket."
      refute body =~ "Supervisor check"
      assert body =~ "the self-heal lane"
    end

    test "parent_tickets hands over to Plan Review and sends a change through Rework" do
      assert {:ok, body} = Playbook.fetch("parent_tickets")

      assert body =~ "hands the parent over with `linear_update_state` naming `Plan Review`"
      assert body =~ "Only a plan parent may name it."
      refute body =~ "In Review"
      refute body =~ "Human Review"
      refute body =~ "Final verification:"
      assert body =~ "Symphony moves the\n  parent to `Rework` itself, and the run revises the plan in place"
      assert body =~ "State: only `Plan Review`"
    end

    test "the partials that write walkthroughs write plain steps: the implementer names the test, the repo the check" do
      assert {:ok, backlog} = Playbook.fetch("out_of_scope_backlog")
      backlog = String.replace(backlog, ~r/\s+/, " ")

      assert backlog =~ "Write the walkthrough end to end, in plain words from the user's seat, and name no test and no check in it."
      assert backlog =~ "The implementer, who writes the tests, records which test proves each step it covers (`Proved by: <test>`)"
      assert backlog =~ "the repo names the check that runs them (`proof_check` in its WORKFLOW.md)"
      assert backlog =~ "Unit-level facts (keys, counters, error tuples) are acceptance criteria, not walkthrough steps."
      assert backlog =~ "A step that needs an environment QA lacks (a signed build, a device, real credentials) needs an automated harness"
      assert backlog =~ "A judgment by sight of what the user sees ends with `Proved by: QA`"
      assert backlog =~ "One journey sits in one walkthrough."

      for partial <- ["out_of_scope_backlog", "parent_tickets", "plan_pipeline", "ticket_types"] do
        assert {:ok, body} = Playbook.fetch(partial)
        refute body =~ "<check> › <test>", "#{partial} still asks for a check name"
      end

      assert {:ok, parent} = Playbook.fetch("parent_tickets")
      parent = String.replace(parent, ~r/\s+/, " ")

      assert parent =~ "the result they should see, naming no test and no check"
      assert parent =~ "One journey never sits both in a sub-ticket's walkthrough and in an end-to-end sub-ticket"

      assert {:ok, types} = Playbook.fetch("ticket_types")
      assert String.replace(types, ~r/\s+/, " ") =~ "record it on the step with `linear_record_walkthrough_proofs` (`Proved by: <test>`, never a check name)"
    end

    test "plan_pipeline files no verification sub-ticket: the epic closes itself" do
      assert {:ok, body} = Playbook.fetch("plan_pipeline")

      assert body =~ "The split files no verification sub-ticket: the epic closes"
      refute body =~ "Final verification:"
      refute body =~ "sub-ticket last)"
    end

    # The partials that once handed off to `In Review`: each names none of the retired states,
    # checks or tickets.
    for {name, says} <- [
          {"pr_feedback_sweep", "before the push that hands it off to\n`Code Review`"},
          {"ci_triage", "moves it to `CI Fix`"},
          {"review_brief", "a PR handed off to `Code Review`"},
          {"completion_bar", "## Completion bar before the handoff"},
          {"guardrails", "while a `Blocked` or `Needs Decision` hold is set, do not make changes"}
        ] do
      test "#{name} hands off to the machine" do
        assert {:ok, body} = Playbook.fetch(unquote(name))
        assert body =~ unquote(says)

        for word <- ["Auto Review", "In Review", "Human Review", "Supervisor check", "Final verification"] do
          refute body =~ word
        end
      end
    end

    test "the file system serves the partial whatever its options say" do
      assert FileSystem.read_template_file("status_map", "legacy") == Playbook.fetch("status_map")
      assert FileSystem.read_template_file("status_map", nil) == Playbook.fetch("status_map")
      assert {:error, %Solid.FileSystem.Error{}} = FileSystem.read_template_file("not_a_partial", nil)
    end
  end

  test "parent_tickets hands a plan over to Plan Review and leaves the approval to a person" do
    assert {:ok, body} = Playbook.fetch("parent_tickets")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "Then hand the parent over to `Plan Review` with `linear_update_state` and end the turn."
    assert flat =~ "Never move the parent to `Waiting on sub-tickets` yourself"
    assert flat =~ "Symphony then moves every sub-ticket still in `Backlog` to `Todo` in one batch"
    refute flat =~ "A human promotes the sub-tickets to `Todo`."
  end

  test "the rendered prompt names the `plan` label, with `breakdown` as its older name" do
    template = Solid.parse!(~s({% render "status_map" %}\n{% render "parent_tickets" %}))
    {:ok, rendered, []} = Solid.render(template, %{}, file_system: {FileSystem, nil})
    prompt = rendered |> IO.iodata_to_binary() |> String.replace(~r/\s+/, " ")

    assert prompt =~ "The `plan` label is a human's signal that a ticket is a plan ticket"
    assert prompt =~ "`breakdown` is the label's older name and is still accepted"
    assert prompt =~ "Follow this section instead of the normal implementation steps when the ticket has the `plan` label."
    assert prompt =~ "`Waiting on sub-tickets` -> a plan parent whose plan a person approved"
    assert prompt =~ "### Plan run (a new plan: no `Sub-issues` in the issue context"
    refute prompt =~ "The `breakdown` label is"
  end

  test "parent_tickets resumes a stopped plan and revises one under review without re-planning" do
    assert {:ok, body} = Playbook.fetch("parent_tickets")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "**Resume:** the parent is in `Todo` or `In Progress`, has sub-tickets in `Backlog` only"
    assert flat =~ "keep every artifact document, comment and sub-ticket already made"
    assert flat =~ "never file a sub-ticket a second time"
    assert flat =~ "### Plan revision run (a person commented on the plan under review)"
    assert flat =~ "State: only `Plan Review`. A comment on a parent in any other state starts no revision"
    assert flat =~ "a comment starting with `Supervisor review:` or `Supervisor note:` never triggers a run, in any state"
    assert flat =~ "documents with `linear_update_document`, the HTML screens as the `Plan pipeline` says, and artifact comments (use cases, features, journeys and so on) with `linear_update_comment`"
    assert flat =~ "Leave every sub-ticket outside `Backlog` as it is."
    assert flat =~ "Reply under each comment with `linear_add_comment` and its `parent_id`"
    assert flat =~ "Never move it to `Waiting on sub-tickets` and never promote a sub-ticket"
    assert flat =~ "**Re-plan:** the parent is in `Rework` because a person rejected the plan."
  end

  test "escape_hatches checks a CI job's UTC age before asking a human, and withdraws a request not needed" do
    assert {:ok, body} = Playbook.fetch("escape_hatches")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "Before requesting a human action for slow or stuck CI, compute the job's age from the API's UTC timestamps"
    assert flat =~ "against the current UTC time (`date -u`), never against local time"
    assert flat =~ "When the job is under 30 minutes old, wait for the CI poller's flaky re-run instead of asking a human."
    assert flat =~ "withdraw it with `linear_withdraw_human_action`"

    assert flat =~
             "the run ends shortly after: first push your committed work (open or update the PR if the rest of the ticket is done) and record the blocker in the workpad, then call it, so the person finds the PR waiting with the ticket."

    assert flat =~ "Never add a label to say a person must act: `Needs Decision` is set by the tool, not by you."
  end

  test "ci_triage fixes every red check at its cause and ends a CI-fix run in one of three ways" do
    assert {:ok, body} = Playbook.fetch("ci_triage")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "Every red check is a defect to fix, never a check to rerun."
    assert flat =~ "A test that fails only some of the time is a defect like any other."
    assert flat =~ "fix it at that cause"
    assert flat =~ "`mix test <file>:<line> --repeat-until-failure 500`"
    assert flat =~ "Fix a failure in code the ticket didn't touch the same way, on the same branch"
    assert flat =~ "make the failing step robust where you can, for example a bounded retry inside the step. When you cannot, ask with `linear_request_human_action`."
    assert flat =~ "A CI-fix run ends in one of three ways only:"
    assert flat =~ "**A new head.**"
    assert flat =~ "**A move to `Rework`.**"
    assert flat =~ "**A request for a person.**"
    assert flat =~ "Deciding that a failure is flaky, or that it is not this ticket's, is not an ending"

    refute flat =~ "flaky/retryable"
    refute flat =~ "rerun of a flaky check"
    refute flat =~ "document it in the workpad"

    assert {:ok, status_map} = Playbook.fetch("status_map")
    assert status_map =~ "every red check is fixed, never rerun"
    refute status_map =~ "rerun of a flaky check"
  end

  test "review_brief keeps one brief per ticket, edited in place, with the fixed format and the moves for each kind" do
    assert {:ok, body} = Playbook.fetch("review_brief")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "The workpad is the agent's log, and nobody reviewing needs to read it."
    assert flat =~ "One brief per ticket."
    assert flat =~ "When one exists, edit it in place with `linear_update_comment`, never post a second brief."
    assert flat =~ "Only the first handoff creates it, with `linear_add_comment`."
    assert flat =~ "Write it before the state move that hands the ticket over."

    for section <- [
          "## Review brief",
          "**What to review:**",
          "**What changed since the last brief:**",
          "**Decisions needed:**",
          "1. <the request's title>: <link to the request comment>",
          "**How to approve / change / reject:**"
        ] do
      assert body =~ section
    end

    assert flat =~
             "A plan's brief covers the whole plan in one review: link every artifact (each document or artifact comment, the HTML screens), " <>
               "list every sub-ticket with its identifier and one line on what it delivers, " <>
               "and link each request the plan run raised for a choice it leaves open under `Decisions needed`, so the person reviews everything at once. " <>
               "The brief links the requests and never restates them"

    refute body =~ "- Options: <A>; <B>"

    assert flat =~ "A PR's brief links the PR and says what to check"

    for kind <- ["**Plan review**", "**PR review**", "**Decision**"] do
      assert body =~ kind
    end

    refute body =~ "**Human Review**"
    refute body =~ "**Final verification**"
    assert flat =~ "Approve: move the parent to `Waiting on sub-tickets`"
    assert flat =~ "Reject: Reject Plan in the Inbox, or move the parent to `Rework`; Symphony cancels its `Backlog` sub-tickets"
    assert flat =~ "or ask for changes (Ask for Changes in the Inbox, or a comment on any part of the plan)"
    assert flat =~ "keeps its sub-tickets and updates this brief. Nothing is approved until you approve it."
    assert flat =~ "Approve: nothing to do, or confirm the merge decision when manual review is on."
    assert flat =~ "Approve: reply under the `## Decision needed:` comment with the option you pick; the hold clears and the ticket continues where it stopped."
    refute flat =~ "do the steps"
    assert flat =~ "Reject: `Restart` from the Director app closes the PR and starts over."
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
    assert flat =~ "link each request the plan run raised for a choice it leaves open under `Decisions needed`"
    assert flat =~ "Ask each choice the plan leaves open with `linear_request_human_action`, one request per choice, before the handoff"

    # Plan to Plan Review: the plan run, a resumed plan and a re-plan.
    assert flat =~
             "Leave the review brief (see `Review brief`): one brief for the whole plan, linking every artifact, " <>
               "listing every sub-ticket and linking each request step 4 raised, with the moves that approve, change or reject it. " <>
               "Then hand the parent over to `Plan Review`"

    assert flat =~ "leave the review brief (see `Review brief`), and hand the parent over as the plan run's last step says."
    assert flat =~ "Edit the existing review brief in place with `linear_update_comment`, with what the new plan changes"

    # A second handoff edits the brief instead of adding one: the plan revision run and the PR.
    assert flat =~
             "Edit the existing review brief in place with `linear_update_comment` (never post a second one): " <>
               "bring every part up to date and list under `What changed since the last brief` one line per change"

    assert flat =~ "When one exists, edit it in place with `linear_update_comment`, never post a second brief."

    # PR to Code Review.
    assert flat =~
             "The review brief is left before the push (see `Review brief`): it links the PR and says what to check. " <>
               "On a later handoff (review comments addressed, a rework verdict answered), the existing brief is edited in place with `linear_update_comment`"

    # Human-action handoffs.
    assert flat =~ "After a `linear_request_human_action` request, leave the review brief (see `Review brief`) pointing to the request"

    # The brief is never read as a person's comment on the plan, and the workpad points to it.
    assert flat =~ "skip the workpad, the review brief, QA reports"
    assert flat =~ "The workpad is the agent's log: plan, checklist, validation evidence and notes."
    assert flat =~ "The person reviewing reads the `## Review brief` comment instead"
    assert flat =~ "The one comment written for the person is the review brief, edited in place at each handoff."
  end

  test "the repo WORKFLOW.md hands a person only decisions, and routes checks an agent can't run to CI or QA" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @workflow_path, agent_kind: "claude")
    flat = String.replace(prompt, ~r/\s+/, " ")

    assert prompt =~ "\n## Decisions for a person, checks for the machine (required behavior)\n"
    assert flat =~ "A person only ever makes decisions. Never hand them a check to run or a runbook of steps."
    assert flat =~ "When a manual check could be an automated test, write the test instead of asking anyone to check by hand."

    # TP-612: work already on main becomes a decision, never steps.
    assert flat =~ "hand over the call to close it as a decision; never as steps."

    # A request for a person is a decision with options.
    assert flat =~ "one question in `decision`, 2 to 4 options, each with what it does, one of them recommended. A request without options is refused."
    assert flat =~ "A check on a device is not a blocker for a person: it belongs to CI or a QA playbook"

    for word <- ["Supervisor check", "Auto Review", "In Review", "Human Review", "exact steps"] do
      refute flat =~ word
    end
  end

  test "scoped_tools lists the document tools for a ticket's long-lived artifacts" do
    assert {:ok, body} = Playbook.fetch("scoped_tools")
    flat = String.replace(body, ~r/\s+/, " ")

    assert flat =~ "`linear_create_document(title, content)` creates one in the issue's project, titled `<identifier> · <title>`, and attaches it to the issue"
    assert flat =~ "`linear_update_document(document_id, content, title?)` replaces its content"
    assert flat =~ "`linear_get_document(document_id?)` lists the issue's documents"
  end

  describe "ticket_types" do
    test "the playbook aggregate renders ticket_types right after the repo's Step 0, left-trimmed" do
      assert {"ticket_types", 52} in Playbook.aggregate()

      {:ok, %{prompt_template: body}} = Workflow.load(@workflow_path)
      assert body =~ @ticket_types_anchor <> "\n\n" <> @ticket_types_tag <> "\n\n## Step 1: "
    end

    # Blank lines included: the left-trimmed tag takes the blank line before it, and the
    # partial renders nothing at all for an untyped ticket.
    test "an untyped ticket renders the same WORKFLOW.md prompt as without the partial" do
      {without_tag, with_tag} = workflow_bodies()

      for labels <- [[], ["bug", "feature", "type:other", "needs-human"]] do
        prompt = render(with_tag, labels)
        assert prompt == render(without_tag, labels)
        refute prompt =~ "## Ticket type:"
      end
    end

    test "a typed ticket gets its section between Step 0 and Step 1 of WORKFLOW.md" do
      {:ok, workflow} = Workflow.load(@workflow_path)
      issue = %{WorkflowPreview.sample_issue() | labels: ["type:bug"]}
      prompt = PromptBuilder.build_prompt(issue, workflow: workflow, prompt_mode: :issue, agent_kind: "claude")

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
      flat = String.replace(prompt, ~r/\s+/, " ")
      assert flat =~ "Cover every step code can drive with a test in this PR, and record it on the step with `linear_record_walkthrough_proofs`"
      assert flat =~ "QA walks a `Proved by: QA` step and a step no test covers."
      assert prompt =~ "Nothing listed under `Out of scope`."
      refute prompt =~ "## Ticket type: bug"
    end

    test "a plan is never sent back and turns open questions into decisions with a recommended default" do
      for label <- ["plan", "breakdown"] do
        prompt = render_ticket_types([label])

        assert prompt =~ "## Ticket type: plan"
        assert prompt =~ "Every run on it follows `Parent tickets`, and the `Plan pipeline` when it has an `Artifacts wanted` section."
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

  describe "plan_pipeline" do
    test "the playbook aggregate renders plan_pipeline after the repo's Step 4, right before review_brief, left-trimmed" do
      assert {"plan_pipeline", 94} in Playbook.aggregate()

      slots = Map.new(Playbook.aggregate())
      assert slots["parent_tickets"] < slots["plan_pipeline"] and slots["plan_pipeline"] < slots["review_brief"]

      {:ok, %{prompt_template: body}} = Workflow.load(@workflow_path)

      # The repo's Step 4 closes with its Restart line; `{%-` left-trims the blank line before the
      # tag, and the partial renders its own when it renders anything.
      assert body =~ "rather than starting over on your own.\n\n" <> @plan_pipeline_tag <> ~s(\n\n{% render "review_brief" %})
    end

    # A plan written before the templates (no `Artifacts wanted`) keeps today's plain split.
    test "only a plan ticket with an Artifacts wanted section gets it; every other prompt is unchanged" do
      {:ok, %{prompt_template: body}} = Workflow.load(@workflow_path)
      without_tag = String.replace(body, "\n\n" <> @plan_pipeline_tag, "")
      refute without_tag =~ "plan_pipeline"

      for {labels, description} <- [
            {[], @plan_description},
            {["type:feature", "planning"], @plan_description},
            {["plan"], "Split this into sub-tickets."},
            {["breakdown"], nil}
          ] do
        prompt = render(body, labels, description)
        assert prompt == render(without_tag, labels, description)
        refute prompt =~ "## Plan pipeline"
      end

      for label <- ["plan", "breakdown"] do
        prompt = render(body, [label], @plan_description)
        assert prompt =~ ~r/starting over on your own\.\n\n## Plan pipeline\n/
        assert prompt =~ ~r/updates the brief\.\n\n## Review brief\n/
      end
    end

    test "it names the six stages in order, a document each, and the screens as a document plus one HTML file" do
      prompt = render_plan_pipeline(["plan"])

      stages = [
        "1. **Domain brief** (document `Domain brief`)",
        "2. **User journeys** (document `User journeys`)",
        "3. **Kano feature map** (document `Kano feature map`)",
        "4. **Screens** (document `Screens`, plus one HTML file)",
        "5. **Decisions** (document `Decisions`)",
        "6. **Implementation plan**"
      ]

      positions = Enum.map(stages, fn stage -> prompt |> :binary.match(stage) |> elem(0) end)
      assert positions == Enum.sort(positions)

      assert prompt =~ "Each stage produces one Linear document, created with `linear_create_document(title, content)`"
      assert prompt =~ "never create a second document for a stage."
      assert prompt =~ "first launch, everyday use, fixing a mistake, finding something again, changing a setting, and moving to a new phone"
      assert prompt =~ "Always add the platform baseline from the house standards as Must-be, whatever the niche."
      assert prompt =~ "Material 3 on Android, the Human Interface Guidelines on Apple platforms"
      assert prompt =~ "**One self-contained HTML file** shows every screen in the document"
      assert prompt =~ "with no external assets"
      assert prompt =~ "Write it inside the workspace, at `plan-artifacts/screens.html`"
      assert prompt =~ "never under `$TMPDIR`: `linear_attach_file` refuses a file outside the workspace"
      refute prompt =~ "Write it under `$TMPDIR`"

      assert prompt =~
               "attach it to the ticket with `linear_attach_file`, and link it at the top of the Screens document."

      assert prompt =~ "one ADR-style section per real choice"
    end

    test "every implementation sub-ticket traces to a feature, a journey and a Kano class, Must-be first" do
      prompt = render_plan_pipeline(["plan"])

      assert prompt =~
               "Every sub-ticket names the feature it builds, the journey and the screens it serves and the feature's Kano class " <>
                 "(feature → journey → screen → ticket), and carries a `## User walkthrough`"

      assert prompt =~ "File the Must-be tickets first, then Performance, then Attractive"
    end

    test "each sub-ticket's walkthrough is plain steps naming no test or check, and one journey sits in one place" do
      prompt = render_plan_pipeline(["plan"])
      flat = String.replace(prompt, ~r/\s+/, " ")

      assert flat =~ "each with the result they should see, in plain words and naming no test and no check"
      refute prompt =~ "<check> › <test>"
      assert flat =~ "Never put one journey both in a sub-ticket's walkthrough and in an end-to-end ticket"
      assert flat =~ "`## User walkthrough` of plain steps that name no test and no check"
      refute prompt =~ "written so an end-to-end test or the QA agent can reproduce it"
    end

    test "it loads the house standards, with a project override and the baseline as fallback" do
      prompt = render_plan_pipeline(["plan"])

      assert prompt =~ "Load the house standards on every run that produces a Kano map or screens: read `docs/standards/house-standards.md`"
      assert prompt =~ "A project overrides it with a Linear document named `House standards`"

      assert prompt =~
               "edit, delete, undo, search, backup/export/restore, settings, accessibility, offline use, notification control and privacy controls"
    end

    test "it checks every artifact against its stage's rubric before handing over" do
      prompt = render_plan_pipeline(["plan"])

      assert prompt =~ "Before handing over, check every artifact you produced against its rubric, fix what fails"

      for rubric <- ["Domain brief:", "User journeys:", "Kano feature map:", "Screens:", "Decisions:", "Implementation plan:"] do
        assert prompt =~ "- **#{rubric}**"
      end

      assert prompt =~ "every platform baseline item from the house standards is in it as Must-be"
      assert prompt =~ "every Must-be feature has a screen"
      assert prompt =~ "the HTML file shows every screen in the document and no other"
      assert prompt =~ "every sub-ticket traces to a feature, a journey and a Kano class"
    end

    test "it hands over once, after every wanted stage, with no stop between stages" do
      prompt = render_plan_pipeline(["plan"])

      assert prompt =~ "Produce every wanted stage, then the sub-tickets, then hand over once."
      assert prompt =~ "Never stop between stages for review, never move the ticket after one stage, and never wait for a stage to be approved"
      assert prompt =~ "An open question never stops the run: write it as a decision with the options and a recommended default, go on with the default"
      assert prompt =~ "The review brief (see `Review brief`) links every document, the HTML screens and the `Decisions` document"
      assert prompt =~ "The summary block's `artifacts` link every document and the HTML screens"
      assert prompt =~ "edits the documents with `linear_update_document`, attaches a revised HTML file and relinks it"
    end

    test "unchecked stages are skipped and the implementation plan is always produced" do
      prompt = render_plan_pipeline(["breakdown"])

      assert prompt =~ "Produce a stage only when its box is checked under `Artifacts wanted` (`[x]`). Skip every unchecked stage"
      assert prompt =~ "The implementation plan (stage 6) is always produced, whatever is checked."
      assert prompt =~ "With no box checked, the run is today's plain split into sub-tickets."
    end

    test "the house standards and the worked example exist" do
      docs = Path.expand(Path.join([__DIR__, "..", "..", "docs"]))
      standards = File.read!(Path.join([docs, "standards", "house-standards.md"]))

      for item <- ["Edit", "Delete", "Undo", "Search", "Backup, export and restore", "Settings", "Accessibility", "Offline use", "Notification control", "Privacy controls"] do
        assert standards =~ "\n| #{item} |"
      end

      assert standards =~ "## Design quality bar"

      example = File.read!(Path.join([docs, "ticket-templates", "examples", "plan.md"]))

      for section <- ["Vision", "Context", "Constraints", "Quality bar", "Artifacts wanted", "Done when"],
          do: assert(example =~ "\n## #{section}\n")

      for stage <- ["1. Domain brief", "2. User journeys", "3. Kano feature map", "4. Screens", "5. Decisions", "6. Implementation plan"],
          do: assert(example =~ "\n### #{stage}\n")
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

  # WORKFLOW.md's prompt body, its instruction files expanded, without and with the ticket_types
  # render the playbook puts right after Step 0.
  defp workflow_bodies do
    {:ok, %{prompt_template: body}} = Workflow.load(@workflow_path)
    without_tag = String.replace(body, "\n\n" <> @ticket_types_tag, "")
    refute without_tag =~ "ticket_types"

    {without_tag, body}
  end

  defp render_plan_pipeline(labels) do
    @plan_pipeline_tag
    |> render(labels, @plan_description)
    |> String.replace(~r/\s+/, " ")
  end

  defp render(source, labels, description \\ "Description") do
    issue = %{
      "identifier" => "TP-1",
      "title" => "Title",
      "state" => "Todo",
      "labels" => labels,
      "url" => "https://linear.app/x/issue/TP-1",
      "description" => description,
      "comments" => [],
      "linked_issues" => [],
      "sub_issues" => []
    }

    # `state_machine` is always assigned at runtime (`PromptBuilder`, always `designed`), so an
    # instruction file that still branches on it renders.
    assigns = %{"issue" => issue, "attempt" => nil, "agent" => %{"workpad_heading" => "## Symphony Workpad"}, "state_machine" => "designed"}
    assert {:ok, rendered, []} = Solid.render(Solid.parse!(source), assigns, @render_opts)
    IO.iodata_to_binary(rendered)
  end

  test "the description is edited only through linear_update_issue_summary, updated at each handoff" do
    flat = fn name ->
      assert {:ok, body} = Playbook.fetch(name)
      String.replace(body, ~r/\s+/, " ")
    end

    assert flat.("guardrails") =~ "Do not edit the issue body/description except through `linear_update_issue_summary`"
    assert flat.("review_brief") =~ "Next to the brief, update the summary block at the end of the issue description with `linear_update_issue_summary`"
    assert flat.("scoped_tools") =~ "`linear_update_issue_summary(status, links, changelog_entry)`"
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
