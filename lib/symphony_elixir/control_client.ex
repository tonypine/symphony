defmodule SymphonyElixir.ControlClient do
  @moduledoc """
  Client for the Symphony daemon's operator controls: pause, resume, stop,
  and PR dispatch. Talks to the HTTP control plane at
  `POST /api/v1/control/*` so the CLI does not need distributed Erlang. It also
  fetches the terminal dashboard frame (`GET /api/v1/state?format=terminal`)
  for `symphony dashboard`.

  Calls invoked from inside the daemon BEAM (e.g. tests, attached IEx)
  short-circuit to the in-process `SymphonyElixir.Orchestrator` GenServer
  unless `prefer_local?: false` is passed.
  """

  alias SymphonyElixir.{ControlToken, ControlUrl, Orchestrator}

  @default_url "http://127.0.0.1:4000"
  @url_env "SYMPHONY_CONTROL_URL"
  @token_env "SYMPHONY_CONTROL_TOKEN"
  @control_path "/api/v1/control/"
  @state_path "/api/v1/state"

  @type control_result :: {:ok, map()} | :unavailable | {:error, term()}

  @spec pause_dispatch(String.t() | nil, keyword()) :: control_result()
  def pause_dispatch(reason, opts \\ []) when is_binary(reason) or is_nil(reason) do
    invoke(:pause_dispatch, [reason], "pause", body_for_pause(reason), opts)
  end

  @spec resume_dispatch(keyword()) :: control_result()
  def resume_dispatch(opts \\ []) do
    invoke(:resume_dispatch, [], "resume", %{}, opts)
  end

  @spec stop_running(String.t(), keyword()) :: control_result()
  def stop_running(identifier, opts \\ []) when is_binary(identifier) do
    invoke(:stop_running, [identifier], "stop", %{issue_identifier: identifier}, opts)
  end

  @spec dispatch_pr(String.t(), keyword(), keyword()) :: control_result()
  def dispatch_pr(target, pr_opts \\ [], opts \\ [])
      when is_binary(target) and is_list(pr_opts) and is_list(opts) do
    invoke(:dispatch_pr, [target, pr_opts], "dispatch_pr", body_for_pr(target, pr_opts), opts)
  end

  @doc """
  Fetches the running Symphony's terminal dashboard, rendered for `columns`
  (the server's default width when nil). Always goes over HTTP.
  """
  @spec dashboard_frame(pos_integer() | nil, keyword()) :: {:ok, String.t()} | :unavailable | {:error, term()}
  def dashboard_frame(columns, opts \\ []) do
    with {:ok, token} <- resolve_token(opts) do
      query = URI.encode_query(Enum.reject([format: "terminal", columns: columns], &is_nil(elem(&1, 1))))
      url = control_url(opts) <> @state_path <> "?" <> query
      getter = Keyword.get(opts, :http_get, &default_get/2)

      case getter.(url, token) do
        {:ok, 200, frame} when is_binary(frame) -> {:ok, frame}
        {:ok, 503, _payload} -> :unavailable
        {:ok, status, payload} -> {:error, {:http_status, status, payload}}
        {:error, reason} -> {:error, {:connection_failed, reason}}
      end
    end
  end

  @doc """
  The control plane URL the client talks to: `:control_url`, then
  `SYMPHONY_CONTROL_URL`, then the URL the running Symphony wrote.
  """
  @spec control_url(keyword()) :: String.t()
  def control_url(opts \\ []) do
    Keyword.get(opts, :control_url) ||
      System.get_env(@url_env) ||
      ControlUrl.read() ||
      @default_url
  end

  defp invoke(function, args, path_suffix, body, opts) do
    if Keyword.get(opts, :prefer_local?, true) and local_orchestrator_alive?() do
      apply(Orchestrator, function, args)
    else
      remote_post(path_suffix, body, opts)
    end
  end

  defp local_orchestrator_alive? do
    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp remote_post(path_suffix, body, opts) do
    with {:ok, token} <- resolve_token(opts) do
      url = control_url(opts) <> @control_path <> path_suffix
      poster = Keyword.get(opts, :http_post, &default_post/3)

      case poster.(url, body, token) do
        {:ok, 200, payload} -> {:ok, atomize_keys(payload)}
        {:ok, 401, payload} -> {:error, {:unauthorized, payload}}
        {:ok, 422, payload} -> {:error, {:invalid_request, payload}}
        {:ok, 503, _payload} -> :unavailable
        {:ok, status, payload} -> {:error, {:http_status, status, payload}}
        {:error, reason} -> {:error, {:connection_failed, reason}}
      end
    end
  end

  defp resolve_token(opts) do
    case Keyword.get(opts, :control_token) ||
           System.get_env(@token_env) ||
           ControlToken.read() do
      nil -> {:error, :control_token_unavailable}
      token when is_binary(token) -> {:ok, token}
    end
  end

  defp body_for_pause(nil), do: %{}
  defp body_for_pause(reason) when is_binary(reason), do: %{reason: reason}

  defp body_for_pr(target, pr_opts) do
    base = %{target: target}

    case Keyword.get(pr_opts, :intent) do
      intent when is_binary(intent) ->
        case String.trim(intent) do
          "" -> base
          trimmed -> Map.put(base, :intent, trimmed)
        end

      _ ->
        base
    end
  end

  defp default_post(url, body, token) do
    {:ok, _started} = Application.ensure_all_started(:req)

    case Req.post(url,
           json: body,
           headers: [{"authorization", "Bearer " <> token}],
           connect_options: [timeout: 5_000],
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: status, body: payload}} -> {:ok, status, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  # No retries: the dashboard polls again a second later anyway.
  defp default_get(url, token) do
    {:ok, _started} = Application.ensure_all_started(:req)

    case Req.get(url,
           headers: [{"authorization", "Bearer " <> token}],
           decode_body: false,
           retry: false,
           connect_options: [timeout: 2_000],
           receive_timeout: 5_000
         ) do
      {:ok, %Req.Response{status: status, body: payload}} -> {:ok, status, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  # Convert response keys to atoms only when the atom already exists in the BEAM —
  # otherwise keep the binary key. Falls back to binary keys for anything we do
  # not recognise so a misconfigured SYMPHONY_CONTROL_URL pointing at an arbitrary
  # server cannot exhaust the atom table.
  defp atomize_keys(value) when is_map(value) do
    Map.new(value, fn
      {k, v} when is_binary(k) -> {to_known_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(value) when is_list(value), do: Enum.map(value, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp to_known_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
