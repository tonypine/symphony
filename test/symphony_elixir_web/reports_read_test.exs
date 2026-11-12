defmodule SymphonyElixirWeb.ReportsReadTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 2]

  alias SymphonyElixir.TicketEvents
  alias SymphonyElixirWeb.{ReportsController, Router}

  @endpoint SymphonyElixirWeb.Endpoint
  @repo "fixture"

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "three", issue_identifier: "FIX-3", phase: "Rework"})
    {:ok, moved} = TicketEvents.record(@repo, "three", "ticket.moved", %{from: "QA", to: "Rework"}, at: ~U[2026-11-09 11:00:00Z], actor: {:person, "Director"})
    %{moved: moved.id}
  end

  defp get_reports(query) do
    conn = get(build_conn(), "/api/v1/reports?" <> URI.encode_query(query))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp create(params, opts) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.assign(:reports_opts, opts)
      |> Map.put(:params, params)
      |> ReportsController.create(params)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "a report started on a period is served newest first once its run publishes it", %{moved: moved} do
    parent = self()

    publish = fn _request, _opts ->
      {:ok, [%{"type" => "tool_use", "id" => "t", "name" => "symphony_publish_report", "input" => %{"sentences" => [%{"text" => "You sent FIX-3 back to Rework.", "events" => [moved]}]}}]}
    end

    opts = [turn: publish, start_task: &send(parent, {:run, &1})]

    assert {200, %{"run_id" => "report-" <> _ulid = run_id, "model" => "claude-haiku-5-5", "from" => "2026-11-09T08:00:00Z", "to" => "2026-11-09T12:00:00Z", "events" => 1}} =
             create(%{"from" => "2026-11-09T08:00:00Z", "to" => "2026-11-09T12:00:00Z"}, opts)

    assert {200, %{"reports" => []}} = get_reports(%{})
    assert_received {:run, run}
    {:ok, _event} = run.()

    assert {200, %{"reports" => [report]}} = get_reports(%{"since" => "2026-11-09T00:00:00Z", "until" => ""})

    assert %{
             "run_id" => ^run_id,
             "period" => %{"from" => "2026-11-09T08:00:00Z", "to" => "2026-11-09T12:00:00Z"},
             "tickets" => ["FIX-3"],
             "events" => [^moved],
             "sentences" => ["You sent FIX-3 back to Rework."],
             "text" => "You sent FIX-3 back to Rework.",
             "citations" => [%{"sentence" => 0, "events" => [^moved]}],
             "question_id" => nil
           } = report

    assert {200, %{"reports" => []}} = get_reports(%{"until" => "2026-11-09T00:00:00Z"})
  end

  test "refuses a period it cannot read or one with nothing to cite, and an unreadable query" do
    opts = [start_task: fn _run -> flunk("must not start a run") end]

    assert {422, %{"error" => %{"code" => "no_events", "message" => "No notable event happened in that period, so there is nothing to report."}}} =
             create(%{"from" => "2026-11-01T00:00:00Z", "to" => "2026-11-02T00:00:00Z"}, opts)

    assert {422, %{"error" => %{"code" => "invalid_request", "message" => "--from is required."}}} = create(%{"to" => "now"}, opts)
    assert {422, %{"error" => %{"message" => "The start of the period must come before its end."}}} = create(%{"from" => "now", "to" => "yesterday"}, opts)

    assert {400, %{"error" => %{"code" => "invalid_query", "message" => "since must be an ISO 8601 timestamp"}}} = get_reports(%{"since" => "this morning"})
    conn = get(build_conn(), "/api/v1/reports?until[]=x")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "until must be an ISO 8601 timestamp"

    assert post(build_conn(), "/api/v1/reports").status == 405
  end

  test "starting a report needs the control token, like the other control routes" do
    conn =
      Plug.Test.conn(:post, "/api/v1/control/report", Jason.encode!(%{"from" => "yesterday", "to" => "now"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 401
    assert {:ok, []} = SymphonyElixir.Reports.list()
  end
end
