defmodule SymphonyElixir.PrWatch do
  @moduledoc """
  The PR and CI watcher (`docs/pr-ci-decisions.md`): one `SymphonyElixir.PrWatch.Repo` per
  repository that polls its pull requests (`pull_requests` polling on), each gathering the facts of
  its watched tickets' PRs into their state records (`TicketState.pr_watch`).

  For now it only gathers facts: `SymphonyElixir.PrDecision.decide/1` is not called and nothing is
  applied, so the CI and PR review pollers still decide and act. The state API shows the facts under
  each watched issue's `watch.facts`.
  """

  use Supervisor

  alias SymphonyElixir.PrWatch.Repo

  @doc """
  Starts a watcher for each repository in `opts[:repo_keys]`. The other `opts` go to each
  `SymphonyElixir.PrWatch.Repo`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    repo_opts = Keyword.drop(opts, [:name, :repo_keys])

    opts
    |> Keyword.fetch!(:repo_keys)
    |> Enum.map(&{Repo, Keyword.put(repo_opts, :repo_key, &1)})
    |> Supervisor.init(strategy: :one_for_one)
  end
end
