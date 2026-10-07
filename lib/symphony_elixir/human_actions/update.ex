defmodule SymphonyElixir.HumanActions.Update do
  @moduledoc """
  Renders the project update that lists every open human action in a project.

  The format is written for a phone, and so that each action can be done without opening anything
  else:

  - one numbered `###` heading per action, so the list scans on a narrow screen;
  - the line under it says how long it takes and what it unblocks, so the reader can pick what to
    do before reading the rest;
  - the why, then the question and its options for a decision, or the steps of any other action,
    as a numbered list, one per line (no tables, which scroll sideways on a phone);
  - a closing **Done when** line, so it is clear how the action leaves the list;
  - actions on issues in the Human Review state first, since those issues wait on nobody else, then
    quickest first, so a short session clears the small ones;
  - a footer with the list id (a hash of the action keys), which lets Symphony recognise its own
    last update after a restart instead of posting the same list again.

  The health is `atRisk` while anything is open and `onTrack` when nothing is: an open action is a
  risk to the schedule, and Symphony cannot judge more than that, so it never says `offTrack`.
  The whole body goes through `SymphonyElixir.AgentTools.SecretScanner.redact/1` before it is
  posted, so no secret value reaches the update even when an issue or comment holds one.
  """

  alias SymphonyElixir.AgentTools.SecretScanner
  alias SymphonyElixir.HumanActions.{Action, Request}

  @max_actions 25
  @list_id_pattern ~r/list `([0-9a-f]{8})`/

  @doc "The id of a list of actions: the first 8 hex digits of the SHA-256 of its sorted keys."
  @spec list_id([Action.t()]) :: String.t()
  def list_id(actions) do
    keys = actions |> Enum.map(& &1.key) |> Enum.sort() |> Enum.join("\n")
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
  Renders the update body and the secret patterns redacted from it. `states` are the states a
  person reviews in (`SymphonyElixir.HumanReview.review_states/1`), named where the update has
  more actions than it lists.
  """
  @spec render([Action.t()], [String.t()]) :: {String.t(), [atom()]}
  def render(actions, states) do
    sorted = sort(actions)
    {shown, hidden} = Enum.split(sorted, @max_actions)

    sections =
      shown
      |> Enum.with_index(1)
      |> Enum.map(fn {action, index} -> action_section(action, index) end)

    [header(sorted), sections, more(hidden, states), footer(list_id(actions))]
    |> List.flatten()
    |> Enum.join("\n\n")
    |> SecretScanner.redact()
  end

  @doc "Actions in the order an update lists them: Human Review issues first, then quickest first, then by issue."
  @spec sort([Action.t()]) :: [Action.t()]
  def sort(actions), do: Enum.sort_by(actions, &{not &1.human_review, &1.est_minutes || 1_000_000, &1.issue[:identifier], &1.key})

  defp header([]), do: "**Nothing needs you.** Every action from the last update is closed."
  defp header([_action]), do: "**1 action needs you.**"

  defp header(actions) do
    if Enum.any?(actions, & &1.human_review),
      do: "**#{length(actions)} actions need you.** Human Review tickets first, then quickest first.",
      else: "**#{length(actions)} actions need you.** Quickest first."
  end

  defp action_section(%Action{} = action, index) do
    [
      "### #{index}. #{Request.one_line(action.title)}",
      meta_line(action),
      why_line(action.why),
      question_line(action.question),
      numbered_list(action.options),
      numbered_list(action.steps),
      done_line(action.done_when)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp meta_line(%Action{} = action) do
    review = if action.human_review, do: "**#{action.issue.state}** · "
    time = if is_integer(action.est_minutes), do: "**~#{action.est_minutes} min** · "
    "#{review}#{time}#{issue_relation(action)}"
  end

  defp issue_relation(%Action{issue: nil} = action), do: "Unblocks #{Request.one_line(action.unblocks)}"

  defp issue_relation(%Action{kind: :task} = action), do: "Tracked in #{issue_link(action.issue)}"

  defp issue_relation(%Action{unblocks: unblocks} = action) when is_binary(unblocks),
    do: "Unblocks #{issue_link(action.issue)}: #{Request.one_line(unblocks)}"

  defp issue_relation(%Action{} = action), do: "Unblocks #{issue_link(action.issue)} #{Request.one_line(action.issue.title || "")}"

  defp issue_link(%{identifier: identifier, url: url}) when is_binary(url), do: "[#{identifier}](#{url})"
  defp issue_link(%{identifier: identifier}), do: identifier

  defp why_line(why) when is_binary(why), do: "**Why:** #{Request.one_line(why)}"
  defp why_line(_why), do: nil

  defp question_line(question) when is_binary(question), do: "**Decide:** #{Request.one_line(question)}"
  defp question_line(_question), do: nil

  defp numbered_list([]), do: nil

  defp numbered_list(items) do
    items |> Enum.with_index(1) |> Enum.map_join("\n", fn {item, index} -> "#{index}. #{Request.one_line(item)}" end)
  end

  defp done_line(done_when) when is_binary(done_when), do: "**Done when:** #{done_when}"
  defp done_line(_done_when), do: nil

  defp more([], _states), do: []
  defp more(hidden, states), do: "_…and #{length(hidden)} more: see the issues in #{Enum.map_join(states, " and ", &"`#{&1}`")}._"

  defp footer(list_id), do: "---\n_Symphony posts a new update when this list changes · list `#{list_id}`_"
end
