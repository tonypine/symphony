defmodule SymphonyElixir.Conductor.Answer do
  @moduledoc """
  The Conductor's answer (`SymphonyElixir.Conductor`), read from its turn's text and checked against
  its schema: one JSON object with

    * `instructions`: what the next run should focus on, a non-blank string of at most 2,000
      characters;
    * `update`: for the person, a string of at most 900 characters, or null (a blank string reads
      as null);
    * `refs`: the ids of the events the update rests on (optional; only ids the facts carry are kept);
    * `ask_person`: null, or a question to the person: `title`, `question`, `why`, `if_unanswered`,
      `recommendation_reason` and two to four `options`, each with a `label`, an `effect` and
      `recommended` (the request `SymphonyElixir.Questions.ask/3` takes).

  An answer that misses the schema is refused with why, in plain words.
  """

  alias SymphonyElixir.ReviewAgent

  @instructions_max 2_000
  @update_max 900
  @question_fields ~w(title question why if_unanswered recommendation_reason)

  @type t :: %{
          instructions: String.t(),
          update: String.t() | nil,
          refs: [String.t()],
          ask_person: map() | nil
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
  @spec read([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def read(texts) when is_list(texts) do
    texts
    |> Enum.flat_map(&ReviewAgent.json_object_candidates/1)
    |> Enum.reduce_while({:error, "the answer holds no JSON object"}, fn candidate, error ->
      case parse(candidate) do
        {:ok, answer} -> {:halt, {:ok, answer}}
        {:error, _reason} = refused -> {:cont, first_error(error, refused)}
      end
    end)
  end

  defp first_error({:error, "the answer holds no JSON object"}, refused), do: refused
  defp first_error(error, _refused), do: error

  @doc "Checks one JSON object's text against the schema."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    with {:ok, %{} = answer} <- decode(text),
         {:ok, instructions} <- instructions(Map.get(answer, "instructions")),
         {:ok, update} <- update(Map.get(answer, "update")),
         {:ok, refs} <- refs(Map.get(answer, "refs")),
         {:ok, ask_person} <- ask_person(Map.get(answer, "ask_person")) do
      {:ok, %{instructions: instructions, update: update, refs: refs, ask_person: ask_person}}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = answer} -> {:ok, answer}
      {:ok, _other} -> {:error, "the answer is not a JSON object"}
      {:error, _reason} -> {:error, "the answer is not valid JSON"}
    end
  end

  defp instructions(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, "`instructions` is blank"}
      String.length(text) > @instructions_max -> {:error, "`instructions` is over #{@instructions_max} characters"}
      true -> {:ok, text}
    end
  end

  defp instructions(_text), do: {:error, "`instructions` must be a string"}

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
