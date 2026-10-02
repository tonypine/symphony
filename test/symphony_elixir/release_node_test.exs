defmodule SymphonyElixir.ReleaseNodeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ReleaseNode

  defp deps(overrides) do
    test_pid = self()

    Map.merge(
      %{
        alive?: fn -> false end,
        start_epmd: fn -> send(test_pid, :epmd_started) end,
        start_node: fn name ->
          send(test_pid, {:node_started, name})
          {:ok, test_pid}
        end,
        cookie: fn -> "secret_cookie" end,
        set_cookie: fn cookie ->
          send(test_pid, {:cookie_set, cookie})
          true
        end
      },
      Map.new(overrides)
    )
  end

  test "starts epmd, takes the fixed service node name and applies the release cookie" do
    assert :ok = ReleaseNode.start(deps([]))

    assert_received :epmd_started
    assert_received {:node_started, :"symphony@127.0.0.1"}
    assert_received {:cookie_set, :secret_cookie}
  end

  test "leaves an already distributed node alone" do
    assert :ok = ReleaseNode.start(deps(alive?: fn -> true end))

    refute_received :epmd_started
    refute_received {:node_started, _name}
    refute_received {:cookie_set, _cookie}
  end

  test "reports a taken node name without applying the cookie" do
    start_node = fn _name -> {:error, {:shutdown, :nodistribution}} end

    assert {:error, message} = ReleaseNode.start(deps(start_node: start_node))

    assert message =~ "Could not start Erlang distribution as symphony@127.0.0.1."
    assert message =~ "Is another Symphony already running?"
    assert message =~ ":nodistribution"
    refute_received {:cookie_set, _cookie}
  end

  test "runtime deps report the local node state" do
    deps = ReleaseNode.runtime_deps()

    assert deps.alive?.() == Node.alive?()
    assert is_function(deps.start_epmd, 0)
    assert is_function(deps.start_node, 1)
    assert is_function(deps.cookie, 0)
    assert is_function(deps.set_cookie, 1)
  end

  describe "start_epmd/1" do
    setup do
      bindir = Path.join(System.tmp_dir!(), "symphony-release-node-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bindir)
      on_exit(fn -> File.rm_rf(bindir) end)
      {:ok, bindir: bindir}
    end

    test "runs epmd from BINDIR as a daemon", %{bindir: bindir} do
      marker = Path.join(bindir, "epmd-args")
      epmd = Path.join(bindir, "epmd")
      File.write!(epmd, "#!/bin/sh\nprintf '%s' \"$*\" > #{marker}\nexit 1\n")
      File.chmod!(epmd, 0o755)

      assert :ok = ReleaseNode.start_epmd(bindir)
      assert File.read!(marker) == "-daemon"
    end

    test "reads BINDIR by default", %{bindir: bindir} do
      marker = Path.join(bindir, "epmd-args")
      epmd = Path.join(bindir, "epmd")
      File.write!(epmd, "#!/bin/sh\nprintf '%s' \"$*\" > #{marker}\n")
      File.chmod!(epmd, 0o755)
      previous = System.get_env("BINDIR")
      System.put_env("BINDIR", bindir)

      on_exit(fn ->
        if previous, do: System.put_env("BINDIR", previous), else: System.delete_env("BINDIR")
      end)

      assert :ok = ReleaseNode.start_epmd()
      assert File.read!(marker) == "-daemon"
    end

    test "skips a BINDIR without epmd", %{bindir: bindir} do
      assert :ok = ReleaseNode.start_epmd(bindir)
    end

    test "skips a missing BINDIR" do
      assert :ok = ReleaseNode.start_epmd(nil)
      assert :ok = ReleaseNode.start_epmd("")
    end
  end
end
