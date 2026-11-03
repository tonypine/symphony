defmodule SymphonyElixir.Dispatch.Settle do
  @moduledoc """
  The settle of a new ticket's first dispatch, and the start window of a run.

  Linear sends a ticket's create and its blocked-by links as separate webhook deliveries, so the
  record Symphony files at the create may have no blockers yet, and a by-id read at that instant may
  miss them too. A ticket Linear created less than `SymphonyElixir.Config.dispatch_settle_ms/0` ago
  is therefore not dispatched at once: the orchestrator sets one timer for the end of the settle, and
  reads the ticket by id with its relations when it fires, or at the ticket's next record change
  (a webhook delivery), whichever comes first. The read is observed into the record and the
  ticket's dependency pause synced from it; the ticket is then settled, and the cycle that follows
  dispatches it only if it is still unblocked. No loop: one timer per new ticket, and a ticket with
  no `createdAt` or an older one dispatches as before.

  This module holds the orchestrator's settle map (`t:t/0`), keyed by issue id: a settling entry
  carries its timer, a settled one none. Settled entries are dropped once their ticket is past the
  settle (`prune/3`), so the map only holds tickets created in the last few seconds.

  A run is in its start window (`starting?/1`) from the dispatch decision until its agent session
  starts: a blocked-by link that reaches the record then stops the start.
  """

  alias SymphonyElixir.Linear.Issue

  @typedoc "A ticket's settle: its timer while it settles (nil once settled), its creation and repo."
  @type entry :: %{timer: reference() | nil, created_at: DateTime.t(), repo_key: String.t() | nil}

  @type t :: %{optional(String.t()) => entry()}

  @doc "An empty settle map."
  @spec new() :: t()
  def new, do: %{}

  @doc """
  True when `issue`'s first dispatch must wait: Linear created it less than `settle_ms` before `now`
  (or after `now`, a clock ahead of ours), and it is not settled yet.
  """
  @spec pending?(t(), Issue.t(), DateTime.t(), non_neg_integer()) :: boolean()
  def pending?(settle, %Issue{id: issue_id, created_at: created_at}, %DateTime{} = now, settle_ms) when is_map(settle) do
    fresh?(created_at, now, settle_ms) and not settled?(settle, issue_id)
  end

  def pending?(_settle, _issue, _now, _settle_ms), do: false

  @doc "True when `issue_id` has a settle under way (a timer set, no read yet)."
  @spec settling?(t(), String.t()) :: boolean()
  def settling?(settle, issue_id), do: match?(%{timer: timer} when is_reference(timer), Map.get(settle, issue_id))

  @doc """
  How long from `now` until `issue`'s settle ends: its creation plus `settle_ms`, never less than
  zero and never more than `settle_ms`.
  """
  @spec delay_ms(Issue.t(), DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def delay_ms(%Issue{created_at: %DateTime{} = created_at}, %DateTime{} = now, settle_ms) do
    (settle_ms - DateTime.diff(now, created_at, :millisecond)) |> max(0) |> min(settle_ms)
  end

  def delay_ms(_issue, _now, settle_ms), do: settle_ms

  @doc "Records that `issue` settles, with the `timer` that ends its settle and the repo it dispatches in."
  @spec start(t(), Issue.t(), reference(), String.t() | nil) :: t()
  def start(settle, %Issue{id: issue_id, created_at: %DateTime{} = created_at}, timer, repo_key) when is_reference(timer) do
    Map.put(settle, issue_id, %{timer: timer, created_at: created_at, repo_key: repo_key})
  end

  @doc """
  Ends `issue_id`'s settle: `{:settling, entry, settle}` with the entry it had (its timer to cancel)
  and the ticket now settled, or `:not_settling` when it has no settle under way.
  """
  @spec finish(t(), String.t()) :: {:settling, entry(), t()} | :not_settling
  def finish(settle, issue_id) do
    case Map.get(settle, issue_id) do
      %{timer: timer} = entry when is_reference(timer) -> {:settling, entry, Map.put(settle, issue_id, %{entry | timer: nil})}
      _settled_or_none -> :not_settling
    end
  end

  @doc "Drops the settled entries whose ticket is past the settle at `now`; a settling one stays."
  @spec prune(t(), DateTime.t(), non_neg_integer()) :: t()
  def prune(settle, %DateTime{} = now, settle_ms) do
    Map.filter(settle, fn {_issue_id, entry} -> is_reference(entry.timer) or fresh?(entry.created_at, now, settle_ms) end)
  end

  @doc """
  True when a running entry is still in its start window: dispatched, its agent session not started
  yet (no `session_id`).
  """
  @spec starting?(map() | nil) :: boolean()
  def starting?(%{} = running_entry), do: is_nil(Map.get(running_entry, :session_id))
  def starting?(_running_entry), do: false

  defp fresh?(%DateTime{} = created_at, now, settle_ms), do: settle_ms > 0 and DateTime.diff(now, created_at, :millisecond) < settle_ms
  defp fresh?(_created_at, _now, _settle_ms), do: false

  defp settled?(settle, issue_id), do: match?(%{timer: nil}, Map.get(settle, issue_id))
end
