defmodule SymphonyElixir.AcceptanceGate.Agreement do
  @moduledoc """
  Measures how often the acceptance gate agrees with the human who reviews the PR after it, so an
  operator can tell when a repository is ready for `enforce`. See `docs/acceptance_gate.md`.

  A gate verdict is stored on its gate run (`kind: "acceptance_gate"`). When the issue leaves
  In Review, `observe/5` records the human's decision on that run:

    * a move to Merging (or straight to Done) is `approve`;
    * a move to Rework, or back to In Progress with PR review comments (the PR review poller's
      `rework` action after the verdict, for a change request or a review comment), is `rework`;
    * In Review, Auto Review, Human Review and In Progress without review comments are still
      waiting;
    * any other state is `none`: no decision, and the verdict doesn't count.

  A verdict the gate applied itself in `enforce` mode (the run's `moved_by_gate`: Merging, or back
  to In Progress) has no human decision to record: Symphony's own move is never read as one.

  An `approve` or `rework` writes one `acceptance_gate_agreement` audit event. `stats/1` sums the
  last 50 decisions of a repository and `ready_to_enforce/1` checks them against the threshold.
  """

  require Logger

  alias SymphonyElixir.AcceptanceGate.Runner
  alias SymphonyElixir.{AuditLog, RunStore, Tracker}
  alias SymphonyElixir.Linear.Issue

  @window 50
  @recent_limit 20
  @min_judged 20
  @review_actions ["rework"]
  @waiting_states ["In Review", "Auto Review", "Human Review"]

  @type stats :: %{
          judged: non_neg_integer(),
          agreed: non_neg_integer(),
          agreement_rate: float() | nil,
          unsafe_approvals: non_neg_integer(),
          false_reworks: non_neg_integer(),
          escalations: non_neg_integer(),
          escalations_merged_unchanged: non_neg_integer(),
          tokens: %{median: non_neg_integer() | nil, p90: non_neg_integer() | nil},
          ready_to_enforce: boolean(),
          unmet_condition: String.t() | nil
        }

  @doc "The gate runs in `runs` that ended with a verdict, newest verdict first."
  @spec verdicts([map()]) :: [map()]
  def verdicts(runs) do
    runs
    |> Enum.filter(&(Map.get(&1, :kind) == "acceptance_gate" and is_binary(Map.get(&1, :verdict))))
    |> Enum.sort_by(&sort_key(Map.get(&1, :judged_at)), :desc)
  end

  @doc "The latest verdict of each issue in `runs`, newest first."
  @spec latest_per_issue([map()]) :: [map()]
  def latest_per_issue(runs), do: runs |> verdicts() |> Enum.uniq_by(&Map.get(&1, :issue_id))

  @doc """
  The human's decision on a gate verdict, from the issue's current Linear `state` and its PR
  review record: `"approve"`, `"rework"`, `"none"`, or nil while it is still waiting in one of
  `waiting_states` (the states a person reviews in) or back in progress without review comments
  (also when the state is unknown).
  """
  @spec human_decision(map(), String.t() | nil, map() | nil, [String.t()]) :: String.t() | nil
  def human_decision(gate_run, state, pr_review, waiting_states) do
    case normalize(state) do
      "" -> nil
      "merging" -> "approve"
      "done" -> "approve"
      "rework" -> "rework"
      "in progress" -> if review_since?(pr_review, Map.get(gate_run, :judged_at)), do: "rework"
      state -> if state in Enum.map(waiting_states, &normalize/1), do: nil, else: "none"
    end
  end

  defp review_since?(%{last_action: action, last_action_at: %DateTime{} = at}, %DateTime{} = judged_at) when action in @review_actions,
    do: DateTime.compare(at, judged_at) != :lt

  defp review_since?(_pr_review, _judged_at), do: false

  @doc """
  Records the human's decision on each issue's latest undecided verdict in `runs` (the
  repository's runs, or `undecided/2`). `issues` are the issues the CI poller watches this cycle;
  the state of any other issue is read from the tracker. `ci_checks` give the PR head the human
  decided on.

  Options: `:run_store`, `:tracker`, `:waiting_states` (default In Review, Auto Review and Human
  Review), `:now`, `:audit_dir`. Returns `{issue_id, decision}` for each decision recorded.
  """
  @spec observe(String.t(), [Issue.t()], [map()], [map()], keyword()) :: [{String.t(), String.t()}]
  def observe(repo_key, issues, runs, ci_checks, opts) do
    case undecided_latest(runs) do
      [] -> []
      pending -> decide_pending(repo_key, pending, issues, ci_checks, opts)
    end
  end

  @doc """
  The latest verdict of each issue of repository `repo_key` still waiting for a human decision,
  the runs `observe/5` decides on. It is kept until a gate run is written, so the CI poller reads
  it every cycle without scanning the run store. Options: `:run_store`.
  """
  @spec undecided(String.t(), keyword()) :: [map()]
  def undecided(repo_key, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    case memoize(run_store, {:undecided, repo_key}, fn -> undecided_runs(run_store, repo_key) end) do
      {:ok, runs} -> runs
      {:error, _reason} -> []
    end
  end

  defp undecided_runs(run_store, repo_key) do
    with {:ok, runs} <- memoize(run_store, :verdicts, fn -> verdict_runs(run_store) end) do
      {:ok, runs |> Enum.filter(&(Map.get(&1, :repo_key) == repo_key)) |> undecided_latest()}
    end
  end

  defp undecided_latest(runs),
    do: runs |> latest_per_issue() |> Enum.filter(&(is_nil(Map.get(&1, :human_decision)) and is_nil(Map.get(&1, :moved_by_gate))))

  defp decide_pending(repo_key, pending, issues, ci_checks, opts) do
    states = issue_states(pending, issues, Keyword.get(opts, :tracker, Tracker))
    run_store = Keyword.get(opts, :run_store, RunStore)
    pr_reviews = pr_reviews(run_store, repo_key, pending, states)
    waiting_states = Keyword.get(opts, :waiting_states, @waiting_states)

    Enum.flat_map(pending, fn gate_run ->
      issue_id = Map.get(gate_run, :issue_id)
      state = Map.get(states, issue_id)

      case human_decision(gate_run, state, Map.get(pr_reviews, issue_id), waiting_states) do
        nil -> []
        decision -> record(repo_key, gate_run, decision, state, ci_check(ci_checks, issue_id), run_store, opts)
      end
    end)
  end

  defp issue_states(pending, issues, tracker) do
    watched = for %Issue{id: id, state: state} <- issues, into: %{}, do: {id, state}

    case pending |> Enum.map(&Map.get(&1, :issue_id)) |> Enum.reject(&Map.has_key?(watched, &1)) do
      [] -> watched
      ids -> Map.merge(watched, fetch_states(tracker, ids))
    end
  end

  defp fetch_states(tracker, ids) do
    case tracker.fetch_issue_states_by_ids(ids) do
      {:ok, fetched} ->
        for %Issue{id: id, state: state} <- fetched, into: %{}, do: {id, state}

      {:error, reason} ->
        Logger.warning("Acceptance gate agreement could not read issue states: #{inspect(reason)}")
        %{}
    end
  end

  # PR review records only matter for an issue back in In Progress.
  defp pr_reviews(run_store, repo_key, pending, states) do
    if Enum.any?(pending, &(normalize(Map.get(states, Map.get(&1, :issue_id))) == "in progress")) do
      case run_store.list_pr_reviews(repo_key) do
        reviews when is_list(reviews) -> Map.new(reviews, &{Map.get(&1, :issue_id), &1})
        {:error, _reason} -> %{}
      end
    else
      %{}
    end
  end

  defp ci_check(ci_checks, issue_id), do: Enum.find(ci_checks, &(Map.get(&1, :issue_id) == issue_id)) || %{}

  defp record(repo_key, gate_run, decision, state, ci_check, run_store, opts) do
    head_sha = Map.get(gate_run, :head_sha)
    decision_sha = Map.get(ci_check, :last_observed_sha) || head_sha
    verdict = Map.get(gate_run, :verdict)

    attrs = %{
      human_decision: decision,
      human_decision_state: state,
      human_decision_sha: decision_sha,
      human_decided_at: Keyword.get(opts, :now, DateTime.utc_now()),
      unchanged: decision_sha == head_sha,
      agreed: if(decision != "none" and verdict != "escalate", do: verdict == decision)
    }

    case run_store.update_run(repo_key, Map.get(gate_run, :run_id), attrs) do
      :ok ->
        if decision != "none", do: audit(repo_key, Map.merge(gate_run, attrs), opts)
        [{Map.get(gate_run, :issue_id), decision}]

      {:error, reason} ->
        Logger.warning("Failed to store the human decision on the acceptance gate run run_id=#{Map.get(gate_run, :run_id)}: #{inspect(reason)}")
        []
    end
  end

  defp audit(repo_key, gate_run, opts) do
    event = %{
      event_type: "acceptance_gate_agreement",
      repo_key: repo_key,
      issue_id: Map.get(gate_run, :issue_id),
      issue_identifier: Map.get(gate_run, :issue_identifier),
      run_id: Map.get(gate_run, :run_id),
      sha: Map.get(gate_run, :head_sha),
      decision_sha: gate_run.human_decision_sha,
      mode: Map.get(gate_run, :mode),
      verdict: Map.get(gate_run, :verdict),
      agent_verdict: Map.get(gate_run, :agent_verdict),
      decision: gate_run.human_decision,
      state: gate_run.human_decision_state,
      agreed: gate_run.agreed,
      unchanged: gate_run.unchanged
    }

    audit_opts = for {:audit_dir, dir} <- opts, do: {:dir, dir}

    case AuditLog.record(event, audit_opts) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to audit the acceptance gate agreement for #{event.issue_identifier}: #{inspect(reason)}")
    end
  end

  @doc """
  The agreement of a repository over its last #{@window} decisions (`approve` or `rework`) in
  `runs`. A decision on a verdict the gate didn't escalate agrees when it is the gate's verdict.
  """
  @spec stats([map()]) :: stats()
  def stats(runs) do
    window =
      runs
      |> verdicts()
      |> Enum.filter(&(Map.get(&1, :human_decision) in ["approve", "rework"]))
      |> Enum.sort_by(&sort_key(Map.get(&1, :human_decided_at)), :desc)
      |> Enum.take(@window)

    {escalated, judged} = Enum.split_with(window, &(&1.verdict == "escalate"))
    agreed = Enum.count(judged, &(&1.verdict == &1.human_decision))
    tokens = window |> Enum.map(&total_tokens/1) |> Enum.sort()

    stats = %{
      judged: length(window),
      agreed: agreed,
      agreement_rate: rate(agreed, length(judged)),
      unsafe_approvals: Enum.count(judged, &(&1.verdict == "approve" and &1.human_decision == "rework")),
      false_reworks: Enum.count(judged, &(&1.verdict == "rework" and merged_unchanged?(&1))),
      escalations: length(escalated),
      escalations_merged_unchanged: Enum.count(escalated, &merged_unchanged?/1),
      tokens: %{median: percentile(tokens, 50), p90: percentile(tokens, 90)}
    }

    case ready_to_enforce(Map.put(stats, :not_escalated, length(judged))) do
      :ok -> Map.merge(stats, %{ready_to_enforce: true, unmet_condition: nil})
      {:unmet, condition} -> Map.merge(stats, %{ready_to_enforce: false, unmet_condition: condition})
    end
  end

  defp merged_unchanged?(gate_run), do: gate_run.human_decision == "approve" and Map.get(gate_run, :unchanged) == true

  defp total_tokens(gate_run) do
    case Map.get(gate_run, :tokens) do
      %{total_tokens: total} when is_integer(total) -> total
      _tokens -> 0
    end
  end

  defp rate(_count, 0), do: nil
  defp rate(count, total), do: Float.round(count / total, 3)

  # Nearest rank: the smallest value with at least `p`% of the values at or below it.
  defp percentile([], _p), do: nil
  defp percentile(sorted, p), do: Enum.at(sorted, ceil(p * length(sorted) / 100) - 1)

  @doc """
  `:ok` when the stats meet the threshold for `enforce`: at least #{@min_judged} judged tickets,
  no unsafe approval, false reworks at 10% or less of the judged tickets, and at least 90%
  agreement on the tickets the gate didn't escalate (`not_escalated`). Otherwise the first unmet
  condition.
  """
  @spec ready_to_enforce(map()) :: :ok | {:unmet, String.t()}
  def ready_to_enforce(%{judged: judged, agreed: agreed, unsafe_approvals: unsafe, false_reworks: false_reworks, not_escalated: not_escalated}) do
    cond do
      judged < @min_judged -> {:unmet, "at least #{@min_judged} judged tickets (#{judged} so far)"}
      unsafe > 0 -> {:unmet, "no unsafe approvals (#{unsafe})"}
      false_reworks * 10 > judged -> {:unmet, "false reworks at 10% or less (#{percent(false_reworks, judged)})"}
      not_escalated == 0 -> {:unmet, "at least 90% agreement on the tickets the gate didn't escalate (none yet)"}
      agreed * 10 < not_escalated * 9 -> {:unmet, "at least 90% agreement on the tickets the gate didn't escalate (#{percent(agreed, not_escalated)})"}
      true -> :ok
    end
  end

  defp percent(count, total), do: "#{floor(count * 100 / total)}%"

  @doc """
  The gate for `/api/v1/state`: the passes running and queued, the latest verdict of the
  #{@recent_limit} most recently judged issues, and the agreement stats of each repository with a
  verdict. The verdicts and stats are worked out once per gate run written, not on every call.

  Options: `:run_store`, `:runner` (the gate runner server).
  """
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    judged =
      case memoize(run_store, :snapshot, fn -> judged_snapshot(run_store) end) do
        {:ok, judged} -> judged
        {:error, _reason} -> %{recent: [], agreement: %{}}
      end

    runner = runner_snapshot(Keyword.get(opts, :runner, Runner))
    Map.merge(%{running: runner.running, queued: runner.queued}, judged)
  end

  defp judged_snapshot(run_store) do
    with {:ok, runs} <- verdict_runs(run_store) do
      {:ok,
       %{
         recent: runs |> latest_per_issue() |> Enum.take(@recent_limit),
         agreement: runs |> Enum.group_by(&Map.get(&1, :repo_key)) |> Map.new(fn {repo_key, repo_runs} -> {repo_key, stats(repo_runs)} end)
       }}
    end
  end

  defp verdict_runs(run_store) do
    case run_store.list_all_runs(:all) do
      runs when is_list(runs) -> {:ok, verdicts(runs)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Gate runs are written a few times per ticket, the snapshot is read every second.
  defp memoize(RunStore, key, fun), do: RunStore.memoize_runs({__MODULE__, key}, "acceptance_gate", fun)
  defp memoize(_run_store, _key, fun), do: fun.()

  defp runner_snapshot(runner) do
    Runner.snapshot(runner)
  catch
    :exit, _reason -> %{running: [], queued: []}
  end

  @doc "The latest gate verdict on issue `issue_id` of repository `repo_key`, or nil."
  @spec latest(String.t() | nil, String.t() | nil, keyword()) :: map() | nil
  def latest(repo_key, issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    with true <- is_binary(repo_key) and is_binary(issue_id),
         {:ok, runs} <- memoize(run_store, :verdicts, fn -> verdict_runs(run_store) end) do
      Enum.find(runs, &(Map.get(&1, :repo_key) == repo_key and Map.get(&1, :issue_id) == issue_id))
    else
      _missing -> nil
    end
  end

  defp sort_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp sort_key(_at), do: 0

  defp normalize(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize(_state), do: ""
end
