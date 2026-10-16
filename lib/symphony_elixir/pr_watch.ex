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
  landing waits and auto-merge list.
  """

  use Supervisor

  alias SymphonyElixir.{Config, LandingOrder, RunStore, TicketState}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrWatch.{Attempts, Repo}

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
  def poll_now do
    if Process.whereis(@registry) do
      @registry
      |> Registry.select([{{{:pr_watch, :_}, :"$1", :_}, [], [:"$1"]}])
      |> Enum.each(&Repo.poll_now/1)
    end

    :ok
  end

  @doc """
  The watcher's record of the issue's PR (`TicketState.pr_watch`), or nil when it doesn't watch
  it. `opts`: `:repo_key` (else every configured repo is searched) and `:run_store`.
  """
  @spec watch(String.t() | nil, keyword()) :: TicketState.pr_watch() | nil
  def watch(issue_id, opts \\ [])

  def watch(issue_id, opts) when is_binary(issue_id) do
    store = store(opts)

    Enum.find_value(repo_keys(opts), fn repo_key ->
      case store.get_ticket_state(repo_key, issue_id) do
        %{} = record -> TicketState.pr_watch(record)
        _none -> nil
      end
    end)
  end

  def watch(_issue_id, _opts), do: nil

  @doc """
  Why the orchestrator must not start a run for `issue` now, from the watcher's decision on it, or
  nil when it may. Only the phases whose run waits on the PR are gated: `Code Review` and `QA` run
  on a decision to `dispatch` (a green, conflict-free head), and `Merging`, with auto-merge on,
  runs only the landing agent the decision hands it to (`land_agent`). A ticket the watcher hasn't
  decided on yet waits for it.
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
  Every watched PR that waits for another to land first (`SymphonyElixir.LandingOrder`), with the
  PR it waits for, how many files they share, and the reason the watcher recorded.
  """
  @spec landing_waits(keyword()) :: [map()]
  def landing_waits(opts \\ []) do
    opts
    |> landing_records()
    |> Enum.flat_map(fn
      %{landing: %{waits_for: %{} = wait} = landing} = record ->
        [
          %{
            issue_id: record.issue_id,
            issue_identifier: record.issue_identifier,
            pr_url: record.pr_url,
            state: landing.state,
            waits_for: Map.take(wait, [:issue_id, :issue_identifier, :pr_url, :state]),
            shared_files: wait.shared_files,
            files: wait.files,
            reason: landing_reason(record.decision, wait),
            since: landing.waits_since
          }
        ]

      _record ->
        []
    end)
    |> Enum.sort_by(&(&1.issue_identifier || &1.issue_id || ""))
  end

  # The decision's own words when it is the landing wait; else how the landing order reads.
  defp landing_reason(%{kind: kind, reason: reason}, _wait) when kind in [:wait_for_competitors, :wait] and is_binary(reason), do: reason
  defp landing_reason(_decision, wait), do: LandingOrder.reason(wait)

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
      %{issue_id: record.issue_id, issue_identifier: record.issue_identifier, pr_url: watch.pr_url, landing: landing, decision: watch.decision}
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

      _none ->
        case Config.repos() do
          {:ok, repos} -> repos |> Enum.map(& &1.name) |> Enum.reject(&(&1 in [nil, ""]))
          {:error, _reason} -> List.wrap(Config.repo_key_or_nil())
        end
    end
  end

  defp repo_opts(%Issue{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "", do: [repo_key: repo_key]
  defp repo_opts(_issue), do: []

  defp store(opts), do: Keyword.get(opts, :run_store, RunStore)

  defp same_state?(state, name) when is_binary(name), do: String.downcase(String.trim(state)) == String.downcase(String.trim(name))
  defp same_state?(_state, _name), do: false
end
