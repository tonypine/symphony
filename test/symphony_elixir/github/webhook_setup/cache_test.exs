defmodule SymphonyElixir.GitHub.WebhookSetup.CacheTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.WebhookSetup.Cache, as: SectionCache

  setup do
    test = self()
    port = start_supervised!({Agent, fn -> 4040 end}, id: :port)

    opts = [
      relays: Module.concat(__MODULE__, NoRelays),
      secret: fn -> nil end,
      port: fn -> Agent.get(port, & &1) end,
      repos: fn ->
        send(test, :repos_read)
        [%{key: "app", github: "acme/app"}]
      end
    ]

    %{opts: opts, port: port}
  end

  test "without a server, or before its first build ends, a read builds the section here", %{opts: opts} do
    stopped = [cache: Module.concat(__MODULE__, Stopped)]
    assert %{repos: [%{key: "app"}]} = SectionCache.state_section(stopped ++ opts)
    assert :ok = SectionCache.put(%{mode: "on"}, stopped)
    assert :ok = SectionCache.refresh(stopped)
    assert %{repos: [%{key: "app"}]} = SectionCache.state_section(stopped ++ opts)

    server = start_cache!(section_opts: Keyword.put(opts, :secret, gate(self())))
    assert_receive {:building, task}
    direct = [cache: server] ++ Keyword.put(opts, :repos, fn -> [%{key: "direct", github: "acme/direct"}] end)
    assert %{repos: [%{key: "direct"}]} = SectionCache.state_section(direct)

    send(task, :go)
    await_idle(server)
    assert %{repos: [%{key: "app"}]} = SectionCache.state_section(direct)
  end

  test "builds again on refresh and every interval, with the repositories it read at start", %{opts: opts, port: port} do
    server = start_cache!(section_opts: opts)
    assert_receive :repos_read
    await_idle(server)
    assert local_url(server) == "http://127.0.0.1:4040/api/v1/github/webhook"

    Agent.update(port, fn _port -> 4041 end)
    assert :ok = SectionCache.refresh(cache: server)
    await_idle(server)
    assert local_url(server) == "http://127.0.0.1:4041/api/v1/github/webhook"

    Agent.update(port, fn _port -> 4042 end)
    send(server, :tick)
    await_idle(server)
    assert local_url(server) == "http://127.0.0.1:4042/api/v1/github/webhook"
    refute_received :repos_read
  end

  test "a put replaces the section, and drops a build that started before it", %{opts: opts} do
    server = start_cache!(section_opts: Keyword.put(opts, :secret, gate(self())))
    assert_receive {:building, first}
    send(first, :go)
    await_idle(server)
    assert %{mode: "off"} = SectionCache.state_section(cache: server)

    SectionCache.refresh(cache: server)
    assert_receive {:building, stale}
    assert :ok = SectionCache.put(%{mode: "on"}, cache: server)
    assert SectionCache.state_section(cache: server) == %{mode: "on"}

    send(stale, :go)
    await_idle(server)
    assert SectionCache.state_section(cache: server) == %{mode: "on"}

    SectionCache.refresh(cache: server)
    assert_receive {:building, fresh}
    send(fresh, :go)
    await_idle(server)
    assert %{mode: "off"} = SectionCache.state_section(cache: server)
  end

  test "a config reload builds once, however many events it sends, drops the build it interrupts and reads the repositories again",
       %{opts: opts, port: port} do
    server = start_cache!(section_opts: Keyword.put(opts, :secret, gate(self())))
    assert_receive :repos_read
    assert_receive {:building, first}

    # Both events wait in the mailbox before the first one starts the debounce timer.
    :sys.suspend(server)
    :telemetry.execute(Cache.reloaded_event(), %{}, %{path: "a"})
    :telemetry.execute(Cache.reloaded_event(), %{}, %{path: "b"})
    :sys.resume(server)
    wait_until(server, & &1.rerun?, 1_000)

    # The first build read port 4040 before the reload; the one after it reads 4041.
    Agent.update(port, fn _port -> 4041 end)
    send(first, :go)
    assert_receive :repos_read
    assert_receive {:building, second}
    direct = [cache: server] ++ Keyword.put(opts, :repos, fn -> [%{key: "direct", github: "acme/direct"}] end)
    assert %{repos: [%{key: "direct"}]} = SectionCache.state_section(direct)

    send(second, :go)
    await_idle(server)
    assert local_url(server) == "http://127.0.0.1:4041/api/v1/github/webhook"
    refute_received {:building, _task}
    refute_received :repos_read
  end

  test "a build that crashes keeps the last section", %{opts: opts} do
    repos = start_supervised!({Agent, fn -> [%{key: "app", github: "acme/app"}] end}, id: :repos)
    opts = Keyword.put(opts, :repos, fn -> repos |> Agent.get(& &1) |> then(&if(&1 == :raise, do: raise("git failed"), else: &1)) end)
    server = start_cache!(section_opts: opts)
    await_idle(server)
    assert %{repos: [%{key: "app"}]} = SectionCache.state_section(cache: server)

    Agent.update(repos, fn _repos -> :raise end)

    log =
      capture_log(fn ->
        :telemetry.execute(Cache.reloaded_event(), %{}, %{path: "symphony.yml"})
        await_idle(server)
      end)

    assert log =~ "Instant GitHub updates section build crashed"
    assert %{repos: [%{key: "app"}]} = SectionCache.state_section(cache: server)
  end

  test "a section it couldn't read is nil in the state", %{opts: opts} do
    server = start_cache!(section_opts: Keyword.put(opts, :settings, fn -> raise ArgumentError, "symphony.yml doesn't load" end))
    await_idle(server)

    assert SectionCache.state_section([cache: server] ++ opts) == nil
  end

  test "a server that stops while it is asked reads as no server", %{opts: opts} do
    name = Module.concat(__MODULE__, Stopping)
    pid = spawn(fn -> receive do: (_call -> :ok) end)
    Process.register(pid, name)

    assert %{repos: [%{key: "app"}]} = SectionCache.state_section([cache: name] ++ opts)
  end

  defp start_cache!(opts) do
    name = Module.concat(__MODULE__, "Cache#{System.unique_integer([:positive])}")
    start_supervised!({SectionCache, Keyword.merge([name: name, interval_ms: 60_000, reload_debounce_ms: 0], opts)})
    name
  end

  # A secret read that waits for `:go`: the section reads the secret once per build, in the build's task.
  defp gate(test) do
    fn ->
      send(test, {:building, self()})

      receive do
        :go -> nil
      end
    end
  end

  defp local_url(server), do: SectionCache.state_section(cache: server).relay.local_url

  defp await_idle(server) do
    case :sys.get_state(server) do
      %{task: %Task{pid: pid}} ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        await_idle(server)

      %{reload_timer: timer} when is_reference(timer) ->
        await_idle(server)

      _idle ->
        :ok
    end
  end

  defp wait_until(server, condition, attempts) when attempts > 0 do
    if condition.(:sys.get_state(server)), do: :ok, else: wait_until(server, condition, attempts - 1)
  end
end
