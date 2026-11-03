defmodule SymphonyElixirWeb.TicketPriorityTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{RunStore, TicketState}
  alias SymphonyElixirWeb.{ControlApiController, Router, TicketPriorityController}

  @moduletag :tmp_dir

  defmodule Writer do
    @moduledoc false
    def update_issue_priority(_issue_id, _priority), do: Process.get(:tracker_reply, :ok)
  end

  setup do
    n = System.unique_integer([:positive])
    repo = "priority-api-#{n}"
    ticket = %{repo_key: repo, issue_id: "issue-#{n}", issue_identifier: "PAPI-#{n}", phase: "Todo", title: "Export", priority: 4}
    :ok = RunStore.put_ticket_state(ticket)
    %{repo: repo, ticket: ticket}
  end

  defp post_priority(params, ctx) do
    conn(:post, "/api/v1/control/priority", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> assign(:orchestrator, self())
    |> assign(:audit_log, dir: ctx.tmp_dir)
    |> assign(:director_priority, tracker: Writer, records: RunStore.list_ticket_states(ctx.repo))
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> ControlApiController.priority(params)
  end

  defp get_priority(identifier, ctx) do
    conn(:get, "/api/v1/tickets/#{identifier}/priority")
    |> assign(:director_priority, records: RunStore.list_ticket_states(ctx.repo))
    |> TicketPriorityController.show(%{"issue_identifier" => identifier})
  end

  defp params(ctx, priority), do: %{"issue_identifier" => ctx.ticket.issue_identifier, "priority" => priority}

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp priority(ctx), do: (ctx.ticket.issue_id |> RunStore.get_ticket_state() |> TicketState.normalize()).priority

  test "POST /control/priority sets Urgent then Low, answering the ticket's priority each time", ctx do
    urgent = post_priority(params(ctx, "urgent"), ctx)
    assert urgent.status == 200

    assert body(urgent) == %{
             "action" => "set_priority",
             "issue_identifier" => ctx.ticket.issue_identifier,
             "priority" => "urgent",
             "priority_value" => 1,
             "priorities" => ~w(none urgent high medium low)
           }

    assert priority(ctx) == 1

    low = post_priority(params(ctx, 4), ctx)
    assert low.status == 200
    assert body(low)["priority"] == "low"
    assert priority(ctx) == 4
  end

  test "POST /control/priority refuses an unknown ticket with a 409 and an unknown value with a 422", ctx do
    untracked = post_priority(%{"issue_identifier" => "ZZZ-404", "priority" => "urgent"}, ctx)
    assert untracked.status == 409

    assert body(untracked) == %{
             "error" => %{"code" => "move_not_allowed", "message" => "Symphony doesn't track ZZZ-404, so it can't set its priority."}
           }

    same = post_priority(params(ctx, "low"), ctx)
    assert same.status == 409
    assert body(same)["error"]["message"] == "#{ctx.ticket.issue_identifier} is already Low."

    unknown = post_priority(params(ctx, "critical"), ctx)
    assert unknown.status == 422
    assert body(unknown)["error"]["code"] == "invalid_request"
    assert body(unknown)["error"]["message"] =~ "is not a Linear priority"

    for {params, message} <- [
          {Map.delete(params(ctx, "urgent"), "priority"), "priority is required"},
          {Map.delete(params(ctx, "urgent"), "issue_identifier"), "issue_identifier is required"}
        ] do
      conn = post_priority(params, ctx)
      assert conn.status == 422
      assert body(conn) == %{"error" => %{"code" => "invalid_request", "message" => message}}
    end

    assert priority(ctx) == 4
  end

  @tag :capture_log
  test "POST /control/priority answers 502 when Linear refuses the write", ctx do
    Process.put(:tracker_reply, {:error, :issue_update_failed})
    conn = post_priority(params(ctx, "urgent"), ctx)
    assert conn.status == 502
    assert body(conn)["error"] == %{"code" => "linear_error", "message" => "Linear didn't set #{ctx.ticket.issue_identifier} to Urgent, so nothing changed. Try again in a moment."}
    assert priority(ctx) == 4
  end

  test "POST /control/priority needs the control token like the other control routes", ctx do
    conn =
      conn(:post, "/api/v1/control/priority", Jason.encode!(params(ctx, "urgent")))
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 401
  end

  test "GET /tickets/:identifier/priority reads the record's priority, 404 for an untracked ticket", ctx do
    conn = get_priority(ctx.ticket.issue_identifier, ctx)
    assert conn.status == 200

    assert body(conn) == %{
             "issue_identifier" => ctx.ticket.issue_identifier,
             "priority" => "low",
             "priority_value" => 4,
             "priorities" => ~w(none urgent high medium low)
           }

    routed = conn(:get, "/api/v1/tickets/#{ctx.ticket.issue_identifier}/priority") |> Router.call(Router.init([]))
    assert routed.status == 200
    assert body(routed)["priority"] == "low"

    missing = get_priority("ZZZ-404", ctx)
    assert missing.status == 404
    assert body(missing)["error"]["code"] == "ticket_not_found"
  end
end
