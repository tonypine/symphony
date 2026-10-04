defmodule SymphonyElixir.ForcedQueue do
  @moduledoc """
  The tickets a human has forced with `agent.concurrency.force_label` (default `expedite`), and
  when Symphony first saw each one.

  A ticket joins the queue the first time a poll sees it carry the label outside a terminal state.
  It keeps its `forced_since`, and so its place in the queue, until the label goes, the ticket
  reaches a terminal state, or Linear no longer returns it. The earliest `forced_since` is first.
  """

  alias SymphonyElixir.Linear.Issue

  @type entry :: %{
          identifier: String.t() | nil,
          title: String.t() | nil,
          state: String.t() | nil,
          repo_key: String.t() | nil,
          forced_since: DateTime.t()
        }

  @type entries :: %{optional(String.t()) => entry()}
  @type end_reason :: :label_removed | :terminal | :missing
  @type change :: {:start, String.t(), entry()} | {:end, String.t(), entry(), end_reason()}

  @doc """
  Brings `entries` up to date with the issues a poll observed. `gone_ids` are known forced issues a
  successful fetch by id did not return. A known issue the poll did not observe keeps its entry.
  Returns the new entries and the starts and ends, ordered by identifier.
  """
  @spec reconcile(entries(), [Issue.t()], [String.t()], SymphonyElixir.Config.Schema.t(), DateTime.t()) ::
          {entries(), [change()]}
  def reconcile(entries, issues, gone_ids, settings, %DateTime{} = now) when is_map(entries) and is_list(issues) do
    observed = for %Issue{id: id} = issue <- issues, is_binary(id), into: %{}, do: {id, issue}

    {kept, ended} =
      Enum.reduce(entries, {%{}, []}, fn {issue_id, entry}, {kept, ended} ->
        case known_entry(entry, Map.get(observed, issue_id), issue_id in gone_ids, settings) do
          {:keep, entry} -> {Map.put(kept, issue_id, entry), ended}
          {:end, reason} -> {kept, [{:end, issue_id, entry, reason} | ended]}
        end
      end)

    started =
      for {issue_id, issue} <- observed,
          not Map.has_key?(entries, issue_id),
          Issue.forced?(issue, settings),
          do: {:start, issue_id, issue |> issue_fields() |> Map.put(:forced_since, now)}

    entries = Enum.reduce(started, kept, fn {:start, issue_id, entry}, acc -> Map.put(acc, issue_id, entry) end)

    {entries, Enum.sort_by(ended ++ started, &change_identifier/1)}
  end

  @doc "The queue, earliest `forced_since` first, each entry with its 1-based `position`."
  @spec snapshot(entries() | nil) :: [map()]
  def snapshot(entries) when is_map(entries) do
    entries
    |> Enum.sort_by(fn {_issue_id, entry} -> {DateTime.to_unix(entry.forced_since, :microsecond), entry.identifier} end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{issue_id, entry}, position} ->
      entry
      |> Map.take([:identifier, :title, :state, :forced_since])
      |> Map.merge(%{issue_id: issue_id, position: position})
    end)
  end

  def snapshot(_entries), do: []

  defp known_entry(_entry, nil, true, _settings), do: {:end, :missing}
  defp known_entry(entry, nil, false, _settings), do: {:keep, entry}

  defp known_entry(entry, %Issue{} = issue, _gone?, settings) do
    cond do
      Issue.forced?(issue, settings) -> {:keep, Map.merge(entry, issue_fields(issue))}
      terminal?(issue, settings) -> {:end, :terminal}
      true -> {:end, :label_removed}
    end
  end

  defp terminal?(%Issue{state: state}, settings) when is_binary(state) do
    Enum.any?(settings.tracker.terminal_states, &(normalize(&1) == normalize(state)))
  end

  defp terminal?(_issue, _settings), do: false

  defp issue_fields(%Issue{} = issue) do
    %{identifier: issue.identifier, title: issue.title, state: issue.state, repo_key: issue.repo_key}
  end

  defp change_identifier({:start, _issue_id, entry}), do: entry.identifier || ""
  defp change_identifier({:end, _issue_id, entry, _reason}), do: entry.identifier || ""

  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
