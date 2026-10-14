defmodule SymphonyElixir.UpdateHoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketPullRequest, UpdateHold}

  @repo_key "repo-a"

  @build_sha "d3d301b0123456789abcdef0123456789abcdef0"
  @merge_sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
  @build %{version: "0.0.1.168", sha: @build_sha, repo: "https://github.com/acme/symphony"}
  @fix_pr "https://github.com/acme/symphony/pull/132"
  @terminal ["Done", "Canceled"]

  describe "resolve/5 and hold/4" do
    test "hold a Todo ticket until the running build includes its blocker's merge commit" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      fix = fix_issue("TP-419", @fix_pr)

      cache = resolve([issue], fetch_ok([fix]), included: false)

      assert cache.blockers == %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}
      assert cache.included == %{{@merge_sha, @build_sha} => false}

      assert UpdateHold.hold(issue, @build, cache, @terminal) == %{
               blockers: [%{identifier: "TP-419", merge_sha: @merge_sha}],
               build_sha: @build_sha,
               reason: "waiting for an app update: TP-419 merged in `9f54098`, running `d3d301b`"
             }

      included = %{cache | included: %{{@merge_sha, @build_sha} => true}}
      assert UpdateHold.hold(issue, @build, included, @terminal) == nil
    end

    test "names every blocker still missing from the build" do
      unnamed = %{id: "id-x", identifier: nil, state: "Done"}
      issue = %Issue{todo_blocked_by(blocker("TP-1", "Done")) | blocked_by: [blocker("TP-1", "Done"), unnamed]}

      cache = %{
        blockers: %{"id-TP-1" => {:merged, @fix_pr, "aaaaaaa1"}, "id-x" => {:merged, @fix_pr, "bbbbbbb2"}},
        included: %{{"aaaaaaa1", @build_sha} => false, {"bbbbbbb2", @build_sha} => false}
      }

      assert %{reason: "waiting for an app update: TP-1 merged in `aaaaaaa`, a blocker merged in `bbbbbbb`, running `d3d301b`"} =
               UpdateHold.hold(issue, @build, cache, @terminal)
    end

    test "a blocker merged in another repository releases its dependents at Done" do
      issue = todo_blocked_by(blocker("APP-1", "Done"))
      fix = fix_issue("APP-1", "https://github.com/acme/web-app/pull/5")

      cache = resolve([issue], fetch_ok([fix]), merge_commit_sha: fn _url -> flunk("not the build's repository") end)

      assert cache.blockers == %{"id-APP-1" => :none}
      assert cache.included == %{}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "a blocker whose recorded link is not a GitHub pull request releases its dependents" do
      issue = todo_blocked_by(blocker("TP-5", "Done"))
      fix = fix_issue("TP-5", "https://linear.app/not-a-pr")

      cache = resolve([issue], fetch_ok([fix]), merge_commit_sha: fn _url -> flunk("not a pull request") end)

      assert cache.blockers == %{"id-TP-5" => :none}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "a blocker with an unmerged or no pull request releases its dependents" do
      issue = %Issue{todo_blocked_by(blocker("TP-2", "Canceled")) | blocked_by: [blocker("TP-2", "Canceled"), blocker("TP-3", "Done")]}

      fixes = [fix_issue("TP-2", @fix_pr), fix_issue("TP-3")]
      cache = resolve([issue], fetch_ok(fixes), merge_commit_sha: fn @fix_pr -> {:ok, nil} end)

      assert cache.blockers == %{"id-TP-2" => :none, "id-TP-3" => :none}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "the skip-update-hold label opts out on the held ticket or on the blocker" do
      labelled = %Issue{todo_blocked_by(blocker("TP-419", "Done")) | labels: [" Skip-Update-Hold "]}
      merged_cache = not_included_cache()

      assert resolve([labelled], fn _ids -> flunk("nothing to look up") end) == UpdateHold.empty_cache()
      assert UpdateHold.hold(labelled, @build, merged_cache, @terminal) == nil

      issue = todo_blocked_by(blocker("TP-419", "Done"))
      docs_fix = %Issue{fix_issue("TP-419", @fix_pr) | labels: [UpdateHold.skip_label()]}

      cache = resolve([issue], fetch_ok([docs_fix]), merge_commit_sha: fn _url -> flunk("opted out") end)

      assert cache.blockers == %{"id-TP-419" => :skip}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "only Todo tickets whose blockers are all terminal are looked up or held" do
      open_blocker = todo_blocked_by(blocker("TP-5", "In Review"))
      running = %Issue{todo_blocked_by(blocker("TP-6", "Done")) | state: "In Progress"}
      unblocked = %Issue{id: "free", identifier: "TP-7", state: "Todo", blocked_by: []}
      no_state = %Issue{todo_blocked_by(blocker("TP-8", "Done")) | state: nil}

      assert resolve([open_blocker, running, unblocked, no_state, :not_an_issue], fn _ids -> flunk("nothing to look up") end) ==
               UpdateHold.empty_cache()

      cache = %{not_included_cache() | blockers: %{"id-TP-6" => {:merged, @fix_pr, @merge_sha}}}
      assert UpdateHold.hold(running, @build, cache, @terminal) == nil
    end

    test "cached blockers and merge commits are not looked up again" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      cache = not_included_cache()
      no_compare = fn _url, _sha, _build -> flunk("cached") end

      assert resolve([issue], fn _ids -> flunk("cached") end, cache: cache, commit_included?: no_compare) == cache
    end

    test "a build without a sha or repository holds nothing and looks nothing up" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      cache = not_included_cache()
      lookups = [fetch_issues: fn _ids -> flunk("no build") end]

      for build <- [%{@build | sha: nil}, %{@build | repo: nil}] do
        empty = UpdateHold.empty_cache()
        assert UpdateHold.resolve([issue], build, empty, @terminal, lookups) == empty

        assert UpdateHold.hold(issue, build, cache, @terminal) == nil
      end
    end

    test "a failed lookup is not cached and does not hold the ticket" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      fix = fix_issue("TP-419", @fix_pr)

      assert resolve([issue], fn _ids -> {:error, :linear_down} end) == UpdateHold.empty_cache()

      gh_down = resolve([issue], fetch_ok([fix]), merge_commit_sha: fn _url -> {:error, :gh_down} end)
      assert gh_down == UpdateHold.empty_cache()

      not_found = fn _url, _sha, _build -> {:error, :not_found} end
      compare_down = resolve([issue], fetch_ok([fix]), commit_included?: not_found)
      assert compare_down.blockers == %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}
      assert compare_down.included == %{}
      assert UpdateHold.hold(issue, @build, compare_down, @terminal) == nil
    end

    test "a blocker's pull request is the one Symphony recorded for it, merged or closed" do
      :ok = RunStore.clear()
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      # Read by id, the blocker carries no repo: its record is looked up under the lane's.
      fix = fix_issue("TP-419")
      :ok = TicketPullRequest.record_created(@repo_key, fix.id, @fix_pr, "auto/TP-419")
      :ok = TicketPullRequest.mark_finished(@repo_key, @fix_pr, "merged")

      cache = resolve([issue], fetch_ok([fix]), repo_key: @repo_key)

      assert cache.blockers == %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}
      assert %{blockers: [%{identifier: "TP-419"}]} = UpdateHold.hold(issue, @build, cache, @terminal)

      # A closed record merged nothing.
      :ok = TicketPullRequest.record_created(@repo_key, fix.id, @fix_pr, "auto/TP-419")
      :ok = TicketPullRequest.mark_finished(@repo_key, @fix_pr, "closed")

      cache = resolve([issue], fetch_ok([fix]), repo_key: @repo_key, merge_commit_sha: fn @fix_pr -> {:ok, nil} end)

      assert cache.blockers == %{"id-TP-419" => :none}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "a blocker reopened since the poll, or not asked for, is left out" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      reopened = %Issue{fix_issue("TP-419", @fix_pr) | state: "In Progress"}
      stateless = %Issue{fix_issue("TP-419", @fix_pr) | state: nil}
      stranger = fix_issue("TP-999", @fix_pr)

      assert resolve([issue], fetch_ok([reopened, stateless, stranger])) == UpdateHold.empty_cache()
    end

    test "a blocker without an id is never looked up" do
      issue = todo_blocked_by(%{id: nil, identifier: "TP-1", state: "Done"})
      assert resolve([issue], fn _ids -> flunk("nothing to look up") end) == UpdateHold.empty_cache()
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

  defp resolve(issues, fetch_issues, opts \\ []) do
    included = Keyword.get(opts, :included, false)

    UpdateHold.resolve(issues, @build, Keyword.get(opts, :cache, UpdateHold.empty_cache()), @terminal,
      fetch_issues: fetch_issues,
      merge_commit_sha: Keyword.get(opts, :merge_commit_sha, fn @fix_pr -> {:ok, @merge_sha} end),
      commit_included?: Keyword.get(opts, :commit_included?, fn @fix_pr, @merge_sha, @build_sha -> {:ok, included} end),
      repo_key: Keyword.get(opts, :repo_key, @repo_key)
    )
  end

  defp fetch_ok(issues), do: fn _ids -> {:ok, issues} end

  defp not_included_cache do
    %{blockers: %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}, included: %{{@merge_sha, @build_sha} => false}}
  end

  defp todo_blocked_by(blocker) do
    %Issue{id: "issue", identifier: "TP-332", title: "Final verification: Pause", state: "Todo", blocked_by: [blocker]}
  end

  defp blocker(identifier, state), do: %{id: "id-" <> identifier, identifier: identifier, state: state}

  # A done fix ticket, read by id without its repo; `pr_url` is the PR Symphony's record shows merged.
  defp fix_issue(identifier, pr_url \\ nil) do
    fix = %Issue{id: "id-" <> identifier, identifier: identifier, state: "Done"}

    if pr_url do
      :ok = TicketPullRequest.record_created(@repo_key, fix.id, pr_url, nil)
      :ok = TicketPullRequest.mark_finished(@repo_key, pr_url, "merged")
    end

    fix
  end
end
