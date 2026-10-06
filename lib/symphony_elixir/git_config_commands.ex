defmodule SymphonyElixir.GitConfigCommands do
  @moduledoc """
  Keeps Symphony's host-side git from running the commands a repo's git config names.

  Agents commit in the repo, so its config may hold a command they wrote, and a branch's
  `.gitattributes` picks the files it runs on. Git runs these as the operator:

    * a filter driver (`filter.<name>.clean`, `.smudge` or `.process`) when it writes a work-tree
      file whose attributes name the driver, or reads one back: `worktree add`, `checkout`,
      `reset`, `status`, `add`. `config_args/3` blanks its commands and turns off `required`, so
      git keeps those files as the repo stores them;
    * a merge driver (`merge.<name>.driver`) when `merge` merges such a file. `config_args/3`
      replaces it with `git merge-file`, which merges the file as git does when no driver is set;
    * a diff driver (`diff.external`, `diff.<name>.command` and `.textconv`) when `diff`, `log`,
      `show`, `whatchanged`, `blame` or `format-patch` print a patch or a file, and the config's
      `remote.<name>.uploadpack` or `.receivepack` when `fetch`, `ls-remote`, `pull` or `push`
      reach a remote on the same machine. `subcommand_args/1` passes the options that turn these
      off: the config's value wins over a `-c` one for the two remote keys, and an empty diff
      driver makes git fail. `diff-tree`, `diff-index` and `diff-files` run a diff driver only
      when asked with `--ext-diff` or `--textconv`, so they need neither option. `config_args/3`
      refuses `range-diff`: the `git log -p` it runs for each range gets neither option, so it
      runs the textconv drivers whatever options `range-diff` itself gets.

  `config_args/3` lists the drivers in the config the command reads, and in every file that
  config includes, whatever the include's condition: an `includeIf "gitdir:..."` can apply only
  in the worktree `worktree add` creates.

  `shell_functions/0` blanks the filter drivers the same way in the scripts Symphony runs on an
  SSH worker.
  """

  @typedoc "Runs git with the given arguments and options, returning stdout, exit status and stderr."
  @type reader :: ([String.t()], keyword() -> {String.t(), non_neg_integer(), String.t()})

  # Subcommands that never read or write a work-tree file's content, so no filter or merge driver
  # runs.
  @no_filter_subcommands ~w(branch config fetch for-each-ref log ls-remote ls-tree merge-base remote
                            rev-list rev-parse show show-ref symbolic-ref update-ref)
  # Global options that take their value as the next argument.
  @global_options_with_value ~w(-C -c --git-dir --work-tree --namespace --config-env --attr-source)
  @config_keys "^(filter\\..*\\.(clean|smudge|process|required)|merge\\..*\\.driver|include\\.path|includeif\\..*\\.path)$"
  @shell_filter_keys "^filter\\..*\\.(clean|smudge|process|required)$"
  @shell_include_keys "^(include|includeif\\..*)\\.path$"
  @list_args ["-z", "--show-scope", "--show-origin", "--get-regexp", @config_keys]
  @config_dirs_args ["rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir"]
  @driver_keys [
    filter: ~r/\Afilter\.(.*)\.(?:clean|smudge|process|required)\z/s,
    merge: ~r/\Amerge\.(.*)\.driver\z/s
  ]
  @include_key ~r/\A(?:include|includeif\..*)\.path\z/s
  # Git refuses to follow includes deeper than this.
  @max_include_depth 10
  # Git's own three-way merge of the temp files git hands a merge driver, with the marker size and
  # labels git would use; it exits non-zero when the file conflicts, as a driver must.
  @merge_file_driver "git merge-file --marker-size=%L -L %X -L %S -L %Y %A %O %B"
  @no_diff_drivers ["--no-ext-diff", "--no-textconv"]
  @range_diff_refusal "range-diff runs the repo's textconv drivers in a git log no option reaches"
  @subcommand_options %{
    "blame" => @no_diff_drivers,
    "diff" => @no_diff_drivers,
    "format-patch" => @no_diff_drivers,
    "log" => @no_diff_drivers,
    "show" => @no_diff_drivers,
    "whatchanged" => @no_diff_drivers,
    "fetch" => ["--upload-pack=git-upload-pack"],
    "ls-remote" => ["--upload-pack=git-upload-pack"],
    "pull" => ["--upload-pack=git-upload-pack"],
    "push" => ["--receive-pack=git-receive-pack"]
  }

  @doc """
  The `-c` overrides that turn off every filter and merge driver git could load for `args`.

  `read` runs git with Symphony's safe config and env. Returns an error, and the command must not
  run, when the config can't be read or names a driver `-c` can't address (a name with `=`), and
  for `range-diff`, whose diff drivers no option turns off.
  """
  @spec config_args([String.t()], keyword(), reader()) ::
          {:ok, [String.t()]} | {:error, String.t(), pos_integer()}
  def config_args(args, opts, read) when is_list(args) and is_list(opts) and is_function(read, 2) do
    {global_options, subcommand} = split_global_args(args, [])

    cond do
      subcommand == "range-diff" ->
        {:error, refusal(@range_diff_refusal), 128}

      subcommand in @no_filter_subcommands ->
        {:ok, []}

      true ->
        config_driver_args(global_options, opts, read)
    end
  end

  @doc """
  `args` with the options that keep its subcommand from running a diff driver or the config's
  upload or receive pack command, right after the subcommand.
  """
  @spec subcommand_args([String.t()]) :: [String.t()]
  def subcommand_args(args) when is_list(args) do
    case split_global_args(args, []) do
      {global_options, subcommand} when is_map_key(@subcommand_options, subcommand) ->
        {global_args, [^subcommand | rest]} = Enum.split(args, length(Enum.concat(global_options)))
        global_args ++ [subcommand | Map.fetch!(@subcommand_options, subcommand)] ++ rest

      _other ->
        args
    end
  end

  @doc """
  Shell functions for the scripts Symphony runs on an SSH worker, which give them
  `symphony_git <dir> <args>`: git `-C <dir>` with the filter driver overrides of
  `config_args/3`.

  The script defines `symphony_git_raw`, which runs git with Symphony's safe config and env, before
  it calls `symphony_git`. A subcommand that can read or write a work-tree file first lists the
  drivers in the merged config of `<dir>`, in its repo's `config` and `config.worktree` files, and
  in every file those include, whatever the condition; a file included from them that git can't
  read adds nothing. As in `config_args/3`, git doesn't run, and the call fails with 128, when the
  config can't be read or names a driver with `=` in its name. It also refuses an include path that
  holds a newline (or `\\x01`, the byte the scan reads a newline as), rather than guess the file.

  `<dir>` is the top of a work tree (or a bare repo), so the paths `rev-parse` prints relative to
  it need no `--path-format`, which workers with git older than 2.31 lack. Included paths are
  resolved to their physical directory, so a symlinked loop of includes reads each file once.
  """
  @spec shell_functions() :: String.t()
  def shell_functions do
    """
    symphony_git_nl='
    '
    symphony_git_soh=$(printf '\\001')
    symphony_git_refuse() {
      printf 'symphony: refusing to run git, %s\\n' "$1" >&2
      return 128
    }
    symphony_git_config() {
      symphony_git_out=$({ if symphony_git_raw "$@" </dev/null; then symphony_git_status=0; else symphony_git_status=$?; fi; printf '\\000%s' "$symphony_git_status"; } | tr '\\n\\000' '\\001\\n')
      symphony_git_status=${symphony_git_out##*"$symphony_git_nl"}
      printf '%s' "${symphony_git_out%"$symphony_git_nl"*}"
      [ "$symphony_git_status" -le 1 ] || return "$symphony_git_status"
    }
    symphony_git_physical() {
      symphony_git_parent=${1%/*}
      symphony_git_parent=$(cd -P -- "${symphony_git_parent:-/}" 2>/dev/null && pwd -P) || return
      printf '%s/%s' "${symphony_git_parent%/}" "${1##*/}"
    }
    symphony_git_filter_keys() {
      symphony_git_dirs=$(symphony_git_raw -C "$1" rev-parse --git-common-dir --git-dir) ||
        { symphony_git_refuse "git printed no config directories in $1"; return; }
      symphony_git_keys=$(symphony_git_config -C "$1" config -z --name-only --get-regexp '#{@shell_filter_keys}') ||
        { symphony_git_refuse "reading its config failed"; return; }
      symphony_git_common=${symphony_git_dirs%%"$symphony_git_nl"*}
      symphony_git_gitdir=${symphony_git_dirs#*"$symphony_git_nl"}
      case $symphony_git_common in /*) ;; *) symphony_git_common=$1/$symphony_git_common ;; esac
      case $symphony_git_gitdir in /*) ;; *) symphony_git_gitdir=$1/$symphony_git_gitdir ;; esac
      symphony_git_files=$symphony_git_common/config$symphony_git_nl$symphony_git_gitdir/config.worktree
      symphony_git_seen=$symphony_git_nl
      symphony_git_depth=0
      while [ -n "$symphony_git_files" ] && [ "$symphony_git_depth" -le #{@max_include_depth} ]; do
        symphony_git_next=
        while IFS= read -r symphony_git_file; do
          symphony_git_file=$(symphony_git_physical "$symphony_git_file") || continue
          case $symphony_git_seen in *"$symphony_git_nl$symphony_git_file$symphony_git_nl"*) continue ;; esac
          symphony_git_seen=$symphony_git_seen$symphony_git_file$symphony_git_nl
          [ -f "$symphony_git_file" ] || continue
          if symphony_git_found=$(symphony_git_config config --file "$symphony_git_file" --no-includes -z --name-only --get-regexp '#{@shell_filter_keys}' 2>/dev/null) &&
            symphony_git_includes=$(symphony_git_config config --file "$symphony_git_file" --no-includes -z --get-regexp '#{@shell_include_keys}' 2>/dev/null); then
            symphony_git_keys=$symphony_git_keys$symphony_git_nl$symphony_git_found
          elif [ "$symphony_git_depth" -eq 0 ]; then
            symphony_git_refuse "reading $symphony_git_file failed"
            return
          else
            continue
          fi
          while IFS= read -r symphony_git_line; do
            case $symphony_git_line in
              *"$symphony_git_soh"*"$symphony_git_soh"*)
                symphony_git_refuse "$symphony_git_file includes a path it can't be sure of"
                return
                ;;
              *"$symphony_git_soh") continue ;;
              *"$symphony_git_soh"*) symphony_git_path=${symphony_git_line#*"$symphony_git_soh"} ;;
              *) continue ;;
            esac
            case $symphony_git_path in
              /*) ;;
              "~/"*) symphony_git_path=${HOME:-}/${symphony_git_path#"~/"} ;;
              *) symphony_git_path=${symphony_git_file%/*}/$symphony_git_path ;;
            esac
            symphony_git_next=$symphony_git_next$symphony_git_path$symphony_git_nl
          done <<SYMPHONY_GIT_EOF
    $symphony_git_includes
    SYMPHONY_GIT_EOF
        done <<SYMPHONY_GIT_EOF
    $symphony_git_files
    SYMPHONY_GIT_EOF
        symphony_git_files=$symphony_git_next
        symphony_git_depth=$((symphony_git_depth + 1))
      done
      printf '%s\\n' "$symphony_git_keys"
    }
    symphony_git() {
      case ${2-} in
        range-diff) symphony_git_refuse "#{@range_diff_refusal}"; return ;;
        #{Enum.join(@no_filter_subcommands, "|")}) symphony_git_raw -C "$@"; return ;;
      esac
      symphony_git_drivers=$(symphony_git_filter_keys "$1") || return
      symphony_git_dir=$1
      shift
      symphony_git_set=$symphony_git_nl
      while IFS= read -r symphony_git_name; do
        [ -n "$symphony_git_name" ] || continue
        symphony_git_name=${symphony_git_name#filter.}
        symphony_git_name=${symphony_git_name%.*}
        case $symphony_git_set in *"$symphony_git_nl$symphony_git_name$symphony_git_nl"*) continue ;; esac
        symphony_git_set=$symphony_git_set$symphony_git_name$symphony_git_nl
        case $symphony_git_name in
          *=*)
            symphony_git_refuse "the repo config defines filter driver \\"$symphony_git_name\\", which -c can't turn off"
            return
            ;;
        esac
        set -- -c "filter.$symphony_git_name.clean=" -c "filter.$symphony_git_name.smudge=" \\
          -c "filter.$symphony_git_name.process=" -c "filter.$symphony_git_name.required=false" "$@"
      done <<SYMPHONY_GIT_EOF
    $symphony_git_drivers
    SYMPHONY_GIT_EOF
      symphony_git_raw -C "$symphony_git_dir" "$@"
    }\\
    """
  end

  defp split_global_args([option, value | rest], acc) when option in @global_options_with_value,
    do: split_global_args(rest, [[option, value] | acc])

  defp split_global_args(["-" <> _flag = option | rest], acc), do: split_global_args(rest, [[option] | acc])
  defp split_global_args([subcommand | _rest], acc), do: {Enum.reverse(acc), subcommand}
  defp split_global_args([], acc), do: {Enum.reverse(acc), nil}

  defp config_driver_args(global_options, opts, read) do
    global_args = Enum.concat(global_options)

    with {:ok, entries} <- read_entries(read, global_args ++ ["config" | @list_args], opts),
         {:ok, config_dirs} <- config_dirs(entries, global_args, read, opts) do
      entries
      |> includes(config_dirs, 1)
      |> walk_includes(driver_names(entries), %{}, read, opts)
      |> override_args()
    end
  end

  # `git config` prints the path of the repo's own config files relative to the directory git
  # moves to, such as the top of the work tree, which can be neither `-C` nor `:cd`. So git
  # names the directories that hold them: the repo config's (scope `local`) and the worktree
  # config's (scope `worktree`).
  defp config_dirs(entries, global_args, read, opts) do
    if Enum.any?(entries, &relative_include?/1) do
      case read.(global_args ++ @config_dirs_args, opts) do
        {stdout, 0, _stderr} -> parse_config_dirs(stdout)
        {_stdout, status, stderr} -> {:error, refusal("reading its config failed: #{String.trim(stderr)}"), status}
      end
    else
      {:ok, %{}}
    end
  end

  defp relative_include?({_scope, "file:" <> path, key, _value}),
    do: Regex.match?(@include_key, key) and Path.type(path) != :absolute

  defp relative_include?(_entry), do: false

  defp parse_config_dirs(stdout) do
    case String.split(stdout, "\n") do
      [common_dir, git_dir, ""] -> {:ok, %{"local" => common_dir, "worktree" => git_dir}}
      _lines -> {:error, refusal("git printed no config directories it can be sure of: #{inspect(stdout)}"), 128}
    end
  end

  defp walk_includes([], names, _seen, _read, _opts), do: names

  defp walk_includes([{path, depth} | rest], names, seen, read, opts) do
    if depth > @max_include_depth or Map.has_key?(seen, path) or not File.regular?(path) do
      walk_includes(rest, names, seen, read, opts)
    else
      # A file git can't parse defines no driver git could load, so a failed read adds nothing.
      entries =
        case read_entries(read, ["config", "--file", path, "--no-includes" | @list_args], opts) do
          {:ok, entries} -> entries
          {:error, _message, _status} -> []
        end

      walk_includes(
        rest ++ includes(entries, %{}, depth + 1),
        driver_names(entries) ++ names,
        Map.put(seen, path, true),
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
        {:error, refusal("reading its config failed: #{String.trim(stderr)}"), status}
    end
  end

  defp refusal(reason), do: "symphony: refusing to run git, #{reason}\n"

  # `-z --show-scope --show-origin` prints `<scope>\0<origin>\0<key>\n<value>\0` per entry, and
  # `<scope>\0<origin>\0<key>\0` for a key set without a value.
  defp parse_entries(stdout) do
    stdout
    |> String.split("\0")
    |> Enum.chunk_every(3, 3, :discard)
    |> Enum.map(fn [scope, origin, key_value] ->
      case String.split(key_value, "\n", parts: 2) do
        [key, value] -> {scope, origin, key, value}
        [key] -> {scope, origin, key, nil}
      end
    end)
  end

  defp driver_names(entries) do
    for {_scope, _origin, key, _value} <- entries,
        {kind, pattern} <- @driver_keys,
        [_key, name] <- [Regex.run(pattern, key)],
        do: {kind, name}
  end

  # Git reads a relative include path from the directory of the file that includes it.
  defp includes(entries, config_dirs, depth) do
    for {scope, origin, key, path} <- entries,
        is_binary(path) and Regex.match?(@include_key, key),
        resolved = resolve_include(path, origin_dir(scope, origin, config_dirs)),
        do: {resolved, depth}
  end

  defp origin_dir(scope, "file:" <> path, config_dirs) do
    case Path.type(path) do
      :absolute -> Path.dirname(path)
      _relative -> Map.get(config_dirs, scope)
    end
  end

  defp origin_dir(_scope, _origin, _config_dirs), do: nil

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
    case Enum.find(names, fn {_kind, name} -> String.contains?(name, "=") end) do
      nil ->
        {:ok, names |> Enum.uniq() |> Enum.sort() |> Enum.flat_map(&driver_args/1)}

      {kind, name} ->
        {:error, refusal("the repo config defines #{kind} driver #{inspect(name)}, which -c can't turn off"), 128}
    end
  end

  defp driver_args({:filter, name}) do
    Enum.flat_map(["clean=", "smudge=", "process=", "required=false"], &["-c", "filter.#{name}.#{&1}"])
  end

  defp driver_args({:merge, name}), do: ["-c", "merge.#{name}.driver=#{@merge_file_driver}"]
end
