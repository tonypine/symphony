defmodule SymphonyElixir.Paths do
  @moduledoc """
  Resolves filesystem paths used for Symphony runtime state.
  """

  @app :symphony_elixir
  @state_root_env "SYMPHONY_STATE_ROOT"
  @logs_root_env "SYMPHONY_LOGS_ROOT"
  @state_root_override_key :state_root_override
  @logs_root_override_key :logs_root_override
  @burrito_env "__BURRITO"
  @release_subdir "release"

  @spec state_root() :: Path.t()
  def state_root do
    configured_root(@state_root_override_key) ||
      env_root(@state_root_env) ||
      configured_root(:state_root) ||
      default_state_root()
  end

  @spec logs_root() :: Path.t()
  def logs_root do
    configured_root(@logs_root_override_key) ||
      env_root(@logs_root_env) ||
      configured_root(:logs_root) ||
      default_logs_root()
  end

  @spec log_file() :: Path.t()
  def log_file do
    Path.join(logs_root(), "symphony.log")
  end

  @spec run_store_dir() :: Path.t()
  def run_store_dir do
    Path.join(state_root(), "run_store")
  end

  @spec audit_dir() :: Path.t()
  def audit_dir do
    Path.join(state_root(), "audit")
  end

  @spec secret_key_base_file() :: Path.t()
  def secret_key_base_file do
    Path.join(state_root(), "secret_key_base")
  end

  @spec erlang_cookie_file() :: Path.t()
  def erlang_cookie_file do
    Path.join(state_root(), "erlang_cookie")
  end

  @spec control_token_file() :: Path.t()
  def control_token_file do
    Path.join(state_root(), "control_token")
  end

  @spec control_url_file() :: Path.t()
  def control_url_file do
    Path.join(state_root(), "control_url")
  end

  @spec set_state_root(Path.t()) :: :ok
  def set_state_root(root) when is_binary(root) do
    Application.put_env(@app, @state_root_override_key, Path.expand(root))
    :ok
  end

  @spec set_logs_root(Path.t()) :: :ok
  def set_logs_root(root) when is_binary(root) do
    expanded_root = Path.expand(root)
    Application.put_env(@app, @logs_root_override_key, expanded_root)
    Application.put_env(@app, :log_file, Path.join(expanded_root, "symphony.log"))
    :ok
  end

  @spec set_state_root_from_env() :: :ok
  def set_state_root_from_env do
    set_root_from_env(@state_root_env, :state_root)
  end

  @spec set_logs_root_from_env() :: :ok
  def set_logs_root_from_env do
    set_root_from_env(@logs_root_env, :logs_root)
  end

  defp set_root_from_env(env_name, app_env_key) do
    case env_root(env_name) do
      nil -> :ok
      root -> Application.put_env(@app, app_env_key, root)
    end

    :ok
  end

  defp configured_root(key) do
    @app
    |> Application.get_env(key)
    |> normalize_root()
  end

  defp env_root(name) do
    name
    |> System.get_env()
    |> normalize_root()
  end

  defp normalize_root(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      root -> Path.expand(root)
    end
  end

  defp normalize_root(_value), do: nil

  defp default_state_root do
    [System.user_home!(), "Library", "Application Support", "symphony"]
    |> Path.join()
    |> maybe_append_release_subdir()
  end

  defp default_logs_root do
    [System.user_home!(), "Library", "Logs", "symphony"]
    |> Path.join()
    |> maybe_append_release_subdir()
  end

  defp maybe_append_release_subdir(base) do
    if running_as_release?(), do: Path.join(base, @release_subdir), else: base
  end

  # The release service runs as `symphony@127.0.0.1` (`SymphonyElixir.ReleaseNode`) while
  # `mix run` / escript runs default to `nonode@nohost`. Mnesia tags every
  # disc_copies replica with `node()`, so a single state dir can't be shared
  # across the two. Route the release to its own subdirectory so the two modes
  # never see each other's schema unless the operator explicitly opts in by
  # setting SYMPHONY_STATE_ROOT.
  defp running_as_release? do
    case Application.fetch_env(@app, :running_as_release) do
      {:ok, value} when is_boolean(value) -> value
      _ -> detect_burrito_release()
    end
  end

  defp detect_burrito_release do
    System.get_env(@burrito_env) not in [nil, ""]
  end
end
