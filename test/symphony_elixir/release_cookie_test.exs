defmodule SymphonyElixir.ReleaseCookieTest do
  use ExUnit.Case, async: false

  @env_script Path.expand("../../rel/env.sh.eex", __DIR__)
  @distribution_timeout_ms 30_000

  setup do
    tmp = Path.join(System.tmp_dir!(), "symphony-release-cookie-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

  test "release env creates and reuses a state-root cookie", %{tmp: tmp} do
    state_root = Path.join(tmp, "state")

    assert {:ok, first} = source_env(["start", "--state-root", state_root])
    cookie_path = Path.join(state_root, "erlang_cookie")

    assert first.cookie =~ ~r/^[0-9a-f]{64}$/
    assert first.distribution == "name"
    assert first.node == "symphony@127.0.0.1"
    assert File.read!(cookie_path) == first.cookie <> "\n"
    assert file_mode(cookie_path) == "600"

    assert {:ok, second} = source_env(["start", "--state-root", state_root])
    assert second.cookie == first.cookie
  end

  test "release env uses SYMPHONY_COOKIE without consulting the state-root file", %{tmp: tmp} do
    state_root = Path.join(tmp, "state")

    assert {:ok, result} =
             source_env(["start", "--state-root", state_root], env: [{"SYMPHONY_COOKIE", "operator_cookie"}])

    assert result.cookie == "operator_cookie"
    refute File.exists?(Path.join(state_root, "erlang_cookie"))
  end

  test "release env uses SYMPHONY_STATE_ROOT when no flag is present", %{tmp: tmp} do
    state_root = Path.join(tmp, "env-state")

    assert {:ok, result} = source_env(["start"], env: [{"SYMPHONY_STATE_ROOT", state_root}])

    assert result.cookie =~ ~r/^[0-9a-f]{64}$/
    assert File.exists?(Path.join(state_root, "erlang_cookie"))
  end

  test "release env refuses the legacy static cookie from env" do
    assert {:error, %{stderr: stderr}} = source_env(["start"], env: [{"SYMPHONY_COOKIE", "symphony"}])

    assert stderr =~ ~s(Refusing to start with insecure Erlang distribution cookie "symphony")
  end

  test "release env refuses the legacy static cookie from file", %{tmp: tmp} do
    state_root = Path.join(tmp, "state")
    cookie_path = Path.join(state_root, "erlang_cookie")
    File.mkdir_p!(state_root)
    File.write!(cookie_path, "symphony\n")
    File.chmod(cookie_path, 0o600)

    assert {:error, %{stderr: stderr}} = source_env(["start", "--state-root", state_root])

    assert stderr =~ ~s(Refusing to start with insecure Erlang distribution cookie "symphony")
  end

  test "release env refuses a group or world-readable persisted cookie", %{tmp: tmp} do
    state_root = Path.join(tmp, "state")
    cookie_path = Path.join(state_root, "erlang_cookie")
    File.mkdir_p!(state_root)
    File.write!(cookie_path, "safe_cookie\n")
    File.chmod(cookie_path, 0o644)

    assert {:error, %{stderr: stderr}} = source_env(["start", "--state-root", state_root])

    assert stderr =~ "must be readable only by its owner"
  end

  test "Erlang distribution rejects a wrong cookie" do
    erl = System.find_executable("erl") || flunk("erl executable is required for distribution smoke test")

    server_node = unique_node("symphony_cookie_server")
    good_cookie = "cookie#{System.unique_integer([:positive])}"
    bad_cookie = "wrong#{System.unique_integer([:positive])}"
    deadline = System.monotonic_time(:millisecond) + @distribution_timeout_ms

    assert {:ok, dist_port} = start_server(erl, server_node, good_cookie, deadline)
    assert ping_node(erl, dist_port, server_node, bad_cookie) == :pang
  end

  defp source_env(args, opts \\ []) do
    env =
      %{
        "RELEASE_COOKIE" => nil,
        "RELEASE_DISTRIBUTION" => nil,
        "RELEASE_NODE" => nil,
        "SYMPHONY_COOKIE" => nil,
        "SYMPHONY_STATE_ROOT" => nil
      }
      |> Map.merge(Map.new(Keyword.get(opts, :env, [])))
      |> Map.to_list()

    command = """
    . #{shell_quote(@env_script)}
    printf '%s\\n' "$RELEASE_COOKIE"
    printf '%s\\n' "$RELEASE_DISTRIBUTION"
    printf '%s\\n' "$RELEASE_NODE"
    """

    case System.cmd("sh", ["-c", command, "release-env" | args], env: env, stderr_to_stdout: true) do
      {stdout, 0} ->
        [cookie, distribution, node] = String.split(stdout, "\n", trim: true)
        {:ok, %{cookie: cookie, distribution: distribution, node: node}}

      {output, status} ->
        {:error, %{status: status, stderr: output}}
    end
  end

  defp ping_node(erl, dist_port, server_node, cookie) do
    client_node = unique_node("symphony_cookie_client")

    eval =
      ~s|Target = list_to_atom("#{server_node}"), case net_adm:ping(Target) of pong -> halt(0); pang -> halt(1) end.|

    args = ["-noshell", "-setcookie", cookie, "-name", client_node, "-dist_listen", "false"] ++ dist_args(dist_port)

    case System.cmd(erl, args ++ ["-eval", eval], stderr_to_stdout: true) do
      {_output, 0} -> :pong
      {_output, _status} -> :pang
    end
  end

  defp dist_args(dist_port), do: ["-start_epmd", "false", "-erl_epmd_port", Integer.to_string(dist_port)]

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # The nodes meet on a per-test port instead of the shared epmd, so a cold or
  # slow epmd on a loaded runner can't delay or break the server's startup. The
  # probed port can be taken before the server binds it, so a server that exits
  # with eaddrinuse is started once more on a fresh port.
  defp start_server(erl, server_node, cookie, deadline, retries \\ 1) do
    dist_port = free_tcp_port()

    port =
      Port.open({:spawn_executable, erl}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args:
          ["-noshell", "-setcookie", cookie, "-name", server_node] ++
            dist_args(dist_port) ++ ["-eval", "timer:sleep(120000), erlang:halt()."]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true) end)

    case await_pong(port, fn -> ping_node(erl, dist_port, server_node, cookie) end, deadline) do
      :ok ->
        {:ok, dist_port}

      {:error, {:exit_status, _status, output}} = error ->
        if retries > 0 and output =~ "eaddrinuse" do
          start_server(erl, server_node, cookie, deadline, retries - 1)
        else
          error
        end

      error ->
        error
    end
  end

  defp await_pong(port, ping, deadline, output \\ "") do
    receive do
      {^port, {:data, data}} -> await_pong(port, ping, deadline, output <> data)
      {^port, {:exit_status, status}} -> {:error, {:exit_status, status, output}}
    after
      0 ->
        cond do
          ping.() == :pong ->
            :ok

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, {:timeout, output}}

          true ->
            Process.sleep(100)
            await_pong(port, ping, deadline, output)
        end
    end
  end

  defp unique_node(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}@127.0.0.1"
  end

  defp file_mode(path), do: cookie_stat(["-c", "%a", path]) || cookie_stat(["-f", "%Lp", path])

  defp cookie_stat(args) do
    case System.cmd("stat", args, stderr_to_stdout: true) do
      {mode, 0} -> String.trim(mode)
      {_output, _status} -> nil
    end
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
