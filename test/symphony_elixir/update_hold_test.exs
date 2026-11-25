defmodule SymphonyElixir.UpdateHoldTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Pauses, TicketPullRequest, TicketState, UpdateHold}

  @repo_key "repo-a"

  @build_sha "d3d301b0123456789abcdef0123456789abcdef0"
  @merge_sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
  @build %{version: "0.0.1.168", sha: @build_sha, repo: "https://github.com/acme/symphony"}
  @fix_pr "https://github.com/acme/symphony/pull/132"
  @other_pr "https://github.com/acme/symphony/pull/133"
  @other_sha "bbbbbbb2bbbbbbb2bbbbbbb2bbbbbbb2bbbbbbb2"
  @terminal ["Done", "Canceled"]

  # `resolve/5` writes the tickets' pauses in the store.
  setup do
    :ok = RunStore.clear()
    on_exit(fn -> :ok = RunStore.clear() end)
  end

  describe "resolve/5 and hold/4" do
    test "hold a Todo ticket until the running build includes its blocker's merge commit" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      fix_issue("TP-419", @fix_pr)

      cache = resolve([issue], included: false)

      assert cache.blockers == %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}
      assert cache.included == %{{@merge_sha, @build_sha} => false}

      assert UpdateHold.hold(issue, @build, cache, @terminal) == %{
               blockers: [%{identifier: "TP-419", merge_sha: @merge_sha, pull_request: 132}],
               build_sha: @build_sha,
               reasons: [%{kind: :build, waits_on: %{pull_request: 132}, text: "Waiting for a Symphony update that includes TP-419's fix"}]
             }

      included = %{cache | included: %{{@merge_sha, @build_sha} => true}}
      assert UpdateHold.hold(issue, @build, included, @terminal) == nil
    end

    test "names every blocker still missing from the build" do
      unnamed = %{id: "id-x", identifier: nil, state: "Done"}
      issue = todo_blocked_by([blocker("TP-1", "Done"), unnamed])

      cache = %{
        blockers: %{"id-TP-1" => {:merged, @fix_pr, "aaaaaaa1"}, "id-x" => {:merged, @other_pr, "bbbbbbb2"}},
        included: %{{"aaaaaaa1", @build_sha} => false, {"bbbbbbb2", @build_sha} => false}
      }

      assert %{reasons: [%{text: "Waiting for a Symphony update that includes TP-1's fix"}, %{text: "Waiting for a Symphony update that includes the fix in PR #133"}]} =
               UpdateHold.hold(issue, @build, cache, @terminal)
    end

    test "a blocker merged in another repository releases its dependents at Done" do
      issue = todo_blocked_by(blocker("APP-1", "Done"))
      fix_issue("APP-1", "https://github.com/acme/web-app/pull/5")

      cache = resolve([issue], merge_commit_sha: fn _url -> flunk("not the build's repository") end)

      assert cache.blockers == %{"id-APP-1" => :none}
      assert cache.included == %{}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "a blocker whose recorded link is not a GitHub pull request releases its dependents" do
      issue = todo_blocked_by(blocker("TP-5", "Done"))
      fix_issue("TP-5", "https://linear.app/not-a-pr")

      cache = resolve([issue], merge_commit_sha: fn _url -> flunk("not a pull request") end)

      assert cache.blockers == %{"id-TP-5" => :none}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "a blocker with an unmerged or no pull request releases its dependents" do
      issue = todo_blocked_by([blocker("TP-2", "Canceled"), blocker("TP-3", "Done")])

      fix_issue("TP-2", @fix_pr)
      fix_issue("TP-3")
      cache = resolve([issue], merge_commit_sha: fn @fix_pr -> {:ok, nil} end)

      assert cache.blockers == %{"id-TP-2" => :none, "id-TP-3" => :none}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "the skip-update-hold label opts out on the held ticket or on the blocker" do
      labelled = %Issue{todo_blocked_by(blocker("TP-419", "Done")) | labels: [" Skip-Update-Hold "]}
      merged_cache = not_included_cache()

      assert resolve([labelled], no_lookups()) == UpdateHold.empty_cache()
      assert UpdateHold.hold(labelled, @build, merged_cache, @terminal) == nil

      # The blocker's own record carries the label.
      issue = todo_blocked_by(Map.put(blocker("TP-419", "Done"), :labels, [UpdateHold.skip_label()]))
      fix_issue("TP-419", @fix_pr)

      cache = resolve([issue], merge_commit_sha: fn _url -> flunk("opted out") end)

      assert cache.blockers == %{"id-TP-419" => :skip}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "the release gate's fix ticket is never held for an app update (TP-1528)" do
      issue = %Issue{todo_blocked_by(blocker("TP-419", "Done")) | repo_key: @repo_key}
      cache = %{blockers: %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}, included: %{{@merge_sha, @build_sha} => false}}
      assert %{blockers: [_blocker]} = UpdateHold.hold(issue, @build, cache, @terminal)

      :ok = RunStore.put_github_updates({:release_gate_fix, @repo_key}, %{identifier: "TP-332", red: true})
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "only Todo tickets whose stored dependencies are all met are looked up or held" do
      open_blocker = todo_blocked_by(blocker("TP-5", "In Review"), "open")
      running = %Issue{todo_blocked_by(blocker("TP-6", "Done"), "running") | state: "In Progress"}
      unblocked = todo_blocked_by([], "free")
      no_state = %Issue{todo_blocked_by(blocker("TP-8", "Done"), "stateless") | state: nil}
      # A dependency on a ticket Symphony holds no record of is never met.
      unknown = todo_blocked_by(blocker("TP-9", :no_record), "unknown")
      # A ticket with no record at all has no stored dependency.
      unrecorded = %Issue{id: "unrecorded", identifier: "TP-10", state: "Todo"}

      assert resolve([open_blocker, running, unblocked, no_state, unknown, unrecorded, :not_an_issue], no_lookups()) ==
               UpdateHold.empty_cache()

      cache = %{not_included_cache() | blockers: %{"id-TP-6" => {:merged, @fix_pr, @merge_sha}}}
      assert UpdateHold.hold(running, @build, cache, @terminal) == nil
      assert UpdateHold.hold(%Issue{unrecorded | id: nil}, @build, cache, @terminal) == nil
    end

    test "a dependency met by a merged ticket waiting on its own sub-tickets holds nothing and is not looked up" do
      SymphonyElixir.SubIssueWait.reset_for_test("Waiting on sub-tickets")
      issue = todo_blocked_by(blocker("TP-50", "Waiting on sub-tickets"))
      :ok = RunStore.put_merged_wait("id-TP-50")
      fix_issue("TP-50", @fix_pr)

      assert resolve([issue], no_lookups()) == UpdateHold.empty_cache()
      assert UpdateHold.hold(issue, @build, UpdateHold.empty_cache(), @terminal) == nil
    end

    test "cached blockers and merge commits are not looked up again" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      cache = not_included_cache()
      no_compare = fn _url, _sha, _build -> flunk("cached") end

      no_sha = fn _url -> flunk("cached") end

      assert resolve([issue], cache: cache, merge_commit_sha: no_sha, commit_included?: no_compare) == cache
    end

    test "a build without a sha or repository holds nothing and looks nothing up" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      cache = not_included_cache()
      lookups = [merge_commit_sha: fn _url -> flunk("no build") end]

      for build <- [%{@build | sha: nil}, %{@build | repo: nil}] do
        empty = UpdateHold.empty_cache()
        assert UpdateHold.resolve([issue], build, empty, @terminal, lookups) == empty

        assert UpdateHold.hold(issue, build, cache, @terminal) == nil
      end
    end

    test "a failed lookup is not cached and does not hold the ticket" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      fix_issue("TP-419", @fix_pr)

      gh_down = resolve([issue], merge_commit_sha: fn _url -> {:error, :gh_down} end)
      assert gh_down == UpdateHold.empty_cache()

      not_found = fn _url, _sha, _build -> {:error, :not_found} end
      compare_down = resolve([issue], commit_included?: not_found)
      assert compare_down.blockers == %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}
      assert compare_down.included == %{}
      assert UpdateHold.hold(issue, @build, compare_down, @terminal) == nil
    end

    test "a blocker's pull request is the one Symphony recorded for it, merged or closed" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      # The blocker's record names its repo: its pull request is looked up under it.
      fix = fix_issue("TP-419")
      :ok = TicketPullRequest.record_created(@repo_key, fix.id, @fix_pr, "auto/TP-419")
      :ok = TicketPullRequest.mark_finished(@repo_key, @fix_pr, "merged")

      cache = resolve([issue], repo_key: "another-lane")

      assert cache.blockers == %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}
      assert %{blockers: [%{identifier: "TP-419"}]} = UpdateHold.hold(issue, @build, cache, @terminal)

      # A closed record merged nothing.
      :ok = TicketPullRequest.record_created(@repo_key, fix.id, @fix_pr, "auto/TP-419")
      :ok = TicketPullRequest.mark_finished(@repo_key, @fix_pr, "closed")

      cache = resolve([issue], merge_commit_sha: fn @fix_pr -> {:ok, nil} end)

      assert cache.blockers == %{"id-TP-419" => :none}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "a blocker reopened is not looked up" do
      issue = todo_blocked_by(blocker("TP-419", "In Progress"))
      fix_issue("TP-419", @fix_pr)

      assert resolve([issue], no_lookups()) == UpdateHold.empty_cache()
    end
  end

  describe "the wait on the ticket's pause" do
    test "a Todo ticket waits for the update on its stored dependency and starts by itself once the build includes the fix" do
      # The ticket read from Linear carries no blocker link at all: the dependency is Symphony's own.
      refute Map.has_key?(%Issue{}, :blocked_by)
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      fix_issue("TP-419", @fix_pr)

      resolve([issue], included: false)
      assert [%{kind: :build, waits_on: %{pull_request: 132}}] = UpdateHold.reasons(@repo_key, "issue")

      # The app updates to a build that includes the merge: the reason clears, and the dispatch gate,
      # which reads the reasons, lets the ticket start with no one's action.
      included = %{not_included_cache() | included: %{{@merge_sha, @build_sha} => true}}
      resolve([issue], no_lookups(cache: included))
      assert UpdateHold.reasons(@repo_key, "issue") == []
      assert Pauses.get({:ticket, @repo_key, "issue"}) == {:ok, nil}
      assert UpdateHold.hold(issue, @build, included, @terminal) == nil
    end

    test "resolve/5 writes one build reason per blocker the build lacks, once, and it outlasts a restart" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      fix_issue("TP-419", @fix_pr)

      log = capture_log(fn -> resolve([issue]) end)
      assert log =~ "Holding for an app update: issue_id=issue issue_identifier=TP-332; Waiting for a Symphony update that includes TP-419's fix"

      assert [
               %{
                 kind: :build,
                 waits_on: %{pull_request: 132},
                 text: "Waiting for a Symphony update that includes TP-419's fix",
                 set_by: %{kind: :rule, name: "App update hold"},
                 releasable: false
               }
             ] = UpdateHold.reasons(@repo_key, "issue")

      # The next poll writes nothing new and logs nothing.
      cache = not_included_cache()
      refute capture_log(fn -> resolve([issue], no_lookups(cache: cache)) end) =~ "app update"
      assert [_one] = UpdateHold.reasons(@repo_key, "issue")

      # After a restart nothing is in memory and the lookup fails: the reason stays.
      assert resolve([issue], merge_commit_sha: fn _url -> {:error, :github_down} end) == UpdateHold.empty_cache()
      assert [%{waits_on: %{pull_request: 132}}] = UpdateHold.reasons(@repo_key, "issue")
    end

    test "the build that includes the fix clears the reason on the next resolve" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      set_reason(132, "TP-419")

      included = %{not_included_cache() | included: %{{@merge_sha, @build_sha} => true}}
      log = capture_log(fn -> resolve([issue], no_lookups(cache: included)) end)

      assert log =~ "Released from the app update hold: issue_id=issue issue_identifier=TP-332"
      assert Pauses.get({:ticket, @repo_key, "issue"}) == {:ok, nil}
    end

    test "each reason clears on its own as its build arrives" do
      issue = todo_blocked_by([blocker("TP-1", "Done"), blocker("TP-2", "Done")])
      set_reason(132, "TP-1")
      set_reason(133, "TP-2")

      cache = %{
        blockers: %{"id-TP-1" => {:merged, @fix_pr, @merge_sha}, "id-TP-2" => {:merged, @other_pr, @other_sha}},
        included: %{{@merge_sha, @build_sha} => true, {@other_sha, @build_sha} => false}
      }

      refute capture_log(fn -> resolve([issue], no_lookups(cache: cache)) end) =~ "Released"
      assert [%{waits_on: %{pull_request: 133}}] = UpdateHold.reasons(@repo_key, "issue")
    end

    test "the skip-update-hold label prevents the reason, or clears it" do
      labelled = %Issue{todo_blocked_by(blocker("TP-419", "Done")) | labels: [UpdateHold.skip_label()]}

      resolve([labelled], no_lookups(cache: not_included_cache()))
      assert Pauses.get({:ticket, @repo_key, "issue"}) == {:ok, nil}

      set_reason(132, "TP-419")
      resolve([labelled], no_lookups(cache: not_included_cache()))
      assert Pauses.get({:ticket, @repo_key, "issue"}) == {:ok, nil}
    end

    test "a ticket out of Todo, with an open blocker, or on a build without a sha loses the reason" do
      held = todo_blocked_by(blocker("TP-419", "Done"))
      moved = %Issue{held | state: "In Progress"}

      set_reason(132, "TP-419")
      resolve([moved], no_lookups(cache: not_included_cache()))
      assert Pauses.get({:ticket, @repo_key, "issue"}) == {:ok, nil}

      # The blocker reopened: its record is back in progress.
      reopened = todo_blocked_by(blocker("TP-419", "In Progress"))
      set_reason(132, "TP-419")
      resolve([reopened], no_lookups(cache: not_included_cache()))
      assert Pauses.get({:ticket, @repo_key, "issue"}) == {:ok, nil}

      todo_blocked_by(blocker("TP-419", "Done"))
      set_reason(132, "TP-419")
      UpdateHold.resolve([held], %{@build | sha: nil}, not_included_cache(), @terminal, repo_key: @repo_key)
      assert Pauses.get({:ticket, @repo_key, "issue"}) == {:ok, nil}
    end

    test "a ticket whose stored dependency a person removed is no longer held for a build" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      set_reason(132, "TP-419")

      :ok = RunStore.remove_dependency("issue", "id-TP-419")
      resolve([issue], no_lookups(cache: not_included_cache()))
      assert Pauses.get({:ticket, @repo_key, "issue"}) == {:ok, nil}
      assert UpdateHold.hold(issue, @build, not_included_cache(), @terminal) == nil
    end

    test "a reason whose blocker no longer merged there clears; one the cache can't answer for stays" do
      unknown = todo_blocked_by(blocker("TP-7", "Done"))
      set_reason(132, "TP-419")
      fix_issue("TP-7", @other_pr)
      resolve([unknown], merge_commit_sha: fn _url -> {:error, :github_down} end)
      assert [%{waits_on: %{pull_request: 132}}] = UpdateHold.reasons(@repo_key, "issue")

      # Its blocker merged nothing: no blocker of the ticket merged that pull request.
      resolve([unknown], merge_commit_sha: fn @other_pr -> {:ok, nil} end)
      assert Pauses.get({:ticket, @repo_key, "issue"}) == {:ok, nil}
    end

    test "only its own reasons are cleared, and a ticket without a repo key is not written" do
      ticket = {:ticket, @repo_key, "issue"}
      moved = %Issue{todo_blocked_by(blocker("TP-419", "Done")) | state: "In Progress"}
      {:ok, _pause} = Pauses.set(ticket, Pauses.ticket_reason(:dependency, "TP-9"))
      {:ok, _pause} = Pauses.set(ticket, %{kind: :build, waits_on: %{pull_request: 132}})
      set_reason(132, "TP-419")

      resolve([moved], no_lookups())
      assert {:ok, %{reasons: [%{kind: :ticket}, %{kind: :build, set_by: %{kind: :symphony}}]}} = Pauses.get(ticket)
      assert UpdateHold.reasons(@repo_key, "issue") == []

      issue = todo_blocked_by(blocker("TP-419", "Done"))
      assert %{blockers: [_one]} = UpdateHold.hold(issue, @build, not_included_cache(), @terminal)
      other = todo_blocked_by(blocker("TP-419", "Done"), "other")
      assert %{blockers: [_one]} = UpdateHold.hold(other, @build, not_included_cache(), @terminal)
      assert UpdateHold.reasons(nil, "other") == []
      assert UpdateHold.reasons(@repo_key, "other") == []

      own = todo_blocked_by(blocker("TP-419", "Done"), "own")
      assert %{blockers: [_one]} = UpdateHold.hold(%Issue{own | repo_key: @repo_key}, @build, not_included_cache(), @terminal)
      assert [%{waits_on: %{pull_request: 132}}] = UpdateHold.reasons(@repo_key, "own")
    end

    test "blockers/3 names each reason's blocker from the cache, or only its pull request" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      set_reason(132, "TP-419")
      set_reason(133, nil)
      reasons = UpdateHold.reasons(@repo_key, "issue")

      assert UpdateHold.blockers(issue, reasons, not_included_cache()) == [
               %{identifier: "TP-419", merge_sha: @merge_sha, pull_request: 132},
               %{identifier: nil, merge_sha: nil, pull_request: 133}
             ]

      refute UpdateHold.reason?(Pauses.ticket_reason(:dependency, "TP-9"))
    end
  end

  describe "awaiting_update/4" do
    test "names a terminal fix ticket until the running build includes its merge commit" do
      fix = fix_issue("TP-900", @fix_pr)

      empty = UpdateHold.empty_cache()

      assert {%{identifier: "TP-900", merge_sha: @merge_sha}, cache} = awaiting(fix, empty, included: false)
      assert cache.blockers == %{"id-TP-900" => {:merged, @fix_pr, @merge_sha}}
      assert cache.included == %{{@merge_sha, @build_sha} => false}

      # The cached answers are not looked up again.
      no_lookups = [
        merge_commit_sha: fn _url -> flunk("cached") end,
        commit_included?: fn _url, _sha, _build -> flunk("cached") end
      ]

      assert {%{identifier: "TP-900"}, ^cache} = awaiting(fix, cache, no_lookups)

      assert {nil, _cache} = awaiting(fix, empty, included: true)
    end

    test "finds the fix ticket's pull request in Symphony's record under the lane's repo" do
      :ok = RunStore.clear()
      fix = fix_issue("TP-900")
      :ok = TicketPullRequest.record_created(@repo_key, fix.id, @fix_pr, "auto/TP-900")
      :ok = TicketPullRequest.mark_finished(@repo_key, @fix_pr, "merged")

      assert {%{identifier: "TP-900", merge_sha: @merge_sha}, _cache} =
               awaiting(fix, UpdateHold.empty_cache(), repo_key: @repo_key)
    end

    test "a fix merged elsewhere, opted out, unreadable or with no build sha is not waited on" do
      elsewhere = fix_issue("APP-1", "https://github.com/acme/web-app/pull/5")
      assert {nil, %{blockers: %{"id-APP-1" => :none}}} = awaiting(elsewhere, UpdateHold.empty_cache())

      skipped = %Issue{fix_issue("TP-901", @fix_pr) | labels: [UpdateHold.skip_label()]}
      assert {nil, %{blockers: %{"id-TP-901" => :skip}}} = awaiting(skipped, UpdateHold.empty_cache())

      fix = fix_issue("TP-900", @fix_pr)
      empty = UpdateHold.empty_cache()
      assert awaiting(fix, empty, merge_commit_sha: fn @fix_pr -> {:error, :rate_limited} end) == {nil, empty}

      assert UpdateHold.awaiting_update(fix, %{@build | sha: nil}, empty, []) == {nil, empty}
    end
  end

  defp awaiting(fix, cache, opts \\ []) do
    included = Keyword.get(opts, :included, false)

    UpdateHold.awaiting_update(fix, @build, cache,
      merge_commit_sha: Keyword.get(opts, :merge_commit_sha, fn @fix_pr -> {:ok, @merge_sha} end),
      commit_included?: Keyword.get(opts, :commit_included?, fn @fix_pr, @merge_sha, @build_sha -> {:ok, included} end),
      repo_key: Keyword.get(opts, :repo_key, @repo_key)
    )
  end

  defp resolve(issues, opts \\ []) do
    included = Keyword.get(opts, :included, false)

    UpdateHold.resolve(issues, @build, Keyword.get(opts, :cache, UpdateHold.empty_cache()), @terminal,
      merge_commit_sha: Keyword.get(opts, :merge_commit_sha, fn @fix_pr -> {:ok, @merge_sha} end),
      commit_included?: Keyword.get(opts, :commit_included?, fn @fix_pr, @merge_sha, @build_sha -> {:ok, included} end),
      repo_key: Keyword.get(opts, :repo_key, @repo_key)
    )
  end

  # Options under which any lookup fails the test.
  defp no_lookups(opts \\ []) do
    Keyword.merge([merge_commit_sha: fn _url -> flunk("nothing to look up") end, commit_included?: fn _url, _sha, _build -> flunk("cached") end], opts)
  end

  # The reason the update hold sets on the test ticket's pause, as it would have on an earlier poll.
  defp set_reason(number, identifier) do
    fix = if identifier, do: "#{identifier}'s fix", else: "the fix in PR ##{number}"
    reason = %{kind: :build, waits_on: %{pull_request: number}, text: "Waiting for a Symphony update that includes #{fix}"}
    {:ok, _pause} = Pauses.set({:ticket, @repo_key, "issue"}, reason, set_by: %{kind: :rule, name: "App update hold"})
  end

  defp not_included_cache do
    %{blockers: %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}, included: %{{@merge_sha, @build_sha} => false}}
  end

  # The Todo ticket `issue_id` (TP-332), stored with a `:done` dependency on each of `blockers`, each
  # with its own record in the phase its `state` names (none for `:no_record`) and its labels. No
  # blocker link of Linear's is read: the issue returned carries none.
  defp todo_blocked_by(blockers, issue_id \\ "issue") do
    identifier = if issue_id == "issue", do: "TP-332", else: "TP-" <> issue_id
    put_record(issue_id, identifier, "Todo")

    for %{id: id} = blocker <- List.wrap(blockers) do
      if blocker.state != :no_record, do: put_record(id, blocker.identifier, blocker.state, Map.get(blocker, :labels, []))
      :ok = RunStore.add_dependency(issue_id, id, :done)
    end

    %Issue{id: issue_id, identifier: identifier, title: "Final verification: Pause", state: "Todo"}
  end

  defp put_record(issue_id, identifier, phase, labels \\ []) do
    :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, issue_id, %{issue_identifier: identifier, phase: phase, labels: labels}))
  end

  defp blocker(identifier, state), do: %{id: "id-" <> identifier, identifier: identifier, state: state}

  # A done fix ticket, as `awaiting_update/4` reads it (by id, without its repo); `pr_url` is the PR
  # Symphony's record shows merged.
  defp fix_issue(identifier, pr_url \\ nil) do
    fix = %Issue{id: "id-" <> identifier, identifier: identifier, state: "Done"}

    if pr_url do
      :ok = TicketPullRequest.record_created(@repo_key, fix.id, pr_url, nil)
      :ok = TicketPullRequest.mark_finished(@repo_key, pr_url, "merged")
    end

    fix
  end
end
