defmodule SymphonyElixir.QaBuild.Store do
  @moduledoc """
  One QA pre-build on the QA host (`auto_review.worker_host`), for `SymphonyElixir.QaBuild`.

  Symphony keeps one folder per repository there, `~/.symphony-qa/store/<repo key>/`:

    * `work/` is the one checkout of the repository the builds run in. `build/2` brings it to the
      commit by content: the commit is archived here (`git archive`), shipped to a scratch folder in
      a run directory, and copied over `work/` with `rsync --checksum`, which writes only the files
      whose content changed and leaves every other file, and its modification time, as it was. So
      what the compiler kept under `work/` from the last build still holds, and the build compiles
      only what changed. Files the last commit had and this one does not are removed, by comparing
      the two commits' file lists (`manifest`); nothing else is deleted, so build outputs stay.
    * `builds/<tree>/` holds the `.app` a build of that tree produced, with a `.complete` file
      written last. The newest five trees are kept.

  The build is the playbook's `build` command, run in `work/` with the QA user's login environment
  and the playbook's `build_timeout_ms`. It gets no `QA_HOST_PORTS`: no pass, so no tunnel, is open.
  It runs in a process group of its own, whose leader's pid (with its start time, so a reused pid is
  never taken for it) is kept in `build.pid` in the repository's folder while it runs. That is how a
  build is stopped on the QA host, not only its SSH session here: `cancel/2` kills the group, and so
  does every build before it touches `work/`, so a build a restart of Symphony left running never
  writes into `work/` beside the next one. A build that ran out of time is killed the same way.

  A build that exits 0 without leaving a usable `.app` at the playbook's `app` path failed, as one
  that exits non-zero did: its output says so.

  The QA host passes the same checks as for a pass (`SymphonyElixir.QaDriver.SafeHost`), and the run
  directory they create is removed when the build ends.
  """

  require Logger

  alias SymphonyElixir.QaDriver.{Checks, Remote, SafeHost}
  alias SymphonyElixir.Workspace

  @script_timeout_ms 300_000
  @output_limit 8_000
  @failure_tail 4_000

  # Works in `~/.symphony-qa/store/<repo key>` on the QA host and nowhere else: the repo key (`$2`)
  # must be a plain name, and the folder it resolves to must be that one.
  #
  # `cancel <repo>` kills the build `build.pid` names, when that process still runs. `sync <repo>
  # <src>` does too, then brings `work/` to the tree unpacked in `<src>`, which must be the `src`
  # folder of a run directory, and prints `work/`'s path. `build <repo> <command>` runs the command
  # in `work/` in a process group of its own, recorded in `build.pid`, and prints its exit status.
  # `store <repo> <tree> <app>` copies the built bundle `work/<app>` to `builds/<tree>/`, marks it
  # complete, removes the trees past the newest five and prints the copy's path; it exits 3 when
  # the build left no usable bundle there.
  @store_script """
  verb=$1; repo=$2
  case "$repo" in ""|.|..|*[!A-Za-z0-9._-]*) echo "invalid repo key"; exit 2 ;; esac
  umask 077
  store="$HOME/.symphony-qa/store/$repo"
  mkdir -p "$store/work" "$store/builds" || exit 1
  store=$(cd "$store" && pwd -P) || exit 1
  case "$store" in /*/.symphony-qa/store/"$repo") ;; *) echo "$store is not a store folder"; exit 2 ;; esac
  kill_build() {
    [ -f "$store/build.pid" ] || return 0
    read -r pid started < "$store/build.pid"
    case "$pid" in ""|*[!0-9]*) rm -f "$store/build.pid"; return 0 ;; esac
    set -- $(ps -o lstart= -p "$pid" 2>/dev/null)
    if [ -n "$started" ] && [ "$*" = "$started" ]; then
      kill -s TERM -- "-$pid" 2>/dev/null
      i=0
      while [ "$i" -lt 50 ] && kill -0 -- "-$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
      kill -s KILL -- "-$pid" 2>/dev/null
      printf 'symphony-qa-killed:%s\\n' "$pid"
    fi
    rm -f "$store/build.pid"
  }
  case "$verb" in
  cancel)
    kill_build
    printf 'symphony-qa-cancelled:%s\\n' "$repo"
    ;;
  build)
    kill_build
    cd "$store/work" || exit 1
    set -m
    /bin/sh -c "$3" &
    pid=$!
    set +m
    set -- $(ps -o lstart= -p "$pid")
    printf '%s %s\\n' "$pid" "$*" > "$store/build.pid"
    wait "$pid"
    status=$?
    rm -f "$store/build.pid"
    printf '\\nsymphony-qa-build-exit:%s\\n' "$status"
    ;;
  sync)
    kill_build
    src=$3
    case "$src" in /*/.symphony-qa/runs/run.*/src) ;; *) echo "$src is not in a run directory"; exit 2 ;; esac
    if [ ! -d "$src" ] || [ -L "$src" ]; then echo "$src is not a directory"; exit 2; fi
    (cd "$src" && find . ! -type d | LC_ALL=C sort) > "$store/manifest.new" || exit 1
    rsync -rlpc "$src/" "$store/work/" || exit 1
    if [ -f "$store/manifest" ]; then
      LC_ALL=C comm -23 "$store/manifest" "$store/manifest.new" | while IFS= read -r file; do rm -f "$store/work/$file"; done
    fi
    mv -f "$store/manifest.new" "$store/manifest" || exit 1
    printf 'symphony-qa-work:%s\\n' "$store/work"
    ;;
  store)
    tree=$3; app=$4
    case "$tree" in ""|*[!0-9a-f]*) echo "invalid tree"; exit 2 ;; esac
    case "$app" in *.app) ;; *) echo "$app is not an .app bundle"; exit 3 ;; esac
    bundle="$store/work/$app"
    if [ ! -d "$bundle" ] || [ -L "$bundle" ]; then echo "$app is not a directory after the build"; exit 3; fi
    case "$(cd "$bundle" && pwd -P)/" in "$store/work/"*) ;; *) echo "$app resolves outside the checkout"; exit 3 ;; esac
    dest="$store/builds/$tree"
    rm -rf "$dest" && mkdir "$dest" && cp -R "$bundle" "$dest/" && : > "$dest/.complete" || exit 1
    ls -1t "$store/builds" | grep -v -x "$tree" | tail -n +5 | while IFS= read -r old; do
      case "$old" in ""|*[!0-9a-f]*) ;; *) rm -rf "$store/builds/$old" ;; esac
    done
    printf 'symphony-qa-stored:%s\\n' "$dest/${bundle##*/}"
    ;;
  *)
    echo "unknown verb"; exit 2 ;;
  esac
  """

  @typedoc """
  What to build: the repository and the commit (`sha`) whose tree is `tree`, the ticket workspace
  that holds the commit, and the playbook's `build` command, `app` path and timeout with the QA
  host to build on.
  """
  @type job :: %{
          required(:repo_key) => String.t(),
          required(:tree) => String.t(),
          required(:sha) => String.t(),
          required(:workspace) => Path.t(),
          required(:plan) => SymphonyElixir.QaBuild.plan(),
          optional(atom()) => term()
        }

  @typedoc """
  How a build ended: `{:ready, app}` with the stored `.app`'s path on the QA host, `{:failed,
  status, output}` when the build command exited non-zero (the end of its output) or exited 0
  without leaving a usable app, or `{:unavailable, reason}` when it could not run or its app could
  not be stored.
  """
  @type outcome :: {:ready, String.t()} | {:failed, integer(), String.t()} | {:unavailable, String.t()}

  @doc """
  Builds `job` on its QA host and stores the app. Options: `:host` (`worker_host -> host`, the QA
  host's OS boundary, default `SymphonyElixir.QaDriver.Remote.host/1`), `:local_uuid` (as
  `SymphonyElixir.QaDriver.SafeHost.open/3`) and `:git` (`fn args, cwd -> {output, status}`).
  """
  @spec build(job(), keyword()) :: outcome()
  def build(%{plan: %{worker_host: worker_host}} = job, opts) do
    host = Keyword.get(opts, :host, &Remote.host/1).(worker_host)
    scratch = Checks.private_dir("qa-build")

    try do
      case SafeHost.open(host, worker_host, [scratch_dir: scratch, user: "QA build"] ++ Keyword.take(opts, [:local_uuid])) do
        {:ok, dir} -> build_in(host, dir, scratch, job, Keyword.get(opts, :git, &default_git/2))
        {:error, {code, message}} -> {:unavailable, "#{code}: #{message}"}
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp build_in(host, dir, scratch, job, git) do
    src = Path.join(dir, "src")

    with :ok <- archive(job, Path.join(scratch, "src.tar"), git),
         :ok <- ship(host, Path.join(scratch, "src.tar"), src),
         {:ok, _work} <- script(host, ["sync", job.repo_key, src], "symphony-qa-work", "bring the checkout to the commit"),
         :ok <- run_build(host, job) do
      store_app(host, job)
    end
  after
    host.cleanup.(dir)
  end

  @doc """
  Stops the build running in `repo_key`'s folder on `plan`'s QA host, if one runs: its whole
  process group is killed there. `:ok` once the QA host answered. Options: `:host`, as `build/2`.
  """
  @spec cancel(String.t(), SymphonyElixir.QaBuild.plan(), keyword()) :: :ok | {:unavailable, String.t()}
  def cancel(repo_key, %{worker_host: worker_host}, opts) do
    host = Keyword.get(opts, :host, &Remote.host/1).(worker_host)
    kill(host, repo_key)
  end

  defp kill(host, repo_key) do
    with {:ok, _repo} <- script(host, ["cancel", repo_key], "symphony-qa-cancelled", "stop the build"), do: :ok
  end

  defp archive(job, tar, git) do
    case git.(["archive", "--format=tar", "-o", tar, job.sha], job.workspace) do
      {_output, 0} -> :ok
      {output, status} -> {:unavailable, "git archive of #{job.sha} failed (exit #{status}): #{tail(to_string(output), 500)}"}
    end
  end

  defp ship(host, tar, src) do
    with {:error, reason} <- host.ship.(tar, src), do: {:unavailable, "the commit could not be copied to the QA host: #{reason}"}
  end

  defp script(host, args, marker, doing), do: host |> run_script(["-c", @store_script, "sh" | args]) |> answer(marker, doing)

  defp run_script(host, args), do: host.cmd.("/bin/sh", args, timeout_ms: @script_timeout_ms, output_limit: @output_limit)

  defp answer(result, marker, doing) do
    case result do
      {:ok, {output, 0}} ->
        case Regex.run(~r/^#{marker}:(.+)$/m, output) do
          [_line, path] -> {:ok, path}
          nil -> {:unavailable, "the QA host could not #{doing}: no answer: #{tail(String.trim(output), 500)}"}
        end

      {:ok, {output, status}} ->
        {:unavailable, "the QA host could not #{doing} (exit #{status}): #{tail(String.trim(output), 500)}"}

      {:error, reason} ->
        {:unavailable, "the QA host could not #{doing}: #{inspect(reason)}"}
    end
  end

  # The build gets the QA user's login environment and nothing more. One that ran out of time is
  # killed on the QA host, not only its SSH session here.
  defp run_build(host, job) do
    args = ["-c", @store_script, "sh", "build", job.repo_key, job.plan.build]

    case host.cmd.("/bin/sh", args, timeout_ms: job.plan.build_timeout_ms, output_limit: @output_limit) do
      {:ok, {output, 0}} ->
        build_exit(output)

      {:ok, {output, status}} ->
        {:unavailable, "the build could not start on the QA host (exit #{status}): #{tail(String.trim(output), 500)}"}

      {:error, :timeout} ->
        kill(host, job.repo_key)
        {:unavailable, "the build did not finish within #{job.plan.build_timeout_ms} ms"}

      {:error, reason} ->
        {:unavailable, "the build command could not start: #{inspect(reason)}"}
    end
  end

  # The exit line comes after a newline of its own, which is not the build's.
  defp build_exit(output) do
    case Regex.run(~r/\nsymphony-qa-build-exit:(\d+)\n?\z/, output, return: :index) do
      [{start, _length}, {status_at, status_length}] ->
        status = output |> binary_part(status_at, status_length) |> String.to_integer()
        if status == 0, do: :ok, else: {:failed, status, tail(binary_part(output, 0, start), @failure_tail)}

      nil ->
        {:unavailable, "the build ended on the QA host without saying how: #{tail(String.trim(output), 500)}"}
    end
  end

  # A build that exited 0 but left no usable app failed: the command did not make what the playbook
  # names.
  defp store_app(host, job) do
    args = ["-c", @store_script, "sh", "store", job.repo_key, job.tree, job.plan.app]

    case run_script(host, args) do
      {:ok, {output, 3}} ->
        {:failed, 0, "The build command finished, but it made no app at #{job.plan.app}: #{String.trim(output)}."}

      result ->
        with {:ok, app} <- answer(result, "symphony-qa-stored", "store the built app"), do: {:ready, app}
    end
  end

  defp tail(output, limit) when byte_size(output) > limit, do: "…" <> binary_part(output, byte_size(output) - limit, limit)
  defp tail(output, _limit), do: output

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)
end
