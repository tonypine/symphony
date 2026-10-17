defmodule SymphonyElixirWeb.SetupControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 3, json_response: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.GitHub.{RelaySupervisor, WebhookSetup}
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.Health
  alias SymphonyElixir.Secret

  @endpoint SymphonyElixirWeb.Endpoint
  @t0 ~U[2026-10-17 09:00:00Z]

  # The `github_updates` section's contract with the app: the app's decoding tests read this file too.
  @fixture Path.expand("../../fixtures/api/github_updates.json", __DIR__)

  setup do
    # The test config writes every section inline; the setup edits blocks (see WebhookSetupTest).
    file = Workflow.symphony_file_path()
    File.write!(file, file |> File.read!() |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "dashboard:")) |> Enum.join("\n"))
    Cache.clear()

    dir = Path.join(System.tmp_dir!(), "setup-controller-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    gh_bin = Path.join(dir, "gh")
    File.write!(gh_bin, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(gh_bin, 0o755)

    relays = Module.concat(__MODULE__, "Relays#{System.unique_integer([:positive])}")
    relay_opts = [executable: gh_bin, utc_now: fn -> @t0 end, timer: fn _ms, _message -> make_ref() end]
    start_supervised!({RelaySupervisor, name: relays, resume: nil, relay_opts: relay_opts})

    test = self()
    secret = start_supervised!({Agent, fn -> nil end}, id: :secret)

    opts = [
      gh: &fake_gh/1,
      hand_off: fn value ->
        send(test, {:handed_off, Secret.unwrap(value)})
        Agent.update(secret, fn _old -> value end)
      end,
      secret: fn -> Agent.get(secret, & &1) end,
      relays: relays,
      now: fn -> @t0 end,
      repos: fn -> [%{key: "app", github: "acme/app"}, %{key: "lib", github: "acme/lib"}] end,
      port: fn -> 4040 end
    ]

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), github_updates: opts)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.delete(endpoint_config, :github_updates)) end)
    :ok
  end

  defp fake_gh(["auth", "status"]), do: {:ok, "  - Token scopes: 'admin:repo_hook', 'repo'\n"}
  defp fake_gh(["extension", "list"]), do: {:ok, "gh webhook\tcli/gh-webhook\tv0.1.0\n"}
  defp fake_gh(["api", "repos/acme/lib", "--jq", ".permissions.admin"]), do: {:ok, "false\n"}
  defp fake_gh(["api", "repos/acme/app", "--jq", ".permissions.admin"]), do: {:ok, "true\n"}

  defp post_action(action, body, headers \\ [{"content-type", "application/json"}]) do
    Enum.reduce(headers, build_conn(), fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> post("/api/v1/setup/github_updates/#{action}", body)
  end

  defp section(conn, status \\ 200), do: json_response(conn, status)["github_updates"]

  # Turns updates on through gh webhook forward and connects `app`; `lib` lacks admin access.
  defp turn_on! do
    section(post_action("turn_on", ~s({"relay": "gh_webhook_forward"})))
    for step <- ~w(relay gh_ready secret port repo:app repo:lib), do: section(post_action("run_step", Jason.encode!(%{step: step})))
    section(post_action("test", "{}"))
  end

  test "GET /api/v1/setup has github_updates: off, every repository on polling" do
    section = build_conn() |> get("/api/v1/setup") |> section()

    assert section["mode"] == "off"
    assert Enum.map(section["repos"], &{&1["key"], &1["connection"]}) == [{"app", "polling"}, {"lib", "polling"}]
  end

  test "turn on through the API, step by step, then test: the repository verified is on, the one without admin fails alone" do
    section = turn_on!()

    steps = Map.new(section["steps"], &{&1["id"], &1})
    assert %{"status" => "done"} = steps["repo:app"]
    assert %{"status" => "failed", "detail" => "You need admin access to acme/lib to add a webhook.", "fix" => "Ask an owner of acme/lib" <> _} = steps["repo:lib"]
    assert %{"status" => "waiting"} = steps["test:app"]

    body = Jason.encode!(%{zen: "hi", hook_id: 1, repository: %{html_url: "https://github.com/acme/app"}})
    assert_received {:handed_off, secret}
    # What the app's launcher passes once it keeps the handed-off secret.
    previous = System.get_env("SYMPHONY_GITHUB_WEBHOOK_SECRET")
    System.put_env("SYMPHONY_GITHUB_WEBHOOK_SECRET", secret)
    on_exit(fn -> restore_env("SYMPHONY_GITHUB_WEBHOOK_SECRET", previous) end)
    signature = "sha256=" <> (:hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower))

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "ping")
      |> put_req_header("x-hub-signature-256", signature)
      |> post("/api/v1/github/webhook", body)

    # It verified: the PR watcher isn't running here, but the setup counted it first.
    assert %{"error" => %{"code" => "pr_watch_unavailable"}} = json_response(conn, 503)

    section = build_conn() |> get("/api/v1/setup") |> section()
    assert section["mode"] == "on"
    assert %{"status" => "done", "detail" => "received and verified"} = Enum.find(section["steps"], &(&1["id"] == "test:app"))

    section = section(post_action("turn_off", "{}"))
    assert section["mode"] == "off"
    assert Enum.all?(section["repos"], &(&1["connection"] == "polling"))
  end

  test "the github_updates section matches the contract the app decodes" do
    turn_on!()
    WebhookSetup.delivered("https://github.com/acme/app", Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)[:github_updates])

    :ok = Health.save(RunStore, "app", %{Health.new() | last_delivery_at: DateTime.add(@t0, 5), deliveries: 3, signature_failures: [DateTime.add(@t0, -60)]})

    watch = %{
      facts: Facts.new(phase: :code_review, pr: :open),
      pr_url: "https://github.com/acme/app/pull/1",
      read_at: @t0,
      rate_limit: %{remaining: 4321, limit: 5000, reset_at: ~U[2026-10-17 10:00:00Z]}
    }

    :ok = RunStore.put_ticket_pr_watch("default", "issue-1", "TP-1", watch)

    section = build_conn() |> get("/api/v1/setup") |> json_response(200)

    if System.get_env("SYMPHONY_WRITE_FIXTURES") == "1", do: File.write!(@fixture, Jason.encode_to_iodata!(section, pretty: true))
    assert section == @fixture |> File.read!() |> Jason.decode!()
  end

  test "takes curl's JSON sent as a form, as the walkthrough does" do
    section = section(post_action("turn_on", ~s({"relay":"gh_webhook_forward"}), [{"content-type", "application/x-www-form-urlencoded"}]))
    assert section["mode"] == "setting_up"
    assert section["relay"]["kind"] == "gh_webhook_forward"

    section = section(post_action("run_step", "step=port", [{"content-type", "application/x-www-form-urlencoded"}]))
    assert %{"status" => "done"} = Enum.find(section["steps"], &(&1["id"] == "port"))

    assert %{"error" => %{"code" => "invalid_params"}} = post_action("run_step", "nope", [{"content-type", "application/x-www-form-urlencoded"}]) |> json_response(422)
  end

  test "names a wrong action, wrong params, a conflict, and a symphony.yml it can't edit" do
    assert %{"error" => %{"code" => "not_found"}} = post_action("explode", "{}") |> json_response(404)
    assert %{"error" => %{"code" => "invalid_params"}} = post_action("turn_on", ~s({"relay": "ngrok"})) |> json_response(422)
    assert %{"error" => %{"code" => "conflict", "message" => "Instant GitHub updates are off. Turn them on first."}} = post_action("run_step", ~s({"step": "relay"})) |> json_response(409)

    File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "github: {}\n")
    Cache.clear()
    assert %{"error" => %{"code" => "config_not_written"}} = post_action("turn_on", "{}") |> json_response(422)
  end

  test "answers 503 while the configuration can't be read" do
    File.write!(Workflow.symphony_file_path(), "repositories: [\n")
    Cache.clear()

    assert %{"error" => %{"code" => "config_unavailable"}} = build_conn() |> get("/api/v1/setup") |> json_response(503)
    # Turning off still stops what runs, and says the file needs a hand.
    assert %{"error" => %{"code" => "config_not_written", "message" => "Symphony couldn't change symphony.yml (it doesn't parse as YAML)." <> _}} =
             post_action("turn_off", "{}") |> json_response(422)

    File.write!(Workflow.symphony_file_path(), "repositories: []\n")
    Cache.clear()
    assert %{"error" => %{"code" => "config_unavailable"}} = post_action("run_step", "{}") |> json_response(503)
  end

  test "refuses another site's page, and other methods" do
    conn = post_action("turn_off", "{}", [{"content-type", "application/json"}, {"origin", "https://evil.example.com"}])
    assert conn.status == 403

    assert build_conn() |> put_req_header("content-type", "application/json") |> post("/api/v1/setup", "{}") |> json_response(405)
  end

  test "the secret never appears in an answer, symphony.yml or the log" do
    log =
      capture_log(fn ->
        send(self(), {:answer, Jason.encode!(turn_on!())})
        send(self(), {:answer, post_action("recreate_secret", "{}").resp_body})
        send(self(), {:answer, build_conn() |> get("/api/v1/setup") |> Map.fetch!(:resp_body)})
      end)

    assert_received {:handed_off, first}
    assert_received {:handed_off, second}
    answers = for _answer <- 1..3, do: assert_received({:answer, answer}) && answer

    for secret <- [first, second], text <- [log, File.read!(Workflow.symphony_file_path()) | answers] do
      refute text =~ secret
    end
  end
end
