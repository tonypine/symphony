defmodule SymphonyElixir.Reports do
  @moduledoc """
  Status reports for a period, written by a report run.

  A report run is a run of Symphony's own, of the kind `report`: it belongs to no ticket and takes no
  slot. Its prompt is the period's notable events and the situation of every ticket they concern
  (`SymphonyElixir.Reports.Material`), and its only tools are the two of
  `SymphonyElixir.AgentTools.Report`: one publishes the report, and refuses one with a sentence that
  cites no event of the period; the other asks the Director one question through the one decision
  path, which lands in the Inbox. So a report asks and never acts: nothing else in the factory
  changes because of it. The run calls the model of `reports.model` (`SymphonyElixir.Config.report_model/0`,
  the cheapest capable model by default) through `SymphonyElixir.Reports.Anthropic`, a turn at a time,
  until the report is published or `@max_turns` turns have passed.

  `start/2` starts a run in the background (`symphony report --from --to`,
  `POST /api/v1/control/report`); `run/2` is the run itself. A published report is one
  `report.published` event on the reports ledger (`SymphonyElixir.RunStore.append_report_event/1`);
  `list/1` reads them newest first (`GET /api/v1/reports`). This module starts no run on a schedule.
  """

  require Logger

  alias SymphonyElixir.{Config, RunStore}
  alias SymphonyElixir.AgentTools.Report
  alias SymphonyElixir.Reports.{Anthropic, Material, Period}
  alias SymphonyElixir.TicketEvents.Event

  @max_turns 6

  @system_prompt """
  You write Symphony's status report for the Director, the person who runs this software factory.
  Symphony is a factory of agents working on tickets; the Director reads your report to know, in a
  minute, what happened in the period and what needs them.

  Write it as a colleague would: short, plain sentences, the most important first (what shipped,
  what is stuck or failing, what waits on the Director), tickets named by their identifier. No code,
  no file names, no event ids or type names in the text.

  Every sentence rests on events of the period. Publish the report with symphony_publish_report,
  giving each sentence on its own with the ids of the events it rests on, in square brackets in the
  list you are given. A sentence you cannot back with an event does not belong in the report.

  If the period shows a decision only the Director can make, ask it once with request_decision
  before you publish, in their words, with two to four options and one recommended. Otherwise ask
  nothing. You cannot change anything else.
  """

  @typedoc "What `start/2` answers: the run's id, its model, its period and how many events it reads."
  @type started :: %{run_id: String.t(), model: String.t(), from: DateTime.t(), to: DateTime.t(), events: non_neg_integer()}

  @doc """
  Starts a report run on `period` in the background and answers at once, or refuses a period with
  no notable event (`:no_events`), which leaves nothing to cite. `opts`: `model:` (default
  `reports.model`), `start_task:` (`(fun -> term)`, default a `SymphonyElixir.TaskSupervisor`
  child), and `run/2`'s and `SymphonyElixir.Reports.Material.read/2`'s.
  """
  @spec start(Period.t(), keyword()) :: {:ok, started()} | {:error, term()}
  def start(%{from: from, to: to} = period, opts \\ []) do
    with {:ok, material} <- material(period, opts) do
      run_id = "report-" <> Event.ulid(DateTime.utc_now())
      model = Keyword.get_lazy(opts, :model, &Config.report_model/0)
      start_task = Keyword.get(opts, :start_task, &Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, &1))
      run_opts = Keyword.merge(opts, run_id: run_id, model: model)
      _started = start_task.(fn -> run(material, run_opts) end)
      Logger.info("Report run started run_id=#{run_id} model=#{model} from=#{DateTime.to_iso8601(from)} to=#{DateTime.to_iso8601(to)} events=#{length(material.events)}")
      {:ok, %{run_id: run_id, model: model, from: from, to: to, events: length(material.events)}}
    end
  end

  @doc """
  The material of `period` (`SymphonyElixir.Reports.Material.read/2`), or `{:error, :no_events}`
  when the period holds no notable event.
  """
  @spec material(Period.t(), keyword()) :: {:ok, Material.t()} | {:error, term()}
  def material(period, opts \\ []) do
    with {:ok, material} <- Material.read(period, opts) do
      if material.events == [], do: {:error, :no_events}, else: {:ok, material}
    end
  end

  @doc """
  Runs the report run on `material` and answers the `report.published` event it recorded, or why
  none was: `:not_published` once `@max_turns` turns passed without a report its tool took,
  `:no_tool_call` when the model called no tool, or the model's error. `opts`: `run_id:`, `model:`
  and `turn:` (`(request, opts) -> {:ok, blocks} | {:error, reason}`, default
  `SymphonyElixir.Reports.Anthropic.turn/2`).
  """
  @spec run(Material.t(), keyword()) :: {:ok, Event.t()} | {:error, term()}
  def run(material, opts) do
    state = %{run_id: Keyword.fetch!(opts, :run_id), model: Keyword.fetch!(opts, :model), material: material, question_id: nil, published: nil}
    messages = [%{"role" => "user", "content" => Material.prompt(material)}]

    case loop(messages, state, Keyword.get(opts, :turn, &Anthropic.turn/2), @max_turns) do
      {:ok, event} ->
        Logger.info("Report run published run_id=#{state.run_id} report_id=#{event.id}")
        {:ok, event}

      {:error, reason} ->
        Logger.warning("Report run published no report run_id=#{state.run_id} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp loop(_messages, _state, _turn, 0), do: {:error, :not_published}

  defp loop(messages, state, turn, turns_left) do
    with {:ok, content} <- turn.(%{system: @system_prompt, messages: messages, tools: Report.specs(), model: state.model}, []) do
      case call_tools(content, state) do
        {_results, %{published: %Event{} = event}} -> {:ok, event}
        {[], _state} -> {:error, :no_tool_call}
        {results, state} -> loop(messages ++ [%{"role" => "assistant", "content" => content}, %{"role" => "user", "content" => results}], state, turn, turns_left - 1)
      end
    end
  end

  defp call_tools(content, state) do
    Enum.flat_map_reduce(content, state, fn
      %{"type" => "tool_use", "id" => id, "name" => name} = block, state ->
        {status, text, state} = Report.execute(name, Map.get(block, "input") || %{}, state)
        {[%{"type" => "tool_result", "tool_use_id" => id, "content" => text, "is_error" => status == :error}], state}

      _text, state ->
        {[], state}
    end)
  end

  @doc """
  The published reports, newest first, by when they were published: `opts` `since:` and `until:`
  (exclusive) bound it. A store error is returned as it is.
  """
  @spec list(keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def list(opts \\ []) do
    with events when is_list(events) <- RunStore.list_report_events() do
      {:ok,
       events
       |> Enum.filter(&(&1.type == "report.published" and after?(&1.at, opts[:since]) and before?(&1.at, opts[:until])))
       |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.seq || 0}, :desc)}
    end
  end

  defp after?(_at, nil), do: true
  defp after?(at, since), do: DateTime.compare(at, since) == :gt
  defp before?(_at, nil), do: true
  defp before?(at, until), do: DateTime.compare(at, until) == :lt

  @doc "A published report as the API serves it."
  @spec json(Event.t()) :: map()
  def json(%Event{payload: payload} = event) do
    %{
      id: event.id,
      at: DateTime.to_iso8601(event.at),
      run_id: payload.run_id,
      model: payload.model,
      period: payload.period,
      tickets: payload.tickets,
      events: payload.events,
      sentences: payload.sentences,
      text: payload.text,
      citations: payload.citations,
      question_id: Map.get(payload, :question_id)
    }
  end
end
