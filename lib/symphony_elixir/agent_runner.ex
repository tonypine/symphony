defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured agent.
  """

  require Logger

  alias SymphonyElixir.{
    AgentLabels,
    AgentTmpDir,
    AgentTools,
    AgentTools.Linear.CommentRegistry,
    AuditLog,
    AutoReview,
    AutoReview.ParentWalkthrough,
    CiPoller,
    Config,
    DependencyAudit,
    DependencyGate,
    GitHub.PullRequest,
    LeftoverProcesses,
    Linear.Issue,
    Linear.TransientRetry,
    Linear.Usage,
    Notifications,
    PromptBuilder,
    PrReviewPoller,
    ReviewAgent,
    RunKind,
    RunStore,
    SubIssueWait,
    Tracker,
    URLUtils,
    UsageLimit,
    Verification,
    Workpad,
    Workspace,
    WorkspaceHead
  }

  @dev_server_pid_key {__MODULE__, :verification_dev_server_pid}
  @dependency_review_state "In Review"
  @idle_park_state "Backlog"
  # Consecutive turns with no new commit, no state change and no PR change that end the run.
  @max_empty_turns 2
  # Fallback when settings are unavailable; the effective value comes from
  # `agent.codex_stdio_prompt_soft_limit` (see Config.Schema.Agent).
  @codex_stdio_prompt_soft_limit_fallback 65_536
  @terminal_agent_setup_error_marker "missing_required_mcp_tools"
  @tmp_dir_prefix "symphony-run-"

  @type worker_host :: String.t() | nil

  @doc """
  The kind of run `issue` is about to start and its model and effort, from `settings`.

  The orchestrator resolves this once per dispatch and passes it as `:run_profile`, so every
  turn of the run, continuations included, starts the agent with the same model and effort.
  """
  @spec run_profile(Issue.t(), Config.Schema.t(), keyword()) :: RunKind.profile()
  def run_profile(%Issue{} = issue, settings, opts \\ []) do
    kind =
      RunKind.classify(issue,
        terminal_states: settings.tracker.terminal_states,
        ci_failure: pending_ci_failure(issue, opts),
        reviewer_comments: pending_reviewer_comments(issue, opts)
      )

    settings |> Config.run_profile(kind) |> Map.put(:kind, kind) |> UsageLimit.for_agent_kind(settings.agent.kind)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    repo_key = run_repo_key(issue, opts)
    settings = Config.settings_for_repo!(repo_key)

    opts =
      opts
      |> Keyword.put(:repo_key, repo_key)
      |> Keyword.put(:settings, settings)
      |> put_linear_wait_notice(issue, codex_update_recipient)

    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), settings.worker.ssh_hosts)
    Usage.put_caller({:agent, Map.get(issue, :identifier)})

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")

        cond do
          usage_limit = usage_limit_reason(reason) ->
            exit({:usage_limited, usage_limit})

          terminal_agent_setup_error?(reason) ->
            exit({:terminal_agent_setup_error, reason})

          terminal_review_agent_block?(reason) ->
            exit(reason)

          terminal_tool_failure_circuit_breaker?(reason) ->
            exit(reason)

          linear_unavailable?(reason) ->
            exit({:linear_unavailable, reason})

          true ->
            raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end
    end
  end

  # The orchestrator holds the provider's runs until the limit resets instead of failing the run.
  defp usage_limit_reason({:usage_limited, %{} = info}), do: info
  defp usage_limit_reason(_reason), do: nil

  defp terminal_review_agent_block?({:review_agent_blocked, _reason}), do: true
  defp terminal_review_agent_block?(_reason), do: false

  defp terminal_tool_failure_circuit_breaker?({:tool_failure_circuit_breaker, _payload}), do: true
  defp terminal_tool_failure_circuit_breaker?(_reason), do: false

  # Tells the orchestrator before each wait on Linear in this run, so its stall check and
  # no-progress watchdog count the wait as activity instead of restarting the run.
  defp put_linear_wait_notice(opts, %{id: issue_id}, recipient) when is_binary(issue_id) and is_pid(recipient) do
    notify = fn _reason, delay_ms -> send(recipient, {:linear_wait, issue_id, delay_ms}) end
    Keyword.update(opts, :linear_retry_opts, [on_wait: notify], &Keyword.put_new(&1, :on_wait, notify))
  end

  defp put_linear_wait_notice(opts, _issue, _recipient), do: opts

  # A step that still could not reach Linear once its wait ran out, such as
  # `{:idle_park_failed, {:linear_rate_limited, until_ms}}`, failed through no fault of the
  # issue; the orchestrator retries the run without counting an attempt.
  defp linear_unavailable?(reason) when is_tuple(reason) and tuple_size(reason) > 1 do
    reason |> elem(tuple_size(reason) - 1) |> TransientRetry.transient?()
  end

  defp linear_unavailable?(_reason), do: false

  defp terminal_agent_setup_error?(reason) do
    reason
    |> inspect()
    |> String.contains?(@terminal_agent_setup_error_marker)
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")
    settings = Keyword.fetch!(opts, :settings)

    case Verification.context_for_agent(issue, Keyword.put(opts, :worker_host, worker_host)) do
      {:ok, verification} ->
        verification_env = Verification.env(verification)

        case workspace_for_issue(issue, codex_update_recipient, opts, worker_host) do
          {:ok, workspace} ->
            send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)
            tmp_dirs = run_tmp_dirs(workspace, worker_host, opts)
            opts = put_agent_tmp_dir(opts, tmp_dirs, issue)

            result =
              try do
                with :ok <-
                       Workspace.run_before_run_hook(workspace, issue, worker_host,
                         env: verification_env,
                         settings: settings,
                         on_hook: workspace_hook_listener(codex_update_recipient, issue)
                       ),
                     {:ok, dev_server_pid} <-
                       Verification.start_dev_server(verification, workspace, settings: settings) do
                  remember_verification_dev_server(dev_server_pid)
                  enriched_issue = enrich_issue_for_dispatch(issue, opts)

                  # Start the comment registry before workpad bootstrap so the
                  # bootstrap comment is recorded as run-owned at creation time
                  # instead of relying on the post-hoc Linear re-query, which can
                  # miss a just-created comment (read lag).
                  with {:ok, linear_comment_registry} <- CommentRegistry.start_link([]),
                       {:ok, bootstrapped_issue} <-
                         Workpad.bootstrap(
                           enriched_issue,
                           workspace,
                           opts
                           |> Keyword.put(:worker_host, worker_host)
                           |> Keyword.put(:comment_registry, linear_comment_registry)
                         ) do
                    try do
                      run_issue(
                        workspace,
                        bootstrapped_issue,
                        codex_update_recipient,
                        Keyword.put(opts, :linear_comment_registry, linear_comment_registry),
                        worker_host
                      )
                    after
                      send_run_comment_ids(codex_update_recipient, issue, linear_comment_registry)
                    end
                  end
                end
              after
                Workspace.run_after_run_hook(workspace, issue, worker_host,
                  env: verification_env,
                  settings: settings
                )

                stop_remembered_verification_dev_server()
                stop_leftover_processes(workspace, tmp_dirs, issue, worker_host, opts)
                Verification.release(verification, "after_run completed")
              end

            finish_agent_tmp_dir(result, tmp_dirs, issue)
            result

          {:error, {:branch_already_checked_out_elsewhere, details}} = error ->
            log_branch_collision(issue, worker_host, details)
            Verification.release(verification, "workspace setup failed")
            error

          {:error, reason} ->
            Verification.release(verification, "workspace setup failed")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remember_verification_dev_server(pid) when is_pid(pid), do: Process.put(@dev_server_pid_key, pid)
  defp remember_verification_dev_server(_pid), do: :ok

  defp stop_remembered_verification_dev_server do
    case Process.delete(@dev_server_pid_key) do
      pid when is_pid(pid) -> Verification.stop_dev_server(pid)
      _ -> :ok
    end
  end

  @doc """
  The temp folders a local run in `workspace` may use, one under each of `bases`: the run
  takes the first one it can create (see `SymphonyElixir.AgentTmpDir`). Named after a short
  hash of the workspace, so `SymphonyElixir.StrayProcesses` can name the folder of a run in
  flight and the next run of the workspace removes one a failed run kept.
  """
  @spec tmp_dirs(Path.t(), [Path.t()]) :: [Path.t()]
  def tmp_dirs(workspace, bases \\ tmp_bases()), do: AgentTmpDir.paths(@tmp_dir_prefix, workspace, bases)

  # The test suite points runs at a folder of its own, so the folders failed runs keep stay out of `/tmp`.
  defp tmp_bases, do: Application.get_env(:symphony_elixir, :agent_run_tmp_bases) || AgentTmpDir.default_bases()

  # A remote worker's agent keeps its host's temp folder.
  defp run_tmp_dirs(workspace, nil, opts), do: tmp_dirs(workspace, Keyword.get_lazy(opts, :agent_tmp_bases, &tmp_bases/0))
  defp run_tmp_dirs(_workspace, _worker_host, _opts), do: []

  # Every agent session of the run, the pre-push reviewer's included, gets the folder as its
  # `$TMPDIR`, writable in its sandbox. A run that can't create one still runs, with the
  # runtime's default temp folder.
  defp put_agent_tmp_dir(opts, [], _issue), do: opts

  defp put_agent_tmp_dir(opts, tmp_dirs, issue) do
    case AgentTmpDir.create(tmp_dirs) do
      {:ok, tmp_dir} ->
        opts
        |> Keyword.put(:agent_tmp_dir, tmp_dir)
        |> Keyword.update!(:settings, &AgentTmpDir.allow_write(&1, tmp_dir))

      :error ->
        Logger.warning("Could not create a temp folder for #{issue_context(issue)}; the agent uses its runtime's default one paths=#{inspect(tmp_dirs)}")
        opts
    end
  end

  # Removed when the run succeeds, kept for debugging when it fails (until the workspace's next run).
  defp finish_agent_tmp_dir(:ok, tmp_dirs, _issue), do: Enum.each(tmp_dirs, &File.rm_rf/1)

  defp finish_agent_tmp_dir(_result, tmp_dirs, issue) do
    for tmp_dir <- tmp_dirs, File.dir?(tmp_dir) do
      Logger.info("Keeping the temp folder of a failed run for debugging #{issue_context(issue)} path=#{tmp_dir}")
    end

    :ok
  end

  # Stops what the agent left running in its workspace or temp folder, detached ones
  # included (see `SymphonyElixir.LeftoverProcesses`). The process table is read on this
  # host, so a remote worker's processes are left alone.
  defp stop_leftover_processes(workspace, tmp_dirs, issue, nil, opts) do
    leftover_opts = opts |> Keyword.get(:leftover_processes, []) |> Keyword.put(:log_context, issue_context(issue))
    claude_task_dirs = LeftoverProcesses.claude_task_dirs(workspace, Keyword.get(opts, :claude_tmp_dir, "/tmp"))
    LeftoverProcesses.stop_under([workspace | tmp_dirs ++ claude_task_dirs], leftover_opts)
    :ok
  end

  defp stop_leftover_processes(_workspace, _tmp_dirs, _issue, _worker_host, _opts), do: :ok

  defp enrich_issue_for_dispatch(issue, opts) do
    issue_enricher = Keyword.get(opts, :issue_enricher, &Tracker.enrich_issue/1)

    try do
      case with_linear_retry(fn -> issue_enricher.(issue) end, "enriching #{issue_context(issue)}", opts) do
        {:ok, enriched_issue} ->
          enriched_issue

        {:error, reason} ->
          Logger.warning("issue_enrichment_failed #{issue_context(issue)} reason=#{inspect(reason)}")
          issue
      end
    rescue
      exception ->
        Logger.warning("issue_enrichment_failed #{issue_context(issue)} reason=#{inspect(exception)}")
        issue
    end
  end

  defp workspace_for_issue(issue, codex_update_recipient, opts, worker_host) do
    case Keyword.get(opts, :workspace_path) do
      workspace when is_binary(workspace) and workspace != "" ->
        with :ok <- Workspace.validate(workspace, worker_host) do
          {:ok, workspace}
        end

      _ ->
        issue
        |> sync_workspace_to_pr_head(opts)
        |> Workspace.create_for_issue(worker_host, Keyword.get(opts, :repo_key),
          active_workspace_identifiers: Keyword.get(opts, :active_workspace_identifiers, []),
          on_hook: workspace_hook_listener(codex_update_recipient, issue)
        )
    end
  end

  # Tells the orchestrator a workspace hook is running, and until when, so its stall
  # and watchdog clocks wait out the hook's own timeout rather than end the run.
  defp workspace_hook_listener(recipient, %Issue{id: issue_id}) when is_pid(recipient) and is_binary(issue_id) do
    fn
      {:started, hook_name, timeout_ms} ->
        deadline = DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond)
        send(recipient, {:worker_runtime_info, issue_id, %{workspace_hook: %{name: hook_name, deadline: deadline}}})

      {:finished, _hook_name} ->
        send(recipient, {:worker_runtime_info, issue_id, %{workspace_hook: nil}})
    end
  end

  defp workspace_hook_listener(_recipient, _issue), do: nil

  # When an issue is dispatched to rework an existing PR (resolve a merge
  # conflict or address reviewer comments), the workspace must reflect the
  # latest remote PR head before the worktree is created or reused. Otherwise a
  # reused worktree keeps its stale state (base_ref nil => no `git reset --hard`)
  # and a fresh worktree branches off configured trunk, so commits pushed to the
  # PR head after the run (e.g. via the GitHub UI) stay invisible to the agent.
  # Mirror the explicit PR-run wiring (`SymphonyElixir.PrRun`) by pointing the
  # workspace branch/base ref at the PR head. An explicit base ref already on the
  # issue (PR runs) is left untouched. Fork/cross-repo CI reworks deliberately do
  # not pin to origin/<head_ref>, because that ref is not guaranteed to exist in
  # the local origin remote.
  defp sync_workspace_to_pr_head(%Issue{workspace_base_ref: ref} = issue, _opts)
       when is_binary(ref) and ref != "",
       do: issue

  defp sync_workspace_to_pr_head(%Issue{} = issue, opts) do
    case resolve_pr_head_ref(issue, opts) do
      head_ref when is_binary(head_ref) and head_ref != "" ->
        %Issue{issue | workspace_branch: head_ref, workspace_base_ref: "origin/#{head_ref}"}

      _ ->
        issue
    end
  end

  # A pending merge conflict wins (its snapshot pins the exact head); otherwise
  # reviewer-comment and same-repo CI reworks target the same PR head branch.
  defp resolve_pr_head_ref(issue, opts) do
    case resolve_pr_conflict(issue, opts) do
      %{head_ref: head_ref} when is_binary(head_ref) and head_ref != "" ->
        head_ref

      _ ->
        pending_reviewer_rework_head_ref(issue, opts) || pending_ci_rework_head_ref(issue, opts) ||
          renamed_issue_pr_head_ref(issue, opts)
    end
  end

  # Workspaces and branches default to `auto/<identifier>`, but the identifier
  # changes when the Linear team key is renamed (TON-218 -> TP-218). Without
  # this, the next dispatch builds a fresh `auto/TP-218` worktree and the scoped
  # GitHub tools, which resolve the PR from the workspace's current branch, no
  # longer see the PR opened on `auto/TON-218`. When the attached PR is still
  # open, same-repo, and its head differs from the default branch, keep working
  # on that head. Lookup failures fall back to the default branch.
  defp renamed_issue_pr_head_ref(%Issue{identifier: identifier, pr_urls: [pr_url | _rest]}, opts)
       when is_binary(identifier) and is_binary(pr_url) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_ci_status(pr_url, []) do
      {:ok, %{state: "OPEN", is_cross_repository: false, head_ref_name: head_ref}}
      when is_binary(head_ref) and head_ref != "" ->
        if head_ref != "auto/" <> identifier, do: head_ref

      _status ->
        nil
    end
  end

  defp renamed_issue_pr_head_ref(_issue, _opts), do: nil

  # Reuse an already-resolved conflict snapshot when the caller supplied one
  # (same precedence as put_pr_conflict/2), otherwise look it up in the store.
  defp resolve_pr_conflict(issue, opts) do
    if Keyword.has_key?(opts, :pr_conflict) do
      Keyword.get(opts, :pr_conflict)
    else
      pending_pr_conflict(issue, opts)
    end
  end

  defp pending_reviewer_rework_head_ref(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    PrReviewPoller.pending_pr_head_ref(issue_id, pending_lookup_opts(issue, opts))
  end

  defp pending_reviewer_rework_head_ref(_issue, _opts), do: nil

  defp pending_ci_rework_head_ref(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    case CiPoller.pending_ci_failure(issue_id, pending_lookup_opts(issue, opts)) do
      %{is_cross_repository: false, head_ref_name: head_ref} when is_binary(head_ref) and head_ref != "" ->
        head_ref

      _ci_failure ->
        nil
    end
  end

  defp pending_ci_rework_head_ref(_issue, _opts), do: nil

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, issue, message), do: send_codex_update(recipient, issue, message, :executor)

  defp send_codex_update(recipient, %Issue{id: issue_id}, message, phase)
       when is_binary(issue_id) and is_pid(recipient) do
    payload = SymphonyElixir.ClaudeCode.AppServer.event_to_update(message) || message
    payload = maybe_put_agent_phase(payload, phase)
    send(recipient, {:codex_worker_update, issue_id, payload})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message, _phase), do: :ok

  defp maybe_put_agent_phase(payload, phase) when is_map(payload), do: Map.put(payload, :agent_phase, phase)
  defp maybe_put_agent_phase(payload, _phase), do: payload

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  # The comments the run posted, so the orchestrator can tell them from people's comments on a
  # breakdown parent's plan (see `SymphonyElixir.PlanComments`).
  defp send_run_comment_ids(recipient, %Issue{id: issue_id}, registry)
       when is_binary(issue_id) and is_pid(recipient) and is_pid(registry) do
    send(recipient, {:worker_runtime_info, issue_id, %{comment_ids: CommentRegistry.comment_ids(registry)}})
    :ok
  end

  defp send_run_comment_ids(_recipient, _issue, _registry), do: :ok

  defp send_agent_session_info(recipient, %Issue{id: issue_id}, agent_module, session)
       when is_binary(issue_id) and is_pid(recipient) and is_atom(agent_module) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         agent_module: agent_module,
         agent_session: session
       }}
    )

    :ok
  end

  defp send_agent_session_info(_recipient, _issue, _agent_module, _session), do: :ok

  # Reuse the registry started before workpad bootstrap (it already owns the
  # bootstrap comment) and merge in ids recovered from Linear; fall back to a
  # fresh registry for callers that skip the bootstrap path.
  defp ensure_comment_registry(opts, seed_ids) do
    case Keyword.get(opts, :linear_comment_registry) do
      pid when is_pid(pid) ->
        Enum.each(seed_ids, &CommentRegistry.record(pid, &1))
        {:ok, pid}

      nil ->
        CommentRegistry.start_link(seed_ids: seed_ids)
    end
  end

  # A `Final verification:` ticket gets the Auto Review parent walkthrough in place of executor
  # turns when it applies (see `SymphonyElixir.AutoReview.ParentWalkthrough`).
  defp run_issue(workspace, issue, codex_update_recipient, opts, worker_host) do
    walkthrough_opts =
      opts
      |> Keyword.put(:worker_host, worker_host)
      |> Keyword.put(:on_message, codex_message_handler(codex_update_recipient, issue))

    case Keyword.get(opts, :parent_walkthrough, ParentWalkthrough).run(issue, workspace, walkthrough_opts) do
      :skip -> run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
      result -> result
    end
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    settings = Keyword.fetch!(opts, :settings)
    max_turns = Keyword.get(opts, :max_turns, settings.agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    seed_ids = AgentTools.Linear.recover_comment_registry_seeds(issue, settings.tracker.kind, Keyword.take(opts, [:linear_retry_opts]))
    opts = Keyword.put_new_lazy(opts, :run_profile, fn -> run_profile(issue, settings, opts) end)

    with {:ok, agent_module} <- agent_module(opts),
         {:ok, linear_comment_registry} <- ensure_comment_registry(opts, seed_ids),
         {:ok, session} <-
           start_agent_session(agent_module, workspace, worker_host, issue, Keyword.put(opts, :linear_comment_registry, linear_comment_registry)) do
      send_agent_session_info(codex_update_recipient, issue, agent_module, session)

      # Capture pending rework context (reviewer comments, CI failure, PR
      # conflict) up front so the review-agent skip decision after the turn
      # sees the same snapshot as the first-turn prompt, even if the pending
      # records get completed mid-run.
      run_opts =
        opts
        |> Keyword.put(:linear_comment_registry, linear_comment_registry)
        |> put_reviewer_comments(issue)
        |> put_ci_failure(issue)
        |> put_qa_failure(issue)
        |> put_pr_conflict(issue)

      run_context = %{
        workspace: workspace,
        issue: issue,
        codex_update_recipient: codex_update_recipient,
        opts: run_opts,
        issue_state_fetcher: issue_state_fetcher,
        worker_host: worker_host,
        review_agent: initial_review_agent_state(),
        next_prompt: nil,
        session_rebuilt: false,
        progress: initial_progress(workspace, worker_host, issue, run_opts),
        dispatch_pr_url: URLUtils.pull_request_url(issue)
      }

      try do
        do_run_codex_turns(agent_module, session, run_context, 1, max_turns)
      after
        agent_module.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(agent_module, app_session, run_context, turn_number, max_turns) do
    %{
      workspace: workspace,
      issue: issue,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher
    } = run_context

    prompt = run_context.next_prompt || build_turn_prompt(issue, opts, turn_number, max_turns, run_context.review_agent)
    run_context = %{run_context | next_prompt: nil}
    audit_prompt_sent(issue, Keyword.get(opts, :run_id), prompt, turn_number, max_turns, agent_module, opts)

    case run_agent_turn(agent_module, app_session, prompt, run_context) do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        case maybe_hold_for_dependency_approval(workspace, issue, turn_session, run_context) do
          :ok ->
            continue_after_completed_turn(
              issue,
              issue_state_fetcher,
              opts,
              run_context,
              agent_module,
              app_session,
              turn_number,
              max_turns
            )

          {:hold, _items} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} = error ->
        if retry_in_fresh_session?(reason, run_context, turn_number) do
          retry_turn_in_fresh_session(reason, agent_module, prompt, run_context, turn_number, max_turns)
        else
          error
        end
    end
  end

  defp start_agent_session(agent_module, workspace, worker_host, issue, opts) do
    settings = Keyword.fetch!(opts, :settings)

    agent_module.start_session(workspace,
      worker_host: worker_host,
      settings: settings,
      issue: issue,
      run_id: Keyword.get(opts, :run_id),
      run_profile: Keyword.fetch!(opts, :run_profile),
      repo_key: Keyword.get(opts, :repo_key),
      linear_comment_registry: Keyword.get(opts, :linear_comment_registry),
      dependency_audit_module: dependency_audit_module(opts),
      dependency_audit_base_ref: Keyword.get(opts, :dependency_audit_base_ref),
      dependency_audit_command_runner: Keyword.get(opts, :dependency_audit_command_runner),
      extra_env: AgentTmpDir.env(settings.agent.kind, Keyword.get(opts, :agent_tmp_dir))
    )
  end

  defp run_agent_turn(agent_module, app_session, prompt, run_context) do
    %{issue: issue, codex_update_recipient: codex_update_recipient, opts: opts} = run_context

    agent_module.run_turn(
      app_session,
      prompt,
      issue,
      on_message: codex_message_handler(codex_update_recipient, issue),
      settings: Keyword.fetch!(opts, :settings),
      repo_key: Keyword.get(opts, :repo_key),
      run_id: Keyword.get(opts, :run_id),
      linear_comment_registry: Keyword.get(opts, :linear_comment_registry),
      dependency_audit_module: dependency_audit_module(opts),
      dependency_audit_base_ref: Keyword.get(opts, :dependency_audit_base_ref),
      dependency_audit_command_runner: Keyword.get(opts, :dependency_audit_command_runner)
    )
  end

  # A continuation turn that starts without the Symphony MCP server gets one retry in a
  # fresh session (new MCP session, socket, settings and `--mcp-config` files). Turn 1
  # setup errors stay terminal: no earlier turn has shown the setup can work.
  defp retry_in_fresh_session?(reason, run_context, turn_number) do
    turn_number > 1 and not run_context.session_rebuilt and terminal_agent_setup_error?(reason)
  end

  # The broken session is left for `run_codex_turns/5` to stop, so each session is
  # stopped exactly once.
  defp retry_turn_in_fresh_session(reason, agent_module, prompt, run_context, turn_number, max_turns) do
    %{workspace: workspace, worker_host: worker_host, issue: issue, opts: opts} = run_context

    Logger.warning("Continuation turn started without the Symphony MCP server for #{issue_context(issue)}; retrying once in a fresh session turn=#{turn_number}/#{max_turns} reason=#{inspect(reason)}")

    case start_agent_session(agent_module, workspace, worker_host, issue, opts) do
      {:ok, fresh_session} ->
        send_agent_session_info(run_context.codex_update_recipient, issue, agent_module, fresh_session)
        retry_context = %{run_context | next_prompt: prompt, session_rebuilt: true}

        try do
          do_run_codex_turns(agent_module, fresh_session, retry_context, turn_number, max_turns)
        after
          agent_module.stop_session(fresh_session)
        end

      {:error, restart_reason} ->
        Logger.warning("Could not start a fresh session for #{issue_context(issue)} reason=#{inspect(restart_reason)}")
        {:error, reason}
    end
  end

  defp continue_after_completed_turn(issue, issue_state_fetcher, opts, run_context, agent_module, app_session, turn_number, max_turns) do
    case continue_with_issue?(issue, issue_state_fetcher, opts, run_context) do
      {:continue, refreshed_issue} ->
        run_context = track_turn_progress(run_context, refreshed_issue)

        case end_run_after_turn(refreshed_issue, run_context) do
          :continue when turn_number < max_turns ->
            run_context = %{run_context | issue: refreshed_issue}
            continue_active_issue(agent_module, app_session, run_context, refreshed_issue, turn_number, max_turns)

          :continue ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            :ok

          result ->
            result
        end

      {:done, refreshed_issue} ->
        forget_rework_base_outside_rework(refreshed_issue, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # How a run whose issue is still active ends after a turn, or `:continue` to take another turn.
  defp end_run_after_turn(%Issue{} = issue, run_context) do
    cond do
      merging_ci_pending?(issue, run_context) ->
        :ok

      rework_finished?(issue, run_context) ->
        hand_off_finished_rework(issue, run_context)

      ci_action = pushed_head_handoff_ci_action(issue, run_context) ->
        hand_off_pushed_head(issue, ci_action, run_context)

      idle_turn_limit_reached?(issue, run_context) ->
        forget_rework_base(issue, run_context.opts)
        park_idle_issue(issue, run_context.opts)

      true ->
        :continue
    end
  end

  # The workspace can be removed mid-turn (for example by PR-merge cleanup) and
  # the agent may already have moved the issue to a terminal state. Neither case
  # should turn into a hold that reopens the issue.
  defp maybe_hold_for_dependency_approval(workspace, issue, turn_session, run_context) do
    if DependencyGate.workspace_missing?(workspace, run_context.worker_host) do
      Logger.info("Skipping dependency audit for #{issue_context(issue)}; workspace is gone workspace=#{workspace}")
      :ok
    else
      audit_dependencies(workspace, issue, turn_session, run_context)
    end
  end

  defp audit_dependencies(workspace, issue, turn_session, %{opts: opts, issue_state_fetcher: issue_state_fetcher}) do
    audit_module = dependency_audit_module(opts)

    audit_opts =
      opts
      |> Keyword.take([:repo_key, :settings])
      |> maybe_put_option(:base_ref, Keyword.get(opts, :dependency_audit_base_ref))
      |> maybe_put_option(:command_runner, Keyword.get(opts, :dependency_audit_command_runner))

    case audit_module.audit(workspace, audit_opts) do
      {:ok, []} ->
        :ok

      result ->
        if DependencyGate.issue_terminal?(issue, issue_state_fetcher) do
          Logger.info("Skipping dependency hold for #{issue_context(issue)}; issue is already terminal")
          :ok
        else
          react_to_dependency_audit(result, issue, turn_session, opts)
        end
    end
  end

  defp react_to_dependency_audit({:hold, items}, issue, turn_session, opts),
    do: hold_dependency_approval(issue, items, turn_session, opts)

  defp react_to_dependency_audit({:error, reason}, _issue, _turn_session, _opts),
    do: {:error, {:dependency_audit_failed, reason}}

  defp dependency_audit_module(opts) do
    Keyword.get(opts, :dependency_audit_module) || DependencyAudit
  end

  defp hold_dependency_approval(%Issue{id: issue_id} = issue, items, turn_session, opts)
       when is_binary(issue_id) do
    move = fn -> Tracker.update_issue_state(issue_id, @dependency_review_state) end

    case with_linear_retry(move, "moving #{issue_context(issue)} to #{@dependency_review_state} for dependency approval", opts) do
      :ok ->
        Notifications.emit_issue_event(
          :dependency_pending_approval,
          issue,
          dependency_approval_attrs(items, turn_session, opts)
        )

        Logger.warning("Dependency approval required for #{issue_context(issue)} items=#{length(items)}")
        {:hold, items}

      {:error, reason} ->
        {:error, {:dependency_approval_state_update_failed, reason}}
    end
  end

  defp hold_dependency_approval(issue, items, turn_session, opts) do
    Notifications.emit_issue_event(
      :dependency_pending_approval,
      issue,
      dependency_approval_attrs(items, turn_session, opts)
    )

    {:hold, items}
  end

  defp dependency_approval_attrs(items, turn_session, opts) do
    %{
      repo_key: Keyword.get(opts, :repo_key),
      run_id: Keyword.get(opts, :run_id),
      session_id: turn_session[:session_id],
      state: @dependency_review_state,
      reason: "dependency_source_requires_approval",
      metadata: DependencyAudit.approval_metadata(items)
    }
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp continue_active_issue(agent_module, app_session, run_context, refreshed_issue, turn_number, max_turns) do
    case maybe_review_agent_next_turn(run_context, turn_number, max_turns) do
      {:review_agent_turn, next_context} ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} with reviewer-agent guidance turn=#{turn_number}/#{max_turns}")

        do_run_codex_turns(agent_module, app_session, next_context, turn_number + 1, max_turns)

      {:error, reason} ->
        {:error, reason}

      :normal_continuation ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_codex_turns(
          agent_module,
          app_session,
          run_context,
          turn_number + 1,
          max_turns
        )
    end
  end

  defp initial_review_agent_state, do: %{phase: :not_run, request_change_rounds: 0, inconclusive_retries: 0}

  defp maybe_review_agent_next_turn(run_context, _turn_number, _max_turns) do
    config = run_context.opts |> Keyword.fetch!(:settings) |> Map.fetch!(:review_agent)

    cond do
      not ReviewAgent.enabled?(config) ->
        :normal_continuation

      ReviewAgent.skip_for_run?(config, run_context.opts) ->
        :normal_continuation

      true ->
        review_agent_next_turn(run_context, config)
    end
  end

  defp review_agent_next_turn(%{review_agent: %{phase: :complete}}, _config), do: :normal_continuation

  defp review_agent_next_turn(%{review_agent: %{phase: phase}} = run_context, config)
       when phase in [:not_run, :awaiting_correction] do
    round = review_agent_request_change_rounds(run_context) + 1

    case evaluate_review_agent(run_context) do
      {:ok, result} ->
        emit_review_agent_verdict(run_context, result, round, config.max_iterations)

        case handle_review_agent_result(result, run_context, config) do
          {:error, {:review_agent_inconclusive, reason}} ->
            handle_review_agent_inconclusive(run_context, config, round, reason)

          other ->
            other
        end

      {:error, {:review_agent_blocked, payload} = reason} ->
        emit_review_agent_blocked(run_context, payload, round, config.max_iterations)
        {:error, reason}

      {:error, {:review_agent_inconclusive, reason}} ->
        handle_review_agent_inconclusive(run_context, config, round, reason)

      {:error, reason} ->
        {:error, {:review_agent_failed, reason}}
    end
  end

  defp review_agent_next_turn(_run_context, _config), do: :normal_continuation

  defp handle_review_agent_result(%{verdict: :approve} = result, run_context, _config) do
    {:review_agent_turn,
     %{
       run_context
       | review_agent: %{
           phase: :complete,
           request_change_rounds: review_agent_request_change_rounds(run_context),
           inconclusive_retries: review_agent_inconclusive_retries(run_context)
         },
         next_prompt: ReviewAgent.approval_prompt(result, run_context.opts)
     }}
  end

  defp handle_review_agent_result(%{verdict: :request_changes} = result, run_context, config) do
    if review_agent_correction_round_available?(run_context, config) do
      {:review_agent_turn,
       %{
         run_context
         | review_agent: %{
             phase: :awaiting_correction,
             request_change_rounds: next_review_agent_request_change_round(run_context),
             inconclusive_retries: review_agent_inconclusive_retries(run_context),
             comments: result.comments
           },
           next_prompt: ReviewAgent.request_changes_prompt(result)
       }}
    else
      rounds = review_agent_request_change_rounds(run_context)

      Logger.warning("Reviewer agent hit the request-change limit for #{issue_context(run_context.issue)} rounds=#{rounds} last_comments=#{inspect(result.comments)}")

      {:error, {:review_agent_inconclusive, {:review_agent_max_iterations_reached, result.comments}}}
    end
  end

  # Findings nobody could ground do not earn a correction round: the push goes ahead
  # and they ride along on the approval prompt as advisory notes.
  defp handle_review_agent_inconclusive(run_context, config, round, {:review_agent_unverifiable, payload}) do
    notes = ReviewAgent.unverified_notes(payload)
    dropped = payload |> Map.get(:failures, []) |> length()

    Logger.warning("Reviewer agent findings stayed unverifiable for #{issue_context(run_context.issue)} round=#{round} dropped=#{dropped}; approving with advisory notes")

    audit_review_agent_unverified(run_context, round, dropped)

    result = %{
      verdict: :approve,
      comments: notes,
      reason: "reviewer findings unverifiable; approved with #{dropped} advisory note(s)",
      advisory_notes: notes
    }

    emit_review_agent_verdict(run_context, result, round, config.max_iterations)
    handle_review_agent_result(result, run_context, config)
  end

  defp handle_review_agent_inconclusive(run_context, config, round, reason) do
    if review_agent_inconclusive_retry_available?(run_context) do
      Logger.info("Reviewer agent was inconclusive for #{issue_context(run_context.issue)} reason=#{inspect(reason)}; retrying reviewer once with a fresh session")

      run_context =
        put_inconclusive_retries(run_context, review_agent_inconclusive_retries(run_context) + 1)

      review_agent_next_turn(run_context, config)
    else
      # A second inconclusive pass on the same commit gives the executor nothing to act on, so
      # the push goes ahead: CI, QA and the supervisor still gate the PR.
      Logger.warning("Reviewer agent remained inconclusive for #{issue_context(run_context.issue)} reason=#{inspect(reason)}; letting the push go ahead without reviewer approval")

      reason_text = review_agent_non_convergence_reason(reason)
      notes = review_agent_inconclusive_notes(reason)

      audit_review_agent_inconclusive(run_context, round, reason_text)

      result = %{
        verdict: :approve,
        comments: notes,
        reason: "#{reason_text}; push allowed without reviewer approval",
        inconclusive: reason_text,
        advisory_notes: notes
      }

      emit_review_agent_verdict(run_context, result, round, config.max_iterations)
      handle_review_agent_result(result, run_context, config)
    end
  end

  defp review_agent_inconclusive_notes({:review_agent_max_iterations_reached, comments}), do: comments
  defp review_agent_inconclusive_notes(_reason), do: []

  defp review_agent_non_convergence_reason(reason) do
    case review_agent_inconclusive_summary(reason) do
      nil -> "reviewer did not converge"
      summary -> "reviewer did not converge: #{summary}"
    end
  end

  defp review_agent_inconclusive_summary({:review_agent_max_iterations_reached, _comments}), do: "request-change limit reached"
  defp review_agent_inconclusive_summary({:max_iterations, _reason}), do: "review turn reached max iterations"
  defp review_agent_inconclusive_summary({:self_check_max_iterations, _reason}), do: "self-check reached max iterations"

  defp review_agent_inconclusive_summary({:malformed_review_agent_response, reason}) do
    "malformed response #{limited_inspect(reason)}"
  end

  defp review_agent_inconclusive_summary(reason) when is_atom(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ")
  end

  defp review_agent_inconclusive_summary(_reason), do: nil

  defp limited_inspect(term) do
    term
    |> inspect(limit: 3, printable_limit: 160)
    |> truncate_text(220)
  end

  defp truncate_text(text, max_length) when byte_size(text) > max_length do
    String.slice(text, 0, max_length) <> "..."
  end

  defp truncate_text(text, _max_length), do: text

  defp emit_review_agent_verdict(
         %{
           issue: issue,
           codex_update_recipient: codex_update_recipient
         },
         result,
         round,
         max_iterations
       ) do
    event = %{
      event: :review_agent_verdict,
      timestamp: DateTime.utc_now(),
      payload: %{
        type: "review_agent_verdict",
        verdict: result.verdict,
        round: round,
        max_iterations: max_iterations,
        reason: review_agent_verdict_reason(result),
        comments: Map.get(result, :comments, []),
        tokens: %{
          input_tokens: 0,
          uncached_input_tokens: 0,
          cached_input_tokens: 0,
          cache_creation_input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0
        }
      }
    }

    send_codex_update(codex_update_recipient, issue, event, :reviewer)
  end

  defp emit_review_agent_blocked(run_context, payload, round, max_iterations) do
    result = %{
      verdict: :block,
      reason: review_agent_block_payload_reason(payload),
      comments: review_agent_block_payload_comments(payload)
    }

    emit_review_agent_verdict(run_context, result, round, max_iterations)
  end

  defp review_agent_block_payload_reason(%{reason: reason}) when is_binary(reason), do: reason
  defp review_agent_block_payload_reason(reason) when is_binary(reason), do: reason
  defp review_agent_block_payload_reason(reason), do: inspect(reason)

  defp review_agent_block_payload_comments(%{comments: comments}) when is_list(comments), do: comments
  defp review_agent_block_payload_comments(_payload), do: []

  defp review_agent_verdict_reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp review_agent_verdict_reason(%{comments: [comment | _]}) when is_binary(comment), do: comment
  defp review_agent_verdict_reason(_result), do: nil

  defp review_agent_correction_round_available?(run_context, config) do
    review_agent_request_change_rounds(run_context) < config.max_iterations
  end

  defp next_review_agent_request_change_round(run_context), do: review_agent_request_change_rounds(run_context) + 1

  defp review_agent_request_change_rounds(%{review_agent: %{request_change_rounds: rounds}}) when is_integer(rounds), do: rounds

  defp review_agent_inconclusive_retries(%{review_agent: %{inconclusive_retries: retries}}) when is_integer(retries), do: retries
  defp review_agent_inconclusive_retries(_run_context), do: 0

  defp review_agent_inconclusive_retry_available?(run_context), do: review_agent_inconclusive_retries(run_context) < 1

  defp put_inconclusive_retries(run_context, retries) when is_integer(retries) do
    review_agent =
      run_context.review_agent
      |> Map.put(:inconclusive_retries, retries)

    %{run_context | review_agent: review_agent}
  end

  defp evaluate_review_agent(%{
         issue: issue,
         workspace: workspace,
         opts: opts,
         worker_host: worker_host,
         codex_update_recipient: codex_update_recipient
       }) do
    review_opts =
      opts
      |> Keyword.take([:repo_key, :run_id, :reviewer_run_profile, :linear_comment_registry, :review_agent_module, :agent_tmp_dir])
      |> Keyword.put(:worker_host, worker_host)
      |> maybe_put_option(:base_branch, review_base_branch(opts))
      |> Keyword.put(:on_reviewer_message, reviewer_message_handler(codex_update_recipient, issue))
      |> put_reviewer_comments(issue)
      |> put_ci_failure(issue)

    ReviewAgent.evaluate(issue, workspace, Keyword.fetch!(opts, :settings), review_opts)
  end

  defp reviewer_message_handler(recipient, issue) do
    fn message -> send_codex_update(recipient, issue, message, :reviewer) end
  end

  defp review_base_branch(opts) do
    repo_key = Keyword.get(opts, :repo_key)

    case Config.repo_base_branch(repo_key) do
      {:ok, base_branch} ->
        base_branch

      {:error, reason} ->
        Logger.warning("ReviewAgent base_branch lookup failed repo_key=#{inspect(repo_key)} reason=#{inspect(reason)}")
        nil
    end
  end

  defp agent_module(opts) do
    case Keyword.get(opts, :agent_module) do
      nil -> agent_module_for_kind()
      module -> {:ok, module}
    end
  end

  defp agent_module_for_kind do
    case Config.settings!().agent.kind do
      "codex" -> {:ok, SymphonyElixir.Codex.AppServer}
      "claude" -> {:ok, SymphonyElixir.ClaudeCode.AppServer}
      kind -> {:error, {:unknown_agent_kind, kind}}
    end
  end

  # Exposed as a public seam so the agent-kind gating around compact-prompt fallback can be
  # regression-tested without spinning up a full agent runtime. Internal callers go through
  # `build_turn_prompt/4`.
  @doc false
  @spec build_first_turn_prompt(map(), keyword()) :: String.t()
  def build_first_turn_prompt(issue, opts) do
    build_turn_prompt(issue, opts, 1, Keyword.get(opts, :max_turns, 1), initial_review_agent_state())
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, _review_agent_state) do
    prompt_opts =
      opts
      |> put_reviewer_comments(issue)
      |> put_ci_failure(issue)
      |> put_qa_failure(issue)
      |> put_pr_conflict(issue)

    prompt = PromptBuilder.build_prompt(issue, prompt_opts)
    maybe_compact_codex_initial_prompt(prompt, issue, prompt_opts)
  end

  defp build_turn_prompt(_issue, opts, turn_number, max_turns, review_agent_state) do
    agent_name =
      opts
      |> Keyword.get(:settings)
      |> agent_kind_from_settings()
      |> AgentLabels.display_name()

    """
    Continuation guidance:

    - The previous #{agent_name} turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    #{review_agent_continuation_guard(opts, review_agent_state)}
    """
  end

  defp review_agent_continuation_guard(opts, review_agent_state) do
    case Keyword.get(opts, :settings) do
      %{review_agent: %{enabled: true} = config} ->
        cond do
          ReviewAgent.skip_for_run?(config, opts) ->
            ""

          review_agent_state.phase == :complete ->
            """

            Review-agent gate status:

            - Reviewer-agent approval has already been injected for this run.
            - Do not stop at the reviewer-agent gate again; complete the normal push/PR handoff unless code changes after approval or a true auth/permission blocker prevents handoff.
            #{ReviewAgent.approval_handoff_tool_guidance(Keyword.get(opts, :settings))}
            """

          true ->
            """

            Review-agent gate reminder:

            - If this thread has not already received a reviewer-agent approval prompt, stop before `git push`, PR creation, or moving the issue to review after validation and committed-diff review.
            - Ending the turn at that gate is expected even if the issue remains active; Symphony will run the reviewer agent and inject the next prompt.
            """
        end

      _settings ->
        ""
    end
  end

  defp agent_kind_from_settings(%{agent: %{kind: kind}}), do: kind
  defp agent_kind_from_settings(_settings), do: nil

  defp maybe_compact_codex_initial_prompt(prompt, issue, opts) when is_binary(prompt) do
    limit = codex_stdio_prompt_soft_limit(opts)

    if codex_agent?(opts) and byte_size(prompt) > limit do
      Logger.warning("Codex initial prompt exceeded stdio soft limit; using compact bootstrap prompt issue_identifier=#{issue_identifier(issue)} bytes=#{byte_size(prompt)} limit=#{limit}")

      PromptBuilder.build_compact_prompt(issue, opts)
    else
      prompt
    end
  end

  defp codex_stdio_prompt_soft_limit(opts) do
    case Keyword.get(opts, :settings) do
      %{agent: %{codex_stdio_prompt_soft_limit: limit}} when is_integer(limit) and limit > 0 -> limit
      _settings -> @codex_stdio_prompt_soft_limit_fallback
    end
  end

  defp codex_agent?(opts) do
    opts
    |> Keyword.get(:settings)
    |> agent_kind_from_settings()
    |> case do
      "codex" -> true
      :codex -> true
      _kind -> false
    end
  end

  defp issue_identifier(%Issue{identifier: identifier}), do: identifier || "unknown"

  defp audit_prompt_sent(issue, run_id, prompt, turn_number, max_turns, agent_module, opts) do
    issue
    |> AuditLog.record_prompt_sent(
      run_id,
      prompt,
      audit_opts(opts,
        turn_number: turn_number,
        max_turns: max_turns,
        agent: inspect(agent_module)
      )
    )
    |> log_audit_error("record prompt_sent")
  end

  defp audit_review_agent_unverified(%{issue: issue, opts: opts}, round, dropped) do
    %{
      event_type: "review_agent_unverified",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      run_id: Keyword.get(opts, :run_id),
      round: round,
      findings_dropped: dropped
    }
    |> AuditLog.record(audit_opts(opts))
    |> log_audit_error("record review_agent_unverified")
  end

  defp audit_review_agent_inconclusive(%{issue: issue, opts: opts}, round, reason) do
    %{
      event_type: "review_agent_inconclusive",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      run_id: Keyword.get(opts, :run_id),
      round: round,
      reason: reason
    }
    |> AuditLog.record(audit_opts(opts))
    |> log_audit_error("record review_agent_inconclusive")
  end

  defp audit_opts(opts, extra \\ []) do
    opts
    |> Keyword.take([:repo_key])
    |> Keyword.merge(extra)
  end

  defp put_reviewer_comments(opts, issue) when is_list(opts) do
    if Keyword.has_key?(opts, :reviewer_comments) do
      opts
    else
      Keyword.put(opts, :reviewer_comments, pending_reviewer_comments(issue, opts))
    end
  end

  defp pending_reviewer_comments(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    PrReviewPoller.pending_reviewer_comments(issue_id, pending_lookup_opts(issue, opts))
  end

  defp pending_reviewer_comments(_issue, _opts), do: []

  defp put_ci_failure(opts, issue) when is_list(opts) do
    if Keyword.has_key?(opts, :ci_failure) do
      opts
    else
      Keyword.put(opts, :ci_failure, pending_ci_failure(issue, opts))
    end
  end

  defp pending_ci_failure(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    CiPoller.pending_ci_failure(issue_id, pending_lookup_opts(issue, opts))
  end

  defp pending_ci_failure(_issue, _opts), do: nil

  defp put_qa_failure(opts, issue) when is_list(opts) do
    if Keyword.has_key?(opts, :qa_failure) do
      opts
    else
      Keyword.put(opts, :qa_failure, pending_qa_failure(issue, opts))
    end
  end

  defp pending_qa_failure(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    CiPoller.pending_qa_failure(issue_id, pending_lookup_opts(issue, opts))
  end

  defp pending_qa_failure(_issue, _opts), do: nil

  defp put_pr_conflict(opts, issue) when is_list(opts) do
    if Keyword.has_key?(opts, :pr_conflict) do
      opts
    else
      Keyword.put(opts, :pr_conflict, pending_pr_conflict(issue, opts))
    end
  end

  defp pending_pr_conflict(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    PrReviewPoller.pending_pr_conflict(issue_id, pending_lookup_opts(issue, opts))
  end

  defp pending_pr_conflict(_issue, _opts), do: nil

  defp pending_lookup_opts(%Issue{} = issue, opts) do
    case Keyword.get(opts, :repo_key) || issue_repo_key(issue) do
      repo_key when is_binary(repo_key) and repo_key != "" -> [repo_key: repo_key]
      _repo_key -> []
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, opts, run_context) when is_binary(issue_id) do
    case refresh_issue_state(issue, issue_state_fetcher, opts) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        audit_linear_state_transition(issue, refreshed_issue, Keyword.get(opts, :run_id), opts)
        warn_if_pr_url_lost(refreshed_issue, run_context)

        cond do
          post_pr_quiet_continuation?(issue, refreshed_issue, run_context) ->
            Logger.info("Stopping agent run for #{issue_context(refreshed_issue)} after PR opened; waiting for review, CI, or manual rework signal")
            {:done, refreshed_issue}

          waiting_on_sub_issues?(refreshed_issue) ->
            Logger.info("Stopping agent run for #{issue_context(refreshed_issue)}; waiting for its open sub-issues")
            {:done, refreshed_issue}

          Issue.blocked?(refreshed_issue, Config.settings!().tracker.terminal_states) ->
            Logger.info("Stopping agent run for #{issue_context(refreshed_issue)}; back in Todo and waiting for its blockers")
            {:done, refreshed_issue}

          active_issue_state?(refreshed_issue.state) ->
            {:continue, refreshed_issue}

          true ->
            {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _opts, _run_context), do: {:done, issue}

  # The checks that hand a run on its PR to CI or review, instead of parking it, read the PR URL
  # from the refreshed issue's attachments. Say so when one the issue had at dispatch is gone.
  defp warn_if_pr_url_lost(%Issue{} = refreshed_issue, %{dispatch_pr_url: pr_url}) when is_binary(pr_url) do
    if is_nil(URLUtils.pull_request_url(refreshed_issue)) do
      Logger.warning("#{issue_context(refreshed_issue)} had PR #{pr_url} at dispatch, but its refreshed Linear attachments show no PR; checks on its PR will not run")
    end
  end

  defp warn_if_pr_url_lost(_refreshed_issue, _run_context), do: :ok

  # The turn is done; a rate limit or a dropped connection on this refresh says
  # nothing about the run. Wait for Linear in this run and session instead of
  # failing the run and starting a new session.
  defp refresh_issue_state(%Issue{id: issue_id} = issue, issue_state_fetcher, opts) do
    retry_opts = Keyword.get(opts, :linear_retry_opts, [])
    notify_wait = Keyword.get(retry_opts, :on_wait, fn _reason, _delay_ms -> :ok end)

    on_wait = fn reason, delay_ms ->
      Logger.warning("Linear refresh after turn failed for #{issue_context(issue)}; retrying in #{delay_ms}ms in the same session reason=#{inspect(reason)}")
      notify_wait.(reason, delay_ms)
    end

    TransientRetry.run(fn -> issue_state_fetcher.([issue_id]) end, Keyword.put(retry_opts, :on_wait, on_wait))
  end

  # Waits out a rate limit or a dropped connection on a Linear call the run makes, the
  # same way the post-turn refresh does, instead of failing the run.
  defp with_linear_retry(fun, label, opts) do
    TransientRetry.run(fun, opts |> Keyword.get(:linear_retry_opts, []) |> Keyword.put(:label, label))
  end

  defp waiting_on_sub_issues?(%Issue{} = issue) do
    settings = Config.settings!()
    terminal_states = settings.tracker.terminal_states

    Issue.waiting_on_sub_issues?(issue, terminal_states) or SubIssueWait.held?(issue, terminal_states, settings)
  end

  defp post_pr_quiet_continuation?(%Issue{} = previous_issue, %Issue{} = refreshed_issue, run_context) do
    case URLUtils.pull_request_url(refreshed_issue) || URLUtils.pull_request_url(previous_issue) do
      pr_url when is_binary(pr_url) ->
        active_issue_state?(refreshed_issue.state) and
          !rework_state?(refreshed_issue.state) and
          !merging_state?(refreshed_issue.state) and
          no_pending_rework_signal?(refreshed_issue, run_context.opts) and
          work_on_pr?(refreshed_issue, pr_url, run_context)

      nil ->
        false
    end
  end

  # The run's work is on its PR once the workspace HEAD is the PR head and that head has passed the
  # pre-push reviewer, when the reviewer applies to the run. A commit the run has not pushed, or
  # pushed without a review, keeps the run going: the next turn runs the reviewer and the agent
  # pushes. An unreadable HEAD or PR head stops the run as before; the orchestrator checks the
  # workspace for unpushed commits before it moves the issue on.
  defp work_on_pr?(%Issue{} = issue, pr_url, run_context) do
    head = read_workspace_head(run_context.workspace, run_context.worker_host, run_context.opts)
    github = Keyword.get(run_context.opts, :github, PullRequest)

    with true <- is_binary(head),
         {:ok, %{commit_sha: pr_head}} when is_binary(pr_head) <-
           github.fetch_ci_status(pr_url, cwd: run_context.workspace) do
      cond do
        pr_head != head ->
          Logger.info("Not stopping agent run for #{issue_context(issue)} after PR opened; workspace HEAD #{head} is not its PR head #{pr_head}, continuing so it is reviewed and pushed")
          false

        not head_reviewed?(head, run_context) ->
          Logger.info("Not stopping agent run for #{issue_context(issue)} after PR opened; its PR head #{head} has not passed the pre-push reviewer, continuing")
          false

        true ->
          true
      end
    else
      _unknown -> true
    end
  end

  defp head_reviewed?(head, %{progress: progress, review_agent: review_agent, opts: opts}) do
    config = opts |> Keyword.fetch!(:settings) |> Map.fetch!(:review_agent)

    head == progress.start_head or review_agent.phase == :complete or
      not ReviewAgent.enabled?(config) or ReviewAgent.skip_for_run?(config, opts)
  end

  defp no_pending_rework_signal?(%Issue{} = issue, opts) do
    pending_reviewer_comments(issue, opts) == [] and
      is_nil(pending_ci_failure(issue, opts)) and
      is_nil(pending_qa_failure(issue, opts)) and
      is_nil(pending_pr_conflict(issue, opts))
  end

  # A turn makes progress when it adds a commit, changes the issue state, attaches a PR or
  # follows a reviewer-agent verdict (the push after an approval adds no commit). Without a
  # readable workspace HEAD (an SSH worker, no git checkout) progress is unknown and no turn
  # counts as empty.
  defp initial_progress(workspace, worker_host, issue, opts) do
    head = read_workspace_head(workspace, worker_host, opts)
    fingerprint = progress_fingerprint(head, issue, initial_review_agent_state())
    rework_base = rework_base(issue, head, opts)
    %{rework_base: rework_base, start_head: head, head: head, fingerprint: fingerprint, empty_turns: 0}
  end

  # The head a Rework started from: recorded by the first run dispatched in Rework and reused by
  # re-dispatched runs, so rework an earlier run pushed still counts. A run outside Rework forgets
  # it. When the store is unavailable only this run's own commits count.
  defp rework_base(%Issue{id: issue_id} = issue, head, opts) when is_binary(issue_id) and is_binary(head) do
    repo_key = run_repo_key(issue, opts)

    if rework_state?(issue.state) and attached_pr?(issue) do
      case RunStore.get_rework_base(repo_key, issue_id) do
        base when is_binary(base) ->
          base

        nil ->
          _ = RunStore.put_rework_base(repo_key, issue_id, head)
          head

        {:error, reason} ->
          Logger.warning("Could not read the rework base for #{issue_context(issue)}; counting this run's commits only reason=#{inspect(reason)}")
          head
      end
    else
      forget_rework_base(issue, opts)
      head
    end
  end

  defp rework_base(_issue, head, _opts), do: head

  defp forget_rework_base(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    _ = RunStore.delete_rework_base(run_repo_key(issue, opts), issue_id)
    :ok
  end

  defp forget_rework_base(_issue, _opts), do: :ok

  defp forget_rework_base_outside_rework(issue, opts) do
    if rework_state?(Map.get(issue, :state)), do: :ok, else: forget_rework_base(issue, opts)
  end

  defp track_turn_progress(%{progress: progress} = run_context, %Issue{} = refreshed_issue) do
    head = read_workspace_head(run_context.workspace, run_context.worker_host, run_context.opts)
    fingerprint = progress_fingerprint(head, refreshed_issue, run_context.review_agent)
    empty_turns = if is_nil(head) or fingerprint != progress.fingerprint, do: 0, else: progress.empty_turns + 1

    %{run_context | progress: %{progress | head: head, fingerprint: fingerprint, empty_turns: empty_turns}}
  end

  defp read_workspace_head(workspace, worker_host, opts) do
    reader = Keyword.get(opts, :workspace_head_reader, &WorkspaceHead.read/2)
    reader.(workspace, worker_host)
  end

  defp progress_fingerprint(head, issue, review_agent),
    do: {head, Map.get(issue, :state), URLUtils.pull_request_url(issue), review_agent}

  # Nothing moves an issue out of `Rework` once its rework is done: the agent may not ask for
  # `In Review` with Auto Review on, and the post-PR move skips `Rework`. The rework is done once
  # the workspace HEAD has moved past the head the Rework started from (by this run or an earlier
  # one), that HEAD is the attached PR's head, and no review, CI, QA or conflict signal is pending.
  defp rework_finished?(%Issue{} = issue, %{progress: %{head: head} = progress} = run_context) when is_binary(head) do
    rework_state?(issue.state) and attached_pr?(issue) and
      head != progress.rework_base and
      no_pending_rework_signal?(issue, run_context.opts) and
      pr_head?(issue, head, run_context)
  end

  defp rework_finished?(_issue, _run_context), do: false

  defp pr_head?(%Issue{} = issue, head, run_context) do
    github = Keyword.get(run_context.opts, :github, PullRequest)

    case github.fetch_ci_status(URLUtils.pull_request_url(issue), cwd: run_context.workspace) do
      {:ok, %{commit_sha: ^head}} ->
        true

      {:ok, _ci_status} ->
        false

      {:error, reason} ->
        Logger.warning("Could not read the PR head for rework #{issue_context(issue)}; continuing reason=#{inspect(reason)}")
        false
    end
  end

  defp hand_off_finished_rework(%Issue{} = issue, run_context) do
    post_pr_state = post_pr_state(run_context)
    Logger.info("Rework for #{issue_context(issue)} is pushed to its PR with no rework signal pending; moving to #{post_pr_state}")

    case move_to_post_pr_state(issue, post_pr_state, "after rework", run_context) do
      :ok ->
        forget_rework_base(issue, run_context.opts)
        :ok

      {:error, reason} ->
        {:error, {:rework_handoff_failed, reason}}
    end
  end

  # A run on an issue whose PR is already open (a conflict, CI, QA or review fix) never takes the
  # post-PR stop: the signal that started it stays pending until the run ends. Once it has pushed
  # a new head to that PR and CI on that head is running or green, the CI poller takes it from
  # there: in the post-PR state it starts QA on green, and re-runs a flaky failure or dispatches a
  # fix run on red. So the run moves to that state instead of turning while CI runs until the idle
  # check parks it. A head the pre-push reviewer applies to but has not passed keeps the run going,
  # as the post-PR stop does (`head_reviewed?/2`), so the next turn reviews it. Gives the CI action
  # (`:pending` or `:success`), or nil for a head with no checks yet, a red head, another PR head or
  # an unreviewed head. `Rework` and `Merging` keep their own rules (`rework_finished?/2`,
  # `merging_ci_pending?/2`).
  defp pushed_head_handoff_ci_action(%Issue{} = issue, %{progress: %{head: head, start_head: start_head}} = run_context)
       when is_binary(head) and is_binary(start_head) do
    if head != start_head and !rework_state?(issue.state) and !merging_state?(issue.state) and
         head_reviewed?(head, run_context) do
      case pushed_head_ci_action(issue, run_context) do
        action when action in [:pending, :success] -> action
        _action -> nil
      end
    end
  end

  defp pushed_head_handoff_ci_action(_issue, _run_context), do: nil

  defp hand_off_pushed_head(%Issue{} = issue, ci_action, %{progress: %{head: head}} = run_context) do
    post_pr_state = post_pr_state(run_context)
    ci = if ci_action == :success, do: "green", else: "running"
    Logger.info("CI is #{ci} on #{issue_context(issue)}'s pushed head #{head} on its PR; moving to #{post_pr_state}")

    case move_to_post_pr_state(issue, post_pr_state, "with CI #{ci} on its pushed head", run_context) do
      :ok -> :ok
      {:error, reason} -> {:error, {:pushed_head_handoff_failed, reason}}
    end
  end

  defp post_pr_state(run_context), do: run_context.opts |> Keyword.fetch!(:settings) |> AutoReview.post_pr_state()

  defp move_to_post_pr_state(%Issue{id: issue_id} = issue, post_pr_state, reason, run_context) do
    move = fn -> Tracker.update_issue_state(issue_id, post_pr_state) end
    with_linear_retry(move, "moving #{issue_context(issue)} to #{post_pr_state} #{reason}", run_context.opts)
  end

  # A landing run waits on CI through `merging_ci_pending?/2`, and parking it would drop the
  # human's merge approval. A run whose HEAD is the PR head with checks pending, but that is not
  # handed off (a Rework run, or one that started on that head), is not idle either; it keeps
  # turning, up to `agent.max_turns`, until CI settles.
  defp idle_turn_limit_reached?(%Issue{} = issue, %{progress: progress} = run_context) do
    progress.empty_turns >= @max_empty_turns and !merging_state?(issue.state) and
      !pushed_head_ci_pending?(issue, run_context)
  end

  defp pushed_head_ci_pending?(%Issue{} = issue, %{progress: %{head: head}} = run_context) do
    if pushed_head_ci_action(issue, run_context) == :pending do
      Logger.info("Not parking #{issue_context(issue)}; waiting for CI on its pushed head #{head}")
      true
    else
      false
    end
  end

  # The CI action for the workspace HEAD when it is the attached PR's head, or nil. A PR with no
  # checks reported yet gives nil, so a repo without CI never waits on it and stays parkable.
  defp pushed_head_ci_action(%Issue{} = issue, %{progress: %{head: head}} = run_context) do
    pr_url = URLUtils.pull_request_url(issue)
    github = Keyword.get(run_context.opts, :github, PullRequest)

    with true <- is_binary(pr_url),
         {:ok, %{commit_sha: ^head, checks: [_ | _]} = ci_status} <-
           github.fetch_ci_status(pr_url, cwd: run_context.workspace) do
      CiPoller.ci_action(ci_status)
    else
      _ -> nil
    end
  end

  defp park_idle_issue(%Issue{id: issue_id} = issue, opts) do
    Logger.warning(
      "Parking #{issue_context(issue)} in #{@idle_park_state} after #{@max_empty_turns} turns with no new commit or state change" <>
        idle_park_pr_note(issue)
    )

    label = "parking #{issue_context(issue)} in #{@idle_park_state}"

    with :ok <- with_linear_retry(fn -> Tracker.update_issue_state(issue_id, @idle_park_state) end, label, opts),
         :ok <- with_linear_retry(fn -> Tracker.create_comment(issue_id, idle_park_note()) end, label, opts) do
      :ok
    else
      {:error, reason} -> {:error, {:idle_park_failed, reason}}
    end
  end

  # The CI checks that keep a run that pushed from being parked read the issue's PR URL. Saying
  # when there is none shows a lost PR link instead of parking without a trace.
  defp idle_park_pr_note(%Issue{} = issue) do
    if attached_pr?(issue), do: "", else: "; it has no attached PR, so CI on its head was not checked"
  end

  defp idle_park_note do
    """
    Symphony parked this issue in #{@idle_park_state}: the agent's last #{@max_empty_turns} turns made no new commit and no state change, so another turn would repeat them. Move it back to Todo once it can make progress.
    """
  end

  defp attached_pr?(%Issue{} = issue), do: is_binary(URLUtils.pull_request_url(issue))

  defp rework_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "rework"
  end

  defp rework_state?(_state_name), do: false

  # `Merging` means a human approved the merge. Parking it as post-PR quiet would move it
  # back to review and drop that approval while the landing agent waits for CI.
  defp merging_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "merging"
  end

  defp merging_state?(_state_name), do: false

  # A landing agent that ends its turn while the PR head's checks are pending would only spend
  # turns finding them still pending. End the run and tell the orchestrator, which holds the
  # issue in `Merging` until the CI poller sees that head settle.
  defp merging_ci_pending?(%Issue{} = issue, run_context) do
    pr_url = URLUtils.pull_request_url(issue)

    if merging_state?(issue.state) and is_binary(pr_url) do
      github = Keyword.get(run_context.opts, :github, PullRequest)

      case github.fetch_ci_status(pr_url, cwd: run_context.workspace) do
        {:ok, ci_status} ->
          maybe_wait_for_merging_ci(issue, pr_url, ci_status, run_context)

        {:error, reason} ->
          Logger.warning("Could not read CI status for landing #{issue_context(issue)}; continuing reason=#{inspect(reason)}")
          false
      end
    else
      false
    end
  end

  defp maybe_wait_for_merging_ci(issue, pr_url, ci_status, run_context) do
    if CiPoller.ci_action(ci_status) == :pending do
      commit_sha = Map.get(ci_status, :commit_sha)
      Logger.info("Stopping landing run for #{issue_context(issue)}; waiting for CI on #{commit_sha}")
      send_merging_ci_wait(run_context.codex_update_recipient, issue, %{commit_sha: commit_sha, pr_url: pr_url})
      true
    else
      false
    end
  end

  defp send_merging_ci_wait(recipient, %Issue{id: issue_id}, wait) when is_pid(recipient) do
    send(recipient, {:merging_ci_wait, issue_id, wait})
    :ok
  end

  defp send_merging_ci_wait(_recipient, _issue, _wait), do: :ok

  defp audit_linear_state_transition(issue, refreshed_issue, run_id, opts) do
    issue
    |> AuditLog.record_linear_state_transition(refreshed_issue, run_id, audit_opts(opts))
    |> log_audit_error("record linear_state_change")
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp run_repo_key(issue, opts) do
    Keyword.get(opts, :repo_key) || issue_repo_key(issue) || Config.repo_key!()
  end

  defp issue_repo_key(%Issue{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp issue_repo_key(%{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp issue_repo_key(%{"repo_key" => repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp issue_repo_key(_issue), do: nil

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp log_branch_collision(issue, worker_host, details) when is_list(details) do
    branch = Keyword.get(details, :branch)
    at = Keyword.get(details, :at)
    requested = Keyword.get(details, :requested)

    Logger.error("Refusing run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}: branch #{branch} already checked out at #{at} (requested #{requested})")
  end

  defp log_branch_collision(issue, worker_host, details) do
    Logger.error("Refusing run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}: branch collision details=#{inspect(details)}")
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp log_audit_error(:ok, _action), do: :ok

  defp log_audit_error({:error, reason}, action) do
    Logger.warning("Audit log failed to #{action}: #{inspect(reason)}")
    :ok
  end
end
