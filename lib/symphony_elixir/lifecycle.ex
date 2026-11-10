defmodule SymphonyElixir.Lifecycle do
  @moduledoc """
  Where a ticket has been on its way to landing, for the ticket read: the `lifecycle` (the five
  stages with their state, visits, time and tokens, and the ticket's token cap) and the `phase_path`
  (the phases in the order entered, with counts, and the time of each move). Facts 7, 19 and 20 of
  `docs/design/director-ticket-page.md`; `docs/control-api.md` documents both shapes.

  Everything comes from the ticket's ledger (`phase.entered`, `run.started`, `run.ended`), never from
  Linear's state history, and a read writes nothing.

  Rework and CI Fix have no stage of their own: they count as visits of the stage they serve. Rework
  serves Code Review, the stage it hands back to, whichever stage sent it back. CI Fix serves the
  stage it interrupted. Each time the ticket goes into one of them is one more visit, and the move
  back out of CI Fix or Rework into the stage they serve is the same visit going on. A phase outside
  the five (Backlog, Todo, Plan Review) belongs to no stage.

  A run belongs to the stage the ticket was in when the run started, and its tokens and time join the
  stage when it ends. A run that started outside any stage (a first run starts before its move out of
  Todo, a plan run never enters one) counts in Coding, so the stages' tokens always add up to the
  total.

  Code Review, QA and CI Fix go by the names the repository configures for them
  (`issues.states.code_review`, `qa` and `ci_fix`); the other phases' names are fixed.
  """

  alias SymphonyElixir.{CiFix, Config, TicketEvents}
  alias SymphonyElixir.TicketEvents.Event

  @stages [{"coding", "Coding"}, {"code_review", "Code Review"}, {"qa", "QA"}, {"merging", "Merging"}, {"done", "Done"}]
  @rework "rework"
  @fixed_stage_of %{"in progress" => "coding", @rework => "code_review", "merging" => "merging", "done" => "done"}
  @outside_any_stage "coding"

  @type stage :: %{
          id: String.t(),
          name: String.t(),
          state: String.t(),
          visits: non_neg_integer(),
          time_ms: non_neg_integer(),
          agent_time_ms: non_neg_integer(),
          tokens: non_neg_integer()
        }

  @type t :: %{
          lifecycle: %{
            current: String.t() | nil,
            stages: [stage()],
            tokens: %{total: non_neg_integer(), cap: non_neg_integer() | nil}
          },
          phase_path: %{
            current: String.t() | nil,
            phases: [
              %{phase: String.t(), count: pos_integer(), time_ms: non_neg_integer(), first_entered_at: String.t()}
            ],
            moves: [%{from: String.t() | nil, to: String.t(), at: String.t()}]
          }
        }

  @typedoc "What `compute/2` needs beside the ledger."
  @type facts :: %{
          now: DateTime.t(),
          terminal_states: [String.t()],
          token_cap: non_neg_integer() | nil,
          phase_names: %{code_review: String.t() | nil, qa: String.t() | nil, ci_fix: String.t()}
        }

  @doc """
  The lifecycle and the phase path of ticket `issue_id`, from its ledger and the configured token cap
  (`agent.max_tokens_per_issue`), terminal states and phase names. A ledger that cannot be read reads
  as empty.
  """
  @spec read(String.t() | nil, DateTime.t()) :: t()
  def read(issue_id, now \\ DateTime.utc_now()) do
    issue_id
    |> TicketEvents.query(limit: :all)
    |> List.wrap()
    |> compute(facts(now))
  end

  @doc "What `compute/2` and `stage_spans/2` need beside the ledger, from the settings, at `now`."
  @spec facts(DateTime.t()) :: facts()
  def facts(now) do
    settings = Config.settings!()

    %{
      now: now,
      terminal_states: settings.tracker.terminal_states,
      token_cap: settings.agent.max_tokens_per_issue,
      phase_names: %{code_review: settings.tracker.code_review_state, qa: settings.tracker.qa_state, ci_fix: CiFix.state(settings)}
    }
  end

  @doc """
  Each stay of a ticket holding `events` (oldest first) in a phase that counts for a stage: the stage
  and when the stay began and ended, as `compute/2` counts the stages' time (the phase the ticket is
  in runs to `now`; a terminal one takes no time, so it has no span). `SymphonyElixir.Aggregate`'s
  time by stage.
  """
  @spec stage_spans([Event.t() | term()], facts()) :: [%{stage: String.t(), from: DateTime.t(), to: DateTime.t()}]
  def stage_spans(events, %{now: now, terminal_states: terminal_states, phase_names: phase_names}) do
    for %{stage: stage, at: at, time_ms: time_ms} <- moves(events, now, Enum.map(terminal_states, &normalized/1), phases(phase_names)),
        is_binary(stage) and time_ms > 0,
        do: %{stage: stage, from: at, to: DateTime.add(at, time_ms, :millisecond)}
  end

  @doc """
  The lifecycle and the phase path of a ticket holding `events` (oldest first). The phase the ticket
  is in counts its time up to `now`, unless it is a terminal one, which takes no time.
  """
  @spec compute([Event.t() | term()], facts()) :: t()
  def compute(events, %{now: now, terminal_states: terminal_states, token_cap: token_cap, phase_names: phase_names}) do
    moves = moves(events, now, Enum.map(terminal_states, &normalized/1), phases(phase_names))
    runs = runs(events, moves)

    %{lifecycle: lifecycle(moves, runs, token_cap), phase_path: phase_path(moves)}
  end

  # A repository may turn Code Review or QA off with an empty name: then no phase goes by it.
  defp phases(%{code_review: code_review, qa: qa, ci_fix: ci_fix}) do
    named_stages = [{code_review, "code_review"}, {qa, "qa"}]
    stage_of = for {name, stage} <- named_stages, is_binary(name), into: @fixed_stage_of, do: {normalized(name), stage}

    %{stage_of: stage_of, ci_fix: normalized(ci_fix)}
  end

  # Each move into a phase, with the stage it counts for, whether it opens a visit of that stage and
  # how long the ticket stayed. A second event naming the phase the ticket is already in is no move.
  defp moves(events, now, terminal_states, phases) do
    entered = for %Event{type: "phase.entered", payload: %{to: to} = payload, at: %DateTime{} = at} <- events, do: %{to: to, from: Map.get(payload, :from), at: at}
    entered = Enum.dedup_by(entered, & &1.to)
    ends = entered |> Enum.drop(1) |> Enum.map(& &1.at)

    {moves, _last} =
      entered
      |> Enum.zip(ends ++ [nil])
      |> Enum.map_reduce({nil, nil}, fn {move, next_at}, {previous_phase, previous_stage} ->
        phase = normalized(move.to)
        stage = stage_of(phase, previous_stage, phases)

        {%{
           to: move.to,
           from: move.from || previous_phase,
           at: move.at,
           stage: stage,
           opens_visit?: opens_visit?(stage, phase, previous_stage, previous_phase, phases.ci_fix),
           time_ms: time_ms(move.at, next_at || end_of_last(move.at, phase, now, terminal_states))
         }, {move.to, stage}}
      end)

    moves
  end

  # CI Fix serves the stage it interrupted; before any stage it can only be repairing the coding.
  defp stage_of(ci_fix, previous_stage, %{ci_fix: ci_fix}), do: previous_stage || @outside_any_stage
  defp stage_of(phase, _previous_stage, %{stage_of: stage_of}), do: Map.get(stage_of, phase)

  defp opens_visit?(nil, _phase, _previous_stage, _previous_phase, _ci_fix), do: false
  defp opens_visit?(stage, _phase, previous_stage, _previous_phase, _ci_fix) when stage != previous_stage, do: true

  defp opens_visit?(_stage, phase, _previous_stage, previous_phase, ci_fix) when phase in [ci_fix, @rework],
    do: normalized(previous_phase) != ci_fix

  defp opens_visit?(_stage, _phase, _previous_stage, _previous_phase, _ci_fix), do: false

  defp end_of_last(at, phase, now, terminal_states), do: if(phase in terminal_states, do: at, else: now)

  defp time_ms(from, to), do: max(DateTime.diff(to, from, :millisecond), 0)

  # Each ended run with its stage, its tokens and how long it ran. A run still working is not here
  # yet. A run whose start the ledger lacks counts at its end.
  defp runs(events, moves) do
    started =
      for %Event{type: "run.started", payload: %{run_id: run_id}, at: %DateTime{} = at} <- events, into: %{} do
        {run_id, at}
      end

    for %Event{type: "run.ended", payload: %{run_id: run_id} = payload, at: %DateTime{} = ended_at} <- events do
      started_at = Map.get(started, run_id, ended_at)

      %{
        stage: stage_at(moves, started_at),
        tokens: tokens(Map.get(payload, :tokens)),
        agent_time_ms: Map.get(payload, :duration_ms) || time_ms(started_at, ended_at)
      }
    end
  end

  defp stage_at(moves, at) do
    moves
    |> Enum.take_while(&(DateTime.compare(&1.at, at) != :gt))
    |> List.last(%{stage: nil})
    |> Map.fetch!(:stage) || @outside_any_stage
  end

  defp tokens(tokens) when is_integer(tokens), do: tokens
  defp tokens(%{} = tokens), do: tokens(Map.get(tokens, :total_tokens, Map.get(tokens, "total_tokens")))
  defp tokens(_tokens), do: 0

  defp lifecycle(moves, runs, token_cap) do
    current = current_stage(moves)
    position = position(moves, current)

    stages =
      @stages
      |> Enum.with_index()
      |> Enum.map(fn {stage, index} -> stage_row(stage, index, {current, position}, moves, runs) end)

    %{current: current, stages: stages, tokens: %{total: runs |> Enum.map(& &1.tokens) |> Enum.sum(), cap: token_cap}}
  end

  # Done is where the ticket stands once it ended, not a stage it works in: nothing is current then.
  defp current_stage(moves) do
    case List.last(moves) do
      %{stage: stage} when stage not in [nil, "done"] -> stage
      _other -> nil
    end
  end

  # The stages before this index are behind the ticket: the current one, or, when none is, the one
  # after the last it entered.
  defp position(_moves, current) when is_binary(current), do: stage_index(current)

  defp position(moves, nil) do
    last_entered = moves |> Enum.map(& &1.stage) |> Enum.reject(&is_nil/1) |> List.last()

    if last_entered, do: stage_index(last_entered) + 1, else: 0
  end

  defp stage_index(stage), do: Enum.find_index(@stages, fn {id, _name} -> id == stage end)

  defp stage_row({id, name}, index, where, moves, runs) do
    in_stage = Enum.filter(moves, &(&1.stage == id))
    runs_in_stage = Enum.filter(runs, &(&1.stage == id))
    visits = Enum.count(in_stage, & &1.opens_visit?)

    %{
      id: id,
      name: name,
      state: stage_state(id, index, visits, where),
      visits: visits,
      time_ms: in_stage |> Enum.map(& &1.time_ms) |> Enum.sum(),
      agent_time_ms: runs_in_stage |> Enum.map(& &1.agent_time_ms) |> Enum.sum(),
      tokens: runs_in_stage |> Enum.map(& &1.tokens) |> Enum.sum()
    }
  end

  defp stage_state(id, _index, _visits, {id, _position}), do: "current"
  defp stage_state(_id, index, 0, {_current, position}) when index < position, do: "skipped"
  defp stage_state(_id, index, _visits, {_current, position}) when index < position, do: "passed"
  defp stage_state(_id, _index, _visits, _where), do: "not_yet"

  defp phase_path(moves) do
    %{
      current: List.last(moves, %{to: nil}).to,
      phases:
        moves
        |> Enum.uniq_by(& &1.to)
        |> Enum.map(fn %{to: to, at: first_entered_at} ->
          in_phase = Enum.filter(moves, &(&1.to == to))

          %{phase: to, count: length(in_phase), time_ms: in_phase |> Enum.map(& &1.time_ms) |> Enum.sum(), first_entered_at: iso8601(first_entered_at)}
        end),
      moves: Enum.map(moves, &%{from: &1.from, to: &1.to, at: iso8601(&1.at)})
    }
  end

  defp iso8601(at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp normalized(value), do: value |> String.trim() |> String.downcase()
end
