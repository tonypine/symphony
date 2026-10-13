defmodule SymphonyElixirWeb.ObservabilityShippedTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.RunStore

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok
  end

  test "GET /api/v1/shipped serves the tickets merged in the period from the run records" do
    now = DateTime.utc_now()
    repo_key = Config.repo_key!()

    :ok =
      RunStore.put_run(%{
        repo_key: repo_key,
        run_id: "shipped-run-1",
        issue_id: "shipped-issue-1",
        issue_identifier: "SHP-1",
        title: "Ship it",
        status: "success",
        pull_request_url: "https://github.com/acme/app/pull/9",
        initiative: %{identifier: "SHP-0", title: "Launch"},
        started_at: DateTime.add(now, -3600, :second),
        issue_completed_notified_at: now
      })

    :ok = RunStore.record_ticket_signal(repo_key, "shipped-issue-1", "claim", %{from: "Todo", to: "In Progress"})

    body = json_response(get(build_conn(), "/api/v1/shipped?days=2"), 200)

    assert %{"days" => 2, "shipped_per_day" => [_, %{"shipped" => shipped}], "tickets" => tickets} = body
    assert shipped >= 1

    assert %{
             "repo_key" => ^repo_key,
             "initiative" => %{"identifier" => "SHP-0", "title" => "Launch"},
             "pr_url" => "https://github.com/acme/app/pull/9",
             "todo_to_done_seconds" => seconds
           } = Enum.find(tickets, &(&1["identifier"] == "SHP-1"))

    assert seconds >= 0
  end

  test "GET /api/v1/shipped rejects an invalid days value and other methods" do
    assert %{"error" => %{"code" => "invalid_days"}} = json_response(get(build_conn(), "/api/v1/shipped?days=91"), 400)
    assert json_response(post(build_conn(), "/api/v1/shipped", %{}), 405)
  end

  test "GET /api/v1/learnings serves the stored learnings, filtered by repo, tag and text" do
    repo_key = Config.repo_key!()
    now = DateTime.utc_now()

    learning = fn id, rule, tags, created_at ->
      %{
        repo_key: repo_key,
        id: id,
        host: "github.com",
        owner: "acme",
        repo: "app",
        rule: rule,
        tags: tags,
        evidence_quote: "Quote for #{id}.",
        evidence_issue_identifier: "LRN-1",
        evidence_issue_url: "https://linear.app/acme/issue/LRN-1",
        evidence_pr_number: 7,
        evidence_run_id: "run-#{id}",
        created_at: created_at
      }
    end

    :ok =
      RunStore.put_learnings(
        [
          learning.("api-learning-1", "Seed the ledger first.", ["migrations"], now),
          learning.("api-learning-2", "Keep fixtures small.", ["testing"], DateTime.add(now, -60, :second))
        ],
        500
      )

    body = json_response(get(build_conn(), "/api/v1/learnings"), 200)
    assert ["api-learning-1", "api-learning-2"] = body["records"] |> Enum.map(& &1["id"]) |> Enum.filter(&String.starts_with?(&1, "api-learning"))
    assert repo_key in body["repos"]
    assert "migrations" in body["tags"]

    body = json_response(get(build_conn(), "/api/v1/learnings?repo=#{repo_key}&tag=testing&q=FIXTURES"), 200)

    assert [%{"id" => "api-learning-2", "pr_url" => "https://github.com/acme/app/pull/7", "issue_url" => "https://linear.app/acme/issue/LRN-1"}] =
             body["records"]

    assert json_response(post(build_conn(), "/api/v1/learnings", %{}), 405)
  end
end
