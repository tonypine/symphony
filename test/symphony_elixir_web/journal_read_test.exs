defmodule SymphonyElixirWeb.JournalReadTest do
  use SymphonyElixir.TestSupport

  import Plug.Test

  alias SymphonyElixir.{RuleActions, TicketEvents}
  alias SymphonyElixirWeb.Router

  @repo "fixture"
  @morning "2026-11-09T06:00:00Z"

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "child", issue_identifier: "FIX-2", title: "A sub-ticket", phase: "In Progress"})
    :ok
  end

  defp at(hour), do: DateTime.new!(~D[2026-11-09], Time.new!(hour, 0, 0))

  defp get_events(query) do
    conn = :get |> conn("/api/v1/events?" <> URI.encode_query(query)) |> Router.call(Router.init([]))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "reads the notable events since this morning as a journal: each line names the ticket and who did it" do
    {:ok, _event} = TicketEvents.record(@repo, "child", "run.started", %{run_id: "run-1", run_kind: "implementation"}, at: at(8))
    {:ok, _event} = TicketEvents.record(@repo, "child", "verdict.recorded", %{kind: "code_review", outcome: "approve"}, at: at(9), run_id: "run-2")
    :ok = RuleActions.record(@repo, "child", "CI wait", "paused", "Waiting for CI on abc1234 to finish", at: at(10))
    {:ok, _event} = TicketEvents.record(@repo, "child", "ticket.moved", %{from: "QA", to: "Rework"}, at: at(11), actor: {:person, "Director"})

    assert {200, %{"events" => events, "next_until" => nil}} = get_events(%{"since" => @morning, "repo" => @repo})

    assert [
             %{"type" => "ticket.moved", "by" => %{"kind" => "person", "name" => "Director"}},
             %{"type" => "rule.action", "by" => %{"kind" => "rule", "name" => "CI wait"}, "summary" => %{"title" => "CI wait paused the ticket"}},
             %{"type" => "verdict.recorded", "by" => %{"kind" => "run", "run_id" => "run-2"}}
           ] = events

    for event <- events do
      assert event["ticket"] == %{"repo_key" => @repo, "identifier" => "FIX-2", "title" => "A sub-ticket"}
      assert event["notable"] == true
      assert is_binary(event["at"]) and is_map(event["summary"]) and event["artifacts"] == []
    end

    assert Enum.map(events, & &1["class"]) == ["move", "rule", "verdict"]

    assert {200, %{"events" => all}} = get_events(%{"since" => @morning, "notable" => "false", "classes" => "run,verdict"})
    assert Enum.map(all, & &1["type"]) == ["verdict.recorded", "run.started"]

    assert {200, %{"events" => [_newest], "next_until" => next_until}} = get_events(%{"limit" => "1", "until" => "", "epic" => " "})
    assert {200, %{"events" => [%{"type" => "rule.action"}]}} = get_events(%{"limit" => "1", "until" => next_until})
  end

  test "a malformed query is 400 and another method is 405" do
    for {query, message} <- [
          {%{"since" => "this morning"}, "since must be an ISO 8601 timestamp"},
          {%{"until" => "later"}, "until must be an ISO 8601 timestamp"},
          {%{"classes" => "verdict,gossip"}, "Unknown class(es): gossip"},
          {%{"notable" => "maybe"}, "notable must be true or false"},
          {%{"limit" => "0"}, "limit must be a positive integer"},
          {%{"limit" => "ten"}, "limit must be a positive integer"}
        ] do
      assert {400, %{"error" => %{"code" => "invalid_query", "message" => ^message}}} = get_events(query)
    end

    for {param, message} <- [
          {"since", "since must be an ISO 8601 timestamp"},
          {"classes", "classes must be a comma-separated list"},
          {"limit", "limit must be a positive integer"}
        ] do
      conn = :get |> conn("/api/v1/events?#{param}[]=x") |> Router.call(Router.init([]))
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["message"] == message
    end

    conn = :post |> conn("/api/v1/events", "") |> Router.call(Router.init([]))
    assert conn.status == 405
  end
end
