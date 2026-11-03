defmodule SymphonyElixirWeb.TicketBlockersTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{RunStore, TicketState}
  alias SymphonyElixirWeb.{ControlApiController, Router, TicketBlockersController}

  @moduletag :tmp_dir

  defmodule Linker do
    @moduledoc false
    def add_blocked_by(_blocker, _issue_id), do: Process.get(:linker_reply, :ok)
    def remove_blocked_by(_blocker, _issue_id), do: Process.get(:linker_reply, :ok)
  end

  setup do
    n = System.unique_integer([:positive])
    repo = "blocker-api-#{n}"
    ticket = %{repo_key: repo, issue_id: "issue-#{n}-1", issue_identifier: "API-#{n}1", phase: "Todo", title: "Export"}
    blocker = %{repo_key: repo, issue_id: "issue-#{n}-2", issue_identifier: "API-#{n}2", phase: "Todo", title: "Fix"}
    :ok = RunStore.put_ticket_state(ticket)
    :ok = RunStore.put_ticket_state(blocker)
    %{repo: repo, ticket: ticket, blocker: blocker}
  end

  defp post_blocker(params, ctx) do
    conn(:post, "/api/v1/control/blocker", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> assign(:orchestrator, self())
    |> assign(:audit_log, dir: ctx.tmp_dir)
    |> assign(:director_blockers, linker: Linker, records: RunStore.list_ticket_states(ctx.repo))
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> ControlApiController.blocker(params)
  end

  defp get_blockers(identifier, ctx) do
    conn(:get, "/api/v1/tickets/#{identifier}/blockers")
    |> assign(:director_blockers, records: RunStore.list_ticket_states(ctx.repo))
    |> TicketBlockersController.index(%{"issue_identifier" => identifier})
  end

  defp params(ctx, action, blocker \\ nil),
    do: %{"issue_identifier" => ctx.ticket.issue_identifier, "blocker" => blocker || ctx.blocker.issue_identifier, "action" => action}

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "POST /control/blocker adds a blocker and removes it, answering the ticket's blockers each time", ctx do
    added = post_blocker(params(ctx, "add"), ctx)

    assert added.status == 200

    assert body(added) == %{
             "action" => "add",
             "issue_identifier" => ctx.ticket.issue_identifier,
             "blocker" => ctx.blocker.issue_identifier,
             "blockers" => [%{"issue_identifier" => ctx.blocker.issue_identifier, "title" => "Fix", "state" => "Todo"}]
           }

    record = ctx.ticket.issue_id |> RunStore.get_ticket_state() |> TicketState.normalize()
    assert [%{identifier: identifier}] = record.blockers
    assert identifier == ctx.blocker.issue_identifier
    assert [%{waits_on: %{identifier: ^identifier}}] = TicketState.pause_reasons(record)

    removed = post_blocker(params(ctx, "remove"), ctx)
    assert removed.status == 200
    assert body(removed)["blockers"] == []
    assert TicketState.pause_reasons(ctx.ticket.issue_id |> RunStore.get_ticket_state() |> TicketState.normalize()) == []
  end

  test "POST /control/blocker answers each refusal with a 409 the app shows", ctx do
    itself = post_blocker(params(ctx, "add", ctx.ticket.issue_identifier), ctx)
    assert itself.status == 409
    assert body(itself) == %{"error" => %{"code" => "move_not_allowed", "message" => "#{ctx.ticket.issue_identifier} can't block itself."}}

    untracked = post_blocker(params(ctx, "add", "ZZZ-404"), ctx)
    assert untracked.status == 409
    assert body(untracked)["error"]["message"] =~ "Symphony doesn't track ZZZ-404"

    assert post_blocker(params(ctx, "add"), ctx).status == 200
    reverse = %{"issue_identifier" => ctx.blocker.issue_identifier, "blocker" => ctx.ticket.issue_identifier, "action" => "add"}
    cycle = post_blocker(reverse, ctx)
    assert cycle.status == 409
    assert body(cycle)["error"]["message"] =~ "would make a cycle"
  end

  test "POST /control/blocker refuses a missing parameter or an unknown action", ctx do
    for {params, message} <- [
          {Map.delete(params(ctx, "add"), "blocker"), "blocker is required"},
          {Map.delete(params(ctx, "add"), "issue_identifier"), "issue_identifier is required"},
          {params(ctx, "toggle"), "action must be add or remove"}
        ] do
      conn = post_blocker(params, ctx)
      assert conn.status == 422
      assert body(conn) == %{"error" => %{"code" => "invalid_request", "message" => message}}
    end
  end

  test "POST /control/blocker answers 502 when Linear refuses the write", ctx do
    Process.put(:linker_reply, {:error, :issue_relation_failed})
    conn = post_blocker(params(ctx, "add"), ctx)
    assert conn.status == 502
    assert body(conn)["error"]["code"] == "linear_error"
  end

  test "POST /control/blocker needs the control token like the other control routes", ctx do
    conn =
      conn(:post, "/api/v1/control/blocker", Jason.encode!(params(ctx, "add")))
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 401
  end

  test "GET /tickets/:identifier/blockers lists the blockers and the candidates, 404 for an untracked ticket", ctx do
    conn = get_blockers(ctx.ticket.issue_identifier, ctx)
    assert conn.status == 200

    assert body(conn) == %{
             "issue_identifier" => ctx.ticket.issue_identifier,
             "blockers" => [],
             "candidates" => [%{"issue_identifier" => ctx.blocker.issue_identifier, "title" => "Fix", "state" => "Todo"}]
           }

    routed = conn(:get, "/api/v1/tickets/#{ctx.ticket.issue_identifier}/blockers") |> Router.call(Router.init([]))
    assert routed.status == 200
    assert body(routed)["issue_identifier"] == ctx.ticket.issue_identifier

    missing = get_blockers("ZZZ-404", ctx)
    assert missing.status == 404
    assert body(missing)["error"]["code"] == "ticket_not_found"
  end
end
