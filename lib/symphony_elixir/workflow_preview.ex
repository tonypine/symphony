defmodule SymphonyElixir.WorkflowPreview do
  @moduledoc """
  Renders the assembled base-issue prompt for a `WORKFLOW.md` using deterministic
  synthetic sample data, so authors can preview exactly what the agent would
  receive without Linear access, network, or a running orchestrator.

  Reuses `SymphonyElixir.PromptBuilder.build_prompt/2` (the single source of prompt
  assembly) via its `:workflow` seam, so the preview never drifts from runtime.

  With `ledger.prompt_brief_enabled` on, the sample ticket carries a sample record and ledger,
  whose summary `SymphonyElixir.TicketEvents.Brief.build/2` renders, so the preview shows the
  ticket history summary agents get; no store is read.
  """

  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Workflow}
  alias SymphonyElixir.TicketEvents.{Brief, Event}

  @default_file "WORKFLOW.md"
  @default_agent_kind "codex"

  @type render_opts :: [file: String.t(), agent_kind: String.t(), repo_key: String.t()]

  @doc """
  Renders the base-issue prompt for the workflow at `:file` (default `WORKFLOW.md`).

  Pass `[]` to render the default file. `:repo_key` names the configured repo the preview is for,
  so the prompt renders with that repo's settings. Returns `{:ok, prompt}` or
  `{:error, human_readable_message}`.
  """
  @spec render(render_opts()) :: {:ok, String.t()} | {:error, String.t()}
  def render(opts) when is_list(opts) do
    file = Keyword.get(opts, :file, @default_file)
    agent_kind = Keyword.get(opts, :agent_kind, @default_agent_kind)
    repo_key = Keyword.get(opts, :repo_key)

    case Workflow.load(file) do
      {:ok, workflow} ->
        render_workflow(workflow, agent_kind, repo_key)

      {:error, reason} ->
        {:error, load_error_message(file, reason)}
    end
  end

  # `Workflow.load/1` reports a few distinct shapes; translate each into a
  # human-readable line since this is surfaced directly by the preview command.
  # `:file.format_error/1` turns the POSIX reason (`:enoent`, `:eacces`, ...) into
  # a readable string, so a missing file and a permission error read differently.
  defp load_error_message(file, {:missing_workflow_file, _path, posix}) do
    "Could not read workflow file `#{file}`: #{:file.format_error(posix)}"
  end

  defp load_error_message(file, {:workflow_parse_error, reason}) do
    "Could not parse front matter in `#{file}`: #{inspect(reason)}"
  end

  defp load_error_message(file, reason) do
    "Could not load workflow file `#{file}`: #{inspect(reason)}"
  end

  @doc "Deterministic synthetic issue used for previews."
  @spec sample_issue() :: Issue.t()
  def sample_issue do
    %Issue{
      id: "issue_sample_0001",
      identifier: "ABC-123",
      title: "Sample: improve the export pipeline",
      description: "As a user I want faster exports.\n\nAcceptance criteria:\n- Export under 2s.",
      priority: 2,
      state: "In Progress",
      branch_name: "abc-123-improve-export-pipeline",
      url: "https://linear.app/your-org/issue/ABC-123",
      repo_key: "your-repo",
      labels: ["enhancement"]
    }
  end

  @doc "The sample ticket's record, as the store would hold it."
  @spec sample_ticket_state() :: map()
  def sample_ticket_state do
    %{repo_key: "your-repo", issue_id: "issue_sample_0001", issue_identifier: "ABC-123", phase: "Rework"}
  end

  @doc """
  The sample ticket's ledger: three runs (implementation, a failed QA pass, the rework under way),
  twelve open findings across three classes, two decisions (one answered, one open) and three notes.
  Its ids and times are fixed, so it renders the same bytes every time.
  """
  @spec sample_ticket_events() :: [Event.t()]
  def sample_ticket_events do
    head = "4f1c2a9e7b3d5f60a1c8e2d4b6f8a0c3e5d7f9b1"
    implementation = {:agent, "run_sample_1", "implementation"}
    qa = {:agent, "run_sample_2", "qa"}
    rework = {:agent, "run_sample_3", "rework"}
    director = {:person, "Sam"}

    [
      {0, "phase.entered", %{to: "In Progress", from: "Todo"}, :machine},
      {1, "run.started", %{run_id: "run_sample_1", run_kind: "implementation", run_number: 1, state: "In Progress"}, :machine, "run_sample_1"},
      {20, "step.completed", %{title: "Profile the export query", mode: "orchestrated"}, implementation},
      {25, "note", %{text: "The export spends most of its time writing rows one by one; batching them is the plan."}, implementation},
      {90, "run.ended", %{run_id: "run_sample_1", run_kind: "implementation", run_number: 1, exit: "success", head: head}, :machine, "run_sample_1"},
      {91, "attempt.pushed", %{head: head, attempt: 1, intent: "handoff"}, :machine},
      {120, "verdict.recorded", %{kind: "code_review", outcome: "approve", head: head}, :machine},
      {125, "run.started", %{run_id: "run_sample_2", run_kind: "qa", run_number: 1, state: "QA", head: head}, :machine, "run_sample_2"}
    ]
    |> Kernel.++(sample_findings(qa))
    |> Kernel.++([
      {170, "decision.requested",
       %{
         title: "Large exports",
         question: "Should an export over 10,000 rows run in the background?",
         options: [%{label: "In the background", effect: "The export runs on its own and notifies the user."}, %{label: "Wait", effect: "The user waits."}]
       }, qa},
      {180, "run.ended", %{run_id: "run_sample_2", run_kind: "qa", run_number: 1, exit: "failed", head: head}, :machine, "run_sample_2"},
      {181, "verdict.recorded", %{kind: "qa", outcome: "fail", head: head}, :machine},
      {182, "phase.entered", %{to: "Rework", from: "QA"}, :machine},
      {240, "decision.recorded", %{answer: "In the background, with a notification when it is done.", request: "evt_sample_170"}, director},
      {245, "decision.requested", %{title: "CSV header", question: "Should the export keep its CSV header row?"}, :machine},
      {250, "note", %{text: "The export button stays where it is: users know it there."}, director},
      {255, "run.started", %{run_id: "run_sample_3", run_kind: "rework", run_number: 1, state: "Rework", head: head}, :machine, "run_sample_3"},
      {260, "step.started", %{title: "Fix the clipped export dialog at the laptop viewport", mode: "orchestrated"}, rework},
      {280, "evidence", %{caption: "The export dialog at 1440×900 after the fix", artifacts: ["art_sample_1"]}, rework, nil, ["art_sample_1"]},
      {285, "step.completed", %{title: "Fix the clipped export dialog at the laptop viewport", mode: "orchestrated"}, rework},
      {290, "note", %{text: "The truncated labels come from a fixed column width; the next step makes it flexible."}, rework}
    ])
    |> Enum.with_index(1)
    |> Enum.map(&sample_event/1)
  end

  # Five clipped, four truncated and three missing-state findings from the QA run.
  defp sample_findings(qa) do
    [
      {"clipped", "laptop 1440×900", "Open the export dialog", "The Export button is cut off at the dialog's bottom edge; no scroll reaches it."},
      {"clipped", "laptop 1440×900", "Pick the columns", "The column list's last three rows are hidden behind the footer."},
      {"clipped", "desktop 2560×1440", "Open the export dialog", "The dialog's right edge is cut off when the sidebar is open."},
      {"clipped", "laptop 1440×900", "Choose the format", "The format menu opens past the window's bottom edge."},
      {"clipped", "laptop 1440×900", "Review the summary", "The summary's totals row is hidden under the toolbar."},
      {"truncated", "laptop 1440×900", "Pick the columns", "Long column names end in an ellipsis with no way to read them."},
      {"truncated", "desktop 2560×1440", "Pick the columns", "The column type labels are cut to three letters."},
      {"truncated", "laptop 1440×900", "Review the summary", "The file name is truncated in the middle."},
      {"truncated", "laptop 1440×900", "Choose the format", "The format descriptions are cut to one line."},
      {"state missing", "laptop 1440×900", "Start the export", "No progress shows while the export runs."},
      {"state missing", "laptop 1440×900", "Start the export", "A failed export shows no error."},
      {"state missing", "desktop 2560×1440", "Open the export dialog", "The dialog shows no empty state when there are no rows."}
    ]
    |> Enum.with_index()
    |> Enum.map(fn {{class, viewport, step, description}, n} ->
      {130 + 3 * n, "finding.recorded", %{class: class, severity: "major", viewport: viewport, step: step, description: description}, qa}
    end)
  end

  defp sample_event({{minute, type, payload, actor}, seq}), do: sample_event({{minute, type, payload, actor, nil}, seq})
  defp sample_event({{minute, type, payload, actor, run_id}, seq}), do: sample_event({{minute, type, payload, actor, run_id, []}, seq})

  defp sample_event({{minute, type, payload, actor, run_id, artifacts}, seq}) do
    actor = Event.normalize_actor(actor)

    %Event{
      id: "evt_sample_#{minute}",
      seq: seq,
      repo_key: "your-repo",
      issue_id: "issue_sample_0001",
      at: DateTime.add(~U[2026-01-05 09:00:00Z], minute * 60),
      type: type,
      actor: actor,
      run_id: run_id || Map.get(actor, :run_id),
      payload: payload,
      artifacts: artifacts
    }
  end

  defp render_workflow(workflow, agent_kind, repo_key) do
    prompt =
      PromptBuilder.build_prompt(
        sample_issue(),
        [
          workflow: workflow,
          prompt_mode: :issue,
          agent_kind: agent_kind,
          repo_key: repo_key
        ] ++ sample_ledger_opts()
      )

    {:ok, prompt}
  rescue
    # PromptBuilder raises RuntimeError for template/partial failures; convert all
    # exceptions to {:error, message} so the preview can report them cleanly and
    # double as an author lint.
    error -> {:error, Exception.message(error)}
  end

  defp sample_ledger_opts do
    if Config.prompt_brief_enabled?() do
      state = sample_ticket_state()
      [ticket_state: state, ticket_ledger: Brief.build(state, sample_ticket_events())]
    else
      []
    end
  end
end
