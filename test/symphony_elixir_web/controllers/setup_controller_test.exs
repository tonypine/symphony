defmodule SymphonyElixirWeb.SetupControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 3, json_response: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{BlockedHold, Setup, StateProvisioning}
  alias SymphonyElixir.GitHub.{RelaySupervisor, WebhookSetup}
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.Health
  alias SymphonyElixir.Repo.FetchLog
  alias SymphonyElixir.Routing.{PollLog, Resolver}
  alias SymphonyElixir.Secret

  @endpoint SymphonyElixirWeb.Endpoint
  @t0 ~U[2026-10-17 09:00:00Z]

  # The `github_updates` section's contract with the app: the app's decoding tests read this file too.
  @fixture Path.expand("../../fixtures/api/github_updates.json", __DIR__)
  # The setup problems' contract with the app, for its Setup screens.
  @problems_fixture Path.expand("../../fixtures/api/setup_problems.json", __DIR__)
  # The label problems and their Linear fixes, for the app's Setup confirm sheets.
  @labels_fixture Path.expand("../../fixtures/api/setup_label_problems.json", __DIR__)

  # Answers the snapshot `/api/v1/state` reads: nothing running.
  defmodule IdleOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    def init(nil), do: {:ok, nil}
    def handle_call(:snapshot, _from, state), do: {:reply, %{running: [], retrying: [], rate_limits: nil}, state}
  end

  setup do
    # The test config writes every section inline; the setup edits blocks (see WebhookSetupTest).
    file = Workflow.symphony_file_path()
    File.write!(file, file |> File.read!() |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "dashboard:")) |> Enum.join("\n"))
    Cache.clear()
    # Earlier tests may have left failed fetches of `default` in the shared fetch log, and polls in
    # the poll log: either would put a problem in a healthy payload.
    FetchLog.record("default", :ok)
    :ets.delete_all_objects(PollLog)
    # So may the labels an earlier test's orchestrator provisioned in the memory tracker: a team with
    # some labels is one the labels check judges.
    Application.delete_env(:symphony_elixir, :memory_tracker_labels_list)

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

    setup_server = Module.concat(__MODULE__, "Setup#{System.unique_integer([:positive])}")
    start_supervised!({Setup, name: setup_server, now: fn -> @t0 end})
    # Its startup run reads the config: let it finish before a test edits the file.
    Setup.refresh(setup_server)
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!({IdleOrchestrator, orchestrator})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        github_updates: opts,
        setup: setup_server,
        orchestrator: orchestrator,
        snapshot_timeout_ms: 1_000
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.drop(endpoint_config, [:github_updates, :setup, :orchestrator, :snapshot_timeout_ms]))
    end)

    :ok
  end

  defp refresh(headers \\ [{"content-type", "application/json"}]) do
    Enum.reduce(headers, build_conn(), fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> post("/api/v1/setup/refresh", "{}")
  end

  # Writes the repos into symphony.yml and records each one's poll, as the orchestrator's poll does.
  defp route_and_poll!(repos) do
    path = Workflow.symphony_file_path()
    repos = Enum.map(repos, &Map.put(&1, "workflow", Workflow.workflow_file_path()))
    File.write!(path, String.replace(File.read!(path), ~r/^repositories: .*$/m, "repositories: " <> Jason.encode!(repos)))
    Cache.clear()

    for repo <- Config.system!().repos, do: PollLog.record(repo, Tracker.fetch_candidate_issues_for_repo(repo))
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

    section = build_conn() |> get("/api/v1/setup") |> json_response(200) |> Map.take(["github_updates"])

    if System.get_env("SYMPHONY_WRITE_FIXTURES") == "1", do: File.write!(@fixture, Jason.encode_to_iodata!(section, pretty: true))
    assert section == @fixture |> File.read!() |> Jason.decode!()
  end

  describe "setup problems" do
    test "a healthy config has no problems and nothing unchecked, next to github_updates" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      assert %{"problems" => [], "not_checked" => [], "checked_at" => "2026-10-17T09:00:00Z", "linear_checked_at" => "2026-10-17T09:00:00Z"} =
               refresh() |> json_response(200)

      assert %{"problems" => [], "not_checked" => [], "github_updates" => %{"mode" => "off"}} = build_conn() |> get("/api/v1/setup") |> json_response(200)
    end

    test "a refresh checks the edited config again, and /api/v1/state carries the same payload" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      assert %{"problems" => []} = refresh() |> json_response(200)

      File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "auto_review:\n  enabled: true\n")
      Cache.clear()

      problems = refresh() |> json_response(200)
      if System.get_env("SYMPHONY_WRITE_FIXTURES") == "1", do: File.write!(@problems_fixture, Jason.encode_to_iodata!(problems, pretty: true))
      assert problems == @problems_fixture |> File.read!() |> Jason.decode!()

      assert %{"problems" => [%{"id" => "deprecated_key:auto_review.enabled", "severity" => "warning", "fix" => %{"kind" => "config_edit", "action" => "remove"}}]} =
               problems

      assert build_conn() |> get("/api/v1/setup") |> json_response(200) |> Map.delete("github_updates") == problems
      assert build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("setup") == problems
    end

    test "a slug route whose tickets carry only the project id is a routing error until its fix is applied" do
      # The `issues` team gives every repo its team, so only routing problems show.
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_team: "TP")
      project_id = "8e6f0c39-6a8b-4c1e-9d0e-1f2a3b4c5d6e"
      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, [%{id: project_id, name: "Symphony", slug_id: "a1abb875ac02"}])
      Application.put_env(:symphony_elixir, :memory_tracker_teams_list, [%{id: "team-tp", key: "TP", name: "Tony Pine"}])
      issues = for number <- 1..3, do: %Issue{id: "issue-#{number}", identifier: "TP-#{number}", state: "Todo", project: %{id: project_id}}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

      on_exit(fn ->
        :ets.delete_all_objects(PollLog)
        Enum.each([:memory_tracker_projects_list, :memory_tracker_teams_list], &Application.delete_env(:symphony_elixir, &1))
      end)

      symphony = %{"key" => "symphony", "route" => %{"projects" => ["a1abb875ac02"]}}
      route_and_poll!([symphony])

      assert %{"problems" => [problem]} = refresh() |> json_response(200)

      assert %{
               "id" => "routing:round_trip:symphony",
               "severity" => "error",
               "category" => "routing",
               "repos" => ["symphony"],
               "fix" => %{"kind" => "config_edit", "path" => "repositories[symphony].route.projects", "action" => "add", "value" => ^project_id}
             } = problem

      assert %{"label" => "Resolves", "value" => "0 of 3 come back to symphony"} in problem["details"]

      # The fix applied: the tickets route back, so holds and decisions find their repo.
      symphony = put_in(symphony, ["route", "projects"], ["a1abb875ac02", project_id])
      route_and_poll!([symphony])

      assert %{"problems" => []} = refresh() |> json_response(200)
      assert Enum.all?(issues, &(Resolver.with_repo_key(&1, Config.system!().repos).repo_key == "symphony"))

      # A second repo routed to the same project.
      route_and_poll!([symphony, %{"key" => "web", "route" => %{"projects" => [project_id]}}])

      assert %{"problems" => [%{"id" => "routing:overlap:symphony+web", "severity" => "error", "repos" => ["symphony", "web"], "fix" => %{"kind" => "open", "target" => "repos"}}]} =
               refresh() |> json_response(200)
    end

    test "an unset $VAR a notification channel names is a secrets error without a value until it is set" do
      previous = System.get_env("SLACK_URL")
      System.delete_env("SLACK_URL")
      on_exit(fn -> restore_env("SLACK_URL", previous) end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        notifications: %{enabled: true, channels: [%{kind: "slack", url: "$SLACK_URL", events: ["run_failed"]}]}
      )

      assert %{"problems" => [problem]} = refresh() |> json_response(200)

      assert %{
               "id" => "secret:notifications.channels[0].url",
               "severity" => "error",
               "category" => "secrets",
               "fix" => %{"kind" => "open", "target" => "settings"}
             } = problem

      assert %{"label" => "Key", "value" => "notifications.channels[0].url"} in problem["details"]
      assert %{"label" => "Variable", "value" => "SLACK_URL"} in problem["details"]

      System.put_env("SLACK_URL", "https://hooks.slack.test/services/T0/B0/sekret")
      refresh()
      conn = build_conn() |> get("/api/v1/setup")
      assert %{"problems" => []} = json_response(conn, 200)
      refute conn.resp_body =~ "sekret"
    end

    test "without a Linear API key the payload holds one secrets error for it" do
      previous = System.get_env("LINEAR_API_KEY")
      System.delete_env("LINEAR_API_KEY")
      on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)
      write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

      assert %{"problems" => [%{"id" => "secret:LINEAR_API_KEY", "severity" => "error", "title" => "Symphony can't read Linear: no ticket is picked up"}]} =
               refresh() |> json_response(200)
    end

    test "a refresh is refused from another site's page, and takes no other method" do
      assert refresh([{"content-type", "application/json"}, {"origin", "https://evil.example.com"}]).status == 403
      assert build_conn() |> get("/api/v1/setup/refresh") |> json_response(405)
    end
  end

  describe "label fixes" do
    setup do
      on_exit(fn ->
        for key <- [:memory_tracker_labels_list, :memory_tracker_create_label_result],
            do: Application.delete_env(:symphony_elixir, key)
      end)

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_team: "TP")
      wanted = for %{names: [name | _]} <- StateProvisioning.machine_labels("expedite", ["needs-human"]), name != "Needs Decision", do: name
      Application.put_env(:symphony_elixir, :memory_tracker_labels_list, Enum.map(wanted, &%{id: &1, name: &1, team_id: "id-TP", team_key: "TP"}))
      :ok
    end

    defp post_fix(body, headers \\ [{"content-type", "application/json"}]) do
      Enum.reduce(headers, build_conn(), fn {name, value}, conn -> put_req_header(conn, name, value) end)
      |> post("/api/v1/setup/fixes", body)
    end

    defp problem(payload, id), do: Enum.find(payload["problems"], &(&1["id"] == id))

    # A poll of the ticket, as the orchestrator's Blocked hold sweep runs it.
    defp poll!(issue) do
      capture_log(fn -> BlockedHold.sync(issue, ["Done"], settings: Config.settings!(), repo_key: "default", now: @t0) end)
    end

    defp ticket_labels, do: hd(Application.get_env(:symphony_elixir, :memory_tracker_issues)).labels

    # The user walkthrough: create the missing label, re-sync a drifted ticket, refuse what the check didn't propose.
    test "a missing label is created by its fix, a drifted ticket is re-synced, and an unproposed fix is refused" do
      # 1. Team TP has no `Needs Decision`: a label error with a create_label fix.
      refresh()
      missing = problem(build_conn() |> get("/api/v1/setup") |> json_response(200), "labels:missing:TP:Needs Decision")
      assert %{"severity" => "error", "fix" => %{"kind" => "linear", "action" => "create_label", "team" => "TP", "name" => "Needs Decision"} = fix} = missing

      # 2. Running it creates exactly that label in TP, and the error is gone.
      payload = post_fix(Jason.encode!(fix)) |> json_response(200)
      assert payload["problems"] == []
      assert %{name: "Needs Decision", team_id: "TP"} = List.last(Application.get_env(:symphony_elixir, :memory_tracker_labels_list))

      # 3. A Blocked label with no hold, which the polls fail to clear, for two checks: a drift
      # warning naming the ticket.
      issue = %Issue{id: "issue-1", identifier: "TP-7", url: "https://linear.app/t/issue/TP-7", state: "Todo", labels: ["Blocked"]}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      forbidden = {:error, :forbidden}
      Application.put_env(:symphony_elixir, :memory_tracker_remove_issue_label_result, [forbidden, forbidden])

      for _check <- 1..2 do
        poll!(issue)
        refresh()
      end

      payload = build_conn() |> get("/api/v1/setup") |> json_response(200)
      drift = problem(payload, "hold_drift:default")

      assert %{
               "severity" => "warning",
               "tickets" => [%{"identifier" => "TP-7", "url" => "https://linear.app/t/issue/TP-7"}],
               "details" => [%{"label" => "TP-7", "value" => "Blocked label with no hold, since 2026-10-17 09:00 UTC"}],
               "fix" => %{"kind" => "linear", "action" => "resync_hold", "repo" => "default", "tickets" => ["TP-7"]} = resync
             } = drift

      # The contract the app's Setup decodes for both Linear fixes.
      contract = %{"problems" => [missing | payload["problems"]]}
      if System.get_env("SYMPHONY_WRITE_FIXTURES") == "1", do: File.write!(@labels_fixture, Jason.encode_to_iodata!(contract, pretty: true))
      assert contract == @labels_fixture |> File.read!() |> Jason.decode!()

      # Its fix removes the label, and the warning clears.
      assert post_fix(Jason.encode!(%{fix: resync})) |> json_response(200) |> Map.fetch!("problems") == []
      assert ticket_labels() == []

      # 4. A descriptor the check didn't propose is refused.
      assert %{"error" => %{"code" => "fix_not_proposed"}} = post_fix(Jason.encode!(resync)) |> json_response(422)
      assert %{"error" => %{"code" => "fix_not_proposed"}} = post_fix(Jason.encode!(fix)) |> json_response(422)
    end

    test "a create Linear refuses answers its reason and leaves the problem in place" do
      refresh()
      taken = {:error, {:linear_graphql_errors, [%{"message" => "Label name already taken"}]}}
      Application.put_env(:symphony_elixir, :memory_tracker_create_label_result, taken)
      fix = %{kind: "linear", action: "create_label", team: "TP", name: "Needs Decision"}

      payload = post_fix(Jason.encode!(fix), [{"content-type", "application/x-www-form-urlencoded"}]) |> json_response(422)

      assert %{"code" => "fix_refused", "message" => message} = payload["error"]
      assert message =~ ~s(Linear refused to create the label "Needs Decision" in team TP: Label name already taken.)
      assert problem(payload, "labels:missing:TP:Needs Decision")
    end

    test "fixes are refused from another site's page, and take no other method" do
      assert post_fix("{}", [{"content-type", "application/json"}, {"origin", "https://evil.example.com"}]).status == 403
      assert build_conn() |> get("/api/v1/setup/fixes") |> json_response(405)
    end
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
