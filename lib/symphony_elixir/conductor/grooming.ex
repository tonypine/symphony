defmodule SymphonyElixir.Conductor.Grooming do
  @moduledoc """
  Grooming: the Conductor's first turn on a ticket (`SymphonyElixir.Conductor`, junction
  `grooming`), before any run works on it. The turn reads what was asked and writes the ticket's
  plan (`SymphonyElixir.TicketPlan`); this module holds what Symphony does around it.

  It is due (`due?/2`) when the run about to start is a ticket's first (an implementation run, or
  the breakdown run of a ticket labelled `plan`), the ticket holds no `plan.written` and no run
  other than the Conductor's ever started or ended on it, and fewer than 2 tries failed. A ticket
  that has a run or a plan is never groomed, so one in flight keeps the behaviour it had.

  Before the turn Symphony records the ask (`record_ask/4`): the ticket's description, word for
  word but for Symphony's own blocks, once. The turn runs in the ticket's workspace
  (`workspace/3`), created as the run's would be, with read-only tools, so it may read the code.

  A plan the turn wrote is recorded as version 1 (`write_plan/4`, `by: grooming`). A `split` is
  carried out once it is written (`split/3`, `SymphonyElixir.Conductor.Tree`): its sub-tickets are
  created, and the ticket waits on them with no run of its own. A first run about to start on a
  ticket whose plan is a split carries the split out again instead (`split_due?/2`), creating only
  what is missing. Where the waiting state is off, a split plan is recorded as a `single` one. A
  ticket labelled `plan` or
  `breakdown` is groomed like any other: once its plan is written the label is taken off
  (`take_over/3`), in the tracker and on the record, so no breakdown run follows.

  A try that wrote no plan and asked nothing (the turn timed out, failed, answered outside the
  schema, or no provider of `runs.conductor` could take it) is counted (`failed/3`), as a status
  note on the ticket that says why, written under the key `grooming.try:<n>`: the notes under that
  key are the count (`tries/1`). After the first the ticket is groomed again at its next dispatch;
  after the second it starts without a plan, as it did before plans, and the note says so. A ticket
  therefore never waits on Grooming.
  """

  require Logger

  alias SymphonyElixir.Conductor.{Answer, Facts, Tree}
  alias SymphonyElixir.{Decisions, IssueSummary, RunStore, TicketEvents, TicketPlan}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixir.{Tracker, Workspace, WorkspaceCleanup}

  @max_tries 2
  # The kinds of a ticket's first run: a breakdown run is the first of a ticket labelled `plan`.
  @first_kinds ["implementation", "breakdown"]
  @try_key "grooming.try:"
  @ask_key "ask.recorded:linear"
  @ask_max 20_000
  @reason "Grooming"

  @doc "How many tries may fail before the ticket starts without a plan."
  @spec max_tries() :: pos_integer()
  def max_tries, do: @max_tries

  @doc """
  Whether Grooming comes before a run of `next_kind` on the ticket whose `events` (oldest first)
  these are: the run is a ticket's first, the ticket has no plan and no run but the Conductor's, and
  fewer than `max_tries/0` tries failed. It also takes what `Facts.read_events/1` read: events that
  could not be read say nothing about the ticket, which may be in flight, so Grooming is not due.
  """
  @spec due?(atom() | String.t(), [Event.t()] | {:ok, [Event.t()]} | {:error, term()}) :: boolean()
  def due?(_next_kind, {:error, _reason}), do: false
  def due?(next_kind, {:ok, events}), do: due?(next_kind, events)

  def due?(next_kind, events) when is_list(events) do
    to_string(next_kind) in @first_kinds and not Enum.any?(events, &(plan?(&1) or worked?(&1))) and tries(events) < @max_tries
  end

  defp plan?(%Event{type: type}), do: type == "plan.written"

  @doc """
  Whether a run of `next_kind` about to start on the ticket whose `events` these are meets a split
  instead: it is a first run, and the ticket's plan is a `split`. Such a ticket gets no run: its
  split is carried out (`split/3`), which leaves it waiting on its sub-tickets.
  """
  @spec split_due?(atom() | String.t(), [Event.t()]) :: boolean()
  def split_due?(next_kind, events) when is_list(events) do
    to_string(next_kind) in @first_kinds and match?(%{shape: "split"}, TicketPlan.current(events))
  end

  defp worked?(%Event{type: type} = event) when type in ["run.started", "run.ended"], do: payload(event, :run_kind) != "conductor"
  defp worked?(_event), do: false

  @doc "How many Grooming tries failed on the ticket whose `events` these are."
  @spec tries([Event.t()]) :: non_neg_integer()
  def tries(events) when is_list(events) do
    Enum.count(events, &(&1.type == "note" and is_binary(&1.idempotency) and String.starts_with?(&1.idempotency, @try_key)))
  end

  @doc """
  Counts a try that wrote no plan, with `why` in plain words, as a status note on `repo_key`'s ticket
  `issue_id`. Answers `:retry` when the ticket is groomed again at its next dispatch, and `:give_up`
  when it starts without a plan: this was the last try, or the count could not be read or written,
  so a ticket never waits on a count that does not grow.
  """
  @spec failed(String.t(), String.t(), String.t()) :: :retry | :give_up
  def failed(repo_key, issue_id, why) when is_binary(why) do
    case Facts.read_events(issue_id) do
      {:ok, events} ->
        count_try(repo_key, issue_id, why, tries(events) + 1)

      {:error, reason} ->
        Logger.warning("Grooming could not read the ticket's events issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(reason)}; no try is counted, and the ticket starts without a plan")
        :give_up
    end
  end

  defp count_try(repo_key, issue_id, why, try) do
    last? = try >= @max_tries

    case TicketEvents.record(repo_key, issue_id, "note", %{text: try_text(why, last?), status: true}, idempotency: "#{@try_key}#{try}") do
      {:ok, _note} when not last? ->
        :retry

      {:ok, _note} ->
        :give_up

      {:error, reason} ->
        Logger.warning("Grooming could not count its try issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(reason)}; the ticket starts without a plan")
        :give_up
    end
  end

  defp try_text(why, false), do: fit("Grooming did not finish: #{why}. Symphony tries once more before the first run.")
  defp try_text(why, true), do: fit("Grooming did not finish, #{@max_tries} times: #{why}. This ticket starts without a plan.")

  defp fit(text), do: String.slice(text, 0, 4_000)

  @doc """
  Records what was asked on `issue`, once: its description (the issue's, else the `record`'s) with
  Symphony's own blocks taken out, or its title when the description is blank, as an `ask.recorded`
  from Linear. Nothing when `events` already hold an ask.
  """
  @spec record_ask(String.t(), Issue.t(), map(), [Event.t()]) :: :ok
  def record_ask(repo_key, %Issue{id: issue_id} = issue, record, events) when is_list(events) do
    with [] <- TicketPlan.ask(events),
         text when is_binary(text) <- ask_text(issue.description || Map.get(record, :description)) || ask_text(issue.title || Map.get(record, :title)),
         {:error, reason} <- TicketPlan.record_ask(repo_key, issue_id, text, idempotency: @ask_key) do
      Logger.warning("Grooming could not record the ask issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(reason)}")
    else
      _recorded_or_none -> :ok
    end
  end

  defp ask_text(text) when is_binary(text) do
    case text |> IssueSummary.strip() |> Decisions.strip() |> String.trim() do
      "" -> nil
      ask -> String.slice(ask, 0, @ask_max)
    end
  end

  defp ask_text(_text), do: nil

  @doc """
  The ticket's workspace, the turn's working directory: created as the run's would be
  (`SymphonyElixir.Workspace.create_for_issue/4`), which the run then reuses. `opts`:
  `worker_host` (a run on another host has no local workspace, and none is made),
  `active_workspace_identifiers` (as the run passes them) and `create_workspace` (the creator).
  """
  @spec workspace(Issue.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def workspace(%Issue{} = issue, repo_key, opts) do
    case Keyword.get(opts, :worker_host) do
      nil ->
        WorkspaceCleanup.await(issue.identifier)
        create = Keyword.get(opts, :create_workspace, &Workspace.create_for_issue/4)
        create.(issue, nil, repo_key, Keyword.take(opts, [:active_workspace_identifiers]))

      worker_host ->
        {:error, {:remote_worker, worker_host}}
    end
  end

  @doc """
  Records the turn's `plan` as the first version of the plan of `issue` (`by: grooming`).
  `{:error, why}`, in plain words, for a plan `SymphonyElixir.TicketPlan.write/4` refuses, and for
  a `split` whose sub-tickets Symphony refuses (`SymphonyElixir.Conductor.Tree.refusal/4`: an
  unmanaged repo, or an `identifier` that is not one of the ticket's sub-tickets). A split is
  carried out after it is recorded (`split/3`); where it can't be (the waiting state is off), the
  plan is recorded as a `single` one. `opts[:repo]` is `Tree.refusal/4`'s; the others are
  `TicketPlan.write/4`'s.
  """
  @spec write_plan(String.t(), Issue.t(), Answer.plan(), keyword()) :: {:ok, Event.t()} | {:error, String.t()}
  def write_plan(repo_key, %Issue{id: issue_id} = issue, plan, opts \\ []) do
    {split_opts, opts} = Keyword.split(opts, [:repo])

    with {:ok, plan} <- shaped(repo_key, issue, plan, split_opts),
         {:ok, event} <- TicketPlan.write(repo_key, issue_id, Map.merge(plan, %{reason: @reason, by: "grooming"}), opts) do
      {:ok, event}
    else
      {:error, {:invalid_plan, reasons}} -> {:error, "its plan was refused: " <> Enum.join(reasons, "; ")}
      {:error, {:refused, why}} -> {:error, "its plan was refused: " <> why}
      {:error, reason} -> {:error, "its plan could not be recorded: #{inspect(reason)}"}
    end
  end

  defp shaped(repo_key, issue, %{shape: "split"} = plan, opts) do
    entries = Map.get(plan, :sub_tickets, [])

    cond do
      not Tree.supported?(repo_key) ->
        Logger.warning(
          "Grooming planned a split issue_id=#{issue.id} issue_identifier=#{issue.identifier} repo_key=#{repo_key} " <>
            "sub_tickets=#{length(entries)}; the waiting state is off, so the ticket goes on as a single one"
        )

        {:ok, plan |> Map.put(:shape, "single") |> Map.delete(:sub_tickets)}

      why = Tree.refusal(entries, repo_key, sub_tickets(issue), opts) ->
        {:error, {:refused, why}}

      true ->
        {:ok, plan}
    end
  end

  defp shaped(_repo_key, _issue, plan, _opts), do: {:ok, plan}

  # The identifiers of the sub-tickets the ticket already has: the issue's, and its record's.
  defp sub_tickets(%Issue{id: issue_id, sub_issues: sub_issues}) do
    recorded =
      case RunStore.get_ticket_state(issue_id) do
        %{sub_issues: recorded} -> recorded
        _none -> []
      end

    for %{identifier: identifier} <- List.wrap(if(is_list(sub_issues), do: sub_issues)) ++ List.wrap(if(is_list(recorded), do: recorded)), uniq: true, do: identifier
  end

  @doc """
  Carries out the `split` plan `issue` holds (`SymphonyElixir.Conductor.Tree.split/3`): one
  sub-ticket per `sub_tickets` entry that names none yet, after which the ticket waits on them and
  no run starts on it. `:ok` once it waits; `{:error, why}` when a step failed, with what was
  created kept on the plan, so the next call creates only what is missing.
  """
  @spec split(String.t(), Issue.t(), keyword()) :: :ok | {:error, String.t()}
  def split(repo_key, %Issue{} = issue, opts \\ []), do: Tree.split(repo_key, issue, opts)

  @doc """
  Takes a groomed `issue` out of the old plan flow: a ticket labelled `plan` or `breakdown` loses
  the label, in the tracker (`opts[:tracker]`, default `SymphonyElixir.Tracker`) and on its record,
  and a status note says so. `:taken_over` then: the run that was dispatched for it was a breakdown
  run, which must not start, and the next dispatch starts its first coding run. `:unchanged` for a
  ticket with no such label.
  """
  @spec take_over(String.t(), Issue.t(), keyword()) :: :taken_over | :unchanged
  def take_over(repo_key, %Issue{id: issue_id, labels: labels} = issue, opts \\ []) do
    if Issue.breakdown?(issue) do
      tracker = Keyword.get(opts, :tracker, Tracker)
      {plan_labels, kept} = Enum.split_with(labels, &(is_binary(&1) and Issue.breakdown_label?(&1)))

      for label <- plan_labels, {:error, reason} <- [tracker.remove_issue_label(issue_id, label)] do
        Logger.warning("Grooming could not take the label off issue_id=#{issue_id} issue_identifier=#{issue.identifier} label=#{label}: #{inspect(reason)}")
      end

      _ = RunStore.update_ticket_state(issue_id, %{labels: kept, updated_at: DateTime.utc_now()})
      text = "Grooming wrote this ticket's plan, so Symphony took the #{Enum.join(plan_labels, " and ")} label off: no separate plan run follows."
      _ = TicketEvents.record(repo_key, issue_id, "note", %{text: text, status: true}, idempotency: "grooming.took_over")
      :taken_over
    else
      :unchanged
    end
  end

  defp payload(%Event{payload: payload}, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
