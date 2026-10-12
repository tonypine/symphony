defmodule SymphonyElixir.EscalationRules do
  @moduledoc """
  The escalation rules Code Review applies (`SymphonyElixir.CodeReview`), checked without an agent.
  They are the retired acceptance gate's deterministic rules, migrated per the design
  (`docs/design/state-machine.md`, "Escalation rules route or deepen — they never queue"): the
  person rules (`person_rules/0`) need a person and pause the ticket on a Needs Decision hold, and
  the risk rules (`risk_rules/0`) deepen the Code Review run with a second reviewer pass.

  `check/5` returns one reason per rule that triggers, in this order, or `[]`:

    * `:label` - the issue has an `escalate.labels` label (case-insensitive);
    * `:ticket_pattern` - the issue title or description matches an `escalate.ticket_patterns` regex;
    * `:path` - a changed path outside docs and tests matches an `escalate.paths` glob;
    * `:diff_pattern` - an added line matches an `escalate.diff_patterns` regex;
    * `:dependency` - `mix.lock` or `package.json` adds a dependency or bumps a major version
      (`escalate.dependencies: major`), changes any dependency (`any`), or can't be parsed;
    * `:size` - more than `escalate.max_changed_lines` lines change outside docs and tests;
    * `:busy_file` - more than `escalate.busy_files.max_lines` lines change in one busy file.

  Before `:ticket_pattern` matches, each name in the `:review_states` option (`In Review` and
  `issues.states.human_review`, e.g. `Human Review`) is blanked wherever the text names the
  state: bare, backticked, bolded or quoted. The name matches case-sensitively, so a ticket about
  the state doesn't match `human review`, while "needs a human review" still does. Before `state`
  or `states` it matches in any case ("the human review state"). A name right after a request
  ("Needs Human Review", "requires a Human Review") stays, since that asks for one.

  Docs and tests are the globs QA selection skips (`QaAgent.Selection.docs_or_test?/1`).
  A version's major is its first number, or its first two when the first is `0`, so `0.4` to
  `0.5` counts as a major bump. Only a leading version is read, after any `^`, `~`, `>`, `=`,
  `<` or `v`: a value that doesn't start with one (`latest`, a git ref, a URL, a path) counts as
  a major bump whenever it changes.
  """

  alias SymphonyElixir.Config.Escalate
  alias SymphonyElixir.DependencyAudit.{MixParser, NpmParser}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Selection

  @manifests ["mix.lock", "package.json"]
  @person_rules [:label, :ticket_pattern]
  @risk_rules [:path, :diff_pattern, :dependency, :size, :busy_file]

  @typedoc """
  A file the PR changes. `added_lines` are the diff's added lines, without the leading `+`.
  For `mix.lock` and `package.json`, `base` and `head` are the file's content before and after
  the change (nil when the file is added or removed).
  """
  @type changed_file :: %{
          required(:path) => String.t(),
          required(:additions) => non_neg_integer(),
          required(:deletions) => non_neg_integer(),
          optional(:added_lines) => [String.t()],
          optional(:base) => String.t() | nil,
          optional(:head) => String.t() | nil
        }

  @type diff_summary :: %{files: [changed_file()]}

  @type rule :: :label | :ticket_pattern | :path | :diff_pattern | :dependency | :size | :busy_file

  @type reason :: %{rule: rule(), detail: String.t()}

  @doc "The rules that need a person: a match pauses the ticket on a Needs Decision hold."
  @spec person_rules() :: [rule()]
  def person_rules, do: @person_rules

  @doc "The risk rules: a match deepens the Code Review run instead of routing anywhere."
  @spec risk_rules() :: [rule()]
  def risk_rules, do: @risk_rules

  @doc "Whether `path` is a dependency manifest the `:dependency` rule reads (`mix.lock`, `package.json`)."
  @spec manifest?(String.t()) :: boolean()
  def manifest?(path) when is_binary(path), do: Path.basename(path) in @manifests

  @doc """
  The reasons `issue` and its PR's diff escalate, one per triggered rule. `busy_files` are the
  paths changed most often on the default branch lately; `rules` is the repo's effective `escalate`
  block. Options: `:review_states`, the state names the `:ticket_pattern` rule skips.
  """
  @spec check(Issue.t(), diff_summary(), [String.t()], Escalate.t(), keyword()) :: [reason()]
  def check(%Issue{} = issue, %{files: files}, busy_files, %Escalate{} = rules, opts \\ []) when is_list(files) and is_list(busy_files) do
    [
      {:label, label_detail(issue, rules.labels)},
      {:ticket_pattern, ticket_pattern_detail(issue, rules.ticket_patterns, Keyword.get(opts, :review_states, []))},
      {:path, path_detail(files, rules.paths)},
      {:diff_pattern, diff_pattern_detail(files, rules.diff_patterns)},
      {:dependency, dependency_detail(files, rules.dependencies)},
      {:size, size_detail(files, rules.max_changed_lines)},
      {:busy_file, busy_file_detail(files, busy_files, rules.busy_files.max_lines)}
    ]
    |> Enum.reject(fn {_rule, detail} -> is_nil(detail) end)
    |> Enum.map(fn {rule, detail} -> %{rule: rule, detail: detail} end)
  end

  @doc """
  The reasons the ticket alone (its labels, title and description) needs a person: the
  `:label` and `:ticket_pattern` rules of `check/5`, which need no diff. Options as `check/5`.
  """
  @spec ticket_reasons(Issue.t(), Escalate.t(), keyword()) :: [reason()]
  def ticket_reasons(%Issue{} = issue, %Escalate{} = rules, opts \\ []) do
    [
      {:label, label_detail(issue, rules.labels)},
      {:ticket_pattern, ticket_pattern_detail(issue, rules.ticket_patterns, Keyword.get(opts, :review_states, []))}
    ]
    |> Enum.reject(fn {_rule, detail} -> is_nil(detail) end)
    |> Enum.map(fn {rule, detail} -> %{rule: rule, detail: detail} end)
  end

  defp label_detail(%Issue{labels: labels}, escalate_labels) do
    wanted = MapSet.new(escalate_labels, &normalize_label/1)

    labels
    |> Enum.filter(&(is_binary(&1) and MapSet.member?(wanted, normalize_label(&1))))
    |> join_or_nil(&"the issue is labelled `#{&1}`")
  end

  defp ticket_pattern_detail(%Issue{title: title, description: description}, patterns, review_states) do
    text = [title || "", description || ""] |> Enum.join("\n") |> blank_state_names(review_states)

    patterns
    |> Enum.filter(&Regex.match?(Regex.compile!(&1), text))
    |> join_or_nil(&"the ticket matches `#{&1}`")
  end

  # The ticket naming a review state (`Human Review`) isn't a request for a human review, unless
  # the name follows a request word: "Needs Human Review". Before `state` or `states` the name
  # matches in any case: "the human review state".
  defp blank_state_names(text, states) do
    states
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.reduce(text, fn state, acc ->
      name = Regex.escape(state)

      Regex.replace(~r/(\b(?i:needs?|requires?|wants?)\s+(?:(?i:an?)\s+)?)?\b(?:#{name}\b|(?i:#{name})(?=\W{0,2}\s+(?i:states?)\b))/u, acc, fn
        whole, "" -> String.duplicate(" ", String.length(whole))
        whole, _request -> whole
      end)
    end)
  end

  defp path_detail(files, globs) do
    files
    |> Enum.reject(&Selection.docs_or_test?(&1.path))
    |> Enum.flat_map(fn %{path: path} ->
      case Enum.find(globs, &Selection.glob_match?(path, &1)) do
        nil -> []
        glob -> ["#{path} matches `#{glob}`"]
      end
    end)
    |> join_or_nil(& &1)
  end

  defp diff_pattern_detail(files, patterns) do
    regexes = Enum.map(patterns, &{&1, Regex.compile!(&1)})

    files
    |> Enum.flat_map(fn file ->
      for {pattern, regex} <- regexes, line = Enum.find(Map.get(file, :added_lines, []), &Regex.match?(regex, &1)) do
        "#{file.path} adds a line matching `#{pattern}`: #{excerpt(line)}"
      end
    end)
    |> join_or_nil(& &1)
  end

  defp dependency_detail(_files, "off"), do: nil

  defp dependency_detail(files, mode) do
    files
    |> Enum.filter(&manifest?(&1.path))
    |> Enum.flat_map(&manifest_changes(&1, mode))
    |> join_or_nil(& &1)
  end

  defp manifest_changes(%{path: path} = file, mode) do
    with {:ok, base} <- manifest_versions(path, Map.get(file, :base)),
         {:ok, head} <- manifest_versions(path, Map.get(file, :head)) do
      added = for {package, version} <- head, not Map.has_key?(base, package), do: "#{path}: new dependency #{package} #{version}"

      changed =
        for {package, version} <- head,
            old = Map.get(base, package),
            old not in [nil, version],
            mode == "any" or major_change?(old, version),
            do: "#{path}: #{package} #{old} -> #{version}"

      removed = for {package, _version} <- base, mode == "any", not Map.has_key?(head, package), do: "#{path}: removes #{package}"

      Enum.sort(added) ++ Enum.sort(changed) ++ Enum.sort(removed)
    else
      {:error, _reason} -> ["#{path} could not be parsed"]
    end
  end

  defp manifest_versions(_path, nil), do: {:ok, %{}}

  defp manifest_versions(path, content) do
    if Path.basename(path) == "mix.lock" do
      MixParser.parse_lock(content)
    else
      with {:ok, deps} <- NpmParser.parse(content, path: path) do
        {:ok, Map.new(deps, &{&1.package, npm_version(&1.source)})}
      end
    end
  end

  defp npm_version(%{requirement: requirement}), do: requirement
  defp npm_version(%{url: url}), do: url
  defp npm_version(%{path: path}), do: "file:" <> path
  defp npm_version(%{raw: raw}), do: raw

  defp major_change?(old, new) do
    case {major(old), major(new)} do
      {nil, _new} -> true
      {_old, nil} -> true
      {old_major, new_major} -> old_major != new_major
    end
  end

  defp major(version) do
    case Regex.run(~r/\A[\^~>=<v\s]*(\d+)(?:\.(\d+))?/, version) do
      [_match, "0", minor] -> {0, minor}
      [_match, major | _minor] -> {major}
      nil -> nil
    end
  end

  defp size_detail(files, limit) do
    lines = files |> Enum.reject(&Selection.docs_or_test?(&1.path)) |> Enum.map(&changed_lines/1) |> Enum.sum()

    if lines > limit, do: "#{lines} lines change outside docs and tests (limit #{limit})"
  end

  defp busy_file_detail(files, busy_files, limit) do
    busy = MapSet.new(busy_files)

    files
    |> Enum.filter(&(MapSet.member?(busy, &1.path) and changed_lines(&1) > limit))
    |> join_or_nil(&"#{&1.path} is a busy file and #{changed_lines(&1)} of its lines change (limit #{limit})")
  end

  defp changed_lines(%{additions: additions, deletions: deletions}), do: additions + deletions

  defp normalize_label(label), do: label |> String.trim() |> String.downcase()

  defp excerpt(line) do
    line = String.trim(line)
    if String.length(line) > 120, do: String.slice(line, 0, 117) <> "...", else: line
  end

  defp join_or_nil([], _format), do: nil
  defp join_or_nil(items, format), do: Enum.map_join(items, "; ", format)
end
