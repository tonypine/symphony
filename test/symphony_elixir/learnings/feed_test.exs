defmodule SymphonyElixir.Learnings.FeedTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Learnings.Feed

  @now ~U[2026-10-13 12:00:00Z]

  defp record(id, repo_key, minutes_ago, attrs) do
    Map.merge(
      %{
        id: id,
        repo_key: repo_key,
        host: "github.com",
        owner: "acme",
        repo: repo_key,
        rule: "Rule #{id}.",
        tags: [],
        evidence_quote: "Quote #{id}.",
        evidence_issue_identifier: nil,
        evidence_pr_number: nil,
        evidence_run_id: nil,
        created_at: DateTime.add(@now, -minutes_ago * 60, :second)
      },
      attrs
    )
  end

  defp records do
    %{
      "billing" => [
        record("b1", "billing", 30, %{
          rule: "Run the ledger migration before the seed.",
          tags: ["migrations", "testing"],
          evidence_issue_identifier: "BIL-12",
          evidence_issue_url: "https://linear.app/acme/issue/BIL-12",
          evidence_pr_number: 41,
          evidence_run_id: "run-1"
        }),
        record("b2", "billing", 90, %{tags: ["testing"], evidence_quote: "Keep fixtures small."})
      ],
      "web" => [record("w1", "web", 60, %{tags: ["css"], evidence_issue_identifier: "WEB-7"})],
      "broken" => {:error, :down}
    }
  end

  defp payload(params) do
    records = records()
    Feed.payload(params, repo_keys: ["billing", "web", "broken"], list: &Map.fetch!(records, &1))
  end

  test "lists every repo's records newest first, each with its ticket and PR, and the filters' choices" do
    payload = payload(%{})

    assert payload.filters == %{repo: nil, tag: nil, q: nil}
    assert payload.repos == ["billing", "web"]
    assert payload.tags == ["css", "migrations", "testing"]
    assert Enum.map(payload.records, & &1.id) == ["b1", "w1", "b2"]

    assert hd(payload.records) == %{
             id: "b1",
             repo_key: "billing",
             repo: "github.com/acme/billing",
             rule: "Run the ledger migration before the seed.",
             tags: ["migrations", "testing"],
             evidence_quote: "Quote b1.",
             issue_identifier: "BIL-12",
             issue_url: "https://linear.app/acme/issue/BIL-12",
             pr_number: 41,
             pr_url: "https://github.com/acme/billing/pull/41",
             run_id: "run-1",
             created_at: "2026-10-13T11:30:00Z"
           }
  end

  test "filters by repo, tag and text in the rule, evidence, tags or ticket, in any case" do
    ids = fn params -> params |> payload() |> Map.fetch!(:records) |> Enum.map(& &1.id) end

    assert ids.(%{"repo" => "web"}) == ["w1"]
    assert ids.(%{"tag" => "testing"}) == ["b1", "b2"]
    assert ids.(%{"tag" => "testing", "q" => "FIXTURES"}) == ["b2"]
    assert ids.(%{"q" => "ledger"}) == ["b1"]
    assert ids.(%{"q" => "css"}) == ["w1"]
    assert ids.(%{"q" => "web-7"}) == ["w1"]
    assert ids.(%{"q" => "nothing"}) == []
    assert ids.(%{"repo" => " ", "tag" => "", "q" => nil}) == ["b1", "w1", "b2"]
    assert payload(%{"repo" => " web "}).filters.repo == "web"
  end

  test "links only trusted PRs and tickets" do
    assert Feed.pr_url(%{host: "github.com", owner: "acme", repo: "app", evidence_pr_number: 3}) == "https://github.com/acme/app/pull/3"
    assert Feed.pr_url(%{host: "github.com", owner: "acme", repo: "app", evidence_pr_number: 0}) == nil
    assert Feed.pr_url(%{host: "github.com", owner: "ac me", repo: "app", evidence_pr_number: 3}) == nil
    assert Feed.pr_url(%{host: "github.com", owner: "acme", repo: "a/p", evidence_pr_number: 3}) == nil
    assert Feed.pr_url(%{host: "evil.example", owner: "acme", repo: "app", evidence_pr_number: 3}) == nil
    assert Feed.pr_url(%{repo: "github.com/acme/app", evidence_pr_number: 4}) == "https://github.com/acme/app/pull/4"
    assert Feed.pr_url(%{repo: "acme/app", evidence_pr_number: 4}) == nil
    assert Feed.pr_url(%{repo: "app"}) == nil

    assert Feed.issue_url(%{evidence_issue_url: " https://linear.app/acme/issue/A-1 "}) == "https://linear.app/acme/issue/A-1"
    assert Feed.issue_url(%{evidence_issue_url: "https://LINEAR.app/acme/issue/A-1"}) == "https://LINEAR.app/acme/issue/A-1"
    assert Feed.issue_url(%{evidence_issue_url: "http://linear.app/acme/issue/A-1"}) == nil
    assert Feed.issue_url(%{evidence_issue_url: "https://x@linear.app/acme/issue/A-1"}) == nil
    assert Feed.issue_url(%{evidence_issue_url: "https://linear.example/acme/issue/A-1"}) == nil
    assert Feed.issue_url(%{evidence_issue_url: "https:/no-host"}) == nil
    assert Feed.issue_url(%{evidence_issue_url: ""}) == nil
    assert Feed.issue_url(%{}) == nil

    assert Feed.repo_label(%{host: "github.com", owner: "acme", repo: "app"}) == "github.com/acme/app"
    assert Feed.repo_label(%{repo: "github.com/acme/app"}) == "github.com/acme/app"
    assert Feed.repo_label(%{}) == nil
  end
end
