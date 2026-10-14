defmodule SymphonyElixir.ConnectedTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Connected
  alias SymphonyElixir.Linear.Issue

  @parent %{identifier: "MT-1", title: "Epic", done: 1, total: 2, children: ["completed", "started"]}

  test "build takes blockers and sub-tickets from the polled issue, the parent and links from what the run read" do
    issue = %Issue{
      id: "issue-2",
      identifier: "MT-2",
      blocked_by: [%{id: "b", identifier: "MT-3", state: "In Progress"}, %{id: "x", identifier: nil, state: "Todo"}],
      sub_issues: [%{id: "s", identifier: "MT-4", state: "Todo"}]
    }

    linked = %{
      parent: @parent,
      linked_issues: [
        %{relation: "blocks", identifier: "MT-5", title: "Next", state: "Todo"},
        %{relation: "related", identifier: "MT-6", title: "Context", state: "Done"}
      ]
    }

    assert Connected.build(issue, linked) == %{
             parent: @parent,
             sub_tickets: [%{identifier: "MT-4", title: nil, state: "Todo"}],
             blocked_by: [%{identifier: "MT-3", title: nil, state: "In Progress"}],
             blocks: [%{identifier: "MT-5", title: "Next", state: "Todo"}],
             related: [%{identifier: "MT-6", title: "Context", state: "Done"}]
           }
  end

  test "build without what a run read uses the issue's own parent and links" do
    related = [%{relation: "related", identifier: "MT-6", title: nil, state: nil}]
    issue = %Issue{identifier: "MT-2", parent: @parent, linked_issues: related}

    assert %{parent: @parent, related: [%{identifier: "MT-6"}], blocks: [], blocked_by: [], sub_tickets: []} = Connected.build(issue, nil)
    assert Connected.build(%{identifier: "MT-2"}, nil) == %{parent: nil, sub_tickets: [], blocked_by: [], blocks: [], related: []}
  end

  test "linked keeps an enriched issue's parent and links" do
    links = [%{relation: "blocks", identifier: "MT-5", title: "Next", state: "Todo"}]

    assert Connected.linked(%Issue{parent: @parent, linked_issues: links}) == %{parent: @parent, linked_issues: links}
    assert Connected.linked(%Issue{}) == %{parent: nil, linked_issues: []}
  end

  test "parent orders the sub-tickets by creation and leaves canceled ones out" do
    node = %{
      "identifier" => "MT-1",
      "title" => "Epic",
      "children" => %{
        "nodes" => [
          %{"createdAt" => "2026-10-02T00:00:00Z", "state" => %{"type" => "started"}},
          %{"createdAt" => "2026-10-03T00:00:00Z", "state" => %{"type" => "canceled"}},
          %{"createdAt" => "2026-10-01T00:00:00Z", "state" => %{"type" => "completed"}},
          %{"state" => %{"type" => "backlog"}}
        ]
      }
    }

    assert Connected.parent(node) == %{identifier: "MT-1", title: "Epic", done: 1, total: 3, children: ["backlog", "completed", "started"]}
    assert Connected.parent(%{"identifier" => "MT-1"}) == %{identifier: "MT-1", title: nil, done: 0, total: 0, children: []}
    assert Connected.parent(nil) == nil
    assert Connected.parent(%{"title" => "No identifier"}) == nil
  end
end
