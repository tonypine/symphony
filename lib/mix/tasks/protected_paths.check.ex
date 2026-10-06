defmodule Mix.Tasks.ProtectedPaths.Check do
  use Mix.Task

  @shortdoc "Fail when a branch's own commits change an agent-protected path"

  @moduledoc """
  Fails when `--head` changes a path the agent sandbox write-protects (`.ai/skills`,
  `WORKFLOW.md`, ...), or a file a symlink in one points at, since it forked from `--base`.
  Changes merged from `--base` don't count: the diff starts at the merge-base with it.

  `github_sync_base` and `github_push_branch` refuse such a branch, but a shell `git push` skips
  them. CI runs this on Symphony's pull requests to cover that.

  Usage:

      mix protected_paths.check --base origin/main [--head HEAD] [--repo PATH]

  `--repo` is the git repository to read, the current directory by default.
  """

  alias SymphonyElixir.AgentTools.ProtectedPaths

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args, strict: [base: :string, head: :string, repo: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      is_nil(opts[:base]) ->
        Mix.raise("Missing required option --base")

      true ->
        check(opts[:base], Keyword.get(opts, :head, "HEAD"), Keyword.get(opts, :repo, "."))
    end
  end

  defp check(base, head, repo) do
    case ProtectedPaths.verify(base, head, nil, &run_git(&1, repo)) do
      :ok ->
        Mix.shell().info("No agent-protected path changed since #{head} forked from #{base}.")

      {:error, {:protected_paths_changed, files}} ->
        Enum.each(files, &Mix.shell().error("Changed: #{&1}"))
        Mix.raise("#{head} changes paths the agent sandbox write-protects since it forked from #{base}.")

      {:error, {:git_failed, args, status, output}} ->
        Mix.raise("git #{Enum.join(args, " ")} failed with #{status}: #{String.trim(output)}")
    end
  end

  defp run_git(args, repo) do
    case System.cmd("git", SymphonyElixir.GitConfigCommands.subcommand_args(args), cd: repo, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end
end
