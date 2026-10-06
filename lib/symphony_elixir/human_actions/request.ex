defmodule SymphonyElixir.HumanActions.Request do
  @moduledoc """
  The `## Action needed:` comment that records a request for a human on an issue.

  `linear_request_human_action` posts it and moves the issue to the Human Review state
  (`SymphonyElixir.HumanReview`), and a supervisor or a person can write the same comment by hand.
  It is how Symphony finds the request again on every poll and after a restart:

      ## Action needed: Add the release signing secrets

      **Why:** Every Release run on `main` fails at the signing step without them.
      **Unblocks:** the Release workflow on `main`
      **Time:** about 10 min

      **Steps:**
      1. Open the repository's Settings → Secrets and variables → Actions.
      2. Add `MACOS_CERTIFICATE` with the base64 of the Developer ID certificate.

  Only the heading is required; `parse/1` reads whatever else is there. A request stays open until
  its issue moves on: after the request, the issue leaves a state outside `issues.states.active`
  (`Human Review` to `Merging`, `Rework` or `Done`, `Backlog` back to `Todo`). The request's own
  move to Human Review comes from an active state, so it keeps the request open.

  A request is also closed once it is withdrawn: a reply under it that starts with
  `## Action withdrawn`, which `linear_withdraw_human_action` posts with its reason.
  """

  @heading "## Action needed:"
  @withdrawn_heading "## Action withdrawn"
  @field_pattern ~r/^\*\*(Why|Unblocks|Time):\*\*\s*(.*)$/i
  @steps_marker ~r/^\*\*Steps:\*\*\s*$/i
  @list_item ~r/^\s*(?:\d+[.)]|[-*])\s+(?:\[[ xX]\]\s+)?(.+)$/
  @minutes ~r/(\d+)\s*min/i

  @typedoc "A parsed request. `created_at` is the comment's creation time."
  @type t :: %{
          title: String.t(),
          why: String.t() | nil,
          unblocks: String.t() | nil,
          est_minutes: pos_integer() | nil,
          steps: [String.t()],
          created_at: DateTime.t() | nil
        }

  @doc "The heading that starts a request comment."
  @spec heading() :: String.t()
  def heading, do: @heading

  @doc """
  Renders a request comment. `state` is the state the request moves the issue to, named in the
  closing line so whoever reads the comment knows how to mark it done.
  """
  @spec render(map(), String.t()) :: String.t()
  def render(%{title: title, why: why, steps: steps} = request, state) do
    fields =
      [
        {"Why", why},
        {"Unblocks", Map.get(request, :unblocks)},
        {"Time", minutes_text(Map.get(request, :est_minutes))}
      ]
      |> Enum.reject(fn {_name, value} -> blank?(value) end)
      |> Enum.map(fn {name, value} -> "**#{name}:** #{one_line(value)}" end)

    step_lines = steps |> Enum.with_index(1) |> Enum.map(fn {step, index} -> "#{index}. #{one_line(step)}" end)

    Enum.join(
      [
        "#{@heading} #{one_line(title)}",
        "",
        Enum.join(fields, "\n"),
        "",
        "**Steps:**",
        Enum.join(step_lines, "\n"),
        "",
        "_Symphony lists this in the project update until this issue moves on. Once it is done, move the issue out of #{state}._"
      ],
      "\n"
    )
  end

  @doc "Renders the reply that withdraws a request, with the reason."
  @spec render_withdrawal(String.t()) :: String.t()
  def render_withdrawal(reason), do: "#{@withdrawn_heading}\n\n#{String.trim(reason)}"

  @doc "Whether a comment body withdraws the request it replies to."
  @spec withdrawal?(String.t() | nil) :: boolean()
  def withdrawal?(body) when is_binary(body), do: body |> String.trim_leading() |> String.starts_with?(@withdrawn_heading)
  def withdrawal?(_body), do: false

  @doc "Parses a comment body; nil unless it starts with the request heading."
  @spec parse(String.t() | nil) :: t() | nil
  def parse(body), do: parse(body, nil)

  @doc "Parses a comment body created at `created_at`; nil unless it starts with the request heading."
  @spec parse(String.t() | nil, DateTime.t() | nil) :: t() | nil
  def parse(body, created_at) when is_binary(body) do
    case body |> String.trim() |> String.split("\n") do
      [@heading <> title | lines] -> parse_lines(String.trim(title), lines, created_at)
      _lines -> nil
    end
  end

  def parse(_body, _created_at), do: nil

  defp parse_lines("", _lines, _created_at), do: nil

  defp parse_lines(title, lines, created_at) do
    lines = Enum.map(lines, &String.trim_trailing/1)
    fields = for line <- lines, [_, name, value] <- [Regex.run(@field_pattern, line)], into: %{}, do: {String.downcase(name), String.trim(value)}

    %{
      title: title,
      why: present(fields["why"]),
      unblocks: present(fields["unblocks"]),
      est_minutes: minutes(fields["time"]),
      steps: steps(lines),
      created_at: created_at
    }
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
