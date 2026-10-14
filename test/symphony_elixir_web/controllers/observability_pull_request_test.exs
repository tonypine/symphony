defmodule SymphonyElixirWeb.ObservabilityPullRequestTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog
  import Phoenix.ConnTest

  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.PullRequestPage

  @endpoint SymphonyElixirWeb.Endpoint
  @url "https://github.com/tonypine/symphony/pull/448"

  # PR #448 on TP-892 changes 14 files across four areas.
  @files [
    {"priv/playbook/parent_tickets.liquid", 2, 120},
    {"priv/playbook/plan_pipeline.liquid", 1, 90},
    {".symphony/instructions/020-review.md", 4, 60},
    {".agents/skills/land/SKILL.md", 3, 40},
    {"lib/symphony_elixir/retired_states.ex", 30, 120},
    {"lib/symphony_elixir/transition_guard.ex", 10, 40},
    {"lib/symphony_elixir/code_review.ex", 6, 20},
    {"lib/symphony_elixir/qa_verification.ex", 8, 30},
    {"docs/design/state-machine.md", 12, 50},
    {"SPEC.md", 4, 10},
    {"test/symphony_elixir/retired_states_test.exs", 20, 10},
    {"test/symphony_elixir/transition_guard_test.exs", 15, 12},
    {"test/symphony_elixir/code_review_test.exs", 5, 8},
    {"mix.exs", 0, 0}
  ]

  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, opts), do: {:reply, Keyword.fetch!(opts, :snapshot), opts}
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config) end)
    :ok
  end

  test "an open pull request with two Code Review verdicts" do
    start_endpoint!(page_opts())

    payload = json_response(get(build_conn(), "/api/v1/pull_requests/symphony/448"), 200)

    assert %{
             "number" => 448,
             "url" => @url,
             "title" => "TP-892 Retire two old review steps",
             "repo_key" => "symphony",
             "ticket" => %{"identifier" => "TP-892", "title" => "Retire two old review steps", "state" => "Rework", "waiting_on" => "a slot"},
             "github" => "available",
             "state" => "open",
             "review_state" => "changes_requested",
             "opened_at" => "2026-10-12T09:00:00Z",
             "last_pushed_at" => "2026-10-13T08:30:00Z",
             "merged_at" => nil,
             "summary" => "The Final verification and Supervisor check steps are gone, so a ticket goes from QA straight to Merging.",
             "size" => %{"files" => 14, "additions" => 120, "deletions" => 610, "commits" => 3}
           } = payload

    assert payload["review_history"] == [
             %{"at" => "2026-10-13T05:00:00Z", "kind" => "code_review", "verdict" => "request_changes", "reason" => "The playbook still names the Final verification step."},
             %{"at" => "2026-10-13T08:40:00Z", "kind" => "code_review", "verdict" => "request_changes", "reason" => "The review instructions still describe the Supervisor check."}
           ]

    assert payload["areas"] == [
             %{"name" => "Agent instructions", "files" => 4, "additions" => 10, "deletions" => 310},
             %{"name" => "Server", "files" => 4, "additions" => 54, "deletions" => 210},
             %{"name" => "Documentation", "files" => 2, "additions" => 16, "deletions" => 60},
             %{"name" => "Tests", "files" => 3, "additions" => 40, "deletions" => 30},
             %{"name" => "Other", "files" => 1, "additions" => 0, "deletions" => 0}
           ]

    assert payload["health"] == %{
             "checks" => %{"state" => "passed", "passed" => 9, "failed" => 0, "pending" => 0},
             "code_review" => %{"verdict" => "request_changes", "round" => 2},
             "qa" => nil,
             "overlaps" => [%{"number" => 483, "ticket" => "TP-971"}]
           }

    body = Jason.encode!(payload)
    for {path, _additions, _deletions} <- @files, do: refute(body =~ path, "the page names #{path}")
  end

  test "a merged pull request, with the ticket's wait read from what runs now" do
    merged = fn _url -> {:ok, pull_request(state: "MERGED", merged_at: ~U[2026-10-14 10:00:00Z], review_decision: "APPROVED")} end
    snapshot = %{running: [%{issue_id: "id-TP-892"}]}
    start_endpoint!(page_opts(pull_request: merged), snapshot: snapshot)

    payload = json_response(get(build_conn(), "/api/v1/pull_requests/symphony/448"), 200)

    assert %{"state" => "merged", "review_state" => "merged", "merged_at" => "2026-10-14T10:00:00Z", "github" => "available"} = payload
    assert payload["ticket"]["waiting_on"] == nil
  end

  test "with GitHub unavailable it answers what Linear and Symphony's records know" do
    start_endpoint!(page_opts(pull_request: fn _url -> {:error, {:gh_failed, ["pr", "view"], 1, "HTTP 502"}} end))

    log =
      capture_log(fn ->
        payload = json_response(get(build_conn(), "/api/v1/pull_requests/symphony/448"), 200)

        assert %{
                 "github" => "unavailable",
                 "number" => 448,
                 "url" => @url,
                 "title" => nil,
                 "ticket" => %{"identifier" => "TP-892", "state" => "Rework"},
                 "review_state" => "changes_requested",
                 "areas" => [],
                 "size" => nil
               } = payload

        assert [%{"kind" => "code_review", "at" => "2026-10-13T05:00:00Z"}, %{"kind" => "code_review", "at" => "2026-10-13T08:40:00Z"}] = payload["review_history"]
        assert %{"checks" => nil, "code_review" => %{"round" => 2}, "overlaps" => [%{"number" => 483}]} = payload["health"]
      end)

    assert log =~ "could not read #{@url} from GitHub"
  end

  test "an unknown repo and a pull request GitHub doesn't have answer 404" do
    start_endpoint!(page_opts(pull_request: fn _url -> {:error, :not_found} end))

    assert %{"error" => %{"code" => "unknown_repo"}} = json_response(get(build_conn(), "/api/v1/pull_requests/elsewhere/448"), 404)
    assert %{"error" => %{"code" => "not_found"}} = json_response(get(build_conn(), "/api/v1/pull_requests/symphony/9999"), 404)
    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(post(build_conn(), "/api/v1/pull_requests/symphony/448", %{}), 405)
  end

  test "reads the configured repos when none are given, and keeps no page while its table is gone" do
    start_endpoint!(Keyword.delete(page_opts(), :github_repos))
    # The test workflow's repo has no GitHub repository.
    assert %{"error" => %{"code" => "unknown_repo"}} = json_response(get(build_conn(), "/api/v1/pull_requests/symphony/448"), 404)

    File.write!(Workflow.symphony_file_path(), "repositories: []\n")
    Cache.clear()
    assert %{"error" => %{"code" => "unknown_repo"}} = json_response(get(build_conn(), "/api/v1/pull_requests/symphony/448"), 404)

    stop_supervised!(SymphonyElixirWeb.Endpoint)
    start_endpoint!(Keyword.put(page_opts(), :ttl_ms, 60_000))
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, PullRequestPage)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, PullRequestPage) end)

    assert %{"github" => "available"} = json_response(get(build_conn(), "/api/v1/pull_requests/symphony/448"), 200)
  end

  defp start_endpoint!(page_opts, orchestrator_opts \\ []) do
    orchestrator = Module.concat(__MODULE__, :"Orchestrator#{System.unique_integer([:positive])}")
    snapshot = Keyword.get(orchestrator_opts, :snapshot, %{running: []})
    spec = Supervisor.child_spec({SnapshotOrchestrator, name: orchestrator, snapshot: snapshot}, id: orchestrator)
    start_supervised!(spec)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator,
        inbox: Module.concat(__MODULE__, :Inbox),
        snapshot_timeout_ms: 50,
        pull_request_page: page_opts
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  # The fake GitHub, Linear and Symphony records behind TP-892's PR #448: Code Review sent it back
  # twice, and TP-971's open PR #483 changes one of its files.
  defp page_opts(overrides \\ []) do
    linear = fn _query, %{url: @url}, _opts ->
      issue = %{
        "id" => "id-TP-892",
        "identifier" => "TP-892",
        "title" => "Retire two old review steps",
        "state" => %{"name" => "Rework", "type" => "started"},
        "inverseRelations" => %{"nodes" => []}
      }

      {:ok, %{"data" => %{"attachmentsForURL" => %{"nodes" => [%{"issue" => issue}]}, "issues" => %{"nodes" => [issue]}}}}
    end

    record = %{
      issue_id: "id-TP-892",
      verdicts: [
        %{kind: "code_review", head_sha: "c3", outcome: "request_changes", recorded_at: ~U[2026-10-13 08:40:00Z]},
        %{kind: "code_review", head_sha: "c1", outcome: "request_changes", recorded_at: ~U[2026-10-13 05:00:00Z]}
      ],
      signals: [
        %{name: "code_review", at: ~U[2026-10-13 08:40:03Z], details: %{signal: "code_review_rework", reason: "The review instructions still describe the Supervisor check. Findings follow."}},
        %{name: "code_review", at: ~U[2026-10-13 05:00:02Z], details: %{signal: "code_review_rework", reason: "The playbook still names the Final verification step."}}
      ]
    }

    reviews = [
      %{issue_id: "id-TP-892", issue_identifier: "TP-892", pr_url: @url, landing: %{files: ["lib/symphony_elixir/code_review.ex", "mix.exs"]}},
      %{issue_id: "id-TP-971", issue_identifier: "TP-971", pr_url: "https://github.com/tonypine/symphony/pull/483", landing: %{files: ["mix.exs", "macos/README.md"]}},
      %{issue_id: "id-TP-980", issue_identifier: "TP-980", pr_url: "https://github.com/tonypine/symphony/pull/490", landing: %{files: ["lib/elsewhere.ex"]}}
    ]

    Keyword.merge(
      [
        github_repos: %{"symphony" => "tonypine/symphony"},
        pull_request: fn @url -> {:ok, pull_request()} end,
        linear_client: linear,
        ticket_state: fn "symphony", "id-TP-892" -> record end,
        pr_reviews: fn "symphony" -> reviews end,
        ttl_ms: 0
      ],
      overrides
    )
  end

  defp pull_request(overrides \\ []) do
    Map.merge(
      %{
        number: 448,
        url: @url,
        title: "TP-892 Retire two old review steps",
        body: """
        ## References

        - Ticket: [TP-892](https://linear.app/tonypine/issue/TP-892)

        ## This PR

        The **Final verification** and *Supervisor check* steps are gone, so a ticket goes from `QA` straight to Merging.
        """,
        state: "OPEN",
        review_decision: nil,
        changed_files: 14,
        additions: 120,
        deletions: 610,
        head_ref_name: "auto/TP-892",
        checks: "passed",
        created_at: ~U[2026-10-12 09:00:00Z],
        merged_at: nil,
        last_pushed_at: ~U[2026-10-13 08:30:00Z],
        files: Enum.map(@files, fn {path, additions, deletions} -> %{path: path, additions: additions, deletions: deletions} end),
        commits: ["c1", "c2", "c3"],
        check_counts: %{passed: 9, failed: 0, pending: 0}
      },
      Map.new(overrides)
    )
  end
end
