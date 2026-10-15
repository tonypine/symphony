defmodule SymphonyElixir.SelfHeal do
  # The blocked runs one head may spend before a changed failure stops earning a retry: the flow's
  # own bounded retries, the run that files the fix ticket, and a few more once the repair lands.
  @max_head_attempts 5

  @moduledoc """
  The self-heal lane: a flow blocked by tooling or environment repairs itself
  instead of stopping for a person (`docs/design/state-machine.md`, principle 8 and §Guards
  "Self-heal on environment blocks", "Fix-ticket scope", "Repairs iterate on new information").

  The flow that hit the block retries it boundedly itself; once the bound is used up the block
  reaches this module, which:

    * names the broken **component** and the repo that owns its fix — Symphony for orchestration
      and structural causes, the managed project's repo for its own build/test/run setup
      (`scope/3`);
    * waits on the open ticket the run named as already covering the gap (`covered_by`), or
      files **one** fix ticket per broken component — High, or Urgent for an Urgent affected
      ticket (`SymphonyElixir.SelfHeal.Fixer`) — deduplicated: an open fix ticket for the same
      component and the same failure is reused, not filed again, keeping its priority, and the new
      failure is attached to it as evidence; a terminal one, or one for another failure, is not;
    * links the affected ticket to the fix ticket as blocked-by and gives it a `Blocked` hold
      waiting on that ticket, which lifts on its own when the fix goes terminal
      (`SymphonyElixir.BlockedHold`), or, for a fix merged into the repo the running Symphony was
      built from, once the running build includes it — no decision request and no check for a
      person;
    * when a repair has landed and the block recurs, compares the new failure against the last one
      (`compare/2`): a narrowed or otherwise changed failure is progress and earns another attempt,
      and the same failure with no new information escalates to a `Needs Decision` hold, with its
      decision request posted on the ticket. The retries are bounded: a head with
      #{@max_head_attempts} blocked runs escalates however the failure changed, so a run that words
      the same block differently each time cannot loop.

  A block only a person can clear (`needs_person`: a missing secret, an account, a device this host
  lacks) never reaches the filing path: it keeps the access hold it always had, which a person
  lifts.

  Every effect is injectable: `opts[:store]` (the run store), `opts[:tracker]` and `opts[:fixer]`
  (the fix-ticket filer) default to the real ones and are fakes in tests.
  """

  require Logger

  alias SymphonyElixir.{Config, Hold, RunStore, TicketState}
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.Issue

  @default_component "qa_environment"
  @dev_server "dev_server"
  @worker_host "worker_host"
  @playbook "qa_playbook"

  # The components whose fix belongs to the repo that hit the block, rather than to Symphony: its
  # own build/test/run setup. Everything else is structural — orchestration, agent transports, QA
  # coverage — and lands in Symphony (see §Guards "Fix-ticket scope").
  @repo_components [@dev_server]

  @access_type "access"
  @fix_ticket_type "fix_ticket"
  @blocked_hold :blocked
  @needs_decision_hold :needs_decision

  @typedoc "A blocked run's outcome, as `SymphonyElixir.QaVerification` builds it."
  @type outcome :: map()

  @typedoc "What the self-heal lane did with the block."
  @type action :: :filed | :retry | :held | :escalated

  @doc """
  The broken component an outcome names, the unit a fix ticket is filed per. The causes the flows
  raise today map to a small closed set; anything unrecognized is the flow's own environment.
  """
  @spec component(outcome() | term()) :: String.t()
  def component(outcome) when is_map(outcome), do: outcome |> cause() |> component_for()
  def component(_outcome), do: @default_component

  @doc """
  The repo key that owns the fix for `component`, per the design's scope rule: the affected repo
  for its own build/test/run setup, else Symphony's own repo (`opts[:symphony_repo_key]`, default
  the configured primary repo). `nil` when neither can be resolved.
  """
  @spec scope(String.t(), String.t() | nil, keyword()) :: String.t() | nil
  def scope(component, repo_key, opts \\ []) do
    if component in @repo_components, do: repo_key, else: symphony_repo_key(opts)
  end

  @doc """
  The canonical failure string of an outcome, built from fields that stay put when a run rewords
  the same block: the machine's own `cause` when there is one; else the sorted names of the steps
  the run marked `blocked` and the `covered_by` ticket it named; else, when it gave neither, its
  `reason`. Two blocks with the same signature are the same failure and carry no new information.
  """
  @spec signature(outcome() | term()) :: String.t()
  def signature(outcome) when is_map(outcome) do
    case Map.get(outcome, :cause) do
      nil -> stable_signature(outcome) || signature_for(Map.get(outcome, :reason))
      cause -> signature_for(cause)
    end
  end

  def signature(_outcome), do: ""

  @doc """
  How a new failure compares with the last one recorded for the same ticket: `:first` when there is
  no earlier one, `:same` when nothing changed (no new information), `:narrowed` when the new
  failure is contained in the old (progress), and `:changed` otherwise. Narrowed and changed both
  justify another targeted attempt.
  """
  @spec compare(String.t() | nil, String.t()) :: :first | :narrowed | :changed | :same
  def compare(nil, _new), do: :first

  def compare(old, new) when is_binary(old) and is_binary(new) do
    cond do
      new == "" -> :same
      old == new -> :same
      String.contains?(old, new) -> :narrowed
      true -> :changed
    end
  end

  @doc """
  Heals `issue`'s exhausted block: files or reuses the fix ticket, holds the ticket on it, or — for
  a block a person must clear, or one that recurred with no new information — takes the hold that
  pauses it for that person. Returns the action taken, or `{:error, reason}` when nothing could be
  recorded.

  An outcome whose `covered_by` names an open ticket (one that already tracks the missing
  capability) holds the ticket on that ticket instead, even when an earlier failure was recorded:
  it is linked as the blocker and gets the evidence, and no fix ticket is filed.

  A changed failure retries only while the head has fewer than #{@max_head_attempts} blocked runs
  (`:attempts`); past that it escalates like an unchanged one.

  `opts` carries `:outcome` (required), `:attempts` (the retries already spent), `:repo_key`, and
  the injectable `:store`, `:tracker`, `:fixer`, `:symphony_repo_key` and `:terminal_states`
  (default the configured ones).
  """
  @spec heal(Issue.t(), keyword()) :: action() | {:error, term()}
  def heal(%Issue{} = issue, opts) do
    outcome = Keyword.fetch!(opts, :outcome)
    repo_key = repo_key(issue, opts)
    attempts = Keyword.get(opts, :attempts, 0)

    if needs_person?(outcome) do
      access_hold(issue, repo_key, attempts, outcome, opts)
    else
      reconcile(issue, repo_key, attempts, outcome, opts)
    end
  end

  def heal(_issue, _opts), do: {:error, :invalid_issue}

  defp reconcile(issue, repo_key, attempts, outcome, opts) do
    component = component(outcome)
    scope = scope(component, repo_key, opts)

    if is_nil(scope) do
      {:error, {:self_heal_scope_unknown, component}}
    else
      signature = signature(outcome)
      previous = previous(repo_key, issue.id, opts)

      ctx = %{
        issue: issue,
        repo_key: repo_key,
        scope: scope,
        component: component,
        signature: signature,
        attempts: attempts,
        previous: previous,
        outcome: outcome,
        opts: opts
      }

      ctx = Map.put(ctx, :covering, covering_ticket(ctx))

      case {ctx.covering, compare(previous && previous.signature, signature)} do
        {%{}, _change} -> open(ctx)
        {nil, :first} -> open(ctx)
        {nil, :same} -> escalate(ctx, :unchanged)
        {nil, change} -> revisit(ctx, change)
      end
    end
  end

  # No fix ticket for this component yet, or the run named an open ticket that covers the gap: wait
  # on the covering ticket, else reuse the open one another ticket already filed for the same
  # failure (one fix ticket per break, however many tickets hit it), else file it.
  defp open(ctx) do
    case fix_ticket(ctx) do
      {:ok, %{identifier: identifier} = ticket} ->
        record(ctx, %{
          component: ctx.component,
          scope: ctx.scope,
          signature: ctx.signature,
          fix_ticket: identifier,
          attempts: ctx.attempts
        })

        link(ctx, ticket)

        case fix_ticket_hold(ctx, identifier) do
          :ok -> :filed
          {:error, reason} -> {:error, {:self_heal_hold_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:self_heal_fix_ticket_failed, reason}}
    end
  end

  # A repair landed and the block came back different: that is new information, so the flow earns
  # another attempt. The new failure is recorded — so the next identical one escalates — and
  # attached to the fix ticket the repair came from when the record still names one (the lift that
  # cleared that repair's hold dropped the pointer, keeping the signature that proves the change).
  # The attempts are bounded per head: once it has used them up, a changed failure escalates too.
  defp revisit(%{attempts: attempts} = ctx, _change) when attempts >= @max_head_attempts do
    escalate(ctx, :out_of_attempts)
  end

  defp revisit(ctx, change) do
    record(ctx, %{
      component: ctx.component,
      scope: ctx.scope,
      signature: ctx.signature,
      fix_ticket: ctx.previous && ctx.previous.fix_ticket,
      attempts: ctx.attempts
    })

    attach(ctx.previous, ctx.issue, ctx.signature, ctx.outcome, ctx.opts)
    Logger.info("Self-heal for #{label(ctx.issue)}: the #{ctx.component} failure #{change}; retrying")

    :retry
  end

  # The same failure with no new information, or a head that used up its attempts: there is no next
  # step to try, so only here does the machine ask a person, with the decision structured. The
  # decision is posted as a `## Decision needed:` comment next to the hold: the Inbox clears a Needs
  # Decision hold whose request it no longer reads as open (`SymphonyElixir.NeedsDecisionHold`), so
  # a hold with no request would lift on its next read and the ticket would dispatch again. A
  # comment that can't be posted takes the hold back.
  defp escalate(ctx, stuck) do
    decision = decision(ctx, stuck)

    attrs = %{
      reason: "self-heal is stuck on the #{ctx.component} block: #{ctx.signature}",
      clearing_condition: "when the decision is recorded",
      decision: decision
    }

    with {:hold, :ok} <- {:hold, Hold.set(ctx.repo_key, ctx.issue.id, @needs_decision_hold, attrs, hold_opts(ctx.opts))},
         {:post, :ok} <- {:post, tracker(ctx.opts).create_comment(ctx.issue.id, Request.render_hold(decision, ctx.issue.state))} do
      Logger.warning("Self-heal for #{label(ctx.issue)} is stuck on the #{ctx.component} block; Needs Decision set")
      :escalated
    else
      {:hold, {:error, reason}} ->
        {:error, {:self_heal_escalation_failed, reason}}

      {:post, {:error, reason}} ->
        _ = Hold.clear(ctx.repo_key, ctx.issue.id, @needs_decision_hold, hold_opts(ctx.opts))
        {:error, {:self_heal_escalation_request_failed, reason}}
    end
  end

  # The block needs a person to hand something over (a secret, an account, a device this host
  # lacks), so no fix ticket is filed: the access hold pauses the ticket until a person clears it.
  defp access_hold(issue, repo_key, attempts, outcome, opts) do
    attrs = %{
      reason: "QA blocked after #{attempts} attempt(s): #{reason(outcome)}",
      clearing_condition: "when the access a person grants arrives; a person clears this hold",
      waits_on: %{type: @access_type, keys: []}
    }

    case Hold.set(repo_key, issue.id, @blocked_hold, attrs, hold_opts(opts)) do
      :ok ->
        Logger.warning("QA for #{label(issue)} is blocked and needs a person: #{attrs.reason}")
        :held

      {:error, reason} ->
        {:error, {:self_heal_hold_failed, reason}}
    end
  end

  defp fix_ticket(ctx) do
    case ctx.covering || find_open_fix_ticket(ctx) do
      %{identifier: identifier} = ticket ->
        attach(%{fix_ticket: identifier}, ctx.issue, ctx.signature, ctx.outcome, ctx.opts)
        {:ok, ticket}

      nil ->
        fixer(ctx.opts).create(
          %{
            scope: ctx.scope,
            issue: ctx.issue,
            repo_key: ctx.repo_key,
            component: ctx.component,
            title: fix_title(ctx.component),
            description: fix_description(ctx.issue, ctx.component, ctx.signature, ctx.outcome)
          },
          ctx.opts
        )
    end
  end

  # The open ticket the blocked run named as already tracking the missing capability (`covered_by`,
  # say a ticket the acceptance gate filed for the same QA tools): the ticket waits on that one
  # instead of a new fix ticket for the same gap. A ticket that is terminal, unreadable, or the
  # affected ticket itself covers nothing, and the lane files or reuses its own fix ticket.
  defp covering_ticket(%{outcome: %{covered_by: identifier}} = ctx) when is_binary(identifier) do
    case tracker(ctx.opts).fetch_issue_by_identifier(identifier) do
      {:ok, %Issue{id: id, state: state}} when id != ctx.issue.id ->
        if terminal?(state, ctx.opts), do: nil, else: %{identifier: identifier}

      _other ->
        Logger.info("Self-heal for #{label(ctx.issue)} cannot wait on #{identifier}: it is not an open ticket of its own")
        nil
    end
  end

  defp covering_ticket(_ctx), do: nil

  # The open fix ticket for this same failure, whichever affected ticket filed it. The fix tickets
  # are found through the tickets' own self-heal records, so no second index is kept. A record is
  # reused only when its failure (`signature/1`) is the new one and its fix ticket is still open:
  # a fix ticket for another failure of the same component, or one already terminal or unreadable,
  # would hold the ticket on a gap it does not track, so a new fix ticket is filed instead.
  defp find_open_fix_ticket(ctx) do
    %{component: component, scope: scope, signature: signature} = ctx

    ctx.opts
    |> ticket_states()
    |> Enum.find_value(fn record ->
      case TicketState.self_heal(record) do
        %{component: ^component, scope: ^scope, signature: ^signature, fix_ticket: identifier}
        when is_binary(identifier) ->
          open_fix_ticket(identifier, ctx)

        _none ->
          nil
      end
    end)
  end

  defp open_fix_ticket(identifier, ctx) do
    case tracker(ctx.opts).fetch_issue_by_identifier(identifier) do
      {:ok, %Issue{state: state}} ->
        if terminal?(state, ctx.opts), do: nil, else: %{identifier: identifier}

      _other ->
        Logger.info("Self-heal for #{label(ctx.issue)} cannot reuse fix ticket #{identifier}: it could not be read")
        nil
    end
  end

  defp ticket_states(opts) do
    case store(opts).list_all_ticket_states() do
      {:error, reason} ->
        Logger.warning("Self-heal could not read the ticket states to deduplicate a fix ticket: #{inspect(reason)}")
        []

      states when is_list(states) ->
        states
    end
  end

  defp record(ctx, attrs) do
    case store(ctx.opts).record_ticket_self_heal(ctx.repo_key, ctx.issue.id, attrs) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Self-heal could not record its bookkeeping for #{label(ctx.issue)}: #{inspect(reason)}")
    end
  end

  # Best-effort: a missing blocked-by link never stops the hold, which is what actually pauses the
  # ticket and clears when the fix lands.
  defp link(ctx, ticket) do
    case fixer(ctx.opts).block(ctx.issue, ticket, ctx.opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Self-heal could not link #{label(ctx.issue)} to fix ticket #{ticket.identifier}: #{inspect(reason)}")
        :ok
    end
  end

  defp attach(%{fix_ticket: identifier}, issue, signature, outcome, opts) when is_binary(identifier) do
    case fixer(opts).attach(identifier, evidence(issue, signature, outcome), opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Self-heal could not attach the failure evidence to fix ticket #{identifier}: #{inspect(reason)}")
        :ok
    end
  end

  defp attach(_previous, _issue, _signature, _outcome, _opts), do: :ok

  defp fix_ticket_hold(ctx, identifier) do
    attrs = %{
      reason: "waiting on fix ticket #{identifier} for the #{ctx.component} block: #{ctx.signature}",
      clearing_condition: "when the fix ticket #{identifier} is terminal",
      waits_on: %{type: @fix_ticket_type, keys: [identifier]}
    }

    case Hold.set(ctx.repo_key, ctx.issue.id, @blocked_hold, attrs, hold_opts(ctx.opts)) do
      :ok ->
        Logger.warning("Self-heal holds #{label(ctx.issue)} on #{identifier} for its #{ctx.component} block; the ticket is Blocked")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp previous(repo_key, issue_id, opts) do
    repo_key
    |> get_ticket_state(issue_id, opts)
    |> TicketState.self_heal()
  end

  defp get_ticket_state(repo_key, issue_id, opts) do
    case store(opts).get_ticket_state(repo_key, issue_id) do
      {:error, _reason} -> TicketState.normalize(nil)
      record -> record
    end
  end

  defp evidence(issue, signature, outcome) do
    """
    Symphony's self-heal lane recorded this from #{label(issue)}: the run is blocked by its environment.

    - Failure: `#{signature}`
    - Reason: #{reason(outcome)}
    #{findings(outcome)}
    """
  end

  defp fix_title(component), do: "Self-heal: repair the #{component} block"

  defp fix_description(issue, component, signature, outcome) do
    """
    #{evidence(issue, signature, outcome)}
    This is the #{component} component, so the fix belongs to the repo that owns it. Repair it, and every ticket blocked on this one resumes on its own when this ticket goes terminal — no person has to move anything.
    """
  end

  defp findings(%{findings: findings}) when is_list(findings) do
    case Enum.filter(findings, &is_binary/1) do
      [] -> ""
      lines -> "- Findings:\n" <> Enum.map_join(lines, "\n", &"  - #{&1}") <> "\n"
    end
  end

  defp findings(_outcome), do: ""

  defp decision(ctx, stuck) do
    %{
      title: "Self-heal is stuck on the #{ctx.component} block",
      question: question(ctx, stuck),
      why: why(stuck),
      options: [
        %{
          label: "Investigate the #{ctx.component} by hand",
          effect: "the block is cleared by hand and the ticket resumes in its phase",
          recommended: true
        },
        %{
          label: "Drop the check this block comes from",
          effect: "the check is removed from the flow and the ticket goes on without it"
        }
      ],
      asked_at: DateTime.utc_now()
    }
  end

  defp question(ctx, :unchanged) do
    "The #{ctx.component} block on #{label(ctx.issue)} came back unchanged after #{ctx.attempts} " <>
      "attempt(s) and its fix ticket landed: #{ctx.signature}. How should it be handled?"
  end

  defp question(ctx, :out_of_attempts) do
    "The #{ctx.component} block on #{label(ctx.issue)} kept coming back over #{ctx.attempts} blocked runs " <>
      "of the same change: #{ctx.signature}. How should it be handled?"
  end

  defp why(:unchanged),
    do: "Self-heal retries a changed failure on its own, but this one carries no new information, so there is no next step for the machine to try."

  defp why(:out_of_attempts),
    do: "Self-heal retries a changed failure on its own, but only #{@max_head_attempts} times for one change, so the machine stops retrying it."

  defp cause(outcome) do
    Map.get(outcome, :cause) || Map.get(outcome, :reason)
  end

  defp component_for({:qa_dev_server_failed, cause}), do: component_for(cause)
  defp component_for({:verification_failed, cause}), do: component_for(cause)
  defp component_for({:dev_server_exit, _status}), do: @dev_server
  defp component_for({:dev_server_build_failed, _status}), do: @dev_server
  defp component_for({:dev_server_not_on_socket, _socket}), do: @dev_server
  defp component_for({:dev_server_not_configured}), do: @dev_server
  defp component_for(:health_timeout), do: @dev_server
  defp component_for({:remote_worker_unsupported, _host}), do: @worker_host
  defp component_for(reason) when is_binary(reason), do: binary_component(reason)
  defp component_for(_cause), do: @default_component

  defp binary_component(reason) do
    cond do
      String.contains?(reason, "no QA playbook") -> @playbook
      String.contains?(reason, "remote worker") -> @worker_host
      true -> @default_component
    end
  end

  # The steps the run could not take and the ticket it named as covering the gap: the parts of a
  # blocked verdict that stay the same when the run words its reason differently. `nil` when the
  # outcome has neither.
  defp stable_signature(outcome) do
    steps =
      for %{status: "blocked", name: name} when is_binary(name) <- List.wrap(Map.get(outcome, :steps)),
          step = normalize(name),
          step != "",
          uniq: true,
          do: step

    parts =
      [
        steps != [] && "blocked steps: " <> (steps |> Enum.sort() |> Enum.join(", ")),
        is_binary(Map.get(outcome, :covered_by)) && "covered by: " <> Map.get(outcome, :covered_by)
      ]
      |> Enum.filter(&is_binary/1)

    if parts != [], do: Enum.join(parts, "; ")
  end

  defp signature_for(cause) when is_binary(cause), do: normalize(cause)
  defp signature_for(nil), do: ""
  defp signature_for(cause), do: cause |> inspect() |> normalize()

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.replace(~r/\s+/, " ")

  defp terminal?(state, opts) when is_binary(state) do
    normalized = normalize_state(state)
    opts |> terminal_states() |> Enum.any?(&(normalize_state(&1) == normalized))
  end

  defp terminal?(_state, _opts), do: false

  defp terminal_states(opts), do: Keyword.get_lazy(opts, :terminal_states, fn -> Config.settings!().tracker.terminal_states end)

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  defp needs_person?(%{needs_person: true}), do: true
  defp needs_person?(_outcome), do: false

  defp reason(%{findings: [first | _]}) when is_binary(first), do: first
  defp reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp reason(_outcome), do: "the run could not verify the change"

  defp label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp label(%Issue{id: id}), do: inspect(id)

  defp repo_key(%Issue{repo_key: repo_key}, opts), do: Keyword.get(opts, :repo_key) || repo_key

  defp symphony_repo_key(opts) do
    case Keyword.fetch(opts, :symphony_repo_key) do
      {:ok, repo_key} -> repo_key
      :error -> Config.repo_key_or_nil()
    end
  end

  defp hold_opts(opts), do: Keyword.take(opts, [:store, :tracker])

  defp store(opts), do: Keyword.get(opts, :store, RunStore)

  defp tracker(opts), do: Keyword.get(opts, :tracker, SymphonyElixir.Tracker)

  defp fixer(opts), do: Keyword.get(opts, :fixer, SymphonyElixir.SelfHeal.Fixer)
end
