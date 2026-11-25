defmodule SymphonyElixirWeb.HomeReadTest do
  # The Home read through the API: the orchestrator walks two queued tickets, one depending on the
  # other, behind a ticket in progress; the read is the tree, carries an ETag and answers 304 while
  # nothing changed. Who waits on whom is the dependencies Symphony stores; Linear's blocker links are
  # not read.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 2, json_response: 2, response: 2]
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  alias SymphonyElixir.Views
  alias SymphonyElixirWeb.Presenter

  @endpoint SymphonyElixirWeb.Endpoint
  @repo "default"

  # Answers with the snapshot a test gives it, after `delay_ms` when it has one.
  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, {:unavailable, 0}}

    @impl true
    def handle_call(:snapshot, _from, {snapshot, delay_ms} = state) do
      Process.sleep(delay_ms)
      {:reply, snapshot, state}
    end

    def handle_call({:put, snapshot, delay_ms}, _from, _state), do: {:reply, :ok, {snapshot, delay_ms}}
  end

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Done", "Canceled"],
      max_concurrent_agents: 1
    )

    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: SnapshotOrchestrator, start: {SnapshotOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    %{orchestrator: orchestrator}
  end

  test "the read is the queue's tree behind the ticket in progress, and an unchanged read answers 304", %{orchestrator: orchestrator} do
    working = ticket("w", "MT-W", "In Progress")
    first = ticket("a", "MT-A", "Todo")
    second = ticket("b", "MT-B", "Todo")
    _backlog = ticket("k", "MT-K", "Backlog")
    :ok = RunStore.add_dependency("a", "w", :done)
    :ok = RunStore.add_dependency("b", "a", :done)
    issues = [working, first, second]

    state = Orchestrator.put_dispatch_order_for_test(orchestrator_state(), issues)
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    :ok = GenServer.call(orchestrator, {:put, snapshot, 0})

    conn = get(build_conn(), "/api/v1/home")
    read = json_response(conn, 200)
    [etag] = get_resp_header(conn, "etag")

    assert [%{"kind" => "ticket", "identifier" => "MT-W", "working" => false, "situation" => %{"kind" => _kind}}] = read["in_progress"]

    assert %{"roots" => [%{"identifier" => "MT-A", "after" => "MT-W", "children" => [%{"identifier" => "MT-B", "also_waits_on" => [], "children" => []}]}]} =
             read["queue"]

    assert read["outside"] == %{"backlog" => 1, "below_priority" => 0, "epic" => 0, "behind" => 0}
    refute Map.has_key?(read, "error")

    again = build_conn() |> put_req_header("if-none-match", etag) |> get("/api/v1/home")
    assert response(again, 304) == ""
    assert get_resp_header(again, "etag") == [etag]

    assert %{"error" => %{"code" => "method_not_allowed"}} = build_conn() |> post("/api/v1/home") |> json_response(405)
  end

  test "an epic's sub-tickets wait on one another by their stored dependencies, of both kinds, in the dispatch order and Home, read in the same shape",
       %{orchestrator: orchestrator} do
    previous = Application.fetch_env(:symphony_elixir, :build)
    # A build from a checkout: a released dependency on a done ticket is met.
    Application.put_env(:symphony_elixir, :build, sha: nil, repo: nil, number: nil)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :build, value)
        :error -> Application.delete_env(:symphony_elixir, :build)
      end
    end)

    parent = %{identifier: "MT-E", title: "Checkout"}
    _epic = ticket("e", "MT-E", "Waiting on sub-tickets", labels: ["plan"])
    _landed = ticket("s1", "MT-S1", "Done", parent: parent)
    _working = ticket("s2", "MT-S2", "In Progress", parent: parent)
    next = ticket("s3", "MT-S3", "Todo", parent: parent)
    after_next = ticket("s4", "MT-S4", "Todo", parent: parent)
    released = ticket("s5", "MT-S5", "Todo", parent: parent)
    # Its Linear issue carries a blocker link on MT-S2, which an older build kept in the record: it
    # holds nothing.
    linked = ticket("l", "MT-L", "Todo", blockers: [%{id: "s2", identifier: "MT-S2", state: "In Progress"}])
    issues = [linked, next, after_next, released]

    reads = fn ->
      state = Orchestrator.put_dispatch_order_for_test(orchestrator_state(), issues)
      {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
      :ok = GenServer.call(orchestrator, {:put, snapshot, 0})
      {build_conn() |> get("/api/v1/dispatch/order") |> json_response(200), build_conn() |> get("/api/v1/home") |> json_response(200)}
    end

    {order_before, home_before} = reads.()

    # Met: done on a Done ticket, released on a Done ticket with a build from a checkout. Unmet: done
    # and released on a ticket in progress, done on a queued ticket.
    :ok = RunStore.add_dependency("s3", "s1", :done)
    :ok = RunStore.add_dependency("s3", "s2", :done)
    :ok = RunStore.add_dependency("s4", "s1", :released)
    :ok = RunStore.add_dependency("s4", "s3", :done)
    :ok = RunStore.add_dependency("s5", "s2", :released)

    {order, home} = reads.()

    # The same payload shape as before.
    assert Map.keys(order) == Map.keys(order_before)
    assert Map.keys(home) == Map.keys(home_before)
    assert Enum.map(order["groups"], &Map.keys/1) |> Enum.uniq() == Enum.map(order_before["groups"], &Map.keys/1) |> Enum.uniq()
    root_keys = home_before["queue"]["roots"] |> hd() |> Map.keys()
    assert Enum.all?(home["queue"]["roots"], &(Map.keys(&1) == root_keys))

    # The dispatch order: MT-L starts, unaffected by its Linear link; the sub-tickets wait on the
    # tickets their stored dependencies name.
    tickets = order["groups"] |> Enum.flat_map(& &1["tickets"]) |> Map.new(&{&1["identifier"], &1})
    assert %{"next" => "MT-L"} = order
    assert %{"outcome" => "held", "reason" => "waiting for MT-S2 to be done"} = tickets["MT-S3"]
    assert %{"outcome" => "held", "reason" => "waiting for MT-S3 to be done"} = tickets["MT-S4"]
    assert %{"outcome" => "held", "reason" => "waiting for a Symphony update that includes MT-S2"} = tickets["MT-S5"]
    refute tickets["MT-L"]["outcome"] == "held"

    # Home: the epic holds the ticket in progress; MT-S3 and MT-S5 wait on it, MT-S4 under MT-S3, and
    # MT-L is a ready root.
    assert [%{"kind" => "epic", "identifier" => "MT-E", "tickets" => [%{"identifier" => "MT-S2"}]}] = home["in_progress"]
    roots = Map.new(home["queue"]["roots"], &{&1["identifier"], &1})
    assert Map.keys(roots) |> Enum.sort() == ["MT-L", "MT-S3", "MT-S5"]
    assert %{"after" => nil, "also_waits_on" => []} = roots["MT-L"]
    assert %{"after" => "MT-S2", "children" => [%{"identifier" => "MT-S4", "also_waits_on" => []}]} = roots["MT-S3"]
    assert %{"after" => "MT-S2", "children" => []} = roots["MT-S5"]
    assert home["outside"] == %{"backlog" => 0, "below_priority" => 0, "epic" => 0, "behind" => 0}
  end

  test "the queue lists its tickets in the stored order, not by priority or age", %{orchestrator: orchestrator} do
    # MT-Z joined the queue first; MT-A, urgent and older, joined after it.
    joined_first = ticket("z", "MT-Z", "Todo")
    urgent_older = %{ticket("a", "MT-A", "Todo") | priority: 1, created_at: ~U[2025-01-01 00:00:00Z]}

    state = Orchestrator.put_dispatch_order_for_test(orchestrator_state(), [urgent_older, joined_first])
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    :ok = GenServer.call(orchestrator, {:put, snapshot, 0})

    read = build_conn() |> get("/api/v1/home") |> json_response(200)

    assert read["queue"]["roots"] |> Enum.map(& &1["identifier"]) == ["MT-Z", "MT-A"]
  end

  test "the slot entries and a page of the queue rows, numbered in the stored order; a saved filter keeps the real numbers",
       %{orchestrator: orchestrator} do
    working = ticket("w", "MT-W", "In Progress")
    first = ticket("a", "MT-A", "Todo")
    _backlog = ticket("b", "MT-B", "Backlog")
    third = ticket("c", "MT-C", "Todo")
    :ok = RunStore.put_slot_holder("w", ~U[2026-11-24 08:00:00Z], 1)
    put_snapshot(orchestrator, [working, first, third])

    read = build_conn() |> get("/api/v1/home") |> json_response(200)

    assert [%{"slot" => 1, "empty" => false, "since" => "2026-11-24T08:00:00Z", "epic" => nil, "ticket" => card}] = read["slots"]["entries"]
    assert %{"identifier" => "MT-W", "phase" => "In Progress", "waits_on_you" => false, "plan" => nil, "checks" => nil, "pull_request" => nil} = card
    assert [_coding, _review, _qa, _merging, _done] = card["stages"]
    assert %{"used" => 0} = card["tokens"]

    queue = read["queue"]
    assert Enum.map(queue["rows"], &{&1["number"], &1["identifier"], &1["phase"]}) == [{"1", "MT-A", "Todo"}, {"2", "MT-B", "Backlog"}, {"3", "MT-C", "Todo"}]
    assert %{"count" => 3, "total" => 3, "offset" => 0, "limit" => 100, "next_offset" => nil, "view" => nil, "filters" => []} = queue
    assert [%{"repo_key" => @repo, "waits_on" => [], "parent" => nil, "situation" => %{"kind" => _kind}}, _second, _third] = queue["rows"]
    # The tree the present Home draws is still there.
    assert [_root | _roots] = queue["roots"]

    page = build_conn() |> get("/api/v1/home?limit=2") |> json_response(200)
    assert {Enum.map(page["queue"]["rows"], & &1["identifier"]), page["queue"]["next_offset"]} == {["MT-A", "MT-B"], 2}
    page = build_conn() |> get("/api/v1/home?limit=2&offset=2") |> json_response(200)
    assert {Enum.map(page["queue"]["rows"], & &1["identifier"]), page["queue"]["next_offset"]} == {["MT-C"], nil}

    {:ok, view} = Views.save(%{"name" => "To do", "filters" => [%{"column" => "phase", "value" => ["Todo"]}]})
    filtered = build_conn() |> get("/api/v1/home?view=#{view.id}") |> json_response(200)
    assert Enum.map(filtered["queue"]["rows"], &{&1["number"], &1["identifier"]}) == [{"1", "MT-A"}, {"3", "MT-C"}]
    assert %{"count" => 2, "total" => 3, "view" => %{"id" => id, "name" => "To do"}} = filtered["queue"]
    assert id == view.id

    inline = build_conn() |> get("/api/v1/home?phase=Backlog") |> json_response(200)
    assert Enum.map(inline["queue"]["rows"], &{&1["number"], &1["identifier"]}) == [{"2", "MT-B"}]
    assert [%{"column" => "phase", "value" => ["Backlog"]}] = inline["queue"]["filters"]

    assert %{"error" => %{"code" => "view_not_found"}} = build_conn() |> get("/api/v1/home?view=nope") |> json_response(404)
    assert %{"error" => %{"code" => "invalid_query"}} = build_conn() |> get("/api/v1/home?view=#{view.id}&phase=Todo") |> json_response(400)
    assert %{"error" => %{"code" => "invalid_query", "message" => "offset must be a whole number from 0"}} = build_conn() |> get("/api/v1/home?offset=x") |> json_response(400)
    assert %{"error" => %{"code" => "invalid_query"}} = build_conn() |> get("/api/v1/home?sort=nope") |> json_response(400)
  end

  test "Recently done gives the tickets done today, or in the week, in pages, from the run records; a bad range or number answers 400",
       %{orchestrator: orchestrator} do
    done = ticket("d", "MT-D", "Done")
    put_snapshot(orchestrator, [done])
    now = DateTime.utc_now()

    :ok =
      RunStore.put_run(%{
        repo_key: @repo,
        run_id: "run-d",
        issue_id: "d",
        issue_identifier: "MT-D",
        title: "Ticket MT-D",
        started_at: now,
        issue_completed_notified_at: now,
        pr_url: "https://github.com/acme/app/pull/7"
      })

    read = build_conn() |> get("/api/v1/home") |> json_response(200)
    assert %{"range" => "today", "counts" => %{"today" => 1, "week" => 1}, "offset" => 0, "next_offset" => nil} = read["recently_done"]
    assert [%{"identifier" => "MT-D", "repo_key" => @repo, "pull_request_number" => 7, "epic" => nil, "done_at" => _at}] = read["recently_done"]["entries"]
    # Every key the Home read gave before is still there.
    assert Enum.all?(~w(in_progress queue outside slots), &Map.has_key?(read, &1))

    page = build_conn() |> get("/api/v1/home?done_range=week&done_offset=1&done_limit=1") |> json_response(200)
    assert %{"range" => "week", "entries" => [], "offset" => 1, "limit" => 1, "counts" => %{"today" => 1, "week" => 1}} = page["recently_done"]

    assert %{"error" => %{"code" => "invalid_query", "message" => "done_range must be today or week"}} =
             build_conn() |> get("/api/v1/home?done_range=month") |> json_response(400)

    assert %{"error" => %{"code" => "invalid_query"}} = build_conn() |> get("/api/v1/home?done_offset=x") |> json_response(400)
    assert %{"error" => %{"code" => "invalid_query"}} = build_conn() |> get("/api/v1/home?done_limit=0") |> json_response(400)
  end

  test "a read after a queue move, a slot count change, a Start or a Stop shows it, with no poll between", %{orchestrator: orchestrator} do
    working = ticket("w", "MT-W", "In Progress")
    first = ticket("a", "MT-A", "Todo")
    second = ticket("b", "MT-B", "Todo")
    :ok = RunStore.put_slot_holder("w", ~U[2026-11-24 08:00:00Z], 1)
    snapshot = put_snapshot(orchestrator, [working, first, second])

    home = fn -> build_conn() |> get("/api/v1/home") |> json_response(200) end
    rows = fn read -> Enum.map(read["queue"]["rows"], &{&1["number"], &1["identifier"]}) end
    slots = fn read -> Enum.map(read["slots"]["entries"], &{&1["slot"], get_in(&1, ["ticket", "identifier"])}) end

    assert rows.(home.()) == [{"1", "MT-A"}, {"2", "MT-B"}]

    # A queue move (`RunStore.move_in_queue/2`, then the stream's notice): the snapshot is the same.
    :ok = RunStore.move_in_queue("b", :top)
    assert rows.(home.()) == [{"1", "MT-B"}, {"2", "MT-A"}]

    # The slot count raised to 3: the snapshot the orchestrator publishes in the call (`slots_changed/1`).
    :ok = GenServer.call(orchestrator, {:put, put_in(snapshot, [:slots, :total], 3), 0})
    assert slots.(home.()) == [{1, "MT-W"}, {2, nil}, {3, nil}]

    # A Start on slot 2 (the holder's record written in the call), then a Stop of MT-W.
    :ok = RunStore.put_slot_holder("a", ~U[2026-11-24 09:00:00Z], 2)
    read = home.()
    assert slots.(read) == [{1, "MT-W"}, {2, "MT-A"}, {3, nil}]
    assert rows.(read) == [{"1", "MT-B"}]

    :ok = RunStore.put_slot_holder("w", nil)
    read = home.()
    # MT-W comes back to the queue at its stored place, behind MT-B, which the move put on top.
    assert slots.(read) == [{1, nil}, {2, "MT-A"}, {3, nil}]
    assert rows.(read) == [{"1", "MT-B"}, {"2", "MT-W"}]
  end

  test "an unreadable or slow orchestrator reads the records alone, with an error", %{orchestrator: orchestrator} do
    ticket("w", "MT-W", "In Progress")

    read = build_conn() |> get("/api/v1/home") |> json_response(200)
    assert %{"error" => %{"code" => "snapshot_unavailable"}, "in_progress" => [%{"identifier" => "MT-W"}], "queue" => %{"roots" => []}} = read

    # The slots numbered to the configured count, from the records alone.
    assert [%{"slot" => 1, "empty" => true}] = read["slots"]["entries"]

    :ok = GenServer.call(orchestrator, {:put, %{running: []}, 200})
    assert %{error: %{code: "snapshot_timeout"}, in_progress: [%{identifier: "MT-W"}]} = Presenter.home_payload(orchestrator, 10)
  end

  # The ticket's record and its read from Linear, which carries no blocker link. `attrs` may give the
  # record's `parent`, `labels` and `blockers` (the field an older build observed).
  defp ticket(id, identifier, state, attrs \\ []) do
    attrs = Map.new(attrs)

    :ok =
      RunStore.put_ticket_state(
        Map.merge(
          %{
            repo_key: @repo,
            issue_id: id,
            issue_identifier: identifier,
            title: "Ticket #{identifier}",
            phase: state,
            priority: 2,
            linear_updated_at: DateTime.utc_now()
          },
          attrs
        )
      )

    %Issue{
      id: id,
      identifier: identifier,
      title: "Ticket #{identifier}",
      state: state,
      priority: 2,
      labels: Map.get(attrs, :labels, []),
      parent: Map.get(attrs, :parent),
      repo_key: @repo,
      url: "https://example.org/issues/#{identifier}"
    }
  end

  # The snapshot the orchestrator publishes after walking `issues`, served by the test's orchestrator.
  defp put_snapshot(orchestrator, issues) do
    state = Orchestrator.put_dispatch_order_for_test(orchestrator_state(), issues)
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    :ok = GenServer.call(orchestrator, {:put, snapshot, 0})
    snapshot
  end

  defp orchestrator_state do
    %Orchestrator.State{
      repo_key: @repo,
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
