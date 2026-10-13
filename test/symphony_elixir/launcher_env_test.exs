defmodule SymphonyElixir.LauncherEnvTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.LauncherEnv

  @app :symphony_elixir
  @launcher_vars ~w(ROOTDIR BINDIR EMU PROGNAME RELEASE_ROOT RELEASE_NAME RELEASE_VSN RELEASE_SYS_CONFIG RELEASE_TMP SYMPHONY_RELEASE_ROOT)
  @root "/Applications/Symphony.app/Contents/Resources/symphony-release"

  setup do
    previous_os_env = Map.new(["PATH" | @launcher_vars], &{&1, System.get_env(&1)})
    previous_running_as_release = Application.fetch_env(@app, :running_as_release)

    on_exit(fn ->
      Enum.each(previous_os_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      case previous_running_as_release do
        {:ok, value} -> Application.put_env(@app, :running_as_release, value)
        :error -> Application.delete_env(@app, :running_as_release)
      end
    end)

    :ok
  end

  describe "clear/1" do
    test "unsets the launcher's variables, drops the release from PATH and records a packaged build" do
      Enum.each(@launcher_vars, &System.put_env(&1, "set-by-launcher"))
      Application.put_env(@app, :running_as_release, false)

      env = %{
        "SYMPHONY_RELEASE_ROOT" => @root,
        "PATH" => "#{@root}/erts-16.4/bin:#{@root}/bin:/opt/homebrew/bin:/usr/bin"
      }

      assert LauncherEnv.clear(env) == :ok

      assert Enum.all?(@launcher_vars, &(System.get_env(&1) == nil))
      assert System.get_env("PATH") == "/opt/homebrew/bin:/usr/bin"
      assert Application.get_env(@app, :running_as_release) == true
    end

    test "leaves the environment alone when no launcher started the service" do
      System.put_env("BINDIR", "/usr/local/lib/erlang/bin")
      path = System.get_env("PATH")
      Application.put_env(@app, :running_as_release, false)

      assert LauncherEnv.clear(%{"PATH" => "/usr/bin", "SYMPHONY_RELEASE_ROOT" => ""}) == :ok
      assert LauncherEnv.clear(%{"PATH" => "/usr/bin"}) == :ok

      assert System.get_env("BINDIR") == "/usr/local/lib/erlang/bin"
      assert System.get_env("PATH") == path
      assert Application.get_env(@app, :running_as_release) == false
    end

    test "reads the current OS environment by default" do
      System.put_env("SYMPHONY_RELEASE_ROOT", @root)
      System.put_env("BINDIR", "#{@root}/erts-16.4/bin")
      System.put_env("PATH", "#{@root}/bin:/usr/bin")

      assert LauncherEnv.clear() == :ok

      assert System.get_env("SYMPHONY_RELEASE_ROOT") == nil
      assert System.get_env("BINDIR") == nil
      assert System.get_env("PATH") == "/usr/bin"
    end
  end

  describe "build_path_without_release/2" do
    test "drops the release root and every entry inside it, keeping the rest in order" do
      path = "/usr/bin:#{@root}:#{@root}/erts-16.4/bin:/opt/homebrew/bin:#{@root}/bin/"

      assert LauncherEnv.build_path_without_release(path, @root) == "/usr/bin:/opt/homebrew/bin"
    end

    test "keeps a sibling whose name only starts with the release root, and empty entries" do
      path = "#{@root}-old/bin::/usr/bin"

      assert LauncherEnv.build_path_without_release(path, @root) == "#{@root}-old/bin::/usr/bin"
    end
  end
end
