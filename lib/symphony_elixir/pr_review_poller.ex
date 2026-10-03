defmodule SymphonyElixir.PrReviewPoller do
  @moduledoc """
  Polling-mode pull request review poller.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AuditLog, AutoMerge, CiPoller, Config, Notifications, RunStore, Tracker, Workspace}
  alias SymphonyElixir.GitHub.{CommentMarker, PullRequest}
  alias SymphonyElixir.Learnings.Reflection
  alias SymphonyElixir.Linear.{Issue, Usage}

  @in_review_state "In Review"
  @merging_state "Merging"
  @done_state "Done"
  @active_state "In Progress"
  @changes_requested "CHANGES_REQUESTED"
  @approved "APPROVED"
  @conflicting_mergeable "CONFLICTING"
  @dirty_merge_state "DIRTY"
  @closed_pr_states ["CLOSED"]
  @merged_pr_state "MERGED"
  @conflict_max_retries 3
  @github_error_backoff_threshold 3
  @max_github_error_backoff_ms 300_000
  # Upper bound on the per-PR reply ledger we carry across cursor advances. The
  # ledger is an id-level idempotency guard against re-replying to a comment we
  # already answered (e.g. if the id cursor is ever lost); cap it so a long-lived
  # PR cannot grow the record without bound.
  @max_replied_comment_ids 500
  @status_table :pr_review_poller_status

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
          mode: :polling | :tracker,
          discovered: non_neg_integer(),
          processed: non_neg_integer(),
          actions: [term()]
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
    Usage.put_caller(:pr_review_poller)
    poll_interval_ms = poll_interval_ms(opts)
    opts = poller_opts(opts, poll_interval_ms)
    state = %State{opts: opts, poll_interval_ms: poll_interval_ms}
    publish_status(state)

    {:ok, schedule_poll(state, 0)}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    {state, delay_ms} =
      case poll_cycle_result(state) do
        :ok -> {handle_poll_success(state), state.poll_interval_ms}
        {:error, message, reason} -> handle_poll_failure(state, message, reason)
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

  @doc false
  @spec pending_reviewer_comments(String.t(), keyword()) :: [map()]
  def pending_reviewer_comments(issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_keys = repo_keys_from_opts(opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    pending_reviewer_comments(issue_id, run_store, repo_keys, now)
  end

  defp pending_reviewer_comments(issue_id, run_store, repo_keys, now) when is_binary(issue_id) do
    Enum.find_value(repo_keys, [], &pending_reviewer_comments_for_repo(&1, issue_id, run_store, now))
  end

  defp pending_reviewer_comments(_issue_id, _run_store, _repo_keys, _now), do: []

  defp pending_reviewer_comments_for_repo(repo_key, issue_id, run_store, now) do
    case list_pr_reviews(run_store, repo_key) do
      {:ok, reviews} ->
        reviews
        |> comments_from_review_record(issue_id, run_store, now)
        |> empty_to_nil()

      {:error, reason} ->
        record_pending_comment_lookup_error(run_store, repo_key, issue_id, reason, now)
        nil
    end
  end

  @doc false
  @spec pending_pr_conflict(String.t(), keyword()) :: map() | nil
  def pending_pr_conflict(issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_keys = repo_keys_from_opts(opts)

    if is_binary(issue_id) do
      Enum.find_value(repo_keys, &pending_pr_conflict_for_repo(&1, issue_id, run_store))
    end
  end

  defp pending_pr_conflict_for_repo(repo_key, issue_id, run_store) do
    with {:ok, reviews} <- list_pr_reviews(run_store, repo_key),
         %{} = record <- Enum.find(reviews, &(Map.get(&1, :issue_id) == issue_id)),
         true <- conflict_prompt_pending?(record) do
      normalize_conflict_context(Map.get(record, :conflict_context))
    else
      _ -> nil
    end
  end

  # The PR head branch the workspace should track when a reviewer-comment rework
  # is pending for the issue, so the rework agent resets onto the latest remote
  # head instead of stale local worktree state. Returns nil unless reviewer
  # comments are actually pending (the conflict head is resolved separately via
  # pending_pr_conflict/2) or the record never captured the head branch name.
  @doc false
  @spec pending_pr_head_ref(String.t(), keyword()) :: String.t() | nil
  def pending_pr_head_ref(issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_keys = repo_keys_from_opts(opts)

    if is_binary(issue_id) do
      Enum.find_value(repo_keys, &pending_pr_head_ref_for_repo(&1, issue_id, run_store))
    end
  end

  defp pending_pr_head_ref_for_repo(repo_key, issue_id, run_store) do
    with {:ok, reviews} <- list_pr_reviews(run_store, repo_key),
         %{} = record <- Enum.find(reviews, &(Map.get(&1, :issue_id) == issue_id)),
         false <- unsupported_cross_repo?(record),
         true <- reviewer_comments_pending?(record) do
      string_field(record, :head_ref_name)
    else
      _ -> nil
    end
  end

  defp reviewer_comments_pending?(record) do
    record
    |> Map.get(:pending_reviewer_comments, [])
    |> normalize_comments()
    |> Kernel.!=([])
  end

  defp comments_from_review_record(reviews, issue_id, run_store, now) do
    case Enum.find(reviews, &(Map.get(&1, :issue_id) == issue_id)) do
      %{} = record ->
        clear_pending_comment_lookup_error(run_store, record, now)

        record
        |> Map.get(:pending_reviewer_comments, [])
        |> normalize_comments()

      nil ->
        []
    end
  end

  defp empty_to_nil([]), do: nil
  defp empty_to_nil(value), do: value

  @doc false
  @spec complete_pending_reviewer_comments(String.t(), keyword()) :: :ok | {:error, term()}
  def complete_pending_reviewer_comments(issue_id, opts \\ []) do
    if is_binary(issue_id) do
      do_complete_pending_reviewer_comments(issue_id, opts)
    else
      :ok
    end
  end

  defp do_complete_pending_reviewer_comments(issue_id, opts) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_keys = repo_keys_from_opts(opts)

    case fetch_pr_review_record(run_store, repo_keys, issue_id) do
      {:ok, record} -> complete_reviewer_comment_record(record, put_record_repo_key(opts, record))
      :missing -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_pr_review_record(run_store, repo_keys, issue_id) do
    Enum.reduce_while(repo_keys, :missing, &fetch_pr_review_record_from_repo(&1, &2, run_store, issue_id))
  end

  defp fetch_pr_review_record_from_repo(repo_key, acc, run_store, issue_id) do
    case list_pr_reviews(run_store, repo_key) do
      {:ok, reviews} -> halt_on_review_record(reviews, issue_id, acc)
      {:error, reason} -> {:cont, error_acc(acc, reason)}
    end
  end

  defp halt_on_review_record(reviews, issue_id, acc) do
    case Enum.find(reviews, &(Map.get(&1, :issue_id) == issue_id)) do
      %{} = record -> {:halt, {:ok, record}}
      nil -> {:cont, acc}
    end
  end

  defp complete_reviewer_comment_record(record, opts) do
    cond do
      Map.get(record, :status) == "rework_requested" ->
        do_complete_reviewer_comment_record(record, opts)

      has_pending_reviewer_comments?(record) ->
        do_complete_reviewer_comment_record(record, opts)

      true ->
        :ok
    end
  end

  defp has_pending_reviewer_comments?(record) do
    case Map.get(record, :pending_reviewer_comments) do
      [_ | _] -> true
      _ -> false
    end
  end

  defp do_complete_reviewer_comment_record(record, opts) do
    github = Keyword.get(opts, :github, PullRequest)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    comments = record |> Map.get(:pending_reviewer_comments, []) |> normalize_comments()
    cursor = Map.get(record, :pending_last_addressed_comment_id) || latest_comment_id(comments)

    if comments == [] and is_nil(cursor) do
      :ok
    else
      complete_reviewer_comment_record(record, comments, cursor, github, opts, now)
    end
  end

  defp complete_reviewer_comment_record(record, comments, cursor, github, opts, now) do
    with {:ok, settings} <- poll_settings(opts),
         :ok <- ensure_pending_comment_lookup_succeeded(record),
         {:ok, record} <- maybe_backfill_review_issue_details(record, opts, now),
         {:ok, record} <- ensure_review_comments_have_follow_up_push(record, comments, github),
         {:ok, record} <- maybe_reply_to_comments(record, comments, settings, github, opts, now),
         {:ok, record} <- advance_reviewer_comment_cursor(record, cursor, opts, now) do
      maybe_request_review(record, comments, settings, github, opts, now)
      emit_rework_pushed(record, comments, cursor, now)
    else
      :unchanged_pr_head -> :ok
      other -> other
    end
  end

  defp ensure_pending_comment_lookup_succeeded(record) do
    case Map.get(record, :pending_reviewer_comments_lookup_error) do
      value when value in [nil, ""] -> :ok
      reason -> {:error, {:pending_reviewer_comments_lookup_error, reason}}
    end
  end

  defp ensure_review_comments_have_follow_up_push(record, [], _github), do: {:ok, record}

  defp ensure_review_comments_have_follow_up_push(record, _comments, github) do
    case pending_reviewed_head_sha(record) do
      nil ->
        {:ok, record}

      reviewed_head_sha ->
        ensure_pr_head_advanced(record, github, reviewed_head_sha)
    end
  end

  defp pending_reviewed_head_sha(record) do
    string_field(record, :pending_reviewer_comments_reviewed_head_sha)
  end

  defp ensure_pr_head_advanced(record, github, reviewed_head_sha) do
    case github.fetch_activity(Map.get(record, :pr_url), cwd: Map.get(record, :workspace_path)) do
      {:ok, activity} ->
        current_head_sha = string_field(activity, :head_ref_oid)

        cond do
          current_head_sha in [nil, ""] ->
            {:error, {:reviewer_comment_pr_head_missing, Map.get(record, :pr_url)}}

          current_head_sha == reviewed_head_sha ->
            log_unchanged_pr_head(record, reviewed_head_sha, current_head_sha)
            :unchanged_pr_head

          true ->
            {:ok, Map.put(record, :addressed_commit_sha, current_head_sha)}
        end

      {:error, reason} ->
        {:error, {:reviewer_comment_pr_head_lookup_failed, reason}}
    end
  end

  defp log_unchanged_pr_head(record, reviewed_head_sha, current_head_sha) do
    Logger.warning(
      "Leaving PR review comments pending because PR head did not advance " <>
        "issue_id=#{Map.get(record, :issue_id)} " <>
        "issue_identifier=#{Map.get(record, :issue_identifier)} " <>
        "pr_url=#{Map.get(record, :pr_url)} " <>
        "reviewed_head_sha=#{reviewed_head_sha} " <>
        "current_head_sha=#{current_head_sha}"
    )
  end

  defp advance_reviewer_comment_cursor(record, cursor, opts, now) do
    attrs = %{
      last_addressed_comment_id: cursor,
      last_addressed_comment_at: now,
      pending_reviewer_comments: [],
      pending_last_addressed_comment_id: nil,
      pending_reviewer_comments_reviewed_head_sha: nil,
      replied_comment_ids: retained_replied_comment_ids(record),
      pending_reviewer_comments_lookup_error: nil,
      pending_reviewer_comments_lookup_error_at: nil,
      auto_reply_state_update_error: nil,
      auto_reply_state_update_error_at: nil,
      auto_request_review_error: nil,
      auto_request_review_error_at: nil,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok -> {:ok, Map.merge(record, attrs)}
      {:error, reason} -> {:error, reason}
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
      case settings.pr_review.mode do
        "polling" ->
          do_poll_once(settings, opts)

        _mode ->
          {:ok, %{mode: :tracker, discovered: 0, processed: 0, actions: []}}
      end
    end
  end

  defp poll_once_for_repos(opts) do
    with {:ok, repos} <- Config.repos() do
      repos
      |> Enum.map(&Map.get(&1, :name))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.reduce_while({:ok, empty_poll_summary(:tracker)}, &poll_repo_and_merge(&1, &2, opts))
    end
  end

  defp poll_repo_and_merge(repo_key, {:ok, acc}, opts) do
    repo_opts = opts |> Keyword.put(:repo_key, repo_key) |> Keyword.delete(:settings)

    case poll_once_for_repo(repo_opts) do
      {:ok, summary} -> {:cont, {:ok, merge_poll_summary(acc, summary)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp empty_poll_summary(mode), do: %{mode: mode, discovered: 0, processed: 0, actions: []}

  defp merge_poll_summary(acc, summary) do
    %{
      mode: merged_mode(acc.mode, summary.mode),
      discovered: acc.discovered + summary.discovered,
      processed: acc.processed + summary.processed,
      actions: acc.actions ++ summary.actions
    }
  end

  defp merged_mode(:polling, _mode), do: :polling
  defp merged_mode(_mode, :polling), do: :polling
  defp merged_mode(_left, right), do: right

  defp do_poll_once(settings, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = repo_key_from_opts(opts)
    tracker = Keyword.get(opts, :tracker, Tracker)
    current_gh_user = resolve_current_gh_user(opts)

    with {:ok, discovered, merging_issue_ids} <- discover_reviews(settings, run_store, tracker, repo_key, now),
         {:ok, reviews} <- list_pr_reviews(run_store, repo_key) do
      opts = Keyword.put(opts, :merging_issue_ids, merging_issue_ids)

      actions =
        reviews
        |> Enum.map(&process_review(&1, settings, current_gh_user, opts, now))

      {:ok, %{mode: :polling, discovered: discovered, processed: length(reviews), actions: actions}}
    end
  end

  defp resolve_current_gh_user(opts) do
    case Keyword.fetch(opts, :current_gh_user) do
      {:ok, value} ->
        normalize_user(value)

      :error ->
        opts |> detect_current_gh_user() |> normalize_user()
    end
  end

  defp detect_current_gh_user(opts) do
    github = Keyword.get(opts, :github, PullRequest)

    if function_exported?(github, :current_user, 1) do
      case github.current_user(opts) do
        {:ok, login} when is_binary(login) ->
          login

        {:error, reason} ->
          Logger.debug("PR review current gh user detection failed: #{inspect(reason)}")
          nil

        _other ->
          nil
      end
    else
      nil
    end
  end

  # With auto-merge on, `Merging` issues are watched too: this poller lands them (see AutoMerge).
  defp discover_reviews(settings, run_store, tracker, repo_key, now) do
    with {:ok, issues} <- tracker.fetch_issues_by_states(watched_states(settings)),
         {:ok, runs} <- list_runs(run_store, repo_key),
         {:ok, existing} <- list_pr_reviews(run_store, repo_key) do
      existing_by_issue = Map.new(existing, &{Map.get(&1, :issue_id), &1})
      issues = Enum.filter(issues, &match?(%Issue{}, &1))

      merging_issue_ids =
        if AutoMerge.enabled?(settings),
          do: issues |> Enum.filter(&(AutoMerge.merging?(&1) and issue_in_repo?(&1, repo_key))) |> MapSet.new(& &1.id),
          else: MapSet.new()

      discovered =
        Enum.count(issues, &persist_discovered_review?(&1, runs, existing_by_issue, merging_issue_ids, run_store, repo_key, now))

      {:ok, discovered, merging_issue_ids}
    end
  end

  # The tracker returns `Merging` issues from every repository; only this repository's are landed
  # here, so its auto-merge setting never applies to another's PRs. A missing repo_key means the
  # primary repository, as in `Config.settings_for_repo/1`.
  defp issue_in_repo?(%Issue{repo_key: issue_repo_key}, repo_key) when is_binary(issue_repo_key) and issue_repo_key != "",
    do: issue_repo_key == repo_key

  defp issue_in_repo?(%Issue{}, repo_key), do: repo_key == Config.repo_key_or_nil()

  defp watched_states(settings) do
    if AutoMerge.enabled?(settings), do: [@in_review_state, @merging_state], else: [@in_review_state]
  end

  defp persist_discovered_review?(%Issue{} = issue, runs, existing_by_issue, merging_issue_ids, run_store, repo_key, now) do
    existing = Map.get(existing_by_issue, issue.id)

    record =
      discover_review_record(issue, runs, existing, now) ||
        discover_auto_merge_record(issue, existing, merging_issue_ids, now)

    case record do
      nil ->
        false

      record ->
        case persist_pr_review(run_store, Map.put(record, :repo_key, repo_key)) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning("Failed to persist discovered PR review record issue_id=#{issue.id}: #{inspect(reason)}")

            false
        end
    end
  end

  defp discover_review_record(%Issue{} = issue, runs, %{workspace_path: workspace_path} = existing, now)
       when is_binary(workspace_path) and workspace_path != "" do
    attrs =
      existing
      |> missing_review_detail_attrs(issue)
      |> missing_run_detail_attrs(existing, latest_run_for_issue(runs, issue.id))
      |> maybe_put_updated_at(now)

    if map_size(attrs) > 0 do
      Map.merge(existing, attrs)
    end
  end

  defp discover_review_record(%Issue{} = issue, runs, existing, now) when is_list(runs) do
    with pr_url when is_binary(pr_url) <- first_pr_url(issue),
         %{workspace_path: workspace_path} = run when is_binary(workspace_path) <-
           latest_run_for_issue(runs, issue.id) do
      base = %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_title: issue.title,
        issue_url: issue.url,
        pr_url: pr_url,
        run_id: Map.get(run, :run_id),
        transcript_path: Map.get(run, :transcript_path),
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
        Logger.debug("discover_review_record skipped issue_id=#{issue.id}: #{inspect(other)}")
        nil
    end
  end

  defp discover_review_record(_issue, _runs, _existing, _now), do: nil

  # Auto-merge owns every `Merging` issue with a PR (see AutoMerge.owns_issue?/2), so the
  # poller must watch it even without a run to take the workspace from (run history reset,
  # PR opened outside Symphony). GitHub calls run with `cwd: nil` and cleanup skips the
  # workspace removal.
  defp discover_auto_merge_record(%Issue{} = issue, nil, merging_issue_ids, now) do
    with true <- Enum.member?(merging_issue_ids, issue.id),
         pr_url when is_binary(pr_url) <- first_pr_url(issue) do
      %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_title: issue.title,
        issue_url: issue.url,
        pr_url: pr_url,
        workspace_path: nil,
        status: "watching",
        inserted_at: now,
        updated_at: now
      }
    else
      _other -> nil
    end
  end

  defp discover_auto_merge_record(_issue, _existing, _merging_issue_ids, _now), do: nil

  defp log_poll_action_warnings(%{actions: actions}) when is_list(actions) do
    Enum.each(actions, &log_poll_action_warning/1)
  end

  defp log_poll_action_warning({:cleanup_error, issue_id, reason}) do
    Logger.warning("PR review cleanup error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:poll_error, issue_id, reason}) do
    Logger.warning("PR review poll error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:poll_error_update_failed, issue_id, reason, update_reason}) do
    Logger.warning("PR review poll error update failed issue_id=#{issue_id} reason=#{inspect(reason)}: #{inspect(update_reason)}")
  end

  defp log_poll_action_warning({:state_transition_error, issue_id, action, reason}) do
    Logger.warning("PR review transition error issue_id=#{issue_id} action=#{action}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:state_transition_update_error, issue_id, action, reason}) do
    Logger.warning("PR review transition update error issue_id=#{issue_id} action=#{action}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:state_transition_error_update_failed, issue_id, action, reason, update_reason}) do
    Logger.warning("PR review transition error update failed issue_id=#{issue_id} action=#{action} reason=#{inspect(reason)}: #{inspect(update_reason)}")
  end

  defp log_poll_action_warning({:state_transition_deferred, issue_id, action, _target_state}) do
    Logger.info("PR review transition deferred while dispatch is paused issue_id=#{issue_id} action=#{action}")
  end

  defp log_poll_action_warning({:update_error, issue_id, reason}) do
    Logger.warning("PR review update error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning(_action), do: :ok

  defp process_review(record, settings, current_gh_user, opts, now) when is_map(record) do
    case backoff_active_until(record, now) do
      {:backing_off, next_poll_at} ->
        {:backing_off, Map.get(record, :issue_id), next_poll_at}

      :ready ->
        fetch_and_process_review(record, settings, current_gh_user, opts, now)
    end
  end

  defp fetch_and_process_review(record, settings, current_gh_user, opts, now) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_activity(Map.get(record, :pr_url), cwd: Map.get(record, :workspace_path)) do
      {:ok, activity} ->
        handle_activity(record, activity, settings, current_gh_user, opts, now)

      {:error, reason} ->
        record_poll_error(record, reason, opts, now)
    end
  end

  defp record_poll_error(record, reason, opts, now) do
    attrs = poll_error_attrs(record, reason, opts, now)
    maybe_emit_poll_run_failed(record, attrs, reason)

    case update_review(opts, record, attrs) do
      :ok ->
        {:poll_error, Map.get(record, :issue_id), reason}

      {:error, update_reason} ->
        {:poll_error_update_failed, Map.get(record, :issue_id), reason, update_reason}
    end
  end

  defp handle_activity(record, activity, settings, current_gh_user, opts, now) do
    ignored_users = ignored_review_users(settings, activity, current_gh_user)

    {attrs, latest_activity_at, unaddressed_comments} =
      review_activity_attrs(record, activity, ignored_users, now)

    attrs = clear_auto_merge_fallback(attrs, record, opts)

    case review_action(record, activity, latest_activity_at, unaddressed_comments, ignored_users, settings, now) do
      :merged ->
        with {:ok, record} <- finish_auto_merge(record, opts, now) do
          record
          |> maybe_capture_learnings(activity, settings, opts, now)
          |> cleanup_review(opts, now, "merged")
        end

      :closed ->
        cleanup_review(record, opts, now, "closed")

      :changes_requested ->
        maybe_transition_rework(record, attrs, settings, opts, now)

      :review_comments ->
        maybe_transition_rework(record, attrs, settings, opts, now)

      :conflict ->
        maybe_transition_conflict(record, put_auto_merge_conflict(attrs, record, activity, opts, now), opts, now)

      action when action in [:approved, :stale, :watching] ->
        if auto_merge_issue?(record, opts),
          do: run_auto_merge(record, attrs, activity, settings, opts, now),
          else: handle_review_action(action, record, attrs, opts, now)
    end
  end

  defp handle_review_action(action, record, attrs, opts, now) do
    case action do
      :approved ->
        maybe_transition_merge(record, attrs, opts, now)

      :stale ->
        cleanup_review(record, opts, now, "stale")

      :watching ->
        complete_review_update(opts, record, attrs, {:watching, Map.get(record, :issue_id)})
    end
  end

  @doc """
  The auto-merge state the poller keeps for the issue's PR (see `SymphonyElixir.AutoMerge`),
  or nil when auto-merge hasn't handled it.
  """
  @spec auto_merge(String.t(), keyword()) :: AutoMerge.t() | nil
  def auto_merge(issue_id, opts \\ []) when is_binary(issue_id) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    Enum.find_value(repo_keys_from_opts(opts), fn repo_key ->
      with {:ok, records} <- list_pr_reviews(run_store, repo_key),
           %{auto_merge: %{} = auto_merge} <- Enum.find(records, &(Map.get(&1, :issue_id) == issue_id)) do
        auto_merge
      else
        _other -> nil
      end
    end)
  end

  @doc "Every PR the poller is landing with auto-merge, with a short status for the dashboard."
  @spec auto_merge_statuses(keyword()) :: [map()]
  def auto_merge_statuses(opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    repo_keys_from_opts(opts)
    |> Enum.flat_map(fn repo_key ->
      case list_pr_reviews(run_store, repo_key) do
        {:ok, records} -> Enum.filter(records, &auto_merge_status?/1)
        {:error, _reason} -> []
      end
    end)
    |> Enum.map(fn record ->
      auto_merge = Map.fetch!(record, :auto_merge)

      %{
        issue_id: Map.get(record, :issue_id),
        issue_identifier: Map.get(record, :issue_identifier),
        pr_url: Map.get(record, :pr_url),
        state: auto_merge.state,
        head_sha: Map.get(auto_merge, :head_sha),
        status: AutoMerge.describe(auto_merge),
        updated_at: Map.get(auto_merge, :updated_at)
      }
    end)
    |> Enum.sort_by(&(&1.issue_identifier || &1.issue_id || ""))
  end

  defp auto_merge_status?(%{auto_merge: %{state: state}}) when is_binary(state), do: true
  defp auto_merge_status?(_record), do: false

  defp auto_merge_issue?(record, opts) do
    MapSet.member?(Keyword.get(opts, :merging_issue_ids, MapSet.new()), Map.get(record, :issue_id))
  end

  # A fallback hands one stay in `Merging` to the landing agent. Once the issue leaves
  # `Merging`, the next approval tries auto-merge again.
  defp clear_auto_merge_fallback(attrs, record, opts) do
    if AutoMerge.fallback?(Map.get(record, :auto_merge)) and not auto_merge_issue?(record, opts),
      do: Map.put(attrs, :auto_merge, nil),
      else: attrs
  end

  defp put_auto_merge_conflict(attrs, record, activity, opts, now) do
    previous = Map.get(record, :auto_merge)

    if auto_merge_issue?(record, opts) or AutoMerge.armed?(previous) do
      auto_merge = AutoMerge.conflict(previous, Map.get(activity, :head_ref_oid), now)
      AutoMerge.log_transition(record, previous, auto_merge)
      Map.put(attrs, :auto_merge, auto_merge)
    else
      attrs
    end
  end

  defp run_auto_merge(record, attrs, activity, settings, opts, now) do
    issue_id = Map.get(record, :issue_id)

    case AutoMerge.step(record, activity, settings, opts, now) do
      {:ok, auto_merge} ->
        complete_review_update(opts, record, Map.put(attrs, :auto_merge, auto_merge), {:auto_merge, issue_id, auto_merge.state})

      {:conflict, auto_merge} ->
        # GitHub couldn't merge the base branch in: same path as a conflict GitHub reports.
        conflicted = Map.merge(activity, %{mergeable: @conflicting_mergeable, merge_state_status: @dirty_merge_state})

        attrs =
          attrs
          |> maybe_put_conflict_attrs(record, conflicted, now)
          |> Map.put(:auto_merge, auto_merge)

        case conflict_review_action(record, conflicted) do
          :conflict -> maybe_transition_conflict(record, attrs, opts, now)
          _watching -> complete_review_update(opts, record, attrs, {:auto_merge, issue_id, auto_merge.state})
        end

      {:fallback, auto_merge} ->
        attrs = Map.put(attrs, :auto_merge, auto_merge)

        action = {:auto_merge, issue_id, "fallback"}

        with ^action <- complete_review_update(opts, record, attrs, action) do
          comment_auto_merge_fallback(record, auto_merge, opts)
          action
        end
    end
  end

  defp comment_auto_merge_fallback(record, auto_merge, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)

    case tracker.create_comment(issue_id, AutoMerge.fallback_comment(Map.get(record, :pr_url), auto_merge)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to comment the auto-merge fallback issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  # GitHub merged a PR Symphony was landing with auto-merge: move the issue to Done (Linear's
  # GitHub integration may already have) before the usual merged cleanup.
  defp finish_auto_merge(record, opts, now) do
    previous = Map.get(record, :auto_merge)

    if AutoMerge.armed?(previous) or auto_merge_issue?(record, opts) do
      tracker = Keyword.get(opts, :tracker, Tracker)
      issue_id = Map.get(record, :issue_id)

      case tracker.update_issue_state(issue_id, @done_state) do
        :ok ->
          auto_merge = AutoMerge.merged(previous, now)
          AutoMerge.log_transition(record, previous, auto_merge)
          {:ok, Map.put(record, :auto_merge, auto_merge)}

        {:error, reason} ->
          record_transition_error(record, %{}, opts, now, "done", reason)
      end
    else
      {:ok, record}
    end
  end

  defp review_activity_attrs(record, activity, ignored_users, now) do
    latest_activity_at =
      Map.get(activity, :latest_activity_at) ||
        Map.get(record, :last_activity_at) ||
        Map.get(record, :updated_at) ||
        now

    raw_comments = Map.get(activity, :comments, [])
    reviewer_comments = reviewer_comments(raw_comments, ignored_users)
    unaddressed_comments = unaddressed_reviewer_comments(record, reviewer_comments)
    latest_unaddressed_comment_at = latest_comment_activity_at(unaddressed_comments)

    latest_review_activity_at =
      latest_comment_activity_at(review_activity_events(raw_comments, ignored_users)) ||
        Map.get(record, :last_review_activity_at) ||
        latest_activity_at

    attrs =
      %{
        status: "watching",
        error: nil,
        consecutive_errors: 0,
        next_poll_at: nil,
        last_activity_at: latest_activity_at,
        last_review_activity_at: latest_review_activity_at,
        last_unaddressed_comment_at: latest_unaddressed_comment_at,
        last_review_decision: Map.get(activity, :review_decision),
        review_self_users: ignored_users.self,
        updated_at: now
      }
      |> maybe_put_conflict_attrs(record, activity, now)
      |> maybe_put_pending_comments(record, unaddressed_comments)

    {attrs, latest_activity_at, unaddressed_comments}
  end

  defp review_action(record, activity, latest_activity_at, unaddressed_comments, ignored_users, settings, now) do
    review_decision = normalize_decision(Map.get(activity, :review_decision))
    changes_requested? = changes_requested_decision?(review_decision, activity, ignored_users)

    cond do
      merged_pr_state?(Map.get(activity, :state)) ->
        :merged

      closed_pr_state?(Map.get(activity, :state)) ->
        :closed

      true ->
        open_review_action(
          record,
          activity,
          latest_activity_at,
          unaddressed_comments,
          changes_requested?,
          settings,
          now
        )
    end
  end

  defp open_review_action(record, activity, latest_activity_at, unaddressed_comments, changes_requested?, settings, now) do
    case conflict_review_action(record, activity) do
      nil ->
        reviewer_activity_action(
          activity,
          latest_activity_at,
          unaddressed_comments,
          changes_requested?,
          settings,
          now
        )

      action ->
        action
    end
  end

  defp conflict_review_action(record, activity) do
    cond do
      not merge_conflict?(activity) -> nil
      unsupported_cross_repo?(activity) -> :watching
      conflict_key(activity) in string_list(Map.get(record, :dispatched_conflict_keys, [])) -> :watching
      true -> :conflict
    end
  end

  defp reviewer_activity_action(activity, latest_activity_at, unaddressed_comments, changes_requested?, settings, now) do
    review_decision = normalize_decision(Map.get(activity, :review_decision))
    cross_repo_unsupported = unsupported_cross_repo?(activity)
    change_action = changes_requested_action(changes_requested?, cross_repo_unsupported)
    comment_action = reviewer_comments_action(unaddressed_comments, cross_repo_unsupported)

    cond do
      change_action ->
        change_action

      review_decision == @approved ->
        :approved

      comment_action ->
        comment_action

      stale?(latest_activity_at, now, settings.pr_review.stale_days) ->
        :stale

      true ->
        :watching
    end
  end

  defp changes_requested_action(false, _cross_repo_unsupported), do: nil
  defp changes_requested_action(true, true), do: :watching
  defp changes_requested_action(true, false), do: :changes_requested

  defp reviewer_comments_action([], _cross_repo_unsupported), do: nil
  defp reviewer_comments_action(_unaddressed_comments, true), do: :watching
  defp reviewer_comments_action(_unaddressed_comments, false), do: :review_comments

  defp maybe_transition_conflict(record, attrs, opts, now) do
    issue_id = Map.get(record, :issue_id)

    cond do
      active_agent_run?(issue_id, opts) ->
        complete_review_update(opts, record, Map.merge(attrs, %{status: "conflict_active_run"}), {:active_run, issue_id, :conflict})

      conflict_retry_count(record) >= @conflict_max_retries ->
        complete_review_update(
          opts,
          record,
          Map.merge(attrs, %{
            status: "conflict_escalated",
            error: "merge conflict retry limit reached",
            target_issue_state: @in_review_state,
            updated_at: now
          }),
          {:conflict_escalated, issue_id, @conflict_max_retries}
        )

      true ->
        transition_issue_for_action(record, attrs, opts, now, "conflict")
    end
  end

  defp maybe_put_conflict_attrs(attrs, record, activity, now) do
    cond do
      merge_conflict?(activity) and not unsupported_cross_repo?(activity) ->
        context = conflict_context(record, activity, now)

        attrs
        |> Map.merge(conflict_record_attrs(activity))
        |> Map.put(:conflict_context, context)
        |> Map.put(:last_conflict_key, Map.fetch!(context, :conflict_key))
        |> Map.put(:last_conflict_at, now)

      conflict_state_present?(record) ->
        attrs
        |> Map.merge(conflict_record_attrs(activity))
        |> clear_conflict_attrs()

      true ->
        Map.merge(attrs, conflict_record_attrs(activity))
    end
  end

  defp clear_conflict_attrs(attrs) do
    Map.merge(attrs, %{
      conflict_context: nil,
      conflict_retry_count: 0,
      dispatched_conflict_keys: [],
      last_conflict_key: nil,
      last_conflict_at: nil
    })
  end

  defp conflict_record_attrs(activity) do
    %{
      pr_url: Map.get(activity, :pr_url),
      pr_title: Map.get(activity, :pr_title),
      pr_state: Map.get(activity, :state),
      mergeable: Map.get(activity, :mergeable),
      merge_state_status: Map.get(activity, :merge_state_status),
      head_ref_name: Map.get(activity, :head_ref_name),
      head_ref_oid: Map.get(activity, :head_ref_oid),
      base_ref_name: Map.get(activity, :base_ref_name),
      base_ref_oid: Map.get(activity, :base_ref_oid),
      is_cross_repository: Map.get(activity, :is_cross_repository)
    }
  end

  defp conflict_context(record, activity, now) do
    %{
      pr_url: Map.get(activity, :pr_url) || Map.get(record, :pr_url),
      pr_title: Map.get(activity, :pr_title) || Map.get(record, :pr_title),
      pr_number: Map.get(activity, :pr_number),
      head_ref: Map.get(activity, :head_ref_name),
      head_sha: Map.get(activity, :head_ref_oid),
      base_ref: Map.get(activity, :base_ref_name),
      base_sha: Map.get(activity, :base_ref_oid),
      mergeable: Map.get(activity, :mergeable),
      merge_state_status: Map.get(activity, :merge_state_status),
      conflict_key: conflict_key(activity),
      observed_at: now,
      retry_count: next_conflict_retry_count(record, activity),
      max_retries: @conflict_max_retries
    }
  end

  defp next_conflict_retry_count(record, activity) do
    key = conflict_key(activity)
    retry_count = conflict_retry_count(record)

    if key in string_list(Map.get(record, :dispatched_conflict_keys, [])) do
      max(retry_count, 1)
    else
      retry_count + 1
    end
  end

  defp conflict_prompt_pending?(record) do
    normalize_conflict_context(Map.get(record, :conflict_context)) != nil and
      Map.get(record, :status) not in ["conflict_escalated", "cleanup_pending"]
  end

  defp normalize_conflict_context(context) when is_map(context) do
    normalized = %{
      pr_url: string_field(context, :pr_url),
      pr_title: string_field(context, :pr_title),
      pr_number: integer_field(context, :pr_number),
      head_ref: string_field(context, :head_ref),
      head_sha: string_field(context, :head_sha),
      base_ref: string_field(context, :base_ref),
      base_sha: string_field(context, :base_sha),
      mergeable: string_field(context, :mergeable),
      merge_state_status: string_field(context, :merge_state_status),
      conflict_key: string_field(context, :conflict_key),
      observed_at: datetime_field(context, :observed_at),
      retry_count: non_negative_integer_field(context, :retry_count),
      max_retries: positive_integer_field(context, :max_retries) || @conflict_max_retries
    }

    if Enum.all?([normalized.head_ref, normalized.head_sha, normalized.base_ref, normalized.base_sha, normalized.conflict_key], &is_nil/1) do
      nil
    else
      normalized
    end
  end

  defp normalize_conflict_context(_context), do: nil

  defp merge_conflict?(activity) when is_map(activity) do
    normalize_decision(Map.get(activity, :mergeable)) == @conflicting_mergeable or
      normalize_decision(Map.get(activity, :merge_state_status)) == @dirty_merge_state
  end

  defp unsupported_cross_repo?(activity) do
    Map.get(activity, :is_cross_repository) == true
  end

  defp conflict_key(activity) do
    head = Map.get(activity, :head_ref_oid) || Map.get(activity, :head_ref_name) || "unknown-head"
    base = Map.get(activity, :base_ref_oid) || Map.get(activity, :base_ref_name) || "unknown-base"

    "#{head}|#{base}"
  end

  defp conflict_state_present?(record) do
    Map.get(record, :conflict_context) not in [nil, %{}] or
      Map.get(record, :last_conflict_key) not in [nil, ""] or
      conflict_retry_count(record) > 0 or
      string_list(Map.get(record, :dispatched_conflict_keys, [])) != []
  end

  defp conflict_retry_count(record) do
    case Map.get(record, :conflict_retry_count) do
      value when is_integer(value) and value >= 0 -> value
      _value -> 0
    end
  end

  defp active_agent_run?(issue_id, opts) when is_binary(issue_id) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = repo_key_from_opts(opts)

    case list_runs(run_store, repo_key) do
      {:ok, runs} -> Enum.any?(runs, &(Map.get(&1, :issue_id) == issue_id and Map.get(&1, :status) == "running"))
      {:error, _reason} -> false
    end
  end

  defp active_agent_run?(_issue_id, _opts), do: false

  defp changes_requested_decision?(@changes_requested, activity, ignored_users) do
    unignored_changes_requested?(activity, ignored_users)
  end

  defp changes_requested_decision?(_review_decision, _activity, _ignored_users), do: false

  defp unignored_changes_requested?(activity, ignored_users) do
    activity
    |> Map.get(:comments, [])
    |> Enum.any?(&unignored_changes_requested_review?(&1, ignored_users))
  end

  defp unignored_changes_requested_review?(comment, ignored_users) when is_map(comment) do
    Map.get(comment, :kind) == "review" and
      normalize_decision(Map.get(comment, :state)) == @changes_requested and
      not ignored_comment?(comment, ignored_users)
  end

  defp unignored_changes_requested_review?(_comment, _ignored_users), do: false

  defp maybe_transition_rework(record, attrs, settings, opts, now) do
    latest_activity_at = action_activity_at(attrs)
    issue_id = Map.get(record, :issue_id)

    cond do
      CiPoller.ci_owned_issue?(issue_id, Keyword.take(opts, [:run_store, :repo_key])) ->
        complete_review_update(opts, record, Map.merge(attrs, %{status: "ci_owned"}), {:ci_owned, issue_id, :rework})

      handled_activity?(record, latest_activity_at) ->
        complete_review_update(opts, record, attrs, {:already_handled, issue_id, :rework})

      !cooldown_elapsed?(latest_activity_at, now, settings.pr_review.cooldown_minutes) ->
        complete_review_update(opts, record, Map.merge(attrs, %{status: "cooling_down"}), {:cooling_down, issue_id})

      true ->
        transition_issue_for_action(record, attrs, opts, now, "rework")
    end
  end

  defp maybe_transition_merge(record, attrs, opts, now) do
    latest_activity_at = action_activity_at(attrs)

    if handled_activity?(record, latest_activity_at) do
      complete_review_update(opts, record, attrs, {:already_handled, Map.get(record, :issue_id), :merge})
    else
      transition_issue_for_action(record, attrs, opts, now, "merge")
    end
  end

  defp action_activity_at(attrs) do
    Map.get(attrs, :last_unaddressed_comment_at) ||
      Map.get(attrs, :last_review_activity_at) ||
      Map.fetch!(attrs, :last_activity_at)
  end

  defp transition_issue_for_action(record, attrs, opts, now, action) do
    if dispatch_paused?(opts) do
      defer_transition_action(record, attrs, opts, now, action)
    else
      persist_and_transition_action(record, attrs, opts, now, action)
    end
  end

  defp persist_and_transition_action(record, attrs, opts, now, action) do
    pending_attrs = pending_transition_action_attrs(attrs, action, now)

    case update_review(opts, record, pending_attrs) do
      :ok ->
        transition_persisted_action(record, pending_attrs, opts, now, action)

      {:error, reason} ->
        {:state_transition_update_error, Map.get(record, :issue_id), action_atom(action), reason}
    end
  end

  defp transition_persisted_action(record, pending_attrs, opts, now, action) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)

    case tracker.update_issue_state(issue_id, @active_state) do
      :ok ->
        complete_transition_action(record, pending_attrs, opts, now, action)

      {:error, reason} ->
        record_transition_error(record, pending_attrs, opts, now, action, reason)
    end
  end

  defp defer_transition_action(record, attrs, opts, now, action) do
    complete_review_update(
      opts,
      record,
      Map.merge(attrs, %{
        status: "#{action}_deferred",
        target_issue_state: @active_state,
        last_action: nil,
        last_action_at: nil,
        error: nil,
        updated_at: now
      }),
      {:state_transition_deferred, Map.get(record, :issue_id), action_atom(action), @active_state}
    )
  end

  defp complete_transition_action(record, attrs, opts, now, action) do
    case update_review(opts, record, transition_success_attrs(record, attrs, action, now)) do
      :ok ->
        maybe_emit_reviewer_commented(record, attrs, action, now)
        {:state_transitioned, Map.get(record, :issue_id), action_atom(action), @active_state}

      {:error, reason} ->
        {:state_transition_update_error, Map.get(record, :issue_id), action_atom(action), reason}
    end
  end

  defp record_transition_error(record, attrs, opts, now, action, reason) do
    case update_review(
           opts,
           record,
           Map.merge(attrs, %{
             status: "state_transition_error",
             error: inspect(reason),
             last_action: action,
             last_action_at: nil,
             updated_at: now
           })
         ) do
      :ok ->
        {:state_transition_error, Map.get(record, :issue_id), action_atom(action), reason}

      {:error, update_reason} ->
        {:state_transition_error_update_failed, Map.get(record, :issue_id), action_atom(action), reason, update_reason}
    end
  end

  defp pending_transition_action_attrs(attrs, action, now) do
    Map.merge(attrs, %{
      status: "#{action}_transition_pending",
      target_issue_state: @active_state,
      last_action: nil,
      last_action_at: nil,
      error: nil,
      updated_at: now
    })
  end

  defp transition_success_attrs(record, attrs, action, now) do
    %{
      status: "#{action}_requested",
      target_issue_state: @active_state,
      error: nil,
      last_action: action,
      last_action_at: now,
      updated_at: now
    }
    |> maybe_mark_conflict_dispatched(record, attrs, action)
  end

  defp maybe_mark_conflict_dispatched(attrs, record, pending_attrs, "conflict") do
    conflict_key = Map.get(pending_attrs, :last_conflict_key)

    attrs
    |> Map.put(:conflict_retry_count, conflict_retry_count(record) + 1)
    |> Map.put(:dispatched_conflict_keys, append_string(Map.get(record, :dispatched_conflict_keys, []), conflict_key))
    |> Map.put(:error, nil)
  end

  defp maybe_mark_conflict_dispatched(attrs, _record, _pending_attrs, _action), do: attrs

  defp cleanup_review(record, opts, now, reason) do
    workspace = Keyword.get(opts, :workspace, Workspace)
    run_store = Keyword.get(opts, :run_store, RunStore)

    cond do
      workspace_removed?(record) ->
        delete_review_after_cleanup(run_store, record, reason)

      active_agent_run?(Map.get(record, :issue_id), opts) ->
        # Removing the workspace under a live agent turn breaks its post-turn
        # steps; keep the record so the next poll cleans up after the run ends.
        {:cleanup_deferred, Map.get(record, :issue_id), reason}

      no_workspace?(record) ->
        finish_workspace_cleanup(record, opts, now, reason)

      true ->
        remove_review_workspace(workspace, record, opts, now, reason)
    end
  end

  # Records discovered for auto-merge without a run have no workspace to remove.
  defp no_workspace?(record), do: not match?(path when is_binary(path) and path != "", Map.get(record, :workspace_path))

  defp remove_review_workspace(workspace, record, opts, now, reason) do
    case workspace.remove(Map.get(record, :workspace_path), Map.get(record, :worker_host)) do
      {:ok, _removed_paths} ->
        finish_workspace_cleanup(record, opts, now, reason)

      {:error, cleanup_reason, output} ->
        complete_review_update(
          opts,
          record,
          cleanup_error_attrs(record, {cleanup_reason, output}, opts, now),
          {:cleanup_error, Map.get(record, :issue_id), cleanup_reason}
        )

      other ->
        complete_review_update(
          opts,
          record,
          cleanup_error_attrs(record, other, opts, now),
          {:cleanup_error, Map.get(record, :issue_id), other}
        )
    end
  end

  defp maybe_capture_learnings(record, activity, settings, opts, now) do
    learnings = Map.get(settings, :learnings)

    cond do
      not learnings_enabled?(learnings) ->
        record

      learning_reflection_attempted?(record) ->
        record

      true ->
        do_capture_learnings(record, activity, learnings, opts, now)
    end
  end

  defp do_capture_learnings(record, activity, learnings, opts, now) do
    case mark_learning_reflection_started(record, opts, now) do
      {:ok, started_record} ->
        issue = learning_reflection_issue(started_record, opts)

        result =
          capture_learnings_safely(
            started_record,
            %{record: started_record, activity: activity, issue: issue},
            learnings,
            opts_for_reflection(opts, now)
          )

        started_record
        |> learning_reflection_result_attrs(result, now)
        |> persist_learning_reflection_result(started_record, opts)

      {:error, reason} ->
        Logger.warning("Failed to mark learning reflection started issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
        record
    end
  end

  defp capture_learnings_safely(record, source, learnings, opts) do
    Reflection.capture(source, learnings, opts)
  rescue
    exception ->
      stacktrace = __STACKTRACE__
      log_learning_reflection_crash(record, :error, exception, stacktrace)
      {:error, {:capture_crashed, :error, exception}}
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      log_learning_reflection_crash(record, kind, reason, stacktrace)
      {:error, {:capture_crashed, kind, reason}}
  end

  defp log_learning_reflection_crash(record, kind, reason, stacktrace) do
    issue_id = Map.get(record, :issue_id)

    Logger.error(
      "Learning reflection crashed issue_id=#{issue_id}: " <>
        Exception.format(kind, reason, stacktrace)
    )
  end

  defp opts_for_reflection(opts, now) do
    opts
    |> Keyword.put(:now, now)
    |> Keyword.put_new(:run_store, Keyword.get(opts, :run_store, RunStore))
  end

  defp learnings_enabled?(%{enabled: true}), do: true
  defp learnings_enabled?(_learnings), do: false

  defp learning_reflection_attempted?(record) do
    Map.get(record, :learning_reflection_started_at) != nil or Map.get(record, :learning_reflected_at) != nil
  end

  defp mark_learning_reflection_started(record, opts, now) do
    attrs = %{
      learning_reflection_started_at: now,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok -> {:ok, Map.merge(record, attrs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp learning_reflection_result_attrs(_record, {:ok, count}, now) do
    %{
      learning_reflected_at: now,
      learning_reflection_count: count,
      learning_reflection_error: nil,
      updated_at: now
    }
  end

  defp learning_reflection_result_attrs(_record, {:discarded, reason}, now) do
    %{
      learning_reflected_at: now,
      learning_reflection_count: 0,
      learning_reflection_error: inspect({:discarded, reason}),
      updated_at: now
    }
  end

  defp learning_reflection_result_attrs(_record, {:error, reason}, now) do
    %{
      learning_reflected_at: now,
      learning_reflection_count: 0,
      learning_reflection_error: inspect(reason),
      updated_at: now
    }
  end

  defp persist_learning_reflection_result(attrs, record, opts) do
    case update_review(opts, record, attrs) do
      :ok ->
        Map.merge(record, attrs)

      {:error, reason} ->
        Logger.warning("Failed to persist learning reflection result issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
        record
    end
  end

  defp learning_reflection_issue(record, opts) do
    case fetch_review_issue(record, opts) do
      {:ok, %Issue{} = issue} -> issue
      _other -> issue_from_review_record(record)
    end
  end

  defp issue_from_review_record(record) do
    %Issue{
      id: Map.get(record, :issue_id),
      identifier: Map.get(record, :issue_identifier),
      title: Map.get(record, :issue_title),
      url: Map.get(record, :issue_url),
      pr_urls: [Map.get(record, :pr_url)] |> Enum.filter(&present?/1)
    }
  end

  defp finish_workspace_cleanup(record, opts, now, reason) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    case mark_workspace_removed(record, opts, now) do
      {:ok, updated_record} ->
        delete_review_after_cleanup(run_store, updated_record, reason)

      {:error, update_reason} ->
        {:cleanup_error, Map.get(record, :issue_id), update_reason}
    end
  end

  defp mark_workspace_removed(record, opts, now) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    attrs = %{
      status: "cleanup_pending",
      error: nil,
      consecutive_errors: 0,
      next_poll_at: nil,
      workspace_removed_at: now,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok ->
        {:ok, Map.merge(record, attrs)}

      {:error, reason} ->
        persist_workspace_removed_after_update_error(run_store, record, attrs, reason)
    end
  end

  defp persist_workspace_removed_after_update_error(run_store, record, attrs, update_reason) do
    issue_id = Map.get(record, :issue_id)
    updated_record = Map.merge(record, attrs)

    Logger.warning("Failed to update PR review workspace removal issue_id=#{issue_id}; attempting full record write: #{inspect(update_reason)}")

    case persist_pr_review(run_store, updated_record) do
      :ok ->
        {:ok, updated_record}

      {:error, put_reason} ->
        Logger.warning("Failed to persist PR review workspace removal issue_id=#{issue_id}: #{inspect(put_reason)}")

        {:error, {:workspace_removed_update_failed, update_reason, put_reason}}
    end
  end

  defp workspace_removed?(record) do
    match?(%DateTime{}, Map.get(record, :workspace_removed_at)) or
      Map.get(record, :status) == "cleanup_pending"
  end

  defp delete_review_after_cleanup(run_store, record, reason) do
    case Map.get(record, :repo_key) do
      repo_key when is_binary(repo_key) ->
        case delete_pr_review_record(run_store, repo_key, Map.get(record, :issue_id)) do
          :ok ->
            {:cleanup, Map.get(record, :issue_id), reason}

          {:error, delete_reason} ->
            Logger.warning("Failed to delete PR review record issue_id=#{Map.get(record, :issue_id)} after cleanup: #{inspect(delete_reason)}")

            {:cleanup_error, Map.get(record, :issue_id), delete_reason}
        end

      _repo_key ->
        {:cleanup_error, Map.get(record, :issue_id), :missing_repo_key}
    end
  end

  defp first_pr_url(%Issue{pr_urls: [url | _rest]}) when is_binary(url), do: url
  defp first_pr_url(_issue), do: nil

  defp latest_run_for_issue(runs, issue_id) when is_list(runs) and is_binary(issue_id) do
    runs
    |> Enum.filter(&review_run_for_issue?(&1, issue_id))
    |> Enum.max_by(&run_started_at_sort_key/1, fn -> nil end)
  end

  defp review_run_for_issue?(run, issue_id) do
    Map.get(run, :issue_id) == issue_id and
      Map.get(run, :status) in ["success", "stopped"] and
      is_binary(Map.get(run, :workspace_path))
  end

  defp run_started_at_sort_key(run) do
    case Map.get(run, :started_at) do
      %DateTime{} = started_at -> DateTime.to_unix(started_at, :microsecond)
      _started_at -> 0
    end
  end

  defp handled_activity?(record, latest_activity_at) do
    case {Map.get(record, :last_action_at), latest_activity_at} do
      {%DateTime{} = last_action_at, %DateTime{} = latest} ->
        DateTime.compare(last_action_at, latest) in [:gt, :eq]

      _ ->
        false
    end
  end

  defp maybe_put_pending_comments(attrs, record, comments) when is_list(comments) and comments != [] do
    attrs
    |> Map.put(:pending_reviewer_comments, comments)
    |> Map.put(:pending_last_addressed_comment_id, latest_comment_id(comments))
    |> maybe_put_pending_reviewed_head_sha(record)
  end

  defp maybe_put_pending_comments(attrs, record, []) do
    if pending_comment_cursor_caught_up?(record) do
      attrs
      |> Map.put(:pending_reviewer_comments, [])
      |> Map.put(:pending_last_addressed_comment_id, nil)
      |> Map.put(:pending_reviewer_comments_reviewed_head_sha, nil)
    else
      attrs
    end
  end

  defp maybe_put_pending_comments(attrs, _record, _comments), do: attrs

  defp maybe_put_pending_reviewed_head_sha(attrs, record) do
    existing_reviewed_head_sha = string_field(record, :pending_reviewer_comments_reviewed_head_sha)
    existing_pending_cursor = string_field(record, :pending_last_addressed_comment_id)
    new_pending_cursor = string_field(attrs, :pending_last_addressed_comment_id)

    current_head_sha =
      string_field(attrs, :head_ref_oid) ||
        string_field(record, :head_ref_oid)

    reviewed_head_sha =
      if present?(existing_reviewed_head_sha) and existing_pending_cursor == new_pending_cursor do
        existing_reviewed_head_sha
      else
        current_head_sha || existing_reviewed_head_sha
      end

    if present?(reviewed_head_sha) do
      Map.put(attrs, :pending_reviewer_comments_reviewed_head_sha, reviewed_head_sha)
    else
      attrs
    end
  end

  defp pending_comment_cursor_caught_up?(record) when is_map(record) do
    pending_comments = record |> Map.get(:pending_reviewer_comments, []) |> normalize_comments()
    pending_cursor = Map.get(record, :pending_last_addressed_comment_id) || latest_comment_id(pending_comments)
    addressed_cursor = Map.get(record, :last_addressed_comment_id)

    is_binary(pending_cursor) and pending_cursor != "" and pending_cursor == addressed_cursor
  end

  defp reviewer_comments(comments, ignored_users) when is_map(ignored_users) do
    comments
    |> normalize_comments()
    |> Enum.reject(&(ignored_comment?(&1, ignored_users) or String.trim(Map.get(&1, :body, "")) == ""))
    |> sort_comments()
  end

  defp review_activity_events(comments, ignored_users) when is_map(ignored_users) do
    comments
    |> normalize_comments()
    |> Enum.reject(&(ignored_comment?(&1, ignored_users) or review_activity_drop?(&1)))
    |> sort_comments()
  end

  defp review_activity_drop?(comment) when is_map(comment) do
    Map.get(comment, :kind) != "review" and String.trim(Map.get(comment, :body, "")) == ""
  end

  defp unaddressed_reviewer_comments(record, reviewer_comments) when is_list(reviewer_comments) do
    reviewer_comments
    |> comments_after_cursor(record)
    |> comments_after_last_action(record)
  end

  defp normalize_comments(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_comment/1)
    |> Enum.reject(&(Map.get(&1, :id) in [nil, ""]))
  end

  defp normalize_comments(_comments), do: []

  defp normalize_comment(comment) when is_map(comment) do
    %{
      id: string_field(comment, :id) || fallback_comment_id(comment),
      kind: string_field(comment, :kind),
      author: string_field(comment, :author),
      body: string_field(comment, :body) || "",
      url: string_field(comment, :url),
      path: string_field(comment, :path),
      line: integer_field(comment, :line),
      commit_id: string_field(comment, :commit_id),
      review_id: string_field(comment, :review_id),
      created_at: datetime_field(comment, :created_at),
      updated_at: datetime_field(comment, :updated_at)
    }
  end

  defp normalize_comment(_comment), do: %{id: nil}

  # Configured ignored reviewers are always skipped. The PR author and the
  # current `gh` user are the account Symphony posts with, which on a solo setup
  # is also the human reviewer: their comments count as reviewer feedback unless
  # Symphony posted them (marked) or they carry no text, such as the empty review
  # GitHub wraps around a reply.
  defp ignored_comment?(comment, %{ignored: ignored, self: self_users}) do
    author = normalize_user(Map.get(comment, :author))

    cond do
      author == nil -> false
      author in ignored -> true
      author in self_users -> not operator_feedback?(comment)
      true -> false
    end
  end

  defp operator_feedback?(comment) do
    body = Map.get(comment, :body)

    is_binary(body) and String.trim(body) != "" and not CommentMarker.symphony_authored?(body)
  end

  defp ignored_review_users(settings, activity, current_gh_user) do
    ignored = settings |> configured_ignored_users() |> normalize_users()
    self_users = normalize_users([Map.get(activity || %{}, :pr_author), current_gh_user])

    %{ignored: ignored, self: self_users -- ignored}
  end

  defp normalize_users(users) do
    users
    |> Enum.map(&normalize_user/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp configured_ignored_users(%{pr_review: pr_review}) do
    Map.get(pr_review, :ignored_users) || []
  end

  defp configured_ignored_users(_settings), do: []

  defp normalize_user(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(fn
      "" -> nil
      user -> user
    end)
  end

  defp normalize_user(_value), do: nil

  defp sort_comments(comments) do
    Enum.sort_by(comments, fn comment ->
      {comment_sort_timestamp(comment), Map.get(comment, :id)}
    end)
  end

  defp comments_after_cursor(comments, record) do
    case Map.get(record, :last_addressed_comment_id) do
      cursor when is_binary(cursor) and cursor != "" ->
        case Enum.split_while(comments, &(Map.get(&1, :id) != cursor)) do
          {_before, [_cursor | after_cursor]} ->
            after_cursor

          # The cursor comment is gone (deleted or its id changed), so we cannot
          # locate our position by id. Fall back to the timestamp of the last
          # addressed comment so already-handled comments are not re-surfaced and
          # re-dispatched as fresh rework. Edited comments (newer activity) still
          # resurface, and genuinely new comments are still picked up.
          {_all, []} ->
            comments_after_addressed_at(comments, record)
        end

      _ ->
        comments
    end
  end

  defp comments_after_addressed_at(comments, record) do
    case Map.get(record, :last_addressed_comment_at) do
      %DateTime{} = addressed_at -> reject_comments_at_or_before(comments, addressed_at)
      _ -> comments
    end
  end

  defp comments_after_last_action(comments, record) do
    case Map.get(record, :last_action_at) do
      %DateTime{} = last_action_at -> reject_comments_at_or_before(comments, last_action_at)
      _ -> comments
    end
  end

  defp reject_comments_at_or_before(comments, %DateTime{} = boundary) do
    Enum.reject(comments, fn comment ->
      case comment_activity_at(comment) do
        %DateTime{} = activity_at -> DateTime.compare(activity_at, boundary) in [:lt, :eq]
        _ -> false
      end
    end)
  end

  defp latest_comment_id([]), do: nil

  defp latest_comment_id(comments) when is_list(comments) do
    comments
    |> sort_comments()
    |> List.last()
    |> case do
      nil -> nil
      comment -> Map.get(comment, :id)
    end
  end

  defp latest_comment_activity_at(comments) when is_list(comments) do
    comments
    |> Enum.map(&comment_activity_at/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp comment_activity_at(comment) when is_map(comment), do: Map.get(comment, :updated_at) || Map.get(comment, :created_at)
  defp comment_activity_at(_comment), do: nil

  defp comment_sort_timestamp(comment) do
    case comment_activity_at(comment) do
      %DateTime{} = datetime -> DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp fallback_comment_id(comment) when is_map(comment) do
    [
      string_field(comment, :kind),
      string_field(comment, :author),
      string_field(comment, :url),
      string_field(comment, :body),
      datetime_field(comment, :created_at),
      datetime_field(comment, :updated_at)
    ]
    |> Enum.map_join("|", &fallback_id_part/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fallback_id_part(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp fallback_id_part(nil), do: ""
  defp fallback_id_part(value), do: to_string(value)

  defp string_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp integer_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp non_negative_integer_field(map, key) when is_map(map) and is_atom(key) do
    case integer_field(map, key) do
      value when value >= 0 -> value
      _value -> 0
    end
  end

  defp positive_integer_field(map, key) when is_map(map) and is_atom(key) do
    case integer_field(map, key) do
      value when value > 0 -> value
      _value -> nil
    end
  end

  defp datetime_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      %DateTime{} = datetime -> datetime
      _value -> nil
    end
  end

  defp cooldown_elapsed?(%DateTime{} = latest_activity_at, %DateTime{} = now, cooldown_minutes) do
    DateTime.diff(now, latest_activity_at, :second) >= cooldown_minutes * 60
  end

  defp cooldown_elapsed?(_latest_activity_at, _now, _cooldown_minutes), do: true

  defp stale?(%DateTime{} = latest_activity_at, %DateTime{} = now, stale_days) do
    DateTime.diff(now, latest_activity_at, :day) >= stale_days
  end

  defp stale?(_latest_activity_at, _now, _stale_days), do: false

  defp closed_pr_state?(state) do
    state
    |> normalize_decision()
    |> then(&(&1 in @closed_pr_states))
  end

  defp merged_pr_state?(state) do
    state
    |> normalize_decision()
    |> then(&(&1 == @merged_pr_state))
  end

  defp normalize_decision(value) when is_binary(value) do
    value |> String.trim() |> String.upcase()
  end

  defp normalize_decision(_value), do: nil

  defp list_runs(run_store, repo_key) do
    case list_run_records(run_store, repo_key) do
      runs when is_list(runs) -> {:ok, runs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_pr_reviews(run_store, repo_key) do
    case list_pr_review_records(run_store, repo_key) do
      reviews when is_list(reviews) -> {:ok, reviews}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_run_records(run_store, repo_key) do
    cond do
      function_exported?(run_store, :list_runs, 2) ->
        run_store.list_runs(repo_key, :all)

      function_exported?(run_store, :list_runs, 1) ->
        run_store.list_runs(:all)

      true ->
        {:error, :runs_unsupported}
    end
  end

  defp list_pr_review_records(run_store, repo_key) do
    cond do
      function_exported?(run_store, :list_pr_reviews, 1) ->
        run_store.list_pr_reviews(repo_key)

      function_exported?(run_store, :list_pr_reviews, 0) ->
        run_store.list_pr_reviews()

      true ->
        {:error, :pr_reviews_unsupported}
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

  defp put_record_repo_key(opts, record) do
    case Map.get(record, :repo_key) do
      repo_key when is_binary(repo_key) and repo_key != "" -> Keyword.put(opts, :repo_key, repo_key)
      _repo_key -> opts
    end
  end

  defp error_acc(:missing, reason), do: {:error, reason}
  defp error_acc({:error, _reason} = acc, _new_reason), do: acc

  defp delete_pr_review_record(run_store, repo_key, issue_id) do
    cond do
      function_exported?(run_store, :delete_pr_review, 2) ->
        run_store.delete_pr_review(repo_key, issue_id)

      function_exported?(run_store, :delete_pr_review, 1) ->
        run_store.delete_pr_review(issue_id)

      true ->
        {:error, :pr_reviews_unsupported}
    end
  end

  defp clear_pending_comment_lookup_error(run_store, record, now) do
    if Map.get(record, :pending_reviewer_comments_lookup_error) in [nil, ""] do
      :ok
    else
      issue_id = Map.get(record, :issue_id)

      attrs = %{
        pending_reviewer_comments_lookup_error: nil,
        pending_reviewer_comments_lookup_error_at: nil,
        updated_at: now
      }

      case update_review_direct(run_store, Map.fetch!(record, :repo_key), issue_id, attrs) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to clear pending PR review comment lookup error issue_id=#{issue_id}: #{inspect(reason)}")
      end
    end
  end

  defp record_pending_comment_lookup_error(run_store, repo_key, issue_id, reason, now) do
    Logger.warning("Failed to load pending PR review comments issue_id=#{issue_id}: #{inspect(reason)}")

    attrs = %{
      pending_reviewer_comments_lookup_error: inspect(reason),
      pending_reviewer_comments_lookup_error_at: now,
      updated_at: now
    }

    case update_review_direct(run_store, repo_key, issue_id, attrs) do
      :ok ->
        :ok

      {:error, update_reason} ->
        Logger.warning("Failed to record pending PR review comment lookup error issue_id=#{issue_id} reason=#{inspect(reason)}: #{inspect(update_reason)}")
    end
  end

  defp update_review_direct(run_store, repo_key, issue_id, attrs) when is_binary(issue_id) do
    cond do
      function_exported?(run_store, :update_pr_review, 3) ->
        case run_store.update_pr_review(repo_key, issue_id, attrs) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      function_exported?(run_store, :update_pr_review, 2) ->
        case run_store.update_pr_review(issue_id, attrs) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :update_pr_review_unavailable}
    end
  end

  defp update_review_direct(_run_store, _repo_key, _issue_id, _attrs), do: {:error, :invalid_issue_id}

  defp persist_pr_review(run_store, record) do
    case run_store.put_pr_review(record) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_review(opts, record, attrs) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    issue_id = Map.get(record, :issue_id)

    case Map.get(record, :repo_key) || Keyword.get(opts, :repo_key) do
      repo_key when is_binary(repo_key) ->
        case update_review_direct(run_store, repo_key, issue_id, attrs) do
          :ok ->
            :ok

          {:error, :pr_review_not_found} ->
            upsert_review(run_store, repo_key, record, attrs)

          {:error, reason} ->
            log_review_store_error("update", issue_id, attrs, reason)
            {:error, {:update_pr_review_failed, reason}}
        end

      _repo_key ->
        {:error, :missing_repo_key}
    end
  end

  defp upsert_review(run_store, repo_key, record, attrs) do
    issue_id = Map.get(record, :issue_id)

    case run_store.put_pr_review(record |> Map.merge(attrs) |> Map.put(:repo_key, repo_key)) do
      :ok ->
        :ok

      {:error, reason} ->
        log_review_store_error("upsert", issue_id, attrs, reason)
        {:error, {:put_pr_review_failed, reason}}
    end
  end

  defp complete_review_update(opts, record, attrs, success_action) do
    case update_review(opts, record, attrs) do
      :ok -> success_action
      {:error, reason} -> {:update_error, Map.get(record, :issue_id), reason}
    end
  end

  defp dispatch_paused?(opts) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    if function_exported?(run_store, :get_paused, 0) do
      case run_store.get_paused() do
        %{paused: true} -> true
        _ -> false
      end
    else
      false
    end
  end

  defp maybe_backfill_review_issue_details(record, opts, now) do
    if present?(Map.get(record, :issue_title)) do
      {:ok, record}
    else
      record
      |> fetch_review_issue(opts)
      |> backfill_review_issue_details(record, opts, now)
    end
  end

  defp fetch_review_issue(record, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)

    with issue_id when is_binary(issue_id) and issue_id != "" <- issue_id,
         {:ok, issues} <- tracker.fetch_issue_states_by_ids([issue_id]),
         %Issue{} = issue <- Enum.find(issues, &(&1.id == issue_id)) do
      {:ok, issue}
    else
      nil -> :missing
      "" -> :missing
      {:error, reason} -> {:error, reason}
      _other -> :missing
    end
  end

  defp backfill_review_issue_details({:ok, %Issue{} = issue}, record, opts, now) do
    attrs =
      record
      |> missing_issue_detail_attrs(issue)
      |> maybe_put_updated_at(now)

    if map_size(attrs) > 0 do
      case update_review(opts, record, attrs) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("Failed to backfill PR review issue details issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
      end

      {:ok, Map.merge(record, attrs)}
    else
      {:ok, record}
    end
  end

  defp backfill_review_issue_details(:missing, record, _opts, _now), do: {:ok, record}

  defp backfill_review_issue_details({:error, reason}, record, _opts, _now) do
    Logger.debug("Failed to fetch PR review issue details issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
    {:ok, record}
  end

  defp missing_issue_detail_attrs(record, %Issue{} = issue) do
    %{}
    |> maybe_put_missing(:issue_identifier, record, issue.identifier)
    |> maybe_put_missing(:issue_title, record, issue.title)
    |> maybe_put_missing(:issue_url, record, issue.url)
  end

  defp missing_review_detail_attrs(record, %Issue{} = issue) do
    record
    |> missing_issue_detail_attrs(issue)
    |> maybe_put_missing(:pr_url, record, first_pr_url(issue))
  end

  defp missing_run_detail_attrs(attrs, _record, nil), do: attrs

  defp missing_run_detail_attrs(attrs, record, run) when is_map(run) do
    attrs
    |> maybe_put_missing(:run_id, record, Map.get(run, :run_id))
    |> maybe_put_missing(:transcript_path, record, Map.get(run, :transcript_path))
  end

  defp maybe_put_missing(attrs, key, record, value) do
    if present?(Map.get(record, key)) or not present?(value) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp maybe_put_updated_at(attrs, _now) when map_size(attrs) == 0, do: attrs
  defp maybe_put_updated_at(attrs, now), do: Map.put(attrs, :updated_at, now)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp maybe_reply_to_comments(record, [], _settings, _github, _opts, _now), do: {:ok, record}

  defp maybe_reply_to_comments(record, comments, settings, github, opts, now) do
    case Map.get(settings.pr_review, :auto_reply, false) do
      true -> reply_to_comments(record, comments, github, opts, now)
      _ -> {:ok, record}
    end
  end

  @skip_comments_filename ".symphony-skip-comments.json"

  defp reply_to_comments(record, comments, github, opts, now) do
    record = put_addressed_commit_sha(record)
    skip_ids = consume_skip_comment_ids(record)

    {inline_comments, pr_level_comments} =
      comments
      |> reject_replied_comments(record)
      |> reject_skipped_comments(skip_ids, record)
      |> Enum.split_with(&inline_comment?/1)

    case reply_to_inline_comments(record, inline_comments, github, opts, now) do
      {:ok, record} -> reply_to_pr_level_comments(record, pr_level_comments, github, opts, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_replied_comments(comments, record) do
    replied_ids = MapSet.new(replied_comment_ids(record))
    Enum.reject(comments, &(Map.get(&1, :id) in replied_ids))
  end

  # The rework agent can mark clearly non-actionable bot comments in a workspace
  # skip file so they don't receive the auto-reply note. We only honor the skip for
  # bot-authored comments (the agent can never silence a human reviewer this way),
  # and the file is consumed per run so a reused worktree carries no stale entries.
  defp reject_skipped_comments(comments, skip_ids, record) do
    {skipped, kept} =
      Enum.split_with(comments, fn comment ->
        Map.get(comment, :id) in skip_ids and bot_author?(comment)
      end)

    log_skipped_comments(skipped, record)
    kept
  end

  defp bot_author?(comment) do
    author = Map.get(comment, :author)
    is_binary(author) and String.ends_with?(author, "[bot]")
  end

  # Reads the agent-written skip list (local workspaces only) and deletes the file.
  # Any missing/unreadable/malformed file yields an empty set so behavior degrades
  # to "reply as usual" rather than silently dropping replies.
  defp consume_skip_comment_ids(record) do
    case skip_comments_path(record) do
      nil ->
        MapSet.new()

      path ->
        ids = read_skip_comment_ids(path)
        _ = File.rm(path)
        MapSet.new(ids)
    end
  end

  defp skip_comments_path(record) do
    case Map.get(record, :workspace_path) do
      path when is_binary(path) and path != "" -> Path.join(path, @skip_comments_filename)
      _ -> nil
    end
  end

  defp read_skip_comment_ids(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"skip_comment_ids" => ids}} when is_list(ids) <- Jason.decode(body) do
      Enum.filter(ids, &is_binary/1)
    else
      _ -> []
    end
  end

  defp log_skipped_comments([], _record), do: :ok

  defp log_skipped_comments(skipped, record) do
    ids = Enum.map_join(skipped, ",", &to_string(Map.get(&1, :id)))

    Logger.info(
      "PR review auto-reply skipped non-actionable bot comments " <>
        "issue_id=#{Map.get(record, :issue_id)} count=#{length(skipped)} ids=#{ids}"
    )
  end

  defp inline_comment?(%{kind: "inline_comment"}), do: true
  defp inline_comment?(_comment), do: false

  defp reply_to_inline_comments(record, comments, github, opts, now) do
    Enum.reduce_while(comments, {:ok, record}, fn comment, {:ok, record} ->
      case reply_to_inline_comment(record, comment, github, opts, now) do
        {:ok, updated_record} -> {:cont, {:ok, updated_record}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reply_to_inline_comment(record, comment, github, opts, now) do
    case github.reply_to_comment(Map.get(record, :pr_url), comment, addressed_comment_reply(record), cwd: Map.get(record, :workspace_path)) do
      :ok -> mark_inline_comment_replied(record, comment, opts, now)
      {:error, reason} -> {:error, {:auto_reply_failed, Map.get(comment, :id), reason}}
    end
  end

  defp mark_inline_comment_replied(record, comment, opts, now) do
    case mark_comments_replied(record, [Map.get(comment, :id)], opts, now) do
      {:ok, updated_record} -> {:ok, updated_record}
      {:error, reason} -> handle_auto_reply_state_update_failure(record, [comment], opts, now, reason)
    end
  end

  defp reply_to_pr_level_comments(record, [], _github, _opts, _now), do: {:ok, record}

  defp reply_to_pr_level_comments(record, comments, github, opts, now) do
    summary_comment = %{id: "pr-review-summary", kind: "comment"}

    case github.reply_to_comment(Map.get(record, :pr_url), summary_comment, addressed_comment_summary_reply(record, comments), cwd: Map.get(record, :workspace_path)) do
      :ok ->
        case mark_comments_replied(record, Enum.map(comments, &Map.get(&1, :id)), opts, now) do
          {:ok, updated_record} -> {:ok, updated_record}
          {:error, reason} -> handle_auto_reply_state_update_failure(record, comments, opts, now, reason)
        end

      {:error, reason} ->
        {:error, {:auto_reply_failed, "pr-review-summary", reason}}
    end
  end

  defp put_addressed_commit_sha(record) do
    case addressed_commit_sha(record) do
      nil -> record
      sha -> Map.put(record, :addressed_commit_sha, sha)
    end
  end

  defp addressed_commit_sha(record) do
    recorded_addressed_commit_sha(record) ||
      current_workspace_follow_up_commit_sha(record)
  end

  defp recorded_addressed_commit_sha(record) do
    case normalize_commit_sha(string_field(record, :addressed_commit_sha)) do
      nil -> nil
      sha -> follow_up_commit_sha(sha, reviewed_commit_sha(record))
    end
  end

  defp current_workspace_follow_up_commit_sha(record) when is_map(record) do
    workspace = string_field(record, :workspace_path)

    cond do
      remote_worker?(record) ->
        nil

      is_nil(workspace) or String.trim(workspace) == "" ->
        nil

      true ->
        workspace_follow_up_commit_sha(workspace, reviewed_commit_sha(record))
    end
  end

  defp workspace_follow_up_commit_sha(_workspace, nil), do: nil

  defp workspace_follow_up_commit_sha(workspace, reviewed_sha) do
    workspace
    |> read_workspace_head_sha()
    |> follow_up_commit_sha(reviewed_sha)
  end

  defp follow_up_commit_sha(nil, _reviewed_sha), do: nil

  defp follow_up_commit_sha(candidate_sha, nil), do: candidate_sha

  defp follow_up_commit_sha(candidate_sha, reviewed_sha) do
    if same_commit_sha?(candidate_sha, reviewed_sha) do
      nil
    else
      candidate_sha
    end
  end

  defp reviewed_commit_sha(record) when is_map(record) do
    reviewed_commit_sha_from_record(record) ||
      reviewed_commit_sha_from_comments(Map.get(record, :pending_reviewer_comments, []))
  end

  defp reviewed_commit_sha_from_record(record) do
    [:reviewed_commit_sha, :reviewed_sha]
    |> Enum.find_value(&normalize_commit_sha(string_field(record, &1)))
  end

  defp reviewed_commit_sha_from_comments(comments) when is_list(comments) do
    comments
    |> normalize_comments()
    |> Enum.reverse()
    |> Enum.find_value(&normalize_commit_sha(string_field(&1, :commit_id)))
  end

  defp reviewed_commit_sha_from_comments(_comments), do: nil

  defp same_commit_sha?(left, right) when is_binary(left) and is_binary(right) do
    left = String.downcase(left)
    right = String.downcase(right)

    String.starts_with?(left, right) or String.starts_with?(right, left)
  end

  defp same_commit_sha?(_left, _right), do: false

  defp remote_worker?(record) do
    case string_field(record, :worker_host) do
      nil -> false
      "" -> false
      _worker_host -> true
    end
  end

  defp read_workspace_head_sha(workspace) do
    case Workspace.safe_git(["-C", workspace, "rev-parse", "--short=12", "HEAD"]) do
      {output, 0} -> normalize_commit_sha(output)
      _other -> nil
    end
  end

  defp normalize_commit_sha(output) when is_binary(output) do
    sha = String.trim(output)

    if sha =~ ~r/\A[0-9a-f]{7,40}\z/i do
      sha
    end
  end

  defp normalize_commit_sha(_output), do: nil

  defp mark_comments_replied(record, comment_ids, opts, now) do
    ids =
      comment_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))

    attrs = %{
      replied_comment_ids: cap_replied_comment_ids(Enum.uniq(replied_comment_ids(record) ++ ids)),
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok -> {:ok, Map.merge(record, attrs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_auto_reply_state_update_failure(record, comments, opts, now, reason) do
    ids = comments |> Enum.map(&Map.get(&1, :id)) |> Enum.filter(&is_binary/1)
    issue_id = Map.get(record, :issue_id)

    Logger.error("Auto reply posted but failed to persist replied_comment_ids issue_id=#{issue_id} comment_ids=#{inspect(ids)}; retries may duplicate GitHub replies: #{inspect(reason)}")

    attrs = %{
      auto_reply_state_update_error: inspect({ids, reason}),
      auto_reply_state_update_error_at: now,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok ->
        :ok

      {:error, update_reason} ->
        Logger.error("Failed to record auto reply state update error issue_id=#{issue_id} comment_ids=#{inspect(ids)}: #{inspect(update_reason)}")
    end

    {:error, {:auto_reply_state_update_failed, List.first(ids), reason}}
  end

  defp replied_comment_ids(record) when is_map(record) do
    record
    |> Map.get(:replied_comment_ids, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Carry the reply ledger forward across cursor advances (most recently replied
  # ids last) so already-answered comments are not re-replied, bounded to the most
  # recent @max_replied_comment_ids entries.
  defp retained_replied_comment_ids(record) when is_map(record) do
    record
    |> replied_comment_ids()
    |> cap_replied_comment_ids()
  end

  # Keep only the most recent @max_replied_comment_ids entries so the per-PR ledger
  # stays bounded everywhere it is written, not just at cursor advance.
  defp cap_replied_comment_ids(ids), do: Enum.take(ids, -@max_replied_comment_ids)

  defp maybe_request_review(_record, [], _settings, _github, _opts, _now), do: :ok

  defp maybe_request_review(record, comments, settings, github, opts, now) do
    if Map.get(settings.pr_review, :auto_request_review, false) do
      comments
      |> reviewers_for_request(record, settings)
      |> request_review(record, github)
      |> handle_request_review_result(record, opts, now)
    else
      :ok
    end
  end

  defp handle_request_review_result(:ok, _record, _opts, _now), do: :ok

  defp handle_request_review_result({:error, reason}, record, opts, now) do
    issue_id = Map.get(record, :issue_id)

    Logger.warning("Failed to request follow-up PR review issue_id=#{issue_id}: #{inspect(reason)}")

    attrs = %{
      auto_request_review_error: inspect(reason),
      auto_request_review_error_at: now,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok ->
        :ok

      {:error, update_reason} ->
        Logger.warning("Failed to record follow-up PR review request error issue_id=#{issue_id}: #{inspect(update_reason)}")
        :ok
    end
  end

  defp reviewers_for_request(comments, record, settings) do
    # GitHub rejects review requests to the PR author, so skip Symphony's own account.
    ignored = normalize_users(configured_ignored_users(settings) ++ string_list(Map.get(record, :review_self_users)))

    comments
    |> Enum.map(&Map.get(&1, :author))
    |> Enum.reject(&(normalize_user(&1) in ignored))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp request_review([], _record, _github), do: :ok

  defp request_review(reviewers, record, github) do
    case github.request_review(Map.get(record, :pr_url), reviewers, cwd: Map.get(record, :workspace_path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:auto_request_review_failed, reason}}
    end
  end

  defp addressed_comment_reply(record) do
    [
      "Automated note from Symphony AI: this review comment was marked complete after the latest follow-up update.",
      addressed_commit_sentence(record),
      "Please check the current diff; reply here if it still needs work."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp addressed_comment_summary_reply(record, comments) do
    references =
      Enum.map_join(comments, "\n", &summary_comment_reference/1)

    [
      "Automated note from Symphony AI: these PR-level review comments were marked complete after the latest follow-up update.",
      addressed_commit_sentence(record),
      "Please check the current diff; reply if anything still needs work.\n\nComments:\n#{references}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp addressed_commit_sentence(record) do
    case string_field(record, :addressed_commit_sha) do
      nil -> nil
      sha -> "Follow-up commit: `#{sha}`."
    end
  end

  defp summary_comment_reference(comment) do
    label =
      comment
      |> summary_comment_label()
      |> maybe_link_comment_reference(Map.get(comment, :url))

    case comment_body_excerpt(comment) do
      nil -> "- #{label}"
      excerpt -> "- #{label}: #{excerpt}"
    end
  end

  defp summary_comment_label(comment) do
    id = Map.get(comment, :id) || "unknown-comment"
    author = Map.get(comment, :author)
    type = summary_comment_type(comment)

    if is_binary(author) and String.trim(author) != "" do
      "#{String.trim(author)} #{type} (`#{id}`)"
    else
      "#{type} (`#{id}`)"
    end
  end

  defp summary_comment_type(%{kind: "review"}), do: "review summary"
  defp summary_comment_type(%{kind: "comment"}), do: "PR comment"
  defp summary_comment_type(_comment), do: "review comment"

  defp maybe_link_comment_reference(label, url) when is_binary(url) do
    case String.trim(url) do
      "" -> label
      trimmed -> "[#{markdown_link_label(label)}](#{trimmed})"
    end
  end

  defp maybe_link_comment_reference(label, _url), do: label

  defp markdown_link_label(label) do
    label
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
  end

  defp comment_body_excerpt(comment) do
    comment
    |> Map.get(:body)
    |> first_body_line()
  end

  defp first_body_line(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> normalize_body_excerpt()
  end

  defp first_body_line(_body), do: nil

  defp normalize_body_excerpt(nil), do: nil

  defp normalize_body_excerpt(line) do
    line
    |> String.trim_leading("#")
    |> String.trim()
    |> truncate_body_excerpt()
  end

  defp truncate_body_excerpt(line) do
    if String.length(line) <= 120 do
      line
    else
      line
      |> String.slice(0, 117)
      |> String.trim()
      |> Kernel.<>("...")
    end
  end

  defp log_review_store_error(operation, issue_id, attrs, reason) do
    Logger.warning("Failed to #{operation} PR review record issue_id=#{issue_id} target_status=#{inspect(Map.get(attrs, :status))}: #{inspect(reason)}")
  end

  defp backoff_active_until(record, now) do
    case Map.get(record, :next_poll_at) do
      %DateTime{} = next_poll_at ->
        if DateTime.compare(next_poll_at, now) == :gt do
          {:backing_off, next_poll_at}
        else
          :ready
        end

      _next_poll_at ->
        :ready
    end
  end

  defp poll_error_attrs(record, reason, opts, now) do
    consecutive_errors = consecutive_errors(record) + 1

    attrs = %{
      status: "poll_error",
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

  defp cleanup_error_attrs(record, reason, opts, now) do
    consecutive_errors = consecutive_errors(record) + 1

    %{
      status: "cleanup_error",
      error: inspect(reason),
      consecutive_errors: consecutive_errors,
      next_poll_at: DateTime.add(now, cleanup_error_backoff_ms(consecutive_errors, opts), :millisecond),
      updated_at: now
    }
  end

  defp consecutive_errors(record) do
    case Map.get(record, :consecutive_errors) do
      value when is_integer(value) and value >= 0 -> value
      _value -> 0
    end
  end

  defp maybe_emit_poll_run_failed(record, %{consecutive_errors: consecutive_errors}, reason)
       when consecutive_errors >= @github_error_backoff_threshold do
    if consecutive_errors(record) < @github_error_backoff_threshold do
      Notifications.emit_event(:run_failed, %{
        issue_id: Map.get(record, :issue_id),
        issue_identifier: Map.get(record, :issue_identifier),
        issue_url: Map.get(record, :issue_url),
        pr_url: Map.get(record, :pr_url),
        state: @in_review_state,
        reason: "PR review polling failed #{consecutive_errors} consecutive times: #{inspect(reason)}",
        metadata: %{
          source: "pr_review_poller",
          consecutive_errors: consecutive_errors
        }
      })
    end
  end

  defp maybe_emit_poll_run_failed(_record, _attrs, _reason), do: :ok

  defp maybe_emit_reviewer_commented(record, attrs, "rework", now) do
    comments = attrs |> Map.get(:pending_reviewer_comments, []) |> normalize_comments()

    if comments != [] do
      Notifications.emit_event(
        :reviewer_commented,
        reviewer_feedback_event_attrs(record, %{
          state: @active_state,
          reason: actionable_comment_reason(comments, "discovered"),
          timestamp: now,
          metadata: reviewer_feedback_metadata(comments)
        })
      )
    end
  end

  defp maybe_emit_reviewer_commented(_record, _attrs, _action, _now), do: :ok

  defp emit_rework_pushed(_record, [], _cursor, _now), do: :ok

  defp emit_rework_pushed(record, comments, cursor, now) do
    Notifications.emit_event(
      :rework_pushed,
      reviewer_feedback_event_attrs(record, %{
        state: @active_state,
        reason: actionable_comment_reason(comments, "addressed"),
        timestamp: now,
        metadata: reviewer_feedback_metadata(comments, cursor)
      })
    )
  end

  defp reviewer_feedback_event_attrs(record, attrs) do
    %{
      issue_id: Map.get(record, :issue_id),
      issue_identifier: Map.get(record, :issue_identifier),
      issue_title: Map.get(record, :issue_title),
      issue_url: Map.get(record, :issue_url),
      pr_url: Map.get(record, :pr_url)
    }
    |> Map.merge(attrs)
  end

  defp actionable_comment_reason([_comment], verb), do: "1 actionable reviewer comment #{verb}"
  defp actionable_comment_reason(comments, verb), do: "#{length(comments)} actionable reviewer comments #{verb}"

  defp reviewer_feedback_metadata(comments, latest_comment_id \\ nil) do
    comments = normalize_comments(comments)
    latest_comment_id = latest_comment_id || latest_comment_id(comments)

    %{
      source: "pr_review_poller",
      comment_count: length(comments),
      latest_comment_id: latest_comment_id
    }
  end

  defp append_string(values, value) when is_binary(value) and value != "" do
    values
    |> string_list()
    |> Kernel.++([value])
    |> Enum.uniq()
  end

  defp append_string(values, _value), do: string_list(values)

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_values), do: []

  defp github_error_backoff_ms(consecutive_errors, opts) do
    exponent = max(consecutive_errors - @github_error_backoff_threshold, 0)

    poll_interval_ms(opts)
    |> Kernel.*(Integer.pow(2, exponent))
    |> min(@max_github_error_backoff_ms)
  end

  defp cleanup_error_backoff_ms(consecutive_errors, opts) do
    exponent = max(consecutive_errors - 1, 0)

    poll_interval_ms(opts)
    |> Kernel.*(Integer.pow(2, exponent))
    |> min(@max_github_error_backoff_ms)
  end

  defp poll_cycle_result(%State{} = state) do
    case poll_once(state.opts) do
      {:ok, summary} ->
        Logger.debug("PR review poll completed: #{inspect(summary)}")
        log_poll_action_warnings(summary)
        :ok

      {:error, reason} ->
        {:error, "PR review poll failed: #{inspect(reason)}", reason}
    end
  rescue
    exception ->
      formatted = Exception.format(:error, exception, __STACKTRACE__)
      {:error, "PR review poll raised: #{formatted}", exception}
  catch
    kind, reason ->
      formatted = Exception.format(kind, reason, __STACKTRACE__)
      {:error, "PR review poll failed with #{kind}: #{formatted}", {kind, reason}}
  end

  defp handle_poll_success(%State{consecutive_failures: 0} = state), do: reset_poll_failure_state(state)

  defp handle_poll_success(%State{} = state) do
    Logger.info("PR review poll recovered after #{state.consecutive_failures} consecutive failures")
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
    Logger.error("PR review poll backing off after #{consecutive_failures} consecutive failures; next poll in #{backoff_ms}ms")
  end

  defp maybe_log_poll_failure(_state, _consecutive_failures, _backoff_ms, _message), do: :ok

  defp maybe_record_poller_degraded(%State{degraded?: true}, _consecutive_failures, _backoff_ms, _reason), do: :ok

  defp maybe_record_poller_degraded(%State{} = state, consecutive_failures, backoff_ms, reason) do
    if consecutive_failures >= poller_degraded_threshold(state.opts) do
      record_poller_audit(
        %{
          event_type: "poller_degraded",
          poller: "pr_review",
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
        poller: "pr_review",
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
      {:error, reason} -> Logger.warning("Failed to record PR review poller audit event: #{inspect(reason)}")
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

  defp action_atom("rework"), do: :rework
  defp action_atom("merge"), do: :merge
  defp action_atom("conflict"), do: :conflict
  defp action_atom("done"), do: :done

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
        settings = Config.settings!()
        settings.pr_review.poll_interval_ms || settings.polling.interval_ms
    end
  end
end
