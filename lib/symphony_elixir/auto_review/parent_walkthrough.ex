defmodule SymphonyElixir.AutoReview.ParentWalkthrough do
  @moduledoc """
  The QA-only run a parent's `Final verification:` sub-ticket gets when Auto Review is on.

  Once the other sub-tickets have merged, the verification ticket needs no executor agent and no
  PR. Symphony runs `SymphonyElixir.QaAgent` in a throwaway worktree at the head of the base
  branch (`origin/main` by default), with the parent as the issue under test: the agent walks the
  parent's acceptance criteria and user walkthrough plus the verification ticket's checklist, and
  its evidence attachments land on the parent. There is no fix loop:

  - the `## Symphony QA Report` is written on the parent and on the verification ticket;
  - `pass` (or `blocked` with no failing step) moves the verification ticket to `In Review` for a
    human to sign off, or to the Human Review state (`SymphonyElixir.HumanReview`) when the QA agent
    says only a person can do the steps left (`needs_person`);
  - `fail` (or `blocked` with a failing step, such as the macOS app part blocked while a CLI check
    failed) files each failing step (or, without failing steps, each finding) as a Backlog child of
    the verification ticket that names the step and holds its details and evidence, marks the
    verification ticket blocked by each one, and leaves it in `Todo`, as for any gap a final
    verification finds. Symphony's blocked-by gate holds it there and dispatches it again once every
    gap is terminal. When a gap could not be filed or linked, the ticket goes to `Backlog` for a
    human instead, since nothing would hold it.

  A `blocked` verdict also puts the ticket in the parent project's human-action update (see
  `SymphonyElixir.HumanActions.Collector`), since only a person can provide what QA was missing.

  A QA agent that runs into the provider's usage limit gets no verdict: no report is written, the
  ticket keeps its state, and `run/3` returns `{:error, {:usage_limited, info}}`, so the
  orchestrator holds the run and starts it again once the limit resets, as for any agent run.

  Each Linear call waits out a rate limit or a dropped connection
  (`SymphonyElixir.Linear.TransientRetry`) instead of failing the run; the verdict is kept while the
  final state move waits, for up to 30 minutes rather than the default five, so a finished QA pass is
  not thrown away.

  Playbooks come from `qa:<kind>` labels on the verification ticket or the parent; without one,
  every enabled playbook is offered, since there is no diff to select from.

  The executor run (`Parent tickets` in `WORKFLOW.md`) is used instead when Auto Review is off,
  the tracker is not Linear, the run is on a remote worker, the ticket has the `qa:skip` label, or
  it has no parent.
  """

  require Logger

  alias SymphonyElixir.{AgentTools, AutoReview, Config, HumanReview, QaAgent, RunKind, Tracker, Verification, Workspace}
  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.{Issue, TransientRetry}
  alias SymphonyElixir.QaAgent.{Report, Selection}

  @review_state "In Review"
  @gap_state "Todo"
  @unlinked_gap_state "Backlog"
  @skip_label "qa:skip"
  @label_prefix "qa:"
  @title_limit 120
  @details_limit 4_000
  # Longer than the QA run a lost verdict would redo, so a rate limit that outlasts the default
  # five-minute wait does not throw the verdict away.
  @verdict_move_max_wait_ms 30 * 60_000

  @doc """
  Runs the parent walkthrough for `issue` in its `workspace` when it applies, applies the outcome
  and returns `:ok`. Returns `:skip` when the ticket should get the executor run instead, and
  `{:error, reason}` when the parent could not be read or the ticket could not be moved, and
  `{:error, {:usage_limited, info}}` when the QA agent hit the provider's usage limit.

  Options: `:settings` (required), `:repo_key`, `:run_id`, `:worker_host`, `:on_message`
  (forwarded agent messages), `:linear_retry_opts` (`TransientRetry.run/2` options), and
  `:tracker`, `:qa_agent`, `:git`, `:linear_client` for tests.
  """
  @spec run(Issue.t(), Path.t(), keyword()) :: :ok | :skip | {:error, term()}
  def run(%Issue{} = issue, workspace, opts) do
    settings = Keyword.fetch!(opts, :settings)

    if RunKind.classify(issue) == :final_verification do
      case walkthrough_parent(issue, settings, opts) do
        {:ok, %Issue{} = parent} ->
          run_walkthrough(issue, parent, workspace, settings, opts)

        {:skip, reason} ->
          Logger.info("Final verification gets the executor run for #{issue.identifier}: #{reason}")
          :skip

        {:error, reason} ->
          {:error, {:parent_walkthrough_failed, reason}}
      end
    else
      :skip
    end
  end

  defp walkthrough_parent(issue, %Schema{} = settings, opts) do
    cond do
      not AutoReview.enabled?(settings) -> {:skip, "Auto Review is off"}
      settings.tracker.kind != "linear" -> {:skip, "the parent walkthrough needs the Linear tracker"}
      is_binary(Keyword.get(opts, :worker_host)) -> {:skip, "QA does not run on remote workers yet"}
      @skip_label in labels(issue) -> {:skip, "the ticket has the `qa:skip` label"}
      true -> fetch_parent(issue, opts)
    end
  end

  defp fetch_parent(issue, opts) do
    read_parent = fn -> AgentTools.Linear.get_parent_issue(%{issue: issue}, linear_opts(opts)) end

    case with_linear_retry(read_parent, "reading the parent of #{issue.identifier}", opts) do
      {:ok, %{"identifier" => identifier}} when is_binary(identifier) ->
        fetch = fn -> Keyword.get(opts, :tracker, Tracker).fetch_issue_by_identifier(identifier) end
        with_linear_retry(fetch, "reading the parent #{identifier}", opts)

      {:ok, _no_parent} ->
        {:skip, "the ticket has no parent"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_walkthrough(issue, parent, workspace, settings, opts) do
    branch = AutoReview.base_branch(Keyword.get(opts, :repo_key))
    base_ref = "origin/" <> branch

    outcome =
      case base_commit(workspace, branch, Keyword.get(opts, :git, &default_git/2)) do
        {:ok, sha} ->
          run_agent(issue, parent, workspace, %{sha: sha, base_ref: base_ref}, settings, opts)

        {:error, reason} ->
          %{verdict: :blocked, sha: nil, reason: "could not read the head of #{base_ref}: #{inspect(reason)}"}
      end

    case outcome do
      %{usage_limit: info} ->
        Logger.info("Parent walkthrough for #{parent.identifier} hit the usage limit; #{issue.identifier} keeps its state and runs again once the hold lifts")
        {:error, {:usage_limited, info}}

      _outcome ->
        apply_outcome(issue, parent, Map.put(outcome, :ref, base_ref), settings, opts)
    end
  end

  defp base_commit(workspace, branch, git) do
    with {_output, 0} <- git.(["fetch", "--quiet", "origin", branch], workspace),
         {sha, 0} <- git.(["rev-parse", "--verify", "refs/remotes/origin/#{branch}^{commit}"], workspace) do
      {:ok, String.trim(sha)}
    else
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  end

  defp run_agent(issue, parent, workspace, %{sha: sha, base_ref: base_ref}, settings, opts) do
    started_at = System.monotonic_time(:second)
    playbooks = playbooks(issue, parent, settings)

    job = %{
      issue: parent,
      verification_issue: issue,
      base_ref: base_ref,
      sha: sha,
      workspace_path: workspace,
      repo_key: Keyword.get(opts, :repo_key),
      run_id: Keyword.get(opts, :run_id),
      playbooks: playbooks,
      token_limit: settings.agent.max_tokens_per_issue,
      run_profile: Config.qa_profile(settings)
    }

    agent_opts = Keyword.take(opts, [:git, :linear_client, :on_message])

    outcome =
      case Keyword.get(opts, :qa_agent, QaAgent).run(job, settings, agent_opts) do
        {:ok, %{result: result, tokens: tokens}} -> Map.put(result, :tokens, tokens)
        {:error, reason, tokens} -> error_outcome(reason, tokens)
      end

    Map.merge(outcome, %{
      sha: sha,
      playbooks: Enum.map(playbooks, & &1.kind),
      runtime_seconds: System.monotonic_time(:second) - started_at
    })
  end

  defp error_outcome(reason, tokens) do
    case AutoReview.usage_limit(reason) do
      %{} = info -> %{usage_limit: info}
      nil -> %{verdict: :blocked, reason: AutoReview.blocked_reason(reason), tokens: tokens}
    end
  end

  defp playbooks(issue, parent, settings) do
    playbooks = Selection.playbooks(settings.auto_review, dev_server?: Verification.dev_server_configured?(settings))
    labels = labels(issue) ++ labels(parent)

    case Enum.filter(playbooks, &((@label_prefix <> &1.kind) in labels)) do
      [] -> playbooks
      labelled -> labelled
    end
  end

  defp labels(issue), do: issue |> Issue.label_names() |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

  defp apply_outcome(issue, parent, outcome, settings, opts) do
    {target_state, filed} =
      case outcome.verdict do
        :fail -> fail_target(file_failures(issue, parent, outcome, opts))
        :blocked -> blocked_target(issue, parent, outcome, settings, opts)
        _verdict -> {review_target(outcome, settings), []}
      end

    report =
      outcome
      |> Map.merge(%{target_state: target_state, target_issue: issue.identifier, filed: filed})
      |> Report.render()

    Enum.each([parent, issue], &publish(&1, report, settings, opts))
    move = fn -> Keyword.get(opts, :tracker, Tracker).update_issue_state(issue.id, target_state) end
    move_label = "moving #{issue.identifier} to #{target_state} after the parent walkthrough"

    case with_linear_retry(move, move_label, verdict_move_opts(opts)) do
      :ok ->
        Logger.info("Parent walkthrough for #{parent.identifier} ended #{outcome.verdict}; moved #{issue.identifier} to #{target_state}")
        :ok

      {:error, reason} ->
        {:error, {:parent_walkthrough_state_update_failed, target_state, reason}}
    end
  end

  # Only gaps that block the ticket bring it back; without them it would start again at once.
  defp fail_target(filed) do
    if filed != [] and Enum.all?(filed, & &1.linked?),
      do: {@gap_state, filed},
      else: {@unlinked_gap_state, filed}
  end

  # A blocked playbook (the macOS app without its grants) does not hide the other playbooks'
  # failing steps: they are filed as gaps, as for `fail`. Without one, a human takes over.
  defp blocked_target(issue, parent, outcome, settings, opts) do
    if Enum.any?(Map.get(outcome, :steps, []), &(&1.status == "fail")),
      do: fail_target(file_failures(issue, parent, outcome, opts)),
      else: {review_target(outcome, settings), []}
  end

  # Steps only a person can do (a secret, a check on a device) leave the sign-off with that person.
  defp review_target(%{needs_person: true}, settings), do: HumanReview.target_state(settings)
  defp review_target(_outcome, _settings), do: @review_state

  defp publish(target, report, settings, opts) do
    post = fn -> Report.publish(target, report, Keyword.put(linear_opts(opts), :settings, settings)) end

    case with_linear_retry(post, "publishing the parent walkthrough QA report on #{target.identifier}", opts) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to publish the parent walkthrough QA report on #{target.identifier}: #{inspect(reason)}")
    end
  end

  # Children of the verification ticket that block it, like the gaps an executor final verification files.
  defp file_failures(issue, parent, outcome, opts) do
    {:ok, registry} = CommentRegistry.start_link()
    context = %{issue: issue, comment_registry: registry}

    try do
      outcome
      |> failure_tickets(%{issue: issue, parent: parent, outcome: outcome})
      |> Enum.flat_map(fn {title, description} ->
        attrs = %{"title" => title, "description" => description}
        create = fn -> AgentTools.Linear.create_subissue(context, attrs, linear_opts(opts)) end

        case with_linear_retry(create, "filing a parent walkthrough finding for #{issue.identifier}", opts) do
          {:ok, response} ->
            identifier = get_in(response, ["data", "issueCreate", "issue", "identifier"])
            [%{identifier: identifier, title: title, linked?: link_gap(context, issue, identifier, opts)}]

          {:error, reason} ->
            Logger.warning("Failed to file a parent walkthrough finding for #{issue.identifier}: #{inspect(reason)}")
            []
        end
      end)
    after
      Agent.stop(registry)
    end
  end

  defp link_gap(context, issue, identifier, opts) do
    link = fn -> AgentTools.Linear.add_blocked_by(context, %{"blocked_by" => [identifier]}, linear_opts(opts)) end

    case with_linear_retry(link, "marking #{issue.identifier} blocked by #{identifier}", opts) do
      {:ok, _response} ->
        true

      {:error, reason} ->
        Logger.warning("Failed to mark #{issue.identifier} blocked by #{identifier}: #{inspect(reason)}")
        false
    end
  end

  defp failure_tickets(outcome, ctx) do
    case Enum.filter(Map.get(outcome, :steps, []), &(&1.status == "fail")) do
      [] -> Enum.map(Map.get(outcome, :findings, []), &finding_ticket(&1, ctx))
      failed -> Enum.map(failed, &step_ticket(&1, ctx))
    end
  end

  defp step_ticket(step, ctx) do
    body = """
    #{ticket_intro(ctx)}

    ## Failing step

    #{step.name}

    ```text
    #{fence_safe(step.details)}
    ```

    ## Evidence

    #{evidence_list(step.evidence)}

    ## Acceptance criteria

    - [ ] The step "#{step.name}" behaves as #{ctx.parent.identifier} describes on the default branch.
    - [ ] The parent walkthrough passes this step when #{ctx.issue.identifier} runs again.
    """

    {title("Parent walkthrough fails: " <> step.name), body}
  end

  defp finding_ticket(finding, ctx) do
    body = """
    #{ticket_intro(ctx)}

    ## Finding

    #{finding}

    ## Evidence

    #{ctx.outcome |> Map.get(:steps, []) |> Enum.flat_map(& &1.evidence) |> evidence_list()}

    ## Acceptance criteria

    - [ ] The finding above is fixed on the default branch.
    - [ ] The parent walkthrough passes when #{ctx.issue.identifier} runs again.
    """

    {title("Parent walkthrough finding: " <> first_line(finding)), body}
  end

  defp ticket_intro(%{issue: issue, parent: parent, outcome: outcome}) do
    "The Auto Review parent walkthrough of #{parent.identifier}#{url_suffix(parent)}, run by the final " <>
      "verification ticket #{issue.identifier}, failed on commit `#{String.slice(outcome.sha, 0, 12)}` " <>
      "(head of `#{outcome.ref}`). The full QA report is on #{parent.identifier}."
  end

  defp url_suffix(%Issue{url: url}) when is_binary(url), do: " (#{url})"
  defp url_suffix(_issue), do: ""

  defp evidence_list([]), do: "The QA agent recorded no evidence for this; see the step details."
  defp evidence_list(links), do: Enum.map_join(links, "\n", &("- " <> &1))

  defp fence_safe(text) do
    text = String.replace(text, "```", "'''")
    if byte_size(text) > @details_limit, do: binary_part(text, 0, @details_limit) <> "\n[... truncated ...]", else: text
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp title(text), do: text |> String.slice(0, @title_limit) |> String.trim()

  defp linear_opts(opts), do: Keyword.take(opts, [:linear_client])

  # A caller's own `:max_wait_ms` still wins.
  defp verdict_move_opts(opts) do
    Keyword.update(
      opts,
      :linear_retry_opts,
      [max_wait_ms: @verdict_move_max_wait_ms],
      &Keyword.put_new(&1, :max_wait_ms, @verdict_move_max_wait_ms)
    )
  end

  defp with_linear_retry(fun, label, opts) do
    TransientRetry.run(fun, opts |> Keyword.get(:linear_retry_opts, []) |> Keyword.put(:label, label))
  end

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)
end
