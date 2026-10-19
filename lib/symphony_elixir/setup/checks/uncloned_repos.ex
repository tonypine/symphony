defmodule SymphonyElixir.Setup.Checks.UnclonedRepos do
  @moduledoc """
  A `workspace.source` repo Symphony has not cloned yet (H4), the warning `symphony check` gives
  (`Config.check_findings/1`): it has no `WORKFLOW.md` to read until Symphony clones it.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.Config
  alias SymphonyElixir.Setup.Problem

  @impl true
  def id, do: "uncloned_repo"

  @impl true
  def title, do: "Repos Symphony clones itself"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(%{system: nil}), do: []

  def run(%{system: system}) do
    for repo <- system.repos, Config.uncloned_managed_repo?(repo) do
      Problem.new(
        id: "#{id()}:#{repo.name}",
        severity: :warning,
        category: :runtime,
        title: "#{repo.name} is not cloned yet",
        consequence: "Symphony clones #{repo.workspace.github} into #{repo.path} when it starts, then reads its WORKFLOW.md. Until then no ticket for #{repo.name} can run.",
        repos: [repo.name],
        details: [Repo: repo.name, GitHub: repo.workspace.github, Clone: repo.path],
        fix: Problem.open(:repos)
      )
    end
  end
end
