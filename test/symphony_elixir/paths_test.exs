defmodule SymphonyElixir.PathsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Paths

  @app :symphony_elixir
  @state_keys [:state_root_override, :state_root]
  @logs_keys [:logs_root_override, :logs_root, :log_file]
  @release_keys [:running_as_release]
  @burrito_env "__BURRITO"
  @release_root_env "SYMPHONY_RELEASE_ROOT"

  setup do
    previous_state_env = System.get_env("SYMPHONY_STATE_ROOT")
    previous_logs_env = System.get_env("SYMPHONY_LOGS_ROOT")
    previous_burrito_env = System.get_env(@burrito_env)
    previous_release_root_env = System.get_env(@release_root_env)
    previous_env = Map.new(@state_keys ++ @logs_keys ++ @release_keys, &{&1, Application.get_env(@app, &1)})

    System.delete_env("SYMPHONY_STATE_ROOT")
    System.delete_env("SYMPHONY_LOGS_ROOT")
    System.delete_env(@burrito_env)
    System.delete_env(@release_root_env)
    Enum.each(@state_keys ++ @logs_keys ++ @release_keys, &Application.delete_env(@app, &1))
    Application.put_env(@app, :running_as_release, false)

    on_exit(fn ->
      restore_env("SYMPHONY_STATE_ROOT", previous_state_env)
      restore_env("SYMPHONY_LOGS_ROOT", previous_logs_env)
      restore_env(@burrito_env, previous_burrito_env)
      restore_env(@release_root_env, previous_release_root_env)

      Enum.each(previous_env, fn
        {key, nil} -> Application.delete_env(@app, key)
        {key, value} -> Application.put_env(@app, key, value)
      end)
    end)

    :ok
  end

  test "state root precedence is flag override, env, app env, default" do
    Application.put_env(@app, :state_root, "tmp/app-state")
    System.put_env("SYMPHONY_STATE_ROOT", "tmp/env-state")
    Paths.set_state_root("tmp/flag-state")

    assert Paths.state_root() == Path.expand("tmp/flag-state")

    Application.delete_env(@app, :state_root_override)
    assert Paths.state_root() == Path.expand("tmp/env-state")

    System.delete_env("SYMPHONY_STATE_ROOT")
    assert Paths.state_root() == Path.expand("tmp/app-state")

    Application.delete_env(@app, :state_root)
    assert Paths.state_root() == Path.join([System.user_home!(), "Library", "Application Support", "symphony"])
  end

  test "release builds default state root to a release subdirectory" do
    Application.put_env(@app, :running_as_release, true)

    assert Paths.state_root() ==
             Path.join([System.user_home!(), "Library", "Application Support", "symphony", "release"])

    assert Paths.logs_root() ==
             Path.join([System.user_home!(), "Library", "Logs", "symphony", "release"])
  end

  test "release builds can be detected from the Burrito environment" do
    Application.delete_env(@app, :running_as_release)
    System.put_env(@burrito_env, "1")

    assert Paths.state_root() ==
             Path.join([System.user_home!(), "Library", "Application Support", "symphony", "release"])

    assert Paths.logs_root() ==
             Path.join([System.user_home!(), "Library", "Logs", "symphony", "release"])

    System.put_env(@burrito_env, "")

    assert Paths.state_root() == Path.join([System.user_home!(), "Library", "Application Support", "symphony"])
    assert Paths.logs_root() == Path.join([System.user_home!(), "Library", "Logs", "symphony"])
  end

  test "release builds can be detected from the release launcher's environment" do
    Application.delete_env(@app, :running_as_release)
    System.put_env(@release_root_env, "/Applications/Symphony.app/Contents/Resources/symphony-release")

    assert Paths.state_root() ==
             Path.join([System.user_home!(), "Library", "Application Support", "symphony", "release"])

    assert Paths.logs_root() ==
             Path.join([System.user_home!(), "Library", "Logs", "symphony", "release"])

    System.put_env(@release_root_env, "")

    assert Paths.state_root() == Path.join([System.user_home!(), "Library", "Application Support", "symphony"])
  end

  test "logs root precedence is flag override, env, app env, default" do
    Application.put_env(@app, :logs_root, "tmp/app-logs")
    System.put_env("SYMPHONY_LOGS_ROOT", "tmp/env-logs")
    Paths.set_logs_root("tmp/flag-logs")

    assert Paths.logs_root() == Path.expand("tmp/flag-logs")
    assert Paths.log_file() == Path.join(Path.expand("tmp/flag-logs"), "symphony.log")
    assert Application.get_env(@app, :log_file) == Path.join(Path.expand("tmp/flag-logs"), "symphony.log")

    Application.delete_env(@app, :logs_root_override)
    assert Paths.logs_root() == Path.expand("tmp/env-logs")

    System.delete_env("SYMPHONY_LOGS_ROOT")
    assert Paths.logs_root() == Path.expand("tmp/app-logs")

    Application.delete_env(@app, :logs_root)
    assert Paths.logs_root() == Path.join([System.user_home!(), "Library", "Logs", "symphony"])
  end

  test "release flag is overridden by SYMPHONY_STATE_ROOT and SYMPHONY_LOGS_ROOT" do
    Application.put_env(@app, :running_as_release, true)
    System.put_env("SYMPHONY_STATE_ROOT", "tmp/shared-state")
    System.put_env("SYMPHONY_LOGS_ROOT", "tmp/shared-logs")

    assert Paths.state_root() == Path.expand("tmp/shared-state")
    assert Paths.logs_root() == Path.expand("tmp/shared-logs")
  end

  test "state paths are derived from the resolved state root" do
    Paths.set_state_root("tmp/symphony-state")
    root = Path.expand("tmp/symphony-state")

    assert Paths.run_store_dir() == Path.join(root, "run_store")
    assert Paths.audit_dir() == Path.join(root, "audit")
    assert Paths.secret_key_base_file() == Path.join(root, "secret_key_base")
    assert Paths.erlang_cookie_file() == Path.join(root, "erlang_cookie")
    assert Paths.control_token_file() == Path.join(root, "control_token")
    assert Paths.control_url_file() == Path.join(root, "control_url")
  end

  test "env helpers store trimmed expanded roots in app env" do
    System.put_env("SYMPHONY_STATE_ROOT", " tmp/env-state ")
    System.put_env("SYMPHONY_LOGS_ROOT", " tmp/env-logs ")

    assert :ok = Paths.set_state_root_from_env()
    assert :ok = Paths.set_logs_root_from_env()
    assert Application.get_env(@app, :state_root) == Path.expand("tmp/env-state")
    assert Application.get_env(@app, :logs_root) == Path.expand("tmp/env-logs")
  end

  test "env helpers ignore missing or blank roots" do
    System.put_env("SYMPHONY_STATE_ROOT", " ")
    System.delete_env("SYMPHONY_LOGS_ROOT")

    assert :ok = Paths.set_state_root_from_env()
    assert :ok = Paths.set_logs_root_from_env()
    refute Application.get_env(@app, :state_root)
    refute Application.get_env(@app, :logs_root)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
