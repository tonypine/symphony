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
  )
  @refused_env @symphony_env ++ ~w(PATH HOME)

  @doc "The port a playbook's QA-host dev server listens on when it names none."
  @spec default_port() :: pos_integer()
  def default_port, do: @default_port

  @doc "Whether `launch_env` may not set `name`: one Symphony sets on the app itself, `PATH`, `HOME` or `DYLD_*`."
  @spec refused_env?(String.t()) :: boolean()
  def refused_env?(name) when is_binary(name), do: name in @refused_env or String.starts_with?(name, "DYLD_")

  @doc """
  Checks every playbook's `dev_server`, `dev_server_port` and `launch_env`, naming the first key
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
         :ok <- validate_port(path, Map.get(playbook, "dev_server_port")) do
      validate_launch_env(path, Map.get(playbook, "launch_env"))
    end
  end

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
