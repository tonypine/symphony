defmodule SymphonyElixir.UpdateHoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.UpdateHold

  @build_sha "d3d301b0123456789abcdef0123456789abcdef0"
  @merge_sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
  @build %{version: "0.0.1.168", sha: @build_sha, repo: "https://github.com/acme/symphony"}
  @fix_pr "https://github.com/acme/symphony/pull/132"
  @terminal ["Done", "Canceled"]

  describe "resolve/5 and hold/4" do
    test "hold a Todo ticket until the running build includes its blocker's merge commit" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      fix = fix_issue("TP-419", [@fix_pr])

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
      fix = fix_issue("APP-1", ["https://github.com/acme/web-app/pull/5", "https://linear.app/not-a-pr"])

      cache = resolve([issue], fetch_ok([fix]), merge_commit_sha: fn _url -> flunk("not the build's repository") end)

      assert cache.blockers == %{"id-APP-1" => :none}
      assert cache.included == %{}
      assert UpdateHold.hold(issue, @build, cache, @terminal) == nil
    end

    test "a blocker with an unmerged or no pull request releases its dependents" do
      issue = %Issue{todo_blocked_by(blocker("TP-2", "Canceled")) | blocked_by: [blocker("TP-2", "Canceled"), blocker("TP-3", "Done")]}

      fixes = [fix_issue("TP-2", [@fix_pr]), fix_issue("TP-3", [])]
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
      docs_fix = %Issue{fix_issue("TP-419", [@fix_pr]) | labels: [UpdateHold.skip_label()]}

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
      fix = fix_issue("TP-419", [@fix_pr])

      assert resolve([issue], fn _ids -> {:error, :linear_down} end) == UpdateHold.empty_cache()

      gh_down = resolve([issue], fetch_ok([fix]), merge_commit_sha: fn _url -> {:error, :gh_down} end)
      assert gh_down == UpdateHold.empty_cache()

      not_found = fn _url, _sha, _build -> {:error, :not_found} end
      compare_down = resolve([issue], fetch_ok([fix]), commit_included?: not_found)
      assert compare_down.blockers == %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}
      assert compare_down.included == %{}
      assert UpdateHold.hold(issue, @build, compare_down, @terminal) == nil
    end

    test "a later merged pull request wins over one that failed to load" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      fix = fix_issue("TP-419", ["https://github.com/acme/symphony/pull/1", @fix_pr])

      merge_commit_sha = fn
        "https://github.com/acme/symphony/pull/1" -> {:error, :gh_down}
        @fix_pr -> {:ok, String.upcase(@merge_sha)}
      end

      cache = resolve([issue], fetch_ok([fix]), merge_commit_sha: merge_commit_sha)
      assert cache.blockers == %{"id-TP-419" => {:merged, @fix_pr, @merge_sha}}
    end

    test "a blocker reopened since the poll, or not asked for, is left out" do
      issue = todo_blocked_by(blocker("TP-419", "Done"))
      reopened = %Issue{fix_issue("TP-419", [@fix_pr]) | state: "In Progress"}
      stateless = %Issue{fix_issue("TP-419", [@fix_pr]) | state: nil}
      stranger = fix_issue("TP-999", [@fix_pr])

      assert resolve([issue], fetch_ok([reopened, stateless, stranger])) == UpdateHold.empty_cache()
    end

    test "a blocker without an id is never looked up" do
      issue = todo_blocked_by(%{id: nil, identifier: "TP-1", state: "Done"})
      assert resolve([issue], fn _ids -> flunk("nothing to look up") end) == UpdateHold.empty_cache()
    end
  end

  defp resolve(issues, fetch_issues, opts \\ []) do
    included = Keyword.get(opts, :included, false)

    UpdateHold.resolve(issues, @build, Keyword.get(opts, :cache, UpdateHold.empty_cache()), @terminal,
      fetch_issues: fetch_issues,
      merge_commit_sha: Keyword.get(opts, :merge_commit_sha, fn @fix_pr -> {:ok, @merge_sha} end),
      commit_included?: Keyword.get(opts, :commit_included?, fn @fix_pr, @merge_sha, @build_sha -> {:ok, included} end)
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

  defp fix_issue(identifier, pr_urls) do
    %Issue{id: "id-" <> identifier, identifier: identifier, state: "Done", pr_urls: pr_urls}
  end
end
