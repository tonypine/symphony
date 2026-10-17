defmodule SymphonyElixir.GitHub.RelaySupervisorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.RelaySupervisor
  alias SymphonyElixir.Secret

  setup do
    dir = Path.join(System.tmp_dir!(), "relay-supervisor-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    gh = Path.join(dir, "gh")
    File.write!(gh, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(gh, 0o755)

    name = Module.concat(__MODULE__, "Sup#{System.unique_integer([:positive])}")
    test = self()

    resume = fn -> send(test, :resumed) end
    start_supervised!({RelaySupervisor, name: name, relay_opts: [executable: gh], resume: resume})
    %{name: name}
  end

  defp spec(key), do: %{repo_key: key, repo: "acme/#{key}", events: ["push"], url: "http://127.0.0.1:1/api/v1/github/webhook", secret: Secret.wrap("s")}

  test "runs the resume function once it starts", %{name: _name} do
    assert_receive :resumed
  end

  test "keeps one relay per repository and answers for each", %{name: name} do
    assert RelaySupervisor.start(name, spec("app")) == :ok
    assert RelaySupervisor.start(name, spec("api")) == :ok
    first = RelaySupervisor.status(name, "app")

    # Starting a repository again replaces its relay.
    assert RelaySupervisor.start(name, spec("app")) == :ok
    assert RelaySupervisor.repo_keys(name) == ["api", "app"]
    assert %{state: :running, restarts: 0} = RelaySupervisor.status(name, "app")
    assert first.started_at != nil

    assert RelaySupervisor.restart(name, "app") == :ok
    assert %{restarts: 1} = RelaySupervisor.status(name, "app")

    # A relay that doesn't answer reads as none, rather than holding up the caller.
    [{pid, _value}] = Registry.lookup(Module.concat(name, Registry), "api")
    :sys.suspend(pid)
    assert RelaySupervisor.status(name, "api", 10) == nil
    :sys.resume(pid)

    assert RelaySupervisor.stop(name, "api") == :ok
    assert RelaySupervisor.status(name, "api") == nil
    assert RelaySupervisor.restart(name, "api") == {:error, :not_running}

    assert RelaySupervisor.stop_all(name) == :ok
    assert RelaySupervisor.repo_keys(name) == []
  end

  test "answers as if no relay runs while it isn't running" do
    missing = Module.concat(__MODULE__, Missing)

    assert RelaySupervisor.start(missing, spec("app")) == {:error, :not_running}
    assert RelaySupervisor.stop(missing, "app") == :ok
    assert RelaySupervisor.status(missing, "app") == nil
    assert RelaySupervisor.repo_keys(missing) == []
    assert RelaySupervisor.restart(missing, "app") == {:error, :not_running}
  end

  test "starts without a resume function" do
    name = Module.concat(__MODULE__, "Plain#{System.unique_integer([:positive])}")
    start_supervised!({RelaySupervisor, name: name, resume: nil}, id: :plain)
    assert RelaySupervisor.repo_keys(name) == []
  end
end
