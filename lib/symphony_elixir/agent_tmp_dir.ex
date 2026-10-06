defmodule SymphonyElixir.AgentTmpDir do
  @moduledoc """
  A private temp folder for an agent run or a QA pass, so the agent's `$TMPDIR` is its own
  rather than the `/tmp/claude-<uid>` every Claude session shares or Symphony's own temp
  folder, and concurrent runs never write over each other's temp files.

  A Claude session gets the folder as `CLAUDE_CODE_TMPDIR` and a Codex session as `TMPDIR`
  (see `env/3`), and the folder is added to the session's sandbox writable paths (see
  `allow_write/2`). A folder is named after a short hash of the workspace or worktree it
  belongs to, so the path stays short (Claude Code keeps sockets under it) and the
  stray-process watchdog can name the folders of the runs in flight.
  """

  alias SymphonyElixir.Config.Schema

  @doc """
  The folders `owner` may use, one under each of `bases`, named `prefix` followed by a short
  hash of `owner`. The caller takes the first one `create/1` can make.
  """
  @spec paths(String.t(), Path.t(), [Path.t()]) :: [Path.t()]
  def paths(prefix, owner, bases) do
    id = :sha256 |> :crypto.hash(owner) |> binary_part(0, 6) |> Base.encode16(case: :lower)
    Enum.map(bases, &Path.join(&1, prefix <> id))
  end

  @doc "`/tmp` first; a sandboxed Symphony that can't write there falls back to its own temp folder."
  @spec default_bases() :: [Path.t()]
  def default_bases, do: Enum.uniq(["/tmp", System.tmp_dir!()])

  @doc """
  Creates the first of `paths` it can, private, as Claude Code requires of
  `CLAUDE_CODE_TMPDIR`. A folder left by an earlier run is removed first, so it never
  carries over.
  """
  @spec create([Path.t()]) :: {:ok, Path.t()} | :error
  def create(paths) do
    Enum.find_value(paths, :error, fn path ->
      File.rm_rf(path)
      if File.mkdir(path) == :ok and File.chmod(path, 0o700) == :ok, do: {:ok, path}
    end)
  end

  @doc """
  The session env that puts `dir` behind the agent's `$TMPDIR`: Claude Code puts the
  `$TMPDIR` of the commands it runs under `CLAUDE_CODE_TMPDIR`; Codex passes its own
  `TMPDIR` on to them. Without a folder the session keeps its runtime's default.

  On macOS (`os_type`, default `:os.type()`) a Claude session also gets the env that lets
  `swift build` and `swift test` write in its sandbox. A sandboxed process's Foundation
  stages every `Data.write(options: .atomic)` in `<DARWIN_USER_TEMP_DIR>/TemporaryItems`,
  which the sandbox can't open: macOS refuses to read that folder, so Claude Code withholds
  an `allowWrite` entry for it. `DIRHELPER_USER_DIR_SUFFIX` holding a `/` is a suffix libc
  rejects, so `confstr(_CS_DARWIN_USER_TEMP_DIR)` falls back to `$TMPDIR` and Foundation
  stages the write beside the file it replaces. The per-user cache dir then has no value,
  so `SWIFTPM_MODULECACHE_OVERRIDE` gives SwiftPM a module cache in `dir`.
  """
  @spec env(String.t() | nil, Path.t() | nil, {atom(), atom()}) :: %{String.t() => String.t()}
  def env(kind, dir, os_type \\ :os.type()), do: session_env(kind, dir, os_type)

  defp session_env(_kind, nil, _os_type), do: %{}
  defp session_env("claude", dir, {:unix, :darwin}), do: Map.merge(%{"CLAUDE_CODE_TMPDIR" => dir}, swift_env(dir))
  defp session_env("claude", dir, _os_type), do: %{"CLAUDE_CODE_TMPDIR" => dir}
  defp session_env(_kind, dir, _os_type), do: %{"TMPDIR" => dir}

  defp swift_env(dir) do
    %{
      "DIRHELPER_USER_DIR_SUFFIX" => "symphony/none",
      "SWIFTPM_MODULECACHE_OVERRIDE" => Path.join(dir, "swiftpm-module-cache")
    }
  end

  @doc "`settings` with `dir` writable in the agent sandbox, whatever the runtime's default writable set is."
  @spec allow_write(Schema.t(), Path.t()) :: Schema.t()
  def allow_write(%Schema{} = settings, dir) do
    update_in(settings.workspace.sandbox.allow_write_paths, &(&1 ++ [dir]))
  end
end
