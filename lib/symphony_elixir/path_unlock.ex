defmodule SymphonyElixir.PathUnlock do
  @moduledoc """
  A person's grant that lifts one agent-protected path (`AgentSandboxConfig.workspace_protected_paths/0`)
  for the next agent run of one ticket.

  A person grants it with a decision recorded on the ticket (`SymphonyElixir.Decisions`), in one of
  two ways:

  - By picking an option that carries `unlocks`: a decision request's option names the protected
    paths it unlocks in a field the person never reads (`SymphonyElixir.HumanActions.Request`), and
    its label says in plain words what it allows ("Allow this ticket to change the workflow
    settings file"). The pick, by a reply under the request or in the Inbox, records the option's
    paths with the decision (`picked_paths/2`), and they unlock for the ticket the decision is on.
    Symphony's own question about a PR that changes protected files (rule R18) offers such an
    option, "Allow the change".
  - By a typed grant: a ruling comment or the answer to a decision request that says
    `Unlock <path> for <ticket>`, such as `Decision: Unlock config/settings_ui_exempt.yml for TP-760
    to drop the human_actions.label exemption.` The ticket must be the one the decision is on, so a
    decision copied onto another ticket unlocks nothing there. Backticks, Linear's markdown escapes
    and link wrapping around the path are ignored.

  Either way the path must be on the protected list, or sit in a folder whose files are granted
  one by one (`.github`, `AgentSandboxConfig.file_grant_folders/0`): a grant of
  `.github/workflows/make-all.yml` lifts that file and leaves the rest of `.github` protected. A grant on an alias of a protected folder
  (`.claude/skills`, a symlink to `.agents/skills`) is a grant on the real folder, and lifts it
  under every name (`AgentSandboxConfig.aliases/0`). Each path has a plain description
  (`describe/1`) that a request shows the Director instead of the path.

  The decision is read from the ticket's state, whichever way the Director answered: the Decisions
  section (`SymphonyElixir.Decisions`), and the ticket's answered Questions in its store record
  (`SymphonyElixir.Questions`), whose answer names the option it picked. So a Question answered by
  its id, by its request comment or in the Inbox grants the same paths, even before the section is
  projected into the description the run reads.

  A grant is bound to the ticket, not to one run: each implementation run of the ticket claims its
  grants (`claim/3`) before its session starts, the claim recording in the ticket's store record the
  run that first used each one (`SymphonyElixir.RunStore.claim_path_unlocks/4`), and every later
  run of the ticket (its reworks and CI fixes on the same pull request) keeps the path unlocked.
  Every other ticket keeps the protection. The run's sandbox leaves the path out of its write-deny
  list, its prompt names the path and the decision (`prompt_section/1`), and its `github_sync_base`
  and `github_push_branch` accept the branch's change to it.

  Agents post as the operator's Linear user, so their comment and sub-issue tools refuse text that
  reads as a grant or carries an option's hidden unlocks (`grant_text?/1`), and a reply under a
  request whose options unlock a path.
  """

  require Logger

  alias SymphonyElixir.{AgentSandboxConfig, Decisions, PromptSafety, RunStore, TicketState}
  alias SymphonyElixir.HumanActions.Request

  @grant_pattern ~r/\bunlock\s+(\S+)\s+for\s+([a-z][a-z0-9]*-\d+)\b/iu
  @link_pattern ~r/\[([^\]]*)\]\([^)]*\)/u
  # Quotes and emphasis around the path, and the punctuation that ends its sentence.
  @path_wrapping ~r/^[`'"*]+|[`'"*,;:.!?)]+$/u
  # The hidden line that carries an option's or a decision's unlocks.
  @unlocks_marker ~r/<!--\s*symphony:unlocks\b/iu
  # A negation up to two words before a picked label: `don't allow the change`.
  @negation_pattern ~r/\b(not|never|no|cannot|\w+n['’]t)\s+(\w+\s+){0,2}$/iu
  @number_pick ~r/^(?:option\s*)?#?(\d+)[.):]?$/u
  @prompt_limit 4_000

  @descriptions %{
    "WORKFLOW.md" => "the workflow settings file, which runs commands on your Mac",
    "symphony.yml" => "the repo's Symphony settings",
    "symphony.local.yml" => "this Mac's own Symphony settings for the repo",
    ".claude/settings.json" => "the Claude agent's permission settings",
    ".claude/settings.local.json" => "the Claude agent's permission settings on this Mac",
    ".claude/CLAUDE.md" => "the Claude agent's project instructions",
    ".claude/agents" => "the Claude agent's helper agents",
    ".claude/commands" => "the Claude agent's commands",
    ".claude/hooks" => "the Claude agent's hooks, which run commands on your Mac",
    ".agents/skills" => "the agents' shared guides, also linked from the Claude and Codex agents' folders",
    "mise.toml" => "the tool versions file, which picks the language versions the repo builds with",
    ".tool-versions" => "the older tool versions file",
    ".github" => "the CI workflows and GitHub settings, which decide what merges and how the app is built",
    "config/settings_ui_exempt.yml" => "the list of settings that need no control in the Mac app"
  }

  @typedoc """
  A grant: its `id` (the decision's key and the path), the `decision` that gave it (`D3`, or
  `ruling` before the poll recorded it), the workspace-relative `path` and the decision's `answer`
  (the option picked, for a grant by option).
  """
  @type grant :: %{id: String.t(), decision: String.t(), path: String.t(), answer: String.t()}

  @doc """
  The grants the decisions recorded in `issue`'s description give it, plus the ones its poll-read
  rulings give before the poll writes them there, each once: the paths a picked option unlocks
  (the decision's `unlocks`) and the ones a typed grant names for this issue's own identifier. Only
  a protected path counts.
  """
  @spec grants(map()) :: [grant()]
  def grants(%{identifier: identifier} = issue) when is_binary(identifier) do
    recorded = Decisions.recorded(Map.get(issue, :description))
    recorded_keys = MapSet.new(recorded, & &1.key)

    rulings =
      for %{key: key} = ruling <- List.wrap(Map.get(issue, :rulings)),
          not MapSet.member?(recorded_keys, key),
          do: Map.put(ruling, :id, "ruling")

    decided =
      for decision <- recorded ++ rulings,
          path <- granted_paths(decision.answer, identifier) ++ protected(Map.get(decision, :unlocks)),
          uniq: true,
          do: %{id: "#{decision.key}:#{path}", decision: decision.id, path: path, answer: decision.answer}

    granted = MapSet.new(decided, & &1.path)
    decided ++ Enum.reject(question_grants(issue), &MapSet.member?(granted, &1.path))
  end

  def grants(_issue), do: []

  # The grants the ticket's answered Questions give, read from its store record: an answer whose
  # picked option carries `unlocks` grants those protected paths, however the Director answered
  # it (by the question's id, by its request comment, in the Inbox). Each is labelled with the
  # stored decision that records the answer (keyed by the question or its request comment), else
  # `question`.
  defp question_grants(%{id: issue_id}) when is_binary(issue_id) do
    case RunStore.get_ticket_state(issue_id) do
      %{} = record ->
        record = TicketState.normalize(record)
        labels = decision_labels(record)

        for %{state: :answered, answer: %{option: number, text: text}} = question <- record.questions,
            is_integer(number),
            %{unlocks: unlocks} <- [Enum.at(question.options, number - 1)],
            path <- protected(unlocks),
            uniq: true,
            do: %{id: "#{question.id}:#{path}", decision: question_label(labels, record, question.id), path: path, answer: text}

      _none ->
        []
    end
  end

  defp question_grants(_issue), do: []

  defp decision_labels(record) do
    record
    |> TicketState.decisions()
    |> Enum.uniq_by(& &1.key)
    |> Enum.with_index(1)
    |> Map.new(fn {decision, index} -> {decision.key, "D#{index}"} end)
  end

  defp question_label(labels, record, question_id) do
    Map.get(labels, question_id) || Map.get(labels, request_comment_id(record, question_id)) || "question"
  end

  defp request_comment_id(%{projected: %{comments: %{} = comments}}, question_id),
    do: comments |> Map.get(question_id, %{}) |> Map.get(:comment)

  defp request_comment_id(_record, _question_id), do: nil

  @doc "The protected paths `text` unlocks for the ticket `identifier`."
  @spec granted_paths(String.t() | term(), String.t()) :: [String.t()]
  def granted_paths(text, identifier) when is_binary(text) and is_binary(identifier) do
    for {path, ticket} <- named_grants(text), String.upcase(ticket) == String.upcase(identifier), uniq: true, do: path
  end

  def granted_paths(_text, _identifier), do: []

  @doc """
  Whether `text` reads as a grant that unlocks a protected path for any ticket, or carries the hidden
  line in which an option or a recorded decision names the paths it unlocks.
  """
  @spec grant_text?(String.t() | term()) :: boolean()
  def grant_text?(text) when is_binary(text), do: named_grants(text) != [] or Regex.match?(@unlocks_marker, text)
  def grant_text?(_text), do: false

  @doc """
  The entries of `paths` a grant may name (`AgentSandboxConfig.grantable?/1`), each once, without a
  leading `./`: the protected list, and one path in a folder whose files are granted one by one
  (`.github/workflows/make-all.yml`). An alias of a protected folder (`.claude/skills`) is named by
  its real folder (`.agents/skills`), so a grant on any of its names lifts it under all of them
  (`AgentSandboxConfig.unlocked_entries/1`).
  """
  @spec protected([String.t()] | term()) :: [String.t()]
  def protected(paths) when is_list(paths) do
    for path when is_binary(path) <- paths,
        path = AgentSandboxConfig.real_path(path),
        AgentSandboxConfig.grantable?(path),
        uniq: true,
        do: path
  end

  def protected(_paths), do: []

  @doc "The entries of `paths` that are not on the protected list."
  @spec unprotected([String.t()]) :: [String.t()]
  def unprotected(paths) when is_list(paths) do
    protected = protected(paths)
    Enum.reject(paths, &(is_binary(&1) and AgentSandboxConfig.real_path(&1) in protected))
  end

  @doc """
  What `path` is, in the Director's words, for a request that shows it instead of the path: "the
  workflow settings file, which runs commands on your Mac".
  """
  @spec describe(String.t()) :: String.t()
  def describe(path) do
    path = AgentSandboxConfig.real_path(path)

    cond do
      Map.has_key?(@descriptions, path) -> Map.fetch!(@descriptions, path)
      String.starts_with?(path, ".github/") -> "a CI workflow or GitHub setting, which decides what merges and how the app is built"
      true -> "a file agents may change only with your permission"
    end
  end

  @doc "The descriptions of `paths` (`describe/1`) joined into one phrase: `a; b and c`."
  @spec describe_all([String.t()]) :: String.t()
  def describe_all(paths) do
    case paths |> Enum.map(&describe/1) |> Enum.uniq() do
      [one] -> one
      descriptions -> Enum.join(Enum.drop(descriptions, -1), "; ") <> " and " <> List.last(descriptions)
    end
  end

  @doc """
  The protected paths the option that `answers` pick unlocks, for a decision `request` (a request
  map, a parsed request, or a hold's decision: its `options` and the paths each unlocks,
  `SymphonyElixir.HumanActions.Request.option_unlocks/1`). An answer picks an option by naming its
  label, not just after a negation (`don't allow`), or by its number alone (`2`, `option 2`). Answers
  that pick no option, or more than one, unlock nothing.
  """
  @spec picked_paths(map(), [String.t()]) :: [String.t()]
  def picked_paths(request, answers) when is_map(request) and is_list(answers) do
    unlocks = Request.option_unlocks(request)
    labels = request |> Map.get(:options) |> List.wrap() |> Enum.map(&(&1 |> Request.label() |> plain()))

    case answers |> Enum.flat_map(&picked_indexes(labels, &1)) |> Enum.uniq() do
      [index] -> unlocks |> Enum.at(index) |> protected()
      _none_or_several -> []
    end
  end

  defp picked_indexes(labels, answer) when is_binary(answer) do
    text = plain(answer)

    case Regex.run(@number_pick, text) do
      [_, number] ->
        index = String.to_integer(number) - 1
        if index in 0..(length(labels) - 1)//1, do: [index], else: []

      nil ->
        for {label, index} <- Enum.with_index(labels), label != "", affirmed?(text, label), do: index
    end
  end

  defp picked_indexes(_labels, _answer), do: []

  defp affirmed?(text, label) do
    text
    |> :binary.matches(label)
    |> Enum.any?(fn {start, _length} -> not Regex.match?(@negation_pattern, binary_part(text, 0, start)) end)
  end

  defp plain(text), do: text |> String.replace(~r/[*_`\\]/u, "") |> String.split() |> Enum.join(" ") |> String.downcase()

  # Each `{path, ticket}` the text names, for a path a grant may name.
  defp named_grants(text) do
    text = text |> String.replace("\\", "") |> String.replace(@link_pattern, "\\1")

    for [_match, named, ticket] <- Regex.scan(@grant_pattern, text),
        path <- [named |> String.replace(@path_wrapping, "") |> AgentSandboxConfig.real_path()],
        AgentSandboxConfig.grantable?(path),
        do: {path, ticket}
  end

  @doc """
  Records that the run `opts[:run_id]` uses the grants `issue` has, and returns them all: a grant is
  bound to the ticket, so every run of it keeps the path unlocked, and the store records the run
  that first used each one. A store that can't record the claim unlocks nothing.
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
          {:ok, _first_used} ->
            Enum.each(grants, &Logger.info("Unlocked a protected path for the run issue_identifier=#{issue.identifier} path=#{&1.path} decision=#{&1.decision}"))
            grants

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
    paths = Enum.map(grants, &"- `#{&1.path}`#{also_named(&1.path)}, by #{decision_name(&1.decision)}")
    answers = grants |> Enum.map(& &1.answer) |> Enum.uniq() |> Enum.join("\n")

    Enum.join(
      [
        "Protected paths unlocked for this run:",
        "",
        "A person's decision on this ticket unlocks these agent-protected paths for this ticket's runs. You may edit them for what the decision asks, and `github_sync_base` and `github_push_branch` accept this branch's change to them. Commit and push the change.",
        ""
      ] ++ paths ++ ["", "What the decision says:", PromptSafety.linear_block(answers, "linear_issue_decisions", @prompt_limit)],
      "\n"
    )
  end

  defp also_named(path) do
    case AgentSandboxConfig.aliases(path) do
      [] -> ""
      aliases -> " (also #{Enum.map_join(aliases, " and ", &"`#{&1}`")})"
    end
  end

  defp decision_name("ruling"), do: "a ruling in a comment"
  defp decision_name("question"), do: "a person's answer to a question on this ticket"
  defp decision_name(id), do: "decision #{id}"
end
