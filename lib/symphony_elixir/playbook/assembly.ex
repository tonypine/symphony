defmodule SymphonyElixir.Playbook.Assembly do
  @moduledoc """
  Expands the `{% render "playbook" %}` line of a repo `WORKFLOW.md` body into the
  prompt text it stands for, before Solid parses the template.

  The line becomes Symphony's playbook partials (`SymphonyElixir.Playbook.aggregate/0`)
  merged with the repo's instruction files, the `NNN-name.md` files in its
  instructions directory (`.symphony/instructions` unless the front matter's
  `playbook.instructions` names another), ordered by number. A partial sits on its
  slot, and a file whose number equals a slot comes right after that partial. Sections
  are joined by a blank line, and each file's text goes in as written, so it sees
  the same Liquid variables as the rest of the body.

  The front matter's `playbook` map, which stays in the protected `WORKFLOW.md`, can
  move a partial to another slot, add one the aggregate leaves out, or drop one with
  `false` (`partials`), and names the lock file `dependency_guardrail` cites
  (`lockfile`; without it that partial is left out). A body without the line is
  returned as it is.

  The expansion reads no file itself: the caller passes the directory's files, read
  from disk next to the `WORKFLOW.md` or from the git ref the workflow comes from (see
  `SymphonyElixir.WorkflowSource`).
  """

  alias SymphonyElixir.Playbook

  @directive ~s({% render "playbook" %})
  @default_instructions_dir ".symphony/instructions"
  @settings_keys ~w(instructions lockfile partials)
  @instruction_file ~r/\A(\d+)-[^\/]+\.md\z/
  @left_trimmed ~w(ticket_types)

  @type instruction_files :: [{String.t(), String.t()}]
  @type reader :: (String.t() -> {:ok, instruction_files()} | {:error, term()})

  @doc "The body line that expands to the playbook."
  @spec directive() :: String.t()
  def directive, do: @directive

  @doc "Whether `line` is the playbook line, apart from surrounding whitespace."
  @spec directive?(String.t()) :: boolean()
  def directive?(line) when is_binary(line), do: String.trim(line) == @directive

  @doc "The instructions directory the `playbook` settings name, relative to the `WORKFLOW.md`."
  @spec instructions_dir(map()) :: String.t()
  def instructions_dir(settings) when is_map(settings), do: Map.get(settings, "instructions", @default_instructions_dir)

  @doc "Whether a file in the instructions directory is an instruction file (`NNN-name.md`)."
  @spec instruction_file?(String.t()) :: boolean()
  def instruction_file?(name) when is_binary(name), do: Regex.match?(@instruction_file, name)

  @doc "Checks the front matter's `playbook` map; returns a message for the first problem."
  @spec validate_settings(term()) :: :ok | {:error, String.t()}
  def validate_settings(nil), do: :ok

  def validate_settings(settings) when is_map(settings) do
    case Map.keys(settings) -- @settings_keys do
      [] ->
        with :ok <- validate_instructions(Map.get(settings, "instructions")),
             :ok <- validate_lockfile(Map.get(settings, "lockfile")) do
          validate_partials(Map.get(settings, "partials"))
        end

      [key | _rest] ->
        {:error, "playbook supports only `instructions`, `lockfile` and `partials`, not `#{key}`"}
    end
  end

  def validate_settings(_settings), do: {:error, "playbook must be a map"}

  defp validate_instructions(nil), do: :ok

  defp validate_instructions(dir) when is_binary(dir) do
    if String.trim(dir) != "" and Path.type(dir) == :relative and ".." not in Path.split(dir),
      do: :ok,
      else: {:error, "playbook.instructions must be a directory inside the repo, relative to WORKFLOW.md"}
  end

  defp validate_instructions(_dir), do: {:error, "playbook.instructions must be a string"}

  defp validate_lockfile(nil), do: :ok

  # The name goes into a Liquid string literal, which has no escapes.
  defp validate_lockfile(lockfile) when is_binary(lockfile) do
    if String.trim(lockfile) != "" and not String.contains?(lockfile, ["\"", "\n", "{", "}", "%"]),
      do: :ok,
      else: {:error, "playbook.lockfile must be a file name without quotes or braces"}
  end

  defp validate_lockfile(_lockfile), do: {:error, "playbook.lockfile must be a string"}

  defp validate_partials(nil), do: :ok

  defp validate_partials(partials) when is_map(partials) do
    case Enum.find(partials, fn {name, slot} -> name not in Playbook.names() or not slot?(slot) end) do
      nil ->
        :ok

      {name, _slot} ->
        if name in Playbook.names(),
          do: {:error, "playbook.partials.#{name} must be a slot number or false"},
          else: {:error, "playbook.partials names unknown partial `#{name}`"}
    end
  end

  defp validate_partials(_partials), do: {:error, "playbook.partials must be a map of partial names to slot numbers or false"}

  defp slot?(slot), do: slot == false or (is_integer(slot) and slot >= 0)

  @doc """
  Expands every playbook line in `body_lines`, reading the instruction files with
  `read_instructions` only when there is one.

  `aggregate` defaults to `SymphonyElixir.Playbook.aggregate/0`.
  """
  @spec expand([String.t()], map(), reader(), [{String.t(), non_neg_integer()}]) ::
          {:ok, [String.t()]} | {:error, term()}
  def expand(body_lines, settings, read_instructions, aggregate \\ Playbook.aggregate())
      when is_list(body_lines) and is_map(settings) and is_function(read_instructions, 1) do
    if Enum.any?(body_lines, &directive?/1) do
      with {:ok, playbook} <- render(settings, read_instructions, aggregate) do
        {:ok, Enum.map(body_lines, &if(directive?(&1), do: playbook, else: &1))}
      end
    else
      {:ok, body_lines}
    end
  end

  defp render(settings, read_instructions, aggregate) do
    dir = instructions_dir(settings)

    with {:ok, files} <- read_files(read_instructions, dir),
         :ok <- reject_nested_directive(files, dir) do
      sections = partial_sections(settings, aggregate) ++ file_sections(files)

      {:ok, sections |> Enum.sort() |> Enum.map_join("\n\n", fn {_slot, _order, _name, text} -> text end)}
    end
  end

  defp read_files(read_instructions, dir) do
    case read_instructions.(dir) do
      {:ok, files} -> {:ok, Enum.filter(files, fn {name, _body} -> instruction_file?(name) end)}
      {:error, reason} -> {:error, {:workflow_instructions_error, dir, reason}}
    end
  end

  # The expanded text is parsed again from a snapshot, where a second expansion would
  # read no files.
  defp reject_nested_directive(files, dir) do
    case Enum.find(files, fn {_name, body} -> body |> String.split(~r/\R/) |> Enum.any?(&directive?/1) end) do
      nil -> :ok
      {name, _body} -> {:error, {:workflow_instructions_error, dir, {:playbook_line_in_instruction_file, name}}}
    end
  end

  defp partial_sections(settings, aggregate) do
    lockfile = Map.get(settings, "lockfile")

    aggregate
    |> Map.new()
    |> Map.merge(Map.get(settings, "partials") || %{})
    |> Enum.flat_map(fn
      {name, slot} when is_integer(slot) -> render_line(name, slot, lockfile)
      {_name, false} -> []
    end)
  end

  defp render_line(name, slot, lockfile) do
    vars = Playbook.vars(name)

    if "lockfile" in vars and is_nil(lockfile) do
      []
    else
      args = Enum.map_join(vars, fn var -> ", " <> arg(var, lockfile) end)
      [{slot, 0, name, ~s({#{open_tag(name)} render "#{name}") <> args <> " %}"}]
    end
  end

  # `ticket_types` renders nothing for an untyped ticket and starts each branch with its own
  # blank line, so its tag trims the blank line before it and an untyped prompt is unchanged.
  defp open_tag(name) when name in @left_trimmed, do: "%-"
  defp open_tag(_name), do: "%"

  defp arg("lockfile", lockfile), do: ~s(lockfile: "#{lockfile}")
  defp arg(var, _lockfile), do: "#{var}: #{var}"

  defp file_sections(files) do
    for {name, body} <- files do
      [_name, number] = Regex.run(@instruction_file, name)
      {String.to_integer(number), 1, name, String.trim(body)}
    end
  end
end
