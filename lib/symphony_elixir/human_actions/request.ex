defmodule SymphonyElixir.HumanActions.Request do
  @moduledoc """
  The `## Decision needed:` comment that records a request for a human on an issue.

  `linear_request_human_action` posts it. It leaves the issue in its phase and sets the
  `Needs Decision` hold (`SymphonyElixir.NeedsDecisionHold`), and `render_hold/2` renders that
  comment. A person only ever gets a decision: one question and two to four options, each with what
  it does, one of them recommended. Never a runbook of steps: a check an agent can't run belongs to
  CI or a QA playbook instead.

      ## Decision needed: Close TP-612 as a duplicate of TP-668

      **Question:** TP-668 (Company search) already shipped what TP-612 (Search companies by name) asks for. Close TP-612 as its duplicate?
      **Why:** Nothing is left to build. The ticket only waits on this call.
      **If unanswered:** TP-612 stays open and holds a slot on the board.

      **Options:**
      1. **Close as duplicate** (recommended): TP-612 moves to Done, linked to TP-668.
         - Good: The board shows only work that is left.
      2. **Keep it open**: the next run looks for what TP-668 missed.
         - Cost: A run spends time on work that is likely done.

      **Why recommended:** TP-668 covers every line of TP-612's description.

  The fields are written in the Director's words (`docs/standards/decision-writing.md`). Each option
  carries up to three trade-offs, indented under it as `- Good:`, `- Cost:` or `- Risk:` lines.

  Symphony finds the request again on every poll and after a restart. It also reads the older
  `## Action needed:` comment, with its `**Steps:**` list, which a supervisor or a person may still
  write by hand. Only the heading is required; `parse/1` reads whatever else is there. A request
  is closed once a person answers it — see `SymphonyElixir.HumanActions.Collector.open_requests/2` —
  or once a person moves its issue on: after the request, the issue leaves a state outside
  `issues.states.active` (`Code Review` to `Rework`, `Backlog` back to `Todo`).

  A request is also closed once it is withdrawn: a reply under it that starts with
  `## Action withdrawn`, which `linear_withdraw_human_action` posts with its reason.
  """

  @decision_heading "## Decision needed:"
  @action_heading "## Action needed:"
  @withdrawn_heading "## Action withdrawn"
  # `**Time:**` is an older comment's estimate: it still reads as a field, so it never reads as a
  # step, and is ignored.
  @field_pattern ~r/^\*\*(Question|Why|If unanswered|Why recommended|Unblocks|Time):\*\*\s*(.*)$/i
  @steps_marker ~r/^\*\*Steps:\*\*\s*$/i
  @options_marker ~r/^\*\*Options:\*\*\s*$/i
  @list_item ~r/^\s*(?:\d+[.)]|[-*])\s+(?:\[[ xX]\]\s+)?(.+)$/
  @tradeoff_item ~r/^\s+[-*]\s+(Good|Cost|Risk):\s*(.+)$/i
  @tradeoff_kinds ~w(good cost risk)

  @typedoc "What picking an option gains (`good`), costs (`cost`) or risks (`risk`), in one line."
  @type tradeoff :: %{kind: String.t(), text: String.t()}

  @typedoc """
  One option of a decision: what it is called, what it does, whether it is the recommended one, and
  up to three trade-offs.
  """
  @type option :: %{
          required(:label) => String.t(),
          required(:effect) => String.t(),
          optional(:recommended) => boolean(),
          optional(:tradeoffs) => [tradeoff()]
        }

  @typedoc """
  A parsed request. `created_at` is the comment's creation time. A decision has its `question`
  and its `options`, one rendered line each, with each option's trade-offs at the same index of
  `tradeoffs`; a hand-written `## Action needed:` request has `steps` instead.
  """
  @type t :: %{
          title: String.t(),
          question: String.t() | nil,
          options: [String.t()],
          tradeoffs: [[tradeoff()]],
          why: String.t() | nil,
          if_unanswered: String.t() | nil,
          recommendation_reason: String.t() | nil,
          unblocks: String.t() | nil,
          steps: [String.t()],
          created_at: DateTime.t() | nil
        }

  @doc "The trade-off kinds an option may carry: `good`, `cost` and `risk`."
  @spec tradeoff_kinds() :: [String.t()]
  def tradeoff_kinds, do: @tradeoff_kinds

  @doc "The headings that start a request comment: the decision Symphony posts, and the older hand-written action."
  @spec headings() :: [String.t()]
  def headings, do: [@decision_heading, @action_heading]

  @doc """
  Renders a decision request, which sets the `Needs Decision` hold instead of moving the issue: the
  closing line says the ticket stays in `state` and names the
  Inbox as the other way to answer, so whoever reads the comment knows the ticket is not going
  anywhere while it waits.
  """
  @spec render_hold(map(), String.t() | nil) :: String.t()
  def render_hold(request, state) do
    state = if is_binary(state) and String.trim(state) != "", do: state, else: "its phase"

    render_request(
      request,
      "_Reply with the option you pick, or answer it in the Symphony Inbox: the ticket stays in #{state} until the decision is recorded. Symphony lists this in the project update until then._"
    )
  end

  defp render_request(%{title: title, question: question, why: why, options: options} = request, closing) do
    fields =
      [
        {"Question", question},
        {"Why", why},
        {"If unanswered", Map.get(request, :if_unanswered)},
        {"Unblocks", Map.get(request, :unblocks)}
      ]
      |> fields()

    option_lines = options |> Enum.with_index(1) |> Enum.map(fn {option, index} -> "#{index}. #{option_text(option)}" end)

    [
      "#{@decision_heading} #{one_line(title)}",
      "",
      Enum.join(fields, "\n"),
      "",
      "**Options:**",
      Enum.join(option_lines, "\n"),
      "",
      recommendation_line(request),
      closing
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp fields(fields) do
    fields
    |> Enum.reject(fn {_name, value} -> blank?(value) end)
    |> Enum.map(fn {name, value} -> "**#{name}:** #{one_line(value)}" end)
  end

  defp recommendation_line(request) do
    case fields([{"Why recommended", Map.get(request, :recommendation_reason)}]) do
      [] -> []
      [line] -> [line, ""]
    end
  end

  defp option_text(%{label: label, effect: effect} = option) do
    marker = if Map.get(option, :recommended), do: " (recommended)"
    Enum.join(["**#{option_label(label)}**#{marker}: #{one_line(effect)}" | tradeoff_lines(Map.get(option, :tradeoffs))], "\n")
  end

  # Each trade-off is a sub-item of its option, so the option list still reads as one numbered list.
  defp tradeoff_lines(tradeoffs) when is_list(tradeoffs) do
    for %{kind: kind, text: text} <- tradeoffs, not blank?(text), do: "   - #{String.capitalize(kind)}: #{one_line(text)}"
  end

  defp tradeoff_lines(_tradeoffs), do: []

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
      options: Enum.map(options, &elem(&1, 0)),
      tradeoffs: Enum.map(options, &elem(&1, 1)),
      why: present(fields["why"]),
      if_unanswered: present(fields["if unanswered"]),
      recommendation_reason: present(fields["why recommended"]),
      unblocks: present(fields["unblocks"]),
      steps: steps,
      created_at: created_at
    }
  end

  # The list items after `**Options:**`, as rendered, each with the trade-offs indented under it.
  defp options(lines) do
    lines
    |> Enum.drop_while(&(not Regex.match?(@options_marker, &1)))
    |> Enum.drop(1)
    |> Enum.reduce([], &option_line/2)
    |> Enum.reverse()
    |> Enum.map(fn {option, tradeoffs} -> {option, Enum.reverse(tradeoffs)} end)
  end

  defp option_line(line, [{option, tradeoffs} | rest] = acc) do
    case Regex.run(@tradeoff_item, line) do
      [_, kind, text] -> [{option, [%{kind: String.downcase(kind), text: String.trim(text)} | tradeoffs]} | rest]
      nil -> option_item(line, acc)
    end
  end

  defp option_line(line, []), do: option_item(line, [])

  defp option_item(line, acc) do
    case Regex.run(@list_item, line) do
      [_, item] -> [{String.trim(item), []} | acc]
      nil -> acc
    end
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

  @doc "A pull request as a request names it, `PR #448`; nil for anything but a pull request URL."
  @spec pull_request(String.t() | nil) :: String.t() | nil
  def pull_request(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_, number] -> "PR ##{number}"
      nil -> nil
    end
  end

  def pull_request(_url), do: nil

  @doc "The title as compared for duplicates: trimmed, lower case, single spaces."
  @spec normalize_title(String.t()) :: String.t()
  def normalize_title(title), do: title |> one_line() |> String.downcase()

  @doc "Collapses text to one trimmed line, so a field cannot add headings or break the layout."
  @spec one_line(String.t()) :: String.t()
  def one_line(text), do: text |> String.split() |> Enum.join(" ") |> String.trim_leading("#") |> String.trim()

  defp after?(%DateTime{} = at, %DateTime{} = created_at), do: DateTime.compare(at, created_at) == :gt
  defp after?(_at, _created_at), do: true

  defp present(""), do: nil
  defp present(value), do: value

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
