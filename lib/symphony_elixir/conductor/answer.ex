defmodule SymphonyElixir.Conductor.Answer do
  @moduledoc """
  The Conductor's answer (`SymphonyElixir.Conductor`), read from its turn's text and checked against
  its schema: one JSON object with

    * `instructions`: what the next run should focus on, a non-blank string of at most 2,000
      characters;
    * `update`: for the person, markdown in the Conductor's own voice, a string of at most 1,200
      characters, or null (a blank string reads
      as null);
    * `refs`: the ids of the events the update rests on (optional; only ids the facts carry are kept);
    * `ask_person`: null, or a question to the person: `title`, `question`, `why`, `if_unanswered`,
      `recommendation_reason` and two to four `options`, each with a `label`, an `effect` and
      `recommended` (the request `SymphonyElixir.Questions.ask/3` takes);
    * `steer` (a watch turn's, `SymphonyElixir.Conductor.Watch`): null, or guidance for the running
      run: `message` (at most 1,500 characters) and `when` (`next_turn` or `now`);
    * `blocks` (optional): at most 3 message blocks to pick, each `{"type": ...}` with the facts it
      points at (`steps`, `evidence`, `budget`, `path`, `attempts`, `compare`, `findings`, `epic`;
      `SymphonyElixir.Conductor.Blocks` resolves them); an unknown or malformed entry is dropped, and
      never fails the answer;
    * `stop` (a watch turn's): null, or `{"reason": ...}` to end the running run.

  A watch turn (`watch: true`) may leave `instructions` null. An answer that misses the schema is
  refused with why, in plain words.
  """

  alias SymphonyElixir.ReviewAgent

  @instructions_max 2_000
  @update_max 1_200
  @steer_max 1_500
  @blocks_max 3
  @evidence_max 4
  @compare_text_max 80
  @question_fields ~w(title question why if_unanswered recommendation_reason)

  @type t :: %{
          instructions: String.t() | nil,
          update: String.t() | nil,
          refs: [String.t()],
          ask_person: map() | nil,
          steer: %{message: String.t(), when: String.t()} | nil,
          stop: %{reason: String.t()} | nil,
          blocks: [map()]
        }

  @doc "The most characters `instructions` may hold."
  @spec instructions_max() :: pos_integer()
  def instructions_max, do: @instructions_max

  @doc "The most characters `update` may hold."
  @spec update_max() :: pos_integer()
  def update_max, do: @update_max

  @doc """
  The answer among `texts` (the turn's text candidates, most specific first): the first JSON object
  in them that meets the schema, else the first refusal.
  """
  @spec read([String.t()], keyword()) :: {:ok, t()} | {:error, String.t()}
  def read(texts, opts \\ []) when is_list(texts) do
    texts
    |> Enum.flat_map(&ReviewAgent.json_object_candidates/1)
    |> Enum.reduce_while({:error, "the answer holds no JSON object"}, fn candidate, error ->
      case parse(candidate, opts) do
        {:ok, answer} -> {:halt, {:ok, answer}}
        {:error, _reason} = refused -> {:cont, first_error(error, refused)}
      end
    end)
  end

  defp first_error({:error, "the answer holds no JSON object"}, refused), do: refused
  defp first_error(error, _refused), do: error

  @doc "Checks one JSON object's text against the schema; `watch: true` for a watch turn's."
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(text, opts \\ []) when is_binary(text) do
    with {:ok, %{} = answer} <- decode(text),
         {:ok, instructions} <- instructions(Map.get(answer, "instructions"), Keyword.get(opts, :watch, false)),
         {:ok, update} <- update(Map.get(answer, "update")),
         {:ok, refs} <- refs(Map.get(answer, "refs")),
         {:ok, ask_person} <- ask_person(Map.get(answer, "ask_person")),
         {:ok, steer} <- steer(Map.get(answer, "steer")),
         {:ok, stop} <- stop(Map.get(answer, "stop")) do
      {:ok, %{instructions: instructions, update: update, refs: refs, ask_person: ask_person, steer: steer, stop: stop, blocks: blocks(Map.get(answer, "blocks"))}}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = answer} -> {:ok, answer}
      {:ok, _other} -> {:error, "the answer is not a JSON object"}
      {:error, _reason} -> {:error, "the answer is not valid JSON"}
    end
  end

  defp instructions(nil, true = _watch?), do: {:ok, nil}

  defp instructions(text, _watch?) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, "`instructions` is blank"}
      String.length(text) > @instructions_max -> {:error, "`instructions` is over #{@instructions_max} characters"}
      true -> {:ok, text}
    end
  end

  defp instructions(_text, _watch?), do: {:error, "`instructions` must be a string"}

  defp steer(nil), do: {:ok, nil}

  defp steer(%{"message" => message, "when" => moment}) when is_binary(message) and moment in ["next_turn", "now"] do
    message = String.trim(message)

    cond do
      message == "" -> {:error, "`steer.message` is blank"}
      String.length(message) > @steer_max -> {:error, "`steer.message` is over #{@steer_max} characters"}
      true -> {:ok, %{message: message, when: moment}}
    end
  end

  defp steer(_steer), do: {:error, "`steer` must be null or hold a `message` and `when` (`next_turn` or `now`)"}

  defp stop(nil), do: {:ok, nil}
  defp stop(%{"reason" => reason}) when is_binary(reason) and reason != "", do: {:ok, %{reason: String.trim(reason)}}
  defp stop(_stop), do: {:error, "`stop` must be null or hold a `reason`"}

  defp update(nil), do: {:ok, nil}

  defp update(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:ok, nil}
      String.length(text) > @update_max -> {:error, "`update` is over #{@update_max} characters"}
      true -> {:ok, text}
    end
  end

  defp update(_text), do: {:error, "`update` must be a string or null"}

  # The picks that are well formed, the first three; the rest are dropped one by one.
  defp blocks(picks) when is_list(picks), do: picks |> Enum.flat_map(&block/1) |> Enum.take(@blocks_max)
  defp blocks(_picks), do: []

  defp block(%{"type" => type} = pick) when type in ["budget", "path", "findings", "epic"],
    do: if(map_size(pick) == 1, do: [%{type: type}], else: [])

  defp block(%{"type" => "steps"} = pick), do: with_run(pick, "steps", [])

  defp block(%{"type" => "attempts", "step_id" => step_id} = pick) when is_binary(step_id) and step_id != "",
    do: with_run(Map.delete(pick, "step_id"), "attempts", step_id: step_id)

  defp block(%{"type" => "evidence", "refs" => refs} = pick) when is_list(refs) and refs != [] and map_size(pick) == 2 do
    if length(refs) <= @evidence_max and Enum.all?(refs, &id?/1), do: [%{type: "evidence", refs: Enum.uniq(refs)}], else: []
  end

  defp block(%{"type" => "compare", "expected" => expected, "actual" => actual} = pick) when map_size(pick) == 3 do
    with {:ok, expected} <- side(expected),
         {:ok, actual} <- side(actual) do
      [%{type: "compare", expected: expected, actual: actual}]
    else
      :error -> []
    end
  end

  defp block(_pick), do: []

  # `steps` and `attempts` take an optional `run_id`, and nothing else.
  defp with_run(pick, type, fields) do
    case Map.delete(pick, "type") do
      empty when map_size(empty) == 0 -> [Map.merge(%{type: type}, Map.new(fields))]
      %{"run_id" => run_id} = only when map_size(only) == 1 -> if id?(run_id), do: [Map.merge(%{type: type, run_id: run_id}, Map.new(fields))], else: []
      _extra -> []
    end
  end

  defp side(%{"text" => text} = side) when is_binary(text) and map_size(side) == 1 do
    text = String.trim(text)
    if text != "" and String.length(text) <= @compare_text_max, do: {:ok, %{text: text}}, else: :error
  end

  defp side(%{"ref" => ref} = side) when map_size(side) == 1, do: if(id?(ref), do: {:ok, %{ref: ref}}, else: :error)
  defp side(_side), do: :error

  defp id?(value), do: is_binary(value) and value != ""

  defp refs(nil), do: {:ok, []}

  defp refs(refs) when is_list(refs) do
    if Enum.all?(refs, &is_binary/1), do: {:ok, Enum.uniq(refs)}, else: {:error, "`refs` must list event ids"}
  end

  defp refs(_refs), do: {:error, "`refs` must list event ids"}

  defp ask_person(nil), do: {:ok, nil}

  defp ask_person(%{} = ask) do
    with {:ok, fields} <- question_fields(ask),
         {:ok, options} <- options(Map.get(ask, "options")) do
      {:ok, Map.put(fields, :options, options)}
    end
  end

  defp ask_person(_ask), do: {:error, "`ask_person` must be an object or null"}

  defp question_fields(ask) do
    Enum.reduce_while(@question_fields, {:ok, %{}}, fn field, {:ok, fields} ->
      case Map.get(ask, field) do
        value when is_binary(value) and value != "" -> {:cont, {:ok, Map.put(fields, String.to_existing_atom(field), value)}}
        _missing -> {:halt, {:error, "`ask_person.#{field}` must be a non-blank string"}}
      end
    end)
  end

  defp options(options) when is_list(options) and length(options) in 2..4 do
    Enum.reduce_while(options, {:ok, []}, fn
      %{"label" => label, "effect" => effect} = option, {:ok, acc} when is_binary(label) and is_binary(effect) ->
        {:cont, {:ok, acc ++ [%{label: label, effect: effect, recommended: Map.get(option, "recommended") == true}]}}

      _option, _acc ->
        {:halt, {:error, "each of `ask_person.options` needs a `label` and an `effect`"}}
    end)
  end

  defp options(_options), do: {:error, "`ask_person.options` must list two to four options"}
end
