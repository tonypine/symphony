defmodule Mix.Tasks.PrDecision.Table do
  use Mix.Task

  @shortdoc "Write the PR and CI decision table to docs/pr-ci-decisions.md"

  @moduledoc """
  Writes the PR and CI decision table, generated from `SymphonyElixir.PrDecision.rules/0`, to
  `docs/pr-ci-decisions.md`. Only the part between the generated markers is replaced, so prose
  around it stays.

  Usage:

      mix pr_decision.table [--check] [--path PATH]

  `--check` writes nothing and fails when the file is out of date. `--path` writes another file.
  """

  @requirements ["compile"]

  alias SymphonyElixir.PrDecision.Table

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [check: :boolean, path: :string, help: :boolean], aliases: [h: :help])
    path = Keyword.get(opts, :path, Table.path())

    cond do
      opts[:help] -> Mix.shell().info(@moduledoc)
      invalid != [] -> Mix.raise("Invalid option(s): #{inspect(invalid)}")
      opts[:check] -> check(path)
      true -> write(path)
    end
  end

  defp check(path) do
    current = read(path)

    if Table.update(current) == current do
      Mix.shell().info("#{path} is up to date")
    else
      Mix.raise("#{path} is out of date: run mix pr_decision.table")
    end
  end

  defp write(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Table.update(read(path)))
    Mix.shell().info("Wrote #{path}")
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> ""
    end
  end
end
