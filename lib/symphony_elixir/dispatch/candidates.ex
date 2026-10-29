defmodule SymphonyElixir.Dispatch.Candidates do
  @moduledoc """
  The dispatch candidates of one repo computed from its ticket records (`SymphonyElixir.TicketState`)
  instead of the poll cache: the same filter the cache path's issues go through before the gates
  (assigned to the worker, in an active state, not terminal), over issues rebuilt from what the
  records observed of Linear (`SymphonyElixir.TicketObservation`).

  A record that was never observed (no `linear_updated_at`) is left out, so a half-populated store
  cannot dispatch from guesswork, and so is one a webhook said was removed. Every record left out is
  counted under the reason it was left out, so the counts explain each ticket missing from the
  candidates.

  The rebuilt issue carries the record's priority, labels, open blockers and sub-issues (each with its
  id and state), parent and creation time, so the dispatch gates (`Issue.blocked?/2`, a plan parent's
  wait on its sub-tickets, the priority filter, a forced ticket's label), the epic lanes
  (`SymphonyElixir.EpicLanes.plan/4`) and the dispatch order (priority, then age) read it as they read
  a polled issue: the priority filter stays a gate because a forced ticket and a retry waiting for a
  slot bypass it.

  Everything here is pure: no store read, no Linear read, no process. Nothing calls it yet.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{Orchestrator, TicketState}

  @typedoc "How many records each reason left out."
  @type excluded :: %{
          removed: non_neg_integer(),
          unobserved: non_neg_integer(),
          incomplete: non_neg_integer(),
          unassigned: non_neg_integer(),
          terminal: non_neg_integer(),
          inactive: non_neg_integer()
        }

  @type result :: %{candidates: [Issue.t()], excluded: excluded()}

  @doc """
  The candidates among `records` (the repo's ticket records) for `repo_key` under `settings` (the
  repo's `SymphonyElixir.Config.Schema`), sorted by identifier as the cache path's buckets are, and how
  many records each reason left out:

  - `removed`: a webhook said the ticket was removed (`removed_at`);
  - `unobserved`: no read of Linear observed it (`linear_updated_at` is nil);
  - `incomplete`: it has no identifier, title or state, which a polled issue needs to be a candidate;
  - `unassigned`: its assignee is not the worker's;
  - `terminal`: its state is one of the terminal states;
  - `inactive`: its state is not one of the active states.

  A record is counted under the first reason, in that order, that leaves it out. `opts`:

  - `:route` — the repo's route as the poll reads it (`SymphonyElixir.Config.SystemSchema.Repo`). Its
    `assignee`, when set, names the worker instead of `tracker.assignee`, as the poll's assignee
    filter does (`SymphonyElixir.Linear.Client.repo_scope_filter/1`). Without it, the tracker's counts.
  - `:assignee_ids` — the ids that count as the worker, or nil when any assignee does. It defaults to
    the configured assignee (the route's, else the tracker's): none means any assignee, an id means
    that one. `me` names the API key's user, whose id only Linear knows, so the caller passes it;
    without it no record counts as assigned.
  """
  @spec from_records(String.t(), [map()], Schema.t(), keyword()) :: result()
  def from_records(repo_key, records, %Schema{} = settings, opts \\ []) when is_binary(repo_key) and is_list(records) do
    filter = %{
      assignee_ids: assignee_ids(settings, opts),
      active: Orchestrator.active_state_set(settings),
      terminal: Orchestrator.terminal_state_set(settings)
    }

    {candidates, excluded} =
      Enum.reduce(records, {[], empty_excluded()}, fn record, {candidates, excluded} ->
        record = TicketState.normalize(record)

        case exclusion(record, filter) do
          nil -> {[%{issue_from_record(record) | repo_key: repo_key} | candidates], excluded}
          reason -> {candidates, Map.update!(excluded, reason, &(&1 + 1))}
        end
      end)

    %{candidates: Enum.sort_by(candidates, &{&1.identifier, &1.id}), excluded: excluded}
  end

  @doc """
  The `SymphonyElixir.Linear.Issue` a ticket record describes: its id, identifier, title, state (the
  record's `phase`), labels, priority, assignee, blockers, sub-issues, parent, URL, repo, creation time
  and Linear's `updatedAt`. The record keeps only the blockers that were open when it was observed; one
  a record read before blockers kept their state has no known state, which `Issue.blocked?/2` counts
  as open.
  """
  @spec issue_from_record(map()) :: Issue.t()
  def issue_from_record(record) when is_map(record) do
    record = TicketState.normalize(record)

    %Issue{
      id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      state: record.phase,
      labels: record.labels,
      priority: record.priority,
      assignee_id: record.assignee,
      blocked_by: record.blockers,
      sub_issues: record.sub_issues,
      parent: record.parent,
      url: record.url,
      repo_key: record.repo_key,
      created_at: record.created_at,
      updated_at: record.linear_updated_at
    }
  end

  defp exclusion(record, filter) do
    cond do
      record.removed_at != nil -> :removed
      record.linear_updated_at == nil -> :unobserved
      Enum.any?([record.issue_id, record.issue_identifier, record.title, record.phase], &is_nil/1) -> :incomplete
      not assigned?(record.assignee, filter.assignee_ids) -> :unassigned
      MapSet.member?(filter.terminal, normalize_state(record.phase)) -> :terminal
      not MapSet.member?(filter.active, normalize_state(record.phase)) -> :inactive
      true -> nil
    end
  end

  defp assigned?(_assignee, nil), do: true
  defp assigned?(assignee, assignee_ids), do: is_binary(assignee) and assignee in assignee_ids

  defp assignee_ids(settings, opts) do
    case Keyword.fetch(opts, :assignee_ids) do
      {:ok, nil} -> nil
      {:ok, ids} -> Enum.to_list(ids)
      :error -> configured_assignee_ids(route_assignee(Keyword.get(opts, :route)) || settings.tracker.assignee)
    end
  end

  defp route_assignee(%{assignee: assignee}), do: assignee
  defp route_assignee(_route), do: nil

  defp configured_assignee_ids(assignee) when is_binary(assignee) do
    case String.trim(assignee) do
      "" -> nil
      "me" -> []
      id -> [id]
    end
  end

  defp configured_assignee_ids(_assignee), do: nil

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  defp empty_excluded, do: %{removed: 0, unobserved: 0, incomplete: 0, unassigned: 0, terminal: 0, inactive: 0}
end
