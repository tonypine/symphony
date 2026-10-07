defmodule SymphonyElixir.HumanActions.Request do
  @moduledoc """
  The `## Decision needed:` comment that records a request for a human on an issue.

  `linear_request_human_action` posts it and moves the issue to the Human Review state
  (`SymphonyElixir.HumanReview`). A person only ever gets a decision: one question and two to four
  options, each with what it does, one of them recommended. Never a runbook of steps: a check an
  agent can't run goes to the supervisor as a `## Supervisor check` in `In Review` instead.

      ## Decision needed: Close TP-612 as a duplicate of TP-668

      **Question:** TP-668 already shipped this work on `main`. Close TP-612 as its duplicate?
      **Why:** Nothing is left to build; the ticket only waits on this call.
      **Time:** about 2 min

      **Options:**
      1. **Close as duplicate** (recommended): TP-612 moves to Done, linked to TP-668.
      2. **Keep it open**: the next run looks for what TP-668 missed.

  Symphony finds the request again on every poll and after a restart. It also reads the older
  `## Action needed:` comment, with its `**Steps:**` list, which a supervisor or a person may still
  write by hand. Only the heading is required; `parse/1` reads whatever else is there. A request
  stays open until its issue moves on: after the request, the issue leaves a state outside
  `issues.states.active` (`Human Review` to `Merging`, `Rework` or `Done`, `Backlog` back to
  `Todo`). The tool moves the issue to Human Review before it posts the comment, so that move keeps
  the request open whatever state the issue came from.

  A request is also closed once it is withdrawn: a reply under it that starts with
  `## Action withdrawn`, which `linear_withdraw_human_action` posts with its reason.
  """

  @decision_heading "## Decision needed:"
  @action_heading "## Action needed:"
  @withdrawn_heading "## Action withdrawn"
  @field_pattern ~r/^\*\*(Question|Why|Unblocks|Time):\*\*\s*(.*)$/i
  @steps_marker ~r/^\*\*Steps:\*\*\s*$/i
  @options_marker ~r/^\*\*Options:\*\*\s*$/i
  @list_item ~r/^\s*(?:\d+[.)]|[-*])\s+(?:\[[ xX]\]\s+)?(.+)$/
  @minutes ~r/(\d+)\s*min/i

  @typedoc "One option of a decision: what it is called, what it does, and whether it is the recommended one."
  @type option :: %{label: String.t(), effect: String.t(), recommended: boolean()}

  @typedoc """
  A parsed request. `created_at` is the comment's creation time. A decision has its `question`
  and its `options`, one rendered line each; a hand-written `## Action needed:` request has
  `steps` instead.
  """
  @type t :: %{
          title: String.t(),
          question: String.t() | nil,
          options: [String.t()],
          why: String.t() | nil,
          unblocks: String.t() | nil,
          est_minutes: pos_integer() | nil,
          steps: [String.t()],
          created_at: DateTime.t() | nil
        }

  @doc "The headings that start a request comment: the decision Symphony posts, and the older hand-written action."
  @spec headings() :: [String.t()]
  def headings, do: [@decision_heading, @action_heading]

  @doc """
  Renders a decision request. `state` is the state the request moves the issue to, named in the
  closing line so whoever reads the comment knows how to answer it.
  """
  @spec render(map(), String.t()) :: String.t()
  def render(%{title: title, question: question, why: why, options: options} = request, state) do
    fields =
      [
        {"Question", question},
        {"Why", why},
        {"Unblocks", Map.get(request, :unblocks)},
        {"Time", minutes_text(Map.get(request, :est_minutes))}
      ]
      |> Enum.reject(fn {_name, value} -> blank?(value) end)
      |> Enum.map(fn {name, value} -> "**#{name}:** #{one_line(value)}" end)

    option_lines = options |> Enum.with_index(1) |> Enum.map(fn {option, index} -> "#{index}. #{option_text(option)}" end)

    Enum.join(
      [
        "#{@decision_heading} #{one_line(title)}",
        "",
        Enum.join(fields, "\n"),
        "",
        "**Options:**",
        Enum.join(option_lines, "\n"),
        "",
        "_Reply with the option you pick, then move the issue out of #{state}. Symphony lists this in the project update until the issue moves on._"
      ],
      "\n"
    )
  end

  defp option_text(%{label: label, effect: effect} = option) do
    marker = if Map.get(option, :recommended), do: " (recommended)"
    "**#{option_label(label)}**#{marker}: #{one_line(effect)}"
  end

  # A label stays plain text inside the bold markers.
  defp option_label(label), do: label |> one_line() |> String.replace("*", "")

  @doc "Renders the reply that withdraws a request, with the reason."
  @spec render_withdrawal(String.t()) :: String.t()
  def render_withdrawal(reason), do: "#{@withdrawn_heading}\n\n#{String.trim(reason)}"

  @doc "Whether a comment body withdraws the request it replies to."
  @spec withdrawal?(String.t() | nil) :: boolean()
  def withdrawal?(body) when is_binary(body), do: body |> String.trim_leading() |> String.starts_with?(@withdrawn_heading)
  def withdrawal?(_body), do: false

  @doc "Parses a comment body; nil unless it starts with a request heading."
  @spec parse(String.t() | nil) :: t() | nil
  def parse(body), do: parse(body, nil)

  @doc "Parses a comment body created at `created_at`; nil unless it starts with a request heading."
  @spec parse(String.t() | nil, DateTime.t() | nil) :: t() | nil
  def parse(body, created_at) when is_binary(body) do
    case body |> String.trim() |> String.split("\n") do
      [@decision_heading <> title | lines] -> parse_lines(:decision, String.trim(title), lines, created_at)
      [@action_heading <> title | lines] -> parse_lines(:action, String.trim(title), lines, created_at)
      _lines -> nil
    end
  end

  def parse(_body, _created_at), do: nil

  defp parse_lines(_kind, "", _lines, _created_at), do: nil

  defp parse_lines(kind, title, lines, created_at) do
    lines = Enum.map(lines, &String.trim_trailing/1)
    fields = for line <- lines, [_, name, value] <- [Regex.run(@field_pattern, line)], into: %{}, do: {String.downcase(name), String.trim(value)}

    {options, steps} =
      case kind do
        :decision -> {options(lines), []}
        :action -> {[], steps(lines)}
      end

    %{
      title: title,
      question: present(fields["question"]),
      options: options,
      why: present(fields["why"]),
      unblocks: present(fields["unblocks"]),
      est_minutes: minutes(fields["time"]),
      steps: steps,
      created_at: created_at
    }
  end

  # The list items after `**Options:**`, as rendered.
  defp options(lines) do
    after_marker = lines |> Enum.drop_while(&(not Regex.match?(@options_marker, &1))) |> Enum.drop(1)
    for line <- after_marker, [_, item] <- [Regex.run(@list_item, line)], do: String.trim(item)
  end

  @doc "The steps in free text, such as a human task's description, read as in a request."
  @spec text_steps(String.t() | nil) :: [String.t()]
  def text_steps(text) when is_binary(text), do: text |> String.split("\n") |> Enum.map(&String.trim_trailing/1) |> steps()
  def text_steps(_text), do: []

  # The list items after `**Steps:**`, or anywhere when there is no marker. A hand-written request
  # without a list keeps its free text as one step.
  defp steps(lines) do
    body_lines =
      case Enum.split_while(lines, &(not Regex.match?(@steps_marker, &1))) do
        {_before, [_marker | after_marker]} -> after_marker
        {all, []} -> all
      end

    items = for line <- body_lines, [_, item] <- [Regex.run(@list_item, line)], do: String.trim(item)

    if items != [] do
      items
    else
      body_lines
      |> Enum.reject(&(Regex.match?(@field_pattern, &1) or String.starts_with?(&1, "_")))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> case do
        [] -> []
        text -> [Enum.join(text, " ")]
      end
    end
  end

  @doc """
  Whether a request is still open: no state change after it left a state outside `active_states`.
  """
  @spec open?(t(), [map()], [String.t()]) :: boolean()
  def open?(%{created_at: created_at}, state_changes, active_states) do
    active = MapSet.new(active_states, &normalize/1)

    not Enum.any?(state_changes, fn %{at: at, from: from} ->
      is_binary(from) and not MapSet.member?(active, normalize(from)) and after?(at, created_at)
    end)
  end

  @doc "The title as compared for duplicates: trimmed, lower case, single spaces."
  @spec normalize_title(String.t()) :: String.t()
  def normalize_title(title), do: title |> one_line() |> String.downcase()

  @doc "Collapses text to one trimmed line, so a field cannot add headings or break the layout."
  @spec one_line(String.t()) :: String.t()
  def one_line(text), do: text |> String.split() |> Enum.join(" ") |> String.trim_leading("#") |> String.trim()

  defp after?(%DateTime{} = at, %DateTime{} = created_at), do: DateTime.compare(at, created_at) == :gt
  defp after?(_at, _created_at), do: true

  defp minutes_text(minutes) when is_integer(minutes), do: "about #{minutes} min"
  defp minutes_text(_minutes), do: nil

  defp minutes(text) when is_binary(text) do
    case Regex.run(@minutes, text) do
      [_, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  defp minutes(_text), do: nil

  defp present(""), do: nil
  defp present(value), do: value

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
