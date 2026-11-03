defmodule SymphonyElixirWeb.TicketLabelsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{RunStore, TicketState}
  alias SymphonyElixirWeb.{ControlApiController, Router, TicketLabelsController}

  @moduletag :tmp_dir

  defmodule Writer do
    @moduledoc false
    def add_issue_label(_issue_id, _label), do: Process.get(:tracker_reply, :ok)
    def remove_issue_label(_issue_id, _label), do: Process.get(:tracker_reply, :ok)
  end

  setup do
    n = System.unique_integer([:positive])
    repo = "labels-api-#{n}"
    ticket = %{repo_key: repo, issue_id: "issue-#{n}", issue_identifier: "LAPI-#{n}", phase: "Code Review", title: "Export", labels: []}
    :ok = RunStore.put_ticket_state(ticket)
    %{repo: repo, ticket: ticket}
  end

  defp settings, do: [escalate_labels: ["needs-human"], force_label: "expedite"]

  defp post_label(params, ctx) do
    conn(:post, "/api/v1/control/label", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> assign(:orchestrator, self())
    |> assign(:audit_log, dir: ctx.tmp_dir)
    |> assign(:director_labels, [tracker: Writer, records: RunStore.list_ticket_states(ctx.repo)] ++ settings())
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> ControlApiController.label(params)
  end

  defp get_labels(identifier, ctx) do
    conn(:get, "/api/v1/tickets/#{identifier}/labels")
    |> assign(:director_labels, [records: RunStore.list_ticket_states(ctx.repo)] ++ settings())
    |> TicketLabelsController.index(%{"issue_identifier" => identifier})
  end

  defp params(ctx, label, action), do: %{"issue_identifier" => ctx.ticket.issue_identifier, "label" => label, "action" => action}

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp labels(ctx), do: (ctx.ticket.issue_id |> RunStore.get_ticket_state() |> TicketState.normalize()).labels

  defp on(body), do: for(%{"on" => true, "label" => label} <- body["labels"], do: label)

  test "POST /control/label turns Skip QA on then off, answering the ticket's toggles each time", ctx do
    added = post_label(params(ctx, "qa:skip", "add"), ctx)
    assert added.status == 200
    assert body(added)["action"] == "add_label"
    assert body(added)["issue_identifier"] == ctx.ticket.issue_identifier
    assert on(body(added)) == ["qa:skip"]
    assert %{"label" => "qa:skip", "title" => "Skip QA", "effect" => _effect, "on" => true} = Enum.at(body(added)["labels"], 3)
    assert labels(ctx) == ["qa:skip"]

    removed = post_label(params(ctx, "qa:skip", "remove"), ctx)
    assert removed.status == 200
    assert body(removed)["action"] == "remove_label"
    assert on(body(removed)) == []
    assert labels(ctx) == []
  end

  test "POST /control/label refuses a label Symphony doesn't read with a 409 and a bad request with a 422", ctx do
    machine = post_label(params(ctx, "Blocked", "add"), ctx)
    assert machine.status == 409
    assert body(machine)["error"]["code"] == "move_not_allowed"
    assert body(machine)["error"]["message"] =~ "Blocked is Symphony's own label"

    other = post_label(params(ctx, "frontend", "add"), ctx)
    assert other.status == 409
    assert body(other)["error"]["message"] =~ "isn't a label Symphony reads"

    for {params, message} <- [
          {Map.delete(params(ctx, "plan", "add"), "label"), "label is required"},
          {Map.delete(params(ctx, "plan", "add"), "issue_identifier"), "issue_identifier is required"},
          {params(ctx, "plan", "toggle"), "action must be add or remove"}
        ] do
      conn = post_label(params, ctx)
      assert conn.status == 422
      assert body(conn) == %{"error" => %{"code" => "invalid_request", "message" => message}}
    end

    assert labels(ctx) == []
  end

  @tag :capture_log
  test "POST /control/label answers 502 when Linear refuses the write", ctx do
    Process.put(:tracker_reply, {:error, :issue_update_failed})
    conn = post_label(params(ctx, "plan", "add"), ctx)
    assert conn.status == 502
    assert body(conn)["error"] == %{"code" => "linear_error", "message" => "Linear didn't turn on Plan on #{ctx.ticket.issue_identifier}, so nothing changed. Try again in a moment."}
    assert labels(ctx) == []
  end

  test "POST /control/label needs the control token like the other control routes", ctx do
    conn =
      conn(:post, "/api/v1/control/label", Jason.encode!(params(ctx, "plan", "add")))
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 401
  end

  test "GET /tickets/:identifier/labels reads the toggles from the record, 404 for an untracked ticket", ctx do
    conn = get_labels(ctx.ticket.issue_identifier, ctx)
    assert conn.status == 200
    assert body(conn)["issue_identifier"] == ctx.ticket.issue_identifier

    assert Enum.map(body(conn)["labels"], & &1["label"]) ==
             ~w(plan type:bug type:feature qa:skip skip-update-hold qa:live qa:fixture needs-human)

    assert on(body(conn)) == []

    routed = conn(:get, "/api/v1/tickets/#{ctx.ticket.issue_identifier}/labels") |> Router.call(Router.init([]))
    assert routed.status == 200
    assert hd(body(routed)["labels"])["label"] == "plan"

    missing = get_labels("ZZZ-404", ctx)
    assert missing.status == 404
    assert body(missing)["error"]["code"] == "ticket_not_found"
  end
end
