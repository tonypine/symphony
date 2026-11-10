defmodule SymphonyElixirWeb.AggregateReadTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 2]

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

    :ok =
      RunStore.put_ticket_state(%{
        repo_key: @repo,
        issue_id: "child",
        issue_identifier: "FIX-2",
        title: "A sub-ticket",
        phase: "In Progress",
        parent: %{identifier: "FIX-1", title: "The epic"}
      })

    :ok
  end

  defp get_aggregate(query) do
    conn = get(build_conn(), "/api/v1/aggregate?" <> URI.encode_query(query))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "reads an epic's verdicts by day over a week, every day a bucket" do
    :ok = put_verdict(@repo, "child", "code_review", "abc", "approve", %{}, ~U[2026-11-05 09:00:00Z])

    {200, body} = get_aggregate(%{from: "2026-11-03", to: "2026-11-09", epic: "FIX-1", series: "verdicts,shipped"})

    assert %{"from" => "2026-11-03T00:00:00Z", "to" => "2026-11-10T00:00:00Z", "unit" => "day", "epic" => "FIX-1", "repo" => nil} = body
    assert Map.keys(body["series"]) |> Enum.sort() == ["shipped", "verdicts"]

    verdicts = body["series"]["verdicts"]
    assert %{"total" => 1, "by" => %{"code_review:approve" => 1}, "tickets" => %{"FIX-2" => 1}} = verdicts
    assert length(verdicts["buckets"]) == 7
    assert %{"start" => "2026-11-05T00:00:00Z", "end" => "2026-11-06T00:00:00Z", "value" => 1} = Enum.at(verdicts["buckets"], 2)
  end

  test "a malformed query is 400 and other methods are refused" do
    assert {400, %{"error" => %{"code" => "invalid_query", "message" => "Unknown series: spend"}}} = get_aggregate(%{series: "spend"})
    assert {400, %{"error" => %{"code" => "invalid_query"}}} = get_aggregate(%{unit: "2h"})

    assert post(build_conn(), "/api/v1/aggregate").status == 405
  end
end
