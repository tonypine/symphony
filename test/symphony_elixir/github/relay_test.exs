defmodule SymphonyElixir.GitHub.RelayTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.GitHub.Relay
  alias SymphonyElixir.Secret

  @secret "relay-test-secret-0123456789"

  setup do
    dir = Path.join(System.tmp_dir!(), "relay-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    spec = %{repo_key: "app", repo: "acme/app", events: ["push", "check_suite"], url: "http://127.0.0.1:4040/api/v1/github/webhook", secret: Secret.wrap(@secret)}
    %{dir: dir, spec: spec}
  end

  # A stand-in for `gh`: it records its pid and arguments, then runs or fails as `body` says.
  defp fake_gh(dir, body) do
    path = Path.join(dir, "gh-#{System.unique_integer([:positive])}")

    File.write!(path, """
    #!/bin/sh
    echo $$ > "#{dir}/pid"
    printf '%s\\n' "$@" > "#{dir}/args"
    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp start_relay(spec, opts) do
    test = self()
    timer = fn ms, message -> send(test, {:timer, ms, message}) && make_ref() end
    start_supervised!({Relay, [spec: spec, timer: timer] ++ opts})
  end

  defp wait_for_file(path) do
    Enum.find_value(1..200, fn _attempt -> if File.exists?(path) and File.read!(path) != "", do: true, else: Process.sleep(10) && nil end)
  end

  test "runs gh webhook forward for the repository with its events, local URL and secret", %{dir: dir, spec: spec} do
    relay = start_relay(spec, executable: fake_gh(dir, "echo 'Forwarding Webhook events from GitHub...'\nexec sleep 30"))

    assert wait_for_file(Path.join(dir, "args"))

    assert File.read!(Path.join(dir, "args")) |> String.split("\n", trim: true) ==
             ["webhook", "forward", "--repo", "acme/app", "--events", "push,check_suite", "--url", spec.url, "--secret", @secret]

    assert %{state: :running, restarts: 0, failures: 0, last_error: nil, started_at: %DateTime{}} = Relay.status(relay)
  end

  test "a gh that exits is started again after 1 s, then 2 s, its error kept without the secret", %{dir: dir, spec: spec} do
    gh = fake_gh(dir, "echo \"error: Hook already exists (secret ${10})\"\nexit 1")

    log =
      capture_log(fn ->
        relay = start_relay(spec, executable: gh)

        assert_receive {:timer, 1_000, :start}, 2_000
        assert %{state: :restarting, failures: 1, restarts: 0, last_error: "error: Hook already exists (secret [secret])"} = Relay.status(relay)

        send(relay, :start)
        assert_receive {:timer, 2_000, :start}, 2_000
        assert %{failures: 2, restarts: 1} = Relay.status(relay)
      end)

    assert log =~ "GitHub relay for repo=app github=acme/app stopped: error: Hook already exists"
    refute log =~ @secret
  end

  test "a gh that dies without a word is reported by its exit status", %{dir: dir, spec: spec} do
    capture_log(fn ->
      relay = start_relay(spec, executable: fake_gh(dir, "exit 3"))

      assert_receive {:timer, 1_000, :start}, 2_000
      assert %{last_error: "gh webhook forward stopped (exit status 3)"} = Relay.status(relay)
    end)
  end

  test "a killed relay restarts, and one that ran a minute starts its wait over", %{dir: dir, spec: spec} do
    clock = start_supervised!({Agent, fn -> 0 end})
    gh = fake_gh(dir, "exec sleep 30")

    capture_log(fn ->
      relay = start_relay(spec, executable: gh, clock: fn -> Agent.get(clock, & &1) end)
      assert wait_for_file(Path.join(dir, "pid"))

      # A drop right after the start counts as a failure in a row.
      kill(dir)
      assert_receive {:timer, 1_000, :start}, 2_000
      File.rm!(Path.join(dir, "pid"))
      send(relay, :start)
      assert wait_for_file(Path.join(dir, "pid"))
      kill(dir)
      assert_receive {:timer, 2_000, :start}, 2_000

      # A run of a minute or more starts over at 1 s.
      File.rm!(Path.join(dir, "pid"))
      send(relay, :start)
      assert wait_for_file(Path.join(dir, "pid"))
      Agent.update(clock, &(&1 + 60_000))
      kill(dir)
      assert_receive {:timer, 1_000, :start}, 2_000
      assert %{failures: 1, restarts: 2} = Relay.status(relay)
    end)
  end

  test "restart stops the running gh and starts a new one at once", %{dir: dir, spec: spec} do
    relay = start_relay(spec, executable: fake_gh(dir, "exec sleep 30"))
    assert wait_for_file(Path.join(dir, "pid"))
    first = dir |> Path.join("pid") |> File.read!() |> String.trim()

    File.rm!(Path.join(dir, "pid"))
    assert Relay.restart(relay) == :ok
    assert wait_for_file(Path.join(dir, "pid"))

    assert %{state: :running, restarts: 1} = Relay.status(relay)
    refute alive?(first)
    refute_received {:timer, _ms, _message}
  end

  test "stopping the relay stops its gh", %{dir: dir, spec: spec} do
    start_relay(spec, executable: fake_gh(dir, "exec sleep 30"))
    assert wait_for_file(Path.join(dir, "pid"))
    pid = dir |> Path.join("pid") |> File.read!() |> String.trim()

    stop_supervised!(Relay)
    refute alive?(pid)
  end

  test "reports a missing or unrunnable gh as its error", %{dir: dir, spec: spec} do
    capture_log(fn ->
      relay = start_relay(spec, executable: nil)
      assert_receive {:timer, 1_000, :start}
      assert %{state: :restarting, last_error: "The GitHub CLI (gh) isn't installed."} = Relay.status(relay)

      # Restarting by hand while it waits drops the wait.
      assert Relay.restart(relay) == :ok
      assert_receive {:timer, 2_000, :start}
      assert %{restarts: 1, failures: 2} = Relay.status(relay)
      stop_supervised!(Relay)

      not_executable = Path.join(dir, "gh")
      File.write!(not_executable, "")
      relay = start_relay(spec, executable: not_executable)
      assert_receive {:timer, 1_000, :start}
      assert %{last_error: "gh webhook forward didn't start: " <> _reason} = Relay.status(relay)
    end)
  end

  test "the wait doubles from 1 s and stops at 5 minutes" do
    assert Enum.map([1, 2, 3, 9, 10, 64], &Relay.backoff_ms/1) == [1_000, 2_000, 4_000, 256_000, 300_000, 300_000]
  end

  test "scrub replaces the secret, and leaves text alone when there is none", %{spec: spec} do
    assert Relay.scrub("bad #{@secret}!", spec) == "bad [secret]!"
    assert Relay.scrub("bad", %{spec | secret: nil}) == "bad"
  end

  defp kill(dir) do
    pid = dir |> Path.join("pid") |> File.read!() |> String.trim()
    System.cmd("kill", ["-9", pid])
  end

  defp alive?(pid) do
    Enum.all?(1..100, fn _attempt ->
      case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
        {_output, 0} -> Process.sleep(10) || true
        _gone -> false
      end
    end)
  end
end

defmodule SymphonyElixir.GitHub.RelayDefaultsTest do
  # Not async: it points `PATH` at a stand-in `gh` while it runs.
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.Relay
  alias SymphonyElixir.Secret

  test "finds gh on PATH and waits with its own timer" do
    dir = Path.join(System.tmp_dir!(), "relay-defaults-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "gh"), "#!/bin/sh\necho $$ >> \"#{dir}/runs\"\nexit 1\n")
    File.chmod!(Path.join(dir, "gh"), 0o755)
    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf(dir)
    end)

    System.put_env("PATH", dir)
    spec = %{repo_key: "app", repo: "acme/app", events: ["push"], url: "http://127.0.0.1:1/api/v1/github/webhook", secret: Secret.wrap("defaults-secret")}

    ExUnit.CaptureLog.capture_log(fn ->
      relay = start_supervised!({Relay, spec: spec})
      System.put_env("PATH", path)

      # Its own timer starts it again after 1 s.
      runs = fn -> dir |> Path.join("runs") |> File.read() |> elem(1) |> to_string() |> String.split("\n", trim: true) |> length() end
      assert Enum.find_value(1..300, fn _attempt -> if runs.() >= 2, do: true, else: Process.sleep(10) && nil end)
      assert %{restarts: restarts} = Relay.status(relay)
      assert restarts >= 1
    end)
  end
end
