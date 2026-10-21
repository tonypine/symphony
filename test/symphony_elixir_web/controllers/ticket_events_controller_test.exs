defmodule SymphonyElixirWeb.TicketEventsControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.TicketEvents

  @endpoint SymphonyElixirWeb.Endpoint
  @repo_key "repo-a"
  @issue_id "issue-1"
  @path "/api/v1/repos/repo-a/tickets/TP-1/events"
  @base ~U[2026-10-18 10:00:00.000000Z]

  setup do
    :ok = RunStore.clear()

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "TP-1"})
    :ok
  end

  test "lists a ticket's events oldest first, each with its summary, and filters them by type" do
    record!("verdict.recorded", %{kind: "qa", outcome: "pass", head: "abc1234"}, at(3))
    record!("phase.entered", %{to: "QA", from: "Code Review"}, at(1))
    record!("run.started", %{run_id: "run-1", run_kind: "qa", run_number: 1}, at(2), run_id: "run-1")

    body = json_response(get(build_conn(), @path), 200)

    assert [entered, started, verdict] = body["events"]
    assert %{"type" => "phase.entered", "seq" => 2, "summary" => %{"title" => "Entered QA from Code Review"}, "actor" => %{"kind" => "machine"}} = entered
    assert %{"type" => "run.started", "run_id" => "run-1", "summary" => %{"title" => "QA run 1 started"}} = started
    assert %{"type" => "verdict.recorded", "payload" => %{"kind" => "qa", "outcome" => "pass"}, "summary" => %{"title" => "QA verdict: pass"}} = verdict
    assert verdict["at"] == DateTime.to_iso8601(at(3))
    assert body["next_since"] == verdict["at"]

    assert %{"events" => [%{"type" => "verdict.recorded"}]} = json_response(get(build_conn(), @path <> "?types=verdict.recorded"), 200)

    assert %{"events" => [%{"type" => "phase.entered"}, %{"type" => "verdict.recorded"}]} =
             json_response(get(build_conn(), @path <> "?types=verdict.recorded,%20phase.entered"), 200)

    assert %{"events" => [%{"run_id" => "run-1"}]} = json_response(get(build_conn(), @path <> "?run_id=run-1"), 200)
    assert %{"events" => [_, _, _]} = json_response(get(build_conn(), @path <> "?run_id[]=run-1&types=&since=&limit="), 200)
  end

  test "paging with next_since returns every event exactly once" do
    for minute <- [1, 2, 2, 2, 3, 4, 5], do: record!("note", %{text: "at #{minute}"}, at(minute))

    pages = page([], nil)

    assert Enum.map(pages, &length/1) == [4, 2, 1]
    assert pages |> List.flatten() |> Enum.map(& &1["seq"]) |> Enum.sort() == Enum.to_list(1..7)

    since = DateTime.to_iso8601(at(5))
    assert %{"events" => [], "next_since" => ^since} = json_response(get(build_conn(), @path <> "?since=#{since}"), 200)
  end

  test "caps a page at 200 events" do
    for n <- 1..201, do: record!("note", %{text: "note #{n}"}, DateTime.add(@base, n, :second))

    assert %{"events" => events} = json_response(get(build_conn(), @path <> "?limit=500"), 200)
    assert length(events) == 200
    assert %{"events" => events} = json_response(get(build_conn(), @path), 200)
    assert length(events) == 50
  end

  test "an unknown ticket is 404" do
    assert %{"error" => %{"code" => "ticket_not_found"}} = json_response(get(build_conn(), "/api/v1/repos/repo-a/tickets/TP-404/events"), 404)
    assert %{"error" => %{"code" => "ticket_not_found"}} = json_response(get(build_conn(), "/api/v1/repos/repo-b/tickets/TP-1/events"), 404)
    assert %{"error" => %{"code" => "ticket_not_found"}} = json_response(get(build_conn(), "/api/v1/repos/%20/tickets/TP-1/events"), 404)
  end

  test "an unknown type, a bad since or a bad limit is 400, and other methods are 405" do
    for query <- ["types=verdict.recorded,bogus", "types[]=note", "since=yesterday", "since[]=x", "limit=0", "limit=ten", "limit[]=1"] do
      assert %{"error" => %{"code" => "invalid_query", "message" => message}} = json_response(get(build_conn(), @path <> "?" <> query), 400)
      assert is_binary(message)
    end

    assert %{"error" => %{"message" => "Unknown event type(s): bogus"}} = json_response(get(build_conn(), @path <> "?types=bogus"), 400)
    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(post(build_conn(), @path, %{}), 405)
  end

  defp page(pages, since) do
    query = if since, do: "?limit=2&since=#{URI.encode_www_form(since)}", else: "?limit=2"

    case json_response(get(build_conn(), @path <> query), 200) do
      %{"events" => []} -> Enum.reverse(pages)
      %{"events" => events, "next_since" => next_since} -> page([events | pages], next_since)
    end
  end

  defp record!(type, payload, at, opts \\ []) do
    {:ok, _event} = TicketEvents.record(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, at))
  end

  defp at(minute), do: DateTime.add(@base, minute * 60, :second)
end
