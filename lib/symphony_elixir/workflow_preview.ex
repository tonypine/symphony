defmodule SymphonyElixir.WorkflowPreview do
  @moduledoc """
  Renders the assembled base-issue prompt for a `WORKFLOW.md` using deterministic
  synthetic sample data, so authors can preview exactly what the agent would
  receive without Linear access, network, or a running orchestrator.

  Reuses `SymphonyElixir.PromptBuilder.build_prompt/2` (the single source of prompt
  assembly) via its `:workflow` seam, so the preview never drifts from runtime.
  """

  alias SymphonyElixir.{Linear.Issue, PromptBuilder, Workflow}

  @default_file "WORKFLOW.md"
  @default_agent_kind "codex"

  @type render_opts :: [file: String.t(), agent_kind: String.t(), repo_key: String.t()]

  @doc """
  Renders the base-issue prompt for the workflow at `:file` (default `WORKFLOW.md`).

  Pass `[]` to render the default file. `:repo_key` names the configured repo the preview is for,
  so its resolved state-machine version selects the status map the prompt renders; omitted, the
  preview renders the default version. Returns `{:ok, prompt}` or `{:error, human_readable_message}`.
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

  defp render_workflow(workflow, agent_kind, repo_key) do
    prompt =
      PromptBuilder.build_prompt(sample_issue(),
        workflow: workflow,
        prompt_mode: :issue,
        agent_kind: agent_kind,
        repo_key: repo_key
      )

    {:ok, prompt}
  rescue
    # PromptBuilder raises RuntimeError for template/partial failures; convert all
    # exceptions to {:error, message} so the preview can report them cleanly and
    # double as an author lint.
    error -> {:error, Exception.message(error)}
  end
end
