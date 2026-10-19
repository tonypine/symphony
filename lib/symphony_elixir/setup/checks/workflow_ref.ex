defmodule SymphonyElixir.Setup.Checks.WorkflowRef do
  @moduledoc """
  A repo's `WORKFLOW.md` read from origin (H1, H2). An error when it fails to load from the repo's
  base ref (`WorkflowSource.ref_error/1`): runs keep the last workflow that loaded. A warning when
  the fetch of the repo keeps failing: runs read what the last good fetch brought.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.{Repo.FetchLog, WorkflowSource}
  alias SymphonyElixir.Repo.Status
  alias SymphonyElixir.Setup.Problem

  # Three fetches in a row: one failure is often the network blinking.
  @failing_fetches 3

  @impl true
  def id, do: "workflow"

  @impl true
  def title, do: "Each repo's WORKFLOW.md on origin"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(%{system: nil}), do: []

  def run(%{system: system}) do
    Enum.flat_map(system.repos, fn repo -> List.wrap(ref_problem(repo)) ++ List.wrap(fetch_problem(repo)) end)
  end

  defp ref_problem(repo) do
    case WorkflowSource.ref_error(repo) do
      nil ->
        nil

      reason ->
        Problem.new(
          id: "workflow_ref:#{repo.name}",
          severity: :error,
          category: :runtime,
          title: "WORKFLOW.md of #{repo.name} doesn't load from its base branch",
          consequence: "Runs for #{repo.name} use the last WORKFLOW.md that loaded, so changes merged since then don't reach them.",
          repos: [repo.name],
          details: [Repo: repo.name, Reason: Status.ref_error_message(reason)],
          fix: Problem.open(:repos)
        )
    end
  end

  defp fetch_problem(repo) do
    case FetchLog.last(repo.name) do
      %{result: {:error, reason}, failures: failures, failing_since: since} when failures >= @failing_fetches ->
        Problem.new(
          id: "workflow_fetch:#{repo.name}",
          severity: :warning,
          category: :runtime,
          title: "Fetching #{repo.name} from origin keeps failing",
          consequence: "Runs for #{repo.name} read the WORKFLOW.md and base branch of the last fetch that worked, so newer commits don't reach them.",
          repos: [repo.name],
          details: [Repo: repo.name, "Failed fetches in a row": failures, "Failing since": iso8601(since), "Last error": Status.fetch_error_message(reason)],
          fix: Problem.open(:repos)
        )

      _working_or_unknown ->
        nil
    end
  end

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
