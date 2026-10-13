defmodule SymphonyElixir.ProjectGuides do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PathSafety

  @per_file_bytes 32 * 1024
  @total_bytes 64 * 1024
  @max_depth 5
  @max_files 20
  @import_pattern ~r/^@(.+)$/
  # A prompt with a structured-output contract puts this marker on the line before the contract,
  # so the project conventions land above it and the contract stays the last thing the model reads.
  @output_contract_marker "<!-- symphony:output-contract -->"

  @type guide :: %{path: String.t(), content: String.t()}
  @type runner :: :claude | :codex

  @spec default_files(runner()) :: [String.t()]
  def default_files(:claude), do: ["CLAUDE.md"]
  def default_files(:codex), do: []

  @spec read(Path.t(), [String.t()] | nil, keyword()) :: {:ok, [guide()]} | {:error, term()}
  def read(workspace, files, opts \\ [])
      when is_binary(workspace) and (is_list(files) or is_nil(files)) do
    files = files || default_files(Keyword.get(opts, :runner, :codex))

    with {:ok, root} <- workspace_root(workspace) do
      state = %{
        root: root,
        workspace: root,
        per_file_bytes: Keyword.get(opts, :per_file_bytes, @per_file_bytes),
        total_bytes: Keyword.get(opts, :total_bytes, @total_bytes),
        max_depth: Keyword.get(opts, :max_depth, @max_depth),
        max_files: Keyword.get(opts, :max_files, @max_files),
        bytes_read: 0,
        files_read: 0,
        visited: MapSet.new()
      }

      read_entries(files, state)
    end
  end

  @spec output_contract_marker() :: String.t()
  def output_contract_marker, do: @output_contract_marker

  @spec append_to_prompt(String.t(), Path.t(), Schema.t(), runner()) :: {:ok, String.t()} | {:error, term()}
  def append_to_prompt(prompt, workspace, %Schema{} = settings, runner) when is_binary(prompt) do
    case settings.agent.include_project_guides do
      true -> append_enabled_guides(prompt, workspace, settings, runner)
      false -> {:ok, insert_section(prompt, nil)}
    end
  end

  @spec prompt_section([guide()]) :: String.t() | nil
  def prompt_section([]), do: nil

  def prompt_section(guides) when is_list(guides) do
    body =
      Enum.map_join(guides, "\n\n", fn %{path: path, content: content} ->
        "### #{path}\n\n#{String.trim_trailing(content)}"
      end)

    "## Project conventions\n\n" <> body
  end

  defp read_entries(files, state) do
    files
    |> Enum.reduce_while({:ok, [], state}, &read_entry_step/2)
    |> case do
      {:ok, guides, _state} -> {:ok, guides}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_entry_step(file, {:ok, guides, state}) do
    case read_entry(file, state) do
      {:ok, nil, state} -> {:cont, {:ok, guides, state}}
      {:ok, guide, state} -> {:cont, {:ok, guides ++ [guide], state}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp append_enabled_guides(prompt, workspace, settings, runner) do
    files = settings.agent.project_guide_files || default_files(runner)

    case read(workspace, files, runner: runner) do
      {:ok, guides} -> {:ok, insert_section(prompt, prompt_section(guides))}
      {:error, reason} -> {:error, reason}
    end
  end

  # Splits at the last marker: an earlier one can only come from quoted material such as a diff.
  defp insert_section(prompt, section) do
    case :binary.matches(prompt, @output_contract_marker) do
      [] ->
        append_section(prompt, section)

      matches ->
        {start, length} = List.last(matches)
        before = binary_part(prompt, 0, start)
        contract = binary_part(prompt, start + length, byte_size(prompt) - start - length)
        append_section(before, section) <> "\n" <> String.trim_leading(contract)
    end
  end

  defp append_section(prompt, nil), do: prompt
  defp append_section(prompt, section), do: String.trim_trailing(prompt) <> "\n\n" <> section <> "\n"

  defp read_entry(file, state) do
    case resolve_path(file, state.workspace, state.root) do
      {:ok, resolved} -> read_resolved_entry(resolved, state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_resolved_entry(resolved, state) do
    if File.exists?(resolved.path), do: read_existing_entry(resolved, state), else: {:ok, nil, state}
  end

  defp read_existing_entry(resolved, state) do
    with {:ok, content, state} <- read_file(resolved, 0, state) do
      {:ok, %{path: resolved.relative, content: content}, state}
    end
  end

  defp read_file(resolved, depth, state) do
    cond do
      depth > state.max_depth ->
        {:error, {:project_guide_depth_exceeded, resolved.relative}}

      MapSet.member?(state.visited, resolved.canonical) ->
        Logger.warning("Skipping recursive project guide import path=#{resolved.relative}")
        {:ok, "", state}

      state.files_read + 1 > state.max_files ->
        {:error, :project_guide_file_count_exceeded}

      true ->
        do_read_file(resolved, depth, state)
    end
  end

  defp do_read_file(resolved, depth, state) do
    with {:ok, content} <- File.read(resolved.path),
         :ok <- validate_utf8(content, resolved.relative),
         :ok <- validate_file_size(content, resolved.relative, state),
         {:ok, state} <- count_file(content, resolved, state),
         {:ok, content, state} <- expand_imports(content, resolved, depth, state) do
      {:ok, content, state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp expand_imports(content, resolved, depth, state) do
    content
    |> String.split("\n", trim: false)
    |> Enum.reduce_while({:ok, [], state}, fn line, {:ok, lines, state} ->
      expand_import_line(line, lines, resolved, depth, state)
    end)
    |> case do
      {:ok, lines, state} -> {:ok, Enum.join(lines, "\n"), state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expand_import_line(line, lines, resolved, depth, state) do
    case import_target(line) do
      nil -> {:cont, {:ok, lines ++ [line], state}}
      target -> inline_import_step(target, lines, resolved, depth, state)
    end
  end

  defp inline_import_step(target, lines, resolved, depth, state) do
    case inline_import(target, resolved, depth, state) do
      {:ok, import_lines, state} -> {:cont, {:ok, lines ++ import_lines, state}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp inline_import(target, resolved, depth, state) do
    with {:ok, imported} <- resolve_path(target, Path.dirname(resolved.path), state.root),
         {:ok, content, state} <- read_file(imported, depth + 1, state) do
      content = String.trim_trailing(content)

      lines =
        if content == "" do
          ["### @#{imported.relative}", ""]
        else
          ["### @#{imported.relative}", "", content]
        end

      {:ok, lines, state}
    end
  end

  defp import_target(line) do
    line = String.trim_trailing(line, "\r")

    case Regex.run(@import_pattern, line, capture: :all_but_first) do
      [target] ->
        case String.trim(target) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp count_file(content, resolved, state) do
    bytes_read = state.bytes_read + byte_size(content)

    if bytes_read > state.total_bytes do
      {:error, :project_guide_total_size_exceeded}
    else
      {:ok,
       %{
         state
         | bytes_read: bytes_read,
           files_read: state.files_read + 1,
           visited: MapSet.put(state.visited, resolved.canonical)
       }}
    end
  end

  defp validate_utf8(content, relative) do
    if String.valid?(content), do: :ok, else: {:error, {:project_guide_invalid_utf8, relative}}
  end

  defp validate_file_size(content, relative, state) do
    if byte_size(content) > state.per_file_bytes do
      {:error, {:project_guide_file_too_large, relative}}
    else
      :ok
    end
  end

  defp resolve_path(path, base, root) do
    with :ok <- validate_relative_path(path),
         absolute <- Path.expand(path, base),
         :ok <- within_root(absolute, root),
         {:ok, canonical} <- PathSafety.canonicalize(absolute),
         :ok <- within_root(canonical, root) do
      {:ok, %{path: absolute, canonical: canonical, relative: relative_to_root(canonical, root)}}
    end
  end

  defp within_root(path, root) do
    if String.starts_with?(path <> "/", root <> "/"), do: :ok, else: {:error, :path_escape}
  end

  defp workspace_root(workspace) do
    PathSafety.canonicalize(Path.expand(workspace))
  end

  defp validate_relative_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, :path_escape}

      Path.type(trimmed) != :relative ->
        {:error, :path_escape}

      String.starts_with?(trimmed, "~") ->
        {:error, :path_escape}

      String.contains?(trimmed, ["\n", "\r", <<0>>]) ->
        {:error, :path_escape}

      ".." in Path.split(trimmed) ->
        {:error, :path_escape}

      true ->
        :ok
    end
  end

  defp relative_to_root(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.join("/")
  end
end
