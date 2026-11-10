defmodule SymphonyElixirWeb.WatchPayloadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.TicketState
  alias SymphonyElixirWeb.WatchPayload

  # The `watch` block's contract with the app: the app's decoding tests read this file too.
  @fixture Path.expand("../fixtures/api/watch_block.json", __DIR__)
  # The `app_update` block's contract with the app, read by its `StateSnapshotTests` too.
  @app_update_fixture Path.expand("../fixtures/api/app_update_block.json", __DIR__)

  @at ~U[2026-10-16 12:00:00.250Z]

  # A Rework ticket the watcher decided to dispatch, quiet for two ticks.
  def record(watch \\ %{}) do
    facts = Facts.new(phase: :rework, pr: :open, pr_number: 42, ci: :green, mergeable: :clean)

    TicketState.new("default", "issue-42", %{
      issue_identifier: "TP-42",
      pr_watch:
        Map.merge(
          %{
            facts: facts,
            pr_url: "https://github.com/acme/app/pull/42",
            head_sha: "abc123",
            source: :poll,
            read_at: @at,
            github: :ok,
            rate_limit: %{remaining: 4321, limit: 5000, reset_at: ~U[2026-10-16 13:00:00Z]},
            stay: :rework,
            decision: %{
              rule: "R26",
              kind: :dispatch,
              reason: "Rework: PR #42 is not red and not conflicting, and no run is active",
              owner: nil,
              clears_when: nil,
              args: %{},
              waits_on: nil,
              head_sha: "abc123",
              decided_at: @at,
              since: ~U[2026-10-16 11:59:30Z],
              outcome: :recorded,
              error: nil
            },
            applied: [],
            links: [],
            actions: [%{rule: "R21", kind: :ci_fix, head_sha: "abc000", at: ~U[2026-10-16 11:50:00Z], source: :poll}],
            silent: %{since: ~U[2026-10-16 11:59:30Z], ticks: 2, bound: nil, reason: "R26 decided `dispatch`, but no run started and no wait is recorded"}
          },
          watch
        )
    })
  end

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  test "the watch block matches the contract the app decodes" do
    assert json(WatchPayload.watch(record())) == @fixture |> File.read!() |> Jason.decode!()
  end

  test "a head red only on protected paths lists the protected files its PR changes" do
    facts = Facts.new(phase: :code_review, pr: :open, pr_number: 42, ci: :green, red_kind: :human_only, failing_check: "protected paths")
    files = %{head_sha: "abc123", paths: ["WORKFLOW.md"]}

    assert %{"facts" => %{"protected_files" => ["WORKFLOW.md"]}} = json(WatchPayload.watch(record(%{facts: facts, protected_files: files})))

    # Files read on an older head aren't this head's.
    assert %{"facts" => %{"protected_files" => []}} = json(WatchPayload.watch(record(%{facts: facts, protected_files: %{files | head_sha: "abc000"}})))
  end

  test "a wait keeps its own owner and clearing condition" do
    decision = %{rule: "R23", kind: :wait, reason: "The base is red too", owner: :ci, clears_when: "the base goes green", since: nil, outcome: :recorded}

    assert %{owner: "ci", clears_when: "the base goes green", action: "wait"} = WatchPayload.watch(record(%{decision: decision}))
  end

  test "a ticket the watcher doesn't watch has no watch block" do
    assert WatchPayload.watch(TicketState.new("default", "issue-1")) == nil
    assert WatchPayload.watch(nil) == nil
  end

  test "the summary reads the facts in one line" do
    summary = fn facts, watch -> WatchPayload.watch(record(Map.merge(%{facts: Facts.new(facts)}, watch))).summary end

    assert summary.([pr: :open, pr_number: 42, ci: :none, mergeable: :behind], %{}) == "PR #42 open · no CI · behind the base"
    assert summary.([pr: :missing, pr_number: 42], %{}) == "no PR"
    assert summary.([pr: :merged], %{}) == "merged"

    # A check the base doesn't require still runs on a green head: the summary names it.
    assert summary.([pr: :open, pr_number: 42, ci: :green, running_checks: ["e2e", "docs"], mergeable: :clean], %{}) ==
             "PR #42 open · CI green · still running: e2e, docs · no conflict"

    assert summary.([pr: :open, pr_number: 42, ci: :green, mergeable: :clean], %{}) == "PR #42 open · CI green · no conflict"
    assert summary.([pr: :open, pr_number: 42, ci: :pending, running_checks: ["e2e"], mergeable: :clean], %{}) == "PR #42 open · CI running · no conflict"

    busy = [pr: :draft, pr_number: 7, ci: :red, mergeable: :dirty, auto_merge: :armed, run: :active, hold: :blocked]

    assert summary.(busy, %{github: {:rate_limited, nil}}) ==
             "PR #7 a draft · CI red · conflicts with the base · auto-merge on · run active · Blocked hold · GitHub rate limited"

    # TP-1204: the review's state, beside CI's.
    red_head = [phase: :code_review, pr: :open, pr_number: 42, ci: :red, mergeable: :clean]
    assert summary.(red_head ++ [run: :active], %{}) == "PR #42 open · CI red · no conflict · reviewing"
    assert summary.(red_head ++ [review: :approved], %{}) == "PR #42 open · CI red · no conflict · approved"

    # No decision yet, nor a phase from a move.
    assert %{rule: nil, action: nil, owner: nil, since: nil, phase: "qa", actions: [], silent: nil, facts: %{"github" => "rate_limited"}} =
             record(%{facts: Facts.new(phase: :qa), stay: nil, decision: nil, actions: [], silent: nil, github: {:rate_limited, @at}, rate_limit: nil})
             |> WatchPayload.watch()
             |> json()
             |> then(fn block -> Map.new(block, fn {key, value} -> {String.to_atom(key), value} end) end)
  end

  test "a held ticket's silent wait with no watcher record gives its record's phase and no PR or rule (TP-1175)" do
    assert %{"phase" => "in_progress", "pr_url" => nil, "rule" => nil, "bound" => "no_progress"} =
             json(
               WatchPayload.silent_wait(%{
                 issue_id: "issue-42",
                 issue_identifier: "TP-42",
                 repo_key: "default",
                 phase: "in_progress",
                 pr_url: nil,
                 since: @at,
                 rule: nil,
                 bound: "no_progress",
                 reason: "No progress"
               })
             )
  end

  test "a silent wait and the rate limit, as the state API lists them" do
    assert json(
             WatchPayload.silent_wait(%{
               issue_id: "issue-42",
               issue_identifier: "TP-42",
               repo_key: "default",
               phase: :rework,
               pr_url: "https://github.com/acme/app/pull/42",
               since: @at,
               rule: "R26",
               bound: nil,
               reason: "quiet"
             })
           ) == %{
             "issue_id" => "issue-42",
             "identifier" => "TP-42",
             "repo_key" => "default",
             "phase" => "rework",
             "pr_url" => "https://github.com/acme/app/pull/42",
             "since" => "2026-10-16T12:00:00Z",
             "rule" => "R26",
             "bound" => nil,
             "reason" => "quiet"
           }

    assert WatchPayload.rate_limit(%{remaining: 12, limit: 5000, reset_at: @at}) ==
             %{remaining: 12, limit: 5000, reset: "2026-10-16T12:00:00Z"}

    assert WatchPayload.rate_limit(%{remaining: 12, reset_at: nil}) == %{remaining: 12, limit: nil, reset: nil}
    assert WatchPayload.rate_limit(nil) == nil
  end

  describe "app_update/2" do
    @blocked [
      %{issue_id: "issue-1037", identifier: "TP-1037", kind: :app_update, build_line: "Waiting for the v0.0.1.750 build: queued on GitHub for 23 min"},
      %{issue_id: "issue-9", identifier: "TP-9", blockers: []}
    ]

    test "the app_update block matches the contract the app decodes" do
      release = %{
        repo: "tonypine/symphony",
        tag: "v0.0.1.583",
        published_at: ~U[2026-10-16 08:00:00.123Z],
        etag: ~s("e1"),
        source: :webhook,
        recorded_at: @at
      }

      latest_build = %{
        sha: "9f54098b96666e6e233247d53fc995c3b293c4f2",
        version: "0.0.1.750",
        state: "queued",
        since: ~U[2026-10-16 08:02:00Z],
        reruns: 1,
        url: "https://github.com/tonypine/symphony/actions/runs/41086214847",
        line: "The v0.0.1.750 build: queued on GitHub for 23 min; cancelled for lack of a machine, rerun 1 of 2"
      }

      contract = @app_update_fixture |> File.read!() |> Jason.decode!()
      assert json(WatchPayload.app_update(@blocked, release, latest_build)) == contract
    end

    test "with no ticket held, the build line is the newest merge's build" do
      latest_build = %{sha: "9f54098b", version: "0.0.1.785", state: "queued", since: nil, reruns: 0, url: nil, line: "The v0.0.1.785 build: queued on GitHub for 12 min"}

      assert %{unblocks: 0, build_line: "The v0.0.1.785 build: queued on GitHub for 12 min", latest_build: %{state: "queued", since: nil}} =
               WatchPayload.app_update([], nil, latest_build)

      assert %{build_line: "Waiting for the v0.0.1.750 build: queued on GitHub for 23 min"} = WatchPayload.app_update(@blocked, nil, latest_build)
    end

    test "no release is null, and a release without a publish time keeps its tag" do
      empty = %{unblocks: 0, issue_identifiers: [], latest_release: nil, build_line: nil, latest_build: nil}
      assert WatchPayload.app_update([], nil) == empty

      release = %{repo: "tonypine/symphony", tag: "v2", published_at: nil, etag: nil, source: :poll, recorded_at: @at}

      assert %{unblocks: 1, latest_release: %{tag: "v2", published_at: nil, source: :poll}} =
               WatchPayload.app_update(@blocked, release)
    end
  end
end
