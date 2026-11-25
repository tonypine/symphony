defmodule SymphonyElixirWeb.TicketBlockersTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{RunStore, TicketState}
  alias SymphonyElixirWeb.{ControlApiController, Router, TicketBlockersController}

  @moduletag :tmp_dir

  setup do
    n = System.unique_integer([:positive])
    repo = "blocker-api-#{n}"
    ticket = %{repo_key: repo, issue_id: "issue-#{n}-1", issue_identifier: "API-#{n}1", phase: "Todo", title: "Export"}
    blocker = %{repo_key: repo, issue_id: "issue-#{n}-2", issue_identifier: "API-#{n}2", phase: "Todo", title: "Fix"}
    :ok = RunStore.put_ticket_state(ticket)
    :ok = RunStore.put_ticket_state(blocker)
    %{repo: repo, ticket: ticket, blocker: blocker}
  end

  defp post_blocker(params, ctx, records \\ nil), do: post_control("/api/v1/control/blocker", &ControlApiController.blocker/2, params, ctx, records)

  defp post_dependency(params, ctx, records \\ nil), do: post_control("/api/v1/control/dependency", &ControlApiController.dependency/2, params, ctx, records)

  defp post_control(path, action, params, ctx, records) do
    conn(:post, path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> assign(:orchestrator, forwarding_orchestrator())
    |> assign(:audit_log, dir: ctx.tmp_dir)
    |> assign(:director_blockers, records: records || RunStore.list_ticket_states(ctx.repo))
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> action.(params)
  end

  # An orchestrator that answers a queue change and tells the test of it, and drops the rest.
  defp forwarding_orchestrator do
    parent = self()
    spawn_link(fn -> forward(parent) end)
  end

  defp forward(parent) do
    receive do
      {:"$gen_call", from, :queue_changed} ->
        send(parent, :queue_changed)
        GenServer.reply(from, :ok)

      _message ->
        :ok
    end

    forward(parent)
  end

  defp dependency_params(ctx, action, kind, on \\ nil) do
    params = %{"issue_identifier" => ctx.ticket.issue_identifier, "on" => on || ctx.blocker.issue_identifier, "action" => action}
    if kind, do: Map.put(params, "kind", kind), else: params
  end

  defp stored(ticket), do: (ticket.issue_id |> RunStore.get_ticket_state() |> TicketState.normalize()).depends_on

  defp get_blockers(identifier, ctx) do
    conn(:get, "/api/v1/tickets/#{identifier}/blockers")
    |> assign(:director_blockers, records: RunStore.list_ticket_states(ctx.repo))
    |> TicketBlockersController.index(%{"issue_identifier" => identifier})
  end

  defp params(ctx, action, blocker \\ nil),
    do: %{"issue_identifier" => ctx.ticket.issue_identifier, "blocker" => blocker || ctx.blocker.issue_identifier, "action" => action}

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "POST /control/blocker adds and removes a stored done dependency, with no Linear write, and the list shows it", ctx do
    added = post_blocker(params(ctx, "add"), ctx)

    assert added.status == 200

    assert body(added) == %{
             "action" => "add",
             "issue_identifier" => ctx.ticket.issue_identifier,
             "blocker" => ctx.blocker.issue_identifier,
             "blockers" => [%{"issue_identifier" => ctx.blocker.issue_identifier, "title" => "Fix", "state" => "Todo"}]
           }

    record = ctx.ticket.issue_id |> RunStore.get_ticket_state() |> TicketState.normalize()
    assert [%{issue_id: blocker_id, kind: :done}] = record.depends_on
    assert blocker_id == ctx.blocker.issue_id
    # No Linear write and no pause: the record keeps no Linear blocker at all.
    refute Map.has_key?(record, :blockers)
    assert TicketState.pause_reasons(record) == []

    listed = get_blockers(ctx.ticket.issue_identifier, ctx)
    assert body(listed)["blockers"] == [%{"issue_identifier" => ctx.blocker.issue_identifier, "title" => "Fix", "state" => "Todo"}]

    removed = post_blocker(params(ctx, "remove"), ctx)
    assert removed.status == 200
    assert body(removed)["blockers"] == []
    assert (ctx.ticket.issue_id |> RunStore.get_ticket_state() |> TicketState.normalize()).depends_on == []
    assert body(get_blockers(ctx.ticket.issue_identifier, ctx))["blockers"] == []
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

  @tag :capture_log
  test "POST /control/blocker answers 502 when the store refuses the write", ctx do
    records = RunStore.list_ticket_states(ctx.repo)
    :ok = RunStore.delete_ticket_state(ctx.ticket.issue_id)
    conn = post_blocker(params(ctx, "add"), ctx, records)
    assert conn.status == 502
    assert body(conn)["error"]["code"] == "store_error"
    assert body(conn)["error"]["message"] =~ ~r/^Symphony couldn't add \S+ as a blocker of \S+, so nothing changed\./
  end

  test "POST /control/blocker needs the control token like the other control routes", ctx do
    conn =
      conn(:post, "/api/v1/control/blocker", Jason.encode!(params(ctx, "add")))
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 401
  end

  describe "TP-1633: POST /control/dependency" do
    test "adds a done or a released dependency with the kind given, changes the kind, and removes it", ctx do
      added = post_dependency(dependency_params(ctx, "add", "released"), ctx)
      assert added.status == 200

      assert body(added) == %{
               "action" => "add_dependency",
               "issue_identifier" => ctx.ticket.issue_identifier,
               "on" => ctx.blocker.issue_identifier,
               "kind" => "released",
               "dependencies" => [%{"issue_identifier" => ctx.blocker.issue_identifier, "title" => "Fix", "state" => "Todo", "kind" => "released"}]
             }

      blocker_id = ctx.blocker.issue_id
      assert [%{issue_id: ^blocker_id, kind: :released}] = stored(ctx.ticket)

      assert post_dependency(dependency_params(ctx, "add", "done"), ctx).status == 200
      assert [%{issue_id: ^blocker_id, kind: :done}] = stored(ctx.ticket)

      # The same kind again is refused, as the blocker route refuses a blocker already there.
      twice = post_dependency(dependency_params(ctx, "add", "done"), ctx)
      assert twice.status == 409
      assert body(twice)["error"]["message"] == "#{ctx.ticket.issue_identifier} already depends on #{ctx.blocker.issue_identifier} being done."

      removed = post_dependency(dependency_params(ctx, "remove", nil), ctx)
      assert removed.status == 200
      assert %{"action" => "remove_dependency", "kind" => nil, "dependencies" => []} = body(removed)
      assert stored(ctx.ticket) == []
    end

    test "the add on a ticket that sits lower moves the waiting ticket just below it in the same request", ctx do
      places = RunStore.queue_places()
      assert Map.fetch!(places, ctx.ticket.issue_id) < Map.fetch!(places, ctx.blocker.issue_id)

      assert post_dependency(dependency_params(ctx, "add", "done"), ctx).status == 200
      places = RunStore.queue_places()
      assert Map.fetch!(places, ctx.ticket.issue_id) > Map.fetch!(places, ctx.blocker.issue_id)
      assert_receive :queue_changed
    end

    test "a missing parameter, or a missing or unknown kind on an add, is a 422; an untracked ticket a 409", ctx do
      for {params, message} <- [
            {Map.delete(dependency_params(ctx, "add", "done"), "on"), "on is required"},
            {Map.delete(dependency_params(ctx, "add", "done"), "issue_identifier"), "issue_identifier is required"},
            {dependency_params(ctx, "toggle", "done"), "action must be add or remove"},
            {dependency_params(ctx, "add", nil), "kind must be done or released"},
            {dependency_params(ctx, "add", "merged"), "kind must be done or released"}
          ] do
        conn = post_dependency(params, ctx)
        assert conn.status == 422, inspect(params)
        assert body(conn) == %{"error" => %{"code" => "invalid_request", "message" => message}}
      end

      untracked = post_dependency(dependency_params(ctx, "add", "done", "ZZZ-404"), ctx)
      assert untracked.status == 409
      assert body(untracked)["error"]["message"] =~ "Symphony doesn't track ZZZ-404"
      assert stored(ctx.ticket) == []
    end

    @tag :capture_log
    test "answers 502 when the store refuses the write", ctx do
      records = RunStore.list_ticket_states(ctx.repo)
      :ok = RunStore.delete_ticket_state(ctx.ticket.issue_id)
      conn = post_dependency(dependency_params(ctx, "add", "done"), ctx, records)
      assert conn.status == 502
      assert body(conn)["error"]["message"] =~ ~r/^Symphony couldn't add the dependency of \S+ on \S+, so nothing changed\./
    end

    test "needs the control token like the other control routes", ctx do
      conn =
        conn(:post, "/api/v1/control/dependency", Jason.encode!(dependency_params(ctx, "add", "done")))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 401
    end
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
