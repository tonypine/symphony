defmodule SymphonyElixirWeb.BackfilledQuestionsStateTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.TicketState

  @endpoint SymphonyElixirWeb.Endpoint
  @backfilled "test/fixtures/inbox/backfilled_questions.exs"

  # Answers `GET /api/v1/state` and `GET /api/v1/inbox` with an idle snapshot.
  defmodule IdleOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, %{running: [], retrying: [], rate_limits: nil}, state}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: IdleOrchestrator, start: {IdleOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp backfilled do
    {questions, _binding} = Code.eval_file(@backfilled)
    questions
  end

  defp put_record(identifier, questions) do
    attrs = %{issue_identifier: identifier, title: "QA fixtures for the go-back screens", phase: "Todo", questions: questions}
    :ok = RunStore.put_ticket_state(TicketState.new(Config.repo_key!(), "id-" <> identifier, attrs))
  end

  test "the state and the Inbox answer 200 with the backfilled TP-1074 Question stored, which lists with nothing it unblocks" do
    [tp_1074 | _others] = backfilled()
    put_record("TP-1074", [tp_1074])

    assert %{"waiting_on_you" => _rows} = build_conn() |> get("/api/v1/state") |> json_response(200)

    assert %{"items" => [%{"identifier" => "TP-1074", "kind" => "action", "review" => review}]} = build_conn() |> get("/api/v1/inbox") |> json_response(200)
    assert %{"question_id" => "backfill-e36e1800010dcd90", "unblocks" => nil} = review
  end

  test "every backfilled Question, each on its own ticket, leaves the state and the Inbox readable" do
    for {question, index} <- Enum.with_index(backfilled()), do: put_record("TP-#{index + 1}", [question])

    assert %{} = build_conn() |> get("/api/v1/state") |> json_response(200)
    assert %{"counts" => %{"action" => 3}} = build_conn() |> get("/api/v1/inbox") |> json_response(200)
  end
end
