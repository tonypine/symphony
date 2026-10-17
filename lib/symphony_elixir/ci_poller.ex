defmodule SymphonyElixir.CiPoller do
  @moduledoc """
  Polling-mode GitHub Actions CI poller: it reads the CI of each watched ticket's PR head and keeps
  what it saw (the head, its conclusion, its failed checks, and whether it may land) for a landing
  agent's CI wait (`observed_head/2`, `landing_ready_head/2`). It decides nothing: the PR and CI
  watcher (`SymphonyElixir.PrWatch`) reruns, sends a red head to CI Fix and files the red
  backstop's fix ticket.

  GitHub's webhook deliveries go to the PR and CI watcher (`SymphonyElixir.PrWatch.Ingest`), not
  here; `status/0` shows their health beside the poller's own.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AuditLog, AutoMerge, Config, PrWatch}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.{Issue, Usage}
  alias SymphonyElixir.PrWatch.Ingest
  alias SymphonyElixir.{RunStore, TicketPullRequest, Tracker}

  @merging_state "Merging"
  @rework_state "Rework"
  @closed_pr_states ["CLOSED", "MERGED"]
  @github_error_backoff_threshold 3
  @max_github_error_backoff_ms 300_000
  @status_table :ci_poller_status
  @settled_conclusions ["SUCCESS", "FAILURE"]
  # Checks only a person can clear: the `protected-paths` workflow's job fails a PR whose own
  # commits change an agent-protected path until a person adds the waiver label.
  @human_only_checks ["protected paths"]
  @waiver_label "protected-paths-approved"

  defmodule State do
    @moduledoc false
    defstruct [
      :timer_ref,
      :poll_interval_ms,
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
          [{:current, status}] -> Map.put(status, :webhooks, Ingest.status())
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

  @impl true
  def handle_info(:poll, %State{} = state) do
    {state, delay_ms} =
      case poll_cycle_result(state.opts) do
        {:ok, _summary} ->
          {handle_poll_success(state), state.poll_interval_ms}

        {:error, message, reason} ->
          handle_poll_failure(state, message, reason)
      end

    publish_status(state)
    {:noreply, schedule_poll(state, delay_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec poll_once(keyword()) :: {:ok, poll_summary()} | {:error, term()}
  def poll_once(opts \\ []) when is_list(opts) do
    if scoped_poll_opts?(opts) do
      poll_once_for_repo(opts)
    else
      poll_once_for_repos(opts)
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

    with {:ok, discovered, landing_issue_ids} <- discover_ci_checks(settings, run_store, tracker, repo_key, now, opts),
         {:ok, checks} <- list_ci_checks(run_store, repo_key) do
      opts = Keyword.put(opts, :landing_issue_ids, landing_issue_ids)
      actions = Enum.map(checks, &process_ci_check(&1, opts, now))
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
      Enum.each(issues, &warn_if_pr_url_lost(&1, Map.get(existing_by_issue, &1.id), repo_key))

      discovered = Enum.count(issues, &persist_discovered_ci_check?(&1, existing_by_issue, run_store, repo_key, now))

      {:ok, discovered, landing_issue_ids(issues)}
    end
  end

  # An issue the poller watches a PR for whose record in Symphony (`SymphonyElixir.TicketPullRequest`)
  # now holds no open PR: the lanes that read the ticket's PR from that record would skip it. Issues
  # that never had a PR, such as a final verification ticket, have no CI check record and stay quiet.
  defp warn_if_pr_url_lost(%Issue{} = issue, %{pr_url: pr_url}, repo_key) when is_binary(pr_url) do
    if is_nil(first_pr_url(issue, repo_key)) do
      Logger.warning(
        "issue_id=#{issue.id} issue_identifier=#{issue.identifier} is in #{issue.state} with no open PR in Symphony's record of its pull request; " <>
          "Symphony still watches CI on #{pr_url} for it"
      )
    end
  end

  defp warn_if_pr_url_lost(_issue, _existing, _repo_key), do: :ok

  # Every `Merging` issue: its head's CI is read as a landing reads it (see `landing_action/1`).
  defp landing_issue_ids(issues), do: issues |> Enum.filter(&AutoMerge.merging?/1) |> MapSet.new(& &1.id)

  defp fetch_watched_issues(settings, tracker, opts) do
    case Keyword.fetch(opts, :watched_issues) do
      {:ok, issues} -> {:ok, Enum.filter(issues, &issue_in_states?(&1, watched_states(settings)))}
      :error -> tracker.fetch_issues_by_states(watched_states(settings))
    end
  end

  # The phases whose PR head's CI the rest of Symphony reads from this poller's records: a landing
  # agent in `Merging` waits on its head's checks (`observed_head/2`, `landing_ready_head/2`), and
  # the board's CI label of a webhook delivery is written against the head a record holds.
  defp watched_states(settings) do
    [@merging_state, settings.tracker.code_review_state, settings.tracker.qa_state, @rework_state]
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
    with pr_url when is_binary(pr_url) <- first_pr_url(issue, repo_key),
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

  defp process_ci_check(record, opts, now) when is_map(record) do
    case backoff_active_until(record, now) do
      {:backing_off, next_poll_at} ->
        {:backing_off, Map.get(record, :issue_id), next_poll_at}

      :ready ->
        fetch_and_process_ci(record, opts, now)
    end
  end

  defp fetch_and_process_ci(record, opts, now) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_ci_status(Map.get(record, :pr_url), [cwd: Map.get(record, :workspace_path)] ++ landing_read_opts(record, opts)) do
      {:ok, ci_status} ->
        handle_ci_status(record, ci_status, opts, now)

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

  # The poller only observes: the PR and CI watcher (`SymphonyElixir.PrWatch`) decides what a red,
  # green or conflicting head calls for. The record keeps the head, its conclusion, its failed checks
  # and whether it may land, for a landing agent's CI wait (`observed_head/2`).
  defp handle_ci_status(record, ci_status, opts, now) do
    issue_id = Map.get(record, :issue_id)
    ci_status = put_rerun_pending(ci_status, issue_id, repo_key: repo_key_for(record, opts), run_store: Keyword.get(opts, :run_store, RunStore))

    case ci_action(ci_status) do
      :closed ->
        finish_pull_request(record, ci_status, opts)
        cleanup_ci(record, opts, now, "closed")

      action ->
        status = observed_status(action)
        attrs = ci_status_attrs(record, ci_status, %{status: status, failed_checks: failed_checks(ci_status)}, now)
        complete_ci_update(opts, record, attrs, {:observed, issue_id, status})
    end
  end

  defp observed_status(:success), do: "green"
  defp observed_status(:pending), do: "watching"
  defp observed_status({:failure, _checks}), do: "red"

  defp repo_key_for(record, opts), do: Map.get(record, :repo_key) || repo_key_from_opts(opts)

  # A PR that closed is no longer its ticket's in-flight PR. A `Merging` ticket's merged PR is left
  # to the PR and CI watcher, which moves the ticket to Done before it marks the PR finished.
  defp finish_pull_request(record, ci_status, opts) do
    merged? = normalize_status(Map.get(ci_status, :state)) == "MERGED"

    unless merged? and landing_read?(record, opts) do
      TicketPullRequest.mark_finished(repo_key_for(record, opts), Map.get(record, :pr_url), if(merged?, do: "merged", else: "closed"))
    end
  end

  defp cleanup_ci(record, opts, now, reason) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = repo_key_for(record, opts)
    issue_id = Map.get(record, :issue_id)

    case delete_ci_check(run_store, repo_key, issue_id) do
      :ok ->
        {:cleanup, issue_id, reason}

      {:error, delete_reason} ->
        attrs = %{status: "cleanup_error", error: inspect(delete_reason), updated_at: now}
        complete_ci_update(opts, record, attrs, {:cleanup_error, issue_id, delete_reason})
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
      },
      attrs
    )
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

  @doc """
  What a head's checks say: `:closed` for a closed or merged PR, `{:failure, checks}` with the
  failed ones, `:pending` while any runs (or a rerun hasn't reported, `:rerun_pending`), else
  `:success`. A pure read: the PR and CI watcher decides what it calls for.
  """
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
  failed check holds it, required or not.
  """
  @spec landing_action(map()) :: :closed | :pending | :success | {:failure, [map()]}
  def landing_action(ci_status) do
    case ci_action(ci_status) do
      :pending -> if landing_ready?(ci_status), do: :success, else: :pending
      action -> action
    end
  end

  defp landing_ready?(%{required_checks: [_ | _] = required} = ci_status), do: required_checks_passed?(ci_status, required)
  defp landing_ready?(_ci_status), do: false

  defp required_checks_passed?(ci_status, required) do
    checks = Map.get(ci_status, :checks, [])

    Enum.all?(required, fn name ->
      named = Enum.filter(checks, &(Map.get(&1, :name) == name))
      named != [] and Enum.all?(named, &passed_check?/1)
    end)
  end

  @doc """
  Marks `ci_status` `rerun_pending`, which `ci_action/1` reads as `:pending`, while the rerun the
  PR and CI watcher started on this head has not reported yet: until GitHub's new attempt queues
  them, the rerun checks drop out of the rollup and only the checks that passed are left, so the
  head would read green (`SymphonyElixir.PrWatch.rerun_pending?/4`).
  """
  @spec put_rerun_pending(map(), String.t() | nil, keyword()) :: map()
  def put_rerun_pending(ci_status, issue_id, opts \\ []) when is_map(ci_status) do
    names = ci_status |> Map.get(:checks, []) |> Enum.map(&Map.get(&1, :name))

    if PrWatch.rerun_pending?(issue_id, Map.get(ci_status, :commit_sha), names, Keyword.take(opts, [:repo_key, :run_store])),
      do: Map.put(ci_status, :rerun_pending, true),
      else: ci_status
  end

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

  # The ticket's in-flight PR, from Symphony's record of it.
  defp first_pr_url(%Issue{} = issue, repo_key), do: TicketPullRequest.current_url(issue, repo_key)

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
      poll_interval_ms: state.poll_interval_ms
    }
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
