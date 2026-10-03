defmodule SymphonyElixir.SSH do
  @moduledoc false

  @spec run(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      {timeout_ms, cmd_opts} = Keyword.pop(opts, :timeout_ms)

      run_ssh_command(executable, ssh_args(host, command, opts), cmd_opts, timeout_ms)
    end
  end

  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      line_bytes = Keyword.get(opts, :line)
      env = Keyword.get(opts, :env)
      stdin_path = Keyword.get(opts, :stdin_path)
      ssh_args = ssh_args(host, command, opts)

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(port_args(executable, ssh_args, stdin_path), &String.to_charlist/1)
        ]
        |> maybe_put_line_option(line_bytes)
        |> maybe_put_env_option(env)

      with {:ok, spawn_executable} <- port_executable(executable, stdin_path) do
        {:ok, Port.open({:spawn_executable, String.to_charlist(spawn_executable)}, port_opts)}
      end
    end
  end

  # For callers that run the command themselves and parse its output: ssh never
  # prompts and keeps its own warnings out of the output.
  @spec command(String.t(), String.t()) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def command(host, command) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      {:ok, executable, ssh_args(host, command, options: ["-o", "BatchMode=yes", "-o", "LogLevel=ERROR"])}
    end
  end

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    "bash -lc " <> shell_escape(command)
  end

  defp ssh_executable do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp run_ssh_command(executable, args, opts, nil) do
    {:ok, System.cmd(executable, args, opts)}
  end

  defp run_ssh_command(executable, args, opts, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    task = Task.async(fn -> System.cmd(executable, args, opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, {:timeout, timeout_ms}}
    end
  end

  defp run_ssh_command(_executable, _args, _opts, timeout_ms), do: {:error, {:invalid_timeout_ms, timeout_ms}}

  defp shell_executable do
    case System.find_executable("sh") do
      nil -> {:error, :shell_not_found}
      executable -> {:ok, executable}
    end
  end

  defp port_executable(ssh_executable, nil), do: {:ok, ssh_executable}
  defp port_executable(_ssh_executable, stdin_path) when is_binary(stdin_path), do: shell_executable()

  defp port_args(_ssh_executable, ssh_args, nil), do: ssh_args

  defp port_args(ssh_executable, ssh_args, stdin_path) when is_binary(stdin_path) do
    [
      "-c",
      "prompt_file=$1; shift; exec \"$@\" < \"$prompt_file\"",
      "symphony-ssh-stdin",
      stdin_path,
      ssh_executable
      | ssh_args
    ]
  end

  defp ssh_args(host, command, opts) do
    %{destination: destination, port: port} = parse_target(host)

    []
    |> maybe_put_config()
    |> maybe_put_reverse_forwards(Keyword.get(opts, :reverse_forwards, []))
    |> Kernel.++(Keyword.get(opts, :options, []))
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> Kernel.++([destination, remote_shell_command(command)])
  end

  defp maybe_put_line_option(port_opts, nil), do: port_opts
  defp maybe_put_line_option(port_opts, line_bytes), do: Keyword.put(port_opts, :line, line_bytes)

  defp maybe_put_env_option(port_opts, nil), do: port_opts
  defp maybe_put_env_option(port_opts, env) when is_list(env), do: Keyword.put(port_opts, :env, env)

  defp maybe_put_config(args) do
    case System.get_env("SYMPHONY_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  defp maybe_put_reverse_forwards(args, forwards) when is_list(forwards) do
    Enum.reduce(forwards, args, fn
      {remote_socket, local_socket}, acc when is_binary(remote_socket) and is_binary(local_socket) ->
        acc ++ ["-R", "#{remote_socket}:#{local_socket}"]

      _invalid, acc ->
        acc
    end)
  end

  defp maybe_put_reverse_forwards(args, _forwards), do: args

  defp parse_target(target) when is_binary(target) do
    trimmed_target = String.trim(target)

    # OpenSSH does not interpret bare "host:port" as "host + port"; it treats the
    # whole value as a hostname and leaves the port at 22. We split that shorthand
    # here so worker config can use "localhost:2222" without requiring ssh:// URIs.
    case Regex.run(~r/^(.*):(\d+)$/, trimmed_target, capture: :all_but_first) do
      [destination, port] ->
        if valid_port_destination?(destination) do
          %{destination: destination, port: port}
        else
          %{destination: trimmed_target, port: nil}
        end

      _ ->
        %{destination: trimmed_target, port: nil}
    end
  end

  defp valid_port_destination?(destination) when is_binary(destination) do
    destination != "" and
      (not String.contains?(destination, ":") or bracketed_host?(destination))
  end

  defp bracketed_host?(destination) when is_binary(destination) do
    # IPv6 literals contain ":" already, so we only accept additional ":port"
    # parsing when the host is explicitly bracketed, e.g. "[::1]:2222".
    String.contains?(destination, "[") and String.contains?(destination, "]")
  end

  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
