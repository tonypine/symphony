defmodule SymphonyElixir.Inbox.ReferencesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.Inbox.References
  alias SymphonyElixir.{IssueSummary, PrDecision, TicketState}

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

  # A ticket's record, as the run store holds it.
  defp ticket(identifier, attrs \\ %{}) do
    TicketState.new(
      Map.get(attrs, :repo_key, "symphony"),
      "id-" <> identifier,
      Map.merge(%{issue_identifier: identifier, title: "Title of " <> identifier, description: "Part of TP-923. More text.", url: "https://linear.app/acme/issue/" <> identifier, phase: "Todo"}, attrs)
    )
  end

  defp watched(url), do: %{facts: %PrDecision.Facts{}, pr_url: url}

  defp github(answers) do
    test_pid = self()

    fn url ->
      send(test_pid, {:github, url})
      Map.get_lazy(answers, url, fn -> {:ok, pull_request(url)} end)
    end
  end

  defp opts(github, extra \\ []) do
    Keyword.merge(
      [
        name: {:test, make_ref()},
        pull_request: github,
        github_repos: %{"symphony" => "tonypine/symphony"},
        verdicts: fn _repo_key, _issue_id -> [] end,
        settings_fun: fn _repo_key -> %Schema{} end,
        now_ms: @now
      ],
      extra
    )
  end

  defp resolve(items, records, github, extra \\ []), do: References.resolve(items, records, opts(github, extra))

  describe "resolve/3" do
    test "resolves every ticket and pull request an item mentions from the records and GitHub, with no Linear read" do
      summary = IssueSummary.start_marker() <> "\n\n**Status:** PR open, waiting on **Code Review**\n\n" <> IssueSummary.end_marker()

      tp891 =
        ticket("TP-891", %{
          description: summary,
          phase: "In Progress",
          parent: %{identifier: "TP-923", title: "Improve decisions", done: 0, total: 1, children: ["started"]},
          pr_watch: watched("https://github.com/tonypine/symphony/pull/450"),
          blockers: [
            %{id: "id-TP-880", identifier: "TP-880", state: "In Progress"},
            %{id: "id-TP-870", identifier: "TP-870", state: "Done"},
            %{id: nil, identifier: nil, state: nil}
          ]
        })

      tp892 = ticket("TP-892", %{phase: "Rework"})
      other_repo = ticket("SHOP-1", %{repo_key: "shop"})

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

      records = [tp891, tp892, other_repo]
      log = capture_log(fn -> send(self(), {:result, resolve([item], records, github, verdicts: verdicts)}) end)

      assert_received {:result, [resolved]}
      assert log =~ "could not read https://github.com/tonypine/symphony/pull/449"

      # The mentioned pull requests, then the ones of the tickets it names.
      assert_received {:github, "https://github.com/tonypine/symphony/pull/448"}
      assert_received {:github, "https://github.com/tonypine/symphony/pull/449"}
      assert_received {:github, "https://github.com/tonypine/symphony/pull/450"}
      refute_received {:github, _url}

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
               "SHOP-1" => %{kind: "ticket", repo_key: "shop", summary: "Part of TP-923.", parent: nil, pull_request: nil},
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

    test "reads a ticket's phase as terminal, backlog or started, by its repo's terminal states" do
      records = [
        ticket("TP-1", %{phase: "Done", blockers: [%{id: nil, identifier: "TP-9", state: nil}]}),
        ticket("TP-2", %{phase: " Backlog "}),
        ticket("TP-3", %{phase: "Triage"}),
        ticket("TP-4", %{phase: nil})
      ]

      [resolved] = resolve([item("TP-10", action("TP-1 TP-2 TP-3 TP-4"))], records, github(%{}))

      assert %{state_type: "completed", open_blockers: ["TP-9"]} = resolved.references["TP-1"].facts
      assert %{state_type: "backlog"} = resolved.references["TP-2"].facts
      assert %{state_type: "triage"} = resolved.references["TP-3"].facts
      assert %{state_type: "started"} = resolved.references["TP-4"].facts
    end

    test "a ticket Symphony holds no record of leaves its mentions missing and its context empty, and the rest of the item as it was" do
      item = item("TP-892", action("TP-891 waits on #448."), %{url: nil})
      [resolved] = resolve([item], [], github(%{}))

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

    test "a bare pull request number of a repo with no GitHub repository is missing, with no URL and no GitHub read" do
      item = item("TP-892", action("See #448 and PR #9."), %{repo_key: "elsewhere"})
      [resolved] = resolve([item], [], github(%{}))

      assert resolved.references == %{"#448" => %{kind: "missing", url: nil}, "PR #9" => %{kind: "missing", url: nil}}
      refute_received {:github, _url}
    end

    test "reads a pull request on GitHub Enterprise, and none of a repo whose GitHub repository can't be read" do
      item = item("TP-1", action("#5"), %{repo_key: "enterprise"})
      repos = %{"enterprise" => "github.acme.com/acme/app", "odd" => "odd"}
      [resolved] = resolve([item], [], github(%{}), github_repos: repos)
      assert resolved.references["#5"].url == "https://github.acme.com/acme/app/pull/5"

      [resolved] = resolve([%{item | repo_key: "odd"}], [], github(%{}), github_repos: repos)
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
      [resolved] = resolve([item], [ticket("TP-892")], github, verdicts: verdicts)

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
        [resolved] = resolve([item], [ticket("TP-892")], github(%{}), verdicts: verdicts)
        assert resolved.references["#448"].review_state == state
      end
    end

    test "reads the pull request of the ticket a mentioned pull request belongs to" do
      tp892 = ticket("TP-892", %{pr_watch: watched("https://github.com/tonypine/symphony/pull/500")})
      [_resolved] = resolve([item("TP-1", action("#448"))], [tp892], github(%{}))

      assert_received {:github, "https://github.com/tonypine/symphony/pull/448"}
      assert_received {:github, "https://github.com/tonypine/symphony/pull/500"}
    end

    test "builds the item's context from its record: parent progress, its pull request, connected tickets and earlier decisions" do
      parent = %{identifier: "TP-923", title: "Improve decisions", done: 4, total: 7, children: ~w(backlog completed unstarted completed started completed completed)}
      answered = fn id, title, text, at -> %{id: id, title: title, state: :answered, answer: %{text: text, at: at}} end

      own =
        ticket("TP-892", %{
          parent: parent,
          pr_watch: watched("https://github.com/tonypine/symphony/pull/448"),
          blockers: [
            %{id: "id-TP-880", identifier: "TP-880", state: "Done"},
            %{id: "id-TP-881", identifier: "TP-881", state: "Todo"},
            %{id: nil, identifier: nil, state: nil}
          ],
          questions: [
            answered.("q1", "First", "Pick A", ~U[2026-10-10 01:00:00Z]),
            answered.("q2", "Second", "B", ~U[2026-10-11 02:00:00.123Z]),
            %{id: "q3", title: "Withdrawn", state: :withdrawn, answer: nil},
            answered.("q4", "Third", "A,\nplease", ~U[2026-10-13 05:48:00Z]),
            answered.("q5", "Fourth", "B", ~U[2026-10-09 01:00:00Z]),
            %{id: "q6", title: "Open", state: :open, answer: nil}
          ]
        })

      records = [
        own,
        ticket("TP-880", %{title: "Before", phase: "Done"}),
        ticket("TP-893", %{title: "Next", blockers: [%{id: "id-TP-892", identifier: nil, state: "Rework"}]}),
        ticket("TP-894", %{title: "Later", blockers: [%{id: nil, identifier: "TP-892", state: "Rework"}]}),
        ticket("TP-895", %{blockers: [%{id: "id-TP-1", identifier: "TP-1", state: "Todo"}]}),
        %{repo_key: "symphony", issue_id: "id-no-identifier", blockers: [%{id: "id-TP-892", identifier: "TP-892", state: nil}]}
      ]

      verdicts = fn "symphony", "id-TP-892" ->
        [%{head_sha: "c", outcome: "request_changes"}, %{head_sha: "b", outcome: "request_changes"}, %{head_sha: "a", outcome: "approve"}]
      end

      github = github(%{"https://github.com/tonypine/symphony/pull/448" => {:ok, pull_request("https://github.com/tonypine/symphony/pull/448", %{checks: "pending"})}})

      [resolved] = resolve([item("TP-892", action("Nothing mentioned."))], records, github, verdicts: verdicts)

      assert resolved.context == %{
               parent: parent,
               pull_request: %{number: 448, url: "https://github.com/tonypine/symphony/pull/448", checks: "pending", sent_back: 2},
               blocked_by: [%{identifier: "TP-880", title: "Before", state: "Done"}, %{identifier: "TP-881", title: nil, state: "Todo"}],
               blocks: [%{identifier: "TP-893", title: "Next", state: "Todo"}, %{identifier: "TP-894", title: "Later", state: "Todo"}],
               related: [],
               earlier_decisions: [
                 %{at: "2026-10-13T05:48:00Z", title: "Third", answer: "A, please"},
                 %{at: "2026-10-11T02:00:00Z", title: "Second", answer: "B"},
                 %{at: "2026-10-10T01:00:00Z", title: "First", answer: "Pick A"}
               ]
             }

      assert resolved.references == %{}
    end

    test "a pull request the watcher records under a URL that names no pull request is none" do
      own = ticket("TP-1", %{pr_watch: watched("https://github.com/tonypine/symphony/issues/3")})
      [resolved] = resolve([item("TP-1", action("x"))], [own], github(%{}))
      assert %{parent: nil, pull_request: nil} = resolved.context
      refute_received {:github, _url}
    end

    test "reads a row's pull requests once, again when the row changes, and a failed one again after two minutes" do
      opts = opts(github(%{"https://github.com/tonypine/symphony/pull/449" => {:error, :timeout}}))
      row = item("TP-1", action("#448 #449"))

      log = capture_log(fn -> References.resolve([row], [], opts) end)
      assert log =~ "could not read https://github.com/tonypine/symphony/pull/449"
      assert_received {:github, "https://github.com/tonypine/symphony/pull/448"}
      assert_received {:github, "https://github.com/tonypine/symphony/pull/449"}

      # The same row: nothing is read, the failed read included, until two minutes passed.
      assert [%{references: %{"#448" => %{kind: "pull_request"}, "#449" => %{kind: "missing"}}}] = References.resolve([row], [], Keyword.put(opts, :now_ms, @now + 119_999))
      refute_received {:github, _url}

      capture_log(fn -> References.resolve([row], [], Keyword.put(opts, :now_ms, @now + 120_000)) end)
      assert_received {:github, "https://github.com/tonypine/symphony/pull/448"}
      assert_received {:github, "https://github.com/tonypine/symphony/pull/449"}

      # A row whose reads all succeeded is kept however old they are; a changed row is read again.
      ok_opts = opts(github(%{}))
      References.resolve([row], [], ok_opts)
      assert_received {:github, _first}
      assert_received {:github, _second}
      References.resolve([row], [], Keyword.put(ok_opts, :now_ms, @now + 3_600_000))
      refute_received {:github, _url}
      References.resolve([%{row | ask: "Decide again"}], [], ok_opts)
      assert_received {:github, "https://github.com/tonypine/symphony/pull/448"}
    end

    test "keeps a row's reads by its Question, and reads at most 30 pull requests for a row" do
      opts = opts(github(%{}))
      asked = item("TP-1", Map.put(action("#448"), :question_id, "q-1"))
      References.resolve([asked], [], opts)
      assert_received {:github, _url}

      # The same Question on a row that moved on: its reads are those of the Question.
      References.resolve([asked], [], opts)
      refute_received {:github, _url}
      assert %{{:question, "q-1"} => _reads} = :persistent_term.get({References, :rows, Keyword.fetch!(opts, :name)})

      many = item("TP-2", action(Enum.map_join(1..31, " ", &"##{&1}")))
      [resolved] = References.resolve([many], [], opts)
      assert resolved.references["#31"] == %{kind: "missing", url: "https://github.com/tonypine/symphony/pull/31"}
      assert map_size(:persistent_term.get({References, :rows, Keyword.fetch!(opts, :name)})) == 1
      assert References.resolve([], [], opts) == []
    end

    test "an item with no identifier, or one that isn't a ticket's, and a URL that isn't Linear's" do
      for identifier <- [nil, "weird"] do
        odd = item("x", action("TP-5 and TP-6"), %{identifier: identifier, url: "https://example.com/x"})
        [resolved] = resolve([odd], [ticket("TP-5", %{repo_key: "app"})], github(%{}))
        assert %{"TP-5" => %{kind: "ticket", repo_key: "app"}, "TP-6" => %{kind: "missing", url: nil}} = resolved.references
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
