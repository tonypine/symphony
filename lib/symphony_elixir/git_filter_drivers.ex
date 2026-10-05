defmodule SymphonyElixir.GitFilterDrivers do
  @moduledoc """
  Turns off the filter drivers a repo's git config defines, for Symphony's host-side git.

  A filter driver (`filter.<name>.clean`, `.smudge` or `.process`) is a shell command git runs
  as the operator when it writes a work-tree file whose attributes name the driver, or reads one
  back: `worktree add`, `checkout`, `reset`, `status`, `add`. Agents commit in the repo, so its
  config may hold a driver they wrote, and a branch's `.gitattributes` picks it. `config_args/3`
  returns `-c` overrides that blank the commands of every driver the command could load and turn
  off `required`, so git keeps those files as the repo stores them.

  It lists the drivers in the config the command reads, and in every file that config includes,
  whatever the include's condition: an `includeIf "gitdir:..."` can apply only in the worktree
  `worktree add` creates.
  """

  @typedoc "Runs git with the given arguments and options, returning stdout, exit status and stderr."
  @type reader :: ([String.t()], keyword() -> {String.t(), non_neg_integer(), String.t()})

  # Subcommands that never read or write a work-tree file's content, so no filter runs.
  @no_filter_subcommands ~w(branch config fetch for-each-ref log ls-remote ls-tree merge-base remote
                            rev-list rev-parse show show-ref symbolic-ref update-ref)
  # Global options that take their value as the next argument.
  @global_options_with_value ~w(-C -c --git-dir --work-tree --namespace --config-env --attr-source)
  @config_keys "^(filter\\..*\\.(clean|smudge|process|required)|include\\.path|includeif\\..*\\.path)$"
  @list_args ["-z", "--show-origin", "--get-regexp", @config_keys]
  @driver_key ~r/\Afilter\.(.*)\.(?:clean|smudge|process|required)\z/s
  @include_key ~r/\A(?:include|includeif\..*)\.path\z/s
  # Git refuses to follow includes deeper than this.
  @max_include_depth 10

  @doc """
  The `-c` overrides that turn off every filter driver git could load for `args`.

  `read` runs git with Symphony's safe config and env. Returns an error, and the command must not
  run, when the config can't be read or names a driver `-c` can't address (a name with `=`).
  """
  @spec config_args([String.t()], keyword(), reader()) ::
          {:ok, [String.t()]} | {:error, String.t(), pos_integer()}
  def config_args(args, opts, read) when is_list(args) and is_list(opts) and is_function(read, 2) do
    {global_options, subcommand} = split_global_args(args, [])

    if subcommand in @no_filter_subcommands do
      {:ok, []}
    else
      with {:ok, entries} <- read_entries(read, Enum.concat(global_options) ++ ["config" | @list_args], opts) do
        cwd = git_cwd(global_options, opts)

        entries
        |> includes(cwd, 1)
        |> walk_includes(driver_names(entries), MapSet.new(), read, opts)
        |> override_args()
      end
    end
  end

  defp split_global_args([option, value | rest], acc) when option in @global_options_with_value,
    do: split_global_args(rest, [[option, value] | acc])

  defp split_global_args(["-" <> _flag = option | rest], acc), do: split_global_args(rest, [[option] | acc])
  defp split_global_args([subcommand | _rest], acc), do: {Enum.reverse(acc), subcommand}
  defp split_global_args([], acc), do: {Enum.reverse(acc), nil}

  # `git config` prints each origin path relative to the directory git ends up in.
  defp git_cwd(global_options, opts) do
    Enum.reduce(global_options, Path.expand(Keyword.get(opts, :cd, ".")), fn
      ["-C", dir], cwd -> Path.expand(dir, cwd)
      _option, cwd -> cwd
    end)
  end

  defp walk_includes([], names, _seen, _read, _opts), do: names

  defp walk_includes([{path, depth} | rest], names, seen, read, opts) do
    if depth > @max_include_depth or MapSet.member?(seen, path) or not File.regular?(path) do
      walk_includes(rest, names, seen, read, opts)
    else
      # A file git can't parse defines no driver git could load, so a failed read adds nothing.
      entries =
        case read_entries(read, ["config", "--file", path, "--no-includes" | @list_args], opts) do
          {:ok, entries} -> entries
          {:error, _message, _status} -> []
        end

      walk_includes(
        rest ++ includes(entries, Path.dirname(path), depth + 1),
        MapSet.union(names, driver_names(entries)),
        MapSet.put(seen, path),
        read,
        opts
      )
    end
  end

  defp read_entries(read, args, opts) do
    case read.(args, opts) do
      {stdout, 0, _stderr} ->
        {:ok, parse_entries(stdout)}

      # `--get-regexp` exits 1 when no key matches.
      {_stdout, 1, _stderr} ->
        {:ok, []}

      {_stdout, status, stderr} ->
        {:error, "symphony: refusing to run git, reading its config failed: #{String.trim(stderr)}\n", status}
    end
  end

  # `-z --show-origin` prints `<origin>\0<key>\n<value>\0` per entry, and `<origin>\0<key>\0`
  # for a key set without a value.
  defp parse_entries(stdout) do
    stdout
    |> String.split("\0")
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.map(fn [origin, key_value] ->
      case String.split(key_value, "\n", parts: 2) do
        [key, value] -> {origin, key, value}
        [key] -> {origin, key, nil}
      end
    end)
  end

  defp driver_names(entries) do
    for {_origin, key, _value} <- entries, [_key, name] <- [Regex.run(@driver_key, key)], into: MapSet.new(), do: name
  end

  # Git reads a relative include path from the directory of the file that includes it.
  defp includes(entries, cwd, depth) do
    for {origin, key, path} <- entries,
        is_binary(path) and Regex.match?(@include_key, key),
        resolved = resolve_include(path, origin_dir(origin, cwd)),
        do: {resolved, depth}
  end

  defp origin_dir("file:" <> path, cwd), do: path |> Path.expand(cwd) |> Path.dirname()
  defp origin_dir(_origin, _cwd), do: nil

  defp resolve_include("~/" <> path, _dir), do: Path.join(System.user_home!(), path)

  defp resolve_include(path, dir) do
    case Path.type(path) do
      :absolute -> path
      # `~user/...` and `%(prefix)/...` land on no file here and are skipped: git reads them from
      # a home folder or git's install, which agents can't write.
      :relative when is_binary(dir) and path != "" -> Path.expand(path, dir)
      # Git refuses a relative include outside a file.
      _type -> nil
    end
  end

  defp override_args(names) do
    case Enum.find(names, &String.contains?(&1, "=")) do
      nil ->
        {:ok, names |> Enum.sort() |> Enum.flat_map(&driver_args/1)}

      name ->
        {:error, "symphony: refusing to run git, the repo config defines filter driver #{inspect(name)}, which -c can't turn off\n", 128}
    end
  end

  defp driver_args(name) do
    Enum.flat_map(["clean=", "smudge=", "process=", "required=false"], &["-c", "filter.#{name}.#{&1}"])
  end
end
