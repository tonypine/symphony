defmodule SymphonyElixir.PrWatch.Sweep do
  @moduledoc """
  The skip-reason sweep behind `mix pr_watch.sweep`: every line of Symphony's log where a ticket
  was not dispatched (`Skipping dispatch` and `Not dispatching`) and every silent wait the PR and
  CI watcher logged (`pr_watch.silent_wait`), each mapped to the decision table rule that holds the
  ticket (`docs/pr-ci-decisions.md`), counted per rule.

  A line maps to:

    * a rule (`R21`): the watcher's reason names it (`the PR watcher (R21): ...`), a silent wait
      names the watcher's last rule (`rule=R21`), or a reviewer or QA run held back on its head
      takes the rule of the watcher's last reason for that ticket, else its head's status (running
      is R24, red R21);
    * a dispatch gate that is no PR case (`gate: blocked by a ticket`, `gate: hold`, `gate: paused`
      and the others in `labels/0`): the orchestrator's own reasons, which the decision table
      leaves out on purpose;
    * `no rule`: anything else, including a silent wait with no decision (`rule=none`). Each one
      is a case the table doesn't cover yet and is listed with its line.

  Silent waits still listed now (`GET /api/v1/state`, from the run store) count too, unless the
  log already holds the line that listed them. Deciding is pure: the task reads the files and the
  state and hands the lines here.
  """

  @no_rule "no rule"
  @landing "landing rows (R28-R33)"
  @first_read "watcher: first read"

  # The orchestrator's dispatch gates that are no PR case, by the words of their reasons.
  @gates [
    {"blocked by ", "gate: blocked by a ticket"},
    {~r/\bWaiting for [A-Z][A-Z0-9]*-\d+ to (?:finish|land)\b/, "gate: blocked by a ticket"},
    {~r/\bWaiting for PR #\d+\b.* to land: it changes the same files\b/, "gate: blocked by a ticket"},
    {~r/\bWaiting for CI on [0-9a-f]+ to finish\b/, "gate: hold"},
    {~r/\bThe QA (?:machine|environment) (?:is not|cannot|has no)\b/, "gate: hold"},
    {"Waiting for your answer", "gate: hold"},
    {~r/\bon an? [A-Za-z ]+ hold\b/, "gate: hold"},
    {"waiting on its sub-tickets", "gate: sub-tickets"},
    {"Waiting for a Symphony update that includes", "gate: app update"},
    {"waiting for an app update", "gate: app update"},
    {"its plan waits to be replaced", "gate: re-plan"},
    {"the reviewer is turned off", "gate: reviewer off"},
    {"review_agent.enabled is false", "gate: reviewer off"},
    {"held in Merging until CI settles", "gate: Merging CI wait"},
    {"already running", "gate: run active"},
    {"waiting for the QA host's dev server port", "gate: QA dev server port"},
    {"claimed by a retry", "gate: claimed"},
    {"token budget is spent", "gate: token budget"},
    {"workspace setup failed", "gate: workspace setup failed"},
    {"is not in tickets.priorities", "gate: priority filter"},
    {"not assigned to this Symphony's worker", "gate: another worker"},
    {"is a terminal state", "gate: not active"},
    {"is not an active state", "gate: not active"},
    {"no longer active or visible", "gate: not active"},
    {"Linear returned it without", "gate: Linear read"},
    {"issue refresh failed", "gate: Linear read"},
    {"Linear is rate-limited", "gate: Linear rate limit"},
    {"no worker was free", "gate: no free worker"},
    {"has no repo key", "gate: no repo key"},
    {"dispatch is paused", "gate: paused"},
    {"usage limit holds", "gate: usage limit"},
    {~r/ (limit reached|limit headroom: holding new runs|API unreachable)$/, "gate: usage limit"},
    {"quality gate task failure", "gate: quality gate failed"},
    {"readiness task failure", "gate: readiness failed"},
    {"previous Symphony may still be running", "gate: leftover agent"},
    {"agent left running by a previous Symphony", "gate: leftover agent"},
    {"the PR watcher lands", @landing},
    {"the PR watcher hasn't", @first_read}
  ]

  @rule ~r/\A(R\d+[a-z]?)\z/
  @watcher_rule ~r/the PR watcher \((R\d+[a-z]?)\)/
  @held_head ~r/Not dispatching (?:the reviewer|QA) for .*issue_identifier=(\S+): its head is (\S+)/
  @silent ~r/pr_watch\.silent_wait .*\brule=(\S+)/
  @identifier ~r/issue_identifier=([^\s:;]+)/
  @since ~r/\bsince=(\S+)/
  @stamp ~r/\A(\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)?)\s+(.*)\z/

  @typedoc "One line the sweep maps: when, whether a skipped dispatch or a silent wait, the label, the ticket, the text."
  @type finding :: %{
          required(:at) => DateTime.t() | nil,
          required(:kind) => :skipped | :silent,
          required(:label) => String.t(),
          required(:issue) => String.t() | nil,
          required(:line) => String.t(),
          optional(:since) => String.t() | nil
        }

  @typedoc "What a sweep found: each finding, in order, and the count per label and kind."
  @type report :: %{
          findings: [finding()],
          counts: %{optional(String.t()) => %{skipped: non_neg_integer(), silent: non_neg_integer()}}
        }

  @doc "The labels a line can map to besides a rule: each gate, the landing rows, the first read and `no rule`."
  @spec labels() :: [String.t()]
  def labels, do: Enum.uniq(Enum.map(@gates, &elem(&1, 1)) ++ [@no_rule])

  @doc "The label of a case the table doesn't cover."
  @spec no_rule() :: String.t()
  def no_rule, do: @no_rule

  @doc """
  Sweeps log `lines`. `opts`: `:since` (a `DateTime`; a line before it is left out, and so is a
  line with no time once one is given) and `:silent_now` (the state API's `silent_waits` entries,
  with string or atom keys).
  """
  @spec sweep(Enumerable.t(String.t()), keyword()) :: report()
  def sweep(lines, opts \\ []) do
    since = Keyword.get(opts, :since)

    {findings, _rules} =
      Enum.reduce(lines, {[], %{}}, fn line, {findings, rules} ->
        {at, message} = parse(line)

        case recent?(at, since) && finding(message, rules) do
          nil -> {findings, rules}
          false -> {findings, rules}
          finding -> {[Map.put(finding, :at, at) | findings], remember(rules, finding)}
        end
      end)

    findings = Enum.reverse(findings)
    findings = findings ++ silent_now(Keyword.get(opts, :silent_now, []), findings, since)
    %{findings: findings, counts: count(findings)}
  end

  @doc """
  A log line's time and message: the handler writes `<RFC 3339 time> <level>: <message>`. A line
  without a time is all message.
  """
  @spec parse(String.t()) :: {DateTime.t() | nil, String.t()}
  def parse(line) do
    line = String.trim_trailing(line)

    with [_line, stamp, rest] <- Regex.run(@stamp, line),
         {:ok, at} <- datetime(stamp) do
      {at, strip_level(rest)}
    else
      _no_time -> {nil, line}
    end
  end

  @doc """
  What a message maps to (see the moduledoc): `{kind, label}`, or nil for a message that is no
  skipped dispatch and no silent wait. `rules` holds the last rule seen per ticket.
  """
  @spec classify(String.t(), %{optional(String.t()) => String.t()}) :: {:skipped | :silent, String.t()} | nil
  def classify(message, rules \\ %{}) do
    case finding(message, rules) do
      nil -> nil
      %{kind: kind, label: label} -> {kind, label}
    end
  end

  @doc "The report as the task prints it: a summary line, one line per label with its counts, `no rule: N` and each line no rule covers."
  @spec format(report(), String.t()) :: [String.t()]
  def format(%{findings: findings, counts: counts}, sources) do
    {rules, others} = counts |> Map.delete(@no_rule) |> Map.keys() |> Enum.split_with(&Regex.match?(@rule, &1))
    width = (Map.keys(counts) ++ [@no_rule]) |> Enum.map(&String.length/1) |> Enum.max()
    unmatched = Enum.filter(findings, &(&1.label == @no_rule))

    silent = Enum.count(findings, &(&1.kind == :silent))
    summary = "PR watch sweep of #{sources}: #{length(findings) - silent} skipped dispatches, #{silent} silent waits"

    [summary] ++
      Enum.map(Enum.sort_by(rules, &rule_order/1) ++ Enum.sort(others), &count_line(&1, counts[&1], width)) ++
      ["#{@no_rule}: #{length(unmatched)}"] ++
      Enum.map(unmatched, &"  #{&1.line}")
  end

  defp count_line(label, %{skipped: skipped, silent: silent}, width) do
    "#{String.pad_trailing(label <> ":", width + 1)} #{skipped + silent} (skipped #{skipped}, silent #{silent})"
  end

  defp rule_order(rule) do
    [_rule, number, suffix] = Regex.run(~r/\AR(\d+)([a-z]?)\z/, rule)
    {String.to_integer(number), suffix}
  end

  defp finding(message, rules) do
    cond do
      String.contains?(message, "pr_watch.silent_wait") -> silent(message)
      String.contains?(message, "Skipping dispatch") or String.contains?(message, "Not dispatching") -> skipped(message, rules)
      true -> nil
    end
  end

  defp silent(message) do
    label =
      case Regex.run(@silent, message) do
        [_match, rule] -> if Regex.match?(@rule, rule), do: rule, else: @no_rule
        nil -> @no_rule
      end

    %{kind: :silent, label: label, issue: identifier(message), since: capture(@since, message), line: message}
  end

  defp skipped(message, rules) do
    issue = identifier(message)

    label =
      case {Regex.run(@watcher_rule, message), Regex.run(@held_head, message)} do
        {[_match, rule], _held} -> rule
        {nil, [_match, held, status]} -> Map.get(rules, held) || head_rule(status)
        {nil, nil} -> gate(message)
      end

    %{kind: :skipped, label: label, issue: issue, line: message}
  end

  # A head held back on its own status, when no watcher reason for its ticket came before it.
  defp head_rule(status) when status in ["running", "pending"], do: "R24"
  defp head_rule("red"), do: "R21"
  defp head_rule(_status), do: @no_rule

  defp gate(message) do
    Enum.find_value(@gates, @no_rule, fn
      {%Regex{} = pattern, label} -> Regex.match?(pattern, message) && label
      {words, label} -> String.contains?(message, words) && label
    end)
  end

  defp remember(rules, %{kind: :skipped, issue: issue, label: label}) when is_binary(issue) do
    if Regex.match?(@rule, label), do: Map.put(rules, issue, label), else: rules
  end

  defp remember(rules, _finding), do: rules

  # The silent waits listed now that no logged line already counted.
  defp silent_now(entries, findings, since) do
    logged = for %{kind: :silent, issue: issue, since: at} <- findings, into: MapSet.new(), do: {issue, at}

    for entry <- entries,
        identifier = field(entry, :identifier) || field(entry, :issue_identifier),
        at = field(entry, :since),
        not MapSet.member?(logged, {identifier, at}),
        {:ok, listed_at} <- [datetime(to_string(at))],
        recent?(listed_at, since) do
      rule = field(entry, :rule)
      label = if is_binary(rule) and Regex.match?(@rule, rule), do: rule, else: @no_rule
      line = "silent now: #{identifier} since=#{at} rule=#{rule || "none"} reason=#{inspect(field(entry, :reason))}"
      %{at: listed_at, kind: :silent, label: label, issue: identifier, since: at, line: line}
    end
  end

  defp field(entry, key), do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))

  defp count(findings) do
    Enum.reduce(findings, %{}, fn %{kind: kind, label: label}, counts ->
      counts
      |> Map.put_new(label, %{skipped: 0, silent: 0})
      |> update_in([label, kind], &(&1 + 1))
    end)
  end

  defp recent?(_at, nil), do: true
  defp recent?(nil, _since), do: false
  defp recent?(at, since), do: DateTime.compare(at, since) != :lt

  defp identifier(message), do: capture(@identifier, message)

  defp capture(pattern, message) do
    case Regex.run(pattern, message) do
      [_match, value] -> value
      nil -> nil
    end
  end

  defp strip_level(rest) do
    case Regex.run(~r/\A(?:\[)?(emergency|alert|critical|error|warning|notice|info|debug)(?:\])?:?\s+(.*)\z/, rest) do
      [_match, _level, message] -> message
      nil -> rest
    end
  end

  # An RFC 3339 time, with a space for the `T` or no offset (read as UTC).
  defp datetime(stamp) do
    stamp = String.replace(stamp, " ", "T")
    stamp = if Regex.match?(~r/(Z|[+-]\d\d:?\d\d)\z/, stamp), do: stamp, else: stamp <> "Z"

    case DateTime.from_iso8601(stamp) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, reason} -> {:error, reason}
    end
  end
end
