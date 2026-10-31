defmodule SymphonyElixir.DependencyGate do
  @moduledoc """
  Pre-PR dependency audit gate shared by the Codex and Claude (MCP) agent paths.

  Both paths must block `github_create_pull_request` (and the equivalent
  `gh pr create` shell approval) when the dependency audit reports a hold or
  fails. The gate also pauses the Linear issue in its phase on a Needs Decision
  hold (`pause/4`) and emits an operator-visible notification so dependency
  holds are surfaced before any PR is opened.
  """

  require Logger

  alias SymphonyElixir.{Config, DecisionRequest, DependencyAudit, Notifications, TicketSignals, Tracker}
  alias SymphonyElixir.HumanActions.PlainWords

  @type gate :: %{
          workspace: Path.t(),
          issue: term() | nil,
          settings: term() | nil,
          repo_key: String.t() | nil,
          audit_module: module(),
          base_ref: String.t() | nil,
          command_runner: term() | nil
        }

  @type evaluation ::
          :allow
          | {:hold, [map()], map()}
          | {:audit_error, term(), map()}

  @doc """
  Build a gate map from the standard agent options keyword list.

  Defaults `:audit_module` to `SymphonyElixir.DependencyAudit` so callers don't
  have to know the production module.
  """
  @spec build(Path.t(), term() | nil, term() | nil, keyword()) :: gate()
  def build(workspace, issue, settings, opts \\ []) do
    %{
      workspace: workspace,
      issue: issue,
      settings: settings,
      repo_key: Keyword.get(opts, :repo_key),
      audit_module: Keyword.get(opts, :dependency_audit_module) || DependencyAudit,
      base_ref: Keyword.get(opts, :dependency_audit_base_ref),
      command_runner: Keyword.get(opts, :dependency_audit_command_runner)
    }
  end

  @doc """
  Evaluate a tool name against the gate without performing any side effects.

  Returns `:allow` for non-PR-create tools, when the gate is missing, or when
  the audit reports no holds. Returns `{:hold, items, failure}` or
  `{:audit_error, reason, failure}` otherwise. Callers are responsible for
  wiring side effects with `react_to_hold/2` and `react_to_audit_error/2`.
  """
  @spec evaluate_pr_create_tool(term(), gate() | nil) :: evaluation()
  def evaluate_pr_create_tool(_tool, nil), do: :allow

  def evaluate_pr_create_tool(tool, %{} = gate) do
    if github_create_pull_request_tool?(tool) do
      evaluate_audit(gate)
    else
      :allow
    end
  end

  @doc """
  Returns true for the dynamic-tool name used by the GitHub PR-create tool.
  """
  @spec github_create_pull_request_tool?(term()) :: boolean()
  def github_create_pull_request_tool?(tool)
      when tool in ["github_create_pull_request", "github.create_pull_request"],
      do: true

  def github_create_pull_request_tool?(_tool), do: false

  @doc """
  Run the dependency audit configured by the gate.
  """
  @spec audit(gate()) :: {:ok, []} | {:hold, [map()]} | {:error, term()}
  def audit(%{workspace: workspace, audit_module: audit_module} = gate)
      when is_binary(workspace) and is_atom(audit_module) do
    audit_opts =
      [repo_key: gate.repo_key, settings: gate.settings]
      |> maybe_put_option(:base_ref, gate.base_ref)
      |> maybe_put_option(:command_runner, gate.command_runner)

    audit_module.audit(workspace, audit_opts)
  end

  def audit(_gate), do: {:ok, []}

  @doc """
  Returns true when a local workspace no longer exists on disk.

  A workspace removed by cleanup has nothing left to audit, so callers treat it
  as a clean audit rather than a hold. Remote workspaces are never reported
  missing because the audit cannot see them from this host.
  """
  @spec workspace_missing?(term(), String.t() | nil) :: boolean()
  def workspace_missing?(workspace, nil) when is_binary(workspace), do: not File.dir?(workspace)
  def workspace_missing?(_workspace, _worker_host), do: false

  @doc """
  Returns true when the tracker reports the issue in a terminal state.

  Used before any dependency hold moves state, so an issue that already reached
  a terminal state (for example `Done` after its PR merged) is never reopened.
  Lookup failures report false so a hold still applies when the state is unknown.
  """
  @spec issue_terminal?(term()) :: boolean()
  def issue_terminal?(issue), do: issue_terminal?(issue, &Tracker.fetch_issue_states_by_ids/1)

  @spec issue_terminal?(term(), ([String.t()] -> term())) :: boolean()
  def issue_terminal?(%{id: issue_id}, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%{state: state} | _]} when is_binary(state) -> terminal_state?(state)
      _other -> false
    end
  end

  def issue_terminal?(_issue, _issue_state_fetcher), do: false

  @doc """
  Pause the gated issue on a Needs Decision hold and emit the
  `dependency_pending_approval` notification with the audit items as metadata.
  """
  @spec react_to_hold(gate(), [map()]) :: :ok
  def react_to_hold(gate, items) do
    hold_issue(gate, {:hold, items})
    emit_hold_event(gate, items)
    :ok
  end

  @doc """
  Pause the gated issue on a Needs Decision hold and emit the
  `dependency_pending_approval` notification with the audit error inspected.
  """
  @spec react_to_audit_error(gate(), term()) :: :ok
  def react_to_audit_error(gate, error) do
    hold_issue(gate, {:error, error})
    emit_audit_failure_event(gate, error)
    :ok
  end

  @doc """
  Pauses `issue` in its phase on a Needs Decision hold for what the dependency audit found: the
  changes it holds for approval (`{:hold, items}`) or the failure that kept it from running
  (`{:error, reason}`). The `## Decision needed:` comment asks whether to allow the changes or drop
  them; the answer ends the question and the ticket continues in place
  (`SymphonyElixir.Questions`). `repo_key` names the repo the question is recorded under when
  the issue carries none; `opts` go to `DecisionRequest.ask/4` (`:tracker`, `:store`).
  """
  @spec pause(map(), {:hold, [map()]} | {:error, term()}, String.t() | nil, keyword()) :: :ok | {:error, term()}
  def pause(issue, finding, repo_key, opts \\ []) do
    opts = if is_binary(repo_key), do: Keyword.put(opts, :repo_key, repo_key), else: opts
    DecisionRequest.ask(issue, decision_request(issue, finding), opts)
  end

  defp decision_request(issue, finding) do
    label = Map.get(issue, :identifier) || Map.get(issue, :id)

    %{
      title: "Approve the dependency changes on #{label}",
      question: "#{label} adds or changes outside packages that Symphony's package check keeps out until a person approves them. How should it continue?",
      why: finding_why(finding),
      if_unanswered: "#{label} stays where it is and its pull request is not opened.",
      options: [
        %{
          label: "Allow them",
          effect: "you add these package sources to the repository's allowed list in Symphony's settings; the ticket continues and its next run opens the pull request",
          recommended: false
        },
        %{label: "Drop them", effect: "the ticket continues and its next run removes the package changes before it opens the pull request", recommended: true}
      ],
      recommendation_reason: "The ticket can usually do without a new package, and nothing new enters the code without a review."
    }
  end

  # The package names and reasons come from the audit, so their code is said in plain words.
  defp finding_why({:hold, items}) do
    changes = Enum.map_join(items, ", ", &PlainWords.scrub("#{Map.get(&1, :package)} (#{Map.get(&1, :reason)})"))
    "The package check keeps the pull request closed until a person approves these changes: #{changes}."
  end

  defp finding_why({:error, _reason}), do: "The package check could not run, so the pull request waits until a person decides."

  @doc """
  Build the structured failure response that mirrors `Codex.DynamicTool`
  failures so MCP and Codex paths render identically.
  """
  @spec failure_response(String.t(), String.t(), map()) :: map()
  def failure_response(code, message, details) do
    output =
      %{"error" => Map.merge(%{"code" => code, "message" => message}, details)}
      |> Jason.encode!(pretty: true)

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp evaluate_audit(gate) do
    case audit(gate) do
      {:ok, []} ->
        :allow

      {:hold, items} ->
        {:hold, items,
         failure_response(
           "dependency_source_requires_approval",
           "Pull request creation is blocked because dependency changes require approval.",
           %{"dependency_changes" => items}
         )}

      {:error, reason} ->
        {:audit_error, reason,
         failure_response(
           "dependency_audit_failed",
           "Pull request creation is blocked because dependency audit failed.",
           %{"reason" => inspect(reason)}
         )}
    end
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp hold_issue(%{issue: %{id: issue_id} = issue} = gate, finding) when is_binary(issue_id) do
    if issue_terminal?(issue) do
      Logger.info("Skipping dependency hold for terminal issue issue_id=#{issue_id}")
    else
      pause_issue(issue, finding, Map.get(gate, :repo_key))
    end
  end

  defp hold_issue(_gate, _finding), do: :ok

  defp pause_issue(%{id: issue_id} = issue, finding, repo_key) do
    case pause(issue, finding, repo_key) do
      :ok ->
        record_hold_signal(issue, issue_id, repo_key)
        :ok

      {:error, reason} ->
        Logger.warning("Failed to hold dependency issue issue_id=#{issue_id} on a Needs Decision hold: #{inspect(reason)}")
        :ok
    end
  end

  # Best-effort recording of the dependency hold into the ticket's signals ledger (inert; a store
  # failure never changes the hold). Runs only after the hold is set.
  defp record_hold_signal(issue, issue_id, repo_key) do
    TicketSignals.record(Map.get(issue, :repo_key) || repo_key, issue_id, "decision requested", %{
      question: true,
      reason: "dependency_source_requires_approval"
    })
  end

  defp terminal_state?(state) do
    normalized_state = normalize_state(state)

    Enum.any?(Config.settings!().tracker.terminal_states, &(normalize_state(&1) == normalized_state))
  end

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  defp emit_hold_event(%{issue: issue} = gate, items) do
    Notifications.emit_issue_event(
      :dependency_pending_approval,
      issue,
      %{
        repo_key: gate.repo_key,
        state: issue_state(issue),
        reason: "dependency_source_requires_approval",
        metadata: DependencyAudit.approval_metadata(items)
      }
    )
  end

  # The hold pauses the issue in place, so the event names the state it stays in (none without an
  # issue).
  defp issue_state(%{state: state}), do: state
  defp issue_state(_issue), do: nil

  defp emit_audit_failure_event(%{issue: issue} = gate, error) do
    Notifications.emit_issue_event(
      :dependency_pending_approval,
      issue,
      %{
        repo_key: gate.repo_key,
        state: issue_state(issue),
        reason: "dependency_audit_failed",
        metadata: %{audit_error: inspect(error)}
      }
    )
  end
end
