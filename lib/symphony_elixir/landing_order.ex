defmodule SymphonyElixir.LandingOrder do
  @moduledoc """
  The order in which tracked pull requests that change the same files land.

  When several open PRs edit the same files, each merge reopens a conflict on the others, and each
  of them then pays another conflict fix, another CI run and often another review. So the PR
  review poller keeps an overlap map: on every poll it reads the repository's open PRs and the
  files each changes (`PullRequest.list_open_pull_requests/2`, one GraphQL query, so the files
  follow the head), and keeps the last files it read when that read fails. Two tracked PRs overlap
  when they share a file; the weight of the overlap is the number of files they share.

  Tracked PRs land in this order: the one furthest along first (`Merging`, then the QA state, then
  the Code Review state, then `Rework`, then any other state), then the one longest in its state
  (for `Merging` and QA, the oldest approval), then the lower PR number. A PR waits for the first
  PR in that order, above it, that shares a file with it: the poller sends it no conflict fix and
  auto-merge doesn't update its branch until that PR lands or stops sharing files with it. The
  next one then merges the base branch once, with all of the leader's changes. A PR keeps its
  place while its ticket sits where the poller doesn't read it (`CI Fix`, say): the state it was
  last read in counts.

  A group never deadlocks:

    * a PR on a hold (`Blocked`, `Needs Decision`) leads no one;
    * a PR whose state and head haven't moved for two hours leads no one, but waiting
      for its own leader counts as moving, so it doesn't lose its place the moment that one lands;
    * a forced ticket (the force label, `symphony force`) never waits.

  The poller keeps the result under `:landing` in each PR review record (see `t:landing/0`); the
  state API lists the waits under `landing_waits`, and the agent's first prompt names the open PRs
  that share files with its own.
  """

  require Logger

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Hold
  alias SymphonyElixir.Linear.Issue

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

  @typedoc """
  What the poller keeps for a tracked PR: the files it changes at `head_sha`, the state it was last
  read in and since when, when its state or head last moved, and the PR it waits for.
  """
  @type landing :: %{
          files: [String.t()],
          head_sha: String.t() | nil,
          state: String.t() | nil,
          state_since: DateTime.t(),
          progress_at: DateTime.t(),
          waits_for: wait() | nil,
          waits_since: DateTime.t() | nil
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
          optional(:forced) => boolean()
        }

  @doc """
  The landing of every PR review record in `reviews`, in the same order: `{record, landing}`, with
  nil for a record whose PR is not in the overlap map (no PR, a PR no longer open, or the map is off
  because `opts[:github]` can't list open PRs or fewer than two records have a PR). `issues` are the
  issues this poll read, for the state, the force label and the repo of each record.
  """
  @spec refresh([map()], [Issue.t()], map(), keyword(), DateTime.t()) :: [{map(), landing() | nil}]
  def refresh(reviews, issues, settings, opts, %DateTime{} = now) do
    issues_by_id = Map.new(issues, &{&1.id, &1})
    pulls = open_pull_requests(reviews, opts)

    candidates = Enum.map(reviews, &{&1, candidate(&1, pulls, issues_by_id, settings, opts, now)})
    waits = candidates |> Enum.flat_map(fn {_record, member} -> List.wrap(member) end) |> waits(now)

    Enum.map(candidates, fn
      {record, nil} -> {record, nil}
      {record, member} -> {record, landing(record, member, Map.get(waits, member.issue_id), now)}
    end)
  end

  @doc """
  The PR each member waits for, by issue id; a member that waits for none is left out. Pure: the
  order and the safety rules are the moduledoc's.
  """
  @spec waits([member()], DateTime.t()) :: %{String.t() => wait()}
  def waits(members, %DateTime{} = now) do
    ranked = Enum.sort_by(members, &order_key/1)

    ranked
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {member, index}, acc ->
      case wait_for(member, Enum.take(ranked, index), now) do
        nil -> acc
        wait -> Map.put(acc, member.issue_id, wait)
      end
    end)
  end

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

  defp leads?(leader, now), do: Map.get(leader, :held) != true and DateTime.diff(now, leader.progress_at, :millisecond) < @idle_ms

  defp order_key(member) do
    {-member.rank, DateTime.to_unix(member.state_since, :microsecond), Map.get(member, :pr_number) || :infinity, Map.get(member, :issue_identifier) || member.issue_id}
  end

  defp wait_name(wait), do: Map.get(wait, :issue_identifier) || Map.get(wait, :pr_url) || wait.issue_id

  # Open PRs by number, `:stale` when the read failed (each record keeps the files it last had), or
  # `:off` when there is nothing to order.
  defp open_pull_requests(reviews, opts) do
    github = Keyword.get(opts, :github, PullRequest)

    case Enum.filter(reviews, &is_integer(pr_number(Map.get(&1, :pr_url)))) do
      [first, _second | _rest] ->
        if Code.ensure_loaded?(github) and function_exported?(github, :list_open_pull_requests, 2),
          do: read_open_pull_requests(github, first),
          else: :off

      _fewer ->
        :off
    end
  end

  defp read_open_pull_requests(github, record) do
    case github.list_open_pull_requests(Map.get(record, :pr_url), cwd: Map.get(record, :workspace_path)) do
      {:ok, pulls} ->
        {:ok, for(%{number: number} = pull when is_integer(number) <- pulls, into: %{}, do: {number, pull})}

      {:error, reason} ->
        Logger.warning("Landing order: reading the open pull requests failed; keeping the files last read: #{inspect(reason)}")
        :stale
    end
  end

  defp candidate(_record, :off, _issues_by_id, _settings, _opts, _now), do: nil

  defp candidate(record, pulls, issues_by_id, settings, opts, now) do
    previous = previous_landing(record)

    with {files, head_sha} <- files_and_head(record, previous, pulls) do
      issue = Map.get(issues_by_id, Map.get(record, :issue_id))
      state = issue_state(issue) || Map.get(previous || %{}, :state)
      same_state? = previous != nil and previous.state == state
      moved? = not same_state? or previous.head_sha != head_sha

      %{
        issue_id: Map.get(record, :issue_id),
        issue_identifier: Map.get(record, :issue_identifier),
        pr_url: Map.get(record, :pr_url),
        pr_number: pr_number(Map.get(record, :pr_url)),
        state: state,
        head_sha: head_sha,
        files: files,
        rank: rank(state, settings),
        state_since: if(same_state?, do: previous.state_since, else: now),
        progress_at: if(moved?, do: now, else: previous.progress_at),
        held: held?(record, issue, opts),
        forced: issue != nil and Issue.forced?(issue, settings)
      }
    end
  end

  defp files_and_head(record, _previous, {:ok, pulls}) do
    case Map.get(pulls, pr_number(Map.get(record, :pr_url))) do
      %{files: files} = pull when is_list(files) -> {files, Map.get(pull, :head_sha)}
      _not_open -> nil
    end
  end

  defp files_and_head(_record, %{files: files} = previous, :stale), do: {files, previous.head_sha}
  defp files_and_head(_record, _previous, :stale), do: nil

  defp landing(record, member, wait, now) do
    previous = previous_landing(record)
    same_wait? = wait != nil and match?(%{waits_for: %{issue_id: id}} when id == wait.issue_id, previous)

    %{
      files: member.files,
      head_sha: member.head_sha,
      state: member.state,
      state_since: member.state_since,
      # Waiting for its own leader is not idling: it must not lose its place when that one lands.
      progress_at: if(wait, do: now, else: member.progress_at),
      waits_for: wait,
      waits_since: if(same_wait?, do: previous.waits_since, else: wait && now)
    }
  end

  defp previous_landing(record) do
    case Map.get(record, :landing) do
      %{files: files, state_since: %DateTime{}, progress_at: %DateTime{}} = landing when is_list(files) -> landing
      _none -> nil
    end
  end

  defp held?(record, issue, opts) do
    repo_key = Map.get(record, :repo_key) || Keyword.get(opts, :repo_key) || (issue && issue.repo_key)
    is_binary(repo_key) and Hold.held_any?(repo_key, Map.get(record, :issue_id))
  end

  defp issue_state(%Issue{state: state}) when is_binary(state), do: state
  defp issue_state(_issue), do: nil

  defp pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_match, number] -> String.to_integer(number)
      nil -> nil
    end
  end

  defp pr_number(_url), do: nil

  defp same_state?(left, right) when is_binary(right), do: normalize(left) == normalize(right)

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
