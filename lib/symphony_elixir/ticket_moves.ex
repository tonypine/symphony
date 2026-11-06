defmodule SymphonyElixir.TicketMoves do
  @moduledoc """
  What the Director may do with a ticket now, and why not: the one guard behind every ticket move of
  the control API (`POST /api/v1/control/<move>`) and the `moves` of the ticket read. Fact 5 of
  `docs/design/director-ticket-page.md`; `docs/control-api.md` documents the shape.

  `check/2` judges one move on a ticket's facts and answers with the reason in the words the app
  shows. A control call refuses with that reason, and `read/1` carries it, so a button is never
  clickable into a refusal. `facts/2` builds the facts from the ticket's record and what the caller
  knows live, without reading Linear; `issue_facts/1` builds them from a ticket a call read.

  What a call refuses on its argument (a phase the repository doesn't name, a blocker that would make
  a cycle, a label already on) is not a fact of the ticket, so it stays the call's own.
  """

  alias SymphonyElixir.{Config, DirectorMoves, IdlePark, PlanReview, Questions, StartNow, SubIssueWait, TicketState}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrWatch.Competitors

  @moves [
    :answer,
    :start,
    :stop,
    :restart,
    :cancel,
    :move_to,
    :force,
    :unforce,
    :unblock,
    :note,
    :blocker,
    :priority,
    :labels,
    :ruling,
    :approve_plan,
    :rework,
    :decisions,
    :changes,
    :backlog
  ]
  @start_facts [:phase, :symphony_pause, :repository_pause, :open_question?, :running?]
  @untracked "The ticket is not one Symphony tracks."
  @no_run "No run is working."
  @backlog "backlog"

  @type move ::
          :answer
          | :start
          | :stop
          | :restart
          | :cancel
          | :move_to
          | :force
          | :unforce
          | :unblock
          | :note
          | :blocker
          | :priority
          | :labels
          | :ruling
          | :approve_plan
          | :rework
          | :decisions
          | :changes
          | :backlog

  @typedoc """
  What a move is judged on. `recorded?` says Symphony holds a record of the ticket, `tracked?` that
  the record is not of a ticket removed in Linear, and `unblockable?` that the ticket has something
  the Director's Unblock releases.
  """
  @type facts :: %{
          identifier: String.t() | nil,
          repo_key: String.t() | nil,
          phase: String.t() | nil,
          recorded?: boolean(),
          tracked?: boolean(),
          labels: [String.t()],
          symphony_pause: String.t() | nil,
          repository_pause: String.t() | nil,
          open_question?: boolean(),
          running?: boolean(),
          unblockable?: boolean()
        }

  @typedoc "What only the caller of `facts/2` knows: which ticket it is, the pauses over it and whether a run works on it."
  @type live :: %{
          identifier: String.t() | nil,
          repo_key: String.t() | nil,
          symphony_pause: String.t() | nil,
          repository_pause: String.t() | nil,
          running?: boolean()
        }

  @type entry :: %{
          required(:allowed) => boolean(),
          required(:reason) => String.t() | nil,
          optional(:states) => [String.t()]
        }

  @doc "The moves `read/1` carries, each as `check/2` names it."
  @spec moves() :: [move()]
  def moves, do: @moves

  @doc "The facts of a ticket from its record (nil when Symphony holds none) and what the caller knows live."
  @spec facts(map() | nil, live()) :: facts()
  def facts(record, %{} = live) do
    questions = record_field(record, :questions, [])

    Map.merge(live, %{
      phase: record_field(record, :phase, nil),
      recorded?: is_map(record),
      tracked?: is_map(record) and is_nil(record_field(record, :removed_at, nil)),
      labels: record_field(record, :labels, []),
      open_question?: Enum.any?(questions, &(&1.state == :open)),
      unblockable?: is_map(record) and record_unblockable?(record, questions)
    })
  end

  @doc """
  The facts of a ticket a control call read: its phase and labels are the ones read. What a call's
  guard doesn't ask reads as nothing holding the ticket.
  """
  @spec issue_facts(Issue.t()) :: facts()
  def issue_facts(%Issue{} = issue) do
    %{
      identifier: issue.identifier,
      repo_key: issue.repo_key,
      phase: issue.state,
      recorded?: true,
      tracked?: true,
      labels: List.wrap(issue.labels),
      symphony_pause: nil,
      repository_pause: nil,
      open_question?: false,
      running?: false,
      unblockable?: false
    }
  end

  @doc "Whether Unblock has something to release: a held question, a wait on competing pull requests, or a reason the Director may release."
  @spec unblockable?([map()], boolean()) :: boolean()
  def unblockable?(reasons, held?) when is_list(reasons) and is_boolean(held?) do
    held? or Enum.any?(reasons, &(&1.releasable == true or Competitors.landing_reason?(&1)))
  end

  @doc "The `moves` of the ticket read: each move with whether it is allowed and, when it is not, why."
  @spec read(facts()) :: %{move() => entry()}
  def read(%{} = facts), do: Map.new(@moves, &{&1, entry(&1, facts)})

  @doc "Whether `move` may be made on a ticket with these facts: `:ok`, or the reason in the app's words."
  @spec check(move(), facts()) :: :ok | {:error, String.t()}
  def check(:answer, %{open_question?: true}), do: :ok
  def check(:answer, facts), do: {:error, "#{facts.identifier} is not waiting on a decision"}

  def check(:start, facts) do
    with :ok <- facts |> Map.take(@start_facts) |> StartNow.check() do
      if is_binary(facts.repo_key), do: :ok, else: {:error, StartNow.no_repository_reason()}
    end
  end

  def check(:stop, %{running?: true}), do: :ok
  def check(:stop, _facts), do: {:error, @no_run}

  def check(move, facts) when move in [:restart, :cancel], do: require_open(facts)

  def check(:move_to, %{repo_key: nil} = facts), do: {:error, no_repository_reason(facts.identifier)}
  def check(:move_to, facts), do: require_phase(facts)

  def check(:force, facts) do
    with :ok <- require_open(facts) do
      if forced_label?(facts), do: {:error, "It is already forced."}, else: :ok
    end
  end

  def check(:unforce, facts) do
    with :ok <- require_phase(facts) do
      if forced_label?(facts), do: :ok, else: {:error, "It isn't forced."}
    end
  end

  def check(:unblock, %{unblockable?: true}), do: :ok
  def check(:unblock, facts), do: {:error, "#{facts.identifier} has nothing a person can unblock"}

  def check(:note, %{recorded?: true}), do: :ok
  def check(:note, facts), do: {:error, no_ticket_reason(facts.identifier, facts.repo_key)}

  def check(move, %{tracked?: true}) when move in [:blocker, :priority, :labels, :ruling], do: :ok
  def check(move, facts) when move in [:blocker, :priority, :labels, :ruling], do: {:error, untracked_reason(move, facts.identifier)}

  def check(:approve_plan, facts) do
    settings = Config.settings!()

    with :ok <- require_plan(facts, "approve_plan"),
         :ok <- require_plan_review(facts, settings) do
      if SubIssueWait.enabled?(settings), do: :ok, else: {:error, "the waiting state is turned off, so a plan can't be approved from the app"}
    end
  end

  def check(:rework, facts), do: require_plan_review(facts, Config.settings!())

  def check(move, facts) when move in [:decisions, :changes] do
    with :ok <- require_plan(facts, Atom.to_string(move)), do: require_plan_review(facts, Config.settings!())
  end

  def check(:backlog, facts) do
    with :ok <- require_open(facts) do
      if normalize(facts.phase) == @backlog, do: {:error, "#{facts.identifier} is already in Backlog"}, else: :ok
    end
  end

  @doc "The refusal of a move on a closed ticket: `The ticket is done.`"
  @spec closed_reason(String.t()) :: String.t()
  def closed_reason(phase) when is_binary(phase) do
    case normalize(phase) do
      "canceled" -> "The ticket is cancelled."
      word -> "The ticket is #{word}."
    end
  end

  @doc "The refusal of a move that needs the ticket's repository, on a ticket in none."
  @spec no_repository_reason(String.t() | nil) :: String.t()
  def no_repository_reason(identifier), do: "#{identifier} is in no repository Symphony is configured for, so Symphony doesn't track it"

  @doc "The refusal of a note on a ticket with no record."
  @spec no_ticket_reason(String.t() | nil, String.t() | nil) :: String.t()
  def no_ticket_reason(identifier, repo_key), do: "No ticket #{identifier} in #{repo_key || "any repository"}"

  @doc "The refusal of a move that changes what Symphony holds of a ticket, on one it doesn't track."
  @spec untracked_reason(:blocker | :priority | :labels | :ruling, String.t() | nil) :: String.t()
  def untracked_reason(:blocker, name), do: "Symphony doesn't track #{name}, so it can't be linked as a blocker or be given one."
  def untracked_reason(:priority, name), do: "Symphony doesn't track #{name}, so it can't set its priority."
  def untracked_reason(:labels, name), do: "Symphony doesn't track #{name}, so it can't change its labels."
  def untracked_reason(:ruling, name), do: "Symphony doesn't track #{name}, so it can't record a decision on it."

  defp entry(:move_to, facts) do
    verdict = verdict(:move_to, facts)
    Map.put(verdict, :states, if(verdict.allowed, do: other_phases(facts.phase), else: []))
  end

  defp entry(move, facts), do: verdict(move, facts)

  defp verdict(move, facts) do
    case check(move, facts) do
      :ok -> %{allowed: true, reason: nil}
      {:error, reason} -> %{allowed: false, reason: reason}
    end
  end

  defp other_phases(phase), do: Config.settings!() |> DirectorMoves.phases() |> Enum.reject(&(normalize(&1) == normalize(phase)))

  defp require_phase(%{phase: phase}) when is_binary(phase), do: :ok
  defp require_phase(_facts), do: {:error, @untracked}

  # A ticket Symphony holds that Linear gave no state is open; only a ticket it holds nothing of isn't one it tracks.
  defp require_open(%{phase: nil, recorded?: true}), do: :ok

  defp require_open(facts) do
    with :ok <- require_phase(facts) do
      if closed?(facts.phase), do: {:error, closed_reason(facts.phase)}, else: :ok
    end
  end

  defp closed?(phase), do: Enum.any?(Config.settings!().tracker.terminal_states, &(normalize(&1) == normalize(phase)))

  defp require_plan(facts, move) do
    if Enum.any?(facts.labels, &Issue.breakdown_label?/1), do: :ok, else: {:error, "#{facts.identifier} is not a plan; #{move} is for a plan"}
  end

  # The Director answers a plan a person is reviewing: one in `Plan Review`.
  defp require_plan_review(facts, settings) do
    case PlanReview.state(settings) do
      nil ->
        {:error, "the Plan Review state is turned off, so the Director can't answer #{facts.identifier} from the app"}

      plan_review ->
        if PlanReview.in_state?(facts.phase, settings),
          do: :ok,
          else: {:error, "#{facts.identifier} is #{facts.phase || "in no state"}; the Director answers it only from #{plan_review}"}
    end
  end

  defp forced_label?(facts) do
    force_label = normalize(Config.settings!().agent.force_label)
    Enum.any?(facts.labels, &(normalize(&1) == force_label))
  end

  defp record_unblockable?(record, questions) do
    parked?(record) or unblockable?(pause_reasons(record), Enum.any?(questions, &(&1.state == :open and Questions.held_question?(&1))))
  end

  # A ticket an idle run parked goes back to its phase on Unblock; only Backlog can hold one.
  defp parked?(record), do: normalize(record.phase) == @backlog and IdlePark.parked_from(record.phase, TicketState.signals(record)) != :none

  defp pause_reasons(%{pause: %{reasons: reasons}}), do: reasons
  defp pause_reasons(_record), do: []

  defp record_field(record, field, default) when is_map(record), do: Map.get(record, field) || default
  defp record_field(_record, _field, default), do: default

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: nil
end
