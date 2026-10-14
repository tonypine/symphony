defmodule SymphonyElixir.QaDriver.Checks do
  @moduledoc """
  The checks both host-side QA drivers share: the QA worktree's git status,
  screenshot names, the evidence files they write, the fixture files the agent
  hands them and their private directories (see
  `SymphonyElixir.QaDriver` and `SymphonyElixir.QaAndroid.Driver`).
  """

  alias SymphonyElixir.{AgentEnv, Paths, PathSafety}

  @evidence_dir "qa-evidence"
  @screenshot_name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @fixture_limit 1_000_000
  @fixture_name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
  @fixture_dir_limit 5_000_000
  @fixture_dir_files 1_000
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

  @doc """
  Checks a `local_path` argument: a non-empty string without NUL bytes, at
  most 4 KB.
  """
  @spec fixture_path(term()) :: {:ok, String.t()} | tool_error()
  def fixture_path(path) when is_binary(path) and path != "" and byte_size(path) <= 4_096 do
    if String.contains?(path, <<0>>), do: tool_error("invalid_arguments", "`local_path` must not contain NUL bytes."), else: {:ok, path}
  end

  def fixture_path(_path), do: tool_error("invalid_arguments", "`local_path` is required: a file under #{@evidence_dir}/ or $TMPDIR.")

  @doc "Whether `name` is a fixture's file name on the device or QA host: letters, digits, `.`, `_`, `-`."
  @spec fixture_name?(term()) :: boolean()
  def fixture_name?(name), do: is_binary(name) and Regex.match?(@fixture_name, name)

  @doc """
  The folders a fixture may come from: the canonical `worktree` and, when the
  pass has one, its `$TMPDIR`, resolved (`/tmp` is a link on macOS; the check
  compares resolved paths).
  """
  @spec fixture_roots(Path.t(), Path.t() | nil) :: [Path.t()]
  def fixture_roots(worktree, nil), do: [worktree]

  def fixture_roots(worktree, tmp_dir) do
    {:ok, canonical} = PathSafety.canonicalize(tmp_dir)
    [worktree, canonical]
  end

  @doc """
  Reads a fixture file the agent wrote, for `tool`, and returns its resolved
  path and bytes. Symphony reads files the agent's sandbox may not, so only a
  regular file the agent wrote itself passes: inside one of `roots` (the
  worktree, the pass's `$TMPDIR`) once every link on the way is resolved, not a
  link itself, with no other hard link, which could name a file elsewhere, and
  of at most 1 MB. The read goes through one descriptor that must be the file
  just checked, so a path swapped after the check is refused. A refusal's code
  is `<tool>_refused`. A relative `local_path` is relative to `worktree`.
  """
  @spec read_fixture([Path.t()], Path.t(), String.t(), String.t()) :: {:ok, Path.t(), binary()} | tool_error()
  def read_fixture(roots, worktree, local_path, tool) do
    path = Path.expand(local_path, worktree)

    with {:ok, _stat} <- fixture_lstat(path, local_path, tool),
         {:ok, canonical} <- inside_roots(roots, path, local_path, tool),
         {:ok, stat} <- fixture_lstat(canonical, local_path, tool),
         :ok <- single_regular_file(stat, local_path, tool),
         {:ok, bytes} <- read_checked(canonical, stat, local_path, tool, @fixture_limit) do
      {:ok, canonical, bytes}
    end
  end

  @doc """
  Reads a fixture directory for `tool`'s `argument` (`api_fixtures`) and returns
  its resolved path and every file in it as `{relative path, bytes}`, sorted.
  `dir_path` is relative to the canonical `worktree` (the PR checkout) and must
  resolve, every link on the way followed, to a directory inside it and outside
  its `.git`. Every
  entry under it must be a directory or a regular file with no other hard
  link, never a symlink, and the files must total at most 5 MB and 1000 files.
  Each file is read like `read_fixture/4` reads one, so a file swapped after
  the check is refused. A refusal's code is `<tool>_refused`.
  """
  @spec read_fixture_dir(Path.t(), term(), String.t(), String.t()) ::
          {:ok, Path.t(), [{String.t(), binary()}]} | tool_error()
  def read_fixture_dir(worktree, dir_path, argument, tool) do
    with {:ok, relative} <- fixture_dir_path(dir_path, argument),
         {:ok, dir} <- fixture_dir(worktree, relative, tool),
         {:ok, files, _total} <- walk_fixture_dir(dir, nil, {[], 0}, relative, tool) do
      {:ok, dir, Enum.reverse(files)}
    end
  end

  defp fixture_dir_path(path, argument) when is_binary(path) and path != "" and byte_size(path) <= 4_096 do
    cond do
      String.contains?(path, <<0>>) -> tool_error("invalid_arguments", "`#{argument}` must not contain NUL bytes.")
      Path.type(path) != :relative -> tool_error("invalid_arguments", "`#{argument}` must be relative to the PR checkout.")
      true -> {:ok, path}
    end
  end

  defp fixture_dir_path(_path, argument), do: tool_error("invalid_arguments", "`#{argument}` must be a directory path relative to the PR checkout.")

  defp fixture_dir(worktree, relative, tool) do
    with {:ok, canonical} <- PathSafety.canonicalize(Path.expand(relative, worktree)),
         true <- String.starts_with?(canonical, worktree <> "/") do
      git? = ".git" in Path.split(Path.relative_to(canonical, worktree))

      case File.lstat(canonical) do
        _stat when git? -> refused(tool, "#{relative} is in the checkout's .git directory. Pass a fixtures directory.")
        {:ok, %File.Stat{type: :directory}} -> {:ok, canonical}
        {:ok, _stat} -> refused(tool, "#{relative} is not a directory.")
        {:error, reason} -> refused(tool, "#{relative} could not be read: #{inspect(reason)}.")
      end
    else
      _other -> refused(tool, "#{relative} resolves outside the PR checkout. Pass a directory in the checkout, like macos/Tests/Fixtures/<name>.")
    end
  end

  defp walk_fixture_dir(dir, prefix, acc, label, tool) do
    case File.ls(dir) do
      {:ok, names} -> walk_fixture_entries(Enum.sort(names), dir, prefix, acc, label, tool)
      {:error, reason} -> refused(tool, "#{Path.join([label | List.wrap(prefix)])} could not be listed: #{inspect(reason)}.")
    end
  end

  defp walk_fixture_entries([], _dir, _prefix, {files, total}, _label, _tool), do: {:ok, files, total}

  defp walk_fixture_entries([name | rest], dir, prefix, acc, label, tool) do
    relative = if prefix, do: Path.join(prefix, name), else: name

    with {:ok, files, total} <- fixture_dir_entry(Path.join(dir, name), relative, acc, label, tool) do
      walk_fixture_entries(rest, dir, prefix, {files, total}, label, tool)
    end
  end

  defp fixture_dir_entry(path, relative, acc, label, tool) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> walk_fixture_dir(path, relative, acc, label, tool)
      {:ok, %File.Stat{type: :regular, links: 1} = stat} -> fixture_dir_file(path, stat, relative, acc, label, tool)
      {:ok, stat} -> fixture_dir_refusal(stat, Path.join(label, relative), tool)
      {:error, reason} -> refused(tool, "#{Path.join(label, relative)} could not be read: #{inspect(reason)}.")
    end
  end

  defp fixture_dir_file(path, stat, relative, {files, total} = acc, label, tool) do
    cond do
      length(files) >= @fixture_dir_files -> refused(tool, "#{label} holds more than #{@fixture_dir_files} files.")
      total + stat.size > @fixture_dir_limit -> refused(tool, "#{label} holds over #{@fixture_dir_limit} bytes.")
      true -> read_fixture_dir_file(path, stat, relative, acc, Path.join(label, relative), tool)
    end
  end

  defp fixture_dir_refusal(%File.Stat{type: :symlink}, shown, tool),
    do: refused(tool, "#{shown} is a symlink. A fixture directory may hold only regular files.")

  defp fixture_dir_refusal(%File.Stat{type: :regular}, shown, tool),
    do: refused(tool, "#{shown} has other hard links. A fixture directory may hold only files of its own.")

  defp fixture_dir_refusal(_stat, shown, tool),
    do: refused(tool, "#{shown} is not a regular file. A fixture directory may hold only regular files.")

  defp read_fixture_dir_file(path, stat, relative, {files, total}, shown, tool) do
    with {:ok, bytes} <- read_checked(path, stat, shown, tool, @fixture_dir_limit - total) do
      {:ok, [{relative, bytes} | files], total + byte_size(bytes)}
    end
  end

  defp fixture_lstat(path, local_path, tool) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :symlink}} -> refused(tool, "#{local_path} is a symlink. Pass the regular file itself.")
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> refused(tool, "#{local_path} could not be read: #{inspect(reason)}.")
    end
  end

  defp inside_roots(roots, path, local_path, tool) do
    with {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- Enum.any?(roots, &String.starts_with?(canonical, &1 <> "/")) do
      {:ok, canonical}
    else
      _other ->
        refused(tool, "#{local_path} is outside the QA worktree and $TMPDIR. Write the fixture under #{@evidence_dir}/ or $TMPDIR first.")
    end
  end

  defp single_regular_file(%File.Stat{type: :regular, links: 1, size: size}, _local_path, _tool) when size <= @fixture_limit, do: :ok
  defp single_regular_file(%File.Stat{type: :regular, links: 1}, local_path, tool), do: refused(tool, "#{local_path} is over #{@fixture_limit} bytes.")
  defp single_regular_file(%File.Stat{type: :regular}, local_path, tool), do: refused(tool, "#{local_path} has other hard links. Write a fresh copy.")
  defp single_regular_file(_stat, local_path, tool), do: refused(tool, "#{local_path} is not a regular file.")

  defp read_checked(path, stat, local_path, tool, limit) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          read_opened(fd, path, stat, local_path, tool, limit)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        refused(tool, "#{local_path} could not be read: #{inspect(reason)}.")
    end
  end

  defp read_opened(fd, path, stat, local_path, tool, limit) do
    {:ok, info} = :file.read_file_info(fd, time: :posix)
    opened = File.Stat.from_record(info)

    bytes =
      case :file.read(fd, limit + 1) do
        {:ok, bytes} -> bytes
        :eof -> ""
      end

    same_file? = same_inode?(opened, stat) and opened.links == 1 and still_at?(path, opened)
    complete? = byte_size(bytes) <= limit
    if same_file? and complete?, do: {:ok, bytes}, else: refused(tool, "#{local_path} changed while it was read; leave it alone during #{tool}.")
  end

  defp same_inode?(a, b), do: {a.type, a.inode, a.major_device} == {b.type, b.inode, b.major_device}

  # A folder on the way swapped for a link before the open makes the path
  # resolve elsewhere afterwards, or name another file once it is swapped back.
  defp still_at?(path, %File.Stat{type: type, inode: inode, major_device: device}) do
    match?({:ok, ^path}, PathSafety.canonicalize(path)) and
      match?({:ok, %File.Stat{type: ^type, inode: ^inode, major_device: ^device}}, File.lstat(path))
  end

  defp refused(tool, message), do: tool_error(tool <> "_refused", message)

  defp tool_error(code, message), do: {:error, {:qa_tool, code, message}}

  defp tail(output, limit) when byte_size(output) > limit, do: "…" <> binary_part(output, byte_size(output) - limit, limit)
  defp tail(output, _limit), do: output
end
