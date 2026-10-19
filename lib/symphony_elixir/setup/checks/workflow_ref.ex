defmodule SymphonyElixir.Setup.Checks.WorkflowRef do
  @moduledoc """
  A repo's `WORKFLOW.md` read from origin (H1): an error when it fails to load from the repo's base
  ref (`WorkflowSource.ref_error/1`). Runs keep the last workflow that loaded.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.Repo.Status
  alias SymphonyElixir.Setup.Problem
  alias SymphonyElixir.WorkflowSource

  @impl true
  def id, do: "workflow_ref"

  @impl true
  def title, do: "Each repo's WORKFLOW.md on its base branch"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(%{system: nil}), do: []

  def run(%{system: system}) do
    for repo <- system.repos, reason <- [WorkflowSource.ref_error(repo)], reason != nil do
      Problem.new(
        id: "#{id()}:#{repo.name}",
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
end
