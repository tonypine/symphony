defmodule SymphonyElixir.Init do
  @moduledoc """
  Scaffolds a minimal operator `symphony.yml`.
  """

  alias SymphonyElixir.Config.SystemSchema

  @symphony_file "symphony.yml"
  @switches [force: :boolean]
  @aliases [f: :force]
  @usage "Usage: symphony init [--force]"
  @scaffold """
  issues:
    provider: linear
  workspaces:
    root: .symphony/workspaces
  execution:
    harnesses:
      claude:
        command: claude --dangerously-skip-permissions --verbose
        small_model:
          anthropic: claude-haiku-4-5
  runs:
    default:
      harness: claude
      provider: anthropic
      model: claude-opus-5-5
  repositories:
    - key: default
      workflow: WORKFLOW.md
  """

  @type result :: {:ok, String.t()} | {:error, String.t()}

  @spec run([String.t()]) :: result()
  def run(args) do
    case File.cwd() do
      {:ok, cwd} -> run(args, cwd: cwd)
      {:error, reason} -> {:error, "Failed to read current directory: #{inspect(reason)}"}
    end
  end

  @spec run([String.t()], keyword()) :: result()
  def run(args, opts) do
    with {:ok, parsed_opts} <- parse_args(args),
         :ok <- validate_scaffold(@scaffold) do
      cwd = Keyword.fetch!(opts, :cwd)
      path = Path.join(cwd, @symphony_file)
      write_scaffold(path, @scaffold, Keyword.get(parsed_opts, :force, false))
    end
  end

  @spec scaffold() :: String.t()
  def scaffold, do: @scaffold

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, [], []} -> {:ok, opts}
      {_opts, _argv, [{flag, _value} | _rest]} -> {:error, "Unknown option #{flag}\n#{@usage}"}
      {_opts, [extra | _rest], []} -> {:error, "Unexpected argument #{extra}\n#{@usage}"}
    end
  end

  defp validate_scaffold(content) do
    with {:ok, config} <- YamlElixir.read_from_string(content),
         {:ok, _system_config} <- SystemSchema.parse(config) do
      :ok
    else
      {:error, {:invalid_symphony_config, message}} ->
        {:error, "Generated symphony.yml failed schema validation: #{message}"}

      {:error, reason} ->
        {:error, "Generated symphony.yml failed schema validation: #{inspect(reason)}"}
    end
  end

  defp write_scaffold(path, content, force?) do
    if File.regular?(path) and not force? do
      case File.read(path) do
        {:ok, existing} -> {:error, conflict_message(path, existing, content)}
        {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
      end
    else
      case File.write(path, content) do
        :ok -> {:ok, "Wrote #{path}"}
        {:error, reason} -> {:error, "Failed to write #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp conflict_message(path, existing, generated) do
    """
    #{path} already exists. Use `symphony init --force` to overwrite it.

    Diff:
    #{diff(existing, generated)}\
    """
  end

  defp diff(existing, generated) do
    existing_lines = String.split(existing, "\n", trim: false)
    generated_lines = String.split(generated, "\n", trim: false)

    body =
      existing_lines
      |> List.myers_difference(generated_lines)
      |> Enum.flat_map(&format_diff_chunk/1)
      |> Enum.join("\n")

    """
    --- symphony.yml
    +++ symphony.yml (generated)
    #{body}
    """
  end

  defp format_diff_chunk({:eq, lines}), do: Enum.map(lines, &" #{&1}")
  defp format_diff_chunk({:del, lines}), do: Enum.map(lines, &"-#{&1}")
  defp format_diff_chunk({:ins, lines}), do: Enum.map(lines, &"+#{&1}")
end
