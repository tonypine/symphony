defmodule SymphonyElixir.PullRequestPageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.PullRequestPage

  @url "https://github.com/tonypine/symphony/pull/448"

  describe "area/1" do
    test "maps each file to the one area it belongs to" do
      for path <- ["priv/playbook/review.liquid", ".symphony/instructions/010-review.md", ".agents/skills/land/SKILL.md"],
          do: assert(PullRequestPage.area(path) == "Agent instructions", path)

      for path <- ["macos/Sources/SymphonyBar/InboxView.swift", "macos/Package.swift"], do: assert(PullRequestPage.area(path) == "App", path)
      assert PullRequestPage.area("lib/symphony_elixir/inbox.ex") == "Server"

      for path <- ["docs/design/director-app-screens.md", "SPEC.md", "README.md"], do: assert(PullRequestPage.area(path) == "Documentation", path)

      for path <- ["test/symphony_elixir/inbox_test.exs", "macos/Tests/SymphonyBarCoreTests/InboxTests.swift"],
          do: assert(PullRequestPage.area(path) == "Tests", path)

      for path <- ["mix.exs", ".github/workflows/ci.yml", "config/config.exs", "priv/static/app.css", "elixir/README.md", "Makefile"],
          do: assert(PullRequestPage.area(path) == "Other", path)
    end
  end

  test "areas/1 groups files by area with their counts and line counts, never naming a file" do
    files = [
      file("lib/a.ex", 10, 2),
      file("test/a_test.exs", 30, 0),
      file("priv/playbook/a.liquid", 1, 40),
      file("lib/b.ex", 5, 5),
      file("mix.exs", 1, 1)
    ]

    assert PullRequestPage.areas(files) == [
             %{name: "Agent instructions", files: 1, additions: 1, deletions: 40},
             %{name: "Server", files: 2, additions: 15, deletions: 7},
             %{name: "Tests", files: 1, additions: 30, deletions: 0},
             %{name: "Other", files: 1, additions: 1, deletions: 1}
           ]

    assert PullRequestPage.areas([]) == []
  end

  test "summary/1 is the This PR section as plain text, else the first paragraph" do
    body = """
    ## References

    - Ticket: [TP-892](https://linear.app/x/issue/TP-892)

    ## This PR

    Nothing changes on screen.

    - The **Final verification** step is gone.
    - A ticket goes from `QA` straight to Merging.

    ### Important facts

    - A new flag.

    ## Stack

    More.
    """

    assert PullRequestPage.summary(body) ==
             "Nothing changes on screen. The Final verification step is gone. A ticket goes from QA straight to Merging."

    assert PullRequestPage.summary("<!-- template -->\n\nFirst **paragraph**\nstill first.\n\nSecond.") == "First paragraph still first."
    assert PullRequestPage.summary("## This PR\n\n## Stack\n") == nil
    assert PullRequestPage.summary("") == nil
    assert PullRequestPage.summary(nil) == nil
  end

  describe "fetch/3" do
    test "an unknown repo, a repo without a GitHub repository and a number that isn't one" do
      assert PullRequestPage.fetch("elsewhere", "448", opts()) == {:error, :unknown_repo}
      assert PullRequestPage.fetch("symphony", "x", opts()) == {:error, :not_found}
      assert PullRequestPage.fetch("symphony", "0", opts()) == {:error, :not_found}
      assert PullRequestPage.fetch("symphony", nil, opts()) == {:error, :not_found}
    end

    test "a pull request GitHub doesn't have" do
      assert PullRequestPage.fetch("symphony", 999, opts(pull_request: fn _url -> {:error, :not_found} end)) == {:error, :not_found}
    end

    test "reads an enterprise host's pull request at its URL" do
      test_pid = self()

      fetch = fn url ->
        send(test_pid, {:github, url})
        {:error, :not_found}
      end

      PullRequestPage.fetch("app", 7, opts(github_repos: %{"app" => "git.example.com/acme/app"}, pull_request: fetch))
      assert_received {:github, "https://git.example.com/acme/app/pull/7"}
    end

    test "names the ticket the pull request is attached to in Linear, with what it waits on now" do
      test_pid = self()

      linear = fn query, variables, _opts ->
        send(test_pid, {:linear, query, variables})
        {:ok, %{"data" => %{"attachmentsForURL" => %{"nodes" => [%{"issue" => node("TP-7", "Other")}, %{"issue" => node("TP-892", "Rework")}]}, "issues" => %{"nodes" => []}}}}
      end

      live = fn -> %{running: MapSet.new(), you: MapSet.new(["id-TP-892"])} end
      {:ok, page} = PullRequestPage.fetch("symphony", "448", opts(linear_client: linear, live: live))

      assert page.ticket == %{identifier: "TP-892", title: "Title of TP-892", state: "Rework", waiting_on: "you"}
      assert_received {:linear, query, %{url: @url, withIdentifier: true, filter: %{"number" => %{"eq" => 892}}}}
      assert query =~ "SymphonyPullRequestPage"

      {:ok, page} = PullRequestPage.fetch("symphony", "448", opts(linear_client: linear))
      assert page.ticket.waiting_on == "a slot"
    end

    test "falls back to the ticket Symphony's PR review record names, then to none" do
      linear = fn _query, %{withIdentifier: with?, filter: filter}, _opts ->
        send(self(), {:filter, with?, filter})
        {:ok, %{"data" => %{"attachmentsForURL" => %{"nodes" => []}, "issues" => %{"nodes" => if(with?, do: [node("TP-5", "Todo")], else: [])}}}}
      end

      reviews = fn "symphony" -> [%{issue_id: "id-TP-5", issue_identifier: "TP-5", pr_url: @url}] end
      untitled = fn _url -> {:ok, pr(title: "Untitled", head_ref_name: "feature")} end

      {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(linear_client: linear, pr_reviews: reviews, pull_request: untitled))
      assert page.ticket.identifier == "TP-5"
      assert_received {:filter, true, %{"team" => %{"key" => %{"eq" => "TP"}}, "number" => %{"eq" => 5}}}

      {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(linear_client: linear, pull_request: untitled))
      assert page.ticket == nil
      assert_received {:filter, false, %{}}
    end

    test "an identifier Symphony's record holds that isn't a ticket's is looked up by URL only" do
      linear = fn _query, %{withIdentifier: with?}, _opts ->
        send(self(), {:with_identifier, with?})
        {:ok, %{"data" => %{"attachmentsForURL" => %{"nodes" => []}}}}
      end

      reviews = fn "symphony" -> [%{issue_identifier: "not a ticket", pr_url: @url}] end
      {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(linear_client: linear, pr_reviews: reviews))
      assert page.ticket == nil
      assert_received {:with_identifier, false}
    end

    test "a failed Linear read leaves the ticket out, and Symphony's record still gives the history" do
      failing = fn _query, _variables, _opts -> {:error, :timeout} end
      reviews = fn "symphony" -> [%{issue_id: "id-TP-892", issue_identifier: "TP-892", pr_url: @url}] end
      record = ticket_record([verdict("code_review", "c1", "approve", ~U[2026-10-13 10:00:00Z])], [])

      log =
        capture_log(fn ->
          {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(linear_client: failing, pr_reviews: reviews, ticket_state: fn "symphony", "id-TP-892" -> record end))
          assert page.ticket == nil
          assert [%{kind: "code_review", verdict: "approve"}] = page.review_history
          assert page.review_state == "approved"
        end)

      assert log =~ "could not read the ticket"
    end

    test "review history is the PR's verdicts oldest first, each with the reason its run recorded" do
      verdicts = [
        verdict("qa", "c3", "pass", ~U[2026-10-13 12:00:00Z]),
        verdict("code_review", "c3", "approve", ~U[2026-10-13 11:00:00Z]),
        verdict("code_review", "c2", "request_changes", ~U[2026-10-13 10:00:00Z]),
        verdict("code_review", "c1", "request_changes", ~U[2026-10-13 09:00:00Z]),
        verdict("code_review", "old", "request_changes", ~U[2026-10-01 09:00:00Z]),
        verdict("acceptance", "c1", "pass", ~U[2026-10-13 09:30:00Z]),
        %{kind: "code_review", head_sha: nil, outcome: "inconclusive", recorded_at: nil}
      ]

      signals = [
        signal("qa", ~U[2026-10-13 12:00:01Z], %{"reason" => "every journey verified"}),
        signal("code_review", ~U[2026-10-13 11:00:02Z], %{reason: "QA runs: app files changed", review_reason: "The wording is gone. Ready."}),
        signal("code_review", ~U[2026-10-13 09:00:01Z], %{reason: "The playbook still names the old step. See the findings."}),
        signal("code_review", ~U[2026-10-13 09:00:05Z], %{reason: "A later signal of the same run."}),
        signal("code_review_deepening", ~U[2026-10-13 10:00:01Z], %{reason: "Not this one."}),
        signal("code_review", nil, %{reason: "No time."})
      ]

      record = ticket_record(verdicts, signals)
      {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(ticket_state: fn _repo_key, "id-TP-892" -> record end))

      assert page.review_history == [
               %{at: nil, kind: "code_review", verdict: "inconclusive", reason: nil},
               %{at: "2026-10-13T09:00:00Z", kind: "code_review", verdict: "request_changes", reason: "The playbook still names the old step."},
               %{at: "2026-10-13T10:00:00Z", kind: "code_review", verdict: "request_changes", reason: nil},
               %{at: "2026-10-13T11:00:00Z", kind: "code_review", verdict: "approve", reason: "The wording is gone."},
               %{at: "2026-10-13T12:00:00Z", kind: "qa", verdict: "pass", reason: "every journey verified"}
             ]

      assert page.health.code_review == %{verdict: "approve", round: 3}
      assert page.health.qa == "pass"
      assert page.review_state == "approved"
    end

    test "a ticket without a record or verdicts has no history and no review health" do
      {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(ticket_state: fn _repo_key, _issue_id -> {:error, :not_found} end))
      assert page.review_history == []
      assert page.health.code_review == nil
      assert page.health.qa == nil
      assert page.review_state == "open"
    end

    test "overlaps are the other open pull requests Symphony tracks that change one of its files" do
      reviews = fn "symphony" ->
        [
          %{issue_identifier: "TP-892", pr_url: @url, landing: %{files: ["lib/a.ex"]}},
          %{issue_identifier: "TP-971", pr_url: "https://github.com/tonypine/symphony/pull/483", landing: %{files: ["macos/x.swift", "lib/a.ex"]}},
          %{issue_identifier: "TP-972", pr_url: "https://github.com/tonypine/symphony/pull/484", landing: %{files: ["lib/other.ex"]}},
          %{issue_identifier: "TP-973", pr_url: "https://github.com/tonypine/symphony/pull/485", landing: nil},
          %{issue_identifier: "TP-974", pr_url: "https://github.com/tonypine/symphony/pull/486", landing: %{files: []}},
          %{issue_identifier: "TP-975", pr_url: nil, landing: %{files: ["lib/a.ex"]}},
          %{issue_identifier: "TP-976", pr_url: "https://github.com/tonypine/symphony/issues/9", landing: %{files: ["lib/a.ex"]}}
        ]
      end

      {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(pr_reviews: reviews))
      assert page.health.overlaps == [%{number: 483, ticket: "TP-971"}]

      {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(pr_reviews: fn _repo_key -> {:error, :unavailable} end))
      assert page.health.overlaps == []
    end

    test "with GitHub unavailable it serves what Linear and Symphony's records know" do
      reviews = fn "symphony" ->
        [
          %{issue_id: "id-TP-892", issue_identifier: "TP-892", pr_url: @url, landing: %{files: ["lib/a.ex"]}},
          %{issue_identifier: "TP-971", pr_url: "https://github.com/tonypine/symphony/pull/483", landing: %{files: ["lib/a.ex"]}}
        ]
      end

      record = ticket_record([verdict("code_review", "elsewhere", "request_changes", ~U[2026-10-13 09:00:00Z])], [])

      log =
        capture_log(fn ->
          failing = fn _url -> {:error, :timeout} end
          unavailable = opts(pull_request: failing, pr_reviews: reviews, ticket_state: fn _key, _id -> record end)
          {:ok, page} = PullRequestPage.fetch("symphony", 448, unavailable)

          assert %{github: "unavailable", url: @url, title: nil, state: nil, summary: nil} = page
          assert %{areas: [], size: nil, review_state: "changes_requested"} = page
          assert page.ticket.identifier == "TP-892"
          assert [%{verdict: "request_changes"}] = page.review_history
          assert page.health.checks == nil
          assert page.health.overlaps == [%{number: 483, ticket: "TP-971"}]
        end)

      assert log =~ "could not read #{@url} from GitHub"

      capture_log(fn ->
        {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(pull_request: fn _url -> {:error, :timeout} end))
        assert page.health.overlaps == []
      end)
    end

    test "a merged pull request" do
      merged = fn _url -> {:ok, pr(state: "MERGED", merged_at: ~U[2026-10-13 15:00:00.123Z], review_decision: "APPROVED")} end
      {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(pull_request: merged))
      assert %{state: "merged", review_state: "merged", merged_at: "2026-10-13T15:00:00Z"} = page

      {:ok, page} = PullRequestPage.fetch("symphony", 448, opts(pull_request: fn _url -> {:ok, pr(state: "CLOSED")} end))
      assert %{state: "closed", review_state: "closed", merged_at: nil} = page
    end

    test "keeps a page GitHub answered for one poll interval, and never one it couldn't read" do
      test_pid = self()
      repo_key = "cache-#{System.unique_integer([:positive])}"

      fetch = fn result ->
        fn url ->
          send(test_pid, {:github, url})
          result
        end
      end

      base = opts(github_repos: %{repo_key => "tonypine/symphony"}, ttl_ms: 1_000)
      read = fn now, result -> PullRequestPage.fetch(repo_key, 448, Keyword.merge(base, now_ms: now, pull_request: fetch.(result))) end

      capture_log(fn -> assert {:ok, %{github: "unavailable"}} = read.(0, {:error, :timeout}) end)
      assert_received {:github, @url}
      assert {:ok, %{github: "available", title: "TP-892 Retire two old review steps"}} = read.(10, {:ok, pr()})
      assert_received {:github, @url}
      assert {:ok, %{github: "available"}} = read.(1_009, {:ok, pr(title: "Changed")})
      refute_received {:github, _url}
      assert {:ok, %{title: "Changed"}} = read.(1_010, {:ok, pr(title: "Changed")})
      assert_received {:github, @url}
    end
  end

  defp opts(overrides \\ []) do
    linear = fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"attachmentsForURL" => %{"nodes" => [%{"issue" => node("TP-892", "Rework")}]}, "issues" => %{"nodes" => []}}}}
    end

    Keyword.merge(
      [
        github_repos: %{"symphony" => "tonypine/symphony", "app" => "acme/app"},
        pull_request: fn _url -> {:ok, pr()} end,
        linear_client: linear,
        ticket_state: fn _repo_key, _issue_id -> nil end,
        pr_reviews: fn _repo_key -> [] end,
        ttl_ms: 0
      ],
      overrides
    )
  end

  defp pr(overrides \\ []) do
    Map.merge(
      %{
        number: 448,
        url: @url,
        title: "TP-892 Retire two old review steps",
        body: "## This PR\n\nThe old steps are gone.",
        state: "OPEN",
        review_decision: nil,
        changed_files: 1,
        additions: 3,
        deletions: 1,
        head_ref_name: "auto/TP-892",
        checks: "passed",
        created_at: ~U[2026-10-12 09:00:00Z],
        merged_at: nil,
        last_pushed_at: ~U[2026-10-13 08:00:00Z],
        files: [file("lib/a.ex", 3, 1)],
        commits: ["c1", "c2", "c3"],
        check_counts: %{passed: 2, failed: 0, pending: 0}
      },
      Map.new(overrides)
    )
  end

  defp file(path, additions, deletions), do: %{path: path, additions: additions, deletions: deletions}

  defp node(identifier, state) do
    %{
      "id" => "id-" <> identifier,
      "identifier" => identifier,
      "title" => "Title of " <> identifier,
      "state" => %{"name" => state, "type" => "started"},
      "inverseRelations" => %{"nodes" => []}
    }
  end

  defp verdict(kind, head, outcome, at), do: %{kind: kind, head_sha: head, outcome: outcome, recorded_at: at}
  defp signal(name, at, details), do: %{name: name, at: at, details: details}

  defp ticket_record(verdicts, signals), do: %{issue_id: "id-TP-892", verdicts: verdicts, signals: signals}
end
