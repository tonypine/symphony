defmodule SymphonyElixir.QaAgent.StepPayload do
  @moduledoc """
  What a stepped QA pass puts on a step's own `step.completed` event instead of a `note`
  (`SymphonyElixir.QaAgent.Steps`): the answer of the step, structured, so the Director reads
  fields and never a wall of text. Every text is bounded and cut, never refused
  (`SymphonyElixir.TicketEvents.Types`):

    * `result/1`: `%{status, expected, actual}` of a check step (walk, design check, wide pass,
      recheck);
    * `plan/2`: `%{checks, skips, summary}` of the plan step: a check per walkthrough brief and per
      gallery entry the plan names, and the steps the plan leaves unrun;
    * `recheck/1`: the briefs the review asks to walk again, each `%{title, do, expect}` and an
      optional `design`; whole trailing briefs are dropped before the list passes its size, then
      the strings are trimmed;
    * `verdict_summary/1`: the review's own summary in plain words;
    * `reason/1`: why a step whose answer Symphony could not take ended `failed`.
  """

  @result_text 1_500
  @title 120
  @check_expect 400
  @instruction 400
  @design 600
  @summary 600
  @reason 300
  @recheck_bytes 6_000
  @max_instructions 12
  @max_checks 40
  @missing "not given"

  @doc "`%{status, expected, actual}` of a check step's `answer`, or nil when it names no status."
  @spec result(map()) :: map() | nil
  def result(%{"status" => status} = answer) when is_binary(status) do
    %{status: status, expected: text(answer["expected"], @result_text), actual: text(answer["actual"], @result_text)}
  end

  def result(_answer), do: nil

  @doc "The plan `answer` as `%{checks, skips, summary}`; `skips` are the `%{title, why}` Symphony leaves unrun because of it."
  @spec plan(map(), [%{title: String.t(), why: String.t()}]) :: map()
  def plan(answer, skips) do
    walk =
      for brief <- list(answer["walk"]), is_map(brief) do
        %{title: check_title(brief), expect: text(brief["expect"], @check_expect)}
      end

    gallery =
      for entry <- list(answer["gallery"]) do
        {name, detail} = if is_map(entry), do: {entry["entry"], entry["why"] || entry["variations"]}, else: {entry, nil}
        %{title: cut("Gallery: #{display(name)}", @title), expect: text(display_list(detail), @check_expect)}
      end

    %{
      checks: Enum.take(walk ++ gallery, @max_checks),
      skips: for(skip <- skips, do: %{title: text(skip.title, @title), why: text(skip.why, @check_expect)}),
      summary: summary_text(answer)
    }
  end

  @doc "The recheck `briefs` as a list of `%{title, do, expect}` (and `design`), within a size the event keeps."
  @spec recheck([term()]) :: [map()]
  def recheck(briefs) do
    briefs
    |> Enum.filter(&is_map/1)
    |> Enum.map(&recheck_brief/1)
    |> fit()
  end

  @doc "The review's plain-words summary, cut, or nil when it gave none."
  @spec verdict_summary(term()) :: String.t() | nil
  def verdict_summary(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> nil
      trimmed -> cut(trimmed, @summary)
    end
  end

  def verdict_summary(_summary), do: nil

  @doc "Why a step ended `failed`, cut to what the event takes."
  @spec reason(String.t()) :: String.t()
  def reason(why), do: text(why, @reason)

  defp recheck_brief(brief) do
    base = %{title: check_title(brief), do: instructions(brief["do"]), expect: text(brief["expect"], @result_text)}

    case brief["design"] do
      design when is_binary(design) -> put_design(base, design)
      _none -> base
    end
  end

  defp put_design(base, design) do
    case String.trim(design) do
      "" -> base
      trimmed -> Map.put(base, :design, cut(trimmed, @design))
    end
  end

  # Whole trailing briefs go first, then what is left is trimmed until it fits.
  defp fit(items) do
    cond do
      size(items) <= @recheck_bytes -> items
      length(items) > 1 -> items |> Enum.drop(-1) |> fit()
      true -> Enum.map(items, &trim/1)
    end
  end

  defp trim(item) do
    trimmed = %{item | do: item.do |> Enum.take(3) |> Enum.map(&cut(&1, 100)), expect: cut(item.expect, 600)}
    if Map.has_key?(trimmed, :design), do: Map.update!(trimmed, :design, &cut(&1, 200)), else: trimmed
  end

  defp size(items), do: items |> Jason.encode!() |> byte_size()

  defp instructions(value) when is_list(value), do: value |> Enum.flat_map(&instructions/1) |> Enum.take(@max_instructions)

  defp instructions(value) when is_binary(value) do
    lines =
      for line <- String.split(value, "\n"),
          line = line |> String.trim() |> String.replace(~r/\A(?:[-*]|\d+[.)])\s+/, ""),
          line != "",
          do: cut(line, @instruction)

    Enum.take(lines, @max_instructions)
  end

  defp instructions(_other), do: []

  defp check_title(brief) do
    number = display(brief["step"])
    where = display(brief["where"])

    title =
      cond do
        number != "" and where != "" -> "Step #{number}: #{where}"
        number != "" -> "Step #{number}"
        where != "" -> where
        true -> "Check"
      end

    cut(title, @title)
  end

  defp summary_text(answer) do
    walk = for brief <- list(answer["walk"]), is_map(brief), do: "- Step #{brief["step"]}: #{brief["where"]}; #{brief["do"]}; expect #{brief["expect"]}"
    gallery = for entry <- list(answer["gallery"]), do: "- #{if is_map(entry), do: entry["entry"], else: entry}"

    [
      "QA plan. Needs the app: #{if answer["needs_app"], do: "yes", else: "no"}.",
      if(walk == [], do: "Walk: nothing.", else: Enum.join(["Walk:" | walk], "\n")),
      if(gallery == [], do: "Gallery: nothing.", else: Enum.join(["Gallery:" | gallery], "\n")),
      "Notes: #{answer["notes"]}"
    ]
    |> Enum.join("\n")
    |> cut(@summary)
  end

  defp list(value), do: List.wrap(value)

  defp display(nil), do: ""
  defp display(value) when is_binary(value), do: String.trim(value)
  defp display(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp display(value), do: Jason.encode!(value)

  defp display_list(values) when is_list(values), do: Enum.map_join(values, ", ", &display/1)
  defp display_list(value), do: value

  # A text the event takes: trimmed, cut to `max`, and never blank.
  defp text(value, max) do
    case display(value) do
      "" -> @missing
      text -> cut(text, max)
    end
  end

  defp cut(text, max), do: if(String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text)
end
