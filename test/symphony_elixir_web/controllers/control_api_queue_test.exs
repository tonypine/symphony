defmodule SymphonyElixirWeb.ControlApiQueueTest do
  # TP-1629: the Director's queue controls. `POST /control/queue/move` puts a ticket at another place
  # in the stored queue, and a read made right after the answer shows it there; `POST /control/slots`
  # sets the slot count from 1 to 6 by editing one line of symphony.yml. Rewrites the app's config:
  # not async.
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{DirectorQueue, TicketState}
  alias SymphonyElixirWeb.{ControlApiController, Presenter}

  @repo "default"

  # An orchestrator over a state a test gives it: its calls are the orchestrator's own, and the
  # cycle a call asks for (a tick) is dropped, so no poll runs.
  defmodule StateOrchestrator do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(message, from, state), do: Orchestrator.handle_call(message, from, state)

    @impl true
    def handle_info(_message, state), do: {:noreply, state}
  end

  defmodule StubOrchestrator do
    use GenServer

    def start_link(reply), do: GenServer.start_link(__MODULE__, reply)

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call(_message, _from, reply), do: {:reply, reply, reply}
  end

  # A store whose move answers what the test put in the process dictionary.
  defmodule Store do
    def move_in_queue(_issue_id, _to), do: Process.get(:store_reply)
  end

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Done", "Canceled"],
      max_concurrent_agents: 1
    )

    write_symphony_blocks!()

    issues = [ticket("a", "MT-A"), ticket("b", "MT-B"), ticket("c", "MT-C")]
    state = Orchestrator.put_dispatch_order_for_test(orchestrator_state(), issues)
    {:ok, orchestrator} = StateOrchestrator.start_link(state)
    %{orchestrator: orchestrator}
  end

  describe "POST /control/queue/move" do
    test "moves a ticket to the top, after, before and to the end, and a read right after the answer shows it there", %{orchestrator: orchestrator} do
      assert queue(orchestrator) == ["MT-A", "MT-B", "MT-C"]

      top = post_move(%{"issue_identifier" => "MT-C", "position" => "top"}, orchestrator)
      assert top.status == 200

      assert body(top) == %{
               "action" => "move_in_queue",
               "issue_id" => "c",
               "issue_identifier" => "MT-C",
               "scope" => nil,
               "order" => ["MT-C", "MT-A", "MT-B"]
             }

      assert stored() == ["c", "a", "b"]
      assert queue(orchestrator) == ["MT-C", "MT-A", "MT-B"]

      assert body(post_move(%{"issue_identifier" => "mt-a", "after" => "MT-B"}, orchestrator))["order"] == ["MT-C", "MT-B", "MT-A"]
      assert queue(orchestrator) == ["MT-C", "MT-B", "MT-A"]

      assert body(post_move(%{"issue_identifier" => "a", "before" => "MT-C"}, orchestrator))["order"] == ["MT-A", "MT-C", "MT-B"]
      assert queue(orchestrator) == ["MT-A", "MT-C", "MT-B"]

      assert body(post_move(%{"issue_identifier" => "MT-A", "position" => "end"}, orchestrator))["order"] == ["MT-C", "MT-B", "MT-A"]
      assert queue(orchestrator) == ["MT-C", "MT-B", "MT-A"]
      assert home_queue(orchestrator) == ["MT-C", "MT-B", "MT-A"]
    end

    test "a sub-ticket moves among its parent's sub-tickets", %{orchestrator: orchestrator} do
      for {id, identifier} <- [{"s1", "MT-S1"}, {"s2", "MT-S2"}], do: ticket(id, identifier, parent: %{identifier: "MT-A"})

      moved = post_move(%{"issue_identifier" => "MT-S2", "before" => "MT-S1"}, orchestrator)
      assert %{"scope" => "MT-A", "order" => ["MT-S2", "MT-S1"]} = body(moved)
      assert stored() == ["a", "s2", "s1", "b", "c"]
    end

    test "a missing or unknown parameter, or a ticket Symphony doesn't track, is a 422 that moves nothing", %{orchestrator: orchestrator} do
      for params <- [
            %{"position" => "top"},
            %{"issue_identifier" => "MT-A"},
            %{"issue_identifier" => "MT-A", "position" => "middle"},
            %{"issue_identifier" => "MT-A", "position" => "top", "after" => "MT-B"},
            %{"issue_identifier" => "MT-A", "after" => "MT-B", "before" => "MT-C"}
          ] do
        conn = post_move(params, orchestrator)
        assert conn.status == 422, "#{inspect(params)} answered #{conn.status}"
        assert %{"error" => %{"code" => "invalid_request"}} = body(conn)
      end

      untracked = post_move(%{"issue_identifier" => "ZZ-1", "position" => "top"}, orchestrator)
      assert untracked.status == 422
      assert body(untracked)["error"]["message"] == "Symphony doesn't track ZZ-1, so it can't move it in the queue."

      neighbour = post_move(%{"issue_identifier" => "MT-A", "after" => "ZZ-2"}, orchestrator)
      assert neighbour.status == 422
      assert body(neighbour)["error"]["message"] == "Symphony doesn't track ZZ-2, so it can't move a ticket next to it."

      assert stored() == ["a", "b", "c"]
    end

    test "a ticket out of the queue, a move next to itself or into another scope is a 409 with the reason", %{orchestrator: orchestrator} do
      ticket("s1", "MT-S1", parent: %{identifier: "MT-A"})
      :ok = RunStore.update_ticket_state("b", %{phase: "Done"})

      for {params, message} <- [
            {%{"issue_identifier" => "MT-B", "position" => "top"}, "MT-B holds no place in the queue."},
            {%{"issue_identifier" => "MT-C", "after" => "MT-C"}, "MT-C can't be moved next to itself."},
            {%{"issue_identifier" => "MT-C", "after" => "MT-S1"}, "MT-S1 is not queued in the same list as MT-C; a ticket moves only among the top-level tickets."},
            {%{"issue_identifier" => "MT-S1", "before" => "MT-A"}, "MT-A is not queued in the same list as MT-S1; a ticket moves only among the sub-tickets of MT-A."}
          ] do
        conn = post_move(params, orchestrator)
        assert conn.status == 409, "#{inspect(params)} answered #{conn.status}"
        assert body(conn) == %{"error" => %{"code" => "move_not_allowed", "message" => message}}
      end

      assert stored() == ["a", "s1", "c"]
    end

    test "TP-1633: a move that would put a ticket above one it depends on is a 409 naming both, and the queue stays", %{orchestrator: orchestrator} do
      :ok = RunStore.add_dependency("c", "b", :done)
      assert stored() == ["a", "b", "c"]

      for params <- [%{"issue_identifier" => "MT-C", "position" => "top"}, %{"issue_identifier" => "MT-B", "position" => "end"}] do
        conn = post_move(params, orchestrator)
        assert conn.status == 409, inspect(params)
        assert body(conn) == %{"error" => %{"code" => "move_not_allowed", "message" => "MT-C depends on MT-B and must stay below it."}}
      end

      assert stored() == ["a", "b", "c"]

      # Two sub-tickets of one parent.
      for {id, identifier} <- [{"s1", "MT-S1"}, {"s2", "MT-S2"}], do: ticket(id, identifier, parent: %{identifier: "MT-A"})
      :ok = RunStore.add_dependency("s2", "s1", :released)
      conn = post_move(%{"issue_identifier" => "MT-S2", "before" => "MT-S1"}, orchestrator)
      assert conn.status == 409
      assert body(conn)["error"]["message"] == "MT-S2 depends on MT-S1 and must stay below it."
      assert stored() == ["a", "s1", "s2", "b", "c"]
    end

    test "a store that loses a race or refuses the write answers 409 or 502", %{orchestrator: orchestrator} do
      for {reply, status, code} <- [
            {{:error, :not_neighbours}, 409, "move_not_allowed"},
            {{:error, :not_in_queue}, 409, "move_not_allowed"},
            # A ticket the store names that the read didn't hold is named by its id.
            {{:error, {:dependency_order, "c", "ghost"}}, 409, "move_not_allowed"},
            {{:error, :aborted}, 502, "store_error"}
          ] do
        Process.put(:store_reply, reply)
        conn = post_move(%{"issue_identifier" => "MT-C", "position" => "top"}, orchestrator, store: Store)
        assert conn.status == status
        assert body(conn)["error"]["code"] == code
      end

      assert stored() == ["a", "b", "c"]
    end
  end

  describe "POST /control/slots" do
    @tag :tmp_dir
    test "sets 1 to 6 by editing the one line, keeping every other line, comment and the order", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "symphony.yml")

      text = """
      # Symphony's settings, edited by hand.
      tracker:
        kind: memory
      execution:
        # How many tickets work at once.
        concurrency:
          max_total: 2 # the slots
        max_turns: 5
      """

      File.write!(file, text)
      {:ok, orchestrator} = StubOrchestrator.start_link({:ok, %{total: 4}})

      conn = post_slots(%{"count" => 4}, orchestrator, file: file)
      assert conn.status == 200
      assert body(conn) == %{"action" => "set_slots", "count" => 4, "slots" => %{"total" => 4}}
      assert File.read!(file) == String.replace(text, "max_total: 2 # the slots", "max_total: 4 # the slots")

      for count <- [1, "6"] do
        assert post_slots(%{"count" => count}, orchestrator, file: file).status == 200
      end

      assert File.read!(file) == String.replace(text, "max_total: 2 # the slots", "max_total: 6 # the slots")
    end

    @tag :tmp_dir
    test "a count outside 1 to 6 is a 422 and leaves the file as it is", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "symphony.yml")
      File.write!(file, "execution:\n  concurrency:\n    max_total: 2\n")
      before = File.read!(file)
      assert DirectorQueue.slot_range() == 1..6

      for count <- [0, 7, -1, 2.5, "seven", "3 slots", nil] do
        conn = post_slots(%{"count" => count}, self(), file: file)
        assert conn.status == 422, "#{inspect(count)} answered #{conn.status}"
        assert body(conn)["error"]["code"] == "invalid_request"
      end

      assert body(post_slots(%{"count" => 7}, self(), file: file))["error"]["message"] == "7 is not a slot count: use a whole number from 1 to 6."
      assert File.read!(file) == before
    end

    @tag :tmp_dir
    test "a file the line editor can't change is a 502 with why", %{tmp_dir: tmp_dir} do
      inline = Path.join(tmp_dir, "symphony.yml")
      File.write!(inline, "execution: {concurrency: {max_total: 2}}\n")

      conn = post_slots(%{"count" => 3}, self(), file: inline)
      assert conn.status == 502

      assert %{"code" => "config_error", "message" => "Symphony couldn't change execution.concurrency.max_total in symphony.yml (execution: is not an indented block); edit it by hand."} =
               body(conn)["error"]

      missing = post_slots(%{"count" => 3}, self(), file: Path.join(tmp_dir, "missing.yml"))
      assert missing.status == 502
      assert body(missing)["error"]["message"] =~ ":enoent"
    end

    test "the new count reaches the orchestrator in the same call, and the reads show it", %{orchestrator: orchestrator} do
      assert %{total: 1} = Presenter.dispatch_order_payload(orchestrator, 1_000).slots

      conn = post_slots(%{"count" => 3}, orchestrator)
      assert conn.status == 200
      assert %{"count" => 3, "slots" => %{"total" => 3, "free" => 3}} = body(conn)
      assert Config.settings!().execution.max_concurrent_agents == 3
      assert %{total: 3} = Presenter.dispatch_order_payload(orchestrator, 1_000).slots
    end
  end

  defp post_move(params, orchestrator, director_queue \\ []), do: post("/api/v1/control/queue/move", params, orchestrator, director_queue, &ControlApiController.queue_move/2)

  defp post_slots(params, orchestrator, director_queue \\ []), do: post("/api/v1/control/slots", params, orchestrator, director_queue, &ControlApiController.slots/2)

  defp post(path, params, orchestrator, director_queue, action) do
    conn(:post, path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> assign(:orchestrator, orchestrator)
    |> assign(:director_queue, director_queue)
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> action.(params)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # The ticket ids in the stored order.
  defp stored, do: RunStore.queue_places() |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  # The tickets in line, as the dispatch order read shows them.
  defp queue(orchestrator), do: Presenter.dispatch_order_payload(orchestrator, 1_000).queue |> Enum.map(& &1.identifier)

  # Home's queue, as the Director's Home read shows it.
  defp home_queue(orchestrator), do: Presenter.home_payload(orchestrator, 1_000).queue.roots |> Enum.map(& &1.identifier)

  defp ticket(id, identifier, attrs \\ []) do
    record = %{
      issue_identifier: identifier,
      title: "Ticket #{identifier}",
      phase: "Todo",
      linear_updated_at: DateTime.utc_now(),
      parent: attrs[:parent]
    }

    :ok = RunStore.put_ticket_state(TicketState.new(@repo, id, record))
    url = "https://example.org/issues/#{identifier}"
    %Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", state: "Todo", priority: 3, repo_key: @repo, url: url}
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
