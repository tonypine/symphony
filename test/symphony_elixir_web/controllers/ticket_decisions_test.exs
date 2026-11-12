defmodule SymphonyElixirWeb.TicketDecisionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{Decisions, RunStore}
  alias SymphonyElixirWeb.{ControlApiController, Router, TicketDecisionsController}

  @moduletag :tmp_dir

  defmodule Tracker do
    @moduledoc false
    def fetch_issue_description(_issue_id), do: Process.get(:description_reply, {:ok, "Ship the export."})
    def update_issue_description(_issue_id, _description), do: :ok
  end

  setup do
    n = System.unique_integer([:positive])
    repo = "decisions-api-#{n}"
    ticket = %{repo_key: repo, issue_id: "issue-#{n}", issue_identifier: "DAPI-#{n}", phase: "In Progress", title: "Export"}
    :ok = RunStore.put_ticket_state(ticket)
    %{repo: repo, ticket: ticket}
  end

  defp post_decision(params, ctx) do
    conn(:post, "/api/v1/control/decision", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> assign(:orchestrator, self())
    |> assign(:audit_log, dir: ctx.tmp_dir)
    |> assign(:director_rulings, tracker: Tracker, records: RunStore.list_ticket_states(ctx.repo))
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> ControlApiController.decision(params)
  end

  defp get_decisions(identifier, ctx, tag \\ nil) do
    conn(:get, "/api/v1/tickets/#{identifier}/decisions")
    |> then(&if(tag, do: put_req_header(&1, "if-none-match", tag), else: &1))
    |> assign(:director_rulings, records: RunStore.list_ticket_states(ctx.repo))
    |> TicketDecisionsController.index(%{"issue_identifier" => identifier})
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp stored(ticket), do: Decisions.stored(%{id: ticket.issue_id, repo_key: ticket.repo_key, description: nil})

  test "POST /control/decision records the ruling and answers the ticket's decisions", ctx do
    text = "Keep the old endpoint until TP-1400 lands"
    conn = post_decision(%{"issue_identifier" => ctx.ticket.issue_identifier, "text" => text}, ctx)

    assert conn.status == 200
    assert %{"action" => "record_decision", "issue_identifier" => identifier, "decisions" => [decision]} = body(conn)
    assert identifier == ctx.ticket.issue_identifier
    assert %{"id" => "D1", "title" => "Ruling by the Director", "answer" => ^text, "scope" => "As answered", "date" => _date, "question" => _question} = decision
    assert [%{answer: ^text}] = stored(ctx.ticket)

    read = get_decisions(ctx.ticket.issue_identifier, ctx)
    assert read.status == 200
    assert body(read)["decisions"] == body(conn)["decisions"]
  end

  test "GET decisions answers 304 with no body while the decisions are unchanged, and in full once one is recorded", ctx do
    identifier = ctx.ticket.issue_identifier
    first = get_decisions(identifier, ctx)
    assert first.status == 200
    [tag] = get_resp_header(first, "etag")

    unchanged = get_decisions(identifier, ctx, tag)
    assert unchanged.status == 304
    assert unchanged.resp_body == ""
    assert get_resp_header(unchanged, "etag") == [tag]

    assert post_decision(%{"issue_identifier" => identifier, "text" => "Keep the old endpoint"}, ctx).status == 200

    answered = get_decisions(identifier, ctx, tag)
    assert answered.status == 200
    assert [%{"answer" => "Keep the old endpoint"}] = body(answered)["decisions"]
    assert get_resp_header(answered, "etag") != [tag]
  end

  test "POST /control/decision refuses an empty text with 400, writing nothing", ctx do
    for text <- ["", "  ", nil] do
      conn = post_decision(%{"issue_identifier" => ctx.ticket.issue_identifier, "text" => text}, ctx)
      assert conn.status == 400
      assert body(conn)["error"] == %{"code" => "invalid_decision", "message" => "A decision needs text"}
    end

    assert stored(ctx.ticket) == []
  end

  test "POST /control/decision answers 422, 409 and 502 as the ruling is refused", ctx do
    missing = post_decision(%{"text" => "Keep it"}, ctx)
    assert missing.status == 422
    assert body(missing)["error"] == %{"code" => "invalid_request", "message" => "issue_identifier is required"}

    untracked = post_decision(%{"issue_identifier" => "NOPE-1", "text" => "Keep it"}, ctx)
    assert untracked.status == 409
    assert body(untracked)["error"]["code"] == "move_not_allowed"
    assert body(untracked)["error"]["message"] =~ "doesn't track NOPE-1"

    Process.put(:description_reply, {:error, :timeout})

    capture_log(fn ->
      refused = post_decision(%{"issue_identifier" => ctx.ticket.issue_identifier, "text" => "Keep it"}, ctx)
      assert refused.status == 502
      assert body(refused)["error"]["code"] == "linear_error"
    end)
  end

  test "GET /tickets/:id/decisions is 404 for a ticket Symphony doesn't track", ctx do
    conn = get_decisions("NOPE-1", ctx)
    assert conn.status == 404
    assert body(conn)["error"]["code"] == "ticket_not_found"
  end

  test "GET /tickets/:id/decisions answers through the router, from every tracked record", ctx do
    conn = conn(:get, "/api/v1/tickets/#{ctx.ticket.issue_identifier}/decisions") |> Router.call(Router.init([]))
    assert conn.status == 200
    assert body(conn) == %{"issue_identifier" => ctx.ticket.issue_identifier, "decisions" => []}
  end

  test "the routes reach the controllers" do
    assert %{plug: ControlApiController, plug_opts: :decision} = Phoenix.Router.route_info(Router, "POST", "/api/v1/control/decision", "")
    assert %{plug: TicketDecisionsController, plug_opts: :index} = Phoenix.Router.route_info(Router, "GET", "/api/v1/tickets/X-1/decisions", "")
    assert %{plug_opts: :method_not_allowed} = Phoenix.Router.route_info(Router, "PUT", "/api/v1/tickets/X-1/decisions", "")
  end
end
