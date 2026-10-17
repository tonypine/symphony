defmodule SymphonyElixirWeb.ObservabilityWatchCheckTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.PrWatch.Repo
  alias SymphonyElixir.{PrWatchSupport, RunStore}

  @endpoint SymphonyElixirWeb.Endpoint
  @repo_key "default"

  # Stands in for a repo's PR watcher: a tick runs the test's function.
  defmodule Watcher do
    use GenServer

    def start_link(tick), do: GenServer.start_link(__MODULE__, tick, name: Repo.name("default"))

    @impl true
    def init(tick), do: {:ok, tick}

    @impl true
    def handle_call(:poll, _from, tick), do: {:reply, tick.(), tick}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", pr_review_mode: "polling")

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok
  end

  defp check(conn \\ build_conn(), identifier), do: post(conn, "/api/v1/issues/#{identifier}/watch/check")

  # A tick that decides the ticket waits on CI.
  defp decide_wait do
    PrWatchSupport.put_watch!(@repo_key, "issue-1",
      identifier: "TP-1",
      phase: :rework,
      decision: %{
        rule: "R23",
        kind: :wait,
        reason: "The `specs` check is red on the base branch too",
        owner: :ci,
        clears_when: "the base branch's `specs` check goes green",
        decided_at: ~U[2026-10-16 12:00:00Z]
      }
    )

    {:ok, %{watched: 1, errors: 0, rate_limited: nil, next_tick_ms: 30_000}}
  end

  test "Check Now reads and decides within the request and returns the new watch block" do
    PrWatchSupport.put_watch!(@repo_key, "issue-1", identifier: "TP-1", phase: :rework, decision: :dispatch)
    start_supervised!({Watcher, &decide_wait/0})

    assert %{"issue_identifier" => "TP-1", "issue_id" => "issue-1", "repo_key" => @repo_key, "watch" => watch} = json_response(check("TP-1"), 200)

    assert %{
             "phase" => "rework",
             "rule" => "R23",
             "action" => "wait",
             "reason" => "The `specs` check is red on the base branch too",
             "owner" => "ci",
             "clears_when" => "the base branch's `specs` check goes green"
           } = watch
  end

  test "Check Now on a silent Rework ticket the watcher sends a run names who acts next and what clears it" do
    PrWatchSupport.put_watch!(@repo_key, "issue-1", identifier: "TP-1", phase: :rework, decision: :dispatch)

    start_supervised!(
      {Watcher,
       fn ->
         PrWatchSupport.put_watch!(@repo_key, "issue-1", identifier: "TP-1", phase: :rework, decision: :dispatch)
         {:ok, %{watched: 1, errors: 0, rate_limited: nil, next_tick_ms: 30_000}}
       end}
    )

    assert %{"watch" => %{"action" => "dispatch", "rule" => rule, "reason" => reason} = watch} = json_response(check("TP-1"), 200)
    assert is_binary(rule) and is_binary(reason)
    assert %{"owner" => "symphony", "clears_when" => "a run starts on the ticket"} = watch
  end

  test "Check Now names a ticket the watcher doesn't watch, a watcher that isn't running, and a tick that failed" do
    assert %{"error" => %{"code" => "issue_not_watched"}} = json_response(check("TP-404"), 404)

    PrWatchSupport.put_watch!(@repo_key, "issue-1", identifier: "TP-1")
    assert %{"error" => %{"code" => "watcher_not_running"}} = json_response(check("TP-1"), 503)

    start_supervised!({Watcher, fn -> {:error, :unauthorized} end})
    assert %{"error" => %{"code" => "watch_check_failed", "message" => "The PR watcher could not read: :unauthorized"}} = json_response(check("TP-1"), 502)
    assert %{} = RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "Check Now is refused to a browser on another origin, and only answers POST" do
    conn = build_conn() |> put_req_header("origin", "https://evil.example") |> check("TP-1")
    assert %{"error" => %{"code" => "forbidden_origin"}} = json_response(conn, 403)

    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(get(build_conn(), "/api/v1/issues/TP-1/watch/check"), 405)
  end
end
