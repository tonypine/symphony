defmodule SymphonyElixir.HumanActions.Update do
  @moduledoc """
  Renders the project update that lists every open human action in a project.

  The format is written for a phone, and so that each action can be done without opening anything
  else:

  - one numbered `###` heading per action, so the list scans on a narrow screen;
  - the line under it says what it unblocks, so the reader can pick what to do before reading the
    rest;
  - the why and what waits until it is answered, then the question and its options for a decision,
    or the steps of any other action,
    as a numbered list, one per line (no tables, which scroll sideways on a phone);
  - a closing **Done when** line, so it is clear how the action leaves the list;
  - ordered by issue, so the list stays put between updates;
  - a footer with the list id (a hash of the action keys), which lets Symphony recognise its own
    last update after a restart instead of posting the same list again.

  Once a status report exists (`SymphonyElixir.Reports`), the update is the newest report instead
  (`render_report/3`): its sentences, each followed by links to the Linear issues of the tickets
  whose events it cites, then the same footer. Its list id also hashes the report's id, so a new
  report is posted as a new update.

  The health is `atRisk` while anything is open and `onTrack` when nothing is: an open action is a
  risk to the schedule, and Symphony cannot judge more than that, so it never says `offTrack`.
  The whole body goes through `SymphonyElixir.AgentTools.SecretScanner.redact/1` before it is
  posted, so no secret value reaches the update even when an issue or comment holds one.
  """

  alias SymphonyElixir.AgentTools.SecretScanner
  alias SymphonyElixir.HumanActions.{Action, Request}
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.TicketEvents.Event

  @max_actions 25
  @list_id_pattern ~r/list `([0-9a-f]{8})`/

  @typedoc "A ticket a report cites: its identifier and its Linear issue's URL when known."
  @type cited :: %{identifier: String.t(), url: String.t() | nil}

  @doc """
  The id of a list of actions: the first 8 hex digits of the SHA-256 of its sorted keys, with the
  key `report:<id>` of the report the update carries, when it carries one.
  """
  @spec list_id([Action.t()], Event.t() | nil) :: String.t()
  def list_id(actions, report \\ nil) do
    report_keys = if report, do: ["report:" <> report.id], else: []
    keys = actions |> Enum.map(& &1.key) |> Enum.concat(report_keys) |> Enum.sort() |> Enum.join("\n")
    :sha256 |> :crypto.hash(keys) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  @doc "The list id in the footer of an update Symphony posted, or nil for any other update."
  @spec list_id_from_body(String.t() | nil) :: String.t() | nil
  def list_id_from_body(body) when is_binary(body) do
    case Regex.run(@list_id_pattern, body) do
      [_, list_id] -> list_id
      nil -> nil
    end
  end

  def list_id_from_body(_body), do: nil

  @doc "The project health an update with these actions sets."
  @spec health([Action.t()]) :: String.t()
  def health([]), do: "onTrack"
  def health(_actions), do: "atRisk"

  @doc """
  Renders the update body and the secret patterns redacted from it.
  """
  @spec render([Action.t()]) :: {String.t(), [atom()]}
  def render(actions) do
    sorted = sort(actions)
    {shown, hidden} = Enum.split(sorted, @max_actions)

    sections =
      shown
      |> Enum.with_index(1)
      |> Enum.map(fn {action, index} -> action_section(action, index) end)

    [header(sorted), sections, more(hidden), footer(list_id(actions))]
    |> List.flatten()
    |> Enum.join("\n\n")
    |> SecretScanner.redact()
  end

  @doc """
  Renders the update as the newest `report`: its period, each sentence on its own line followed by
  the links to the tickets its citations name (`cited`, by event id), then the footer with the list
  id of `actions` and the report. Returns the body and the secret patterns redacted from it.
  """
  @spec render_report(Event.t(), [Action.t()], %{String.t() => cited()}) :: {String.t(), [atom()]}
  def render_report(%Event{payload: payload} = report, actions, cited) do
    citations = Map.new(payload.citations, &{citation_field(&1, :sentence), citation_field(&1, :events) || []})

    lines =
      payload.sentences
      |> Enum.with_index()
      |> Enum.map(fn {sentence, index} -> sentence <> links(Map.get(citations, index, []), cited) end)

    [report_header(payload), lines, footer(list_id(actions, report))]
    |> List.flatten()
    |> Enum.join("\n\n")
    |> SecretScanner.redact()
  end

  defp citation_field(citation, key), do: Map.get(citation, key) || Map.get(citation, Atom.to_string(key))

  defp report_header(%{period: period}) do
    from = period_time(citation_field(period, :from))
    to = period_time(citation_field(period, :to))
    "**Symphony's status report, #{from} to #{to} UTC**"
  end

  defp period_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%Y-%m-%d %H:%M")
      {:error, _reason} -> iso
    end
  end

  # The tickets of a sentence's cited events, once each, as Linear links.
  defp links(event_ids, cited) do
    case event_ids |> Enum.flat_map(&List.wrap(Map.get(cited, &1))) |> Enum.uniq_by(& &1.identifier) do
      [] -> ""
      tickets -> " (" <> Enum.map_join(tickets, ", ", &issue_link/1) <> ")"
    end
  end

  @doc "Actions in the order an update lists them: by issue, then by key."
  @spec sort([Action.t()]) :: [Action.t()]
  def sort(actions), do: Enum.sort_by(actions, &{&1.issue[:identifier], &1.key})

  defp header([]), do: "**Nothing needs you.** Every action from the last update is closed."
  defp header([_action]), do: "**1 action needs you.**"

  defp header(actions), do: "**#{length(actions)} actions need you.**"

  defp action_section(%Action{} = action, index) do
    [
      "### #{index}. #{Request.one_line(action.title)}",
      meta_line(action),
      why_line(action.why),
      if_unanswered_line(action.if_unanswered),
      question_line(action.question),
      numbered_list(action.options),
      numbered_list(action.steps),
      done_line(action.done_when)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp meta_line(%Action{} = action), do: issue_relation(action)

  defp issue_relation(%Action{issue: nil} = action), do: "Unblocks #{Request.one_line(action.unblocks)}"

  defp issue_relation(%Action{unblocks: unblocks} = action) when is_binary(unblocks),
    do: "Unblocks #{issue_link(action.issue)}: #{Request.one_line(unblocks)}"

  defp issue_relation(%Action{} = action), do: "Unblocks #{issue_link(action.issue)} #{Request.one_line(action.issue.title || "")}"

  defp issue_link(%{identifier: identifier, url: url}) when is_binary(url), do: "[#{identifier}](#{url})"
  defp issue_link(%{identifier: identifier}), do: identifier

  defp why_line(why) when is_binary(why), do: "**Why:** #{Request.one_line(why)}"
  defp why_line(_why), do: nil

  defp if_unanswered_line(text) when is_binary(text), do: "**If unanswered:** #{Request.one_line(text)}"
  defp if_unanswered_line(_text), do: nil

  defp question_line(question) when is_binary(question), do: "**Decide:** #{Request.one_line(question)}"
  defp question_line(_question), do: nil

  defp numbered_list([]), do: nil

  defp numbered_list(items) do
    items |> Enum.with_index(1) |> Enum.map_join("\n", fn {item, index} -> "#{index}. #{Request.one_line(item)}" end)
  end

  defp done_line(done_when) when is_binary(done_when), do: "**Done when:** #{done_when}"
  defp done_line(_done_when), do: nil

  defp more([]), do: []
  defp more(hidden), do: "_…and #{length(hidden)} more: see the issues labelled `#{Projector.question_label()}`._"

  defp footer(list_id), do: "---\n_Symphony posts a new update when this list changes · list `#{list_id}`_"
end
