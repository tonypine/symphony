defmodule SymphonyElixir.PrWatch do
  @moduledoc """
  The PR and CI watcher (`docs/pr-ci-decisions.md`): one `SymphonyElixir.PrWatch.Repo` per
  repository whose pull requests are polled (`pull_requests` polling on). Each tick it reads its
  watched tickets' PRs, decides what each one's phase and PR facts call for
  (`SymphonyElixir.PrDecision.decide/1`), applies it (`SymphonyElixir.PrDecision.Apply`) and keeps
  the facts, the decision and the attempts on the ticket's state record (`TicketState.pr_watch`).

  The rest of Symphony reads that record through this module: the orchestrator's dispatch gates
  (`dispatch_reason/2`), a CI Fix run's prompt (`pending_ci_failure/2`, `pending_pr_conflict/2`),
  an agent's view of the open PRs that share its files (`open_pr_overlap/2`), and the state API's
  landing waits, auto-merge list, red base branches (`red_bases/1`), silent waits
  (`silent_waits/1`) and rate limit (`rate_limit/1`). Check Now (`check/2`) makes a ticket's
  watcher read and decide at once.
  """

  use Supervisor

  alias SymphonyElixir.{BlockedHold, Config, LandingOrder, RunStore, TicketState}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrWatch.{Attempts, Competitors, Repo, SilentWait}

  @registry SymphonyElixir.Repo.Registry

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

  @doc """
  Asks every running watcher to tick now, so a ticket that just entered `Merging` lands, or a base
  branch that moved updates the PRs behind it, without waiting for the timer.
  """
  @spec poll_now() :: :ok
  def poll_now, do: Enum.each(running_watchers(), &Repo.poll_now/1)

  @doc """
  Check Now: makes the watcher of `issue_identifier`'s repository read and decide at once, and
  returns the ticket's state record with the new decision. A ticket the watcher has no record of yet
  (it just entered a watched phase) is looked for after every running watcher ticks.
  `{:error, :not_watched}` when the watcher still doesn't watch it, `{:error, :watcher_not_running}`
  when its repository's watcher isn't running, and the tick's error when it failed. `opts`:
  `:run_store`, `:repo_key` and `:timeout`.
  """
  @spec check(String.t(), keyword()) :: {:ok, TicketState.t()} | {:error, term()}
  def check(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    case find_record(issue_identifier, opts) do
      %{repo_key: repo_key} ->
        with {:ok, _summary} <- poll(GenServer.whereis(Repo.name(repo_key)), timeout), do: found(issue_identifier, opts)

      nil ->
        Enum.each(running_watchers(), &Repo.poll(&1, timeout))
        found(issue_identifier, opts)
    end
  end

  defp poll(nil, _timeout), do: {:error, :watcher_not_running}
  defp poll(pid, timeout), do: Repo.poll(pid, timeout)

  defp found(issue_identifier, opts) do
    case find_record(issue_identifier, opts) do
      %{} = record -> {:ok, record}
      nil -> {:error, :not_watched}
    end
  end

  defp find_record(issue_identifier, opts), do: opts |> records() |> Enum.find(&(&1.issue_identifier == issue_identifier))

  defp running_watchers do
    if Process.whereis(@registry), do: Registry.select(@registry, [{{{:pr_watch, :_}, :"$1", :_}, [], [:"$1"]}]), else: []
  end

  @doc """
  Every watched ticket that waits silently (`SymphonyElixir.PrWatch.SilentWait`): its phase, since
  when, the watcher's last rule, the bound that passed (nil when it is only quiet) and why.
  """
  @spec silent_waits(keyword()) :: [map()]
  def silent_waits(opts \\ []) do
    for %{pr_watch: %{silent: silent} = watch} = record <- records(opts), SilentWait.listed?(silent) do
      %{
        issue_id: record.issue_id,
        issue_identifier: record.issue_identifier,
        repo_key: record.repo_key,
        phase: watch.stay || watch.facts.phase,
        pr_url: watch.pr_url,
        since: silent.since,
        rule: watch.decision && watch.decision.rule,
        bound: silent.bound,
        reason: silent.reason
      }
    end
    |> Enum.sort_by(&{DateTime.to_unix(&1.since, :microsecond), &1.issue_identifier || &1.issue_id || ""})
  end

  @doc """
  GitHub's rate limit as the newest read that reported it left it: requests remaining, the window's
  limit and when it resets. Nil before any read reported one.
  """
  @spec rate_limit(keyword()) :: map() | nil
  def rate_limit(opts \\ []) do
    opts
    |> records()
    |> Enum.filter(&match?(%{pr_watch: %{rate_limit: %{}, read_at: %DateTime{}}}, &1))
    |> Enum.max_by(& &1.pr_watch.read_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      %{pr_watch: watch} -> watch.rate_limit
    end
  end

  @doc """
  The watcher's record of the issue's PR (`TicketState.pr_watch`), or nil when it doesn't watch
  it. `opts`: `:repo_key` (else every configured repo is searched) and `:run_store`.
  """
  @spec watch(String.t() | nil, keyword()) :: TicketState.pr_watch() | nil
  def watch(issue_id, opts \\ []), do: if(is_binary(issue_id), do: find_watch(issue_id, opts))

  defp find_watch(issue_id, opts) do
    store = store(opts)

    Enum.find_value(repo_keys(opts), fn repo_key ->
      case store.get_ticket_state(repo_key, issue_id) do
        %{} = record -> TicketState.pr_watch(record)
        _none -> nil
      end
    end)
  end

  @doc """
  Why the orchestrator must not start a run for `issue` now, from the watcher's decision on it, or
  nil when it may. Only the phases whose run waits on the PR are gated: `Code Review` and `QA` run
  on a decision to `dispatch` (a green, conflict-free head), and `Merging`, with auto-merge on,
  runs only the landing agent the decision hands it to (`land_agent`); one with no PR waits for a
  person's answer (R6). A ticket the watcher hasn't decided on yet waits for it.
  """
  @spec dispatch_reason(Issue.t(), map()) :: String.t() | nil
  def dispatch_reason(%Issue{} = issue, settings) do
    case gated_phase(issue.state, settings) do
      nil -> nil
      phase -> gate(phase, watch(issue.id, repo_opts(issue)))
    end
  end

  defp gated_phase(state, settings) when is_binary(state) do
    cond do
      same_state?(state, settings.tracker.code_review_state) -> :review
      same_state?(state, settings.tracker.qa_state) -> :review
      same_state?(state, "Merging") and SymphonyElixir.AutoMerge.enabled?(settings) -> :landing
      true -> nil
    end
  end

  defp gated_phase(_state, _settings), do: nil

  defp gate(_phase, nil), do: "the PR watcher hasn't read its PR yet"
  defp gate(_phase, %{decision: nil}), do: "the PR watcher hasn't decided on its PR yet"
  defp gate(:review, %{decision: %{kind: :dispatch}}), do: nil
  defp gate(:landing, %{decision: %{kind: :land_agent}}), do: nil
  defp gate(_phase, %{decision: %{reason: reason, rule: rule}}), do: "the PR watcher (#{rule}): #{reason}"

  @doc """
  The red head's failure a CI Fix run was sent for, as its prompt renders it (the failed checks,
  their log and whether the PR was approved), or nil once the head is green or the watcher doesn't
  watch the ticket.
  """
  @spec pending_ci_failure(String.t() | nil, keyword()) :: map() | nil
  def pending_ci_failure(issue_id, opts \\ []), do: fix(issue_id, :ci_failure, opts)

  @doc "The conflict a CI Fix run was sent for, as its prompt renders it, or nil once it is resolved."
  @spec pending_pr_conflict(String.t() | nil, keyword()) :: map() | nil
  def pending_pr_conflict(issue_id, opts \\ []), do: fix(issue_id, :pr_conflict, opts)

  defp fix(issue_id, kind, opts) do
    case watch(issue_id, opts) do
      %{fix: fix} -> Map.get(fix, kind)
      nil -> nil
    end
  end

  @doc """
  Whether the rerun the watcher started on `head` has not reported yet, so a read of that head
  that looks green is still running (`SymphonyElixir.PrWatch.Attempts.rerun_pending?/2`).
  `check_names` are the checks the read shows.
  """
  @spec rerun_pending?(String.t() | nil, String.t() | nil, [String.t()], keyword()) :: boolean()
  def rerun_pending?(issue_id, head, check_names, opts \\ []) do
    case watch(issue_id, opts) do
      %{attempts: attempts} -> Attempts.rerun_pending?(attempts, %{head_sha: head, check_names: check_names})
      nil -> false
    end
  end

  @doc """
  The other open PRs the watcher reads, for an agent's first prompt: with the issue's own PR read,
  the ones that share files with it (`shared`) and the one it waits for; without it (no PR yet),
  every other open PR and the files it changes (`open`). Nil when there are none.
  """
  @spec open_pr_overlap(String.t(), keyword()) :: map() | nil
  def open_pr_overlap(issue_id, opts \\ []) when is_binary(issue_id) do
    {own, others} =
      opts
      |> landing_records()
      |> Enum.filter(&match?(%{landing: %{files: [_ | _]}}, &1))
      |> Enum.split_with(&(&1.issue_id == issue_id))

    case {own, others} do
      {_own, []} -> nil
      {[%{landing: landing} | _], others} -> overlap_with(landing, others)
      {[], others} -> %{waits_for: nil, shared: [], open: Enum.map(others, &overlap_entry(&1, &1.landing.files))}
    end
  end

  defp overlap_with(landing, others) do
    shared =
      for record <- others, files = LandingOrder.shared_files(landing.files, record.landing.files), files != [] do
        overlap_entry(record, files)
      end

    if shared == [], do: nil, else: %{waits_for: landing.waits_for, shared: shared, open: []}
  end

  defp overlap_entry(record, files) do
    %{issue_identifier: record.issue_identifier, state: record.landing.state, pr_url: record.pr_url, files: files}
  end

  @doc """
  Every watched PR that waits for another to land first (`SymphonyElixir.LandingOrder`), or waits on
  its competitors on a landing hold (`SymphonyElixir.PrWatch.Competitors`), with the PR it waits for
  (the first competitor, for a hold), how many files they share, and the reason: the hold's, else
  the one the watcher recorded.
  """
  @spec landing_waits(keyword()) :: [map()]
  def landing_waits(opts \\ []) do
    opts
    |> landing_records()
    |> Enum.flat_map(&landing_wait/1)
    |> Enum.sort_by(&(&1.issue_identifier || &1.issue_id || ""))
  end

  defp landing_wait(%{landing: landing, hold: hold} = record) do
    case landing.waits_for || held_wait(hold, record.links) do
      %{} = wait ->
        [
          %{
            issue_id: record.issue_id,
            issue_identifier: record.issue_identifier,
            pr_url: record.pr_url,
            state: landing.state,
            waits_for: Map.take(wait, [:issue_id, :issue_identifier, :pr_url, :state]),
            shared_files: wait.shared_files,
            files: wait.files,
            reason: landing_reason(hold, record.decision, wait),
            since: landing.waits_since || if(BlockedHold.landing?(hold), do: hold.set_at)
          }
        ]

      nil ->
        []
    end
  end

  # A landing hold waits on the competitors it recorded, the first of them named.
  defp held_wait(hold, links) do
    with true <- BlockedHold.landing?(hold),
         [link | _] <- for(%{released: false} = link <- links, do: link) do
      %{issue_id: link.issue_id, issue_identifier: link.issue_identifier || "PR ##{link.pr_number}", pr_url: link.pr_url, state: nil, shared_files: length(link.files), files: link.files}
    else
      _none -> nil
    end
  end

  # The hold's words when the ticket waits on a landing hold; the decision's own words when it is the
  # landing wait; else how the landing order reads.
  defp landing_reason(hold, decision, wait) do
    cond do
      BlockedHold.landing?(hold) and is_binary(hold.reason) -> hold.reason
      match?(%{kind: kind, reason: reason} when kind in [:wait_for_competitors, :wait] and is_binary(reason), decision) -> decision.reason
      true -> LandingOrder.reason(wait)
    end
  end

  @doc """
  The competitors the issue's landing hold waits on, for the state API (`watch.waits_on`): each
  one's ticket (else its PR), its PR, how many files they share and which. Empty without a wait.
  """
  @spec competitor_waits(TicketState.pr_watch() | nil) :: [map()]
  def competitor_waits(%{links: links}) do
    for %{released: false} = link <- links do
      %{identifier: link.issue_identifier || "PR ##{link.pr_number}", kind: "competitor", pr_url: link.pr_url, shared_files: length(link.files), files: link.files}
    end
  end

  def competitor_waits(_watch), do: []

  @doc """
  A person's `Unblock` of the issue's landing hold: the PR watcher of `repo_key` removes the links
  Symphony added and stops waiting on those PRs (`SymphonyElixir.PrWatch.Competitors.release/3`),
  in its own process when it runs. `opts` go to the release when it doesn't.
  """
  @spec release_competitors(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def release_competitors(repo_key, issue_id, opts \\ []) do
    if Process.whereis(@registry) && GenServer.whereis(Repo.name(repo_key)),
      do: Repo.release(Repo.name(repo_key), issue_id),
      else: Competitors.release(repo_key, issue_id, opts)
  end

  @doc """
  Every check red on a base branch that holds watched PRs (R23), once per base and check: the base,
  the check and the tickets waiting for it to go green, for the state API. It clears by itself once
  the base is green and no PR waits on it.
  """
  @spec red_bases(keyword()) :: [map()]
  def red_bases(opts \\ []) do
    opts
    |> records()
    |> Enum.filter(&match?(%{pr_watch: %{decision: %{rule: "R23"}}}, &1))
    |> Enum.group_by(fn %{pr_watch: %{facts: facts}} -> {facts.base_ref, facts.failing_check} end)
    |> Enum.map(fn {{base, check}, records} ->
      %{base: base, check: check, issue_identifiers: records |> Enum.map(&(&1.issue_identifier || &1.issue_id)) |> Enum.sort()}
    end)
    |> Enum.sort_by(&{&1.base || "", &1.check || ""})
  end

  @doc """
  Every watched `Merging` PR, with whether GitHub auto-merge is on and what the watcher decided, for
  the dashboard.
  """
  @spec auto_merge_statuses(keyword()) :: [map()]
  def auto_merge_statuses(opts \\ []) do
    opts
    |> records()
    |> Enum.filter(&match?(%{pr_watch: %{facts: %{phase: :merging}}}, &1))
    |> Enum.map(fn %{pr_watch: watch} = record ->
      %{
        issue_id: record.issue_id,
        issue_identifier: record.issue_identifier,
        pr_url: watch.pr_url,
        state: Atom.to_string(watch.facts.auto_merge),
        head_sha: watch.head_sha,
        status: watch.decision && watch.decision.reason,
        updated_at: watch.read_at
      }
    end)
    |> Enum.sort_by(&(&1.issue_identifier || &1.issue_id || ""))
  end

  defp landing_records(opts) do
    for %{pr_watch: %{landing: %{} = landing} = watch} = record <- records(opts) do
      %{
        issue_id: record.issue_id,
        issue_identifier: record.issue_identifier,
        pr_url: watch.pr_url,
        landing: landing,
        decision: watch.decision,
        hold: TicketState.get_hold(record, :blocked),
        links: watch.links
      }
    end
  end

  defp records(opts) do
    store = store(opts)

    Enum.flat_map(repo_keys(opts), fn repo_key ->
      case store.list_ticket_states(repo_key) do
        records when is_list(records) -> records |> Enum.map(&TicketState.normalize/1) |> Enum.filter(& &1.pr_watch)
        {:error, _reason} -> []
      end
    end)
  end

  defp repo_keys(opts) do
    case Keyword.fetch(opts, :repo_key) do
      {:ok, repo_key} when is_binary(repo_key) and repo_key != "" ->
        [repo_key]

      # A configuration that can't be read has no repository to search.
      _none ->
        for {:ok, repos} <- [Config.repos()], %{name: name} <- repos, name not in [nil, ""], do: name
    end
  end

  defp repo_opts(%Issue{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "", do: [repo_key: repo_key]
  defp repo_opts(_issue), do: []

  defp store(opts), do: Keyword.get(opts, :run_store, RunStore)

  defp same_state?(state, name), do: normalize(state) == normalize(name)

  defp normalize(name), do: name |> to_string() |> String.trim() |> String.downcase()
end
