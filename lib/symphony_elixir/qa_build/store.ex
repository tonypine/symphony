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
  # `sync <repo> <src>` brings `work/` to the tree unpacked in `<src>`, which must be the `src`
  # folder of a run directory, and prints `work/`'s path. `store <repo> <tree> <app>` copies the
  # built bundle `work/<app>` to `builds/<tree>/`, marks it complete, removes the trees past the
  # newest five and prints the copy's path.
  @store_script """
  verb=$1; repo=$2
  case "$repo" in ""|.|..|*[!A-Za-z0-9._-]*) echo "invalid repo key"; exit 2 ;; esac
  umask 077
  store="$HOME/.symphony-qa/store/$repo"
  mkdir -p "$store/work" "$store/builds" || exit 1
  store=$(cd "$store" && pwd -P) || exit 1
  case "$store" in /*/.symphony-qa/store/"$repo") ;; *) echo "$store is not a store folder"; exit 2 ;; esac
  case "$verb" in
  sync)
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
    case "$app" in *.app) ;; *) echo "$app is not an .app bundle"; exit 1 ;; esac
    bundle="$store/work/$app"
    if [ ! -d "$bundle" ] || [ -L "$bundle" ]; then echo "$app is not a directory after the build"; exit 1; fi
    case "$(cd "$bundle" && pwd -P)/" in "$store/work/"*) ;; *) echo "$app resolves outside the checkout"; exit 1 ;; esac
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
  status, output}` when the build command exited non-zero (the end of its output), or
  `{:unavailable, reason}` when it could not run or its app could not be stored.
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
         {:ok, work} <- script(host, ["sync", job.repo_key, src], "symphony-qa-work", "bring the checkout to the commit"),
         :ok <- run_build(host, job, work) do
      script(host, ["store", job.repo_key, job.tree, job.plan.app], "symphony-qa-stored", "store the built app")
      |> case do
        {:ok, app} -> {:ready, app}
        unavailable -> unavailable
      end
    end
  after
    host.cleanup.(dir)
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

  defp script(host, args, marker, doing) do
    case host.cmd.("/bin/sh", ["-c", @store_script, "sh" | args], timeout_ms: @script_timeout_ms, output_limit: @output_limit) do
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

  # The build gets the QA user's login environment and nothing more.
  defp run_build(host, job, work) do
    opts = [cd: work, remote_env: [], timeout_ms: job.plan.build_timeout_ms, output_limit: @output_limit]

    case host.cmd.("/bin/sh", ["-c", job.plan.build], opts) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:failed, status, tail(output, @failure_tail)}
      {:error, :timeout} -> {:unavailable, "the build did not finish within #{job.plan.build_timeout_ms} ms"}
      {:error, reason} -> {:unavailable, "the build command could not start: #{inspect(reason)}"}
    end
  end

  defp tail(output, limit) when byte_size(output) > limit, do: "…" <> binary_part(output, byte_size(output) - limit, limit)
  defp tail(output, _limit), do: output

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)
end
