defmodule SymphonyElixirWeb.TicketFactsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias SymphonyElixir.{RunStore, TicketEvents}
  alias SymphonyElixirWeb.TicketFactsController

  setup do
    n = System.unique_integer([:positive])
    ticket = %{repo_key: "facts-api-#{n}", issue_id: "issue-facts-api-#{n}", issue_identifier: "FAPI-#{n}", phase: "QA", title: "Export"}
    :ok = RunStore.put_ticket_state(ticket)
    %{ticket: ticket}
  end

  defp get_facts(identifier, params) do
    conn(:get, "/api/v1/tickets/#{identifier}/facts")
    |> Plug.Conn.assign(:conductor_facts, diff_stat: fn _record -> nil end, token_cap: 100)
    |> TicketFactsController.show(Map.put(params, "issue_identifier", identifier))
  end

  test "answers the ticket's facts for the junction", %{ticket: ticket} do
    {:ok, ended} = TicketEvents.record(ticket.repo_key, ticket.issue_id, "run.ended", %{run_id: "run-1", run_kind: "implementation", exit: "normal"}, run_id: "run-1")

    conn = get_facts(ticket.issue_identifier, %{"junction" => "after_coding"})

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"junction" => "after_coding", "ticket" => %{"title" => "Export"}, "standing" => %{"phase" => "QA"}, "budget" => %{"tokens_cap" => 100}} = body
    assert body["last_run"]["event_id"] == ended.id
  end

  test "is 404 for a ticket Symphony keeps no record of and 400 for a junction that is not one", %{ticket: ticket} do
    assert %{status: 404, resp_body: missing} = get_facts("NOPE-0", %{})
    assert %{"error" => %{"code" => "ticket_not_found"}} = Jason.decode!(missing)

    assert %{status: 400, resp_body: invalid} = get_facts(ticket.issue_identifier, %{"junction" => "someday"})
    assert %{"error" => %{"code" => "invalid_query"}} = Jason.decode!(invalid)
  end

  test "the router serves it, and answers 405 to another method" do
    assert %{status: 404} = conn(:get, "/api/v1/tickets/NOPE-0/facts") |> SymphonyElixirWeb.Router.call(SymphonyElixirWeb.Router.init([]))
    assert %{status: 405} = conn(:post, "/api/v1/tickets/NOPE-0/facts") |> SymphonyElixirWeb.Router.call(SymphonyElixirWeb.Router.init([]))
  end
end
