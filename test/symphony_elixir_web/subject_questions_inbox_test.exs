defmodule SymphonyElixirWeb.SubjectQuestionsInboxTest do
  @moduledoc """
  `GET /api/v1/inbox` and `GET /api/v1/state` list a Question on Symphony itself with its subject in
  place of a ticket (TP-1341), and a ticket's row as before, with subject `ticket`.
  """

  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.{Questions, TicketState}

  @endpoint SymphonyElixirWeb.Endpoint

  # Answers `GET /api/v1/state` and `GET /api/v1/inbox` with an idle snapshot.
  defmodule IdleOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, %{running: [], retrying: [], rate_limits: nil}, state}
  end

  @request %{
    title: "The Symphony release build keeps being cancelled",
    question: "GitHub cancelled the release build 3 times. Should Symphony rerun it, or wait for a fix?",
    why: "GitHub cancels a build it can't find a machine for.",
    if_unanswered: "The app stays on its current version.",
    recommendation_reason: "A rerun costs nothing.",
    options: [%{label: "Rerun the build", effect: "Symphony reruns it.", recommended: true}, %{label: "Wait for a fix", effect: "Nothing is rerun."}]
  }

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

  test "a question on Symphony lists with subject symphony and no ticket; a ticket's with subject ticket" do
    {:ok, %{id: id}} = Questions.ask(:symphony, @request, at: ~U[2026-11-02 18:00:00Z])
    ticket = {:ticket, Config.repo_key!(), "id-TP-9"}
    :ok = RunStore.put_ticket_state(TicketState.new(Config.repo_key!(), "id-TP-9", %{issue_identifier: "TP-9", title: "A ticket", phase: "Todo"}))
    {:ok, _question} = Questions.ask(ticket, %{@request | title: "A ticket's question"}, at: ~U[2026-11-02 18:10:00Z])

    assert %{"counts" => %{"action" => 2}, "items" => [symphony, ticket_row]} = build_conn() |> get("/api/v1/inbox") |> json_response(200)

    assert %{"subject" => "symphony", "issue_id" => nil, "identifier" => nil, "title" => "Symphony", "repo_key" => nil, "kind" => "action"} = symphony
    assert %{"question_id" => ^id, "comment_id" => nil, "title" => "The Symphony release build keeps being cancelled"} = symphony["review"]
    assert %{"subject" => "ticket", "identifier" => "TP-9"} = ticket_row

    assert %{"waiting_on_you" => [%{"subject" => "symphony", "issue_identifier" => nil, "decision" => true}, %{"subject" => "ticket"}]} =
             build_conn() |> get("/api/v1/state") |> json_response(200)
  end
end
