defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads operator configuration from `symphony.yml` and repo workflow prompts from
  `WORKFLOW.md`.

  A `WORKFLOW.md` body may hold a `{% render "playbook" %}` line, which loading
  expands into Symphony's playbook partials and the repo's instruction files (see
  `SymphonyElixir.Playbook.Assembly`). `load/1` reads those files next to the
  workflow file; `SymphonyElixir.WorkflowSource` reads them from the git ref.
  """

  alias SymphonyElixir.Config.RepoWorkflowSchema
  alias SymphonyElixir.Playbook.Assembly
  alias SymphonyElixir.WorkflowStore

  @symphony_file_name "symphony.yml"
  @workflow_file_name "WORKFLOW.md"

  @spec symphony_file_path() :: Path.t()
  def symphony_file_path do
    Application.get_env(:symphony_elixir, :symphony_file_path) ||
      Path.join(File.cwd!(), @symphony_file_name)
  end

  @spec set_symphony_file_path(Path.t()) :: :ok
  def set_symphony_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :symphony_file_path, path)
    :ok
  end

  @spec clear_symphony_file_path() :: :ok
  def clear_symphony_file_path do
    Application.delete_env(:symphony_elixir, :symphony_file_path)
    :ok
  end

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @spec repo_workflow_file_path(map()) :: Path.t()
  def repo_workflow_file_path(%{path: repo_path, workflow: workflow}) when is_binary(repo_path) and is_binary(workflow) do
    workflow_path(repo_path, workflow)
  end

  def repo_workflow_file_path(%{"path" => repo_path, "workflow" => workflow}) when is_binary(repo_path) and is_binary(workflow) do
    workflow_path(repo_path, workflow)
  end

  def repo_workflow_file_path(%{path: repo_path}) when is_binary(repo_path), do: workflow_path(repo_path, @workflow_file_name)
  def repo_workflow_file_path(%{"path" => repo_path}) when is_binary(repo_path), do: workflow_path(repo_path, @workflow_file_name)

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec prompt_template(loaded_workflow(), :issue | :pr | String.t() | atom()) :: String.t() | nil
  def prompt_template(%{config: config, prompt_template: prompt}, mode) when is_map(config) do
    mode = mode |> to_string()

    config
    |> Map.get("prompts", %{})
    |> case do
      prompts when is_map(prompts) -> Map.get(prompts, mode)
      _prompts -> nil
    end
    |> case do
      configured when is_binary(configured) -> configured
      _missing when mode == "issue" -> prompt
      _missing -> nil
    end
  end

  def prompt_template(_workflow, _mode), do: nil

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_repo_workflow(content, instructions_on_disk(Path.dirname(path)))

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @spec load_symphony() :: {:ok, map()} | {:error, term()}
  def load_symphony do
    load_symphony(symphony_file_path())
  end

  @spec load_symphony(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_symphony(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_symphony(content)

      {:error, reason} ->
        {:error, {:missing_symphony_file, path, reason}}
    end
  end

  @doc false
  @spec parse_document(String.t()) :: {:ok, {map(), String.t()}} | {:error, term()}
  def parse_document(content) when is_binary(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()
        {:ok, {front_matter, prompt}}

      {:error, :front_matter_not_a_map} ->
        {:error, :front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:front_matter_parse_error, reason}}
    end
  end

  @doc """
  Parses a repo `WORKFLOW.md`, expanding its playbook line with the instruction
  files `read_instructions` returns (none by default).
  """
  @spec parse_repo_workflow(String.t(), Assembly.reader()) :: {:ok, loaded_workflow()} | {:error, term()}
  def parse_repo_workflow(content, read_instructions \\ &no_instructions/1) when is_binary(content) do
    with {:ok, assembled} <- assemble(content, read_instructions) do
      parse_assembled(assembled)
    end
  end

  @doc """
  Returns the `WORKFLOW.md` text with its playbook line expanded, front matter
  unchanged, or the same text when the body has no such line. A snapshot of the
  result loads without the instruction files.
  """
  @spec assemble(String.t(), Assembly.reader()) :: {:ok, String.t()} | {:error, term()}
  def assemble(content, read_instructions) when is_binary(content) do
    {head, body} = split_body(content)

    if Enum.any?(body, &Assembly.directive?/1) do
      with {:ok, _workflow} <- parse_assembled(content),
           {:ok, {front_matter, _prompt}} <- parse_document(content),
           {:ok, body} <- Assembly.expand(body, Map.get(front_matter, "playbook") || %{}, read_instructions) do
        {:ok, Enum.join(head ++ body, "\n")}
      end
    else
      {:ok, content}
    end
  end

  @doc """
  Returns the directory the playbook line of the `WORKFLOW.md` at `path` with `content`
  reads its instruction files from, or nil when the body has no such line.
  """
  @spec instructions_path(Path.t(), String.t()) :: Path.t() | nil
  def instructions_path(path, content) when is_binary(path) and is_binary(content) do
    {_head, body} = split_body(content)

    with true <- Enum.any?(body, &Assembly.directive?/1),
         {:ok, {front_matter, _prompt}} <- parse_document(content),
         settings when is_map(settings) <- Map.get(front_matter, "playbook") || %{},
         dir when is_binary(dir) <- Assembly.instructions_dir(settings) do
      Path.expand(dir, Path.dirname(path))
    else
      _no_playbook -> nil
    end
  end

  @doc """
  Stamps the instruction files in `dir` (`instructions_path/2`) by name, type, size and
  modification time, so a cache of a workflow expanded from them can tell when to load it
  again. Nil for no directory.
  """
  @spec instructions_stamp(Path.t() | nil) :: term()
  def instructions_stamp(nil), do: nil

  def instructions_stamp(dir) when is_binary(dir) do
    case File.ls(dir) do
      {:ok, names} -> for name <- Enum.sort(names), Assembly.instruction_file?(name), do: file_stamp(dir, name)
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_stamp(dir, name) do
    case File.lstat(Path.join(dir, name), time: :posix) do
      {:ok, stat} -> {name, stat.type, stat.size, stat.mtime}
      {:error, reason} -> {name, reason}
    end
  end

  @doc """
  Reads the instruction files of a playbook directory relative to `base_dir`; a
  missing directory has none. Only regular files count: a symlink or directory with an
  instruction file's name is skipped, as it is on a git ref.
  """
  @spec instructions_on_disk(Path.t()) :: Assembly.reader()
  def instructions_on_disk(base_dir) when is_binary(base_dir) do
    fn dir ->
      dir = Path.expand(dir, base_dir)

      case File.ls(dir) do
        {:ok, names} -> names |> Enum.filter(&Assembly.instruction_file?/1) |> read_files(dir)
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_files(names, dir) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, files} ->
      path = Path.join(dir, name)

      with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
           {:ok, body} <- File.read(path) do
        {:cont, {:ok, [{name, body} | files]}}
      else
        {:ok, %File.Stat{}} -> {:cont, {:ok, files}}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  defp no_instructions(_dir), do: {:ok, []}

  defp parse_assembled(content) do
    with {:ok, {front_matter, prompt}} <- parse_document(content),
         {:ok, repo_config} <- RepoWorkflowSchema.parse(front_matter) do
      {:ok,
       %{
         config: RepoWorkflowSchema.to_config_map(repo_config),
         prompt: prompt,
         prompt_template: prompt
       }}
    else
      {:error, :front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, {:front_matter_parse_error, reason}} ->
        {:error, {:workflow_parse_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec parse_symphony(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_symphony(content) when is_binary(content) do
    if String.trim(content) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(content) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _decoded} -> {:error, :symphony_file_not_a_map}
        {:error, reason} -> {:error, {:symphony_parse_error, reason}}
      end
    end
  end

  # The front matter lines, delimiters included, and the body lines.
  defp split_body(content) do
    lines = String.split(content, ~r/\R/, trim: false)
    Enum.split(lines, front_matter_length(lines))
  end

  # Lines of the front matter block, both `---` delimiters included.
  defp front_matter_length(["---" | tail]) do
    case Enum.split_while(tail, &(&1 != "---")) do
      {front, ["---" | _prompt_lines]} -> length(front) + 2
      {front, []} -> length(front) + 1
    end
  end

  defp front_matter_length(_lines), do: 0

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp workflow_path(repo_path, workflow) do
    case Path.type(workflow) do
      :absolute -> Path.expand(workflow)
      _type -> Path.expand(workflow, Path.expand(repo_path))
    end
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end
