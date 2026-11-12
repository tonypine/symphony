defmodule SymphonyElixir.AgentTools.Report do
  @moduledoc """
  The two tools of a report run (`SymphonyElixir.Reports`), and nothing else: the run can publish
  its report and ask the Director one question, and it can change nothing in the factory.

    * `symphony_publish_report` takes the report as its sentences, each with the ids of the events
      of the period it rests on (`events`). It refuses, with the reason, a report with no sentence,
      a sentence that cites no event, one that cites an id that is no event of the period, an entry
      that holds more than one sentence, and a second report. A report it takes is recorded as one
      `report.published` event on the reports ledger (`SymphonyElixir.RunStore.append_report_event/1`).
    * `request_decision` asks the Director one question through the one decision path
      (`SymphonyElixir.Questions.ask/3` on Symphony itself, which checks it against the writing
      standard): it lands in the Inbox, says it comes from this report, and pauses nothing. The run
      may ask once, before it publishes; the report then carries the question's id.

  `execute/3` runs a call and returns the text the model reads back and the run's new state.
  """

  alias SymphonyElixir.{Questions, RunStore, TicketEvents}
  alias SymphonyElixir.Reports.Material
  alias SymphonyElixir.TicketEvents.Event

  @publish "symphony_publish_report"
  @decision "request_decision"
  @max_text 20_000
  # Two sentences in one entry: an end mark, then a capital letter.
  @two_sentences ~r/[.!?]["'”’)\]]*\s+\p{Lu}/u

  @typedoc """
  A report run's state: its id and model, its material, the Question it asked (by id, nil until
  then) and the report it published (nil until then).
  """
  @type state :: %{
          required(:run_id) => String.t(),
          required(:model) => String.t(),
          required(:material) => Material.t(),
          optional(:question_id) => String.t() | nil,
          optional(:published) => Event.t() | nil
        }

  @doc "The tool names, publish first."
  @spec names() :: [String.t()]
  def names, do: [@publish, @decision]

  @doc "The tools as the Messages API takes them: name, description and input schema."
  @spec specs() :: [map()]
  def specs do
    [
      %{
        "name" => @publish,
        "description" =>
          "Publish the status report: its sentences in reading order, each with the ids of the events of the period it rests on. " <>
            "Every sentence must cite at least one event. Call it once, when the report is done.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "sentences" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "text" => %{"type" => "string", "description" => "One sentence, in plain words."},
                  "events" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "The ids of the events it rests on."}
                },
                "required" => ["text", "events"]
              }
            }
          },
          "required" => ["sentences"]
        }
      },
      %{
        "name" => @decision,
        "description" =>
          "Ask the Director one decision the period calls for, in their words: it lands in their Inbox. " <>
            "At most once, before you publish. It changes nothing by itself.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string"},
            "why" => %{"type" => "string"},
            "if_unanswered" => %{"type" => "string"},
            "decision" => %{
              "type" => "object",
              "properties" => %{
                "question" => %{"type" => "string"},
                "recommendation_reason" => %{"type" => "string"},
                "options" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "object",
                    "properties" => %{"label" => %{"type" => "string"}, "effect" => %{"type" => "string"}, "recommended" => %{"type" => "boolean"}},
                    "required" => ["label", "effect"]
                  }
                }
              },
              "required" => ["question", "options", "recommendation_reason"]
            }
          },
          "required" => ["title", "why", "if_unanswered", "decision"]
        }
      }
    ]
  end

  @doc """
  Runs the tool `name` with `input` for the run in `state`: `{:ok, text, state}` when it did what
  was asked, `{:error, text, state}` when it refused, `text` saying why.
  """
  @spec execute(String.t(), map(), state()) :: {:ok, String.t(), state()} | {:error, String.t(), state()}
  def execute(@publish, input, state), do: publish(input, state)
  def execute(@decision, input, state), do: request_decision(input, state)
  def execute(name, _input, state), do: {:error, "#{name} is not a tool of a report run: it has #{Enum.join(names(), " and ")} only.", state}

  defp publish(_input, %{published: %Event{}} = state), do: {:error, "The report is already published.", state}

  defp publish(input, state) do
    with {:ok, sentences} <- sentences(input),
         :ok <- cited(sentences, MapSet.new(Material.event_ids(state.material))),
         {:ok, event} <- record(sentences, state) do
      {:ok, "Published the report #{event.id}.", Map.put(state, :published, event)}
    else
      {:error, message} -> {:error, message, state}
    end
  end

  defp sentences(%{"sentences" => [_ | _] = sentences}) do
    if Enum.all?(sentences, &sentence?/1),
      do: {:ok, Enum.map(sentences, &%{text: String.trim(&1["text"]), events: Enum.uniq(&1["events"])})},
      else: {:error, "Each sentence needs a non-blank text and a list of event ids."}
  end

  defp sentences(_input), do: {:error, "The report needs at least one sentence."}

  defp sentence?(%{"text" => text, "events" => events}) when is_binary(text) and is_list(events), do: String.trim(text) != "" and Enum.all?(events, &is_binary/1)
  defp sentence?(_sentence), do: false

  defp cited(sentences, period_ids) do
    sentences
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {sentence, number} -> refusal(sentence, number, period_ids) end)
  end

  defp refusal(%{text: text, events: []}, number, _ids),
    do: {:error, "Sentence #{number} (#{inspect(text)}) cites no event: every sentence must cite the events of the period it rests on, or go."}

  defp refusal(%{text: text, events: events}, number, ids) do
    cond do
      unknown = Enum.find(events, &(not MapSet.member?(ids, &1))) ->
        {:error, "Sentence #{number} cites #{unknown}, which is no event of the period."}

      Regex.match?(@two_sentences, text) ->
        {:error, "Sentence #{number} (#{inspect(text)}) holds more than one sentence: give each its own entry, with its own events."}

      true ->
        nil
    end
  end

  defp record(sentences, state) do
    texts = Enum.map(sentences, & &1.text)
    cited = sentences |> Enum.flat_map(& &1.events) |> Enum.uniq()
    text = Enum.join(texts, " ")
    period = state.material.period

    payload = %{
      run_id: state.run_id,
      model: state.model,
      period: %{from: DateTime.to_iso8601(period.from), to: DateTime.to_iso8601(period.to)},
      tickets: Material.tickets_of(state.material, cited),
      events: cited,
      sentences: texts,
      text: text,
      citations: sentences |> Enum.with_index() |> Enum.map(fn {sentence, index} -> %{sentence: index, events: sentence.events} end),
      question_id: Map.get(state, :question_id)
    }

    with :ok <- length_ok(text),
         {repo_key, issue_id} = stream(),
         {:ok, event} <- TicketEvents.build(repo_key, issue_id, "report.published", payload, run_id: state.run_id),
         {:ok, stored} <- RunStore.append_report_event(event) do
      TicketEvents.notify(stored)
      {:ok, stored}
    else
      {:error, reason} -> {:error, "The report was not published: " <> reason_text(reason)}
    end
  end

  defp length_ok(text) do
    if String.length(text) <= @max_text, do: :ok, else: {:error, "The report is longer than #{@max_text} characters: say it in fewer words."}
  end

  @doc "The `repo_key` and `issue_id` the reports ledger's events carry: none and `reports`, which no Linear issue has."
  @spec stream() :: {nil, String.t()}
  def stream, do: {nil, "reports"}

  defp request_decision(_input, %{published: %Event{}} = state), do: {:error, "Ask before you publish: the report carries the question it raised.", state}
  defp request_decision(_input, %{question_id: id} = state) when is_binary(id), do: {:error, "A report asks at most one question, and this one asked already.", state}

  defp request_decision(input, state) do
    request = request(input, state.material.period)
    asked_by = %{kind: :run, name: "Report run", run_id: state.run_id}

    case Questions.ask(:symphony, request, asked_by: asked_by, step: "report:" <> state.run_id) do
      {:ok, %{id: id}} -> {:ok, "Asked the Director: question #{id}. The report carries it.", Map.put(state, :question_id, id)}
      {:error, reason} -> {:error, "The question was not asked: " <> reason_text(reason), state}
    end
  end

  # The tool's input as the decision path takes it, its why saying the report it comes from.
  defp request(input, period) do
    decision = if is_map(input["decision"]), do: input["decision"], else: %{}

    %{
      title: input["title"],
      why: Enum.join(Enum.reject([input["why"], "It comes from the status report on #{clock(period.from)} to #{clock(period.to)} UTC."], &is_nil/1), " "),
      question: decision["question"],
      options: for(option <- List.wrap(decision["options"]), is_map(option), do: %{label: option["label"], effect: option["effect"], recommended: option["recommended"] == true}),
      recommendation_reason: decision["recommendation_reason"],
      if_unanswered: input["if_unanswered"]
    }
  end

  # A refusal in words: the standard's or the tool's own message, else the reason as it came.
  defp reason_text({:invalid_question, message}), do: message
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp clock(at), do: Calendar.strftime(at, "%-d %B %H:%M")
end
