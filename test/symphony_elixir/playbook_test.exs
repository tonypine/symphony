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
    assert flat =~ "keep every artifact document, comment and sub-ticket already made"
    assert flat =~ "never file a sub-ticket a second time"
    assert flat =~ "### Plan revision run (a person commented on the plan under review)"
    assert flat =~ "State: only `In Review`. A comment on a parent in `Human Review` starts nothing"
    assert flat =~ "a comment starting with `Supervisor review:` or `Supervisor note:` never triggers a run, in any state"
    assert flat =~ "documents with `linear_update_document`, the HTML screens as the `Plan pipeline` says, and artifact comments (use cases, features, journeys and so on) with `linear_update_comment`"
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
    assert flat =~ "Approve: reply under the `## Decision needed:` comment with the option you pick, then move the ticket to `Todo`"
    refute flat =~ "do the steps"
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
    assert flat =~ "Before the move, leave the review brief (see `Review brief`): the requirements checked"
    assert flat =~ "After a `linear_request_human_action` request, leave the review brief (see `Review brief`) pointing to the request"

    # The brief is never read as a person's comment on the plan, and the workpad points to it.
    assert flat =~ "skip the workpad, the review brief, QA reports"
    assert flat =~ "The workpad is the agent's log: plan, checklist, validation evidence and notes."
    assert flat =~ "The person reviewing reads the `## Review brief` comment instead"
    assert flat =~ "The one comment written for the person is the review brief, edited in place at each handoff."
  end

  test "the repo WORKFLOW.md hands a person only decisions, and routes checks an agent can't run to the supervisor in In Review" do
    assert {:ok, prompt} = WorkflowPreview.render(file: @workflow_path, agent_kind: "claude")
    flat = String.replace(prompt, ~r/\s+/, " ")

    assert prompt =~ "\n## Decisions for a person, checks for the supervisor (required behavior)\n"
    assert flat =~ "A person only ever makes decisions. Never hand them a check to run or a runbook of steps."

    # A verification-only remainder goes to In Review with a supervisor check, never to Human Review.
    assert flat =~
             "When all that is left is verification an agent can't run (launching the app, a host crash check, a check on a device), " <>
               "hand it to the supervisor, never to a person and never to `Human Review`: leave a `## Supervisor check` block, " <>
               "in the review brief or in its own comment, then move the ticket to `In Review`."

    assert prompt =~ "  ## Supervisor check\n\n  **Verify:** <what must hold, and on which commit or build>"
    assert flat =~ "with no PR (the work is already on the default branch), the move to `In Review` is allowed once the block is posted"
    assert flat =~ "When a manual check could be an automated test, write the test instead of asking anyone to check by hand."

    # TP-612: work already on main becomes a decision or a supervisor check, never steps.
    assert flat =~ "hand over the call to close it as a decision, or the check that is left as a supervisor check; never as steps."

    # A request for a person is a decision with options.
    assert flat =~ "one question in `decision`, 2 to 4 options, each with what it does, one of them recommended. A request without options is refused."
    assert flat =~ "A check on a device is not a blocker for a person: it is a `## Supervisor check`"

    # The status map and the final verification send manual checks to In Review, not Human Review.
    assert flat =~ "or all that is left is a `## Supervisor check` an agent can't run; waiting on the supervisor or a human."
    assert flat =~ "It never holds a check to run: a check an agent can't run goes to `In Review` as a `## Supervisor check`."
    refute flat =~ "a final verification whose remaining checks are manual"
    assert flat =~ "still move it to `In Review`, never `Human Review`, with a `## Supervisor check` block for each"
    refute flat =~ "exact steps"
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
      assert body =~ "then execute end-to-end.\n\n" <> @plan_pipeline_tag <> ~s(\n\n{% render "review_brief" %})
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
        assert prompt =~ ~r/then execute end-to-end\.\n\n## Plan pipeline\n/
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

    assigns = %{"issue" => issue, "attempt" => nil, "agent" => %{"workpad_heading" => "## Symphony Workpad"}}
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
