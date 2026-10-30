defmodule SymphonyElixir.QaAgent.PlaybookSettings do
  @moduledoc """
  Checks the QA playbook settings that start the project's dev server on the QA host and hand the
  app under test its environment, wherever `auto_review.playbooks` is set (`symphony.yml` or a
  repository's `WORKFLOW.md`):

  - `dev_server` (boolean): the pass starts `verification.dev_server`; on a `worker_host`, a
    `macos_app` pass starts it on the QA host (see `SymphonyElixir.QaDriver.DevServer`);
  - `dev_server_port` (1..65535, default 8090): the port that server listens on there, as
    `SYMPHONY_VERIFICATION_PORT`;
  - `launch_env` (string to string, default `{}`): extra variables `qa_launch_app` sets on the app
    after Symphony's own, with `$SYMPHONY_VERIFICATION_PORT` replaced by that port. Names match
    `^[A-Z][A-Z0-9_]*$`, and the ones Symphony sets itself, `PATH`, `HOME` and `DYLD_*` are refused.
    The values are written in plain text in a public repository: never a secret.
  - `live` (a `macos_app` playbook only): the project's own server, which a pass marked live
    (`SymphonyElixir.QaPolicy`) runs on the QA host on `dev_server_port`, through the same path as
    `dev_server: true`, with a control token of its own. `build_cmd` and `start_cmd` run it (the
    start command is required), `health_check_url` (default
    `http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state`)
    and `health_timeout_ms` (default 600000) check it, `paths` (globs) and `walkthrough_mentions`
    (words) say which changes make a pass live. A playbook with `dev_server: true` takes no `live`:
    both would listen on its one port.
  """

  alias SymphonyElixir.Verification

  @default_port 8090
  @env_name ~r/\A[A-Z][A-Z0-9_]*\z/

  # The variables `SymphonyElixir.QaDriver` sets on the app itself: QA mode, the OpenRouter stub,
  # API fixtures and the stand-ins `qa_launch_app` takes.
  @symphony_env ~w(
    SYMPHONY_BAR_QA_ROOT
    SYMPHONY_QA_OPENROUTER_URL
    SYMPHONY_BAR_QA_API_FIXTURES
    SYMPHONY_BAR_QA_APPEARANCE
    SYMPHONY_BAR_GH
    SYMPHONY_QA_GH_URL
    SYMPHONY_QA_LINEAR_URL
    SYMPHONY_BAR_QA_OPEN_PANEL_DIR
    SYMPHONY_BAR_UPDATE_URL
    SYMPHONY_BAR_UPDATE_CHECK_INTERVAL
    SYMPHONY_UPDATE_OPEN
    SYMPHONY_BAR_CONTROL_URL
    SYMPHONY_BAR_CONTROL_TOKEN
  )
  @refused_env @symphony_env ++ ~w(PATH HOME)

  @default_live_health_check_url "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state"
  @default_live_health_timeout_ms 600_000
  @live_keys ~w(build_cmd start_cmd health_check_url health_timeout_ms paths walkthrough_mentions)

  @typedoc "A `macos_app` playbook's `live` server, with its defaults filled in."
  @type live_server :: %{
          build_cmd: String.t() | nil,
          start_cmd: String.t(),
          health_check_url: String.t(),
          health_timeout_ms: pos_integer(),
          paths: [String.t()],
          walkthrough_mentions: [String.t()]
        }

  @doc "The port a playbook's QA-host dev server listens on when it names none."
  @spec default_port() :: pos_integer()
  def default_port, do: @default_port

  @doc "Whether `launch_env` may not set `name`: one Symphony sets on the app itself, `PATH`, `HOME` or `DYLD_*`."
  @spec refused_env?(String.t()) :: boolean()
  def refused_env?(name) when is_binary(name), do: name in @refused_env or String.starts_with?(name, "DYLD_")

  @doc """
  Checks every playbook's `dev_server`, `dev_server_port`, `launch_env` and `live`, naming the first key
  that is wrong. A playbook that is not a map is left to the caller.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(playbooks) when is_map(playbooks) do
    playbooks
    |> Enum.sort_by(fn {kind, _playbook} -> to_string(kind) end)
    |> Enum.find_value(:ok, fn
      {kind, playbook} when is_map(playbook) ->
        case validate_playbook("auto_review.playbooks.#{kind}", stringify_keys(playbook)) do
          :ok -> nil
          error -> error
        end

      _other ->
        nil
    end)
  end

  def validate(_playbooks), do: :ok

  defp validate_playbook(path, playbook) do
    with :ok <- validate_dev_server(path, Map.get(playbook, "dev_server")),
         :ok <- validate_port(path, Map.get(playbook, "dev_server_port")),
         :ok <- validate_launch_env(path, Map.get(playbook, "launch_env")) do
      validate_live(path, playbook)
    end
  end

  defp validate_live(_path, %{"live" => nil}), do: :ok

  defp validate_live(path, %{"live" => live} = playbook) do
    cond do
      not String.ends_with?(path, ".macos_app") -> {:error, "#{path}.live is only read on the macos_app playbook"}
      not is_map(live) -> {:error, "#{path}.live must be a map with at least start_cmd"}
      Map.get(playbook, "dev_server") == true -> {:error, "#{path}.live and #{path}.dev_server: true both run a server on its one port; keep one"}
      true -> validate_live_keys("#{path}.live", stringify_keys(live))
    end
  end

  defp validate_live(_path, _playbook), do: :ok

  defp validate_live_keys(path, live) do
    unknown = live |> Map.keys() |> Enum.reject(&(&1 in @live_keys)) |> Enum.sort()

    cond do
      unknown != [] -> {:error, "#{path}.#{hd(unknown)} is not a live setting; use #{Enum.join(@live_keys, ", ")}"}
      not text?(Map.get(live, "start_cmd")) -> {:error, "#{path}.start_cmd must name the command that starts the server"}
      not optional_text?(Map.get(live, "build_cmd")) -> {:error, "#{path}.build_cmd must be a command"}
      not optional_text?(Map.get(live, "health_check_url")) -> {:error, "#{path}.health_check_url must be a URL"}
      not optional_positive?(Map.get(live, "health_timeout_ms")) -> {:error, "#{path}.health_timeout_ms must be a positive number of milliseconds"}
      not optional_texts?(Map.get(live, "paths")) -> {:error, "#{path}.paths must be a list of path globs"}
      not optional_texts?(Map.get(live, "walkthrough_mentions")) -> {:error, "#{path}.walkthrough_mentions must be a list of words"}
      true -> :ok
    end
  end

  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp optional_text?(value), do: is_nil(value) or text?(value)
  defp optional_positive?(value), do: is_nil(value) or (is_integer(value) and value > 0)
  defp optional_texts?(value), do: is_nil(value) or (is_list(value) and Enum.all?(value, &text?/1))

  @doc """
  The `live` server of a playbook's settings (string keys, as `auto_review.playbooks` holds them),
  with its defaults, or nil when it sets none or one `validate/1` refuses.
  """
  @spec live_server(map()) :: live_server() | nil
  def live_server(%{"live" => live} = playbook) when is_map(live) do
    live = stringify_keys(live)

    if validate_live("auto_review.playbooks.macos_app", playbook) == :ok do
      %{
        build_cmd: Map.get(live, "build_cmd"),
        start_cmd: Map.fetch!(live, "start_cmd"),
        health_check_url: Map.get(live, "health_check_url") || @default_live_health_check_url,
        health_timeout_ms: Map.get(live, "health_timeout_ms") || @default_live_health_timeout_ms,
        paths: Map.get(live, "paths") || [],
        walkthrough_mentions: Map.get(live, "walkthrough_mentions") || []
      }
    end
  end

  def live_server(_playbook), do: nil

  defp validate_dev_server(_path, value) when is_nil(value) or is_boolean(value), do: :ok
  defp validate_dev_server(path, _value), do: {:error, "#{path}.dev_server must be true or false"}

  defp validate_port(_path, nil), do: :ok
  defp validate_port(_path, port) when is_integer(port) and port in 1..65_535, do: :ok
  defp validate_port(path, _port), do: {:error, "#{path}.dev_server_port must be a port number from 1 to 65535"}

  defp validate_launch_env(_path, nil), do: :ok

  defp validate_launch_env(path, env) when is_map(env) do
    env
    |> Enum.map(fn {name, value} -> {to_string(name), value} end)
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {name, value} ->
      case validate_env(name, value) do
        :ok -> nil
        {:error, problem} -> {:error, "#{path}.launch_env.#{name} #{problem}"}
      end
    end)
  end

  defp validate_launch_env(path, _env), do: {:error, "#{path}.launch_env must be a map of variable names to strings"}

  defp validate_env(name, value) do
    cond do
      not Regex.match?(@env_name, name) -> {:error, "is not a variable name: use capital letters, digits and _, starting with a letter"}
      refused_env?(name) -> {:error, "is set by Symphony or the system, so launch_env may not set it"}
      not is_binary(value) -> {:error, "must be a string; quote the value"}
      true -> :ok
    end
  end

  @doc """
  The playbook's `launch_env` as `{name, value}` pairs sorted by name, with
  `$SYMPHONY_VERIFICATION_PORT` replaced by its `dev_server_port`. `{:error, name}` names a
  variable `refused_env?/1` refuses.
  """
  @spec launch_env(map()) :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def launch_env(playbook) when is_map(playbook) do
    port = Map.get(playbook, :dev_server_port) || @default_port
    env = for {name, value} <- Map.get(playbook, :launch_env) || %{}, do: {to_string(name), Verification.interpolate_port(to_string(value), port)}

    case Enum.find(env, fn {name, _value} -> refused_env?(name) end) do
      nil -> {:ok, Enum.sort(env)}
      {name, _value} -> {:error, name}
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
