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
    CiFix,
    CiPoller,
    ClosedPullRequest,
    CodeReview,
    Config,
    Connected,
    DecisionRequest,
    Decisions,
    DependencyAudit,
    DependencyGate,
    EpicReview,
    GitHub.PullRequest,
    Handoff,
    Hold,
    LeftoverProcesses,
    Linear.Issue,
    Linear.TransientRetry,
    Linear.Usage,
    Notifications,
    PathUnlock,
    PromptBuilder,
    PrReviewPoller,
    PrWatch,
    QaVerification,
    RunKind,
    RunStore,
    SetupBlock,
    StateMachine,
    SubIssueWait,
    TicketPullRequest,
    TicketSignals,
    Tracker,
    TransitionGuard,
    UsageLimit,
    Verification,
    Workpad,
    Workspace,
    WorkspaceCleanup,
    WorkspaceHead
  }

  @dev_server_pid_key {__MODULE__, :verification_dev_server_pid}
  @idle_park_state "Backlog"
  @merging_state "Merging"
  # Consecutive turns with no new commit, no state change and no PR change that end the run.
  @max_empty_turns 2
  # Fallback when settings are unavailable; the effective value comes from
  # `agent.codex_stdio_prompt_soft_limit` (see Config.Schema.Agent).
  @codex_stdio_prompt_soft_limit_fallback 65_536
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
        reviewer_comments: pending_reviewer_comments(issue, opts),
        settings: settings
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
      |> put_tool_call_notice(issue, codex_update_recipient)

    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), settings.worker.ssh_hosts)
    Usage.put_caller({:agent, Map.get(issue, :identifier)})

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case guard_closed_pull_request(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")

        cond do
          hold = provider_hold_reason(reason) ->
            exit(hold)

          exits_as_is?(reason) ->
            exit(reason)

          SetupBlock.setup_block?(reason) ->
            exit({:setup_block, reason})

          linear_unavailable?(reason) ->
            exit({:linear_unavailable, reason})

          true ->
            raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end
    end
  end

  # A ticket in a phase that works on its existing pull request (Code Review, QA, CI Fix, Rework,
  # Merging) whose pull request is closed — a Backlog move closes it, and moving the ticket back does
  # not reopen it — pauses on a person's decision before its workspace is built, so no run judges
  # the base branch in place of its change (`SymphonyElixir.ClosedPullRequest`).
  defp guard_closed_pull_request(issue, codex_update_recipient, opts, worker_host) do
    case ClosedPullRequest.guard(issue, Keyword.fetch!(opts, :settings), Keyword.take(opts, [:repo_key, :tracker, :store])) do
      :run -> run_on_worker_host(issue, codex_update_recipient, opts, worker_host)
      :held -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The orchestrator holds the provider's runs until the limit resets instead of failing the run;
  # it does the same, until a probe gets through, for a model API the agent couldn't reach.
  # An epic review's or the QA state's agent reports either one as `{:usage_limited, info}`.
  defp provider_hold_reason({:usage_limited, %{} = info}) do
    if UsageLimit.api_unreachable?(info), do: {:model_api_unreachable, info}, else: {:usage_limited, info}
  end

  defp provider_hold_reason({:model_api_unreachable, %{}} = reason), do: reason
  defp provider_hold_reason(_reason), do: nil

  # The reasons the orchestrator reads as they are: the tool-failure circuit breaker, and an epic
  # review or a QA pass waiting for CI.
  defp exits_as_is?(reason), do: terminal_tool_failure_circuit_breaker?(reason) or ci_pending?(reason)

  # An epic review that found CI still running on the commit it reviews, or a QA pass whose named
  # check is still running on the PR head: the orchestrator starts it again after a short wait
  # instead of failing the run (`SymphonyElixir.EpicReview`, `SymphonyElixir.QaVerification`).
  defp ci_pending?({:ci_pending, %{}}), do: true
  defp ci_pending?(_reason), do: false

  defp terminal_tool_failure_circuit_breaker?({:tool_failure_circuit_breaker, _payload}), do: true
  defp terminal_tool_failure_circuit_breaker?(_reason), do: false

  # Tells the orchestrator before each wait on Linear in this run, so its stall check and
  # no-progress watchdog count the wait as activity instead of restarting the run.
  defp put_linear_wait_notice(opts, %{id: issue_id}, recipient) when is_binary(issue_id) and is_pid(recipient) do
    notify = fn _reason, delay_ms -> send(recipient, {:linear_wait, issue_id, delay_ms}) end
    Keyword.update(opts, :linear_retry_opts, [on_wait: notify], &Keyword.put_new(&1, :on_wait, notify))
  end

  defp put_linear_wait_notice(opts, _issue, _recipient), do: opts

  # Tells the orchestrator as each of Symphony's own MCP tool calls in this run starts and ends;
  # see `SymphonyElixir.McpServer`.
  defp put_tool_call_notice(opts, %{id: issue_id}, recipient) when is_binary(issue_id) and is_pid(recipient) do
    Keyword.put_new(opts, :on_tool_call, fn event -> send(recipient, {:mcp_tool_call, issue_id, event}) end)
  end

  defp put_tool_call_notice(opts, _issue, _recipient), do: opts

  # A step that still could not reach Linear once its wait ran out, such as
  # `{:idle_park_failed, {:linear_rate_limited, until_ms}}`, failed through no fault of the
  # issue; the orchestrator retries the run without counting an attempt.
  defp linear_unavailable?(reason) when is_tuple(reason) and tuple_size(reason) > 1 do
    reason |> elem(tuple_size(reason) - 1) |> TransientRetry.transient?()
  end

  defp linear_unavailable?(_reason), do: false

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
                  send_linked_issues(codex_update_recipient, enriched_issue)

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

  # Every agent session of the run gets the folder as its `$TMPDIR`, writable in its sandbox. A
  # run that can't create one still runs, with the runtime's default temp folder.
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
    # A removal of this issue's workspace may still be running from when it last ended.
    WorkspaceCleanup.await(issue.identifier)

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
  # open, same-repo, and its head is this issue's branch under the old key, keep
  # working on that head. Lookup failures fall back to the default branch.
  #
  # Any other head is ignored: Linear links a PR to every issue its body names after
  # a word such as "Part of", so a parent can carry its sub-ticket's PR, and taking
  # that head would put the parent's run on the sub-ticket's branch.
  defp renamed_issue_pr_head_ref(%Issue{identifier: identifier} = issue, opts) when is_binary(identifier) do
    case ticket_pr_url(issue, opts) do
      pr_url when is_binary(pr_url) -> open_own_pr_head_ref(issue, pr_url, opts)
      nil -> nil
    end
  end

  defp renamed_issue_pr_head_ref(_issue, _opts), do: nil

  defp open_own_pr_head_ref(issue, pr_url, opts) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_ci_status(pr_url, []) do
      {:ok, %{state: "OPEN", is_cross_repository: false, head_ref_name: head_ref}}
      when is_binary(head_ref) and head_ref != "" ->
        renamed_own_head_ref(issue, pr_url, head_ref)

      _status ->
        nil
    end
  end

  defp renamed_own_head_ref(%Issue{identifier: identifier} = issue, pr_url, head_ref) do
    cond do
      head_ref == "auto/" <> identifier ->
        nil

      renamed_issue_branch?(identifier, head_ref) ->
        head_ref

      true ->
        Logger.warning("Ignoring attached PR on another issue's branch #{issue_context(issue)} pr_url=#{pr_url} head_ref=#{head_ref}")
        nil
    end
  end

  # The same issue number under another team key: `auto/TON-218` for `TP-218`.
  defp renamed_issue_branch?(identifier, "auto/" <> branch_identifier) do
    case {issue_number(identifier), issue_number(branch_identifier)} do
      {number, number} when is_binary(number) -> true
      _numbers -> false
    end
  end

  defp renamed_issue_branch?(_identifier, _head_ref), do: false

  defp issue_number(identifier) do
    case Regex.run(~r/\A[A-Za-z][A-Za-z0-9]*-(\d+)\z/, identifier) do
      [_identifier, number] -> number
      nil -> nil
    end
  end

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
    case PrWatch.pending_ci_failure(issue_id, pending_lookup_opts(issue, opts)) do
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

  defp send_codex_update(recipient, %Issue{id: issue_id}, message) when is_binary(issue_id) and is_pid(recipient) do
    payload = SymphonyElixir.ClaudeCode.AppServer.event_to_update(message) || message
    send(recipient, {:codex_worker_update, issue_id, payload})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

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

  # The ticket's parent and links the enrichment read, so the ticket page can show them without a
  # Linear read of its own (see `SymphonyElixir.Connected`).
  defp send_linked_issues(recipient, %Issue{id: issue_id} = issue) when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:worker_runtime_info, issue_id, %{linked: Connected.linked(issue)}})
    :ok
  end

  defp send_linked_issues(_recipient, _issue), do: :ok

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

  # A `Code Review` ticket is reviewed rather than executed
  # (`SymphonyElixir.CodeReview`), its `QA` ticket verified rather than executed
  # (`SymphonyElixir.QaVerification`), and its epic parent reviewed once its sub-tickets are
  # terminal (`SymphonyElixir.EpicReview`). Anything else is an ordinary run.
  defp run_issue(workspace, issue, codex_update_recipient, opts, worker_host) do
    walkthrough_opts =
      opts
      |> Keyword.put(:worker_host, worker_host)
      |> Keyword.put(:on_message, codex_message_handler(codex_update_recipient, issue))

    case Keyword.get(opts, :code_review, CodeReview).run(issue, workspace, walkthrough_opts) do
      :skip -> run_non_review_issue(workspace, issue, codex_update_recipient, opts, walkthrough_opts, worker_host)
      result -> result
    end
  end

  defp run_non_review_issue(workspace, issue, codex_update_recipient, opts, walkthrough_opts, worker_host) do
    case Keyword.get(opts, :qa_verification, QaVerification).run(issue, workspace, walkthrough_opts) do
      :skip -> run_epic_or_parent_run(workspace, issue, codex_update_recipient, opts, walkthrough_opts, worker_host)
      result -> result
    end
  end

  # The epic review is machine-owned and applies to an epic parent
  # (`SymphonyElixir.EpicReview.epic_review_run?/2`), so an epic is never executed turn by turn.
  defp run_epic_or_parent_run(workspace, issue, codex_update_recipient, opts, walkthrough_opts, worker_host) do
    case Keyword.get(opts, :epic_review, EpicReview).run(issue, workspace, walkthrough_opts) do
      :skip -> run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
      result -> result
    end
  end

  # A ticket whose history summary is over its size limit starts no agent until the Director says how
  # it goes on (`PromptBuilder.ticket_ledger_gate/2`).
  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    case PromptBuilder.ticket_ledger_gate(issue, repo_key: run_repo_key(issue, opts)) do
      :start -> start_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
      gate -> stop_for_ticket_summary(gate, issue, opts)
    end
  end

  # The run ends like any run a hold stopped: not a failure, and the hold, not a retry, says when the
  # ticket runs again. A request that can't be raised fails the run, so the next one asks again.
  defp stop_for_ticket_summary({:ask, request}, issue, opts) do
    case DecisionRequest.ask(issue, request, [repo_key: run_repo_key(issue, opts)] ++ Keyword.take(opts, [:tracker])) do
      :ok ->
        Logger.info("Starting no agent for #{issue_context(issue)}: its ticket summary is over ledger.prompt_brief_max_tokens; asked the Director how it goes on")
        :ok

      {:error, reason} ->
        {:error, {:ticket_summary_request_failed, reason}}
    end
  end

  defp stop_for_ticket_summary(:waiting, issue, _opts) do
    Logger.info("Starting no agent for #{issue_context(issue)}: its ticket summary is over ledger.prompt_brief_max_tokens and the Director's answer is pending")
    :ok
  end

  defp stop_for_ticket_summary(:cancel, issue, opts) do
    case cancel_issue(issue, opts) do
      {:ok, state} ->
        record_move_signal(issue, "decision returned", %{move: "cancel", from: issue.state, to: state}, opts)
        Logger.info("Moved #{issue_context(issue)} to #{state}: the Director canceled it over its ticket summary")
        :ok

      {:error, reason} ->
        {:error, {:ticket_summary_cancel_failed, reason}}
    end
  end

  # The team's canceled state, under either spelling.
  defp cancel_issue(issue, opts) do
    ctx = %{repo_key: run_repo_key(issue, opts)}

    Enum.reduce_while(["Canceled", "Cancelled"], {:error, :state_not_found}, fn state, _result ->
      case TransitionGuard.perform(issue.id, :director_move, Map.put(ctx, :target, state), Keyword.take(opts, [:tracker])) do
        :ok -> {:halt, {:ok, state}}
        {:error, :state_not_found} = error -> {:cont, error}
        error -> {:halt, error}
      end
    end)
  end

  defp start_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    settings = Keyword.fetch!(opts, :settings)
    max_turns = Keyword.get(opts, :max_turns, settings.agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    seed_ids = AgentTools.Linear.recover_comment_registry_seeds(issue, settings.tracker.kind, Keyword.take(opts, [:linear_retry_opts]))

    opts =
      opts
      |> Keyword.put_new_lazy(:run_profile, fn -> run_profile(issue, settings, opts) end)
      |> put_path_unlocks(issue)

    with {:ok, agent_module} <- agent_module(opts),
         {:ok, linear_comment_registry} <- ensure_comment_registry(opts, seed_ids),
         {:ok, session} <-
           start_agent_session(agent_module, workspace, worker_host, issue, Keyword.put(opts, :linear_comment_registry, linear_comment_registry)) do
      send_agent_session_info(codex_update_recipient, issue, agent_module, session)

      # Capture pending rework context (reviewer comments, CI failure, PR
      # conflict) up front so every turn of the run sees the same snapshot as
      # the first-turn prompt, even if the pending records get completed
      # mid-run.
      run_opts =
        opts
        |> Keyword.put(:linear_comment_registry, linear_comment_registry)
        |> put_reviewer_comments(issue)
        |> put_ci_failure(issue)
        |> put_pr_conflict(issue)
        |> put_ticket_state(issue)
        |> put_decisions(issue)

      run_context = %{
        workspace: workspace,
        issue: issue,
        codex_update_recipient: codex_update_recipient,
        opts: run_opts,
        issue_state_fetcher: issue_state_fetcher,
        worker_host: worker_host,
        progress: initial_progress(workspace, worker_host, issue, run_opts),
        dispatch_pr_url: ticket_pr_url(issue, run_opts)
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

    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
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

      {:error, _reason} = error ->
        error
    end
  end

  # A person's decision may unlock a protected path for this run only (`SymphonyElixir.PathUnlock`):
  # the run claims the grant before its session starts, and its sandbox, tools and prompt get it.
  defp put_path_unlocks(opts, issue) do
    unlocks = PathUnlock.claim(issue, run_repo_key(issue, opts), Keyword.take(opts, [:run_id, :run_store]))

    opts
    |> Keyword.put(:path_unlocks, unlocks)
    |> Keyword.put(:unlocked_paths, PathUnlock.paths(unlocks))
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
      extra_env: AgentTmpDir.env(settings.agent.kind, Keyword.get(opts, :agent_tmp_dir)),
      on_tool_call: Keyword.get(opts, :on_tool_call),
      unlocked_paths: Keyword.get(opts, :unlocked_paths, [])
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
      dependency_audit_command_runner: Keyword.get(opts, :dependency_audit_command_runner),
      unlocked_paths: Keyword.get(opts, :unlocked_paths, [])
    )
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
        end_idle_run(issue, run_context)

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

  # The dependency changes need a person's approval: the ticket pauses in its phase on a Needs
  # Decision hold (`DependencyGate.pause/4`), and the decision clears it so the ticket continues.
  defp hold_dependency_approval(%Issue{id: issue_id} = issue, items, turn_session, opts)
       when is_binary(issue_id) do
    pause = fn -> DependencyGate.pause(issue, {:hold, items}, run_repo_key(issue, opts), Keyword.take(opts, [:tracker])) end

    case with_linear_retry(pause, "holding #{issue_context(issue)} for dependency approval", opts) do
      :ok ->
        record_move_signal(issue, "decision requested", %{hold: "needs_decision", reason: "dependency_source_requires_approval"}, opts)

        Notifications.emit_issue_event(
          :dependency_pending_approval,
          issue,
          dependency_approval_attrs(issue, items, turn_session, opts)
        )

        Logger.warning("Dependency approval required for #{issue_context(issue)} items=#{length(items)}")
        {:hold, items}

      {:error, reason} ->
        {:error, {:dependency_approval_hold_failed, reason}}
    end
  end

  defp hold_dependency_approval(issue, items, turn_session, opts) do
    Notifications.emit_issue_event(
      :dependency_pending_approval,
      issue,
      dependency_approval_attrs(issue, items, turn_session, opts)
    )

    {:hold, items}
  end

  defp dependency_approval_attrs(issue, items, turn_session, opts) do
    %{
      repo_key: Keyword.get(opts, :repo_key),
      run_id: Keyword.get(opts, :run_id),
      session_id: turn_session[:session_id],
      state: Map.get(issue, :state),
      reason: "dependency_source_requires_approval",
      metadata: DependencyAudit.approval_metadata(items)
    }
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp continue_active_issue(agent_module, app_session, run_context, refreshed_issue, turn_number, max_turns) do
    Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

    do_run_codex_turns(agent_module, app_session, run_context, turn_number + 1, max_turns)
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
    build_turn_prompt(issue, opts, 1, Keyword.get(opts, :max_turns, 1))
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    prompt_opts =
      opts
      |> put_reviewer_comments(issue)
      |> put_ci_failure(issue)
      |> put_pr_conflict(issue)
      |> put_open_pr_overlap(issue)
      |> put_ticket_state(issue)
      |> put_decisions(issue)

    prompt = PromptBuilder.build_prompt(issue, prompt_opts)
    maybe_compact_codex_initial_prompt(prompt, issue, prompt_opts)
  end

  defp build_turn_prompt(_issue, opts, turn_number, max_turns) do
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
    """
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
    PrWatch.pending_ci_failure(issue_id, pending_lookup_opts(issue, opts))
  end

  defp pending_ci_failure(_issue, _opts), do: nil

  defp put_pr_conflict(opts, issue) when is_list(opts) do
    if Keyword.has_key?(opts, :pr_conflict) do
      opts
    else
      Keyword.put(opts, :pr_conflict, pending_pr_conflict(issue, opts))
    end
  end

  defp pending_pr_conflict(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    PrWatch.pending_pr_conflict(issue_id, pending_lookup_opts(issue, opts))
  end

  defp pending_pr_conflict(_issue, _opts), do: nil

  defp put_open_pr_overlap(opts, %Issue{id: issue_id} = issue) when is_binary(issue_id) do
    Keyword.put_new_lazy(opts, :open_pr_overlap, fn ->
      PrWatch.open_pr_overlap(issue_id, pending_lookup_opts(issue, opts))
    end)
  end

  defp put_open_pr_overlap(opts, _issue), do: opts

  defp put_ticket_state(opts, issue) when is_list(opts) do
    if Keyword.has_key?(opts, :ticket_state) do
      opts
    else
      Keyword.put(opts, :ticket_state, pending_ticket_state(issue, opts))
    end
  end

  # The decisions the prompt renders come from the ticket's store record, not from its description.
  defp put_decisions(opts, issue) do
    if Keyword.has_key?(opts, :decisions) do
      opts
    else
      Keyword.put(opts, :decisions, Decisions.stored(issue, repo_key: Keyword.get(opts, :repo_key) || issue_repo_key(issue)))
    end
  end

  defp pending_ticket_state(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    case Keyword.get(opts, :repo_key) || issue_repo_key(issue) do
      repo_key when is_binary(repo_key) and repo_key != "" -> RunStore.get_ticket_state(repo_key, issue_id)
      _repo_key -> nil
    end
  end

  defp pending_ticket_state(_issue, _opts), do: nil

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

        if waiting_on_hold?(refreshed_issue, opts) do
          Logger.info("Stopping agent run for #{issue_context(refreshed_issue)}; it waits on a hold or on its decision request")
          {:done, refreshed_issue}
        else
          continue_unheld_issue?(issue, refreshed_issue, run_context)
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _opts, _run_context), do: {:done, issue}

  defp continue_unheld_issue?(%Issue{} = issue, %Issue{} = refreshed_issue, run_context) do
    cond do
      post_pr_quiet_continuation?(issue, refreshed_issue, run_context) ->
        Logger.info("Stopping agent run for #{issue_context(refreshed_issue)} after PR opened; waiting for review, CI, or manual rework signal")
        hand_off_quiet_pr_head(issue, refreshed_issue, run_context)

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
  end

  # The checks that hand a run on its PR to CI or review, instead of parking it, read the ticket's
  # PR from Symphony's record. Say so when one the ticket had at dispatch is gone.
  defp warn_if_pr_url_lost(%Issue{} = refreshed_issue, %{dispatch_pr_url: pr_url} = run_context) when is_binary(pr_url) do
    if is_nil(ticket_pr_url(refreshed_issue, run_context.opts)) do
      Logger.warning("#{issue_context(refreshed_issue)} had PR #{pr_url} at dispatch, but Symphony's record of its PR now shows no open PR; checks on its PR will not run")
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

  # A decision request (`linear_request_human_action`) or a reported block pauses the ticket in its
  # phase on a hold, and the hold, not another turn, says when it continues: a turn would only
  # repeat the wait, and enough of them would park it as idle. A request this run posted counts even
  # before its hold is in the store, so a failed hold write never parks the ticket under its question.
  defp waiting_on_hold?(%Issue{id: issue_id} = issue, opts) do
    CommentRegistry.human_action_requested?(Keyword.get(opts, :linear_comment_registry)) or
      Hold.held_any?(run_repo_key(issue, opts), issue_id)
  end

  defp waiting_on_sub_issues?(%Issue{} = issue) do
    settings = Config.settings!()
    terminal_states = settings.tracker.terminal_states

    Issue.waiting_on_sub_issues?(issue, terminal_states) or SubIssueWait.held?(issue, terminal_states, settings)
  end

  defp post_pr_quiet_continuation?(%Issue{} = previous_issue, %Issue{} = refreshed_issue, run_context) do
    case ticket_pr_url(refreshed_issue, run_context.opts) || ticket_pr_url(previous_issue, run_context.opts) do
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

  # A ticket advances only on the handoff signal, which the push and PR tool hooks emit. A
  # run that finds its PR already on the workspace HEAD (an interrupted run's successor, a park and
  # unpark) has nothing to push, so no hook fires and every successor would stop the same way. The
  # ticket is then exactly where a signal for that head would put it, so the signal is recorded for
  # the head and the run hands off. A HEAD or PR head that can't be read hands nothing off; the
  # orchestrator caps those quiet runs.
  defp hand_off_quiet_pr_head(%Issue{} = previous_issue, %Issue{} = issue, run_context) do
    pr_url = ticket_pr_url(issue, run_context.opts) || ticket_pr_url(previous_issue, run_context.opts)

    with true <- Handoff.origin?(issue.state),
         head when is_binary(head) <- read_workspace_head(run_context.workspace, run_context.worker_host, run_context.opts),
         true <- pr_url_head?(pr_url, head, run_context) do
      Handoff.emit(run_repo_key(issue, run_context.opts), issue.id, %{head: head, pr_url: pr_url, source: "pushed_pr_head"})
      run_context = put_in(run_context.progress.head, head)

      case move_to_post_pr_state(issue, post_pr_state(run_context), "with its PR already on its head", run_context) do
        :ok -> {:done, issue}
        {:error, reason} -> {:error, {:pushed_pr_head_handoff_failed, reason}}
      end
    else
      _no_handoff -> {:done, issue}
    end
  end

  defp pr_url_head?(pr_url, head, run_context) do
    github = Keyword.get(run_context.opts, :github, PullRequest)

    case github.fetch_ci_status(pr_url, cwd: run_context.workspace) do
      {:ok, %{commit_sha: ^head}} -> true
      _other -> false
    end
  end

  # The run's work is on its PR once the workspace HEAD is the PR head. A commit the run has not
  # pushed keeps the run going, so the agent pushes it. An unreadable HEAD or PR head stops the run
  # as before; the orchestrator checks the workspace for unpushed commits before it moves the issue
  # on.
  defp work_on_pr?(%Issue{} = issue, pr_url, run_context) do
    head = read_workspace_head(run_context.workspace, run_context.worker_host, run_context.opts)
    github = Keyword.get(run_context.opts, :github, PullRequest)

    with true <- is_binary(head),
         {:ok, %{commit_sha: pr_head}} when is_binary(pr_head) <-
           github.fetch_ci_status(pr_url, cwd: run_context.workspace) do
      if pr_head == head do
        true
      else
        Logger.info("Not stopping agent run for #{issue_context(issue)} after PR opened; workspace HEAD #{head} is not its PR head #{pr_head}, continuing so it is pushed")
        false
      end
    else
      _unknown -> true
    end
  end

  defp no_pending_rework_signal?(%Issue{} = issue, opts) do
    pending_reviewer_comments(issue, opts) == [] and
      is_nil(pending_ci_failure(issue, opts)) and
      is_nil(pending_pr_conflict(issue, opts))
  end

  # A turn makes progress when it adds a commit, changes the issue state or attaches a PR. Without a
  # readable workspace HEAD (an SSH worker, no git checkout) progress is unknown and no turn
  # counts as empty.
  defp initial_progress(workspace, worker_host, issue, opts) do
    head = read_workspace_head(workspace, worker_host, opts)
    fingerprint = progress_fingerprint(head, issue, opts)
    rework_base = rework_base(issue, head, opts)
    %{rework_base: rework_base, start_head: head, head: head, fingerprint: fingerprint, empty_turns: 0}
  end

  # The head a Rework started from: recorded by the first run dispatched in Rework and reused by
  # re-dispatched runs, so rework an earlier run pushed still counts. A run outside Rework forgets
  # it. When the store is unavailable only this run's own commits count.
  defp rework_base(%Issue{id: issue_id} = issue, head, opts) when is_binary(issue_id) and is_binary(head) do
    repo_key = run_repo_key(issue, opts)

    if rework_state?(issue.state) and attached_pr?(issue, opts) do
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
    fingerprint = progress_fingerprint(head, refreshed_issue, run_context.opts)
    empty_turns = if is_nil(head) or fingerprint != progress.fingerprint, do: 0, else: progress.empty_turns + 1

    %{run_context | progress: %{progress | head: head, fingerprint: fingerprint, empty_turns: empty_turns}}
  end

  defp read_workspace_head(workspace, worker_host, opts) do
    reader = Keyword.get(opts, :workspace_head_reader, &WorkspaceHead.read/2)
    reader.(workspace, worker_host)
  end

  defp progress_fingerprint(head, issue, opts), do: {head, Map.get(issue, :state), ticket_pr_url(issue, opts)}

  # Nothing moves an issue out of `Rework` once its rework is done: the post-PR move skips `Rework`.
  # The rework is done once the workspace HEAD has moved past the head the Rework started from (by
  # this run or an earlier one), that HEAD is the attached PR's head, and no review, CI, QA or
  # conflict signal is pending.
  defp rework_finished?(%Issue{} = issue, %{progress: %{head: head} = progress} = run_context) when is_binary(head) do
    rework_state?(issue.state) and attached_pr?(issue, run_context.opts) and
      head != progress.rework_base and
      no_pending_rework_signal?(issue, run_context.opts) and
      pr_head?(issue, head, run_context)
  end

  defp rework_finished?(_issue, _run_context), do: false

  defp pr_head?(%Issue{} = issue, head, run_context) do
    github = Keyword.get(run_context.opts, :github, PullRequest)

    case github.fetch_ci_status(ticket_pr_url(issue, run_context.opts), cwd: run_context.workspace) do
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
  # a new head to that PR and CI on that head is running or green, the PR and CI watcher takes it from
  # there: in the post-PR state it starts QA on green, and re-runs a flaky failure or dispatches a
  # fix run on red. So the run moves to that state instead of turning while CI runs until the idle
  # check parks it. Gives the CI action (`:pending` or `:success`), or nil for a head with no checks
  # yet, a red head or another PR head. `Rework` and `Merging` keep their own rules (`rework_finished?/2`,
  # `merging_ci_pending?/2`).
  defp pushed_head_handoff_ci_action(%Issue{} = issue, %{progress: %{head: head, start_head: start_head}} = run_context)
       when is_binary(head) and is_binary(start_head) do
    if head != start_head and !rework_state?(issue.state) and !merging_state?(issue.state) do
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

  # A finished implementation is handed off to `Code Review`.
  defp post_pr_state(run_context), do: run_context.opts |> Keyword.fetch!(:settings) |> Handoff.target_state()

  # An implementation handoff moves to `Code Review` only on the session's explicit handoff signal,
  # which the push and PR tool hooks emit into the ticket's ledger. Without it the run does not
  # advance: the ticket is left where it is with a `handoff_missing` event recorded,
  # and the run fails so the orchestrator's retry machinery picks it up.
  #
  # A CI Fix ticket takes neither path: a mechanical repair goes back to the phase the red head or
  # conflict found it in, which the poller recorded on the ticket (see `return_from_ci_fix/3`).
  defp move_to_post_pr_state(%Issue{} = issue, post_pr_state, reason, run_context) do
    if ci_fix_state?(issue, run_context) do
      return_from_ci_fix(issue, reason, run_context)
    else
      hand_off_to_state(issue, post_pr_state, reason, run_context)
    end
  end

  defp hand_off_to_state(%Issue{id: issue_id} = issue, post_pr_state, reason, run_context) do
    settings = Keyword.fetch!(run_context.opts, :settings)

    if Handoff.origin?(issue.state) and not handoff_emitted?(issue, run_context) do
      Logger.warning("Not moving #{issue_context(issue)} to #{post_pr_state} #{reason}: no handoff signal for its head")
      record_move_signal(issue, Handoff.missing_signal(), %{to: post_pr_state, reason: reason}, run_context.opts)
      {:error, {:handoff_signal_missing, post_pr_state}}
    else
      # The handoff is the table's explicit `:handoff` edge, whose target resolves from the settings
      # to the configured Code Review state.
      move = fn -> TransitionGuard.perform(issue_id, :handoff, %{settings: settings, repo_key: run_repo_key(issue, run_context.opts)}) end

      case with_linear_retry(move, "moving #{issue_context(issue)} to #{post_pr_state} #{reason}", run_context.opts) do
        :ok ->
          # A record of the completed move, marked as a move so it never stands in for the explicit
          # signal a later run's own head must still emit (`Handoff.emitted?/3`): a workspace HEAD
          # that reads nil, as an SSH worker's does, would otherwise make this head-less record count
          # for any head.
          record_move_signal(
            issue,
            "handoff",
            %{to: post_pr_state, reason: reason, head: run_context.progress.head, move: true},
            run_context.opts
          )

          :ok

        error ->
          error
      end
    end
  end

  defp ci_fix_state?(%Issue{} = issue, run_context),
    do: CiFix.in_state?(issue.state, Keyword.fetch!(run_context.opts, :settings))

  # A mechanical repair returns the ticket to the phase whose red head or conflict put it in the lane,
  # which the poller recorded on the ticket. The prior verdict is not touched — only `Rework`
  # invalidates one — so a phase that already holds a verdict on this head carries the ticket on
  # without a second review or QA run.
  defp return_from_ci_fix(%Issue{id: issue_id} = issue, reason, run_context) do
    case CiFix.origin(run_repo_key(issue, run_context.opts), issue_id, run_context.opts) do
      origin when is_binary(origin) ->
        do_return_from_ci_fix(issue, origin, reason, run_context)

      nil ->
        # The origin is the whole point of the lane, so a ticket that lost it does not guess: it
        # takes the ordinary post-PR handoff, where review judges its head, rather than returning to
        # a phase nobody recorded.
        post_pr_state = post_pr_state(run_context)

        Logger.warning("No CI Fix origin recorded for #{issue_context(issue)}; moving it to #{post_pr_state} #{reason} instead")

        hand_off_to_state(issue, post_pr_state, reason, run_context)
    end
  end

  defp do_return_from_ci_fix(%Issue{id: issue_id} = issue, origin, reason, run_context) do
    settings = Keyword.fetch!(run_context.opts, :settings)
    head = run_context.progress.head

    # A return to `Merging` starts a new stay there, in which the PR and CI watcher turns
    # auto-merge on again for the head (rule R30): the approval still covers the PR.
    label = "returning #{issue_context(issue)} to #{origin} from CI Fix"
    ctx = %{target: origin, settings: settings, repo_key: run_repo_key(issue, run_context.opts)}
    move = fn -> TransitionGuard.perform(issue_id, :ci_fix_mechanical, ctx) end

    case with_linear_retry(move, label, run_context.opts) do
      :ok ->
        repo_key = run_repo_key(issue, run_context.opts)
        # A repair that pushed a new head re-binds the origin's verdict to it, so the ticket carries
        # forward rather than being reviewed or verified a second time; a repair that pushed nothing
        # leaves the binding as it was.
        CiFix.carry_verdict(repo_key, issue_id, origin, head, settings)
        CiFix.record_origin(repo_key, issue_id, nil, run_context.opts)
        CiFix.record_verdict(repo_key, issue_id, "mechanical", %{to: origin, carried: true, head: head, reason: reason})
        record_move_signal(issue, "ci fix return", %{to: origin, kind: :ci_fix, head: head, move: true}, run_context.opts)
        :ok

      error ->
        error
    end
  end

  defp handoff_emitted?(%Issue{id: issue_id} = issue, run_context) when is_binary(issue_id) do
    Handoff.emitted?(run_repo_key(issue, run_context.opts), issue_id, run_context.progress.head)
  end

  defp handoff_emitted?(_issue, _run_context), do: false

  # A landing run waits on CI through `merging_ci_pending?/2`, and parking it would drop the
  # human's merge approval.
  defp idle_turn_limit_reached?(%Issue{} = issue, %{progress: progress}) do
    progress.empty_turns >= @max_empty_turns and !merging_state?(issue.state)
  end

  # A Rework run that pushed a new head to its PR, with CI on it running or green, waits on that CI,
  # so it is not idle: it moves to the post-PR state, where the PR and CI watcher takes the head over. That
  # covers what `rework_finished?/2` skips, such as a Rework started by a CI failure, which stays
  # pending until the run ends. Outside Rework, `pushed_head_handoff_ci_action/2` already handed off
  # such a head. A run whose HEAD is the PR head with checks pending but that is not handed off (one
  # that started on that head) keeps turning, up to
  # `agent.max_turns`, until CI settles. A CI-fix run that found the red check a flake, or a
  # merge-conflict run that found the PR no longer conflicts, rightly pushes nothing: once CI on
  # its PR head is green, that is its outcome, so it hands the PR back instead of being parked
  # (`hand_off_green_fix/3`). Any other idle run is parked.
  defp end_idle_run(%Issue{} = issue, %{progress: %{head: head}} = run_context) do
    ci_status = pushed_head_ci_status(issue, run_context)
    ci_action = ci_action(ci_status)
    green_fix = if ci_action == :success, do: green_fix(issue, ci_status, run_context)

    cond do
      ci_action in [:pending, :success] and rework_state?(issue.state) and pushed_new_head?(run_context) ->
        hand_off_idle_pushed_head(issue, ci_action, run_context)

      ci_action == :pending ->
        Logger.info("Not parking #{issue_context(issue)}; waiting for CI on its pushed head #{head}")
        :continue

      green_fix != nil ->
        hand_off_green_fix(issue, green_fix, run_context)

      true ->
        park_idle_run(issue, run_context)
    end
  end

  # The head moved past the one this run started on, or past the head the rework started from, so
  # rework an earlier run pushed counts too.
  defp pushed_new_head?(%{progress: progress}), do: progress.head != progress.start_head or progress.head != progress.rework_base

  defp hand_off_idle_pushed_head(%Issue{} = issue, ci_action, run_context) do
    with :ok <- hand_off_pushed_head(issue, ci_action, run_context) do
      forget_rework_base(issue, run_context.opts)
    end
  end

  # The fix a run that pushed nothing was dispatched for, given as the kind, whether the PR was
  # approved (in `Merging`) when the signal came, and the head it came on; or nil. A CI-fix run
  # answers a CI failure; a merge-conflict run answers a conflict, and only a PR GitHub now calls
  # `MERGEABLE` shows it needed no commit, so one still conflicting (or not computed yet) is parked
  # as before, whatever else is pending. `Rework` keeps its own rule (`rework_finished?/2`): a
  # rework that adds no commit is not done.
  defp green_fix(%Issue{} = issue, ci_status, %{opts: opts}) do
    cond do
      rework_state?(issue.state) -> nil
      is_map(opts[:pr_conflict]) and Map.get(ci_status, :mergeable) != "MERGEABLE" -> nil
      is_map(opts[:ci_failure]) -> {:ci_fix, opts[:ci_failure][:approved], opts[:ci_failure][:commit_sha]}
      is_map(opts[:pr_conflict]) -> {:conflict_fix, opts[:pr_conflict][:approved], opts[:pr_conflict][:head_sha]}
      true -> nil
    end
  end

  defp park_idle_run(%Issue{} = issue, run_context) do
    forget_rework_base(issue, run_context.opts)
    park_idle_issue(issue, run_context.opts)
  end

  # A fix on an approved PR (the CI failure or conflict came from `Merging`) whose PR head is still
  # the commit it came on goes back to `Merging`, where auto-merge turns on again: the approval
  # still covers the PR's diff. Any other green fix, such as a run that started on a fix an earlier
  # run pushed, goes to the post-PR state, where review judges its head.
  defp hand_off_green_fix(%Issue{} = issue, {kind, approved, signal_head}, %{progress: %{head: head, start_head: start_head}} = run_context) do
    if ci_fix_state?(issue, run_context) do
      # A CI Fix ticket that pushed nothing returns to its recorded origin whatever the origin is —
      # `Merging` included, where `return_from_ci_fix/3` releases the auto-merge hold.
      Logger.info("CI is green on #{issue_context(issue)}'s PR head #{head} after a #{fix_run_name(kind)} with no new commit; returning it to its CI Fix origin")

      return_from_ci_fix(issue, "with CI green on its PR head", run_context)
    else
      do_hand_off_green_fix(issue, {kind, approved, signal_head}, head, start_head, run_context)
    end
  end

  defp do_hand_off_green_fix(%Issue{} = issue, {kind, approved, signal_head}, head, start_head, run_context) do
    if approved == true and head == start_head and head == signal_head do
      Logger.info("#{fix_run_name(kind)} for #{issue_context(issue)} pushed nothing and CI on its PR head #{head} is green; moving back to #{@merging_state}")
      return_to_merging(issue, kind, head, run_context)
    else
      post_pr_state = post_pr_state(run_context)
      Logger.info("CI is green on #{issue_context(issue)}'s PR head #{head} after a #{fix_run_name(kind)} with no new commit; moving to #{post_pr_state}")

      case move_to_post_pr_state(issue, post_pr_state, "with CI green on its PR head", run_context) do
        :ok -> :ok
        {:error, reason} -> {:error, {:green_fix_handoff_failed, kind, reason}}
      end
    end
  end

  defp fix_run_name(:ci_fix), do: "CI fix run"
  defp fix_run_name(:conflict_fix), do: "merge conflict run"

  defp return_to_merging(%Issue{id: issue_id} = issue, kind, head, run_context) do
    label = "moving #{issue_context(issue)} back to #{@merging_state} with CI green"
    ctx = %{settings: Keyword.fetch!(run_context.opts, :settings), repo_key: run_repo_key(issue, run_context.opts)}
    move = fn -> TransitionGuard.perform(issue_id, :merge_ready, ctx) end
    comment = fn -> Tracker.create_comment(issue_id, green_fix_note(kind, head)) end

    with :ok <- with_linear_retry(move, label, run_context.opts),
         :ok <- with_linear_retry(comment, label, run_context.opts) do
      record_move_signal(issue, "handoff", %{to: @merging_state, kind: kind, head: head, move: true}, run_context.opts)
      :ok
    else
      {:error, reason} -> {:error, {:green_fix_handoff_failed, kind, reason}}
    end
  end

  defp green_fix_note(:ci_fix, head) do
    """
    Symphony moved this issue back to #{@merging_state}: the CI fix run found nothing to change and pushed no commit, and CI on the PR head `#{head}` is green, so the approval still covers the PR and auto-merge turns back on.
    """
  end

  defp green_fix_note(:conflict_fix, head) do
    """
    Symphony moved this issue back to #{@merging_state}: the merge conflict run found nothing to resolve and pushed no commit, the PR no longer conflicts with the base branch, and CI on the PR head `#{head}` is green, so the approval still covers the PR and auto-merge turns back on.
    """
  end

  # The CI action for the workspace HEAD when it is the attached PR's head, or nil. A PR with no
  # checks reported yet gives nil, so a repo without CI never waits on it and stays parkable. A
  # rerun the PR and CI watcher started on that head reads as running until its checks report again.
  defp pushed_head_ci_action(%Issue{} = issue, run_context), do: issue |> pushed_head_ci_status(run_context) |> ci_action()

  defp ci_action(nil), do: nil
  defp ci_action(ci_status), do: CiPoller.ci_action(ci_status)

  # The PR status `pushed_head_ci_action/2` reads its CI action from, or nil.
  defp pushed_head_ci_status(%Issue{} = issue, %{progress: %{head: head}} = run_context) do
    pr_url = ticket_pr_url(issue, run_context.opts)
    github = Keyword.get(run_context.opts, :github, PullRequest)

    with true <- is_binary(pr_url),
         {:ok, %{commit_sha: ^head, checks: [_ | _]} = ci_status} <-
           github.fetch_ci_status(pr_url, cwd: run_context.workspace) do
      CiPoller.put_rerun_pending(ci_status, issue.id, pending_lookup_opts(issue, run_context.opts))
    else
      _ -> nil
    end
  end

  defp park_idle_issue(%Issue{id: issue_id} = issue, opts) do
    Logger.warning(
      "Parking #{issue_context(issue)} in #{@idle_park_state} after #{@max_empty_turns} turns with no new commit or state change" <>
        idle_park_pr_note(issue, opts)
    )

    label = "parking #{issue_context(issue)} in #{@idle_park_state}"

    ctx = %{settings: Keyword.fetch!(opts, :settings), repo_key: run_repo_key(issue, opts)}

    with :ok <- with_linear_retry(fn -> TransitionGuard.perform(issue_id, :idle_park, ctx) end, label, opts),
         :ok <- with_linear_retry(fn -> Tracker.create_comment(issue_id, idle_park_note()) end, label, opts) do
      record_move_signal(issue, "blocked", %{to: @idle_park_state, reason: "idle_park"}, opts)
      :ok
    else
      {:error, reason} -> {:error, {:idle_park_failed, reason}}
    end
  end

  # The CI checks that keep a run that pushed from being parked read the ticket's PR. Saying
  # when there is none shows a lost PR link instead of parking without a trace.
  defp idle_park_pr_note(%Issue{} = issue, opts) do
    if attached_pr?(issue, opts), do: "", else: "; Symphony has no open PR recorded for it, so CI on its head was not checked"
  end

  defp idle_park_note do
    """
    Symphony parked this issue in #{@idle_park_state}: the agent's last #{@max_empty_turns} turns made no new commit and no state change, so another turn would repeat them. Move it back to Todo once it can make progress.
    """
  end

  defp attached_pr?(%Issue{} = issue, opts), do: is_binary(ticket_pr_url(issue, opts))

  # The ticket's in-flight PR, from Symphony's record. An issue the post-turn refresh returned may
  # carry no repo key, so the run's own repo key finds its record.
  defp ticket_pr_url(%Issue{} = issue, opts) do
    TicketPullRequest.current_url(%{issue | repo_key: issue_repo_key(issue) || Keyword.get(opts, :repo_key) || Config.repo_key_or_nil()})
  end

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
  # issue in `Merging` until the CI poller sees that head settle. Only the checks the base branch
  # requires count, when it requires any, and none once the poller let the head past them (see
  # `CiPoller.landing_action/1`).
  defp merging_ci_pending?(%Issue{} = issue, run_context) do
    pr_url = ticket_pr_url(issue, run_context.opts)

    if merging_state?(issue.state) and is_binary(pr_url) do
      github = Keyword.get(run_context.opts, :github, PullRequest)

      case github.fetch_ci_status(pr_url, cwd: run_context.workspace, required_checks: true) do
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
    lookup_opts = pending_lookup_opts(issue, run_context.opts)
    ci_status = CiPoller.put_rerun_pending(ci_status, issue.id, lookup_opts)

    if CiPoller.landing_action(ci_status) == :pending do
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

  # The machine's active states, not the raw `tracker.active_states`: tickets are dispatched from
  # the phase states (`Code Review`, `QA`, `Rework`, the CI Fix lane) too, even though the config
  # lists only the base states.
  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    StateMachine.active_states(Config.settings!())
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

  # Best-effort recording of a state move into the ticket's signals ledger (inert; a store failure
  # never changes the move). Runs only after the move has succeeded.
  defp record_move_signal(%Issue{id: issue_id} = issue, name, details, opts) when is_binary(issue_id) do
    TicketSignals.record(Keyword.get(opts, :repo_key) || issue_repo_key(issue), issue_id, name, details)
  end

  defp record_move_signal(_issue, _name, _details, _opts), do: :ok

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
