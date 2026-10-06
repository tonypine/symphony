defmodule SymphonyElixir.CiPoller do
  @moduledoc """
  Polling-mode GitHub Actions CI poller.

  With `github.webhooks.enabled`, GitHub deliveries that name a watched PR (see
  `webhook_delivery/2`) run the same poll for that PR's repository right away, so a CI result
  lands in seconds instead of up to one poll interval. The timed poll keeps running and catches
  up on anything the relay dropped.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.AcceptanceGate.Agreement
  alias SymphonyElixir.{AuditLog, AutoMerge, AutoReview, Config, Notifications, Orchestrator, RunStore, Tracker}
  alias SymphonyElixir.AutoReview.HoldNote
  alias SymphonyElixir.GitHub.{PullRequest, Webhook}
  alias SymphonyElixir.HumanReview
  alias SymphonyElixir.Linear.{Issue, Usage}

  @in_review_state "In Review"
  @merging_state "Merging"
  @active_state "In Progress"
  @closed_pr_states ["CLOSED", "MERGED"]
  @github_error_backoff_threshold 3
  @max_github_error_backoff_ms 300_000
  # Grace window after a CI-failure dispatch during which escalation is held off,
  # giving the orchestrator time to pick up the In Progress issue and mark the
  # rework run "running". Without it, the poll immediately following the final
  # retry's dispatch could escalate before the agent starts and abandon it.
  @dispatch_start_grace_ms 120_000
  @status_table :ci_poller_status
  # Coalesces the burst of deliveries a CI run sends (one per check run and suite) into one poll.
  @webhook_debounce_ms 1_000
  @settled_conclusions ["SUCCESS", "FAILURE"]
  # Checks only a person can clear: the `protected-paths` workflow's job fails a PR whose own
  # commits change an agent-protected path until a person adds the waiver label.
  @human_only_checks ["protected paths"]
  @waiver_label "protected-paths-approved"
  # How long a `Merging` head waits on checks its base branch doesn't require before it may land
  # without them (see `track_landing_wait/4`).
  @landing_fallback_ms 15 * 60_000

  defmodule State do
    @moduledoc false
    defstruct [
      :timer_ref,
      :poll_interval_ms,
      :webhook_timer_ref,
      webhook_repo_keys: MapSet.new(),
      webhooks: %{
        last_event_at: nil,
        events_received: 0,
        rejected: 0,
        results_via_webhook: 0,
        results_via_poll: 0
      },
      consecutive_failures: 0,
      current_backoff_ms: nil,
      degraded?: false,
      opts: []
    ]
  end

  @type poll_summary :: %{
          mode: :polling | :tracker | :disabled,
          discovered: non_neg_integer(),
          processed: non_neg_integer(),
          actions: [term()],
          settled: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # Reads the last-published poller status from a shared ETS table so the
  # orchestrator snapshot loop does not block on a synchronous GenServer.call
  # when the poller is mid-cycle on a slow remote.
  @doc false
  @spec status() :: map() | :unavailable
  def status do
    case :ets.whereis(@status_table) do
      :undefined ->
        :unavailable

      _table ->
        case :ets.lookup(@status_table, :current) do
          [{:current, status}] -> status
          _other -> :unavailable
        end
    end
  end

  @impl true
  def init(opts) do
    Usage.put_caller(:ci_poller)
    poll_interval_ms = poll_interval_ms(opts)
    opts = poller_opts(opts, poll_interval_ms)
    state = %State{opts: opts, poll_interval_ms: poll_interval_ms}
    publish_status(state)

    {:ok, schedule_poll(state, 0)}
  end

  @doc """
  Hands a verified GitHub webhook delivery to the running poller: `{:ci, event}` (see
  `SymphonyElixir.GitHub.Webhook.parse/3`), `:ping` (the relay (re)connected), `:ignored`, or
  `{:rejected, reason}` for a delivery that failed the signature check.
  """
  @spec webhook_delivery(term(), GenServer.server()) :: :ok | :unavailable
  def webhook_delivery(delivery, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :unavailable
      _pid -> GenServer.cast(server, {:webhook_delivery, delivery})
    end
  end

  @impl true
  def handle_cast({:webhook_delivery, {:rejected, _reason}}, %State{} = state) do
    {:noreply, update_webhook_stats(state, &Map.update!(&1, :rejected, fn count -> count + 1 end))}
  end

  def handle_cast({:webhook_delivery, delivery}, %State{} = state) do
    state =
      update_webhook_stats(state, &%{&1 | last_event_at: DateTime.utc_now(), events_received: &1.events_received + 1})

    case delivery do
      # GitHub pings a hook when it is created, which `gh webhook forward` does on every start:
      # poll everything now to catch up on events missed while the relay was away.
      :ping -> {:noreply, schedule_poll(state, 0)}
      {:ci, event} -> {:noreply, queue_webhook_poll(state, event)}
      _ignored -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    {state, delay_ms} =
      case poll_cycle_result(state.opts) do
        {:ok, summary} ->
          {state |> count_results(:results_via_poll, summary) |> handle_poll_success(), state.poll_interval_ms}

        {:error, message, reason} ->
          handle_poll_failure(state, message, reason)
      end

    publish_status(state)
    {:noreply, schedule_poll(state, delay_ms)}
  end

  def handle_info(:webhook_poll, %State{} = state) do
    state =
      state.webhook_repo_keys
      |> Enum.sort()
      |> Enum.reduce(%{state | webhook_repo_keys: MapSet.new(), webhook_timer_ref: nil}, &webhook_poll_repo/2)

    publish_status(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp queue_webhook_poll(%State{} = state, event) do
    case webhook_repo_keys(event, state.opts) do
      [] ->
        state

      repo_keys ->
        state = %{state | webhook_repo_keys: MapSet.union(state.webhook_repo_keys, MapSet.new(repo_keys))}

        if is_reference(state.webhook_timer_ref) do
          state
        else
          delay_ms = Keyword.get(state.opts, :webhook_debounce_ms, @webhook_debounce_ms)
          %{state | webhook_timer_ref: Process.send_after(self(), :webhook_poll, delay_ms)}
        end
    end
  end

  # Only deliveries about a PR the poller already watches run a poll; the timed poll discovers
  # new ones.
  defp webhook_repo_keys(event, opts) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    Enum.filter(repo_keys_from_opts(opts), fn repo_key ->
      case list_ci_checks(run_store, repo_key) do
        {:ok, checks} -> Enum.any?(checks, &Webhook.matches_record?(event, &1))
        {:error, _reason} -> false
      end
    end)
  end

  defp webhook_poll_repo(repo_key, %State{} = state) do
    case poll_cycle_result(Keyword.put(state.opts, :repo_key, repo_key)) do
      {:ok, summary} ->
        state = count_results(state, :results_via_webhook, summary)
        if summary.settled > 0, do: Keyword.get(state.opts, :on_webhook_result, &request_orchestrator_refresh/0).()
        state

      {:error, message, _reason} ->
        Logger.warning("CI poll for a GitHub webhook failed repo_key=#{repo_key}: #{message}")
        state
    end
  end

  # The orchestrator releases a Merging CI hold on its next tick; ask for that tick now so a
  # result that came in through a webhook lands in seconds.
  defp request_orchestrator_refresh do
    {:ok, _pid} = Task.start(fn -> Orchestrator.request_refresh() end)
    :ok
  end

  defp count_results(%State{} = state, key, summary) do
    update_webhook_stats(state, &Map.update!(&1, key, fn count -> count + summary.settled end))
  end

  defp update_webhook_stats(%State{} = state, fun) do
    state = %{state | webhooks: fun.(state.webhooks)}
    publish_status(state)
    state
  end

  @doc false
  @spec poll_once(keyword()) :: {:ok, poll_summary()} | {:error, term()}
  def poll_once(opts \\ []) when is_list(opts) do
    if scoped_poll_opts?(opts) do
      poll_once_for_repo(opts)
    else
      poll_once_for_repos(opts)
    end
  end

  @doc false
  @spec pending_ci_failure(String.t(), keyword()) :: map() | nil
  def pending_ci_failure(issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_keys = repo_keys_from_opts(opts)

    if is_binary(issue_id) do
      Enum.find_value(repo_keys, &pending_ci_failure_for_repo(&1, issue_id, run_store))
    end
  end

  defp pending_ci_failure_for_repo(repo_key, issue_id, run_store) do
    with {:ok, checks} <- list_ci_checks(run_store, repo_key),
         %{} = record <- Enum.find(checks, &(Map.get(&1, :issue_id) == issue_id)) do
      normalize_ci_failure(Map.get(record, :ci_failure))
    else
      _ -> nil
    end
  end

  @doc """
  The QA failure waiting for the executor's fix run, or nil. Auto Review stores it
  when QA fails and sends the issue back to In Progress.
  """
  @spec pending_qa_failure(String.t(), keyword()) :: map() | nil
  def pending_qa_failure(issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    if is_binary(issue_id) do
      Enum.find_value(repo_keys_from_opts(opts), &qa_failure_for_repo(run_store, &1, issue_id))
    end
  end

  defp qa_failure_for_repo(run_store, repo_key, issue_id) do
    case find_ci_check(run_store, repo_key, issue_id) do
      %{qa_failure: %{} = qa_failure} -> qa_failure
      _record -> nil
    end
  end

  @doc "Clears the pending QA failure once a fix run has finished."
  @spec complete_pending_qa_failure(String.t(), keyword()) :: :ok | {:error, term()}
  def complete_pending_qa_failure(issue_id, opts \\ []) when is_binary(issue_id) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    Enum.reduce_while(repo_keys_from_opts(opts), :ok, fn repo_key, :ok ->
      case clear_qa_failure(run_store, repo_key, issue_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp clear_qa_failure(run_store, repo_key, issue_id) do
    case find_ci_check(run_store, repo_key, issue_id) do
      %{qa_failure: %{}} -> update_ci_check_record(run_store, repo_key, issue_id, %{qa_failure: nil})
      _record -> :ok
    end
  end

  @doc """
  The PR head SHA the poller last saw ready to land (see `landing_action/1`): every check it
  requires passed. Nil before then, or when the last head it saw was not ready.
  """
  @spec landing_ready_head(String.t(), keyword()) :: String.t() | nil
  def landing_ready_head(issue_id, opts \\ []) when is_binary(issue_id) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    Enum.find_value(repo_keys_from_opts(opts), &Map.get(find_ci_check(run_store, &1, issue_id) || %{}, :landing_ready_sha))
  end

  @doc """
  The PR head SHA and its CI conclusion (`"SUCCESS"`, `"FAILURE"`, `"IN_PROGRESS"`, ...) the
  poller last observed for the issue, or nil before its first poll.
  """
  @spec observed_head(String.t(), keyword()) :: %{commit_sha: String.t() | nil, conclusion: String.t() | nil} | nil
  def observed_head(issue_id, opts \\ []) when is_binary(issue_id) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    Enum.find_value(repo_keys_from_opts(opts), fn repo_key ->
      case find_ci_check(run_store, repo_key, issue_id) do
        %{} = record -> %{commit_sha: Map.get(record, :last_observed_sha), conclusion: Map.get(record, :last_observed_conclusion)}
        nil -> nil
      end
    end)
  end

  defp find_ci_check(run_store, repo_key, issue_id) do
    case list_ci_checks(run_store, repo_key) do
      {:ok, checks} -> Enum.find(checks, &(Map.get(&1, :issue_id) == issue_id))
      _error -> nil
    end
  end

  @doc false
  @spec ci_owned_issue?(String.t(), keyword()) :: boolean()
  def ci_owned_issue?(issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_keys = repo_keys_from_opts(opts)

    if is_binary(issue_id), do: Enum.any?(repo_keys, &ci_owned_issue_for_repo?(&1, issue_id, run_store)), else: false
  end

  defp ci_owned_issue_for_repo?(repo_key, issue_id, run_store) do
    with {:ok, checks} <- list_ci_checks(run_store, repo_key),
         %{} = record <- Enum.find(checks, &(Map.get(&1, :issue_id) == issue_id)) do
      ci_owned_record?(record)
    else
      _ -> false
    end
  end

  @doc false
  @spec log_excerpt_for_test(String.t(), pos_integer()) :: String.t()
  def log_excerpt_for_test(log, line_limit), do: log_excerpt(log, line_limit)

  defp poll_settings(opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} ->
        {:ok, settings}

      :error ->
        case Keyword.fetch(opts, :repo_key) do
          {:ok, repo_key} -> Config.settings_for_repo(repo_key)
          :error -> Config.settings()
        end
    end
  end

  defp scoped_poll_opts?(opts), do: Keyword.has_key?(opts, :repo_key) or Keyword.has_key?(opts, :settings)

  defp poll_once_for_repo(opts) do
    with {:ok, settings} <- poll_settings(opts) do
      cond do
        not settings.ci.enabled ->
          {:ok, empty_poll_summary(:disabled)}

        settings.pr_review.mode != "polling" ->
          {:ok, empty_poll_summary(:tracker)}

        true ->
          do_poll_once(settings, opts)
      end
    end
  end

  defp poll_once_for_repos(opts) do
    with {:ok, repos} <- Config.repos() do
      repo_keys = repos |> Enum.map(&Map.get(&1, :name)) |> Enum.reject(&(&1 in [nil, ""]))

      with {:ok, opts} <- prefetch_watched_issues(repo_keys, opts) do
        Enum.reduce_while(repo_keys, {:ok, empty_poll_summary(:disabled)}, &poll_repo_and_merge(&1, &2, opts))
      end
    end
  end

  # The tracker's state query already spans every repository, so one read of the states any
  # repository watches serves them all this cycle; each repository keeps only the states its own
  # settings watch.
  defp prefetch_watched_issues(repo_keys, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    case repo_keys |> Enum.flat_map(&repo_watched_states/1) |> Enum.uniq() do
      [] ->
        {:ok, opts}

      states ->
        with {:ok, issues} <- tracker.fetch_issues_by_states(states) do
          {:ok, Keyword.put(opts, :watched_issues, issues)}
        end
    end
  end

  # A repository whose settings fail to load reports that error from its own poll.
  defp repo_watched_states(repo_key) do
    with {:ok, settings} <- Config.settings_for_repo(repo_key),
         true <- settings.ci.enabled and settings.pr_review.mode == "polling" do
      watched_states(settings)
    else
      _skipped -> []
    end
  end

  defp poll_repo_and_merge(repo_key, {:ok, acc}, opts) do
    repo_opts = opts |> Keyword.put(:repo_key, repo_key) |> Keyword.delete(:settings)

    case poll_once_for_repo(repo_opts) do
      {:ok, summary} -> {:cont, {:ok, merge_poll_summary(acc, summary)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp empty_poll_summary(mode), do: %{mode: mode, discovered: 0, processed: 0, actions: [], settled: 0}

  defp merge_poll_summary(acc, summary) do
    %{
      mode: merged_mode(acc.mode, summary.mode),
      discovered: acc.discovered + summary.discovered,
      processed: acc.processed + summary.processed,
      actions: acc.actions ++ summary.actions,
      settled: acc.settled + summary.settled
    }
  end

  defp merged_mode(:polling, _mode), do: :polling
  defp merged_mode(_mode, :polling), do: :polling
  defp merged_mode(:tracker, _mode), do: :tracker
  defp merged_mode(_mode, :tracker), do: :tracker
  defp merged_mode(_left, right), do: right

  defp do_poll_once(settings, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = repo_key_from_opts(opts)
    tracker = Keyword.get(opts, :tracker, Tracker)

    with {:ok, discovered, auto_review_issues, merging_issue_ids, landing_issue_ids} <-
           discover_ci_checks(settings, run_store, tracker, repo_key, now, opts),
         {:ok, checks} <- list_ci_checks(run_store, repo_key) do
      opts =
        opts
        |> put_prefetched_rework_sources(run_store, repo_key, checks)
        |> Keyword.put(:auto_review_issues, auto_review_issues)
        |> Keyword.put(:merging_issue_ids, merging_issue_ids)
        |> Keyword.put(:landing_issue_ids, landing_issue_ids)

      actions = Enum.map(checks, &process_ci_check(&1, settings, opts, now))
      settled = count_settled(checks, run_store, repo_key)

      {:ok, %{mode: :polling, discovered: discovered, processed: length(checks), actions: actions, settled: settled}}
    end
  end

  # Heads whose green or red result this poll saw first, so the dashboard can tell how many
  # results reached Symphony through a webhook and how many through the timed poll.
  defp count_settled(checks_before, run_store, repo_key) do
    observed_before = Map.new(checks_before, &{Map.get(&1, :issue_id), observed(&1)})

    case list_ci_checks(run_store, repo_key) do
      {:ok, checks_after} ->
        Enum.count(checks_after, fn record ->
          {_sha, conclusion} = observed_after = observed(record)
          conclusion in @settled_conclusions and Map.get(observed_before, Map.get(record, :issue_id)) != observed_after
        end)

      {:error, _reason} ->
        0
    end
  end

  defp observed(record), do: {Map.get(record, :last_observed_sha), Map.get(record, :last_observed_conclusion)}

  defp discover_ci_checks(settings, run_store, tracker, repo_key, now, opts) do
    with {:ok, issues} <- fetch_watched_issues(settings, tracker, opts),
         {:ok, existing} <- list_ci_checks(run_store, repo_key) do
      existing_by_issue = Map.new(existing, &{Map.get(&1, :issue_id), &1})
      issues = Enum.filter(issues, &match?(%Issue{}, &1))
      Enum.each(issues, &warn_if_pr_url_lost(&1, Map.get(existing_by_issue, &1.id)))

      discovered = Enum.count(issues, &persist_discovered_ci_check?(&1, existing_by_issue, run_store, repo_key, now))
      observe_gate_decisions(settings, repo_key, issues, existing, opts)

      merging_issue_ids = auto_merge_issue_ids(settings, issues)
      {:ok, discovered, auto_review_issues(settings, issues), merging_issue_ids, landing_issue_ids(issues)}
    end
  end

  # An issue the poller watches a PR for whose Linear attachments now show none (many other
  # attachments once pushed it out of the page read): the agent runner reads the PR from the issue,
  # so its CI and review checks would skip it. Issues that never had a PR, such as a final
  # verification ticket, have no CI check record and stay quiet.
  defp warn_if_pr_url_lost(%Issue{} = issue, %{pr_url: pr_url}) when is_binary(pr_url) do
    if is_nil(first_pr_url(issue)) do
      Logger.warning(
        "issue_id=#{issue.id} issue_identifier=#{issue.identifier} is in #{issue.state} with no PR URL on its Linear attachments; " <>
          "Symphony still watches CI on #{pr_url} for it"
      )
    end
  end

  defp warn_if_pr_url_lost(_issue, _existing), do: :ok

  # Records the human's decision on gate verdicts whose issue left In Review (or Human Review). It
  # runs before the checks are processed, so the CI check record of a PR merged since the last
  # poll still holds the head the human merged.
  defp observe_gate_decisions(settings, repo_key, issues, ci_checks, opts) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    agreement_opts = [
      run_store: run_store,
      tracker: Keyword.get(opts, :tracker, Tracker),
      waiting_states: [AutoReview.state(settings) | HumanReview.review_states(settings)]
    ]

    undecided = Agreement.undecided(repo_key, run_store: run_store)
    Agreement.observe(repo_key, issues, undecided, ci_checks, agreement_opts ++ Keyword.take(opts, [:audit_dir]))
  end

  # `Merging` issues GitHub auto-merge lands: a CI-fix run for one turns auto-merge off first.
  defp auto_merge_issue_ids(settings, issues) do
    if AutoMerge.enabled?(settings),
      do: issues |> Enum.filter(&AutoMerge.merging?/1) |> MapSet.new(& &1.id),
      else: MapSet.new()
  end

  # Every `Merging` issue: its head's CI is read as a landing reads it (see `landing_action/1`).
  defp landing_issue_ids(issues), do: issues |> Enum.filter(&AutoMerge.merging?/1) |> MapSet.new(& &1.id)

  defp fetch_watched_issues(settings, tracker, opts) do
    case Keyword.fetch(opts, :watched_issues) do
      {:ok, issues} -> {:ok, Enum.filter(issues, &issue_in_states?(&1, watched_states(settings)))}
      :error -> tracker.fetch_issues_by_states(watched_states(settings))
    end
  end

  # Auto Review and Human Review issues have an open PR waiting on CI, just like In Review ones.
  # Merging ones too: the orchestrator holds a landing agent that ended its turn on pending checks
  # until this poller sees the head settle.
  defp watched_states(settings) do
    review_states = HumanReview.review_states(settings)

    if AutoReview.enabled?(settings),
      do: review_states ++ [AutoReview.state(settings), @merging_state],
      else: review_states ++ [@merging_state]
  end

  defp auto_review_issues(settings, issues) do
    if AutoReview.enabled?(settings) do
      auto_review_state = normalize_state_name(AutoReview.state(settings))

      issues
      |> Enum.filter(&(normalize_state_name(&1.state) == auto_review_state))
      |> Map.new(&{&1.id, &1})
    else
      %{}
    end
  end

  defp issue_in_states?(%Issue{state: state}, states) when is_binary(state),
    do: Enum.any?(states, &(normalize_state_name(&1) == normalize_state_name(state)))

  defp issue_in_states?(_issue, _states), do: false

  defp normalize_state_name(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state_name(_state), do: ""

  defp persist_discovered_ci_check?(%Issue{} = issue, existing_by_issue, run_store, repo_key, now) do
    existing = Map.get(existing_by_issue, issue.id)

    case discover_ci_check_record(issue, run_store, repo_key, existing, now) do
      nil ->
        false

      record ->
        case put_ci_check(run_store, Map.put(record, :repo_key, repo_key)) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning("Failed to persist discovered CI check record issue_id=#{issue.id}: #{inspect(reason)}")
            false
        end
    end
  end

  defp discover_ci_check_record(%Issue{} = issue, run_store, repo_key, existing, now) do
    with pr_url when is_binary(pr_url) <- first_pr_url(issue),
         %{workspace_path: workspace_path} = run when is_binary(workspace_path) <-
           latest_run_for_issue(run_store, repo_key, issue.id) do
      base = %{
        repo_key: Map.get(existing || %{}, :repo_key),
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_url: issue.url,
        pr_url: pr_url,
        workspace_path: workspace_path,
        worker_host: Map.get(run, :worker_host),
        status: Map.get(existing || %{}, :status, "watching"),
        ci_retry_count: ci_retry_count(existing || %{}),
        rerun_attempted_shas: string_list(Map.get(existing || %{}, :rerun_attempted_shas, [])),
        dispatched_shas: string_list(Map.get(existing || %{}, :dispatched_shas, [])),
        inserted_at: Map.get(existing || %{}, :inserted_at, now),
        updated_at: now
      }

      Map.merge(existing || %{}, base)
    else
      nil ->
        nil

      other ->
        Logger.debug("discover_ci_check_record skipped issue_id=#{issue.id}: #{inspect(other)}")
        nil
    end
  end

  defp process_ci_check(record, settings, opts, now) when is_map(record) do
    case backoff_active_until(record, now) do
      {:backing_off, next_poll_at} ->
        {:backing_off, Map.get(record, :issue_id), next_poll_at}

      :ready ->
        fetch_and_process_ci(record, settings, opts, now)
    end
  end

  defp fetch_and_process_ci(record, settings, opts, now) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_ci_status(Map.get(record, :pr_url), [cwd: Map.get(record, :workspace_path)] ++ landing_read_opts(record, opts)) do
      {:ok, ci_status} ->
        handle_ci_status(record, ci_status, settings, opts, now)

      {:error, reason} ->
        record_poll_error(record, reason, opts, now)
    end
  end

  # A `Merging` issue's landing waits only on the checks its base branch requires, so its read
  # carries them for `landing_action/1`.
  defp landing_read_opts(record, opts) do
    if landing_read?(record, opts), do: [required_checks: true], else: []
  end

  defp landing_read?(record, opts), do: MapSet.member?(Keyword.get(opts, :landing_issue_ids, MapSet.new()), Map.get(record, :issue_id))

  defp handle_ci_status(record, ci_status, settings, opts, now) do
    ci_status = if rerun_pending?(record, ci_status), do: Map.put(ci_status, :rerun_pending, true), else: ci_status
    ci_status = track_landing_wait(record, ci_status, opts, now)

    case ci_action(ci_status) do
      :closed ->
        cleanup_ci(record, settings, opts, now, "closed")

      :success ->
        mark_ci_green(record, ci_status, settings, opts, now)

      :pending ->
        issue_id = Map.get(record, :issue_id)
        status = if Map.get(ci_status, :rerun_pending), do: "rerun_requested", else: "watching"
        attrs = ci_status_attrs(record, ci_status, %{status: status}, now)

        case complete_ci_update(opts, record, attrs, {:watching, issue_id}) do
          {:watching, ^issue_id} = action -> after_watching(action, record, ci_status, opts, now)
          other -> other
        end

      {:failure, failed_checks} ->
        handle_ci_failure(record, ci_status, failed_checks, settings, opts, now)
    end
  end

  defp handle_ci_failure(record, ci_status, failed_checks, settings, opts, now) do
    commit_sha = Map.get(ci_status, :commit_sha)
    record = reset_for_new_sha(record, commit_sha, opts, now)

    cond do
      Enum.all?(failed_checks, &human_only_check?/1) ->
        await_waiver(record, ci_status, failed_checks, opts, now)

      flaky_retry?(settings) and not rerun_attempted_for_sha?(record, commit_sha) ->
        rerun_failed_ci(record, ci_status, failed_checks, settings, opts, now)

      escalate_ci_failure?(record, settings, commit_sha, opts, now) ->
        escalate_ci_failure(record, ci_status, failed_checks, settings, opts, now)

      Map.get(record, :status) == "escalated" ->
        attrs =
          ci_status_attrs(record, ci_status, %{status: "escalated", failed_checks: failed_checks}, now)

        complete_ci_update(opts, record, attrs, {:already_handled, Map.get(record, :issue_id), commit_sha})

      dispatched_for_sha?(record, commit_sha) ->
        attrs =
          ci_status_attrs(record, ci_status, %{status: "failure_already_handled", failed_checks: failed_checks}, now)

        complete_ci_update(opts, record, attrs, {:already_handled, Map.get(record, :issue_id), commit_sha})

      true ->
        dispatch_ci_failure(record, ci_status, failed_checks, settings, opts, now)
    end
  end

  # A fix run can't clear a human-only check, so the issue stays where it is (the agent that
  # changed the protected path handed it to a person) and no fix attempt is spent. The next
  # green poll resumes the normal flow. A failure stored for an earlier head's fix run is
  # cleared, so it isn't read as pending rework or put into a later prompt.
  defp await_waiver(record, ci_status, failed_checks, opts, now) do
    issue_id = Map.get(record, :issue_id)
    commit_sha = Map.get(ci_status, :commit_sha)

    unless Map.get(record, :status) == "awaiting_waiver" and Map.get(record, :last_observed_sha) == commit_sha do
      Logger.info(
        "CI #{Map.get(record, :issue_identifier)}: only #{Enum.map_join(failed_checks, ", ", &Map.get(&1, :name))} failed; waiting for a person to add the #{@waiver_label} label, no CI-fix run issue_id=#{issue_id} pr_url=#{Map.get(record, :pr_url)} commit_sha=#{commit_sha}"
      )
    end

    waiting = %{status: "awaiting_waiver", failed_checks: failed_checks, ci_failure: nil, log_excerpt: nil}
    attrs = ci_status_attrs(record, ci_status, waiting, now)
    complete_ci_update(opts, record, attrs, {:awaiting_waiver, issue_id, commit_sha})
  end

  # On a new head SHA, the previous SHA's dispatch/rerun history no longer applies:
  # clear it so the new commit gets a fresh dispatch + rerun budget. Lifetime
  # `ci_retry_count` is intentionally preserved so escalation still triggers
  # after enough failed attempts across SHAs (it resets on green).
  defp reset_for_new_sha(record, commit_sha, opts, now) do
    if new_commit_sha?(record, commit_sha) do
      reset_attrs = %{
        dispatched_shas: [],
        rerun_attempted_shas: [],
        rerun_run_id: nil,
        rerun_run_ids: [],
        status: downgrade_status_for_new_sha(Map.get(record, :status)),
        updated_at: now
      }

      run_store = Keyword.get(opts, :run_store, RunStore)

      case update_ci_check(run_store, record, reset_attrs) do
        :ok -> Map.merge(record, reset_attrs)
        _other -> record
      end
    else
      record
    end
  end

  defp new_commit_sha?(record, commit_sha) do
    last_observed = Map.get(record, :last_observed_sha)

    is_binary(commit_sha) and commit_sha != "" and
      is_binary(last_observed) and last_observed != "" and
      last_observed != commit_sha
  end

  defp downgrade_status_for_new_sha("escalated"), do: "watching"
  defp downgrade_status_for_new_sha("escalate_transition_pending"), do: "watching"
  defp downgrade_status_for_new_sha(status), do: status

  defp rerun_failed_ci(record, ci_status, failed_checks, settings, opts, now) do
    github = Keyword.get(opts, :github, PullRequest)
    run_ids = failed_run_ids(failed_checks)
    rerun_run_ids = rerun_run_ids_for_record(record, run_ids)
    pending_run_ids = run_ids -- rerun_run_ids

    case pending_run_ids do
      [_ | _] ->
        case rerun_failed_run_ids(github, pending_run_ids, Map.get(record, :workspace_path)) do
          {:ok, attempted_run_ids} ->
            all_rerun_run_ids = unique_strings(rerun_run_ids ++ attempted_run_ids)

            attrs =
              ci_status_attrs(
                record,
                ci_status,
                %{
                  status: "rerun_requested",
                  failed_checks: failed_checks,
                  rerun_attempted_shas: append_string(Map.get(record, :rerun_attempted_shas, []), Map.get(ci_status, :commit_sha)),
                  rerun_requested_at: now,
                  rerun_run_id: List.first(all_rerun_run_ids),
                  rerun_run_ids: all_rerun_run_ids
                },
                now
              )

            complete_ci_update(opts, record, attrs, {:rerun_requested, Map.get(record, :issue_id), rerun_action_run_ids(all_rerun_run_ids)})

          {:error, {run_id, reason, attempted_run_ids}} ->
            all_rerun_run_ids = unique_strings(rerun_run_ids ++ attempted_run_ids)
            record_rerun_error(record, ci_status, failed_checks, all_rerun_run_ids, run_id, reason, opts, now)
        end

      [] ->
        if run_ids == [] do
          dispatch_ci_failure(record, ci_status, failed_checks, settings, Keyword.put(opts, :missing_run_id, true), now)
        else
          attrs =
            ci_status_attrs(
              record,
              ci_status,
              %{
                status: "rerun_requested",
                failed_checks: failed_checks,
                rerun_attempted_shas: append_string(Map.get(record, :rerun_attempted_shas, []), Map.get(ci_status, :commit_sha)),
                rerun_requested_at: now,
                rerun_run_id: List.first(rerun_run_ids),
                rerun_run_ids: rerun_run_ids
              },
              now
            )

          complete_ci_update(opts, record, attrs, {:rerun_requested, Map.get(record, :issue_id), rerun_action_run_ids(rerun_run_ids)})
        end
    end
  end

  defp rerun_failed_run_ids(github, run_ids, workspace_path) when is_list(run_ids) do
    run_ids
    |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, attempted_run_ids} ->
      case github.rerun_failed(run_id, cwd: workspace_path) do
        :ok ->
          {:cont, {:ok, [run_id | attempted_run_ids]}}

        {:error, reason} ->
          {:halt, {:error, {run_id, reason, Enum.reverse(attempted_run_ids)}}}
      end
    end)
    |> case do
      {:ok, attempted_run_ids} -> {:ok, Enum.reverse(attempted_run_ids)}
      {:error, {_run_id, _reason, _attempted_run_ids}} = error -> error
    end
  end

  defp record_rerun_error(record, _ci_status, _failed_checks, [], run_id, reason, opts, now) do
    record_poll_error(record, {:rerun_failed, run_id, reason}, opts, now)
  end

  defp record_rerun_error(record, ci_status, failed_checks, rerun_run_ids, run_id, reason, opts, now) do
    attrs =
      ci_status_attrs(
        record,
        ci_status,
        %{
          status: "rerun_requested",
          failed_checks: failed_checks,
          rerun_requested_at: now,
          rerun_run_id: List.first(rerun_run_ids),
          rerun_run_ids: rerun_run_ids
        },
        now
      )
      |> Map.merge(error_backoff_attrs(record, {:rerun_failed, run_id, reason}, opts, now))

    case update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs) do
      :ok ->
        {:poll_error, Map.get(record, :issue_id), {:rerun_failed, run_id, reason}}

      {:error, update_reason} ->
        {:poll_error_update_failed, Map.get(record, :issue_id), {:rerun_failed, run_id, reason}, update_reason}
    end
  end

  defp rerun_action_run_ids([run_id]), do: run_id
  defp rerun_action_run_ids(run_ids), do: run_ids

  defp dispatch_ci_failure(record, ci_status, failed_checks, settings, opts, now) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)

    with {:ok, log_excerpt} <- failed_log_excerpt(record, failed_checks, settings, opts),
         :ok <- hold_auto_merge_for_fix(record, ci_status, settings, opts, now) do
      persist_and_dispatch_ci_failure(record, ci_status, failed_checks, opts, now, tracker, issue_id, log_excerpt)
    else
      {:error, reason} -> record_poll_error(record, reason, opts, now)
    end
  end

  # Before a CI-fix run of a `Merging` issue: the fix may push code the approval never covered,
  # so turn GitHub auto-merge off and hold it off until the issue is approved into `Merging`
  # again. While GitHub won't turn it off, the fix waits for the next poll (a red head can't
  # merge meanwhile).
  defp hold_auto_merge_for_fix(record, ci_status, settings, opts, now) do
    issue_id = Map.get(record, :issue_id)

    if MapSet.member?(Keyword.get(opts, :merging_issue_ids, MapSet.new()), issue_id) do
      run_store = Keyword.get(opts, :run_store, RunStore)
      repo_key = Map.get(record, :repo_key) || repo_key_from_opts(opts)
      review = find_pr_review(run_store, repo_key, issue_id)
      previous = review && Map.get(review, :auto_merge)

      case AutoMerge.disable_for_ci_fix(record, ci_status, previous, opts, now) do
        {:ok, auto_merge} ->
          store_auto_merge_hold(run_store, repo_key, review, record, previous, auto_merge)

        {:disabled, auto_merge} ->
          Logger.info(
            "Auto-merge #{Map.get(record, :issue_identifier)}: turned GitHub auto-merge off because CI failed; the fix goes back through review issue_id=#{issue_id} pr_url=#{Map.get(record, :pr_url)} commit_sha=#{auto_merge.head_sha}"
          )

          record_auto_merge_disabled(record, auto_merge)
          comment_auto_merge_disabled(record, settings, opts)
          store_auto_merge_hold(run_store, repo_key, review, record, previous, auto_merge)

        {:error, reason} ->
          Logger.warning(
            "Auto-merge #{Map.get(record, :issue_identifier)}: turning GitHub auto-merge off for the CI fix failed; the fix waits until it is off issue_id=#{issue_id} pr_url=#{Map.get(record, :pr_url)}: #{inspect(reason)}"
          )

          {:error, {:disable_auto_merge_failed, reason}}
      end
    else
      :ok
    end
  end

  defp find_pr_review(run_store, repo_key, issue_id) do
    case list_pr_reviews(run_store, repo_key) do
      {:ok, reviews} -> Enum.find(reviews, &(Map.get(&1, :issue_id) == issue_id))
      {:error, _reason} -> nil
    end
  end

  # The PR poller reads the hold so it doesn't turn auto-merge on again during this `Merging`
  # stay. With no PR review record yet, the poller starts a fresh one on the next approval.
  defp store_auto_merge_hold(_run_store, _repo_key, nil, _record, _previous, _auto_merge), do: :ok

  defp store_auto_merge_hold(run_store, repo_key, review, record, previous, auto_merge) do
    case run_store.update_pr_review(repo_key, Map.get(review, :issue_id), %{auto_merge: auto_merge}) do
      :ok -> AutoMerge.log_transition(record, previous, auto_merge)
      {:error, reason} -> {:error, {:auto_merge_hold_failed, reason}}
    end
  end

  defp record_auto_merge_disabled(record, auto_merge) do
    %{
      event_type: "auto_merge_disabled",
      repo_key: Map.get(record, :repo_key),
      issue_id: Map.get(record, :issue_id),
      issue_identifier: Map.get(record, :issue_identifier),
      pr_url: Map.get(record, :pr_url),
      head_sha: auto_merge.head_sha,
      reason: "ci_failure",
      detail: "GitHub auto-merge turned off because CI failed; the CI fix goes back through review"
    }
    |> AuditLog.record()
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record auto_merge_disabled audit event issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
    end
  end

  defp comment_auto_merge_disabled(record, settings, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)

    case tracker.create_comment(issue_id, AutoMerge.ci_fix_comment(Map.get(record, :pr_url), AutoMerge.rereview?(settings))) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to comment that auto-merge was turned off for a CI fix issue_id=#{issue_id}: #{inspect(reason)}")
    end
  end

  # A failure on an approved (`Merging`) PR is marked `approved`, so a fix run that finds a flake
  # and pushes nothing can hand the PR back to `Merging` once its head is green.
  defp persist_and_dispatch_ci_failure(record, ci_status, failed_checks, opts, now, tracker, issue_id, log_excerpt) do
    retry_count = ci_retry_count(record) + 1
    approved? = MapSet.member?(Keyword.get(opts, :merging_issue_ids, MapSet.new()), issue_id)
    ci_failure = ci_status |> ci_failure_context(failed_checks, log_excerpt) |> Map.put(:approved, approved?)

    attrs =
      ci_status_attrs(
        record,
        ci_status,
        %{
          status: "dispatch_requested",
          target_issue_state: @active_state,
          ci_retry_count: retry_count,
          failed_checks: failed_checks,
          log_excerpt: log_excerpt,
          ci_failure: ci_failure,
          dispatched_shas: append_string(Map.get(record, :dispatched_shas, []), Map.get(ci_status, :commit_sha)),
          last_action: "dispatch",
          last_action_at: now
        },
        now
      )

    case complete_ci_update(opts, record, attrs, :ok) do
      :ok ->
        case tracker.update_issue_state(issue_id, @active_state) do
          :ok ->
            emit_ci_failed(record, ci_status, failed_checks, retry_count, @active_state)
            {:state_transitioned, issue_id, :ci_failure, @active_state}

          {:error, reason} ->
            record_transition_error(record, ci_status, failed_checks, opts, now, "dispatch", reason)
        end

      {:update_error, _issue_id, _reason} = error ->
        error
    end
  end

  defp escalate_ci_failure(record, ci_status, failed_checks, settings, opts, now) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)
    escalation_state = settings.ci.escalation_state || @in_review_state

    context = %{
      escalation_state: escalation_state,
      issue_id: issue_id,
      now: now,
      opts: opts,
      settings: settings,
      tracker: tracker
    }

    case failed_log_excerpt(record, failed_checks, settings, opts) do
      {:ok, log_excerpt} ->
        do_escalate_ci_failure(record, ci_status, failed_checks, context, log_excerpt)

      {:error, reason} ->
        record_poll_error(record, reason, opts, now)
    end
  end

  defp do_escalate_ci_failure(record, ci_status, failed_checks, context, log_excerpt) do
    %{
      escalation_state: escalation_state,
      now: now,
      opts: opts
    } = context

    ci_failure = ci_failure_context(ci_status, failed_checks, log_excerpt)

    pending_attrs =
      ci_status_attrs(
        record,
        ci_status,
        %{
          status: "escalate_transition_pending",
          target_issue_state: escalation_state,
          failed_checks: failed_checks,
          log_excerpt: log_excerpt,
          ci_failure: ci_failure,
          last_action: nil,
          last_action_at: nil
        },
        now
      )

    case complete_ci_update(opts, record, pending_attrs, :ok) do
      :ok ->
        transition_escalated_ci_failure(record, ci_status, failed_checks, context, log_excerpt, ci_failure)

      {:update_error, _issue_id, _reason} = error ->
        error
    end
  end

  defp transition_escalated_ci_failure(record, ci_status, failed_checks, context, log_excerpt, ci_failure) do
    %{
      escalation_state: escalation_state,
      issue_id: issue_id,
      now: now,
      opts: opts,
      tracker: tracker
    } = context

    case tracker.update_issue_state(issue_id, escalation_state) do
      :ok ->
        complete_escalated_ci_failure(record, ci_status, failed_checks, context, log_excerpt, ci_failure)

      {:error, reason} ->
        record_transition_error(record, ci_status, failed_checks, opts, now, "escalate", reason)
    end
  end

  defp complete_escalated_ci_failure(record, ci_status, failed_checks, context, log_excerpt, ci_failure) do
    %{
      escalation_state: escalation_state,
      issue_id: issue_id,
      now: now,
      opts: opts,
      settings: settings
    } = context

    attrs =
      ci_status_attrs(
        record,
        ci_status,
        %{
          status: "escalated",
          target_issue_state: escalation_state,
          failed_checks: failed_checks,
          log_excerpt: log_excerpt,
          ci_failure: ci_failure,
          last_action: "escalate",
          last_action_at: now
        },
        now
      )

    case complete_ci_update(opts, record, attrs, {:escalated, issue_id, escalation_state}) do
      {:escalated, ^issue_id, ^escalation_state} = action ->
        emit_ci_escalated(record, ci_status, failed_checks, settings, escalation_state)
        action

      {:update_error, _issue_id, _reason} = error ->
        error
    end
  end

  defp mark_ci_green(record, ci_status, settings, opts, now) do
    issue_id = Map.get(record, :issue_id)

    if rework_in_progress?(record, opts) do
      attrs =
        ci_status_attrs(
          record,
          ci_status,
          %{
            # CI is green, so this check no longer "owns" the issue even though we
            # defer finalizing until the pending rework lands. Relinquish the
            # failure-derived ownership fields; otherwise ci_owned_issue?/2 keeps
            # the PR-review poller from ever dispatching the rework that would
            # clear this deferral, deadlocking the two pollers.
            status: released_deferred_status(record),
            ci_retry_count: 0,
            failed_checks: [],
            log_excerpt: nil,
            ci_failure: nil,
            last_action: "green_deferred",
            last_action_at: now
          },
          now
        )

      complete_ci_update(opts, record, attrs, {:green_deferred, issue_id, :rework_in_progress})
    else
      attrs =
        ci_status_attrs(
          record,
          ci_status,
          %{
            status: "green",
            ci_retry_count: 0,
            failed_checks: [],
            log_excerpt: nil,
            ci_failure: nil,
            rerun_attempted_shas: [],
            rerun_run_id: nil,
            rerun_run_ids: [],
            dispatched_shas: [],
            last_action: "green",
            last_action_at: now
          },
          now
        )

      case complete_ci_update(opts, record, attrs, {:green, issue_id}) do
        {:green, ^issue_id} = action -> maybe_run_auto_review_qa(action, Map.merge(record, attrs), ci_status, settings, opts)
        other -> other
      end
    end
  end

  # An issue in Auto Review with green CI gets a QA pass (see AutoReview.on_green/5).
  defp maybe_run_auto_review_qa({:green, issue_id} = action, record, ci_status, settings, opts) do
    case Map.get(Keyword.get(opts, :auto_review_issues, %{}), issue_id) do
      %Issue{} = issue -> AutoReview.on_green(issue, record, ci_status, settings, opts)
      nil -> action
    end
  end

  # GitHub runs no `pull_request` workflows on a PR that conflicts with its base, so an Auto Review
  # issue whose PR conflicts and has no checks would wait forever (see AutoReview.on_conflict/4).
  # Side effects of a pending poll, run once the record holds it.
  defp after_watching(action, record, ci_status, opts, now) do
    if Map.get(ci_status, :announce_landing_fallback), do: announce_landing_fallback(record, ci_status, opts, now)
    maybe_send_auto_review_conflict(action, record, ci_status, opts)
  end

  defp maybe_send_auto_review_conflict({:watching, issue_id} = action, record, ci_status, opts) do
    with %Issue{} = issue <- Map.get(Keyword.get(opts, :auto_review_issues, %{}), issue_id),
         true <- Map.get(ci_status, :checks) == [] and PullRequest.conflicting?(ci_status) do
      AutoReview.on_conflict(issue, record, ci_status, opts)
    else
      _other -> action
    end
  end

  # A green CI check must not leave the record in a failure-derived owned status
  # (see ci_owned_record?/1); keep any benign status but drop owned ones back to
  # "watching" so the PR-review poller can take over the deferred rework.
  defp released_deferred_status(record) do
    case Map.get(record, :status) do
      status when status in ["dispatch_requested", "escalated", "escalate_transition_pending", "state_transition_error"] -> "watching"
      status when is_binary(status) -> status
      _ -> "watching"
    end
  end

  defp cleanup_ci(record, settings, opts, now, reason) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = Map.get(record, :repo_key) || repo_key_from_opts(opts)
    issue_id = Map.get(record, :issue_id)
    withdraw_qa_hold_note(record, settings, opts)

    case delete_ci_check(run_store, repo_key, issue_id) do
      :ok ->
        {:cleanup, issue_id, reason}

      {:error, delete_reason} ->
        attrs = %{status: "cleanup_error", error: inspect(delete_reason), updated_at: now}
        complete_ci_update(opts, record, attrs, {:cleanup_error, issue_id, delete_reason})
    end
  end

  # A PR closed or merged while its QA pass was held gets no pass to delete the hold note, so it
  # goes with the record. One that can't be deleted is logged; the record goes all the same.
  defp withdraw_qa_hold_note(%{qa_hold_note: true} = record, settings, opts) do
    issue = %Issue{id: Map.get(record, :issue_id), identifier: Map.get(record, :issue_identifier)}

    case HoldNote.withdraw(issue, [settings: settings] ++ Keyword.take(opts, [:linear_client])) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to remove the QA hold note for #{issue.identifier} after its PR closed: #{inspect(reason)}")
    end
  end

  defp withdraw_qa_hold_note(_record, _settings, _opts), do: :ok

  defp failed_log_excerpt(record, failed_checks, settings, opts) do
    github = Keyword.get(opts, :github, PullRequest)
    run_ids = failed_run_ids(failed_checks)

    cond do
      run_ids != [] ->
        failed_log_excerpts(github, run_ids, Map.get(record, :workspace_path), settings.ci.log_excerpt_lines)

      Keyword.get(opts, :missing_run_id) ->
        {:ok, "No GitHub Actions run id was available for the failed check."}

      true ->
        {:ok, "No GitHub Actions run id was available for the failed check."}
    end
  end

  defp failed_log_excerpts(github, [run_id], workspace_path, line_limit) do
    case github.fetch_failed_log(run_id, cwd: workspace_path) do
      {:ok, log} -> {:ok, log_excerpt(log, line_limit)}
      {:error, reason} -> {:error, {:failed_log_unavailable, run_id, reason}}
    end
  end

  defp failed_log_excerpts(github, run_ids, workspace_path, line_limit) when is_list(run_ids) do
    Enum.reduce_while(run_ids, {:ok, []}, fn run_id, {:ok, excerpts} ->
      case github.fetch_failed_log(run_id, cwd: workspace_path) do
        {:ok, log} ->
          excerpt = "Run #{run_id} failed log:\n#{log_excerpt(log, line_limit)}"
          {:cont, {:ok, [excerpt | excerpts]}}

        {:error, reason} ->
          {:halt, {:error, {:failed_log_unavailable, run_id, reason}}}
      end
    end)
    |> case do
      {:ok, excerpts} -> {:ok, excerpts |> Enum.reverse() |> Enum.join("\n\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ci_status_attrs(record, ci_status, attrs, now) do
    Map.merge(
      %{
        status: Map.get(attrs, :status, Map.get(record, :status, "watching")),
        error: nil,
        consecutive_errors: 0,
        next_poll_at: nil,
        pr_url: Map.get(ci_status, :pr_url) || Map.get(record, :pr_url),
        pr_title: Map.get(ci_status, :pr_title),
        pr_state: Map.get(ci_status, :state),
        head_ref_name: Map.get(ci_status, :head_ref_name),
        is_cross_repository: Map.get(ci_status, :is_cross_repository),
        head_repository: Map.get(ci_status, :head_repository),
        commit_sha: Map.get(ci_status, :commit_sha),
        last_observed_sha: Map.get(ci_status, :commit_sha),
        last_observed_conclusion: conclusion_for_status(ci_status),
        landing_ready_sha: if(landing_action(ci_status) == :success, do: Map.get(ci_status, :commit_sha)),
        updated_at: now
      }
      |> Map.merge(Map.get(ci_status, :landing_wait, %{})),
      attrs
    )
  end

  # How long a `Merging` head has waited on its checks: every landing read of the same head that
  # `landing_action/1` leaves pending keeps the wait, and any other read ends it. Past
  # `@landing_fallback_ms`, a head that may land on the checks still pending
  # (`landing_fallback_eligible?/1`) is let past: `landing_ready_sha` names it, so the orchestrator
  # releases the landing agent, and its merge and CI wait read the mark through
  # `put_landing_fallback/3`. The first time a wait lets a head past, it is marked
  # `:announce_landing_fallback`: once the record holds `landing_fallback_sha`, the checks it skips
  # are logged and the issue gets one comment.
  defp track_landing_wait(record, ci_status, opts, now) do
    sha = Map.get(ci_status, :commit_sha)

    if landing_read?(record, opts) and is_binary(sha) and landing_action(ci_status) == :pending do
      since = if Map.get(record, :landing_wait_sha) == sha, do: Map.get(record, :landing_wait_since) || now, else: now
      wait = %{landing_wait_sha: sha, landing_wait_since: since, landing_fallback_sha: nil}

      if DateTime.diff(now, since, :millisecond) >= @landing_fallback_ms and landing_fallback_eligible?(ci_status),
        do: land_past_pending_checks(record, ci_status, wait),
        else: Map.put(ci_status, :landing_wait, wait)
    else
      Map.put(ci_status, :landing_wait, %{landing_wait_sha: nil, landing_wait_since: nil, landing_fallback_sha: nil})
    end
  end

  defp land_past_pending_checks(record, ci_status, %{landing_wait_sha: sha} = wait) do
    ci_status
    |> Map.put(:landing_fallback, true)
    |> Map.put(:landing_wait, %{wait | landing_fallback_sha: sha})
    |> Map.put(:announce_landing_fallback, Map.get(record, :landing_fallback_sha) != sha)
  end

  defp announce_landing_fallback(record, ci_status, opts, now) do
    issue_id = Map.get(record, :issue_id)
    pr_url = Map.get(ci_status, :pr_url) || Map.get(record, :pr_url)
    sha = Map.get(ci_status, :commit_sha)
    minutes = div(DateTime.diff(now, ci_status.landing_wait.landing_wait_since, :second), 60)
    skipped = ci_status |> Map.get(:checks, []) |> Enum.reject(&passed_check?/1) |> Enum.map(&Map.get(&1, :name)) |> Enum.uniq()

    Logger.warning(
      "Landing without the checks still pending after #{minutes} min in Merging; the base branch requires none: issue_id=#{issue_id} issue_identifier=#{Map.get(record, :issue_identifier)} pr_url=#{pr_url} commit_sha=#{sha} skipped=#{Enum.join(skipped, ", ")}"
    )

    tracker = Keyword.get(opts, :tracker, Tracker)

    case tracker.create_comment(issue_id, landing_fallback_comment(pr_url, ci_status, skipped, minutes)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to comment that a landing skips pending checks issue_id=#{issue_id}: #{inspect(reason)}")
    end
  end

  defp landing_fallback_comment(pr_url, ci_status, skipped, minutes) do
    waiting_on =
      case skipped do
        [] -> "a workflow run that has not finished"
        names -> Enum.map_join(names, ", ", &"`#{&1}`")
      end

    "Symphony stopped waiting on CI to land #{pr_url || "this PR"} at `#{String.slice(Map.get(ci_status, :commit_sha), 0, 7)}`: " <>
      "after #{minutes} min in Merging it was still waiting on #{waiting_on}. " <>
      "The base branch `#{Map.get(ci_status, :base_ref_name)}` requires no checks, none failed and at least one passed, " <>
      "so Symphony lands it without waiting for the rest."
  end

  defp record_poll_error(record, reason, opts, now) do
    attrs = poll_error_attrs(record, reason, opts, now)

    case update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs) do
      :ok ->
        {:poll_error, Map.get(record, :issue_id), reason}

      {:error, update_reason} ->
        {:poll_error_update_failed, Map.get(record, :issue_id), reason, update_reason}
    end
  end

  defp record_transition_error(record, ci_status, failed_checks, opts, now, action, reason) do
    attrs =
      ci_status_attrs(
        record,
        ci_status,
        %{
          status: "state_transition_error",
          ci_retry_count: ci_retry_count(record),
          dispatched_shas: string_list(Map.get(record, :dispatched_shas, [])),
          failed_checks: failed_checks,
          last_action: action,
          last_action_at: nil
        },
        now
      )
      |> Map.merge(error_backoff_attrs(record, reason, opts, now))

    case update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs) do
      :ok ->
        {:state_transition_error, Map.get(record, :issue_id), String.to_atom(action), reason}

      {:error, update_reason} ->
        {:state_transition_error_update_failed, Map.get(record, :issue_id), String.to_atom(action), reason, update_reason}
    end
  end

  defp complete_ci_update(opts, record, attrs, success_action) do
    case update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs) do
      :ok -> success_action
      {:error, reason} -> {:update_error, Map.get(record, :issue_id), reason}
    end
  end

  defp update_ci_check(run_store, record, attrs) do
    issue_id = Map.get(record, :issue_id)

    case Map.get(record, :repo_key) do
      repo_key when is_binary(repo_key) ->
        case update_ci_check_record(run_store, repo_key, issue_id, attrs) do
          :ok ->
            :ok

          {:error, :ci_check_not_found} ->
            put_ci_check(run_store, record |> Map.merge(attrs) |> Map.put(:repo_key, repo_key))

          {:error, reason} ->
            Logger.warning("Failed to update CI check record issue_id=#{issue_id} target_status=#{inspect(Map.get(attrs, :status))}: #{inspect(reason)}")
            {:error, {:update_ci_check_failed, reason}}
        end

      _repo_key ->
        {:error, :missing_repo_key}
    end
  end

  defp put_ci_check(run_store, record) do
    case run_store.put_ci_check(record) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_ci_check(run_store, repo_key, issue_id) do
    case delete_ci_check_record(run_store, repo_key, issue_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_key_from_opts(opts), do: Keyword.get_lazy(opts, :repo_key, &Config.repo_key!/0)

  defp repo_keys_from_opts(opts) do
    case Keyword.fetch(opts, :repo_key) do
      {:ok, repo_key} when is_binary(repo_key) and repo_key != "" ->
        [repo_key]

      _ ->
        configured_repo_keys()
    end
  end

  defp configured_repo_keys do
    case Config.repos() do
      {:ok, repos} ->
        repos
        |> Enum.map(&Map.get(&1, :name))
        |> Enum.reject(&(&1 in [nil, ""]))

      {:error, _reason} ->
        [Config.repo_key!()]
    end
  end

  defp update_ci_check_record(run_store, repo_key, issue_id, attrs) do
    cond do
      function_exported?(run_store, :update_ci_check, 3) ->
        run_store.update_ci_check(repo_key, issue_id, attrs)

      function_exported?(run_store, :update_ci_check, 2) ->
        run_store.update_ci_check(issue_id, attrs)

      true ->
        {:error, :ci_checks_unsupported}
    end
  end

  defp delete_ci_check_record(run_store, repo_key, issue_id) do
    cond do
      function_exported?(run_store, :delete_ci_check, 2) ->
        run_store.delete_ci_check(repo_key, issue_id)

      function_exported?(run_store, :delete_ci_check, 1) ->
        run_store.delete_ci_check(issue_id)

      true ->
        {:error, :ci_checks_unsupported}
    end
  end

  @doc false
  @spec ci_action(map()) :: :closed | :pending | :success | {:failure, [map()]}
  def ci_action(ci_status) do
    cond do
      closed_pr_state?(Map.get(ci_status, :state)) ->
        :closed

      failed_checks(ci_status) != [] ->
        {:failure, failed_checks(ci_status)}

      pending_checks?(ci_status) or Map.get(ci_status, :rerun_pending) == true or unfinished_run?(ci_status) ->
        :pending

      success_checks?(ci_status) ->
        :success

      true ->
        :pending
    end
  end

  @doc """
  What a landing reads from `ci_status`: `ci_action/1`, except that a pending head whose base
  branch requires checks (`:required_checks`, see `PullRequest.fetch_ci_status/2`) lands once
  every required check reported and passed, while checks the branch doesn't require still run. A
  failed check holds it, required or not. Without required checks, it waits on every check, until
  the poller has waited on them for 15 minutes in `Merging` (`:landing_fallback`, see
  `put_landing_fallback/3`): a head whose base branch requires no checks then lands once one check
  passed, while no rerun of a failed job is starting.
  """
  @spec landing_action(map()) :: :closed | :pending | :success | {:failure, [map()]}
  def landing_action(ci_status) do
    case ci_action(ci_status) do
      :pending -> if landing_ready?(ci_status), do: :success, else: :pending
      action -> action
    end
  end

  defp landing_ready?(%{required_checks: [_ | _] = required} = ci_status), do: required_checks_passed?(ci_status, required)
  defp landing_ready?(ci_status), do: Map.get(ci_status, :landing_fallback) == true and landing_fallback_eligible?(ci_status)

  # A branch that requires checks lands once they pass, and one whose requirements couldn't be read
  # can't tell which checks matter, so only a branch read as requiring none lands past its checks.
  # A head where nothing passed yet (a runner outage) has nothing to land on.
  defp landing_fallback_eligible?(ci_status) do
    Map.get(ci_status, :required_checks) == [] and Map.get(ci_status, :rerun_pending) != true and
      ci_status |> Map.get(:checks, []) |> Enum.any?(&passed_check?/1)
  end

  defp required_checks_passed?(ci_status, required) do
    checks = Map.get(ci_status, :checks, [])

    Enum.all?(required, fn name ->
      named = Enum.filter(checks, &(Map.get(&1, :name) == name))
      named != [] and Enum.all?(named, &passed_check?/1)
    end)
  end

  @doc """
  Marks `ci_status` `rerun_pending`, which `ci_action/1` reads as `:pending`, while the poller's
  rerun of the failed jobs on this head has not reported yet. Until GitHub's new attempt queues
  them, the rerun checks drop out of the rollup and only the checks that passed are left, so the
  head would read green. The mark holds while the record is `rerun_requested` for this head and
  a check it reran is missing from the rollup.
  """
  @spec put_rerun_pending(map(), String.t() | nil, keyword()) :: map()
  def put_rerun_pending(ci_status, issue_id, opts \\ []) when is_map(ci_status) do
    if rerun_pending?(find_issue_ci_check(issue_id, opts), ci_status), do: Map.put(ci_status, :rerun_pending, true), else: ci_status
  end

  @doc """
  Marks `ci_status` `landing_fallback` when the poller let this head past the checks it was still
  waiting on after 15 minutes in `Merging`. `landing_action/1` reads the mark as `:success` only
  while this read still qualifies, so a check that failed since holds the landing.
  """
  @spec put_landing_fallback(map(), String.t() | nil, keyword()) :: map()
  def put_landing_fallback(ci_status, issue_id, opts \\ []) when is_map(ci_status) do
    sha = Map.get(ci_status, :commit_sha)
    record = find_issue_ci_check(issue_id, opts) || %{}

    if is_binary(sha) and Map.get(record, :landing_fallback_sha) == sha, do: Map.put(ci_status, :landing_fallback, true), else: ci_status
  end

  defp find_issue_ci_check(issue_id, opts) when is_binary(issue_id) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    Enum.find_value(repo_keys_from_opts(opts), &find_ci_check(run_store, &1, issue_id))
  end

  defp find_issue_ci_check(_issue_id, _opts), do: nil

  defp rerun_pending?(%{status: "rerun_requested"} = record, ci_status) do
    commit_sha = Map.get(ci_status, :commit_sha)
    reported = ci_status |> Map.get(:checks, []) |> MapSet.new(&Map.get(&1, :name))

    is_binary(commit_sha) and commit_sha == Map.get(record, :last_observed_sha) and
      record |> Map.get(:failed_checks, []) |> Enum.any?(&(not MapSet.member?(reported, Map.get(&1, :name))))
  end

  defp rerun_pending?(_record, _ci_status), do: false

  @doc "Whether only a person can clear this failed check, so a CI-fix run must leave it alone."
  @spec human_only_check?(map()) :: boolean()
  def human_only_check?(check) when is_map(check), do: Map.get(check, :name) in @human_only_checks

  @doc "The label a person adds to waive the `protected paths` check."
  @spec waiver_label() :: String.t()
  def waiver_label, do: @waiver_label

  defp failed_checks(ci_status) do
    ci_status
    |> Map.get(:checks, [])
    |> Enum.filter(&failure_check?/1)
  end

  defp failure_check?(check) do
    check
    |> Map.get(:conclusion)
    |> normalize_status()
    |> then(&(&1 in ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]))
  end

  defp pending_checks?(%{checks: []}), do: true

  defp pending_checks?(ci_status) do
    ci_status
    |> Map.get(:checks, [])
    |> Enum.any?(fn check ->
      status = normalize_status(Map.get(check, :status))
      conclusion = normalize_status(Map.get(check, :conclusion))

      status not in ["COMPLETED", "SUCCESS", "FAILURE", "ERROR"] or conclusion in [nil, ""]
    end)
  end

  # A workflow run that reported checks to the rollup but has not completed (a rerun's new
  # attempt, a job with `needs:` not created yet) can still fail. Runs with no check in the rollup
  # (an environment approval, another event's run) are left out, so they can't hold a head forever.
  defp unfinished_run?(ci_status) do
    run_ids = ci_status |> Map.get(:checks, []) |> MapSet.new(&Map.get(&1, :run_id))

    ci_status
    |> Map.get(:workflow_runs, [])
    |> Enum.any?(&(MapSet.member?(run_ids, Map.get(&1, :id)) and Map.get(&1, :status) != "COMPLETED"))
  end

  defp success_checks?(ci_status) do
    checks = Map.get(ci_status, :checks, [])

    checks != [] and Enum.all?(checks, &passed_check?/1)
  end

  defp passed_check?(check), do: normalize_status(Map.get(check, :conclusion)) in ["SUCCESS", "NEUTRAL", "SKIPPED"]

  defp conclusion_for_status(ci_status) do
    case ci_action(ci_status) do
      :success -> "SUCCESS"
      :pending -> "IN_PROGRESS"
      :closed -> "CLOSED"
      {:failure, _checks} -> "FAILURE"
    end
  end

  defp log_excerpt(log, line_limit) when is_binary(log) and is_integer(line_limit) and line_limit > 0 do
    log
    |> sanitize_utf8()
    |> String.split("\n")
    |> Enum.take(-line_limit)
    |> prefer_error_start()
    |> Enum.join("\n")
  end

  defp log_excerpt(_log, _line_limit), do: ""

  defp sanitize_utf8(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: replace_invalid_bytes(binary, <<>>)
  end

  defp replace_invalid_bytes(<<>>, acc), do: acc

  defp replace_invalid_bytes(<<char::utf8, rest::binary>>, acc) do
    replace_invalid_bytes(rest, <<acc::binary, char::utf8>>)
  end

  defp replace_invalid_bytes(<<_byte, rest::binary>>, acc) do
    replace_invalid_bytes(rest, <<acc::binary, ??::utf8>>)
  end

  defp prefer_error_start(lines) do
    case Enum.find_index(lines, &error_line?/1) do
      nil -> lines
      index -> Enum.drop(lines, index)
    end
  end

  defp error_line?(line) when is_binary(line) do
    String.match?(line, ~r/(error|failed|failure|exception|stacktrace|traceback|panic)/i)
  end

  defp failed_run_ids(failed_checks) do
    failed_checks
    |> Enum.map(fn check ->
      case Map.get(check, :run_id) do
        run_id when is_binary(run_id) and run_id != "" -> run_id
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp ci_failure_context(ci_status, failed_checks, log_excerpt) do
    %{
      commit_sha: Map.get(ci_status, :commit_sha),
      head_ref_name: Map.get(ci_status, :head_ref_name),
      is_cross_repository: Map.get(ci_status, :is_cross_repository),
      head_repository: Map.get(ci_status, :head_repository),
      failed_checks: failed_checks,
      log_excerpt: log_excerpt
    }
  end

  defp normalize_ci_failure(ci_failure) when is_map(ci_failure) do
    commit_sha = ci_failure_value(ci_failure, :commit_sha)
    failed_checks = ci_failure_value(ci_failure, :failed_checks)
    log_excerpt = ci_failure_value(ci_failure, :log_excerpt)

    if is_nil(commit_sha) and is_nil(failed_checks) and is_nil(log_excerpt) do
      nil
    else
      %{
        commit_sha: commit_sha,
        head_ref_name: ci_failure_value(ci_failure, :head_ref_name),
        is_cross_repository: ci_failure_value(ci_failure, :is_cross_repository),
        head_repository: ci_failure_value(ci_failure, :head_repository),
        failed_checks: failed_checks,
        log_excerpt: log_excerpt,
        approved: ci_failure_value(ci_failure, :approved) == true
      }
    end
  end

  defp normalize_ci_failure(_ci_failure), do: nil

  defp ci_failure_value(ci_failure, field) do
    case Map.fetch(ci_failure, field) do
      {:ok, value} -> value
      :error -> Map.get(ci_failure, Atom.to_string(field))
    end
  end

  defp emit_ci_failed(record, ci_status, failed_checks, retry_count, target_state) do
    Notifications.emit_event(
      :ci_failed,
      notification_attrs(record, ci_status, failed_checks, target_state, "CI failed; dispatching agent", %{
        retry_count: retry_count
      })
    )
  end

  defp emit_ci_escalated(record, ci_status, failed_checks, settings, target_state) do
    Notifications.emit_event(
      :ci_escalated,
      notification_attrs(record, ci_status, failed_checks, target_state, "CI failed after #{settings.ci.max_retries} agent dispatches; escalation required", %{
        retry_count: ci_retry_count(record),
        max_retries: settings.ci.max_retries,
        escalation_state: target_state
      })
    )
  end

  defp notification_attrs(record, ci_status, failed_checks, target_state, reason, metadata) do
    %{
      issue_id: Map.get(record, :issue_id),
      issue_identifier: Map.get(record, :issue_identifier),
      issue_url: Map.get(record, :issue_url),
      pr_url: Map.get(ci_status, :pr_url) || Map.get(record, :pr_url),
      pr_title: Map.get(ci_status, :pr_title),
      state: target_state,
      reason: reason,
      metadata:
        Map.merge(metadata, %{
          source: "ci_poller",
          commit_sha: Map.get(ci_status, :commit_sha),
          failed_checks: Enum.map(failed_checks, &Map.take(&1, [:name, :run_id, :conclusion]))
        })
    }
  end

  defp flaky_retry?(settings), do: Map.get(settings.ci, :flaky_retry, true)

  defp rerun_attempted_for_sha?(record, sha), do: sha in string_list(Map.get(record, :rerun_attempted_shas, []))
  defp dispatched_for_sha?(record, sha), do: sha in string_list(Map.get(record, :dispatched_shas, []))

  # Escalate once retries are exhausted, but only when no rework is in flight and
  # the latest dispatch has had time to start (see recently_dispatched?/3).
  defp escalate_ci_failure?(record, settings, commit_sha, opts, now) do
    ci_retry_count(record) >= settings.ci.max_retries and
      Map.get(record, :status) != "escalated" and
      not rework_in_progress?(record, opts) and
      not recently_dispatched?(record, commit_sha, now)
  end

  # A dispatch for this SHA landed within the start-grace window, so the rework
  # agent may not have reached "running" yet. Hold off escalation until either it
  # does (covered by rework_in_progress?/2) or the grace window lapses, so the
  # final retry's just-dispatched agent is not escalated out from under itself.
  defp recently_dispatched?(record, commit_sha, now) do
    dispatched_for_sha?(record, commit_sha) and
      Map.get(record, :last_action) == "dispatch" and
      within_dispatch_grace?(Map.get(record, :last_action_at), now)
  end

  defp within_dispatch_grace?(%DateTime{} = last_action_at, %DateTime{} = now) do
    DateTime.diff(now, last_action_at, :millisecond) < @dispatch_start_grace_ms
  end

  defp within_dispatch_grace?(_last_action_at, _now), do: false

  defp ci_owned_record?(record) do
    ci_retry_count(record) > 0 or
      Map.get(record, :status) in ["dispatch_requested", "escalated", "escalate_transition_pending", "state_transition_error"]
  end

  defp rework_in_progress?(record, opts) do
    issue_id = Map.get(record, :issue_id)
    repo_key = Map.get(record, :repo_key) || repo_key_from_opts(opts)

    active_agent_run?(issue_id, repo_key, opts) or pending_rework_review?(issue_id, repo_key, opts)
  end

  # PR reviews are prefetched once per poll cycle so the green-deferral and
  # escalation paths do not rescan storage for every CI check (see
  # rework_in_progress?/2). Runs are read per issue through the run index.
  defp put_prefetched_rework_sources(opts, _run_store, _repo_key, []), do: opts

  defp put_prefetched_rework_sources(opts, run_store, repo_key, _checks) do
    sources = %{
      repo_key: repo_key,
      reviews: ok_list_or_nil(list_pr_reviews(run_store, repo_key))
    }

    Keyword.put(opts, :prefetched_rework_sources, sources)
  end

  defp ok_list_or_nil({:ok, list}) when is_list(list), do: list
  defp ok_list_or_nil(_other), do: nil

  defp prefetched_rework_source(opts, key, repo_key) do
    case Keyword.get(opts, :prefetched_rework_sources) do
      %{repo_key: ^repo_key} = sources ->
        case Map.get(sources, key) do
          list when is_list(list) -> {:ok, list}
          _ -> :miss
        end

      _ ->
        :miss
    end
  end

  defp active_agent_run?(issue_id, repo_key, opts) when is_binary(issue_id) and is_binary(repo_key) do
    case list_issue_runs(Keyword.get(opts, :run_store, RunStore), repo_key, issue_id) do
      {:ok, runs} -> Enum.any?(runs, &(Map.get(&1, :status) == "running"))
      {:error, _reason} -> false
    end
  end

  defp active_agent_run?(_issue_id, _repo_key, _opts), do: false

  defp pending_rework_review?(issue_id, repo_key, opts) when is_binary(issue_id) and is_binary(repo_key) do
    reviews_result =
      case prefetched_rework_source(opts, :reviews, repo_key) do
        {:ok, reviews} -> {:ok, reviews}
        :miss -> list_pr_reviews(Keyword.get(opts, :run_store, RunStore), repo_key)
      end

    case reviews_result do
      {:ok, reviews} ->
        Enum.any?(reviews, fn review ->
          Map.get(review, :issue_id) == issue_id and
            pending_reviewer_comments?(Map.get(review, :pending_reviewer_comments))
        end)

      {:error, _reason} ->
        false
    end
  end

  defp pending_rework_review?(_issue_id, _repo_key, _opts), do: false

  defp pending_reviewer_comments?(comments) when is_list(comments), do: comments != []
  defp pending_reviewer_comments?(_comments), do: false

  defp ci_retry_count(record) when is_map(record) do
    case Map.get(record, :ci_retry_count) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp first_pr_url(%Issue{pr_urls: [url | _rest]}) when is_binary(url), do: url
  defp first_pr_url(_issue), do: nil

  # The issue's newest finished run, or `{:error, reason}` when its runs can't be read.
  defp latest_run_for_issue(run_store, repo_key, issue_id) do
    with {:ok, runs} <- list_issue_runs(run_store, repo_key, issue_id) do
      runs
      |> Enum.filter(&ci_run?/1)
      |> Enum.max_by(&run_started_at_sort_key/1, fn -> nil end)
    end
  end

  defp ci_run?(run), do: Map.get(run, :status) in ["success", "stopped"] and is_binary(Map.get(run, :workspace_path))

  defp run_started_at_sort_key(run) do
    case Map.get(run, :started_at) do
      %DateTime{} = started_at -> DateTime.to_unix(started_at, :microsecond)
      _ -> 0
    end
  end

  defp list_issue_runs(run_store, repo_key, issue_id) do
    if function_exported?(run_store, :list_issue_runs, 2) do
      case run_store.list_issue_runs(repo_key, issue_id) do
        runs when is_list(runs) -> {:ok, runs}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :runs_unsupported}
    end
  end

  defp list_ci_checks(run_store, repo_key) do
    cond do
      function_exported?(run_store, :list_ci_checks, 1) ->
        case run_store.list_ci_checks(repo_key) do
          checks when is_list(checks) -> {:ok, checks}
          {:error, reason} -> {:error, reason}
        end

      function_exported?(run_store, :list_ci_checks, 0) ->
        case run_store.list_ci_checks() do
          checks when is_list(checks) -> {:ok, checks}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :ci_checks_unsupported}
    end
  end

  defp list_pr_reviews(run_store, repo_key) do
    cond do
      function_exported?(run_store, :list_pr_reviews, 1) ->
        case run_store.list_pr_reviews(repo_key) do
          reviews when is_list(reviews) -> {:ok, reviews}
          {:error, reason} -> {:error, reason}
        end

      function_exported?(run_store, :list_pr_reviews, 0) ->
        case run_store.list_pr_reviews() do
          reviews when is_list(reviews) -> {:ok, reviews}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :pr_reviews_unsupported}
    end
  end

  defp append_string(values, value) when is_binary(value) and value != "" do
    values
    |> string_list()
    |> Kernel.++([value])
    |> Enum.uniq()
  end

  defp append_string(values, _value), do: string_list(values)

  defp rerun_run_ids_for_record(record, current_run_ids) do
    record
    |> Map.get(:rerun_run_ids, [])
    |> string_list()
    |> Enum.filter(&(&1 in current_run_ids))
    |> Enum.uniq()
  end

  defp unique_strings(values) when is_list(values) do
    values
    |> string_list()
    |> Enum.uniq()
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_values), do: []

  defp closed_pr_state?(state) do
    state
    |> normalize_status()
    |> then(&(&1 in @closed_pr_states))
  end

  defp normalize_status(value) when is_binary(value) do
    value |> String.trim() |> String.upcase()
  end

  defp normalize_status(_value), do: nil

  defp poll_error_attrs(record, reason, opts, now) do
    error_backoff_attrs(record, reason, opts, now)
  end

  defp error_backoff_attrs(record, reason, opts, now) do
    consecutive_errors = consecutive_errors(record) + 1

    attrs = %{
      error: inspect(reason),
      consecutive_errors: consecutive_errors,
      updated_at: now
    }

    if consecutive_errors >= @github_error_backoff_threshold do
      Map.put(attrs, :next_poll_at, DateTime.add(now, github_error_backoff_ms(consecutive_errors, opts), :millisecond))
    else
      Map.put(attrs, :next_poll_at, nil)
    end
  end

  defp consecutive_errors(record) do
    case Map.get(record, :consecutive_errors) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp backoff_active_until(record, now) do
    case Map.get(record, :next_poll_at) do
      %DateTime{} = next_poll_at ->
        if DateTime.compare(next_poll_at, now) == :gt do
          {:backing_off, next_poll_at}
        else
          :ready
        end

      _ ->
        :ready
    end
  end

  defp github_error_backoff_ms(consecutive_errors, opts) do
    exponent = max(consecutive_errors - @github_error_backoff_threshold, 0)

    poll_interval_ms(opts)
    |> Kernel.*(Integer.pow(2, exponent))
    |> min(@max_github_error_backoff_ms)
  end

  defp poll_cycle_result(opts) do
    case poll_once(opts) do
      {:ok, summary} ->
        Logger.debug("CI poll completed: #{inspect(summary)}")
        log_poll_action_warnings(summary)
        {:ok, summary}

      {:error, reason} ->
        {:error, "CI poll failed: #{inspect(reason)}", reason}
    end
  rescue
    exception ->
      formatted = Exception.format(:error, exception, __STACKTRACE__)
      {:error, "CI poll raised: #{formatted}", exception}
  catch
    kind, reason ->
      formatted = Exception.format(kind, reason, __STACKTRACE__)
      {:error, "CI poll failed with #{kind}: #{formatted}", {kind, reason}}
  end

  defp handle_poll_success(%State{consecutive_failures: 0} = state), do: reset_poll_failure_state(state)

  defp handle_poll_success(%State{} = state) do
    Logger.info("CI poll recovered after #{state.consecutive_failures} consecutive failures")
    maybe_record_poller_recovered(state)
    reset_poll_failure_state(state)
  end

  defp handle_poll_failure(%State{} = state, message, reason) do
    consecutive_failures = state.consecutive_failures + 1
    backoff_ms = poll_cycle_backoff_ms(state, consecutive_failures)
    degraded? = state.degraded? or consecutive_failures >= poller_degraded_threshold(state.opts)

    maybe_log_poll_failure(state, consecutive_failures, backoff_ms, message)
    maybe_record_poller_degraded(state, consecutive_failures, backoff_ms, reason)

    {%{
       state
       | consecutive_failures: consecutive_failures,
         current_backoff_ms: backoff_ms,
         degraded?: degraded?
     }, backoff_ms}
  end

  defp reset_poll_failure_state(%State{} = state) do
    %{state | consecutive_failures: 0, current_backoff_ms: nil, degraded?: false}
  end

  defp maybe_log_poll_failure(%State{consecutive_failures: 0}, _consecutive_failures, _backoff_ms, message) do
    Logger.error(message)
  end

  defp maybe_log_poll_failure(%State{current_backoff_ms: previous_backoff_ms}, consecutive_failures, backoff_ms, _message)
       when is_integer(previous_backoff_ms) and backoff_ms > previous_backoff_ms do
    Logger.error("CI poll backing off after #{consecutive_failures} consecutive failures; next poll in #{backoff_ms}ms")
  end

  defp maybe_log_poll_failure(_state, _consecutive_failures, _backoff_ms, _message), do: :ok

  defp maybe_record_poller_degraded(%State{degraded?: true}, _consecutive_failures, _backoff_ms, _reason), do: :ok

  defp maybe_record_poller_degraded(%State{} = state, consecutive_failures, backoff_ms, reason) do
    if consecutive_failures >= poller_degraded_threshold(state.opts) do
      record_poller_audit(
        %{
          event_type: "poller_degraded",
          poller: "ci",
          status: "degraded",
          consecutive_failures: consecutive_failures,
          current_backoff_ms: backoff_ms,
          reason: inspect(reason)
        },
        state.opts
      )
    end
  end

  defp maybe_record_poller_recovered(%State{degraded?: true} = state) do
    record_poller_audit(
      %{
        event_type: "poller_recovered",
        poller: "ci",
        status: "recovered",
        consecutive_failures: state.consecutive_failures,
        previous_backoff_ms: state.current_backoff_ms
      },
      state.opts
    )
  end

  defp maybe_record_poller_recovered(_state), do: :ok

  defp record_poller_audit(attrs, opts) do
    attrs
    |> Map.put(:repo_key, safe_repo_key(opts))
    |> AuditLog.record()
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record CI poller audit event: #{inspect(reason)}")
    end
  end

  defp poll_cycle_backoff_ms(%State{opts: opts}, consecutive_failures) do
    exponent = max(consecutive_failures - 1, 0)

    opts
    |> poller_backoff_base_ms()
    |> Kernel.*(Integer.pow(2, exponent))
    |> min(poller_max_backoff_ms(opts))
  end

  defp poller_status(%State{} = state) do
    %{
      status: if(state.degraded?, do: :degraded, else: :running),
      consecutive_failures: state.consecutive_failures,
      current_backoff_ms: state.current_backoff_ms,
      poll_interval_ms: state.poll_interval_ms,
      webhooks: Map.merge(webhook_settings_status(state.opts), state.webhooks)
    }
  end

  defp webhook_settings_status(opts) do
    webhooks =
      case Keyword.get(opts, :settings) do
        %{github: %{webhooks: webhooks}} -> webhooks
        _settings -> Webhook.settings()
      end

    %{enabled: webhooks.enabled, relay: webhooks.relay}
  end

  defp publish_status(%State{} = state) do
    ensure_status_table()
    :ets.insert(@status_table, {:current, poller_status(state)})
    :ok
  end

  defp ensure_status_table do
    case :ets.whereis(@status_table) do
      :undefined ->
        try do
          :ets.new(@status_table, [:set, :public, :named_table, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _table ->
        :ok
    end
  end

  defp poller_opts(opts, poll_interval_ms) do
    poller = poller_config(opts)

    opts
    |> Keyword.put(:poll_interval_ms, poll_interval_ms)
    |> Keyword.put(:poller_backoff_base_ms, positive_integer(Keyword.get(opts, :poller_backoff_base_ms)) || positive_integer(Map.get(poller, :backoff_base_ms)) || poll_interval_ms)
    |> Keyword.put(:poller_max_backoff_ms, positive_integer(Keyword.get(opts, :poller_max_backoff_ms)) || positive_integer(Map.get(poller, :max_backoff_ms)) || 300_000)
    |> Keyword.put(:poller_degraded_threshold, positive_integer(Keyword.get(opts, :poller_degraded_threshold)) || positive_integer(Map.get(poller, :degraded_threshold)) || 3)
  end

  defp poller_config(opts) do
    settings = Keyword.get(opts, :settings) || Config.settings!()
    Map.get(settings, :poller, %{})
  end

  defp poller_backoff_base_ms(opts), do: Keyword.fetch!(opts, :poller_backoff_base_ms)
  defp poller_max_backoff_ms(opts), do: Keyword.fetch!(opts, :poller_max_backoff_ms)
  defp poller_degraded_threshold(opts), do: Keyword.fetch!(opts, :poller_degraded_threshold)

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp safe_repo_key(opts) do
    Keyword.get(opts, :repo_key) || Application.get_env(:symphony_elixir, :primary_repo_name)
  end

  defp log_poll_action_warnings(%{actions: actions}) when is_list(actions) do
    Enum.each(actions, &log_poll_action_warning/1)
  end

  defp log_poll_action_warning({:poll_error, issue_id, reason}) do
    Logger.warning("CI poll error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:state_transition_error, issue_id, action, reason}) do
    Logger.warning("CI transition error issue_id=#{issue_id} action=#{action}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:cleanup_error, issue_id, reason}) do
    Logger.warning("CI cleanup error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning(_action), do: :ok

  defp schedule_poll(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.timer_ref) do
      Process.cancel_timer(state.timer_ref)
    end

    %{state | timer_ref: Process.send_after(self(), :poll, delay_ms)}
  end

  defp poll_interval_ms(opts) do
    case Keyword.get(opts, :poll_interval_ms) do
      interval when is_integer(interval) and interval > 0 ->
        interval

      _ ->
        settings = Keyword.get(opts, :settings) || Config.settings!()
        settings.ci.poll_interval_ms || settings.pr_review.poll_interval_ms || settings.polling.interval_ms
    end
  end
end
