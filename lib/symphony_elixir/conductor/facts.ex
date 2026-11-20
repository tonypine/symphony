defmodule SymphonyElixir.Conductor.Facts do
  @moduledoc """
  The facts the Conductor reads at a junction of a ticket's life (`SymphonyElixir.Conductor`), in one
  deterministic document built only from what Symphony already holds: the ticket's record
  (`SymphonyElixir.TicketState`) and its events (`SymphonyElixir.TicketEvents`), and, when the
  ticket's workspace exists, its git diff stat. `GET /api/v1/tickets/:issue_identifier/facts` serves
  it (`read/3`).

  The document (`schema: "symphony.conductor.facts/1"`):

    * `junction`: the junction it is shaped for, and `focus`, what the turn there is for;
    * `ticket`: identifier, title, URL, the description's `problem`, `acceptance` and `walkthrough`
      sections, the walkthrough steps recorded as proved by a test (`proved_steps`: each step's
      number and test, the newest proof of a step; QA's pre-check runs that test and QA does not
      walk the step), the newest brief, the person's decisions, notes and messages, and answers to
      questions;
    * `standing`: phase, coding attempt (the implementation and rework runs started), the pull
      request and its head;
    * `last_run`: the newest run that ended, other than the Conductor's own: its kind, model, exit,
      tokens, steps and their results, the files it changed with a diff stat (only when the workspace
      exists), and the findings it marked resolved;
    * `findings`: every finding with its state (`open`, `resolved`, `reopened`, `confirmed`), class,
      severity, description, evidence, its resolution, and how many times its class was recorded on
      this ticket (`class_count`);
    * `verdicts`: the newest verdicts;
    * `qa_passes` (at `after_qa_blocked` only): the ticket's QA verdicts, oldest first, each with
      its outcome, head and reason, whether it was a block on CI, and the steps of its pass that
      ended blocked: a stepped pass's step answers (`status`, `expected`, `actual`) and the steps
      the pass's verdict named blocked;
    * `conductor`: the Conductor's earlier updates, instructions (with the route Symphony took on
      them, at `after_qa_blocked`) and the guidance its watch gave running runs on this ticket;
    * `budget`: tokens used against the cap (`execution.limits.tokens_per_issue`), QA passes and
      rework runs so far;
    * `filings`: the Conductor's `ticket` route on this ticket (`SymphonyElixir.Conductor.Filing.facts/3`):
      whether it is open, the tickets it already filed or linked from this ticket, how many filings
      remain, and the repos a ticket may be filed in.

  Each fact read from an event carries the event's id (`event_id`), so a claim built on it can be
  traced. Long texts are cut with a marker (`#{inspect(" [cut by Symphony]")}`), lists keep their
  newest entries, and no transcript is read, so a normal ticket's document stays well under 20,000
  tokens.
  """

  alias SymphonyElixir.{Config, RunStore, TicketBrief, TicketEvents, TicketState, Walkthrough, Workspace}
  alias SymphonyElixir.Conductor.Filing
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.TicketEvents.Event

  @schema "symphony.conductor.facts/1"
  @cut_marker " [cut by Symphony]"
  @section_max 3_000
  @text_max 1_000
  @max_findings 30
  @verdicts_shown 10
  @max_notes 10
  @max_conductor 10
  @max_files 40
  @max_qa_passes 10
  @max_blocked_steps 4
  @step_text_max 500
  @coding_kinds ["implementation", "rework"]
  @qa_blocked "after_qa_blocked"
  @focus %{
    "after_coding" => "The implementation run handed off; Code Review or QA judges it next.",
    "after_qa_fail" => "QA failed; a rework run answers its findings next.",
    "after_qa_blocked" =>
      "QA could not judge the change: its newest pass ended blocked or inconclusive. You decide how the ticket gets a real QA result; `qa_passes` holds every pass and why each was blocked.",
    "after_rework" => "The rework run handed off; Code Review or QA judges it again next.",
    "before_merge" => "QA passed or was skipped; the pull request merges next.",
    "during_run" => "A run is working on the ticket now; its live state is under `live`."
  }
  @problem_heading ~r/\A(problem|why|context|background|summary|goal|what)\b/i
  @acceptance_heading ~r/acceptance/i

  @typedoc """
  `build/3`'s options: `events:` (the ticket's events, oldest first), `token_cap:`, `diff_stat:`
  (`(record -> [map()] | nil)`), `conductor:` (the `conductor` settings, default
  `Config.conductor_settings/0`) and `repos:` (the managed repo keys, as `Filing.facts/3` takes them).
  """
  @type opt ::
          {:events, [Event.t()]}
          | {:token_cap, pos_integer() | nil}
          | {:diff_stat, (map() -> [map()] | nil)}
          | {:conductor, Schema.Conductor.t()}
          | {:repos, [String.t()]}

  @doc "The junctions a document may be shaped for: the Conductor's, and `during_run` for a watch turn."
  @spec junctions() :: [String.t()]
  def junctions, do: Schema.Conductor.junctions() ++ ["during_run"]

  @doc """
  The document for the ticket `name` (its identifier, in any case, or its id) at `junction` (nil for
  none): `{:error, :not_found}` for a ticket Symphony keeps no record of, `{:error, {:invalid,
  message}}` for a junction that is not one.
  """
  @spec read(String.t(), String.t() | nil, [opt()]) :: {:ok, map()} | {:error, :not_found | {:invalid, String.t()}}
  def read(name, junction, opts \\ []) when is_binary(name) do
    with :ok <- check_junction(junction),
         {:ok, record} <- find(name) do
      {:ok, build(record, junction, opts)}
    end
  end

  defp check_junction(junction) when junction in [nil, ""], do: :ok

  defp check_junction(junction) do
    if junction in junctions(), do: :ok, else: {:error, {:invalid, "junction must be one of: #{Enum.join(junctions(), ", ")}"}}
  end

  defp find(name) do
    name = String.trim(name)

    # A store that can't be read lists no record, so its tickets read as unknown.
    with({:error, _reason} <- RunStore.list_all_ticket_states(), do: [])
    |> List.wrap()
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.find(&named?(&1, name))
    |> case do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp named?(%{issue_id: id, issue_identifier: identifier}, name),
    do: is_binary(id) and (id == name or (is_binary(identifier) and String.upcase(identifier) == String.upcase(name)))

  @doc "The document for the ticket `record` at `junction` (see the module doc and `t:opt/0`)."
  @spec build(map(), String.t() | nil, [opt()]) :: map()
  def build(record, junction, opts \\ []) do
    record = TicketState.normalize(record)
    events = Keyword.get_lazy(opts, :events, fn -> events(record.issue_id) end)
    last_run = last_run(events)

    %{
      schema: @schema,
      junction: blank_to_nil(junction),
      focus: Map.get(@focus, junction),
      ticket: ticket(record, events),
      standing: standing(record, events),
      last_run: last_run_facts(last_run, events, record, opts),
      findings: findings(events),
      verdicts: verdicts(events),
      conductor: conductor(events),
      budget: budget(record, events, opts),
      filings: Filing.facts(events, Keyword.get_lazy(opts, :conductor, &Config.conductor_settings/0), Keyword.take(opts, [:repos]))
    }
    |> put_qa_passes(junction, events)
  end

  @doc "The events of the ticket `issue_id`, oldest first; none when the store can't read them."
  @spec events(String.t() | nil) :: [Event.t()]
  def events(issue_id) do
    case TicketEvents.query(issue_id, limit: :all) do
      events when is_list(events) -> events
      {:error, _reason} -> []
    end
  end

  # The ticket.

  defp ticket(record, events) do
    sections = sections(record.description)

    %{
      identifier: record.issue_identifier,
      title: record.title,
      url: record.url,
      problem: sections |> section(@problem_heading) |> Kernel.||(untitled(sections)) |> cut(@section_max),
      acceptance: sections |> section(@acceptance_heading) |> cut(@section_max),
      walkthrough: record.description |> Walkthrough.section() |> cut(@section_max),
      proved_steps: proved_steps(events),
      brief: brief(events),
      decisions: Enum.map(record.decisions, &%{title: &1.title, answer: cut(&1.answer, @text_max)}),
      notes: person_notes(events),
      answers: answers(events)
    }
  end

  # The description's sections by heading, in order; the text before the first heading is untitled.
  defp sections(description) when is_binary(description) do
    description
    |> String.split("\n")
    |> Enum.reduce([{nil, []}], fn line, [{heading, lines} | rest] = acc ->
      case Regex.run(~r/^\s*\#{1,6}\s+(.+?)\s*:?\s*$/, line) do
        [_line, title] -> [{title, []} | acc]
        nil -> [{heading, [line | lines]} | rest]
      end
    end)
    |> Enum.map(fn {heading, lines} -> {heading, lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()} end)
    |> Enum.reverse()
  end

  defp sections(_description), do: []

  defp section(sections, pattern) do
    Enum.find_value(sections, fn
      {heading, body} when is_binary(heading) and body != "" -> if Regex.match?(pattern, heading), do: body
      _other -> nil
    end)
  end

  defp untitled([{nil, body} | _rest]) when body != "", do: body
  defp untitled(_sections), do: nil

  # The newest recorded proof of each walkthrough step, by step number (`Walkthrough.proofs_of/1`).
  defp proved_steps(events) do
    events
    |> Enum.flat_map(fn event -> for proof <- Walkthrough.proofs_of([event]), do: Map.put(proof, :event_id, event.id) end)
    |> Enum.reduce(%{}, &Map.put(&2, &1.step, &1))
    |> Map.values()
    |> Enum.sort_by(& &1.step)
    |> Enum.map(&%{&1 | test: cut(&1.test, @step_text_max)})
  end

  defp brief(events) do
    case TicketBrief.current(events) do
      %Event{} = event -> %{event_id: event.id, text: cut(payload(event, :text), @text_max), walkthrough: cut(payload(event, :walkthrough), @section_max)}
      nil -> nil
    end
  end

  defp person_notes(events) do
    events
    |> Enum.filter(&(&1.type in ["note", "message.sent"] and person?(&1)))
    |> Enum.take(-@max_notes)
    |> Enum.map(&%{event_id: &1.id, at: iso8601(&1.at), text: cut(payload(&1, :text), @text_max)})
  end

  defp answers(events) do
    titles =
      for %Event{type: "question.asked"} = asked <- events, into: %{}, do: {payload(asked, :question_id), payload(asked, :title)}

    events
    |> Enum.filter(&(&1.type == "question.answered"))
    |> Enum.take(-@max_notes)
    |> Enum.map(fn answered ->
      %{
        event_id: answered.id,
        question: payload(answered, :title) || Map.get(titles, payload(answered, :question_id)),
        answer: cut(payload(answered, :answer), @text_max),
        option: payload(answered, :option)
      }
    end)
  end

  defp person?(%Event{actor: %{kind: :person}}), do: true
  defp person?(_event), do: false

  # Where it stands.

  defp standing(record, events) do
    pull_request = record.pull_request

    %{
      phase: record.phase,
      attempt: Enum.count(events, &(&1.type == "run.started" and payload(&1, :run_kind) in @coding_kinds)),
      pull_request: pull_request_facts(pull_request),
      head: pull_request && Map.get(pull_request, :head_sha)
    }
  end

  defp pull_request_facts(%{} = pull_request), do: %{number: Map.get(pull_request, :number), url: Map.get(pull_request, :url), state: Map.get(pull_request, :state)}
  defp pull_request_facts(_none), do: nil

  # The last run.

  @doc """
  The newest `run.ended` among `events` (oldest first) of a run other than the Conductor's own, nil
  when no such run ended.
  """
  @spec last_run([Event.t()]) :: Event.t() | nil
  def last_run(events) do
    events
    |> Enum.filter(&(&1.type == "run.ended" and payload(&1, :run_kind) != "conductor"))
    |> List.last()
  end

  defp last_run_facts(nil, _events, _record, _opts), do: nil

  defp last_run_facts(%Event{} = ended, events, record, opts) do
    run_id = payload(ended, :run_id)
    started = Enum.find(events, &(&1.type == "run.started" and payload(&1, :run_id) == run_id))

    %{
      event_id: ended.id,
      started_event_id: started && started.id,
      run_id: run_id,
      kind: payload(ended, :run_kind),
      model: payload(ended, :model) || (started && payload(started, :model)),
      exit: payload(ended, :exit),
      duration_ms: payload(ended, :duration_ms),
      tokens: tokens(payload(ended, :tokens)),
      steps: steps(events, run_id),
      resolved_findings: resolved(events, run_id)
    }
    |> put_files_changed(record, opts)
  end

  defp steps(events, run_id) do
    for %Event{type: "step.completed", run_id: ^run_id} = step <- events do
      %{
        event_id: step.id,
        step_id: payload(step, :step_id),
        title: payload(step, :title),
        mode: payload(step, :mode),
        outcome: payload(step, :outcome),
        returns_to: payload(step, :returns_to),
        reason: payload(step, :reason),
        result: result(payload(step, :result)),
        answer: answer(payload(step, :answer)),
        verdict_summary: payload(step, :verdict_summary)
      }
      |> drop_nil()
    end
  end

  # A QA step's answer, as the pass put it on the step's `step.completed`.
  defp result(%{} = result) do
    field = fn key -> Map.get(result, key, Map.get(result, Atom.to_string(key))) end
    %{status: field.(:status), expected: cut(field.(:expected), @text_max), actual: cut(field.(:actual), @text_max)}
  end

  defp result(_none), do: nil

  # A step's structured answer (`SymphonyElixir.PhaseSteps.StepAnswer`), each value cut for the facts.
  defp answer([_ | _] = entries) do
    for %{} = entry <- entries do
      field = fn key -> Map.get(entry, key, Map.get(entry, Atom.to_string(key))) end
      %{label: field.(:label), value: cut(field.(:value), @text_max)}
    end
  end

  defp answer(_none), do: nil

  defp resolved(events, run_id) do
    for %Event{type: "finding.resolved", run_id: ^run_id} = resolution <- events do
      %{event_id: resolution.id, finding_id: payload(resolution, :finding_id), how: cut(payload(resolution, :how), @text_max)}
    end
  end

  # The files the workspace changed against its base, when the workspace exists; left out otherwise.
  defp put_files_changed(facts, record, opts) do
    case Keyword.get(opts, :diff_stat, &workspace_diff_stat/1).(record) do
      files when is_list(files) -> Map.put(facts, :files_changed, Enum.take(files, @max_files))
      _none -> facts
    end
  end

  defp workspace_diff_stat(%{issue_identifier: identifier, repo_key: repo_key}) when is_binary(identifier) and is_binary(repo_key) do
    with {:ok, workspace} <- Workspace.local_path_for_issue(identifier, repo_key),
         true <- File.exists?(Path.join(workspace, ".git")),
         {output, 0} <- Workspace.safe_git(["-C", workspace, "diff", "--numstat", "origin/HEAD...HEAD"]) do
      numstat(output)
    else
      _missing -> nil
    end
  end

  defp workspace_diff_stat(_record), do: nil

  @doc "The files a `git diff --numstat` lists, each with its lines added and removed (nil for a binary file)."
  @spec numstat(String.t()) :: [%{path: String.t(), added: non_neg_integer() | nil, removed: non_neg_integer() | nil}]
  def numstat(output) when is_binary(output) do
    for line <- String.split(output, "\n", trim: true), [added, removed, path] <- [String.split(line, "\t", parts: 3)] do
      %{path: path, added: count(added), removed: count(removed)}
    end
  end

  defp count(text) do
    case Integer.parse(text) do
      {count, ""} -> count
      _binary -> nil
    end
  end

  # Findings.

  defp findings(events) do
    classes = events |> Enum.filter(&(&1.type == "finding.recorded")) |> Enum.frequencies_by(&payload(&1, :class))

    events
    |> TicketEvents.findings()
    |> Enum.take(-@max_findings)
    |> Enum.map(fn %{finding: finding, state: state, resolution: resolution, reopened_by: reopened_by} ->
      class = payload(finding, :class)

      %{
        event_id: finding.id,
        state: Atom.to_string(state),
        class: class,
        class_count: Map.get(classes, class, 1),
        severity: payload(finding, :severity),
        step: payload(finding, :step),
        description: cut(payload(finding, :description), @text_max),
        evidence: finding |> payload(:evidence) |> List.wrap() |> Enum.map(&cut(&1, 300)),
        resolution: resolution && %{event_id: resolution.id, how: cut(payload(resolution, :how), @text_max)},
        reopened_by: reopened_by && reopened_by.id
      }
      |> drop_nil()
    end)
  end

  defp verdicts(events) do
    events
    |> Enum.filter(&(&1.type == "verdict.recorded" and is_nil(payload(&1, :signal))))
    |> Enum.take(-@verdicts_shown)
    |> Enum.map(&drop_nil(%{event_id: &1.id, kind: payload(&1, :kind), outcome: payload(&1, :outcome), head: payload(&1, :head), reason: cut(verdict_reason(&1), @text_max)}))
  end

  # A QA verdict keeps its reason in its details.
  defp verdict_reason(verdict), do: payload(verdict, :reason) || field(payload(verdict, :details) || %{}, :reason)

  # Every QA verdict with the steps of its pass that ended blocked, read from the events its run
  # recorded: a stepped pass's `step.completed` answers, and the `evidence` of each step the pass's
  # verdict named.
  defp put_qa_passes(facts, @qa_blocked, events), do: Map.put(facts, :qa_passes, qa_passes(events))
  defp put_qa_passes(facts, _junction, _events), do: facts

  defp qa_passes(events) do
    events
    |> Enum.filter(&(&1.type == "verdict.recorded" and payload(&1, :kind) == "qa" and is_nil(payload(&1, :signal))))
    |> Enum.take(-@max_qa_passes)
    |> Enum.map(fn verdict ->
      details = payload(verdict, :details) || %{}

      %{
        event_id: verdict.id,
        run_id: verdict.run_id,
        outcome: payload(verdict, :outcome),
        head: payload(verdict, :head),
        reason: cut(verdict_reason(verdict), @text_max),
        on_ci: if(field(details, :component) == "ci", do: true),
        blocked_steps: blocked_steps(events, verdict.run_id)
      }
      |> drop_nil()
    end)
  end

  defp blocked_steps(_events, nil), do: []

  defp blocked_steps(events, run_id) do
    events
    |> Enum.filter(&(&1.run_id == run_id))
    |> Enum.flat_map(&blocked_step/1)
    |> Enum.take(@max_blocked_steps)
  end

  defp blocked_step(%Event{type: "step.completed"} = step) do
    case payload(step, :result) do
      %{} = result ->
        if field(result, :status) == "blocked",
          do: [drop_nil(%{event_id: step.id, step_id: payload(step, :step_id), title: payload(step, :title), result: step_result(result)})],
          else: []

      _none ->
        []
    end
  end

  defp blocked_step(%Event{type: "evidence"} = evidence) do
    if payload(evidence, :status) == "blocked",
      do: [drop_nil(%{event_id: evidence.id, step: payload(evidence, :step), details: cut(payload(evidence, :details), @step_text_max)})],
      else: []
  end

  defp blocked_step(_event), do: []

  defp step_result(result) do
    %{
      status: field(result, :status),
      expected: cut(field(result, :expected), @step_text_max),
      actual: cut(field(result, :actual), @step_text_max)
    }
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp conductor(events) do
    events
    |> Enum.filter(&(&1.type in ["conductor.update", "conductor.instructions", "conductor.steer"]))
    |> Enum.take(-@max_conductor)
    |> Enum.map(fn event ->
      %{
        event_id: event.id,
        type: String.replace_prefix(event.type, "conductor.", ""),
        junction: payload(event, :junction),
        at: iso8601(event.at),
        text: cut(payload(event, :text), @text_max)
      }
      |> Map.merge(drop_nil(%{route: payload(event, :route), when: payload(event, :when), trigger: payload(event, :trigger)}))
    end)
  end

  # Budget.

  defp budget(record, events, opts) do
    started = Enum.filter(events, &(&1.type == "run.started"))

    %{
      tokens_used: events |> Enum.filter(&(&1.type == "run.ended")) |> Enum.map(&(&1 |> payload(:tokens) |> tokens() || 0)) |> Enum.sum(),
      tokens_cap: Keyword.get_lazy(opts, :token_cap, fn -> token_cap(record.repo_key) end),
      qa_passes: Enum.count(started, &(payload(&1, :run_kind) == "qa")),
      rework_runs: Enum.count(started, &(payload(&1, :run_kind) == "rework"))
    }
  end

  defp token_cap(repo_key) when is_binary(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings.execution.max_tokens_per_issue
      _error -> nil
    end
  end

  defp token_cap(_repo_key), do: nil

  @doc "A run's tokens as its `run.ended` records them: a count, or a map with `total_tokens`; nil when unknown."
  @spec tokens(term()) :: non_neg_integer() | nil
  def tokens(count) when is_integer(count), do: count
  def tokens(%{total_tokens: count}) when is_integer(count), do: count
  def tokens(%{"total_tokens" => count}) when is_integer(count), do: count
  def tokens(_tokens), do: nil

  # Helpers.

  @doc "`text` cut to `max` characters with a marker, nil for a missing or blank text."
  @spec cut(term(), pos_integer()) :: String.t() | nil
  def cut(text, max) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> nil
      String.length(text) > max -> String.slice(text, 0, max) <> @cut_marker
      true -> text
    end
  end

  def cut(_text, _max), do: nil

  @doc """
  `text` (trimmed) fitted to `max` characters: whole when it fits, else cut at the last sentence end
  (or, failing that, the last word end) that leaves room for the marker, with the marker, so the
  result never goes over `max`.
  """
  @spec fit(String.t(), pos_integer()) :: String.t()
  def fit(text, max) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) <= max do
      text
    else
      room = max - String.length(@cut_marker)
      head = String.slice(text, 0, room)
      kept = boundary(head, ~r/[.!?](?=\s)|\n/u, 1) || boundary(head, ~r/\s/u, 0) || head
      String.trim_trailing(kept) <> @cut_marker
    end
  end

  # `head` up to its last match of `pattern` (plus `extra` characters of it) when that keeps at least
  # half of it.
  defp boundary(head, pattern, extra) do
    case pattern |> Regex.scan(head, return: :index) |> List.last() do
      [{start, length}] when start > div(byte_size(head), 2) -> binary_part(head, 0, start + min(extra, length))
      _none -> nil
    end
  end

  defp payload(%Event{payload: payload}, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp drop_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp iso8601(at), do: at && DateTime.to_iso8601(at)
end
