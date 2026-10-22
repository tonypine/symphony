defmodule SymphonyElixir.Artifacts.Transcript do
  @moduledoc """
  Where an agent session's transcript sits, so `SymphonyElixir.Artifacts` can keep a copy of it.

  Claude Code writes a session's transcript to
  `~/.claude/projects/<the session's working directory>/<session id>.jsonl`, the folder named after
  the working directory with every character other than a letter or a digit as `-`. That folder is
  one of Symphony's sensitive paths (`SymphonyElixir.SensitivePath`), so a transcript is only ever
  a `.jsonl` file under it (`root/1`), and an ingest names it as its only root. Codex keeps no
  transcript Symphony reads.
  """

  require Logger

  @type runtime :: :claude | :codex

  @doc """
  The folder Claude Code keeps its sessions' transcripts in: `~/.claude/projects`, or the
  application's `:claude_projects_dir` when set.
  """
  @spec root(:claude) :: Path.t()
  def root(:claude) do
    Path.expand(Application.get_env(:symphony_elixir, :claude_projects_dir) || "~/.claude/projects")
  end

  @doc """
  The transcript of a session of `runtime` run in `cwd` with `session_id`: `reported_path`, the path
  the run reported, when it is a `.jsonl` file under `root/1` (any other is ignored and logged);
  otherwise, for a Claude Code session, its file under `root/1` when it exists. A Codex session and
  a session with no id or working directory have none.
  """
  @spec locate(runtime() | nil, Path.t() | nil, String.t() | nil, Path.t() | nil) :: {:ok, Path.t()} | :none
  def locate(:claude, cwd, session_id, reported_path) do
    case reported(reported_path) do
      {:ok, path} -> {:ok, path}
      :none -> derived(cwd, session_id)
    end
  end

  def locate(_runtime, _cwd, _session_id, _reported_path), do: :none

  defp reported(path) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    if transcript_file?(expanded) and String.starts_with?(expanded, root(:claude) <> "/") do
      {:ok, expanded}
    else
      Logger.warning("Ignoring the reported transcript path #{inspect(path)}: a transcript is a .jsonl file under #{root(:claude)}")
      :none
    end
  end

  defp reported(_path), do: :none

  defp derived(cwd, session_id) when is_binary(cwd) and cwd != "" and is_binary(session_id) do
    path = Path.join([root(:claude), project_folder(cwd), session_id <> ".jsonl"])
    if String.match?(session_id, ~r/\A[A-Za-z0-9_-]+\z/) and File.regular?(path), do: {:ok, path}, else: :none
  end

  defp derived(_cwd, _session_id), do: :none

  defp project_folder(cwd), do: String.replace(cwd, ~r/[^A-Za-z0-9]/, "-")

  defp transcript_file?(path), do: Path.extname(path) == ".jsonl"
end
