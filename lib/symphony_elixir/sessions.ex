defmodule SymphonyElixir.Sessions do
  @moduledoc """
  Every live session, of any kind, in one list: the agent runs, each with its kind from the run
  profile. Landing runs are agent runs, so `finishing` adds none. `/api/v1/state`, the web
  dashboard, the terminal dashboard and the macOS app all read what runs from this list.
  """

  @type session :: %{
          kind: String.t(),
          issue_id: String.t(),
          issue_identifier: String.t() | nil,
          repo_key: String.t() | nil,
          started_at: DateTime.t() | nil
        }

  @doc "The sessions of the agent runs."
  @spec list([map()]) :: [session()]
  def list(running) do
    Enum.map(running, fn entry ->
      session(agent_kind(entry), entry.issue_id, entry.identifier, Map.get(entry, :repo_key), Map.get(entry, :started_at))
    end)
  end

  defp agent_kind(entry) do
    profile = Map.get(entry, :run_profile) || %{}
    to_string(Map.get(profile, :kind) || Map.get(entry, :run_kind) || :agent)
  end

  defp session(kind, issue_id, identifier, repo_key, started_at) do
    %{kind: kind, issue_id: issue_id, issue_identifier: identifier, repo_key: repo_key, started_at: started_at}
  end
end
