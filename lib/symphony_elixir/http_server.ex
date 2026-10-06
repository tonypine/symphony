defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  alias SymphonyElixir.{Config, ControlToken, ControlUrl, Orchestrator}
  alias SymphonyElixirWeb.Endpoint
  require Logger

  @secret_key_bytes 48
  @secret_key_min_bytes 64
  @secret_key_env "SYMPHONY_SECRET_KEY_BASE"
  @allow_remote_bind_env "SYMPHONY_ALLOW_REMOTE_BIND"
  @allowed_origins_env "SYMPHONY_DASHBOARD_ALLOWED_ORIGINS"
  @loopback_hosts ~w(localhost 127.0.0.1 ::1)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        host = Keyword.get(opts, :host, Config.server_host())
        orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

        with {:ok, ip} <- parse_host(host),
             :ok <- guard_remote_bind(ip, host) do
          start_endpoint(ip, port, host, orchestrator, snapshot_timeout_ms)
        end

      _ ->
        :ignore
    end
  end

  defp start_endpoint(ip, port, host, orchestrator, snapshot_timeout_ms) do
    endpoint_opts = [
      server: true,
      http: [ip: ip, port: port],
      url: [host: normalize_host(host)],
      orchestrator: orchestrator,
      snapshot_timeout_ms: snapshot_timeout_ms,
      secret_key_base: secret_key_base()
    ]

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(endpoint_opts)

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)

    with {:ok, _pid} = ok <- Endpoint.start_link() do
      persist_control_url(ip, host)
      _ = ControlToken.current()
      ok
    end
  end

  # A unix socket has no URL for the CLI; its server is reached through a bridge.
  defp persist_control_url({:local, _path}, _host), do: :ok

  defp persist_control_url(_ip, host) do
    case bound_port() do
      port when is_integer(port) ->
        url = "http://#{discovery_host(host)}:#{port}"

        case ControlUrl.persist(url) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("failed to persist control_url to #{inspect(ControlUrl.path())}: #{inspect(reason)}")
            :ok
        end

      _ ->
        Logger.warning("skipping control_url persist: Bandit has no bound port yet; CLI will fall back to the default URL")
        :ok
    end
  end

  # The control_url file is consumed by same-machine CLI clients. Wildcard bind
  # addresses (0.0.0.0, ::) are not valid destinations, so rewrite them to a
  # loopback equivalent. Remote callers should set SYMPHONY_CONTROL_URL.
  defp discovery_host("0.0.0.0"), do: "127.0.0.1"
  defp discovery_host("::"), do: "::1"
  defp discovery_host("::0"), do: "::1"
  defp discovery_host(host), do: normalize_host(host)

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  @doc """
  Phoenix `check_origin` callback for the dashboard WebSocket.

  Accepts loopback origins unconditionally, the configured `server.host`,
  and any host listed in `SYMPHONY_DASHBOARD_ALLOWED_ORIGINS` (comma-separated,
  hostnames only — scheme is ignored, port is irrelevant).
  """
  @spec allowed_origin?(URI.t()) :: boolean()
  def allowed_origin?(%URI{host: host}) when is_binary(host) and host != "" do
    host_down = String.downcase(host)
    host_down in @loopback_hosts or host_down in extra_allowed_hosts()
  end

  def allowed_origin?(_uri), do: false

  defp extra_allowed_hosts do
    configured_server_host() ++ env_allowed_hosts()
  end

  defp configured_server_host do
    case Config.server_host() do
      h when is_binary(h) and h != "" -> [String.downcase(h)]
      _ -> []
    end
  rescue
    _ -> []
  end

  defp env_allowed_hosts do
    @allowed_origins_env
    |> System.get_env()
    |> parse_origin_env()
  end

  defp parse_origin_env(nil), do: []

  defp parse_origin_env(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&host_of/1)
  end

  defp host_of(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> value |> String.downcase() |> String.trim_leading("//")
    end
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  # `unix:<path>` listens on a unix socket instead, as the verification dev server does on macOS
  # (`scripts/qa-dashboard-server.sh`), where Symphony serves it on loopback.
  defp parse_host("unix:" <> path) when path != "", do: {:ok, {:local, path}}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp guard_remote_bind(ip, host) do
    cond do
      loopback?(ip) ->
        :ok

      System.get_env(@allow_remote_bind_env) == "1" ->
        :ok

      true ->
        {:error,
         "refusing to bind HTTP server to non-loopback host #{inspect(host)}: " <>
           "the dashboard has no built-in auth. Put a reverse proxy with auth in " <>
           "front and keep SYMPHONY_SERVER_HOST=127.0.0.1, or set " <>
           "#{@allow_remote_bind_env}=1 if you understand the risk."}
    end
  end

  defp loopback?({:local, _path}), do: true
  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false

  defp normalize_host(host) when host in ["", nil], do: "127.0.0.1"
  defp normalize_host("unix:" <> _path), do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host), do: to_string(host)

  defp secret_key_base do
    case System.get_env(@secret_key_env) do
      value when is_binary(value) and byte_size(value) >= @secret_key_min_bytes ->
        value

      value when is_binary(value) and value != "" ->
        raise """
        #{@secret_key_env} must be at least #{@secret_key_min_bytes} bytes; got #{byte_size(value)}.
        Generate one with `mix phx.gen.secret` or unset the variable to use the persisted key.
        """

      _ ->
        load_or_create_secret_key_base()
    end
  end

  defp load_or_create_secret_key_base do
    path = secret_key_base_path()
    migrate_legacy_secret_key_base(legacy_secret_key_base_path(), path)

    with {:ok, contents} <- File.read(path),
         key = String.trim(contents),
         true <- byte_size(key) >= @secret_key_min_bytes do
      key
    else
      _ -> write_secret_key_base!(path)
    end
  end

  defp write_secret_key_base!(path) do
    key = generate_secret_key_base()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    _ = File.chmod(dir, 0o700)
    File.write!(path, key)
    _ = File.chmod(path, 0o600)
    key
  end

  defp generate_secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end

  defp secret_key_base_path do
    SymphonyElixir.Paths.secret_key_base_file()
  end

  defp legacy_secret_key_base_path do
    Path.join([System.user_home!(), ".symphony", "secret_key_base"])
  end

  @doc false
  @spec migrate_legacy_secret_key_base(Path.t(), Path.t()) :: :ok
  def migrate_legacy_secret_key_base(old_path, new_path) do
    if old_path != new_path and File.exists?(old_path) and not File.exists?(new_path) do
      with :ok <- File.mkdir_p(Path.dirname(new_path)),
           :ok <- File.rename(old_path, new_path) do
        Logger.info("migrated secret_key_base from ~/.symphony/ to #{new_path}")
        :ok
      else
        {:error, reason} ->
          Logger.warning("failed to migrate secret_key_base from ~/.symphony/ to #{new_path}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end
end
