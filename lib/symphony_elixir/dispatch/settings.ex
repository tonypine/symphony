defmodule SymphonyElixir.Dispatch.Settings do
  @moduledoc """
  The settings a dispatch cycle reads, as one comparable value: the dispatch source, the configured
  repositories and, for each, what makes a ticket a candidate (the tracker's active and terminal
  states, its labels and assignee, `tickets.priorities`) and how many may run (the agent slot limits
  and token budgets).

  The orchestrator keeps the value it last read and compares it after each config reload
  (`SymphonyElixir.Config.Cache.reloaded_event/0`): a change that may free a ticket runs a dispatch
  cycle at once, and a reload that leaves these settings as they were runs none.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

  @agent_fields [
    :max_concurrent_agents,
    :max_concurrent_agents_by_state,
    :epic_lanes,
    :finishing_max,
    :force_label,
    :forced_max,
    :max_tokens_per_issue,
    :max_tokens_per_day
  ]

  @tracker_fields [:active_states, :terminal_states, :labels, :assignee, :team, :project_slug]

  @type t :: term()

  @doc "The dispatch settings of every configured repository, read from the config cache."
  @spec read() :: t()
  def read do
    {Config.dispatch_source(), Map.new(repo_keys(), &{&1, repo_settings(&1)})}
  end

  defp repo_keys do
    case Config.repos() do
      {:ok, [_ | _] = repos} -> Enum.map(repos, & &1.name)
      _none -> [nil]
    end
  end

  defp repo_settings(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, %Schema{} = settings} ->
        %{
          agent: Map.take(settings.agent, @agent_fields),
          tracker: Map.take(settings.tracker, @tracker_fields),
          priorities: settings.tickets.priorities
        }

      {:error, reason} ->
        {:error, reason}
    end
  end
end
