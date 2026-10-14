defmodule SymphonyElixir.PathUnlock do
  @moduledoc """
  A person's grant that lifts one agent-protected path (`AgentSandboxConfig.workspace_protected_paths/0`)
  for the next agent run of one ticket.

  A person grants it with a decision recorded on the ticket (`SymphonyElixir.Decisions`): a ruling
  comment or the answer to a decision request that says `Unlock <path> for <ticket>`, such as
  `Decision: Unlock config/settings_ui_exempt.yml for TP-760 to drop the human_actions.label
  exemption.` The path must be on the protected list and the ticket must be the one the decision
  is on, so a decision copied onto another ticket unlocks nothing there. Backticks, Linear's
  markdown escapes and link wrapping around the path are ignored.

  The next implementation run of the ticket claims the grant (`claim/3`) before its session starts:
  the claim is recorded in the ticket's store record (`SymphonyElixir.RunStore.claim_path_unlocks/4`),
  so a grant unlocks its path for that run only, and every later run, and every other ticket, keeps
  the protection. The run's sandbox leaves the path out of its write-deny list, its prompt names
  the path and the decision (`prompt_section/1`), and its `github_sync_base` and
  `github_push_branch` accept the branch's change to it. To unlock the path again a person gives a
  new decision.

  Agents post as the operator's Linear user, so their comment and sub-issue tools refuse text that
  reads as a grant (`grant_text?/1`).
  """

  require Logger

  alias SymphonyElixir.{AgentSandboxConfig, Decisions, PromptSafety, RunStore}

  @grant_pattern ~r/\bunlock\s+(\S+)\s+for\s+([a-z][a-z0-9]*-\d+)\b/iu
  @link_pattern ~r/\[([^\]]*)\]\([^)]*\)/u
  # Quotes and emphasis around the path, and the punctuation that ends its sentence.
  @path_wrapping ~r/^[`'"*]+|[`'"*,;:.!?)]+$/u
  @prompt_limit 4_000

  @typedoc """
  A grant: its `id` (the decision's key and the path), the `decision` that gave it (`D3`, or
  `ruling` before the poll recorded it), the workspace-relative `path` and the decision's `answer`.
  """
  @type grant :: %{id: String.t(), decision: String.t(), path: String.t(), answer: String.t()}

  @doc """
  The grants the decisions recorded in `issue`'s description give it, plus the ones its poll-read
  rulings give before the poll writes them there, each once. Only a protected path, granted for
  this issue's own identifier, counts.
  """
  @spec grants(map()) :: [grant()]
  def grants(%{identifier: identifier} = issue) when is_binary(identifier) do
    recorded = Decisions.recorded(Map.get(issue, :description))
    recorded_keys = MapSet.new(recorded, & &1.key)

    rulings =
      for %{key: key} = ruling <- List.wrap(Map.get(issue, :rulings)),
          not MapSet.member?(recorded_keys, key),
          do: Map.put(ruling, :id, "ruling")

    for decision <- recorded ++ rulings,
        path <- granted_paths(decision.answer, identifier),
        uniq: true,
        do: %{id: "#{decision.key}:#{path}", decision: decision.id, path: path, answer: decision.answer}
  end

  def grants(_issue), do: []

  @doc "The protected paths `text` unlocks for the ticket `identifier`."
  @spec granted_paths(String.t() | term(), String.t()) :: [String.t()]
  def granted_paths(text, identifier) when is_binary(text) and is_binary(identifier) do
    for {path, ticket} <- named_grants(text), String.upcase(ticket) == String.upcase(identifier), uniq: true, do: path
  end

  def granted_paths(_text, _identifier), do: []

  @doc "Whether `text` reads as a grant that unlocks a protected path for any ticket."
  @spec grant_text?(String.t() | term()) :: boolean()
  def grant_text?(text) when is_binary(text), do: named_grants(text) != []
  def grant_text?(_text), do: false

  # Each `{path, ticket}` the text names, for a path on the protected list.
  defp named_grants(text) do
    protected = AgentSandboxConfig.workspace_protected_paths()

    text = text |> String.replace("\\", "") |> String.replace(@link_pattern, "\\1")

    for [_match, named, ticket] <- Regex.scan(@grant_pattern, text),
        path <- [named |> String.replace(@path_wrapping, "") |> String.trim_leading("./")],
        path in protected,
        do: {path, ticket}
  end

  @doc """
  Claims the grants `issue` has that no run used yet for the run `opts[:run_id]`, and returns them.
  A store that can't record the claim unlocks nothing. `opts[:repo_key]` names the store's repo and
  `opts[:run_store]` overrides the store.
  """
  @spec claim(map(), String.t() | nil, keyword()) :: [grant()]
  def claim(issue, repo_key, opts) do
    case grants(issue) do
      [] ->
        []

      grants ->
        store = Keyword.get(opts, :run_store, RunStore)

        case store.claim_path_unlocks(repo_key, issue.id, Enum.map(grants, & &1.id), Keyword.get(opts, :run_id)) do
          {:ok, ids} ->
            claimed = Enum.filter(grants, &(&1.id in ids))
            Enum.each(claimed, &Logger.info("Unlocked a protected path for one run issue_identifier=#{issue.identifier} path=#{&1.path} decision=#{&1.decision}"))
            claimed

          {:error, reason} ->
            Logger.warning("Failed to claim path unlocks; the run keeps every protection issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
            []
        end
    end
  end

  @doc "The paths `grants` unlock, each once."
  @spec paths([grant()]) :: [String.t()]
  def paths(grants), do: grants |> Enum.map(& &1.path) |> Enum.uniq()

  @doc """
  The prompt section telling the run which protected paths it may edit and why, or `nil` when it
  has none.
  """
  @spec prompt_section([grant()]) :: String.t() | nil
  def prompt_section([]), do: nil

  def prompt_section(grants) when is_list(grants) do
    paths = Enum.map(grants, &"- `#{&1.path}`, by #{decision_name(&1.decision)}")
    answers = grants |> Enum.map(& &1.answer) |> Enum.uniq() |> Enum.join("\n")

    Enum.join(
      [
        "Protected paths unlocked for this run:",
        "",
        "A person's decision on this ticket unlocks these agent-protected paths for this run only. You may edit them for what the decision asks, and `github_sync_base` and `github_push_branch` accept this branch's change to them. The next run protects them again, so commit and push the change in this run.",
        ""
      ] ++ paths ++ ["", "What the decision says:", PromptSafety.linear_block(answers, "linear_issue_decisions", @prompt_limit)],
      "\n"
    )
  end

  defp decision_name("ruling"), do: "a ruling in a comment"
  defp decision_name(id), do: "decision #{id}"
end
