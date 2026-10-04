defmodule SymphonyElixirWeb.ObservabilityReposTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.Paths
  alias SymphonyElixir.Repo.FetchLog
  alias SymphonyElixir.Repo.Supervisor, as: RepoSupervisor

  @endpoint SymphonyElixirWeb.Endpoint
  @token "ghp_" <> String.duplicate("a1B2", 9)
  @git_env [
    {"GIT_AUTHOR_NAME", "Symphony Test"},
    {"GIT_AUTHOR_EMAIL", "symphony@example.com"},
    {"GIT_COMMITTER_NAME", "Symphony Test"},
    {"GIT_COMMITTER_EMAIL", "symphony@example.com"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"}
  ]

  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, opts) do
      if delay = Keyword.get(opts, :delay_ms), do: Process.sleep(delay)
      {:reply, Keyword.fetch!(opts, :snapshot), opts}
    end
  end

  setup do
    original_state_root = Application.get_env(:symphony_elixir, :state_root_override)
    root = Path.join(System.tmp_dir!(), "symphony-repos-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Paths.set_state_root(Path.join(root, "state"))
    Enum.each(["repos-app", "repos-web", "repos-docs"], &:ets.delete(FetchLog, &1))

    on_exit(fn ->
      if original_state_root,
        do: Application.put_env(:symphony_elixir, :state_root_override, original_state_root),
        else: Application.delete_env(:symphony_elixir, :state_root_override)

      File.rm_rf(root)
    end)

    app = Path.join(root, "app")
    git!(root, ["init", "-q", "-b", "main", app])
    git!(app, ["remote", "add", "origin", "https://x-access-token:#{@token}@github.com/acme/app.git"])
    File.write!(Path.join(app, "WORKFLOW.md"), "App prompt\n")

    docs = Path.join(root, "docs")
    File.mkdir_p!(docs)
    File.write!(Path.join(docs, "WORKFLOW.md"), "---\nfoo: [\n---\nDocs prompt\n")

    write_symphony!(root, app, docs)

    {:ok, root: root, app: app, docs: docs, clone: Path.join([root, "clones", "acme", "web"])}
  end

  test "lists every configured repo with its source, routing, workflow, last fetch and worktrees", %{
    root: root,
    app: app,
    docs: docs,
    clone: clone
  } do
    fetched_at = ~U[2026-10-04 12:00:00Z]

    FetchLog.record(
      "repos-app",
      {:error, {:git_failed, app, ["fetch", "origin"], 128}, "fatal: unable to access 'https://x-access-token:#{@token}@github.com/acme/app.git/' (token #{@token})\n"},
      fetched_at
    )

    FetchLog.record("repos-web", :ok, fetched_at)

    running = [
      %{repo_key: "repos-app", issue_id: "issue-1", identifier: "TP-1", workspace_path: "/ws/repos-app/TP-1", worker_host: nil},
      %{repo_key: nil, issue_id: "issue-3", identifier: "TP-3", workspace_path: "/ws/repos-app/TP-3", worker_host: "worker-1"},
      %{repo_key: "repos-web", issue_id: "issue-2", identifier: "TP-2", workspace_path: "/ws/repos-web/TP-2"},
      %{repo_key: "elsewhere", issue_id: "issue-4", identifier: "TP-4", workspace_path: "/ws/elsewhere/TP-4"}
    ]

    start_endpoint!(snapshot: %{running: running})

    conn = get(build_conn(), "/api/v1/repos")
    body = response(conn, 200)
    payload = Jason.decode!(body)

    refute body =~ @token
    refute Map.has_key?(payload, "error")
    assert [app_repo, web_repo, docs_repo] = payload["repos"]

    assert app_repo == %{
             "key" => "repos-app",
             "default" => true,
             "base_branch" => "main",
             "source" => %{"kind" => "local", "path" => app},
             "github" => "acme/app",
             "routing" => %{"team" => "ENG", "projects" => ["app-platform"], "labels" => ["frontend"], "assignee" => "me"},
             "workflow" => %{"path" => Path.join(app, "WORKFLOW.md"), "found" => true, "status" => "valid", "error" => nil},
             "last_fetch" => %{
               "at" => "2026-10-04T12:00:00Z",
               "result" => "error",
               "error" => "git fetch origin exited with status 128: fatal: unable to access 'https://[REDACTED]@github.com/acme/app.git/' (token [REDACTED:github_token])"
             },
             "worktrees" => [
               %{"issue_id" => "issue-1", "issue_identifier" => "TP-1", "path" => "/ws/repos-app/TP-1", "worker_host" => nil},
               %{"issue_id" => "issue-3", "issue_identifier" => "TP-3", "path" => "/ws/repos-app/TP-3", "worker_host" => "worker-1"}
             ]
           }

    clone_workflow = Path.join(clone, "WORKFLOW.md")

    assert web_repo == %{
             "key" => "repos-web",
             "default" => false,
             "base_branch" => nil,
             "source" => %{"kind" => "managed", "github" => "acme/web", "clone_path" => clone, "cloned" => false},
             "github" => "acme/web",
             "routing" => %{"team" => nil, "projects" => ["web"], "labels" => [], "assignee" => nil},
             "workflow" => %{
               "path" => clone_workflow,
               "found" => false,
               "status" => "missing",
               "error" => "Missing WORKFLOW.md at #{clone_workflow}: :enoent"
             },
             "last_fetch" => %{"at" => "2026-10-04T12:00:00Z", "result" => "ok", "error" => nil},
             "worktrees" => [%{"issue_id" => "issue-2", "issue_identifier" => "TP-2", "path" => "/ws/repos-web/TP-2", "worker_host" => nil}]
           }

    assert %{
             "key" => "repos-docs",
             "source" => %{"kind" => "local", "path" => ^docs},
             "github" => nil,
             "workflow" => %{"found" => true, "status" => "invalid", "error" => "Failed to parse WORKFLOW.md: " <> _message},
             "last_fetch" => nil,
             "worktrees" => []
           } = docs_repo

    # Once Symphony has its clone, the repo reports it and reads its workflow from it.
    git!(root, ["init", "-q", "-b", "main", clone])
    File.write!(clone_workflow, "Web prompt\n")

    assert %{"repos" => [_app, %{"source" => %{"cloned" => true}, "workflow" => %{"status" => "valid"}}, _docs]} =
             json_response(get(build_conn(), "/api/v1/repos"), 200)
  end

  test "reads a running repo's workflow status from its store", %{docs: docs} do
    {:ok, repo} = Config.repo("repos-docs")
    start_supervised!({RepoSupervisor, repo})
    start_endpoint!(snapshot: %{running: []})

    capture_log(fn ->
      assert %{"repos" => [_app, _web, %{"workflow" => %{"status" => "invalid", "found" => true}}]} =
               json_response(get(build_conn(), "/api/v1/repos"), 200)
    end)

    File.write!(Path.join(docs, "WORKFLOW.md"), "Docs prompt\n")

    assert %{"repos" => [_app, _web, %{"workflow" => %{"status" => "valid", "error" => nil}}]} =
             json_response(get(build_conn(), "/api/v1/repos"), 200)
  end

  test "reports fetch errors of every shape without secrets" do
    FetchLog.record("repos-app", {:error, {:managed_clone_failed, "repos-app", {:fetch, {:git_failed, 128, "fatal: #{@token}"}}}})
    FetchLog.record("repos-web", {:error, {:git_failed, ["fetch", "origin"], 1, "fatal: no remote\n"}})
    FetchLog.record("repos-docs", {:error, {:timeout, @token}})
    start_endpoint!(snapshot: %{running: []})

    body = response(get(build_conn(), "/api/v1/repos"), 200)
    refute body =~ @token

    assert %{"repos" => [app, web, docs]} = Jason.decode!(body)
    assert app["last_fetch"]["error"] == "git fetch exited with status 128: fatal: [REDACTED:github_token]"
    assert web["last_fetch"]["error"] == "git fetch origin exited with status 1: fatal: no remote"
    assert docs["last_fetch"]["error"] == ~s({:timeout, "[REDACTED:github_token]"})
  end

  test "still lists the repos when the snapshot is unavailable or times out" do
    start_endpoint!(orchestrator: Module.concat(__MODULE__, :MissingOrchestrator))

    assert %{"repos" => [%{"worktrees" => []}, _web, _docs], "error" => %{"code" => "snapshot_unavailable"}} =
             json_response(get(build_conn(), "/api/v1/repos"), 200)

    stop_supervised!(SymphonyElixirWeb.Endpoint)
    start_endpoint!(snapshot: %{running: []}, delay_ms: 200, snapshot_timeout_ms: 10)

    assert %{"repos" => [_app, _web, _docs], "error" => %{"code" => "snapshot_timeout"}} =
             json_response(get(build_conn(), "/api/v1/repos"), 200)
  end

  test "answers 503 when the config does not load and 405 to other methods", %{root: root} do
    start_endpoint!(snapshot: %{running: []})

    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(post(build_conn(), "/api/v1/repos", %{}), 405)

    File.write!(Path.join(root, "symphony.yml"), "repositories: []\n")
    Cache.clear()

    assert %{"error" => %{"code" => "config_unavailable", "message" => "Invalid symphony.yml config: " <> _message}} =
             json_response(get(build_conn(), "/api/v1/repos"), 503)
  end

  defp start_endpoint!(opts) do
    orchestrator =
      case Keyword.fetch(opts, :orchestrator) do
        {:ok, name} ->
          name

        :error ->
          name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
          start_supervised!({SnapshotOrchestrator, name: name, snapshot: Keyword.fetch!(opts, :snapshot), delay_ms: opts[:delay_ms]})
          name
      end

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator,
        snapshot_timeout_ms: Keyword.get(opts, :snapshot_timeout_ms, 1_000)
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp write_symphony!(root, app, docs) do
    path = Path.join(root, "symphony.yml")

    File.write!(path, """
    issues:
      provider: memory
    repositories:
      - key: repos-app
        workflow: #{Path.join(app, "WORKFLOW.md")}
        workflow_source: local
        default: true
        base_branch: main
        route:
          team: ENG
          projects: [app-platform]
          labels: [frontend]
          assignee: me
        workspace:
          strategy: worktree
          repo: #{app}
      - key: repos-web
        route:
          projects: [web]
        workspace:
          source: acme/web
      - key: repos-docs
        workflow: #{Path.join(docs, "WORKFLOW.md")}
        workflow_source: local
        route:
          projects: [docs]
    workspaces:
      root: #{Path.join(root, "workspaces")}
      clones_root: #{Path.join(root, "clones")}
    agent:
      runtime: codex
      command: codex app-server
    """)

    Workflow.set_symphony_file_path(path)
    Cache.clear()
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], env: @git_env, stderr_to_stdout: true)
    output
  end
end
