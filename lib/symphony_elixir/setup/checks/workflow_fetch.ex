defmodule SymphonyElixir.Setup.Checks.WorkflowFetch do
  @moduledoc """
  A repo whose fetch from origin keeps failing (H2): a warning once it failed three times in a row
  (`Repo.FetchLog`). Runs read the `WORKFLOW.md` and base branch the last good fetch brought.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.Repo.{FetchLog, Status}
  alias SymphonyElixir.Setup.Problem

  # Three fetches in a row: one failure is often the network blinking.
  @failing_fetches 3

  @impl true
  def id, do: "workflow_fetch"

  @impl true
  def title, do: "Each repo's fetch from origin"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(%{system: nil}), do: []

  def run(%{system: system}) do
    for repo <- system.repos,
        %{result: {:error, reason}, failures: failures, failing_since: since} <- [FetchLog.last(repo.name)],
        failures >= @failing_fetches do
      Problem.new(
        id: "#{id()}:#{repo.name}",
        severity: :warning,
        category: :runtime,
        title: "Fetching #{repo.name} from origin keeps failing",
        consequence: "Runs for #{repo.name} read the WORKFLOW.md and base branch of the last fetch that worked, so newer commits don't reach them.",
        repos: [repo.name],
        details: [Repo: repo.name, "Failed fetches in a row": failures, "Failing since": iso8601(since), "Last error": Status.fetch_error_message(reason)],
        fix: Problem.open(:repos)
      )
    end
  end

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
