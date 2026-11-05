defmodule SymphonyElixir.Workpad.Projection do
  @moduledoc """
  Renders the `### Plan` and `### Validation` sections of a ticket's single workpad comment from its
  step events (`step.started`, `step.completed`, `SymphonyElixir.PhaseSteps`). Agents write
  neither: the run's step list is the plan, and the machine steps' results are the validation. The
  `Notes` and `Confusions` the agent writes, and every other byte of the comment, stay as they are.

  * **Plan** is the newest run's steps, in the step list's order, each with its outcome and elapsed
    time ("Build: passed, 4 min"; "Run the tests: failed, back to Write the code"; "paused on your
    answer"), checked once it passed or was skipped, and a line naming the step the run is on.
  * **Validation** is the last result of each machine step on the ticket: its command, the result
    and a link to its output (the `step_output` artifact, uploaded to Linear once,
    `SymphonyElixir.QaAgent.Report.artifact_link/4`).

  Each section sits between its own markers, `<!-- symphony:workpad:plan:start:<hash> -->` and
  `<!-- symphony:workpad:plan:end -->` (and `validation`), with the same discipline as the
  Decisions section (`SymphonyElixir.Decisions`): the block is found by its markers wherever it
  stands, never by its text, since Linear rewrites the markdown it stores (`*` bullets, escapes,
  blank lines); a repeated block is dropped, so a section is never shown twice. The start marker
  carries the hash of what was rendered, so a section Linear rewrote but whose events did not
  change is not written again. A workpad with no block yet has its `### Plan` (or
  `### Validation`) section replaced, heading included, up to the next heading; one without it gets
  the block before the template's next section there is (`### Acceptance Criteria`, then
  `### Notes` and `### Confusions`), else at the end.

  `project_now/2` writes the projection into the ticket's workpad on a Linear tracker, once per
  change, serialized per ticket so the last write carries the newest events; the step runner calls
  `project_later/2` after each step event it records. The agent's own writes to the workpad take
  the same lock (`write_agent_body/4`), so neither overwrites the other. A ticket with no step
  event, or no workpad comment, is left as it is.
  """

  require Logger

  alias SymphonyElixir.{Config, RunStore, Workpad}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Report

  @step_types ["step.started", "step.completed"]
  @sections [:plan, :validation]
  @headings %{plan: "### Plan", validation: "### Validation"}
  @intros %{
    plan: "_Symphony writes this section from the run's steps._",
    validation: "_Symphony writes this section from the machine steps' results._"
  }
  @command_max 200
  @text_max 200

  @typedoc "What the sections show: each one's markdown, or nil when there is nothing to show."
  @type rendered :: %{plan: String.t() | nil, validation: String.t() | nil}

  @typedoc "Where an artifact's output is published: its URL, or nil when it has none."
  @type link_fun :: (String.t() -> String.t() | nil)

  @typedoc """
  `steps:` the run's step list (`SymphonyElixir.Config.Schema.Phases.Step`), so a step not reached
  yet shows too; `link:` the artifact link (`t:link_fun/0`, default its Linear upload);
  `settings:`, `linear_client:`, `upload_client:` and `linear_retry_opts:` for the Linear calls.
  """
  @type opt ::
          {:steps, [map()] | nil}
          | {:link, link_fun()}
          | {:settings, map()}
          | {:linear_client, term()}
          | {:upload_client, term()}
          | {:linear_retry_opts, keyword()}

  @doc "The marker that opens `section` (`:plan` or `:validation`), carrying `hash`."
  @spec start_marker(:plan | :validation, String.t()) :: String.t()
  def start_marker(section, hash) when section in @sections, do: "<!-- symphony:workpad:#{section}:start:#{hash} -->"

  @doc "The marker that closes `section`."
  @spec end_marker(:plan | :validation) :: String.t()
  def end_marker(section) when section in @sections, do: "<!-- symphony:workpad:#{section}:end -->"

  @doc """
  `body` without the projection's markers, so a copy of the workpad (a restart's superseded
  attempt, `Workpad.supersede_body/4`) is plain history the next projection never takes for its own
  sections.
  """
  @spec strip_markers(String.t()) :: String.t()
  def strip_markers(body) when is_binary(body), do: Regex.replace(~r/^[ \t]*<!-- symphony:workpad:(?:plan|validation):(?:start(?::\w*)?|end) -->[ \t]*\n?/m, body, "")

  @doc """
  The two sections for a ticket's `events` (its step events, oldest first) as markdown, each with
  its heading and intro: nil for a section with nothing to show. Pure: `link` gives each output
  artifact's URL.
  """
  @spec render([map()], link_fun(), [map()] | nil) :: rendered()
  def render(events, link, steps \\ nil) when is_list(events) and is_function(link, 1) do
    events = Enum.filter(events, &(&1.type in @step_types and is_map(&1.payload)))
    %{plan: plan(events, steps), validation: validation(events, steps, link)}
  end

  defp plan([], _steps), do: nil

  defp plan(events, steps) do
    run_id = List.last(events).run_id
    run = Enum.filter(events, &(&1.run_id == run_id))
    lines = Enum.map(order(run, steps, fn _step -> true end), &plan_line(&1, latest(run, &1.id)))
    Enum.join([@headings.plan, "", @intros.plan, "", now(run, steps), "" | lines], "\n")
  end

  defp validation(events, steps, link) do
    case order(events, steps, &(&1.mode == "machine")) |> Enum.filter(&latest(events, &1.id)) do
      [] -> nil
      machine -> Enum.join([@headings.validation, "", @intros.validation, "" | Enum.map(machine, &validation_line(&1, events, link))], "\n")
    end
  end

  # The steps in the step list's order, then the ones its events name that the list does not, in
  # the order they first appear; `keep?` picks among them.
  defp order(events, steps, keep?) do
    listed = for %{id: id} = step <- steps || [], is_binary(id), do: %{id: id, title: Map.get(step, :title), mode: Map.get(step, :mode)}

    seen =
      for %{payload: payload} <- events, id = field(payload, :step_id), is_binary(id), uniq: true do
        %{id: id, title: field(payload, :title), mode: field(payload, :mode)}
      end

    listed_ids = MapSet.new(listed, & &1.id)

    (listed ++ Enum.reject(seen, &MapSet.member?(listed_ids, &1.id)))
    |> Enum.map(&%{&1 | title: text(&1.title) || &1.id})
    |> Enum.filter(keep?)
  end

  defp latest(events, id), do: events |> Enum.filter(&(field(&1.payload, :step_id) == id)) |> List.last()

  defp now(run, steps) do
    case List.last(run) do
      %{type: "step.started", payload: payload} -> "**Now:** #{title_of(payload, steps)}."
      %{type: "step.completed", payload: payload} -> ended_line(payload, steps)
    end
  end

  defp ended_line(payload, steps) do
    if field(payload, :outcome) == "paused",
      do: "**Now:** paused on your answer at #{title_of(payload, steps)}.",
      else: "**Now:** between steps, #{title_of(payload, steps)} ended last."
  end

  defp title_of(payload, steps) do
    id = field(payload, :step_id)
    listed = Enum.find(steps || [], &(Map.get(&1, :id) == id))
    text((listed && Map.get(listed, :title)) || field(payload, :title)) || text(id) || "a step"
  end

  defp plan_line(step, nil), do: "- [ ] #{step.title}"
  defp plan_line(step, %{type: "step.started"}), do: "- [ ] #{step.title}: running"
  defp plan_line(step, %{payload: payload}), do: "- [#{check(payload)}] #{step.title}: #{outcome(payload)}"

  defp validation_line(step, events, link) do
    last = latest(events, step.id)
    command = command(events, step.id)
    result = if last.type == "step.started", do: "running", else: outcome(last.payload)
    output = output_link(last, link)
    "- [#{if last.type == "step.completed", do: check(last.payload), else: " "}] #{step.title}#{command}: #{result}#{output}"
  end

  defp command(events, id) do
    case events |> Enum.filter(&(&1.type == "step.started" and field(&1.payload, :step_id) == id)) |> List.last() do
      %{payload: payload} ->
        case text(field(payload, :command)) do
          nil -> ""
          command -> " `#{command |> String.replace("`", "'") |> String.slice(0, @command_max)}`"
        end

      nil ->
        ""
    end
  end

  defp output_link(%{type: "step.completed", artifacts: [id | _rest]}, link) when is_binary(id) do
    case link.(id) do
      url when is_binary(url) -> " · [output](#{url})"
      _none -> ""
    end
  end

  defp output_link(_event, _link), do: ""

  defp check(payload), do: if(field(payload, :outcome) in ["passed", "skipped"], do: "x", else: " ")

  defp outcome(payload) do
    case field(payload, :outcome) do
      "passed" -> "passed" <> duration(field(payload, :duration_ms))
      "skipped" -> "skipped" <> suffix(": ", text(field(payload, :reason)))
      "paused" -> "paused on your answer"
      "failed" -> "failed" <> duration(field(payload, :duration_ms)) <> back_to(payload)
      other -> text(other) || "ended"
    end
  end

  defp back_to(payload) do
    case {field(payload, :returns_to), text(field(payload, :returns_to_title))} do
      {"end", _title} -> ", the run ended"
      {_id, nil} -> ""
      {_id, title} -> ", back to " <> title
    end
  end

  defp duration(ms) when is_integer(ms) and ms >= 60_000, do: ", #{div(ms + 30_000, 60_000)} min"
  defp duration(ms) when is_integer(ms) and ms >= 0, do: ", under a minute"
  defp duration(_ms), do: ""

  defp suffix(_separator, nil), do: ""
  defp suffix(separator, text), do: separator <> text

  defp field(payload, key) when is_map(payload), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  # One line of plain text that cannot open or close a marker.
  defp text(value) when is_binary(value) do
    case value |> String.replace(["<!--", "-->"], "") |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, @text_max) do
      "" -> nil
      text -> text
    end
  end

  defp text(_value), do: nil

  @doc """
  Writes `rendered` into the workpad `body`: each section that has something to show replaces its
  marked block, or its `###` section when it has no block yet, or is inserted (see the moduledoc).
  A section whose block carries the same hash is left as it is, byte for byte, as is every byte
  outside the two sections.
  """
  @spec put(String.t(), rendered()) :: String.t()
  def put(body, rendered) when is_binary(body) and is_map(rendered) do
    Enum.reduce(@sections, body, fn section, body -> put_section(body, section, Map.get(rendered, section)) end)
  end

  defp put_section(body, _section, nil), do: body

  defp put_section(body, section, markdown) do
    hash = hash(markdown)
    block = Enum.join([start_marker(section, hash), markdown, end_marker(section)], "\n")

    case blocks(body, section) do
      [] -> place(body, section, block)
      [{_from, _to, ^hash} | _rest] = found -> drop_blocks(body, tl(found))
      [{from, to, _hash} | rest] -> body |> drop_blocks(rest) |> splice(from, to, block)
    end
  end

  # The marked blocks of `section` in `body`: each `{from, to, hash}`, the byte range from its start
  # marker through its end marker. A start marker with no end before the next start marker ends at
  # the end of its own line, so a stray marker never takes the text after it.
  defp blocks(body, section) do
    starts = Regex.scan(~r/<!-- symphony:workpad:#{section}:start(?::(\w*))? -->/, body, return: :index)

    limits =
      Enum.map(tl(starts ++ [nil]), fn
        [{from, _length} | _hash] -> from
        nil -> byte_size(body)
      end)

    end_marker = end_marker(section)

    for {[{from, length} | hash_index], limit} <- Enum.zip(starts, limits) do
      after_start = from + length

      to =
        case :binary.match(body, end_marker, scope: {after_start, limit - after_start}) do
          {at, len} -> at + len
          :nomatch -> min(line_end(body, after_start), limit)
        end

      {from, to, marker_hash(body, hash_index)}
    end
  end

  # The hash a start marker carries; an older marker without one carries none.
  defp marker_hash(body, [{at, length}]) when at >= 0, do: binary_part(body, at, length)
  defp marker_hash(_body, _none), do: ""

  defp line_end(body, from) do
    case :binary.match(body, "\n", scope: {from, byte_size(body) - from}) do
      {at, _len} -> at
      :nomatch -> byte_size(body)
    end
  end

  # The repeated blocks go, last first so the earlier ranges stand, with the line break after each.
  defp drop_blocks(body, blocks) do
    blocks
    |> Enum.reverse()
    |> Enum.reduce(body, fn {from, to, _hash}, body ->
      to = if binary_part(body, to, min(1, byte_size(body) - to)) == "\n", do: to + 1, else: to
      splice(body, from, to, "")
    end)
  end

  defp splice(body, from, to, insert), do: binary_part(body, 0, from) <> insert <> binary_part(body, to, byte_size(body) - to)

  # A workpad with no block yet: its `###` section of the same name gives way to the block, else the
  # block goes before the section that follows it in the template, else at the end.
  defp place(body, section, block) do
    lines = String.split(body, "\n")

    case Enum.find_index(lines, &heading?(&1, section_name(section))) do
      nil ->
        insert_before(lines, block, section)

      index ->
        {before, from_heading} = Enum.split(lines, index)
        {content, rest} = Enum.split_while(tl(from_heading), &(not any_heading?(&1)))
        {_content, blank} = split_trailing_blank(content)
        Enum.join(before ++ [block] ++ blank_or_one(blank, rest) ++ rest, "\n")
    end
  end

  defp blank_or_one(blank, []), do: blank
  defp blank_or_one(_blank, _rest), do: [""]

  defp insert_before(lines, block, section) do
    case Enum.find_index(lines, fn line -> Enum.any?(later_sections(section), &heading?(line, &1)) end) do
      nil -> lines |> Enum.join("\n") |> String.trim_trailing() |> Kernel.<>("\n\n" <> block <> "\n")
      index -> lines |> List.insert_at(index, block <> "\n") |> Enum.join("\n")
    end
  end

  defp section_name(:plan), do: "Plan"
  defp section_name(:validation), do: "Validation"

  # The template's sections after `section`, in order: the block goes before the first one there is.
  defp later_sections(:plan), do: ["Acceptance Criteria", "Validation", "Notes", "Confusions"]
  defp later_sections(:validation), do: ["Notes", "Confusions"]

  # A workpad section's own heading: `###` exactly, so a restart's demoted `####` copy never counts.
  defp heading?(line, name), do: Regex.match?(~r/^[ \t]*###[ \t]+#{Regex.escape(name)}[ \t]*:?[ \t]*$/i, line)

  defp any_heading?(line), do: Regex.match?(~r/^[ \t]*\#{1,6}[ \t]+\S/, line)

  defp split_trailing_blank(lines) do
    {blank, content} = lines |> Enum.reverse() |> Enum.split_while(&(String.trim(&1) == ""))
    {Enum.reverse(content), Enum.reverse(blank)}
  end

  defp hash(markdown), do: :sha256 |> :crypto.hash(markdown) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  @doc """
  Projects `ticket`'s step events into its workpad (see the moduledoc) on a Linear tracker; any
  other tracker, a ticket with no step event, and one with no workpad comment are left as they
  are. Serialized per ticket.
  """
  @spec project_now({:ticket, String.t() | nil, String.t()}, [opt()]) :: :ok | {:error, term()}
  def project_now({:ticket, _repo_key, issue_id}, opts \\ []) when is_binary(issue_id) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

    if linear?(settings),
      do: :global.trans(lock_id(issue_id), fn -> project(issue_id, Keyword.put(opts, :settings, settings)) end),
      else: :ok
  end

  @doc """
  The `:global` lock id `project_now/2` serializes on: the ticket is the resource and the calling
  process the requester, so two processes projecting one ticket take turns, and tickets never wait
  on each other.
  """
  @spec lock_id(String.t()) :: {{module(), String.t()}, pid()}
  def lock_id(issue_id) when is_binary(issue_id), do: {{__MODULE__, issue_id}, self()}

  @doc """
  `project_now/2` in a task of its own, so the step runner never waits on Linear; a projection that
  fails is logged, and the next step event projects again.
  """
  @spec project_later({:ticket, String.t() | nil, String.t()}, [opt()]) :: {:ok, pid()}
  def project_later({:ticket, _repo_key, issue_id} = ticket, opts \\ []), do: Task.start(fn -> logged(ticket, issue_id, opts) end)

  defp logged(ticket, issue_id, opts) do
    with {:error, reason} <- project_now(ticket, opts) do
      Logger.warning("Failed to project the workpad of issue_id=#{issue_id}: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("Failed to project the workpad of issue_id=#{issue_id}: #{Exception.message(error)}")
  end

  defp project(issue_id, opts) do
    case rendered(issue_id, opts) do
      nil -> :ok
      rendered -> Workpad.rewrite(%Issue{id: issue_id}, &put(&1, rendered), opts)
    end
  end

  @doc """
  Writes an agent's workpad `body` for `issue_id` with `write`, under the lock `project_now/2`
  takes, with the Plan and Validation the ticket's step events render put into it (`put/2`). The
  agent's write and a projection's read-then-write never interleave, so a projection never writes
  back Notes older than the agent's, and the agent's write never brings back a stale Plan. A ticket
  with no step event keeps `body` as it is.
  """
  @spec write_agent_body(String.t(), String.t(), (String.t() -> result), [opt()]) :: result when result: term()
  def write_agent_body(issue_id, body, write, opts) when is_binary(issue_id) and is_binary(body) and is_function(write, 1) do
    :global.trans(lock_id(issue_id), fn ->
      case rendered(issue_id, opts) do
        nil -> write.(body)
        rendered -> write.(put(body, rendered))
      end
    end)
  end

  defp rendered(issue_id, opts) do
    case RunStore.list_ticket_events(issue_id, types: @step_types) do
      [_ | _] = events ->
        issue = %Issue{id: issue_id}
        link = Keyword.get(opts, :link, &Report.artifact_link(issue, &1, true, opts).url)
        render(events, link, Keyword.get(opts, :steps))

      _none_or_unreadable ->
        nil
    end
  end

  defp linear?(%{tracker: %{kind: kind}}), do: to_string(kind) == "linear"
  defp linear?(_settings), do: false
end
