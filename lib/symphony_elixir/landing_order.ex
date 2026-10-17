defmodule SymphonyElixir.LandingOrder do
  @moduledoc """
  The order in which tracked pull requests that change the same files land.

  When several open PRs edit the same files, each merge reopens a conflict on the others, and each
  of them then pays another conflict fix, another CI run and often another review. So the PR and
  CI watcher (`SymphonyElixir.PrWatch.Repo`) keeps an overlap map: on every tick it reads the
  repository's open PRs and the files each changes (`PullRequest.list_open_pull_requests/2`, one
  GraphQL query, so the files follow the head), and keeps the last files it read when that read
  fails. Two tracked PRs overlap when they share a file; the weight of the overlap is the number of
  files they share.

  Tracked PRs land in this order: a PR that conflicts with the base branch after the ones that
  don't (it can't land before a fix run, and that run would only conflict again once the others
  land), then the one furthest along first (`Merging`, then the QA state, then
  the Code Review state, then `Rework`, then any other state), then the one longest in its state
  (for `Merging` and QA, the oldest approval), then the lower PR number. A PR waits for the first
  PR in that order, above it, that shares a file with it (the fact `ahead`): the watcher sends it
  no conflict fix (rule R14a) and doesn't update its branch (R28) until that PR lands or stops
  sharing files with it. The next one then merges the base branch once, with all of the leader's
  changes. A PR keeps its place while its ticket sits in `CI Fix`: the state the stay returns to
  counts. A PR whose conflict came back after its fix runs steps behind every PR it then waits on
  (rule R15, `behind`): it ranks after each of them, so none of them waits for it.

  A group never deadlocks:

    * a PR on a hold (`Blocked`, `Needs Decision`) leads no one;
    * a PR whose state and head haven't moved for two hours leads no one, but waiting
      for its own leader counts as moving, so it doesn't lose its place the moment that one lands;
    * a forced ticket (the force label, `symphony force`) never waits.

  The watcher keeps the result under `:landing` on each ticket's record (`TicketState.pr_watch`);
  the state API lists the waits under `landing_waits`, and the agent's first prompt names the open
  PRs that share files with its own (`SymphonyElixir.PrWatch.open_pr_overlap/2`).
  """

  @idle_ms 2 * 60 * 60 * 1000
  @listed_files 10
  @merging_state "Merging"
  @rework_state "Rework"

  @typedoc "The PR a follower waits for, and the files the two share."
  @type wait :: %{
          issue_id: String.t(),
          issue_identifier: String.t() | nil,
          pr_url: String.t() | nil,
          state: String.t() | nil,
          shared_files: pos_integer(),
          files: [String.t()]
        }

  @typedoc "A tracked PR in the overlap map."
  @type member :: %{
          required(:issue_id) => String.t(),
          required(:files) => [String.t()],
          required(:rank) => integer(),
          required(:state_since) => DateTime.t(),
          required(:progress_at) => DateTime.t(),
          optional(:issue_identifier) => String.t() | nil,
          optional(:pr_url) => String.t() | nil,
          optional(:pr_number) => non_neg_integer() | nil,
          optional(:state) => String.t() | nil,
          optional(:held) => boolean(),
          optional(:conflicting) => boolean(),
          optional(:forced) => boolean(),
          optional(:behind) => [String.t()]
        }

  @doc """
  The PR each member waits for, by issue id; a member that waits for none is left out. Pure: the
  order and the safety rules are the moduledoc's.
  """
  @spec waits([member()], DateTime.t()) :: %{String.t() => wait()}
  def waits(members, %DateTime{} = now) do
    ranked = members |> Enum.sort_by(&order_key/1) |> Enum.with_index()

    Enum.reduce(ranked, %{}, fn {member, index}, acc ->
      above =
        for {other, other_index} <- ranked,
            other.issue_id != member.issue_id,
            ahead_of?({other, other_index}, {member, index}),
            do: other

      case wait_for(member, above, now) do
        nil -> acc
        wait -> Map.put(acc, member.issue_id, wait)
      end
    end)
  end

  # A member that stepped behind another ranks after it, whatever the order says.
  defp ahead_of?({other, other_index}, {member, index}) do
    cond do
      stepped_behind?(member, other) -> true
      stepped_behind?(other, member) -> false
      true -> other_index < index
    end
  end

  defp stepped_behind?(member, other), do: other.issue_id in (Map.get(member, :behind) || [])

  @doc "How a wait reads: `waits for TP-1 to land (shares 3 files)`."
  @spec reason(wait()) :: String.t()
  def reason(%{shared_files: count} = wait) do
    "waits for #{wait_name(wait)} to land (shares #{count} #{if count == 1, do: "file", else: "files"})"
  end

  @doc "The files of `files` that `other` changes too, in `files`' order."
  @spec shared_files([String.t()], [String.t()]) :: [String.t()]
  def shared_files(files, other) do
    other = MapSet.new(other)
    Enum.filter(files, &MapSet.member?(other, &1))
  end

  @doc "How far along a ticket in `state` is: the higher, the sooner its PR lands."
  @spec rank(String.t() | nil, map()) :: integer()
  def rank(state, settings) when is_binary(state) do
    tracker = Map.get(settings, :tracker) || %{}

    cond do
      same_state?(state, @merging_state) -> 5
      same_state?(state, Map.get(tracker, :qa_state) || "QA") -> 4
      same_state?(state, Map.get(tracker, :code_review_state) || "Code Review") -> 3
      same_state?(state, @rework_state) -> 2
      true -> 1
    end
  end

  def rank(_state, _settings), do: 0

  defp wait_for(%{forced: true}, _above, _now), do: nil

  defp wait_for(member, above, now) do
    Enum.find_value(above, fn leader ->
      with true <- leads?(leader, now),
           [_ | _] = shared <- shared_files(member.files, leader.files) do
        %{
          issue_id: leader.issue_id,
          issue_identifier: Map.get(leader, :issue_identifier),
          pr_url: Map.get(leader, :pr_url),
          state: Map.get(leader, :state),
          shared_files: length(shared),
          files: Enum.take(shared, @listed_files)
        }
      else
        _no -> nil
      end
    end)
  end

  @doc "How long a PR whose state and head haven't moved leads no one: two hours."
  @spec idle_ms() :: pos_integer()
  def idle_ms, do: @idle_ms

  @doc "Whether `member` is in the race: not on a hold, and its state or head moved within `idle_ms/0`."
  @spec leads?(member(), DateTime.t()) :: boolean()
  def leads?(member, %DateTime{} = now), do: Map.get(member, :held) != true and DateTime.diff(now, member.progress_at, :millisecond) < @idle_ms

  defp order_key(member) do
    {if(Map.get(member, :conflicting) == true, do: 1, else: 0), -member.rank, DateTime.to_unix(member.state_since, :microsecond), Map.get(member, :pr_number) || :infinity,
     Map.get(member, :issue_identifier) || member.issue_id}
  end

  defp wait_name(wait), do: Map.get(wait, :issue_identifier) || Map.get(wait, :pr_url) || wait.issue_id

  defp same_state?(left, right) when is_binary(right), do: normalize(left) == normalize(right)

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
