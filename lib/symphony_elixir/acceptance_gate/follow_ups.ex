defmodule SymphonyElixir.AcceptanceGate.FollowUps do
  @moduledoc """
  Files the acceptance gate's follow-ups (gaps it found outside the ticket) as Backlog sub-issues
  of the judged ticket, through `SymphonyElixir.AgentTools.Linear.create_subissue/3`, as the Auto
  Review parent walkthrough files its gaps. Only an enforced verdict files them (see
  `SymphonyElixir.AcceptanceGate.judge/2`); in `shadow` mode they are listed, not filed.

  At most 3 are filed per verdict. A follow-up an existing ticket covers is not filed: one the
  answer names in `covered_by`, one whose title a ticket of the ticket's family already has (its
  sub-issues, siblings, parent and blockers; titles compare without case), and one the answer
  repeats. When the family can't be read, nothing is filed, so a title is never filed twice.

  Each filed follow-up lists the answer's `acceptance` criteria, plus "CI is green". A criterion
  that only restates the title is dropped, and a follow-up left without one is not filed: its
  criteria must say what a test or a check shows.
  """

  require Logger

  alias SymphonyElixir.AgentTools
  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PromptSafety

  @max_per_verdict 3

  @type status ::
          {:filed, String.t() | nil} | {:covered, String.t() | nil} | :no_acceptance | :over_cap | {:failed, term()}
  @type result :: %{title: String.t(), detail: String.t(), status: status()}

  @doc "How many follow-ups one verdict files at most."
  @spec max_per_verdict() :: pos_integer()
  def max_per_verdict, do: @max_per_verdict

  @doc """
  Files `follow_ups` (the gate answer's `%{title, detail}` items) under `issue` and returns what
  happened to each one, in order. A tracker other than Linear files nothing.
  """
  @spec file(Issue.t(), [map()], String.t(), Schema.t(), keyword()) :: [result()]
  def file(%Issue{} = issue, follow_ups, sha, %Schema{} = settings, opts) do
    follow_ups = Enum.reject(follow_ups, &(&1.title == ""))

    cond do
      follow_ups == [] -> []
      settings.tracker.kind == "linear" -> file_linear(issue, follow_ups, sha, opts)
      true -> Enum.map(follow_ups, &Map.put(&1, :status, {:failed, :tracker_not_linear}))
    end
  end

  defp file_linear(issue, follow_ups, sha, opts) do
    {:ok, registry} = CommentRegistry.start_link()
    context = %{issue: issue, comment_registry: registry}
    linear_opts = Keyword.take(opts, [:linear_client])

    try do
      case AgentTools.Linear.get_related_issues(context, linear_opts) do
        {:ok, tickets} ->
          existing = Map.new(tickets, &{normalize(Map.get(&1, "title")), Map.get(&1, "identifier")})

          follow_ups
          |> Enum.map_reduce({existing, 0}, &file_one(&1, &2, context, issue, sha, linear_opts))
          |> elem(0)

        {:error, reason} ->
          Logger.warning("Acceptance gate could not read the tickets related to #{issue.identifier}, so it filed no follow-up: #{inspect(reason)}")
          Enum.map(follow_ups, &Map.put(&1, :status, {:failed, reason}))
      end
    after
      Agent.stop(registry)
    end
  end

  defp file_one(follow_up, {seen, filed}, context, issue, sha, linear_opts) do
    title = normalize(PromptSafety.linear_issue_title(follow_up.title))
    acceptance = acceptance(follow_up)
    covered_by = Map.get(follow_up, :covered_by)

    cond do
      covered_by ->
        {Map.put(follow_up, :status, {:covered, covered_by}), {seen, filed}}

      Map.has_key?(seen, title) ->
        {Map.put(follow_up, :status, {:covered, Map.fetch!(seen, title)}), {seen, filed}}

      acceptance == [] ->
        {Map.put(follow_up, :status, :no_acceptance), {seen, filed}}

      filed >= @max_per_verdict ->
        {Map.put(follow_up, :status, :over_cap), {seen, filed}}

      true ->
        attrs = %{"title" => follow_up.title, "description" => description(follow_up, acceptance, issue, sha)}

        case AgentTools.Linear.create_subissue(context, attrs, linear_opts) do
          {:ok, response} ->
            identifier = get_in(response, ["data", "issueCreate", "issue", "identifier"])
            Logger.info("Acceptance gate filed follow-up #{identifier} under #{issue.identifier}: #{follow_up.title}")
            {Map.put(follow_up, :status, {:filed, identifier}), {Map.put(seen, title, identifier), filed + 1}}

          {:error, reason} ->
            Logger.warning("Acceptance gate could not file a follow-up under #{issue.identifier}: #{inspect(reason)}")
            {Map.put(follow_up, :status, {:failed, reason}), {seen, filed}}
        end
    end
  end

  # Sub-issue titles come back wrapped as untrusted data, so a follow-up's title is wrapped the
  # same way before the two are compared.
  defp normalize(title) when is_binary(title), do: title |> String.trim() |> String.downcase()
  defp normalize(_title), do: ""

  # The checkable acceptance criteria of `follow_up`: its `acceptance` items without a checklist
  # marker, less the blank ones and the ones that only restate its title (compared without case,
  # punctuation or markdown).
  defp acceptance(follow_up) do
    title = criterion_key(follow_up.title)

    follow_up
    |> Map.get(:acceptance, [])
    |> Enum.map(&(&1 |> String.replace(~r/^\s*[-*+]\s+(\[[ xX]\]\s+)?/, "") |> String.trim()))
    |> Enum.reject(&(criterion_key(&1) in ["", title]))
  end

  defp criterion_key(text), do: text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, " ") |> String.trim()

  defp description(follow_up, acceptance, issue, sha) do
    """
    #{if follow_up.detail != "", do: follow_up.detail, else: follow_up.title}

    Symphony's acceptance gate found this gap outside #{issue.identifier} while judging its PR head `#{String.slice(sha, 0, 12)}`, and filed it here. A person promotes it from Backlog when it is worth doing.

    ## Acceptance criteria

    #{Enum.map_join(acceptance, "\n", &"- [ ] #{&1}")}
    - [ ] CI is green.
    """
  end
end
