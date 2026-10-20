defmodule SymphonyElixir.QaDriver.DevServer do
  @moduledoc """
  Runs the project's `verification.dev_server` on the QA host for a `macos_app` pass on a
  `worker_host`, beside the app under test, which cannot reach a server on the Symphony host.

  `start/2` copies the QA worktree's `HEAD` (a `git archive`, as `qa_build` does) into
  `dev-server/src/` in the pass's run directory there, a copy of its own so that a `qa_build`,
  which unpacks `src/` afresh, never takes the files from under the running server. It runs
  `build_cmd`, then `start_cmd`, in that copy, as the QA user and outside any sandbox (the same
  trust as `qa_build`), with `SYMPHONY_VERIFICATION_PORT` set to the playbook's port, `HOME` set
  to the fresh `dev-server/home/` (so no config file of the QA user's is read) and `TMPDIR` to
  `dev-server/tmp/`. `start_cmd` runs in a process group of its own, its output in
  `dev-server/server.log`. The QA host then polls `health_check_url` with `curl` until it answers
  200, the server exits, or `health_timeout_ms` passes.

  `stop/2` sends the group `stop_signal`, waits `stop_timeout_ms` and kills what is left of it.
  The driver's removal of the run directory takes the rest.
  """

  @build_timeout_ms 900_000
  @step_timeout_ms 30_000
  @output_limit 8_000
  @log_lines 20
  @stop_outcomes %{"stopped" => :stopped, "killed" => :killed, "gone" => :gone}

  # Creates `$1/dev-server` with a fresh home and temp folder and an empty log.
  @prepare_script """
  dir="$1/dev-server"
  umask 077
  rm -rf "$dir" && mkdir -p "$dir/home" "$dir/tmp" && : > "$dir/server.log" || exit 1
  printf 'symphony-qa-dev-server-dir:%s\\n' "$dir"
  """

  # Runs `$4` in `$1/dev-server/src` with the dev server's environment: `build` waits for it and
  # prints its exit status and the log's tail when it fails; `start` starts it in a process group
  # of its own (`set -m`) and prints that group's leader, a subshell that writes the exit status.
  @run_script """
  dir="$1/dev-server"; log="$dir/server.log"
  cd "$dir/src" || exit 125
  export SYMPHONY_VERIFICATION_PORT="$2" HOME="$dir/home" TMPDIR="$dir/tmp/"
  case "$3" in
    build)
      /bin/sh -c "$4" < /dev/null >> "$log" 2>&1
      status=$?
      if [ "$status" -ne 0 ]; then printf 'symphony-qa-dev-server-exit:%s\\n' "$status"; tail -n #{@log_lines} "$log"; fi
      ;;
    start)
      set -m
      (/bin/sh -c "$4"; printf '%s\\n' "$?" > "$dir/exit-status") < /dev/null >> "$log" 2>&1 &
      printf 'symphony-qa-dev-server-pid:%s\\n' "$!"
      ;;
  esac
  exit 0
  """

  # Polls `$2` until it answers 200, the server (`$4`) exits, or `$3` seconds pass.
  @health_script """
  dir="$1/dev-server"; url=$2; pid=$4
  end=$(($(date +%s) + $3))
  while [ "$(date +%s)" -lt "$end" ]; do
    code=$(curl -s --noproxy '*' -o /dev/null -m 2 -w '%{http_code}' "$url" 2> /dev/null)
    if [ "$code" = 200 ]; then printf 'symphony-qa-dev-server:healthy\\n'; exit 0; fi
    if ! kill -0 "$pid" 2> /dev/null; then
      printf 'symphony-qa-dev-server-exit:%s\\n' "$(cat "$dir/exit-status" 2> /dev/null || printf unknown)"
      tail -n #{@log_lines} "$dir/server.log"
      exit 0
    fi
    sleep 0.5
  done
  printf 'symphony-qa-dev-server:timeout\\n'
  tail -n #{@log_lines} "$dir/server.log"
  """

  # Sends the group `$2` the signal `$3`, waits up to `$4` tenths of a second for it to go, then
  # kills it.
  @stop_script """
  kill -s "$3" -- -"$2" 2> /dev/null || { printf 'symphony-qa-dev-server:gone\\n'; exit 0; }
  i=0
  while [ "$i" -lt "$4" ]; do
    if ! kill -0 -- -"$2" 2> /dev/null; then printf 'symphony-qa-dev-server:stopped\\n'; exit 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -s KILL -- -"$2" 2> /dev/null
  printf 'symphony-qa-dev-server:killed\\n'
  """

  @typedoc "What to run: `verification.dev_server` with its health check URL for `port`."
  @type spec :: %{
          required(:start_cmd) => String.t(),
          required(:build_cmd) => String.t() | nil,
          required(:health_check_url) => String.t(),
          required(:health_timeout_ms) => pos_integer(),
          required(:stop_signal) => String.t(),
          required(:stop_timeout_ms) => non_neg_integer(),
          required(:port) => pos_integer(),
          required(:url) => String.t()
        }

  @typedoc "A running server: its process group on the QA host and how to stop it."
  @type server :: %{
          pid: pos_integer(),
          port: pos_integer(),
          url: String.t(),
          stop_signal: String.t(),
          stop_timeout_ms: non_neg_integer()
        }

  @typedoc """
  Why it did not start, and the last #{@log_lines} lines of its log: `{:dev_server_build_failed,
  status}`, `{:dev_server_exit, status}` (it exited before its health check passed),
  `:health_timeout`, or `{:dev_server_unreachable, message}` when the QA host could not be asked.
  """
  @type failure :: {:error, term(), String.t()}

  @doc """
  Starts the server on the QA host, as the moduledoc says. `config` is the driver's: its `host`
  (`cmd` and `ship`), `host_dir` (the run directory), `git`, `worktree` and `scratch_dir`.
  """
  @spec start(map(), spec()) :: {:ok, server()} | failure()
  def start(config, spec) do
    with :ok <- prepare(config),
         :ok <- ship(config),
         :ok <- build(config, spec),
         {:ok, pid} <- launch(config, spec) do
      server = %{pid: pid, port: spec.port, url: spec.url, stop_signal: spec.stop_signal, stop_timeout_ms: spec.stop_timeout_ms}

      case healthy(config, spec, pid) do
        :ok ->
          {:ok, server}

        {:error, _cause, _log} = error ->
          stop(config, server)
          error
      end
    end
  end

  @doc "Stops a server `start/2` started: `:stopped` by `stop_signal`, `:killed` after `stop_timeout_ms`, `:gone` when it had already exited."
  @spec stop(map(), server()) :: :stopped | :killed | :gone | {:error, term()}
  def stop(config, server) do
    tenths = div(server.stop_timeout_ms + 99, 100)
    args = [Integer.to_string(server.pid), server.stop_signal, Integer.to_string(tenths)]

    case script(config, @stop_script, args, server.stop_timeout_ms + @step_timeout_ms) do
      {:ok, {output, _status}} ->
        Map.get(@stop_outcomes, marker(output, "symphony-qa-dev-server"), {:error, String.trim(output)})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare(config) do
    case script(config, @prepare_script, [], @step_timeout_ms) do
      {:ok, {output, 0}} -> if marker(output, "symphony-qa-dev-server-dir"), do: :ok, else: unreachable(output)
      {:ok, {output, _status}} -> unreachable(output)
      {:error, reason} -> unreachable(inspect(reason))
    end
  end

  defp ship(config) do
    tar = Path.join(config.scratch_dir, "dev-server-src.tar")

    result =
      case config.git.(["archive", "--format=tar", "-o", tar, "HEAD"], config.worktree) do
        {_output, 0} ->
          with {:error, reason} <- config.host.ship.(tar, Path.join([config.host_dir, "dev-server", "src"])) do
            {:error, {:dev_server_unreachable, "the PR head could not be copied to the QA host: #{reason}"}, ""}
          end

        {output, status} ->
          {:error, {:dev_server_unreachable, "git archive failed (exit #{status}): #{String.trim(to_string(output))}"}, ""}
      end

    File.rm(tar)
    result
  end

  defp build(_config, %{build_cmd: nil}), do: :ok

  defp build(config, spec) do
    case run(config, spec, "build", spec.build_cmd, @build_timeout_ms) do
      {:ok, {output, 0}} ->
        case marker(output, "symphony-qa-dev-server-exit") do
          nil -> :ok
          status -> {:error, {:dev_server_build_failed, exit_status(status)}, log_after(output, "symphony-qa-dev-server-exit")}
        end

      {:ok, {output, _status}} ->
        unreachable(output)

      {:error, :timeout} ->
        {:error, {:dev_server_build_failed, :timeout}, "build_cmd did not finish within #{div(@build_timeout_ms, 60_000)} minutes"}

      {:error, reason} ->
        unreachable(inspect(reason))
    end
  end

  defp launch(config, spec) do
    case run(config, spec, "start", spec.start_cmd, @step_timeout_ms) do
      {:ok, {output, 0}} ->
        case marker(output, "symphony-qa-dev-server-pid") do
          nil -> unreachable(output)
          pid -> {:ok, String.to_integer(pid)}
        end

      {:ok, {output, _status}} ->
        unreachable(output)

      {:error, reason} ->
        unreachable(inspect(reason))
    end
  end

  defp healthy(config, spec, pid) do
    seconds = div(spec.health_timeout_ms + 999, 1000)
    args = [spec.health_check_url, Integer.to_string(seconds), Integer.to_string(pid)]

    case script(config, @health_script, args, spec.health_timeout_ms + @step_timeout_ms) do
      {:ok, {output, _status}} ->
        health_outcome(output, marker(output, "symphony-qa-dev-server"), marker(output, "symphony-qa-dev-server-exit"))

      {:error, reason} ->
        unreachable(inspect(reason))
    end
  end

  defp health_outcome(_output, "healthy", _exit), do: :ok
  defp health_outcome(output, "timeout", _exit), do: {:error, :health_timeout, log_after(output, "symphony-qa-dev-server")}
  defp health_outcome(output, _outcome, nil), do: unreachable(output)

  defp health_outcome(output, _outcome, status),
    do: {:error, {:dev_server_exit, exit_status(status)}, log_after(output, "symphony-qa-dev-server-exit")}

  defp run(config, spec, mode, command, timeout_ms) do
    script(config, @run_script, [Integer.to_string(spec.port), mode, command], timeout_ms)
  end

  defp script(config, script, args, timeout_ms) do
    config.host.cmd.("/bin/sh", ["-c", script, "sh", config.host_dir | args], timeout_ms: timeout_ms, output_limit: @output_limit)
  end

  defp unreachable(output), do: {:error, {:dev_server_unreachable, String.trim(output)}, ""}

  defp exit_status(status) do
    case Integer.parse(status) do
      {number, ""} -> number
      _other -> status
    end
  end

  defp marker(output, name) do
    case Regex.run(~r/^#{name}:(.*)$/m, output) do
      [_line, value] -> value
      nil -> nil
    end
  end

  # The log's tail the scripts print after their marker line, which `output` holds.
  defp log_after(output, name) do
    [_before, log] = Regex.split(~r/^#{name}:.*\n?/m, output, parts: 2)
    String.trim_trailing(log)
  end
end
