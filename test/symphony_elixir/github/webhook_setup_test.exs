defmodule SymphonyElixir.GitHub.WebhookSetupTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.LineEditor
  alias SymphonyElixir.GitHub.{RelaySupervisor, WebhookSetup}
  alias SymphonyElixir.PrWatch.Health
  alias SymphonyElixir.Secret

  @t0 ~U[2026-10-17 09:00:00Z]
  @scopes "github.com\n  ✓ Logged in to github.com account octo (keyring)\n  - Token scopes: 'admin:repo_hook', 'gist', 'repo'\n"

  setup do
    # The test config writes every section inline; the app and the operator write blocks, which
    # is what the setup edits. `dashboard` holds only defaults here, so the port step adds it.
    file = Workflow.symphony_file_path()
    File.write!(file, file |> File.read!() |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "dashboard:")) |> Enum.join("\n"))
    Cache.clear()

    dir = Path.join(System.tmp_dir!(), "webhook-setup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # The relays' `gh`: it greets as gh does, records its pid and arguments, and fails while `fail` exists.
    gh_bin = Path.join(dir, "gh")

    File.write!(
      gh_bin,
      ~s(#!/bin/sh\necho "Forwarding Webhook events from GitHub..."\necho $$ > "#{dir}/pid"\nprintf '%s\\n' "$@" > "#{dir}/args"\nif [ -e "#{dir}/fail" ]; then echo "unable to connect to webhooks server, forwarding stopped"; exit 1; fi\nexec sleep 30\n)
    )

    File.chmod!(gh_bin, 0o755)

    test = self()
    relays = Module.concat(__MODULE__, "Relays#{System.unique_integer([:positive])}")
    timer = fn ms, message -> send(test, {:relay_timer, ms, message}) && make_ref() end
    # The relays' monotonic clock, in milliseconds.
    relay_clock = start_supervised!({Agent, fn -> 0 end}, id: :relay_clock)
    relay_opts = [executable: gh_bin, timer: timer, clock: fn -> Agent.get(relay_clock, & &1) end]
    start_supervised!({RelaySupervisor, name: relays, resume: nil, relay_opts: relay_opts})

    gh = start_supervised!({Agent, fn -> %{installed: false, overrides: %{}, hook_ids: [11, 12]} end}, id: :gh)
    secret = start_supervised!({Agent, fn -> nil end}, id: :secret)
    clock = start_supervised!({Agent, fn -> @t0 end}, id: :clock)
    configured = [%{key: "app", github: "acme/app"}, %{key: "lib", github: "acme/lib"}, %{key: "local", github: nil}]
    repos = start_supervised!({Agent, fn -> configured end}, id: :repos)
    port = start_supervised!({Agent, fn -> 4040 end}, id: :port)

    opts = [
      gh: fn args -> fake_gh(test, gh, args) end,
      hand_off: fn value ->
        send(test, {:handed_off, Secret.unwrap(value)})
        Agent.update(secret, fn _old -> value end)
      end,
      secret: fn -> Agent.get(secret, & &1) end,
      relays: relays,
      now: fn -> Agent.get(clock, & &1) end,
      repos: fn -> Agent.get(repos, & &1) end,
      port: fn -> Agent.get(port, & &1) end
    ]

    %{opts: opts, gh: gh, secret: secret, clock: clock, repos: repos, port: port, relays: relays, dir: dir}
    |> Map.put(:relay_clock, relay_clock)
  end

  ## The fake `gh`

  defp fake_gh(test, gh, args) do
    input = input_of(args)
    key = Enum.map(args, fn arg -> if arg == input_path(args), do: "-", else: arg end)
    send(test, {:gh, key, input && Jason.decode!(input)})

    state = Agent.get(gh, & &1)

    case Map.fetch(state.overrides, key) do
      {:ok, response} -> response
      :error -> default_gh(gh, without_hostname(key), state)
    end
  end

  defp without_hostname(["api", "--hostname", _host | rest]), do: ["api" | rest]
  defp without_hostname(args), do: args

  defp input_path(args) do
    case Enum.drop_while(args, &(&1 != "--input")) do
      ["--input", path | _rest] -> path
      _none -> nil
    end
  end

  defp input_of(args) do
    case input_path(args) do
      nil ->
        nil

      path ->
        assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
        File.read!(path)
    end
  end

  defp default_gh(_gh, ["auth", "status"], _state), do: {:ok, @scopes}
  defp default_gh(_gh, ["extension", "list"], %{installed: true}), do: {:ok, "gh webhook\tcli/gh-webhook\tv0.1.0\n"}
  defp default_gh(_gh, ["extension", "list"], _state), do: {:ok, ""}

  defp default_gh(gh, ["extension", "install", "cli/gh-webhook"], _state) do
    Agent.update(gh, &%{&1 | installed: true})
    {:ok, "✓ Installed extension cli/gh-webhook\n"}
  end

  defp default_gh(_gh, ["api", "repos/acme/lib", "--jq", ".permissions.admin"], _state), do: {:ok, "false\n"}
  defp default_gh(_gh, ["api", "repos/" <> _repo, "--jq", ".permissions.admin"], _state), do: {:ok, "true\n"}

  defp default_gh(gh, ["api", "repos/" <> path, "--method", "POST", "--input", "-"], _state) do
    true = String.ends_with?(path, "/hooks")
    id = Agent.get_and_update(gh, fn %{hook_ids: [id | rest]} = state -> {id, %{state | hook_ids: rest}} end)
    {:ok, Jason.encode!(%{id: id, name: "web"})}
  end

  defp default_gh(_gh, ["api", "repos/" <> _path | _rest], _state), do: {:ok, "{}"}

  defp gh_respond(gh, key, response), do: Agent.update(gh, &put_in(&1, [:overrides, key], response))

  defp gh_calls do
    receive do
      {:gh, args, input} -> [{args, input} | gh_calls()]
    after
      0 -> []
    end
  end

  ## Helpers

  defp act(action, params, opts) do
    assert {:ok, section} = WebhookSetup.action(action, params, opts)
    section
  end

  defp step(section, id), do: Enum.find(section.steps, &(&1.id == id))
  defp repo(section, key), do: Enum.find(section.repos, &(&1.key == key))
  defp yml, do: Workflow.symphony_file_path() |> File.read!()
  defp webhooks, do: YamlElixir.read_from_string!(yml()) |> get_in(["github", "webhooks"])
  defp at(clock, seconds), do: Agent.update(clock, fn _now -> DateTime.add(@t0, seconds) end)

  defp wait_for(path) do
    Enum.find_value(1..300, fn _attempt -> if File.exists?(path) and File.read!(path) != "", do: true, else: Process.sleep(10) && nil end)
  end

  defp relay_args(dir) do
    assert wait_for(Path.join(dir, "args"))
    dir |> Path.join("args") |> File.read!() |> String.split("\n", trim: true)
  end

  # Waits for the relay started last to pass `secret`: a `gh` the action stopped may write its own
  # arguments just before it is killed, after the test removed the file.
  defp assert_relay_secret(dir, secret) do
    assert Enum.find_value(1..300, fn _attempt -> relay_secret(dir) == secret || (Process.sleep(10) && nil) end),
           "no relay started with the expected secret; the last one passed #{inspect(relay_secret(dir))}"
  end

  defp relay_secret(dir) do
    case File.read(Path.join(dir, "args")) do
      {:ok, args} -> args |> String.split("\n", trim: true) |> List.last()
      {:error, _reason} -> nil
    end
  end

  # Sets up instant updates through `gh webhook forward` for `app` (on) and `lib` (no admin).
  defp set_up_forwarding(%{opts: opts, dir: dir}) do
    act("turn_on", %{"relay" => "gh_webhook_forward"}, opts)

    for step <- ["relay", "gh_ready", "secret", "port", "repo:app", "repo:lib", "repo:local"] do
      act("run_step", %{"step" => step}, opts)
    end

    relay_args(dir)
    act("test", %{}, opts)
  end

  ## Mode off

  test "with webhooks off, every configured repository is on polling and nothing is set up", %{opts: opts} do
    section = WebhookSetup.section(opts)

    assert section.mode == "off"
    assert section.enabled == false
    assert Enum.map(section.repos, &{&1.key, &1.connection}) == [{"app", "polling"}, {"lib", "polling"}, {"local", "polling"}]
    assert Enum.map(section.steps, & &1.id) == ~w(relay gh_ready secret port repo:app repo:lib repo:local test:app test:lib test:local)
    assert %{status: "pending"} = step(section, "relay")
    assert %{status: "failed", detail: "Symphony has no webhook secret on this Mac.", fix: "Run the secret step: " <> _} = step(section, "secret")
    assert %{status: "failed", fix: "Run this step: Symphony pins dashboard.port to 4040 in symphony.yml."} = step(section, "port")
    assert %{status: "pending"} = step(section, "test:app")
    assert section.relay == %{kind: "smee", label: "smee.io", runs_in_symphony: false, url: nil, payload_url: nil, local_url: "http://127.0.0.1:4040/api/v1/github/webhook"}
    assert section.secret == %{present: false, item: "symphony-github-webhook", env: "SYMPHONY_GITHUB_WEBHOOK_SECRET"}
    assert section.poll == %{interval_ms: 30_000, fallback_interval_ms: 300_000, silence_alert_minutes: 10}
    assert section.rate_limit == nil

    assert {:error, {:conflict, "Instant GitHub updates are off. Turn them on first."}} = WebhookSetup.action("run_step", %{"step" => "relay"}, opts)
  end

  test "the state's section is the setup's, or nil when it can't be read", %{opts: opts} do
    assert WebhookSetup.state_section(opts) == WebhookSetup.section(opts)
    assert WebhookSetup.state_section(Keyword.put(opts, :settings, fn -> raise ArgumentError, "no config" end)) == nil
    assert WebhookSetup.state_section(Keyword.put(opts, :repos, fn -> exit(:noproc) end)) == nil
  end

  # Every `/api/v1/state` poll carries the section; each settings read parses the configuration
  # again, and each repositories read asks git for every repository's GitHub name.
  test "the section reads the settings, the repositories, the port and the secret once", %{opts: opts} do
    reads = start_supervised!({Agent, fn -> %{} end}, id: :reads)

    counted =
      for key <- [:settings, :repos, :port, :secret] do
        read = Keyword.get(opts, key, &Config.settings!/0)

        {key,
         fn ->
           Agent.update(reads, &Map.update(&1, key, 1, fn count -> count + 1 end))
           read.()
         end}
      end

    assert WebhookSetup.section(Keyword.merge(opts, counted)) == WebhookSetup.section(opts)
    assert Agent.get(reads, & &1) == %{settings: 1, repos: 1, port: 1, secret: 1}
  end

  ## J1–J3: turn on through gh webhook forward

  test "turn on, run each step, test: a repository without admin access fails alone and the mode is on", %{opts: opts, dir: dir, clock: clock} do
    section = act("turn_on", %{"relay" => "gh_webhook_forward"}, opts)

    assert section.mode == "setting_up"
    assert %{"enabled" => true, "relay" => "gh_webhook_forward"} = webhooks()
    assert %{status: "failed", detail: "The GitHub CLI's webhook extension isn't installed."} = step(section, "relay")
    assert %{status: "done"} = step(section, "gh_ready")
    # A repository whose step hasn't run is pending, not failed.
    assert %{status: "pending", fix: nil} = step(section, "repo:app")
    assert section.turned_on_at == @t0

    section = act("run_step", %{"step" => "relay"}, opts)
    assert %{status: "done", detail: "Through GitHub CLI forwarding"} = step(section, "relay")
    assert {["extension", "install", "cli/gh-webhook"], nil} in gh_calls()

    section = act("run_step", %{"step" => "secret"}, opts)
    assert_received {:handed_off, secret}
    assert %{status: "done"} = step(section, "secret")
    assert webhooks()["secret"] == "$SYMPHONY_GITHUB_WEBHOOK_SECRET"

    section = act("run_step", %{"step" => "port"}, opts)
    assert %{status: "done"} = step(section, "port")
    assert YamlElixir.read_from_string!(yml())["dashboard"]["port"] == 4040

    section = act("run_step", %{"step" => "repo:app"}, opts)
    assert %{status: "done"} = step(section, "repo:app")

    assert relay_args(dir) == [
             "webhook",
             "forward",
             "--repo",
             "acme/app",
             "--events",
             "check_suite,check_run,workflow_run,pull_request,push,release",
             "--url",
             "http://127.0.0.1:4040/api/v1/github/webhook",
             "--secret",
             secret
           ]

    section = act("run_step", %{"step" => "repo:lib"}, opts)
    assert %{status: "failed", detail: "You need admin access to acme/lib to add a webhook.", fix: "Ask an owner of acme/lib for admin access, or leave lib on polling."} = step(section, "repo:lib")
    assert %{status: "done"} = step(section, "repo:app")

    section = act("run_step", %{"step" => "repo:local"}, opts)
    assert %{status: "failed", detail: "Symphony can't tell which GitHub repository local is."} = step(section, "repo:local")

    assert section.mode == "setting_up"
    assert Enum.map(section.repos, &{&1.key, &1.connection}) == [{"app", "webhook"}, {"lib", "polling"}, {"local", "polling"}]

    File.rm!(Path.join(dir, "pid"))
    section = act("test", %{}, opts)
    assert %{status: "waiting", detail: "Waiting for the test delivery."} = step(section, "test:app")
    assert %{status: "pending"} = step(section, "test:lib")
    # The test starts the relay again, so GitHub pings the new forwarding hook.
    assert wait_for(Path.join(dir, "pid"))
    assert repo(section, "app").test == %{sent_at: @t0, verified_at: nil}

    at(clock, 12)
    assert WebhookSetup.delivered("https://github.com/acme/lib", opts) == :ok
    assert %{status: "waiting"} = step(WebhookSetup.section(opts), "test:app")
    assert WebhookSetup.delivered("https://github.com/Acme/App/", opts) == :ok

    section = WebhookSetup.section(opts)
    assert %{status: "done", detail: "received and verified"} = step(section, "test:app")
    assert section.mode == "on"
    assert %{relay: %{state: "running", stable: true}, relay_restarts: 1, hook: nil, degraded: false} = repo(section, "app")
    assert repo(section, "app").degraded_reason == nil
  end

  test "a relay that is killed starts again, and one that can't restart degrades the mode", %{opts: opts, dir: dir, relay_clock: relay_clock} = ctx do
    set_up_forwarding(ctx)
    WebhookSetup.delivered("https://github.com/acme/app", opts)
    assert WebhookSetup.section(opts).mode == "on"

    # Killed once: it restarts after 1 s and runs again.
    pid = dir |> Path.join("pid") |> File.read!() |> String.trim()
    File.rm!(Path.join(dir, "pid"))
    System.cmd("kill", ["-9", pid])
    assert_receive {:relay_timer, 1_000, :start}, 2_000
    [relay] = Registry.lookup(Module.concat(ctx.relays, Registry), "app") |> Enum.map(&elem(&1, 0))
    send(relay, :start)
    assert wait_for(Path.join(dir, "pid"))
    assert %{relay: %{state: "running"}} = repo(WebhookSetup.section(opts), "app")

    # Dropped again and failing to come back: degraded, and the step says why.
    File.write!(Path.join(dir, "fail"), "")
    pid = dir |> Path.join("pid") |> File.read!() |> String.trim()
    System.cmd("kill", ["-9", pid])
    assert_receive {:relay_timer, 2_000, :start}, 2_000
    send(relay, :start)
    assert_receive {:relay_timer, 4_000, :start}, 2_000

    section = WebhookSetup.section(opts)
    assert section.mode == "degraded"
    assert %{degraded: true, relay: %{state: "restarting", failures: 3}} = repo(section, "app")
    assert repo(section, "app").degraded_reason == "The relay can't start again: unable to connect to webhooks server, forwarding stopped"
    assert %{status: "failed", detail: "The relay for acme/app stopped: unable to connect to webhooks server, forwarding stopped"} = step(section, "repo:app")

    # Back, but it stopped more than twice in ten minutes: degraded until it runs ten minutes.
    File.rm!(Path.join(dir, "fail"))
    send(relay, :start)
    assert wait_for(Path.join(dir, "args"))
    assert Enum.find_value(1..300, fn _ -> match?(%{relay: %{state: "running"}}, repo(WebhookSetup.section(opts), "app")) || (Process.sleep(10) && nil) end)
    assert %{degraded: true, degraded_reason: "The relay stopped more than twice in ten minutes" <> _} = repo(WebhookSetup.section(opts), "app")

    Agent.update(relay_clock, &(&1 + 10 * 60_000))
    assert WebhookSetup.section(opts).mode == "on"
  end

  test "a change no delivery reported, then silence past the alert's minutes, degrades the mode", %{opts: opts, clock: clock} = ctx do
    set_up_forwarding(ctx)
    WebhookSetup.delivered("https://github.com/acme/app", opts)

    health = %{Health.new() | last_delivery_at: DateTime.add(@t0, 5), deliveries: 1}
    :ok = Health.save(RunStore, "app", health)
    assert WebhookSetup.section(opts).mode == "on"

    :ok = Health.save(RunStore, "app", Health.missed(health, "https://github.com/acme/app/pull/1", :ci, DateTime.add(@t0, 60)))
    at(clock, 5 * 60)
    assert WebhookSetup.section(opts).mode == "on"

    at(clock, 11 * 60)
    section = WebhookSetup.section(opts)
    assert section.mode == "degraded"
    assert %{degraded: true, silent: true, healthy: false, last_delivery_at: last, deliveries: 1} = repo(section, "app")
    assert repo(section, "app").degraded_reason == "No delivery for 10 minutes after a read found a change none reported."
    assert last == DateTime.add(@t0, 5)
  end

  test "a relay killed three times in ten minutes degrades its repository and keeps the normal poll until it runs ten minutes",
       %{opts: opts, dir: dir, relay_clock: relay_clock} = ctx do
    set_up_forwarding(ctx)
    WebhookSetup.delivered("https://github.com/acme/app", opts)
    :ok = Health.save(RunStore, "app", Health.delivered(Health.new(), @t0))

    section = WebhookSetup.section(opts)
    assert section.mode == "on"
    assert %{degraded: false, poll_interval_ms: fallback} = repo(section, "app")
    assert fallback == section.poll.fallback_interval_ms
    assert fallback != section.poll.interval_ms

    [relay] = Registry.lookup(Module.concat(ctx.relays, Registry), "app") |> Enum.map(&elem(&1, 0))

    for _kill <- 1..3 do
      assert wait_for(Path.join(dir, "pid"))
      pid = dir |> Path.join("pid") |> File.read!() |> String.trim()
      File.rm!(Path.join(dir, "pid"))
      System.cmd("kill", ["-9", pid])
      assert_receive {:relay_timer, _ms, :start}, 2_000
      send(relay, :start)
    end

    assert wait_for(Path.join(dir, "pid"))
    section = WebhookSetup.section(opts)
    assert section.mode == "degraded"
    assert %{degraded: true, relay: %{state: "running", stable: false, last_error: "gh webhook forward was killed by signal 9"}} = repo(section, "app")
    assert "The relay stopped more than twice in ten minutes (gh webhook forward was killed by signal 9)" <> _rest = repo(section, "app").degraded_reason
    assert repo(section, "app").poll_interval_ms == section.poll.interval_ms

    # Ten minutes up without a stop: steady again, at the safety-net pace.
    Agent.update(relay_clock, &(&1 + 10 * 60_000))
    section = WebhookSetup.section(opts)
    assert section.mode == "on"
    assert %{degraded: false, degraded_reason: nil, relay: %{stable: true}} = repo(section, "app")
    assert repo(section, "app").poll_interval_ms == fallback
  end

  test "a test that hears nothing in 30 seconds fails with what to check", %{opts: opts, clock: clock} = ctx do
    set_up_forwarding(ctx)

    at(clock, 31)
    section = WebhookSetup.section(opts)
    assert %{status: "failed", detail: "No test delivery reached Symphony within 30 seconds.", fix: "Check that the relay is running" <> _} = step(section, "test:app")
    assert section.mode == "setting_up"
  end

  test "restart and re-create the secret: the relays start again with the new secret", %{opts: opts, dir: dir} = ctx do
    set_up_forwarding(ctx)
    assert_received {:handed_off, first}

    File.rm!(Path.join(dir, "args"))
    act("restart_relay", %{"repo" => "app"}, opts)
    assert_relay_secret(dir, first)

    File.rm!(Path.join(dir, "args"))
    section = act("recreate_secret", %{}, opts)
    assert_received {:handed_off, second}
    assert second != first
    assert_relay_secret(dir, second)
    assert %{status: "done"} = step(section, "repo:app")
    assert webhooks()["secret"] == "$SYMPHONY_GITHUB_WEBHOOK_SECRET"

    assert {:error, {:not_found, ~s("lib" isn't a connected repository.)}} = WebhookSetup.action("restart_relay", %{"repo" => "lib"}, opts)
  end

  test "a test starts a relay that isn't running; a restart without the secret or the port says so", %{opts: opts, relays: relays, secret: secret, port: port, dir: dir} = ctx do
    set_up_forwarding(ctx)
    RelaySupervisor.stop_all(relays)
    File.rm!(Path.join(dir, "args"))

    section = act("test", %{"repo" => "app"}, opts)
    assert %{status: "waiting"} = step(section, "test:app")
    assert relay_args(dir) |> Enum.take(4) == ["webhook", "forward", "--repo", "acme/app"]

    Agent.update(port, fn _port -> nil end)
    assert %{status: "failed", detail: "Symphony's port changes each time it starts" <> _} = step(act("restart_relay", %{}, opts), "repo:app")

    # The failed restart left app unconnected; its step connects it again.
    Agent.update(port, fn _port -> 4040 end)
    assert %{status: "done"} = step(act("run_step", %{"step" => "repo:app"}, opts), "repo:app")
    Agent.update(secret, fn _secret -> nil end)
    assert %{status: "failed", detail: "Symphony has no webhook secret on this Mac."} = step(act("restart_relay", %{}, opts), "repo:app")
  end

  test "turn off stops the relays and leaves polling, the secret and the done steps", %{opts: opts, relays: relays} = ctx do
    set_up_forwarding(ctx)
    assert RelaySupervisor.repo_keys(relays) == ["app"]

    section = act("turn_off", %{}, opts)

    assert section.mode == "off"
    assert webhooks()["enabled"] == false
    assert RelaySupervisor.repo_keys(relays) == []
    assert Enum.all?(section.repos, &(&1.connection == "polling"))
    assert section.secret.present
    assert %{status: "done"} = step(section, "relay")
    assert %{status: "pending"} = step(section, "repo:app")
    assert section.turned_on_at == nil
  end

  test "leave on polling stops a connected repository's relay and forgets its steps, so the setup finishes without it",
       %{opts: opts, relays: relays} = ctx do
    set_up_forwarding(ctx)
    section = WebhookSetup.section(opts)
    assert %{status: "waiting"} = step(section, "test:app")
    assert %{status: "failed"} = step(section, "repo:lib")
    assert RelaySupervisor.repo_keys(relays) == ["app"]

    # lib never connected: its failed step goes, and the mode still needs app's test.
    section = act("leave_on_polling", %{"repo" => "lib"}, opts)
    assert %{status: "pending", detail: nil, fix: nil, action: nil} = step(section, "repo:lib")
    assert section.mode == "setting_up"

    # app connected but its test never came: back on polling, with nothing left to finish.
    section = act("leave_on_polling", %{"repo" => "app"}, opts)
    assert RelaySupervisor.repo_keys(relays) == []
    assert %{status: "pending"} = step(section, "repo:app")
    assert %{status: "pending"} = step(section, "test:app")
    assert repo(section, "app").connection == "polling"
    assert repo(section, "app").test == nil
    assert section.mode == "setting_up"

    assert {:error, {:unprocessable, "Name the repository in repo."}} = WebhookSetup.action("leave_on_polling", %{}, opts)
    assert {:error, {:not_found, ~s(There is no repository named "nope".)}} = WebhookSetup.action("leave_on_polling", %{"repo" => "nope"}, opts)
    act("turn_off", %{}, opts)
    assert {:error, {:conflict, "Instant GitHub updates are off. Turn them on first."}} = WebhookSetup.action("leave_on_polling", %{"repo" => "app"}, opts)
  end

  ## URL relays

  test "leave on polling deletes the hook Symphony created, and keeps one GitHub wouldn't delete", %{opts: opts, gh: gh} do
    act("turn_on", %{"relay" => "smee", "url" => "https://smee.io/AbC"}, opts)
    for step <- ["secret", "port", "repo:app"], do: act("run_step", %{"step" => step}, opts)
    gh_calls()

    gh_respond(gh, ["api", "repos/acme/app/hooks/11", "--method", "DELETE"], {:error, {:gh_failed, [], 1, "HTTP 502"}})
    section = act("leave_on_polling", %{"repo" => "app"}, opts)
    assert [{["api", "repos/acme/app/hooks/11", "--method", "DELETE"], nil}] = gh_calls()
    # Turning off tries it again.
    assert repo(section, "app").hook == %{id: 11, created_by_symphony: true}
    assert repo(section, "app").connection == "polling"

    gh_respond(gh, ["api", "repos/acme/app/hooks/11", "--method", "DELETE"], {:ok, ""})
    section = act("leave_on_polling", %{"repo" => "app"}, opts)
    assert repo(section, "app").hook == nil

    # Nothing left to delete.
    act("leave_on_polling", %{"repo" => "app"}, opts)
    assert gh_calls() == [{["api", "repos/acme/app/hooks/11", "--method", "DELETE"], nil}]
  end

  test "a URL relay registers a hook per repository, pings it, and turn off deletes only the hooks Symphony created", %{opts: opts} do
    section = act("turn_on", %{"relay" => "smee", "url" => "https://smee.io/AbC/"}, opts)
    assert %{status: "done", detail: "Through smee.io"} = step(section, "relay")
    assert %{kind: "smee", url: "https://smee.io/AbC", payload_url: "https://smee.io/AbC", runs_in_symphony: false} = section.relay
    assert %{status: "pending"} = step(section, "repo:app")

    act("run_step", %{"step" => "secret"}, opts)
    assert_received {:handed_off, secret}
    act("run_step", %{"step" => "port"}, opts)
    gh_calls()

    section = act("run_step", %{"step" => "repo:app"}, opts)
    assert %{status: "done"} = step(section, "repo:app")
    assert repo(section, "app").hook == %{id: 11, created_by_symphony: true}

    assert [
             {["api", "repos/acme/app", "--jq", ".permissions.admin"], nil},
             {["api", "repos/acme/app/hooks", "--method", "POST", "--input", "-"], body}
           ] = gh_calls()

    assert body == %{
             "name" => "web",
             "active" => true,
             "events" => ["check_suite", "check_run", "workflow_run", "pull_request", "push", "release"],
             "config" => %{"url" => "https://smee.io/AbC", "content_type" => "json", "insecure_ssl" => "0", "secret" => secret}
           }

    # A hook that is there already is kept.
    act("run_step", %{"step" => "repo:app"}, opts)
    assert [{["api", "repos/acme/app", "--jq", ".permissions.admin"], nil}, {["api", "repos/acme/app/hooks/11"], nil}] = gh_calls()

    act("test", %{}, opts)
    assert [{["api", "repos/acme/app/hooks/11/pings", "--method", "POST"], nil}] = gh_calls()
    WebhookSetup.delivered("https://github.com/acme/app", opts)
    assert WebhookSetup.section(opts).mode == "on"

    assert {:error, {:conflict, "Symphony doesn't run the smee.io relay; restart it where it runs."}} = WebhookSetup.action("restart_relay", %{}, opts)

    section = act("recreate_secret", %{}, opts)
    assert_received {:handed_off, new_secret}
    assert [{["api", "repos/acme/app/hooks/11", "--method", "PATCH", "--input", "-"], patch}] = gh_calls()
    # GitHub replaces the whole config, so the hook keeps its URL.
    assert patch == %{"config" => %{"url" => "https://smee.io/AbC", "content_type" => "json", "insecure_ssl" => "0", "secret" => new_secret}}
    assert %{status: "done"} = step(section, "repo:app")

    section = act("turn_off", %{}, opts)
    assert section.mode == "off"
    assert [{["api", "repos/acme/app/hooks/11", "--method", "DELETE"], nil}] = gh_calls()
    assert repo(section, "app").hook == nil
  end

  test "a tunnel's public host gets Symphony's webhook path, and a hook that is gone is reported", %{opts: opts, gh: gh} do
    section = act("turn_on", %{"relay" => "cloudflare_tunnel", "url" => "https://hooks.example.com"}, opts)
    assert section.relay.payload_url == "https://hooks.example.com/api/v1/github/webhook"
    act("run_step", %{"step" => "secret"}, opts)
    act("run_step", %{"step" => "repo:app"}, opts)
    assert gh_calls() |> List.last() |> elem(1) |> get_in(["config", "url"]) == "https://hooks.example.com/api/v1/github/webhook"

    gh_respond(gh, ["api", "repos/acme/app/hooks/11"], {:error, {:gh_failed, [], 1, "gh: Not Found (HTTP 404)"}})
    assert WebhookSetup.check("repo:app", opts) == {:error, %{detail: "The webhook Symphony added to acme/app is gone.", fix: "Run the webhook step for app again: Symphony adds a new one."}}

    section = act("run_step", %{"step" => "repo:app"}, opts)
    assert repo(section, "app").hook.id == 12

    # A tunnel URL that already ends in the path is used as it is.
    section = act("change_relay", %{"relay" => "tailscale_funnel", "url" => "https://mac.tail.ts.net/api/v1/github/webhook"}, opts)
    assert %{kind: "tailscale_funnel", payload_url: "https://mac.tail.ts.net/api/v1/github/webhook"} = section.relay
  end

  test "change relay deletes Symphony's hooks, clears the repository steps and keeps the rest", %{opts: opts, gh: gh} do
    act("turn_on", %{"relay" => "smee", "url" => "https://smee.io/a"}, opts)
    act("run_step", %{"step" => "secret"}, opts)
    act("run_step", %{"step" => "repo:app"}, opts)
    gh_calls()

    # A hook GitHub won't delete stays listed, so turning off tries it again.
    gh_respond(gh, ["api", "repos/acme/app/hooks/11", "--method", "DELETE"], {:error, {:gh_failed, [], 1, "gh: Server Error (HTTP 500)"}})

    log = capture_log(fn -> act("change_relay", %{"relay" => "gh_webhook_forward"}, opts) end)
    assert log =~ "Instant GitHub updates couldn't delete hook=11 github=acme/app: gh: Server Error (HTTP 500)"

    section = WebhookSetup.section(opts)
    assert webhooks()["relay"] == "gh_webhook_forward"
    assert repo(section, "app").hook == %{id: 11, created_by_symphony: true}
    assert %{status: "pending"} = step(section, "repo:app")
    assert %{status: "done"} = step(section, "secret")
    assert section.relay.url == nil

    gh_respond(gh, ["api", "repos/acme/app/hooks/11", "--method", "DELETE"], {:error, {:timeout, 5_000}})
    capture_log(fn -> act("turn_off", %{}, opts) end)
    assert repo(WebhookSetup.section(opts), "app").hook != nil

    gh_respond(gh, ["api", "repos/acme/app/hooks/11", "--method", "DELETE"], {:error, {:gh_failed, [], 1, "gh: Not Found (HTTP 404)"}})
    assert repo(act("turn_off", %{}, opts), "app").hook == nil
  end

  test "turning on through another relay removes what the old one connected", %{opts: opts} do
    act("turn_on", %{"relay" => "smee", "url" => "https://smee.io/a"}, opts)
    act("run_step", %{"step" => "secret"}, opts)
    act("run_step", %{"step" => "repo:app"}, opts)
    gh_calls()

    # The same relay again keeps everything.
    act("turn_on", %{"relay" => "smee"}, opts)
    refute Enum.any?(gh_calls(), fn {args, _input} -> "DELETE" in args end)

    section = act("turn_on", %{"relay" => "gh_webhook_forward"}, opts)
    assert {["api", "repos/acme/app/hooks/11", "--method", "DELETE"], nil} in gh_calls()
    assert repo(section, "app").hook == nil
    # The old relay's done step goes back to pending until the new relay connects it.
    assert %{status: "pending", checked_at: nil} = step(section, "repo:app")
    assert %{status: "done"} = step(section, "secret")
  end

  test "an action whose symphony.yml edit fails leaves the hooks, the relays and the record as they were", %{opts: opts, dir: dir} = ctx do
    act("turn_on", %{"relay" => "smee", "url" => "https://smee.io/a"}, opts)
    act("run_step", %{"step" => "secret"}, opts)
    act("run_step", %{"step" => "repo:app"}, opts)
    gh_calls()
    before = WebhookSetup.section(opts)

    unwritable = Keyword.put(opts, :symphony_file, Path.join(dir, "missing.yml"))

    for {action, params} <- [{"turn_off", %{}}, {"change_relay", %{"relay" => "gh_webhook_forward"}}, {"turn_on", %{"relay" => "gh_webhook_forward"}}] do
      assert {:error, {:config, "Symphony couldn't change symphony.yml" <> _}} = WebhookSetup.action(action, params, unwritable)
    end

    refute Enum.any?(gh_calls(), fn {args, _input} -> "DELETE" in args end)
    assert %{"enabled" => true, "relay" => "smee"} = webhooks()
    assert WebhookSetup.section(opts) == before
    assert repo(before, "app").hook == %{id: 11, created_by_symphony: true}

    # A relay Symphony runs keeps running too.
    set_up_forwarding(ctx)
    assert {:error, {:config, _message}} = WebhookSetup.action("turn_off", %{}, unwritable)
    assert RelaySupervisor.repo_keys(ctx.relays) == ["app"]
  end

  test "a delivery waits while a setup action changes the record, then keeps both changes", %{opts: opts} do
    act("turn_on", %{"relay" => "smee", "url" => "https://smee.io/a"}, opts)
    act("run_step", %{"step" => "secret"}, opts)
    act("run_step", %{"step" => "port"}, opts)
    act("run_step", %{"step" => "repo:app"}, opts)
    act("test", %{}, opts)

    # Another process holds the record's lock, as a setup action does while it stores a result.
    test = self()

    holder =
      spawn_link(fn ->
        :global.set_lock({WebhookSetup, self()}, [node()])
        send(test, :locked)
        receive do: (:release -> :global.del_lock({WebhookSetup, self()}, [node()]))
        send(test, :released)
      end)

    assert_receive :locked
    delivery = Task.async(fn -> WebhookSetup.delivered("https://github.com/acme/app", opts) end)
    assert Task.yield(delivery, 100) == nil

    send(holder, :release)
    assert_receive :released
    assert Task.await(delivery) == :ok

    section = WebhookSetup.section(opts)
    assert section.mode == "on"
    assert repo(section, "app").hook == %{id: 11, created_by_symphony: true}
  end

  ## J6: a symphony.yml brought from another Mac

  test "on with no setup on this Mac needs setup, with the steps already done shown done", %{opts: opts, secret: secret} do
    File.write!(Workflow.symphony_file_path(), yml() <> "github:\n  webhooks:\n    enabled: true\n    relay: gh_webhook_forward\n    secret: $SYMPHONY_GITHUB_WEBHOOK_SECRET\n")
    Cache.clear()

    section = WebhookSetup.section(opts)
    assert section.mode == "needs_setup"
    assert %{status: "failed"} = step(section, "secret")

    Agent.update(secret, fn _none -> Secret.wrap("kept") end)
    File.write!(Workflow.symphony_file_path(), yml() <> "dashboard:\n  port: 4040\n")
    Cache.clear()

    section = WebhookSetup.section(opts)
    assert section.mode == "needs_setup"
    assert %{status: "done"} = step(section, "secret")
    assert %{status: "done"} = step(section, "port")
    assert %{runs_in_symphony: true, url: nil} = section.relay

    assert act("turn_on", %{}, opts).mode == "setting_up"
  end

  test "at start, the relays of the connected repositories run again", %{opts: opts, relays: relays} = ctx do
    set_up_forwarding(ctx)
    RelaySupervisor.stop_all(relays)

    assert WebhookSetup.resume(opts) == :ok
    assert RelaySupervisor.repo_keys(relays) == ["app"]

    # Nothing starts while updates are off, or when the configuration can't be read.
    act("turn_off", %{}, opts)
    assert WebhookSetup.resume(opts) == :ok
    assert RelaySupervisor.repo_keys(relays) == []

    log = capture_log(fn -> assert WebhookSetup.resume(Keyword.put(opts, :settings, fn -> raise ArgumentError, "bad symphony.yml" end)) == :ok end)
    assert log =~ "Instant GitHub updates didn't resume their relays: bad symphony.yml"
  end

  ## Step failures

  test "gh_ready: signed out, no gh, no webhook scope, or a token gh can't list scopes for", %{opts: opts, gh: gh} do
    gh_respond(gh, ["auth", "status"], {:error, {:gh_failed, ["auth", "status"], 1, "You are not logged into any GitHub hosts."}})
    assert {:error, %{detail: "The GitHub CLI isn't signed in.", fix: "Run gh auth login in Terminal, then run this step again.", action: "sign_in"}} = WebhookSetup.check("gh_ready", opts)

    gh_respond(gh, ["auth", "status"], {:error, {:gh_unavailable, "enoent"}})
    assert {:error, %{detail: "The GitHub CLI (gh) isn't installed."}} = WebhookSetup.run("gh_ready", %{}, opts)

    gh_respond(gh, ["auth", "status"], {:ok, "  - Token scopes: 'gist', 'read:org'\n"})

    assert {:error, %{detail: "The GitHub CLI is signed in, but can't add webhooks" <> _, fix: "Run gh auth refresh -h github.com -s admin:repo_hook in Terminal" <> _, action: "grant_permission"}} =
             WebhookSetup.check("gh_ready", opts)

    # The section names the app's button for it, and a step the app can't help with names none.
    act("turn_on", %{}, opts)
    assert %{status: "failed", action: "grant_permission"} = step(act("run_step", %{"step" => "gh_ready"}, opts), "gh_ready")
    assert %{status: "failed", action: nil} = step(WebhookSetup.section(opts), "relay")

    gh_respond(gh, ["auth", "status"], {:ok, "  ✓ Logged in to github.com using token (GH_TOKEN)\n"})
    assert WebhookSetup.check("gh_ready", opts) == :ok
  end

  test "relay: extensions that can't be listed or installed, and a URL relay without its URL", %{opts: opts, gh: gh} do
    write_relay("gh_webhook_forward")
    gh_respond(gh, ["extension", "list"], {:error, {:gh_failed, ["extension", "list"], 1, "boom\nnetwork down"}})
    assert {:error, %{detail: "Symphony couldn't list the GitHub CLI's extensions (network down).", fix: "Run gh extension list in Terminal" <> _}} = WebhookSetup.check("relay", opts)

    gh_respond(gh, ["extension", "list"], {:error, {:gh_unavailable, "enoent"}})
    gh_respond(gh, ["extension", "install", "cli/gh-webhook"], {:error, {:gh_unavailable, "enoent"}})

    assert {:error, %{detail: "The GitHub CLI couldn't install its webhook extension (the GitHub CLI isn't installed).", fix: "Run gh extension install cli/gh-webhook in Terminal."}} =
             WebhookSetup.run("relay", %{}, opts)

    gh_respond(gh, ["extension", "list"], {:ok, "gh webhook\tcli/gh-webhook\n"})
    assert WebhookSetup.run("relay", %{}, opts) == :ok

    write_relay("cloudflare_tunnel")
    assert {:error, %{detail: "Symphony needs the public URL of your Cloudflare Tunnel relay.", fix: "Run this step with the relay's https URL."}} = WebhookSetup.run("relay", %{}, opts)
    assert {:error, %{detail: ~s(The Cloudflare Tunnel URL must be an https:// address, got "http://x.example.com".)}} = WebhookSetup.run("relay", %{"url" => "http://x.example.com"}, opts)
    assert {:error, %{detail: ~s(The Cloudflare Tunnel URL must be an https:// address, got "42".)}} = WebhookSetup.run("relay", %{"url" => 42}, opts)
    assert WebhookSetup.run("relay", %{"url" => "https://x.example.com"}, opts) == :ok
    assert WebhookSetup.check("relay", opts) == :ok
  end

  test "secret: a hand-off that fails, and a symphony.yml that can't be edited", %{opts: opts} do
    failing = Keyword.put(opts, :hand_off, fn _secret -> {:error, :eacces} end)

    assert {:error, %{detail: "Symphony couldn't save the webhook secret (permission denied).", fix: "Check that Symphony's state folder can be written" <> _}} =
             WebhookSetup.run("secret", %{}, failing)

    File.write!(Workflow.symphony_file_path(), yml() <> "github: {\"enterprise_hosts\": []}\n")
    Cache.clear()

    assert {:error,
            %{detail: "Symphony couldn't change symphony.yml (github: in symphony.yml is an inline value, not an indented block).", fix: "Edit github.webhooks.secret in symphony.yml by hand."}} =
             WebhookSetup.run("secret", %{}, opts)

    assert {:error, {:config, "Symphony couldn't change symphony.yml (github: in symphony.yml is an inline value" <> _}} = WebhookSetup.action("turn_on", %{}, opts)
  end

  test "port: no port to pin yet, or one that moved since it was pinned", %{opts: opts, port: port} do
    Agent.update(port, fn _port -> nil end)
    assert {:error, %{detail: "Symphony's web server isn't listening yet" <> _, fix: "Start Symphony, then run this step again."}} = WebhookSetup.run("port", %{}, opts)
    assert {:error, %{fix: "Start Symphony, then run this step again."}} = WebhookSetup.check("port", opts)

    Agent.update(port, fn _port -> 4040 end)
    assert WebhookSetup.run("port", %{}, opts) == :ok
    Agent.update(port, fn _port -> 5050 end)

    assert {:error, %{detail: "symphony.yml pins dashboard.port to 4040, but Symphony listens on another port.", fix: "Restart Symphony so it listens on 4040.", action: "restart_symphony"}} =
             WebhookSetup.check("port", opts)
  end

  test "repo: no secret or port yet, a hook GitHub refuses or doesn't name, and unknown repositories", %{opts: opts, secret: secret, port: port, gh: gh} do
    write_relay("gh_webhook_forward")
    assert {:error, %{detail: "There is no webhook secret yet.", fix: "Run the secret step first."}} = WebhookSetup.run("repo:app", %{}, opts)

    Agent.update(secret, fn _none -> Secret.wrap("a-test-secret-long-enough") end)
    Agent.update(port, fn _port -> nil end)
    assert {:error, %{detail: "Symphony's port changes each time it starts" <> _}} = WebhookSetup.run("repo:app", %{}, opts)

    gh_respond(gh, ["api", "repos/acme/app", "--jq", ".permissions.admin"], {:error, {:gh_failed, [], 1, "gh: Not Found (HTTP 404)"}})
    Agent.update(port, fn _port -> 4040 end)
    assert {:error, %{detail: "You need admin access to acme/app to add a webhook."}} = WebhookSetup.run("repo:app", %{}, opts)

    write_relay("smee")
    gh_respond(gh, ["api", "repos/acme/app", "--jq", ".permissions.admin"], {:ok, "true"})
    assert {:error, %{detail: "Symphony needs the public URL of your smee.io relay."}} = WebhookSetup.run("repo:app", %{}, opts)

    assert WebhookSetup.run("relay", %{"url" => "https://smee.io/x"}, opts) == :ok
    gh_respond(gh, ["api", "repos/acme/app/hooks", "--method", "POST", "--input", "-"], {:error, {:gh_failed, [], 1, "gh: Validation Failed (HTTP 422)"}})
    assert {:error, %{detail: "GitHub refused the webhook on acme/app (gh: Validation Failed (HTTP 422)).", fix: "Check your admin access to acme/app" <> _}} = WebhookSetup.run("repo:app", %{}, opts)

    gh_respond(gh, ["api", "repos/acme/app/hooks", "--method", "POST", "--input", "-"], {:ok, "not json"})
    assert {:error, %{detail: "GitHub didn't say which hook it created on acme/app."}} = WebhookSetup.run("repo:app", %{}, opts)

    assert {:error, %{detail: "There is no repository named nope."}} = WebhookSetup.check("repo:nope", opts)
    assert {:error, %{detail: "There is no setup step named \"nope\"."}} = WebhookSetup.run("nope", %{}, opts)
    assert {:error, %{detail: "acme/app isn't connected yet."}} = WebhookSetup.run("test:app", %{}, opts)
    assert {:error, %{detail: "Symphony hasn't sent a test delivery yet."}} = WebhookSetup.check("test:app", opts)
    assert {:error, %{detail: "acme/app isn't connected yet."}} = WebhookSetup.check("repo:app", opts)
  end

  test "repo with gh webhook forward: a relay still starting, one already forwarded by someone else, or one that can't start", %{opts: opts, secret: secret, dir: dir} = ctx do
    Agent.update(secret, fn _none -> Secret.wrap("a-test-secret-long-enough") end)
    write_relay("gh_webhook_forward")

    File.write!(Path.join(dir, "gh"), "#!/bin/sh\necho 'error: Hook already exists on this repository'\nexit 1\n")

    capture_log(fn ->
      assert {:error, failure} = WebhookSetup.run("repo:app", %{}, opts) |> retry_until_error(opts)
      assert failure.detail == "Someone is already forwarding acme/app's webhooks: GitHub lets one person forward a repository at a time."
    end)

    stopped = Keyword.put(opts, :relays, Module.concat(ctx.relays, Missing))
    assert {:error, %{detail: "Symphony couldn't start the relay for acme/app.", fix: "Restart Symphony, then run this step again."}} = WebhookSetup.run("repo:app", %{}, stopped)
  end

  test "test: GitHub refuses the ping, or the hook is no longer listed", %{opts: opts, gh: gh} do
    act("turn_on", %{"relay" => "smee", "url" => "https://smee.io/a"}, opts)
    act("run_step", %{"step" => "secret"}, opts)
    act("run_step", %{"step" => "repo:app"}, opts)

    gh_respond(gh, ["api", "repos/acme/app/hooks/11/pings", "--method", "POST"], {:error, {:gh_failed, [], 1, ""}})
    section = act("test", %{"repo" => "app"}, opts)
    assert %{status: "failed", detail: "GitHub didn't send the test delivery to acme/app (gh exited with 1).", fix: "Run the webhook step for app, then send another test."} = step(section, "test:app")
    assert repo(section, "app").test == nil

    act("turn_off", %{}, opts)
    act("turn_on", %{"relay" => "smee"}, opts)
    assert {:error, %{detail: "acme/app isn't connected yet."}} = WebhookSetup.run("test:app", %{}, opts)
  end

  ## Actions and params

  test "names what's wrong with an action or its params", %{opts: opts} do
    assert {:error, {:not_found, ~s(There is no GitHub updates action named "explode".)}} = WebhookSetup.action("explode", %{}, opts)
    assert {:error, {:unprocessable, "relay must be one of gh_webhook_forward, smee, cloudflare_tunnel, tailscale_funnel."}} = WebhookSetup.action("turn_on", %{"relay" => "ngrok"}, opts)
    assert {:error, {:unprocessable, "The smee.io URL must be an https:// address" <> _}} = WebhookSetup.action("turn_on", %{"relay" => "smee", "url" => "ftp://x"}, opts)

    act("turn_on", %{"url" => "https://ignored.example.com"}, opts)
    assert WebhookSetup.section(opts).relay.url == nil
    assert {:error, {:unprocessable, "Name the step to run in step."}} = WebhookSetup.action("run_step", %{}, opts)
    assert {:error, {:not_found, ~s(There is no setup step named "repo:nope".)}} = WebhookSetup.action("run_step", %{"step" => "repo:nope"}, opts)
    assert {:error, {:conflict, "No repository is connected yet: run the webhook steps first."}} = WebhookSetup.action("test", %{}, opts)
    assert {:error, {:unprocessable, _message}} = WebhookSetup.action("change_relay", %{"relay" => "x"}, opts)

    assert {:error, {:conflict, "Symphony couldn't save the webhook secret (permission denied)."}} =
             WebhookSetup.action("recreate_secret", %{}, Keyword.put(opts, :hand_off, fn _secret -> {:error, :eacces} end))

    assert WebhookSetup.actions() == ~w(turn_on run_step test leave_on_polling restart_relay recreate_secret change_relay turn_off)
    assert hd(WebhookSetup.relays()) == "gh_webhook_forward"
  end

  test "a delivery without a repository, or with no test running, changes nothing", %{opts: opts} do
    assert WebhookSetup.delivered(nil, opts) == :ok
    assert WebhookSetup.delivered("https://github.com/acme/app", opts) == :ok
    assert WebhookSetup.section(opts).repos |> Enum.all?(&(&1.test == nil))
  end

  test "running the secret step again keeps the secret already set", %{opts: opts} do
    act("turn_on", %{"relay" => "gh_webhook_forward"}, opts)
    act("run_step", %{"step" => "secret"}, opts)
    assert_received {:handed_off, _first}

    section = act("run_step", %{"step" => "secret"}, opts)
    refute_received {:handed_off, _second}
    assert %{status: "done"} = step(section, "secret")
    assert webhooks()["secret"] == "$SYMPHONY_GITHUB_WEBHOOK_SECRET"
  end

  test "a delivery whose record can't be read is logged and still answered :ok", %{opts: opts} do
    defmodule FailingStore do
      def get_github_updates(_key), do: raise("store down")
    end

    defmodule ExitingStore do
      def get_github_updates(_key), do: exit(:noproc)
    end

    log =
      capture_log(fn ->
        assert WebhookSetup.delivered("https://github.com/acme/app", Keyword.put(opts, :run_store, FailingStore)) == :ok
        assert WebhookSetup.delivered("https://github.com/acme/app", Keyword.put(opts, :run_store, ExitingStore)) == :ok
      end)

    assert log =~ "couldn't record a test delivery: store down"
    assert log =~ "couldn't record a test delivery: ** (exit) no process"
  end

  test "the secret never appears in symphony.yml, the section or the logs", %{opts: opts} = ctx do
    log =
      capture_log(fn ->
        set_up_forwarding(ctx)
        act("recreate_secret", %{}, opts)
        WebhookSetup.delivered("https://github.com/acme/app", opts)
        send(self(), {:section, Jason.encode!(%{github_updates: WebhookSetup.section(opts)})})
        act("turn_off", %{}, opts)
      end)

    assert_received {:handed_off, first}
    assert_received {:handed_off, second}
    assert_received {:section, json}

    for secret <- [first, second] do
      refute yml() =~ secret
      refute json =~ secret
      refute log =~ secret
    end
  end

  test "a GitHub Enterprise repository is called on its host", %{opts: opts, repos: repos} do
    Agent.update(repos, fn _repos -> [%{key: "ent", github: "ghe.acme.dev/acme/ent"}] end)
    act("turn_on", %{"relay" => "smee", "url" => "https://smee.io/e"}, opts)
    act("run_step", %{"step" => "secret"}, opts)
    gh_calls()

    act("run_step", %{"step" => "repo:ent"}, opts)

    assert [
             {["api", "--hostname", "ghe.acme.dev", "repos/acme/ent", "--jq", ".permissions.admin"], nil},
             {["api", "--hostname", "ghe.acme.dev", "repos/acme/ent/hooks", "--method", "POST", "--input", "-"], _body}
           ] = gh_calls()

    act("test", %{}, opts)
    WebhookSetup.delivered("https://ghe.acme.dev/acme/ent", opts)
    assert %{status: "done"} = step(WebhookSetup.section(opts), "test:ent")
  end

  defmodule DownStore do
    def get_github_updates(_key), do: nil
    def put_github_updates(_key, _value), do: {:error, :down}
    def list_ticket_states(_repo_key), do: []
  end

  test "a run store that can't keep the record is logged, and the section still answers", %{opts: opts} do
    log = capture_log(fn -> assert {:ok, %{mode: "needs_setup"}} = WebhookSetup.action("turn_on", %{}, Keyword.put(opts, :run_store, DownStore)) end)
    assert log =~ "Instant GitHub updates couldn't keep their setup record: :down"
  end

  test "the default collaborators read the configuration, the run store and the HTTP server" do
    section = WebhookSetup.section()
    assert section.mode == "off"
    assert [%{key: "default"}] = section.repos

    runner = fn ["auth", "status"], _opts -> {"  - Token scopes: 'repo'\n", 0} end
    assert WebhookSetup.check("gh_ready", gh_runner: runner) == :ok
  end

  defp write_relay(relay) do
    :ok = LineEditor.write(Workflow.symphony_file_path(), [{["github", "webhooks", "enabled"], "true"}, {["github", "webhooks", "relay"], relay}])
    Cache.clear()
  end

  # A relay that exits at once may still run when the step returns; a later check sees its error.
  defp retry_until_error(:ok, opts) do
    Enum.find_value(1..300, fn _attempt ->
      case WebhookSetup.check("repo:app", opts) do
        {:error, _failure} = error -> error
        _starting -> Process.sleep(10) && nil
      end
    end)
  end

  defp retry_until_error(result, _opts), do: result
end
