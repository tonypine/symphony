defmodule SymphonyElixirWeb.PullRequestReadTest do
  # The ticket read's `pull_request`, through the control API, from the watcher's real read.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.{PrDecision, TicketPullRequest, TicketSignals}
  alias SymphonyElixir.PrWatch.{Fetch, Snapshot}
  alias SymphonyElixirWeb.PullRequestPayload

  @endpoint SymphonyElixirWeb.Endpoint
  @repo "default"
  @pr_url "https://github.com/acme/app/pull/741"
  @ticket %{phase: :code_review, origin: nil, hold: :none, run: :none, max_red_attempts: 3, ahead: []}

  defmodule IdleOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, %{running: [], retrying: [], rate_limits: nil}, state}
  end

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    write_workflow_file!(Workflow.workflow_file_path())
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: IdleOrchestrator, start: {IdleOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok
  end

  defp check(name, conclusion, opts) do
    %{
      "__typename" => "CheckRun",
      "name" => name,
      "status" => if(conclusion, do: "COMPLETED", else: "IN_PROGRESS"),
      "conclusion" => conclusion,
      "detailsUrl" => "https://github.com/acme/app/actions/runs/#{opts[:run]}/job/#{opts[:job]}",
      "startedAt" => "2026-11-06T10:00:00Z",
      "completedAt" => conclusion && "2026-11-06T10:02:00Z",
      "checkSuite" => %{"workflowRun" => %{"workflow" => %{"name" => opts[:workflow]}}}
    }
  end

  # The watcher's own read of a PR with these checks.
  defp watcher_read(checks) do
    pull = %{
      "id" => "PR_1",
      "number" => 741,
      "title" => "TP-1 The change",
      "state" => "OPEN",
      "isDraft" => false,
      "merged" => false,
      "baseRefName" => "main",
      "headRefName" => "auto/TP-1",
      "headRefOid" => "8b03e51c0ffee",
      "mergeable" => "MERGEABLE",
      "mergeStateStatus" => "BEHIND",
      "headRef" => %{"name" => "auto/TP-1"},
      "changedFiles" => 9,
      "additions" => 486,
      "deletions" => 52,
      "reviewDecision" => nil,
      "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"contexts" => %{"nodes" => checks}}}}]}
    }

    answer = Jason.encode!(%{"data" => %{"repository" => %{"defaultBranchRef" => %{"name" => "main"}, "pullRequest" => pull}}})

    runner = fn
      ["api", "--include" | _rest], _opts -> {"HTTP/2.0 200 OK\r\n\r\n" <> answer, 0}
      ["run", "list" | _rest], _opts -> {"[]", 0}
    end

    {:ok, read} = Fetch.read(@pr_url, gh_runner: runner, required_checks: %{"main" => ["Tests"]})
    read
  end

  # The ticket's record as a tick of the watcher writes it from `read`.
  defp watched(issue_id, identifier, read) do
    facts = Fetch.facts(@ticket, read)
    action = PrDecision.decide(facts)
    decision = %{rule: action.rule, kind: action.kind, reason: action.reason, owner: action.owner, clears_when: action.clears_when, since: ~U[2026-11-06 10:03:00Z], outcome: :applied}
    pull_request = Map.put(read.pull_request, :read_at, ~U[2026-11-06 10:03:00Z])

    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: issue_id, issue_identifier: identifier, phase: "Code Review"})
    :ok = RunStore.put_ticket_pr_watch(@repo, issue_id, identifier, %{facts: facts, head_sha: read.head_sha, decision: decision, pull_request: pull_request})
  end

  defp ticket_read(identifier), do: build_conn() |> get("/api/v1/#{identifier}") |> json_response(200)

  test "a PR with a red check names the workflow, the failed check, its log and the watcher's next action" do
    watched(
      "red",
      "PR-1",
      watcher_read([
        check("Tests", "FAILURE", workflow: "CI", run: 100, job: 1),
        check("Lint", "SUCCESS", workflow: "CI", run: 100, job: 2),
        check("Swift tests", nil, workflow: "macOS", run: 101, job: 3)
      ])
    )

    assert %{"pull_request" => pull_request} = ticket_read("PR-1")

    assert %{
             "number" => 741,
             "url" => @pr_url,
             "title" => "TP-1 The change",
             "state" => "open",
             "draft" => false,
             "head_sha" => "8b03e51c0ffee",
             "head_short" => "8b03e51",
             "base" => "main",
             "mergeable" => "behind",
             "behind_base" => true,
             "review_state" => "open",
             "review_rounds" => 0,
             "files_changed" => 9,
             "additions" => 486,
             "deletions" => 52,
             "red_kind" => "failure",
             "read_at" => "2026-11-06T10:03:00Z"
           } = pull_request

    assert [
             %{
               "workflow" => "CI",
               "checks" => [
                 %{
                   "name" => "Tests",
                   "state" => "failed",
                   "started_at" => "2026-11-06T10:00:00Z",
                   "duration_ms" => 120_000,
                   "url" => "https://github.com/acme/app/actions/runs/100/job/1",
                   "required" => true
                 },
                 %{"name" => "Lint", "state" => "passed", "required" => false}
               ]
             },
             %{"workflow" => "macOS", "checks" => [%{"name" => "Swift tests", "state" => "running", "duration_ms" => nil}]}
           ] = pull_request["checks"]

    assert %{"rule" => "R22", "action" => "rerun_failed", "reason" => reason, "owner" => owner, "since" => "2026-11-06T10:03:00Z", "outcome" => "applied"} = pull_request["next_action"]
    assert is_binary(reason) and is_binary(owner)
    assert %{"rule" => "R22", "reason" => ^reason, "owner" => ^owner} = ticket_read("PR-1")["watch"]
  end

  test "a superseded run lists each check once with its newest state, and a cancelled-for-lack-of-a-machine check reads as such" do
    watched(
      "rerun",
      "PR-2",
      watcher_read([
        check("Tests", "FAILURE", workflow: "CI", run: 100, job: 1),
        check("Tests", "SUCCESS", workflow: "CI", run: 200, job: 9),
        check("Swift build", "CANCELLED", workflow: "macOS", run: 300, job: 4)
      ])
    )

    assert %{"pull_request" => %{"red_kind" => "cancelled", "checks" => checks}} = ticket_read("PR-2")

    assert [
             %{"workflow" => "CI", "checks" => [%{"name" => "Tests", "state" => "passed", "url" => "https://github.com/acme/app/actions/runs/200/job/9"}]},
             %{"workflow" => "macOS", "checks" => [%{"name" => "Swift build", "state" => "cancelled_no_machine"}]}
           ] = checks
  end

  test "review state and rounds come from the ticket's Code Review verdicts, and GitHub's review decision goes first" do
    read = watcher_read([check("Tests", "SUCCESS", workflow: "CI", run: 100, job: 1)])
    watched("reviewed", "PR-3", read)

    :ok = TicketSignals.record_verdict(@repo, "reviewed", "code_review", "head-1", "request_changes")
    :ok = TicketSignals.record_verdict(@repo, "reviewed", "code_review", "head-2", "approve")
    :ok = TicketSignals.record_verdict(@repo, "reviewed", "qa", "head-2", "pass")

    assert %{"pull_request" => %{"review_state" => "approved", "review_rounds" => 2, "red_kind" => nil}} = ticket_read("PR-3")

    watched("asked", "PR-4", put_in(read.pull_request.review_decision, "CHANGES_REQUESTED"))
    assert %{"pull_request" => %{"review_state" => "changes_requested", "review_rounds" => 0}} = ticket_read("PR-4")
  end

  test "a ticket the watcher stopped watching still reads its PR, with no next action, and says it merged" do
    read = watcher_read([check("Tests", "SUCCESS", workflow: "CI", run: 100, job: 1)])
    watched("merged", "PR-5", read)
    :ok = TicketPullRequest.put(@repo, "merged", %{pr_url: @pr_url, branch: "auto/TP-1"})

    assert %{"pull_request" => %{"state" => "open", "next_action" => %{}}} = ticket_read("PR-5")

    :ok = RunStore.put_ticket_pr_watch(@repo, "merged", "PR-5", nil)
    :ok = TicketPullRequest.mark_finished(@repo, @pr_url, "merged")

    assert %{
             "watch" => nil,
             "pull_request" => %{"number" => 741, "state" => "merged", "review_state" => "merged", "red_kind" => nil, "next_action" => nil, "checks" => [%{"workflow" => "CI"}]}
           } = ticket_read("PR-5")
  end

  test "the ticket's newer PR is not taken for the one the watcher read" do
    watched("newer", "PR-6", watcher_read([]))
    :ok = TicketPullRequest.put(@repo, "newer", %{pr_url: "https://github.com/acme/app/pull/999", branch: "auto/TP-1"})
    :ok = TicketPullRequest.mark_finished(@repo, "https://github.com/acme/app/pull/999", "closed")

    assert %{"pull_request" => %{"number" => 741, "state" => "open", "checks" => []}} = ticket_read("PR-6")
  end

  test "before the watcher has read a PR the read has none" do
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "new", issue_identifier: "PR-7", phase: "In Progress"})

    assert %{"pull_request" => nil} = ticket_read("PR-7")
    assert PullRequestPayload.read(nil) == nil
  end

  test "a PR with no head reads as such, and a decision not yet made as no next action" do
    pull_request = Snapshot.build(%{pr_number: 1, pr_url: @pr_url, pr_title: nil, pr: :open, head_sha: nil, base_ref: nil, mergeable: :unknown}, %{}, [], nil)

    assert %{head_short: nil, read_at: nil, next_action: nil, red_kind: nil, behind_base: false} =
             PullRequestPayload.read(%{repo_key: @repo, issue_id: "none", pull_request: pull_request, pr_watch: %{decision: nil}})
  end

  test "each of the state's issues carries the same pull request" do
    watched("listed", "PR-8", watcher_read([check("Tests", "FAILURE", workflow: "CI", run: 100, job: 1)]))

    assert %{"issues" => [issue]} = build_conn() |> get("/api/v1/state") |> json_response(200)
    assert %{"identifier" => "PR-8", "pull_request" => pull_request} = issue
    assert pull_request == ticket_read("PR-8")["pull_request"]
    assert %{"checks" => [%{"workflow" => "CI", "checks" => [%{"name" => "Tests", "state" => "failed"}]}], "next_action" => %{"rule" => _rule}} = pull_request
  end
end
