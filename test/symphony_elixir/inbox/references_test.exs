defmodule SymphonyElixir.Inbox.ReferencesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Inbox.References
  alias SymphonyElixir.IssueSummary

  @now 1_000_000

  defp item(identifier, review, attrs \\ %{}) do
    Map.merge(
      %{
        issue_id: "id-" <> identifier,
        identifier: identifier,
        title: "Title of " <> identifier,
        repo_key: "symphony",
        kind: :action,
        state: "Rework",
        ask: "Decide",
        waiting_since: nil,
        url: "https://linear.app/acme/issue/#{identifier}/title-of-it",
        review: review
      },
      attrs
    )
  end

  defp action(why), do: %{title: "Decide", why: why, options: []}

  defp pull_request(url, attrs \\ %{}) do
    Map.merge(
      %{
        number: url |> String.split("/") |> List.last() |> String.to_integer(),
        url: url,
        title: "TP-892 Remove the Final verification and Supervisor check flows",
        body: "## References\n\n- Ticket\n\n## This PR\n\nNothing changes on screen. The two old review steps are gone. More.\n\n## Stack\n\nx",
        state: "OPEN",
        review_decision: nil,
        changed_files: 12,
        additions: 120,
        deletions: 480,
        head_ref_name: "auto/TP-892",
        checks: "passed"
      },
      attrs
    )
  end

  defp ticket(identifier, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "id-" <> identifier,
        "identifier" => identifier,
        "title" => "Title of " <> identifier,
        "description" => "Part of TP-923. More text.",
        "url" => "https://linear.app/acme/issue/" <> identifier,
        "state" => %{"name" => "Todo", "type" => "unstarted"},
        "parent" => nil,
        "attachments" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      },
      attrs
    )
  end

  # A Linear stand-in answering the references query with `own` and `mentioned` nodes and reporting
  # each query's variables to the test process.
  defp linear(own, mentioned) do
    test_pid = self()

    fn query, variables, _opts ->
      assert query =~ "SymphonyInboxReferences"
      send(test_pid, {:linear, variables})
      {:ok, %{"data" => %{"own" => %{"nodes" => own}, "mentioned" => %{"nodes" => mentioned}}}}
    end
  end

  defp github(answers) do
    test_pid = self()

    fn url ->
      send(test_pid, {:github, url})
      Map.get_lazy(answers, url, fn -> {:ok, pull_request(url)} end)
    end
  end

  defp opts(linear, github, extra \\ []) do
    Keyword.merge(
      [
        linear_client: linear,
        pull_request: github,
        github_repos: %{"symphony" => "tonypine/symphony"},
        verdicts: fn _repo_key, _issue_id -> [] end,
        now_ms: @now
      ],
      extra
    )
  end

  defp resolve(items, linear, github, extra \\ []), do: References.resolve(items, %{}, opts(linear, github, extra))
  defp resolve_with(items, nodes, linear, github, extra \\ []), do: References.resolve(items, nodes, opts(linear, github, extra))

  describe "resolve/3" do
    test "resolves every ticket and pull request an item mentions, in one Linear query" do
      own_892 = %{"id" => "id-TP-892", "identifier" => "TP-892"}

      tp891 =
        ticket("TP-891", %{
          "description" => IssueSummary.start_marker() <> "\n\n**Status:** PR open, waiting on **Code Review**\n\n" <> IssueSummary.end_marker(),
          "state" => %{"name" => "In Progress", "type" => "started"},
          "parent" => %{"identifier" => "TP-923", "title" => "Improve decisions"},
          "attachments" => %{
            "nodes" => [
              %{"url" => "https://github.com/tonypine/symphony/pull/440"},
              %{"url" => "https://www.figma.com/file/abc"},
              %{"url" => "https://github.com/tonypine/symphony/pull/450"}
            ]
          },
          "inverseRelations" => %{
            "nodes" => [
              %{"type" => "blocks", "issue" => %{"identifier" => "TP-880", "state" => %{"type" => "started"}}},
              %{"type" => "blocks", "issue" => %{"identifier" => "TP-870", "state" => %{"type" => "completed"}}},
              %{"type" => "related", "issue" => %{"identifier" => "TP-860", "state" => %{"type" => "started"}}}
            ]
          }
        })

      tp892 = ticket("TP-892", %{"state" => %{"name" => "Rework", "type" => "started"}})
      other_team = ticket("SHOP-1")

      item = item("TP-892", action("TP-891 and SHOP-1 wait. Code Review sent PR #448 back; #449 is gone. TP-999 and SHA-256 too."))

      github =
        github(%{
          "https://github.com/tonypine/symphony/pull/449" => {:error, {:gh_failed, ["pr"], 1, "not found"}},
          "https://github.com/tonypine/symphony/pull/450" => {:ok, pull_request("https://github.com/tonypine/symphony/pull/450", %{checks: "failed"})}
        })

      verdicts = fn
        "symphony", "id-TP-892" ->
          [
            %{kind: "code_review", head_sha: "c", outcome: "request_changes"},
            %{kind: "code_review", head_sha: "b", outcome: "approve"},
            %{kind: "code_review", head_sha: "b", outcome: "approve"},
            %{kind: "code_review", head_sha: "a", outcome: "inconclusive"}
          ]
      end

      log =
        capture_log(fn ->
          linear = linear([own_892], [tp891, tp892, other_team])
          send(self(), {:result, resolve([item], linear, github, verdicts: verdicts)})
        end)

      assert_received {:result, {[resolved], cache}}
      assert log =~ "could not read https://github.com/tonypine/symphony/pull/449"

      assert_received {:linear, variables}
      refute_received {:linear, _second_query}
      assert variables.own == %{"id" => %{"in" => ["id-TP-892"]}}
      assert variables.withMentioned

      assert variables.mentioned["or"] == [
               %{"team" => %{"key" => %{"eq" => "TP"}}, "number" => %{"eq" => 891}},
               %{"team" => %{"key" => %{"eq" => "SHOP"}}, "number" => %{"eq" => 1}},
               %{"team" => %{"key" => %{"eq" => "TP"}}, "number" => %{"eq" => 999}},
               %{"team" => %{"key" => %{"eq" => "SHA"}}, "number" => %{"eq" => 256}},
               %{"team" => %{"key" => %{"eq" => "TP"}}, "number" => %{"eq" => 892}}
             ]

      # The mentioned pull requests first, then the ones attached to the tickets read.
      assert_received {:github, "https://github.com/tonypine/symphony/pull/448"}
      assert_received {:github, "https://github.com/tonypine/symphony/pull/449"}
      assert_received {:github, "https://github.com/tonypine/symphony/pull/450"}
      refute_received {:github, _url}
      assert Map.keys(cache) |> Enum.sort() == Enum.map([448, 449, 450], &"https://github.com/tonypine/symphony/pull/#{&1}")

      assert %{
               "TP-891" => %{
                 kind: "ticket",
                 identifier: "TP-891",
                 title: "Title of TP-891",
                 repo_key: "symphony",
                 state: "In Progress",
                 summary: "PR open, waiting on Code Review",
                 url: "https://linear.app/acme/issue/TP-891",
                 parent: %{identifier: "TP-923", title: "Improve decisions"},
                 pull_request: %{number: 450, url: "https://github.com/tonypine/symphony/pull/450", checks: "failed"},
                 waiting_on: nil,
                 facts: %{issue_id: "id-TP-891", state: "In Progress", state_type: "started", open_blockers: ["TP-880"]}
               },
               "SHOP-1" => %{kind: "ticket", repo_key: nil, summary: "Part of TP-923.", parent: nil, pull_request: nil},
               "PR #448" => %{
                 kind: "pull_request",
                 number: 448,
                 repo_key: "symphony",
                 url: "https://github.com/tonypine/symphony/pull/448",
                 title: "TP-892 Remove the Final verification and Supervisor check flows",
                 summary: "The two old review steps are gone.",
                 review_state: "changes_requested",
                 review_rounds: 2,
                 files: 12,
                 additions: 120,
                 deletions: 480,
                 checks: "passed",
                 ticket: "TP-892"
               },
               "#449" => %{kind: "missing", url: "https://github.com/tonypine/symphony/pull/449"},
               "TP-999" => %{kind: "missing", url: "https://linear.app/acme/issue/TP-999"},
               "SHA-256" => %{kind: "missing", url: "https://linear.app/acme/issue/SHA-256"}
             } = resolved.references

      assert map_size(resolved.references) == 6
    end

    test "a failed Linear read leaves every ticket mention missing and the context empty, and the rest of the item as it was" do
      item = item("TP-892", action("TP-891 waits on #448."), %{url: nil})

      for failure <- [{:error, :timeout}, {:ok, %{"data" => nil, "errors" => [%{"message" => "boom"}]}}] do
        failing = fn _query, _variables, _opts -> failure end
        log = capture_log(fn -> send(self(), {:result, resolve([item], failing, github(%{}))}) end)
        assert log =~ "could not read the tickets the Inbox mentions from Linear"
        assert_received {:result, {[resolved], _cache}}

        assert resolved.references["TP-891"] == %{kind: "missing", url: nil}
        assert %{kind: "pull_request", number: 448, ticket: "TP-892", review_rounds: 0, review_state: "open"} = resolved.references["#448"]

        assert resolved.context == %{
                 parent: nil,
                 pull_request: nil,
                 blocked_by: [],
                 blocks: [],
                 related: [],
                 earlier_decisions: []
               }

        assert Map.drop(resolved, [:references, :context]) == item
      end
    end

    test "a bare pull request number of a repo with no GitHub repository is missing, with no URL and no GitHub read" do
      item = item("TP-892", action("See #448 and PR #9."), %{repo_key: "elsewhere"})
      {[resolved], cache} = References.resolve([item], %{}, opts(linear([], []), github(%{})))

      assert resolved.references == %{"#448" => %{kind: "missing", url: nil}, "PR #9" => %{kind: "missing", url: nil}}
      assert cache == %{}
      refute_received {:github, _url}
      assert_received {:linear, %{withMentioned: false, mentionedFirst: 1, mentioned: %{"or" => []}}}
    end

    test "reads a pull request on GitHub Enterprise, and none of a repo whose GitHub repository can't be read" do
      item = item("TP-1", action("#5"), %{repo_key: "enterprise"})
      repos = %{"enterprise" => "github.acme.com/acme/app", "odd" => "odd"}
      {[resolved], _cache} = References.resolve([item], %{}, opts(linear([], []), github(%{}), github_repos: repos))
      assert resolved.references["#5"].url == "https://github.acme.com/acme/app/pull/5"

      {[resolved], _cache} = resolve([%{item | repo_key: "odd"}], linear([], []), github(%{}), github_repos: repos)
      assert resolved.references["#5"] == %{kind: "missing", url: nil}
    end

    test "a pull request whose ticket can't be told has no ticket and no review rounds, and GitHub's own review decision wins" do
      item = item("TP-1", action("#1 #2 #3 #4 #5"))
      url = &"https://github.com/tonypine/symphony/pull/#{&1}"

      github =
        github(%{
          url.(1) => {:ok, pull_request(url.(1), %{title: nil, head_ref_name: nil, state: "MERGED", body: nil})},
          url.(2) => {:ok, pull_request(url.(2), %{title: "Fix it", head_ref_name: "main", state: "CLOSED", body: "Just a body. Two."})},
          url.(3) => {:ok, pull_request(url.(3), %{review_decision: "CHANGES_REQUESTED"})},
          url.(4) => {:ok, pull_request(url.(4), %{review_decision: "APPROVED"})},
          url.(5) => {:ok, pull_request(url.(5), %{title: "Tidy", head_ref_name: "tp-5", body: "## This PR\n\nNothing changes on screen.\n"})}
        })

      verdicts = fn _repo_key, _issue_id -> [%{head_sha: "a", outcome: "approve"}] end
      tp892 = ticket("TP-892")
      {[resolved], _cache} = References.resolve([item], %{}, opts(linear([], [tp892]), github, verdicts: verdicts))

      assert %{ticket: nil, review_rounds: 0, review_state: "merged", summary: nil} = resolved.references["#1"]
      assert %{ticket: nil, review_state: "closed", summary: "Just a body."} = resolved.references["#2"]
      assert %{ticket: "TP-892", review_state: "changes_requested", review_rounds: 1} = resolved.references["#3"]
      assert %{review_state: "approved"} = resolved.references["#4"]
      assert %{ticket: nil, review_state: "open", summary: "Nothing changes on screen."} = resolved.references["#5"]
    end

    test "Symphony's newest Code Review verdict is the review state when GitHub has none" do
      item = item("TP-892", action("#448"))

      for {outcome, state} <- [{"approve", "approved"}, {"request_changes", "changes_requested"}, {"block", "open"}] do
        verdicts = fn "symphony", "id-TP-892" -> [%{head_sha: "a", outcome: outcome}] end
        own = [%{"id" => "id-TP-892", "identifier" => "TP-892"}]
        {[resolved], _cache} = resolve([item], linear(own, []), github(%{}), verdicts: verdicts)
        assert resolved.references["#448"].review_state == state
      end
    end

    test "builds the item's context: parent progress, its pull request, connected tickets and earlier decisions" do
      children =
        for {type, index} <- Enum.with_index(~w(completed completed started canceled completed unstarted completed backlog)) do
          %{"createdAt" => "2026-10-0#{9 - index}T00:00:00Z", "state" => %{"type" => type}}
        end

      own = %{
        "id" => "id-TP-892",
        "identifier" => "TP-892",
        "parent" => %{"identifier" => "TP-923", "title" => "Improve decisions", "children" => %{"nodes" => children}},
        "attachments" => %{"nodes" => [%{"url" => "https://github.com/tonypine/symphony/pull/448"}]},
        "relations" => %{
          "nodes" => [
            %{"type" => "blocks", "relatedIssue" => %{"identifier" => "TP-893", "title" => "Next", "state" => %{"name" => "Todo"}}},
            %{"type" => "related", "relatedIssue" => %{"identifier" => "TP-891", "title" => "Old text", "state" => %{"name" => "In Progress"}}},
            %{"type" => "duplicate", "relatedIssue" => %{"identifier" => "TP-1", "title" => "Dup", "state" => %{"name" => "Done"}}}
          ]
        },
        "inverseRelations" => %{
          "nodes" => [
            %{"type" => "blocks", "issue" => %{"identifier" => "TP-880", "title" => "Before", "state" => %{"name" => "Done"}}},
            %{"type" => "related", "issue" => %{"identifier" => "TP-891", "title" => "Old text", "state" => %{"name" => "In Progress"}}}
          ]
        }
      }

      options = [%{label: "A", effect: "a", recommended: true}, %{label: "B", effect: "b"}]
      decision = fn title -> Request.render_hold(%{title: title, question: "Q?", why: "W.", options: options}, "Rework") end

      node = %{
        "id" => "id-TP-892",
        "comments" => %{
          "nodes" => [
            %{"id" => "r1", "body" => decision.("First"), "createdAt" => "2026-10-10T00:00:00Z"},
            %{"id" => "a1", "body" => "Pick A", "createdAt" => "2026-10-10T01:00:00Z", "parent" => %{"id" => "r1"}},
            %{"id" => "r2", "body" => decision.("Second"), "createdAt" => "2026-10-11T00:00:00Z"},
            %{"id" => "a2", "body" => "Decision from the Director:\n\n1. Q?\n   **Decision:** B", "createdAt" => "2026-10-11T02:00:00.123Z", "parent" => %{"id" => "r2"}},
            %{"id" => "r3", "body" => decision.("Withdrawn"), "createdAt" => "2026-10-12T00:00:00Z"},
            %{"id" => "w3", "body" => "## Action withdrawn\n\nNot needed.", "createdAt" => "2026-10-12T01:00:00Z", "parent" => %{"id" => "r3"}},
            %{"id" => "r4", "body" => decision.("Third"), "createdAt" => "2026-10-12T03:00:00Z"},
            %{"id" => "a4", "body" => "A,\nplease", "createdAt" => "2026-10-13T05:48:00Z", "parent" => %{"id" => "r4"}},
            %{"id" => "r5", "body" => decision.("Fourth"), "createdAt" => "2026-10-09T00:00:00Z"},
            %{"id" => "a5", "body" => "B", "createdAt" => "2026-10-09T01:00:00Z", "parent" => %{"id" => "r5"}},
            %{"id" => "r6", "body" => decision.("Open"), "createdAt" => "2026-10-13T06:00:00Z"}
          ]
        }
      }

      verdicts = fn "symphony", "id-TP-892" ->
        [%{head_sha: "c", outcome: "request_changes"}, %{head_sha: "b", outcome: "request_changes"}, %{head_sha: "a", outcome: "approve"}]
      end

      github = github(%{"https://github.com/tonypine/symphony/pull/448" => {:ok, pull_request("https://github.com/tonypine/symphony/pull/448", %{checks: "pending"})}})

      item = item("TP-892", action("Nothing mentioned."))
      {[resolved], _cache} = resolve_with([item], %{"id-TP-892" => node}, linear([own], []), github, verdicts: verdicts)

      assert resolved.context == %{
               parent: %{
                 identifier: "TP-923",
                 title: "Improve decisions",
                 done: 4,
                 total: 7,
                 children: ~w(backlog completed unstarted completed started completed completed)
               },
               pull_request: %{number: 448, url: "https://github.com/tonypine/symphony/pull/448", checks: "pending", sent_back: 2},
               blocked_by: [%{identifier: "TP-880", title: "Before", state: "Done"}],
               blocks: [%{identifier: "TP-893", title: "Next", state: "Todo"}],
               related: [%{identifier: "TP-891", title: "Old text", state: "In Progress"}],
               earlier_decisions: [
                 %{at: "2026-10-13T05:48:00Z", title: "Third", answer: "A, please"},
                 %{at: "2026-10-11T02:00:00Z", title: "Second", answer: "B"},
                 %{at: "2026-10-10T01:00:00Z", title: "First", answer: "Pick A"}
               ]
             }

      assert resolved.references == %{}
    end

    test "a parent with no sub-tickets read and a ticket with no parent or pull request" do
      own = %{"id" => "id-TP-1", "identifier" => "TP-1", "parent" => %{"identifier" => "TP-2", "title" => "Plan"}}
      {[resolved], _cache} = References.resolve([item("TP-1", action("x"))], %{}, opts(linear([own], []), github(%{})))
      assert %{parent: %{identifier: "TP-2", done: 0, total: 0, children: []}, pull_request: nil} = resolved.context

      own = %{"id" => "id-TP-1", "identifier" => "TP-1", "parent" => nil}
      {[resolved], _cache} = resolve([item("TP-1", action("x"))], linear([own, %{"id" => nil}], []), github(%{}))
      assert %{parent: nil, pull_request: nil} = resolved.context
    end

    test "an answer without a reply time sorts last" do
      node = %{
        "comments" => %{
          "nodes" => [
            %{"id" => "r1", "body" => "## Decision needed: Old\n\n**Question:** Q?", "createdAt" => "2026-10-10T00:00:00Z"},
            %{"id" => "a1", "body" => "Yes", "parent" => %{"id" => "r1"}},
            %{"id" => "r2", "body" => "## Decision needed: New\n\n**Question:** Q?", "createdAt" => "2026-10-11T00:00:00Z"},
            %{"id" => "a2", "body" => "No", "createdAt" => "2026-10-11T01:00:00Z", "parent" => %{"id" => "r2"}}
          ]
        }
      }

      {[resolved], _cache} = resolve_with([item("TP-1", action("x"))], %{"id-TP-1" => node}, linear([], []), github(%{}))
      assert resolved.context.earlier_decisions == [%{at: "2026-10-11T01:00:00Z", title: "New", answer: "No"}, %{at: nil, title: "Old", answer: "Yes"}]
    end

    test "reuses a pull request read younger than two minutes, and reads at most 30 per poll" do
      item = item("TP-1", action("#448"))
      {[_resolved], cache} = References.resolve([item], %{}, opts(linear([], []), github(%{})))
      assert_received {:github, _url}

      {[resolved], ^cache} = resolve([item], linear([], []), github(%{}), cache: cache, now_ms: @now + 119_999)
      refute_received {:github, _url}
      assert resolved.references["#448"].kind == "pull_request"

      {[_resolved], new_cache} = resolve([item], linear([], []), github(%{}), cache: cache, now_ms: @now + 120_000)
      assert_received {:github, _url}
      later = @now + 120_000
      assert %{"https://github.com/tonypine/symphony/pull/448" => {^later, {:ok, _pr}}} = new_cache

      many = item("TP-1", action(Enum.map_join(1..31, " ", &"##{&1}")))
      {[resolved], cache} = References.resolve([many], %{}, opts(linear([], []), github(%{})))
      assert map_size(cache) == 30
      assert resolved.references["#31"] == %{kind: "missing", url: "https://github.com/tonypine/symphony/pull/31"}
    end

    test "places another team's ticket in no repo, an Inbox ticket in its own, and nothing for no items" do
      tp5 = ticket("TP-5")
      mine = item("TP-5", action("x"), %{repo_key: "app"})
      clarify = item("unknown", %{found: "TP-5 again", questions: []}, %{kind: :clarify, identifier: nil, url: nil, issue_id: "id-clarify"})
      {[_mine, resolved], _cache} = References.resolve([mine, clarify], %{}, opts(linear([], [tp5]), github(%{})))
      assert resolved.references["TP-5"].repo_key == "app"

      other = item("SHOP-1", action("TP-5"))
      {[resolved], _cache} = References.resolve([other], %{}, opts(linear([], [tp5]), github(%{})))
      assert resolved.references["TP-5"].repo_key == nil

      assert References.resolve([], %{}, []) == {[], %{}}

      # An item with no identifier, or one that isn't a ticket's, and a URL that isn't Linear's.
      for identifier <- [nil, "weird"] do
        odd = item("x", action("TP-5 and TP-6"), %{identifier: identifier, url: "https://example.com/x"})
        {[resolved], _cache} = resolve([odd], linear([], [tp5]), github(%{}))
        assert %{"TP-5" => %{kind: "ticket", repo_key: nil}, "TP-6" => %{kind: "missing", url: nil}} = resolved.references
      end
    end
  end

  describe "live/2" do
    defp live_reference(facts), do: %{references: %{"X-1" => %{kind: "ticket", waiting_on: nil, facts: Map.merge(%{issue_id: "i", state: "Todo", state_type: "unstarted", open_blockers: []}, facts)}}}

    defp waiting_on(facts, live \\ %{}) do
      live = Map.merge(%{running: MapSet.new(), you: MapSet.new()}, live)
      References.live(live_reference(facts), live).references["X-1"].waiting_on
    end

    test "says what a ticket waits on in the ticket page's words" do
      assert waiting_on(%{state: "Done", state_type: "completed"}) == nil
      assert waiting_on(%{state_type: "canceled"}) == nil
      assert waiting_on(%{}, %{running: MapSet.new(["i"])}) == nil
      assert waiting_on(%{}, %{you: MapSet.new(["i"])}) == "you"
      assert waiting_on(%{state: "Backlog", state_type: "backlog"}) == "you"
      assert waiting_on(%{state: "Plan Review", state_type: "started"}) == "you"
      assert waiting_on(%{open_blockers: ["TP-1", "TP-2"]}) == "a blocker: TP-1, TP-2"
      assert waiting_on(%{state: "Merging", state_type: "started"}) == "CI"
      assert waiting_on(%{state: "CI Fix", state_type: "started"}) == "CI"
      assert waiting_on(%{state: "Code Review", state_type: "started"}) == "a review"
      assert waiting_on(%{state: "Waiting on sub-tickets", state_type: "started"}) == "its sub-tickets"
      assert waiting_on(%{state: nil, state_type: nil}) == "a slot"
    end

    test "drops the facts it read, and leaves other references and items without references as they are" do
      live = %{running: MapSet.new(), you: MapSet.new()}
      assert %{references: %{"X-1" => reference}} = References.live(live_reference(%{}), live)
      refute Map.has_key?(reference, :facts)

      missing = %{references: %{"#1" => %{kind: "missing", url: nil}}}
      assert References.live(missing, live) == missing
      assert References.live(%{kind: :clarify}, live) == %{kind: :clarify}
    end
  end

  describe "summaries" do
    test "a ticket's is its Symphony status line, else its description's first sentence without Symphony's sections" do
      status = IssueSummary.start_marker() <> "\n\n### Symphony summary\n\n**Status:** [PR](https://x) open\n\n" <> IssueSummary.end_marker()
      assert References.ticket_summary("Build it. Then ship.\n\n" <> status) == "PR open"

      decisions = "<!-- symphony:decisions:start -->\n### Decisions\n\n- **D1** · x\n<!-- symphony:decisions:end -->"
      assert References.ticket_summary(decisions <> "\n\nBuild **it**. Then ship.") == "Build it."
      assert References.ticket_summary(IssueSummary.start_marker() <> "\nno status\n" <> IssueSummary.end_marker() <> "\nAfter.") == "After."
      assert References.ticket_summary(nil) == nil
    end

    test "a pull request's is its This PR section's first sentence, else its body's" do
      assert References.pull_request_summary("## This PR\n\nAdds [chips](https://x).\n\n## Stack\n\nNo.") == "Adds chips."
      assert References.pull_request_summary("Intro line. More.") == "Intro line."
      assert References.pull_request_summary(nil) == nil
    end
  end

  test "reads each configured repo's GitHub repository" do
    repo = %SystemSchema.Repo{name: "app", workspace: %SystemSchema.Repo.Workspace{github: "acme/app"}}
    assert References.github_repos([repo, %{name: "plain"}]) == %{"app" => "acme/app"}
  end
end
