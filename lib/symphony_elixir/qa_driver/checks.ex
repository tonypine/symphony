defmodule SymphonyElixir.QaDriver.Checks do
  @moduledoc """
  The checks both host-side QA drivers share: the QA worktree's git status,
  screenshot names, the evidence files they write and their private
  directories (see
  `SymphonyElixir.QaDriver` and `SymphonyElixir.QaAndroid.Driver`).
  """

  alias SymphonyElixir.{AgentEnv, Paths, PathSafety}

  @evidence_dir "qa-evidence"
  @screenshot_name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  # Every tool error that stops an app part says this, so the other playbooks still run.
  @blocked_hint "Mark the app steps you could not check `blocked` with this reason, finish the other playbooks' steps " <>
                  "(pass or fail), then answer with verdict `blocked` and this reason."

  @type git :: ([String.t()], Path.t() -> {Collectable.t(), integer()})
  @type tool_error :: {:error, {:qa_tool, String.t(), String.t()}}

  @doc "The folder in the QA worktree that holds the agent's evidence."
  @spec evidence_dir() :: String.t()
  def evidence_dir, do: @evidence_dir

  @doc "What a tool error that stops an app part tells the agent to do."
  @spec blocked_hint() :: String.t()
  def blocked_hint, do: @blocked_hint

  @doc """
  Runs `git status --porcelain=v1 -z` with `flags` in the worktree and returns
  its ignored (`!!`) and other paths. Paths under `qa-evidence/` are left out,
  and so are new or ignored files in the folders Symphony itself creates in the
  QA agent's workspace (see `SymphonyElixir.AgentEnv.owned_dirs/0`); a change to
  a tracked file there still counts.
  """
  @spec worktree_status(git(), Path.t(), [String.t()]) :: {:ok, [String.t()], [String.t()]} | tool_error()
  def worktree_status(git, worktree, flags) do
    case git.(["status", "--porcelain=v1", "-z" | flags], worktree) do
      {output, 0} ->
        {ignored, dirty} =
          output
          |> to_string()
          |> String.split(<<0>>, trim: true)
          |> Enum.reject(&skipped?/1)
          |> Enum.split_with(&String.starts_with?(&1, "!! "))

        {:ok, Enum.map(ignored, &String.slice(&1, 3..-1//1)), Enum.map(dirty, &String.slice(&1, 3..-1//1))}

      {output, status} ->
        tool_error("qa_git_failed", "git status failed (exit #{status}): #{tail(to_string(output), 500)}")
    end
  end

  defp skipped?(entry) do
    {status, path} = String.split_at(entry, 3)

    String.starts_with?(path, @evidence_dir <> "/") or
      (status in ["?? ", "!! "] and Enum.any?(AgentEnv.owned_dirs(), &String.starts_with?(path, &1 <> "/")))
  end

  @doc """
  Creates a new `0700` directory for one pass under `<state root>/<name>/runs`
  and returns its canonical path. It is not under `System.tmp_dir!/0`, which the
  agent sandbox may write.
  """
  @spec private_dir(String.t()) :: Path.t()
  def private_dir(name) do
    runs = Path.join([Paths.state_root(), name, "runs"])
    File.mkdir_p!(runs)
    File.chmod!(runs, 0o700)
    dir = Path.join(runs, "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    {:ok, canonical} = PathSafety.canonicalize(dir)
    canonical
  end

  @doc "The error for a worktree with `changed` paths outside `qa-evidence/`."
  @spec worktree_modified([String.t()], String.t()) :: tool_error()
  def worktree_modified(changed, advice) do
    tool_error(
      "qa_worktree_modified",
      "The QA worktree has changes outside #{@evidence_dir}/ (#{Enum.join(Enum.take(changed, 5), ", ")}). QA tests the PR head as pushed; #{advice}"
    )
  end

  @doc "Checks a screenshot name (a trailing `.png` is dropped)."
  @spec screenshot_name(term()) :: {:ok, String.t()} | tool_error()
  def screenshot_name(name) when is_binary(name) do
    name = String.replace_suffix(name, ".png", "")

    if Regex.match?(@screenshot_name, name) do
      {:ok, name}
    else
      tool_error("invalid_arguments", "`name` must be 1-64 characters of letters, digits, `.`, `_` or `-`, starting with a letter or digit.")
    end
  end

  def screenshot_name(_name), do: tool_error("invalid_arguments", "`name` is required.")

  @doc "Returns `qa-evidence/` in the worktree, creating it; a symlink or file there is refused."
  @spec ensure_evidence_dir(Path.t()) :: {:ok, Path.t()} | tool_error()
  def ensure_evidence_dir(worktree) do
    dir = Path.join(worktree, @evidence_dir)

    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, dir}

      {:error, :enoent} ->
        case File.mkdir(dir) do
          :ok -> {:ok, dir}
          {:error, reason} -> tool_error("qa_evidence_unsafe", "#{@evidence_dir}/ could not be created in the QA worktree: #{inspect(reason)}.")
        end

      _other ->
        tool_error("qa_evidence_unsafe", "#{@evidence_dir}/ in the QA worktree must be a plain directory, not a symlink or file.")
    end
  end

  @doc """
  Writes `png` to `destination` as a new file. `:exclusive` is O_CREAT|O_EXCL:
  it never follows, replaces or removes a symlink or file the agent left at the
  name, so a screenshot cannot be redirected outside `qa-evidence/`.
  """
  @spec write_evidence(Path.t(), binary(), String.t()) :: :ok | tool_error()
  def write_evidence(destination, png, file) do
    case File.write(destination, png, [:exclusive]) do
      :ok ->
        :ok

      {:error, :eexist} ->
        tool_error("qa_screenshot_exists", "#{@evidence_dir}/#{file} already exists. Give each screenshot a new name.")

      {:error, reason} ->
        tool_error("qa_screenshot_failed", "Could not save #{@evidence_dir}/#{file}: #{inspect(reason)}.")
    end
  end

  defp tool_error(code, message), do: {:error, {:qa_tool, code, message}}

  defp tail(output, limit) when byte_size(output) > limit, do: "…" <> binary_part(output, byte_size(output) - limit, limit)
  defp tail(output, _limit), do: output
end
