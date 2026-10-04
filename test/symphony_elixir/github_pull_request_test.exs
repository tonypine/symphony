defmodule SymphonyElixir.GitHub.PullRequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Hosts
  alias SymphonyElixir.GitHub.PullRequest

  test "GitHub host helper allowlists public and configured enterprise hosts exactly" do
    assert Hosts.allowed_github_hosts(github_enterprise_hosts: [" GHE.EXAMPLE.COM "]) == ["github.com", "www.github.com", "ghe.example.com"]

    assert Hosts.github_host?("GITHUB.COM")
    assert Hosts.github_host?(" www.github.com ")
    assert Hosts.github_host?("ghe.example.com", github_enterprise_hosts: ["GHE.EXAMPLE.COM"])

    refute Hosts.github_host?(nil)
    refute Hosts.github_host?("github.evil.tld", github_enterprise_hosts: [])

    assert {:ok, "github.com"} = Hosts.canonical_github_host("www.github.com")
    assert {:ok, "ghe.example.com"} = Hosts.canonical_github_host("ghe.example.com", github_enterprise_hosts: ["GHE.EXAMPLE.COM"])
    assert :error = Hosts.canonical_github_host(nil)
  end

  test "fetch_activity separates review timestamps from PR updates and supports enterprise hosts" do
    pr_url = "https://github.example.com/org/repo/pull/42"

    runner = fn
      ["pr", "view", ^pr_url, "--json", fields], opts ->
        assert fields ==
                 "id,number,state,reviewDecision,mergeable,mergeStateStatus,autoMergeRequest,headRefName,baseRefName,headRefOid,baseRefOid,isCrossRepository,updatedAt,comments,reviews,title,body,url,author"

        assert opts[:stderr_to_stdout]

        {Jason.encode!(%{
           "number" => 42,
           "title" => "Ship review polling",
           "body" => "PR body",
           "author" => %{"login" => "pr-author"},
           "state" => "OPEN",
           "reviewDecision" => "APPROVED",
           "mergeable" => "CONFLICTING",
           "mergeStateStatus" => "DIRTY",
           "headRefName" => "feature/review-polling",
           "baseRefName" => "main",
           "headRefOid" => "head-sha",
           "baseRefOid" => "base-sha",
           "isCrossRepository" => false,
           "updatedAt" => "2026-05-01T10:00:00Z",
           "comments" => [],
           "reviews" => [
             %{
               "id" => "PRR_kw1",
               "author" => %{"login" => "reviewer"},
               "body" => "Looks good.",
               "url" => "#{pr_url}#pullrequestreview-1",
               "state" => "APPROVED",
               "submittedAt" => "2026-05-01T09:00:00Z"
             }
           ],
           "url" => pr_url
         }), 0}

      ["api", "--hostname", "github.example.com", "repos/org/repo/pulls/42/comments"], opts ->
        assert opts[:stderr_to_stdout]

        {Jason.encode!([
           %{
             "id" => 123,
             "user" => %{"login" => "reviewer"},
             "body" => "Nit fixed separately.",
             "html_url" => "#{pr_url}#discussion_r1",
             "path" => "lib/example.ex",
             "line" => 42,
             "created_at" => "2026-05-01T09:03:00Z",
             "updated_at" => "2026-05-01T09:05:00Z"
           }
         ]), 0}
    end

    assert {:ok, activity} = PullRequest.fetch_activity(pr_url, gh_runner: runner, github_enterprise_hosts: ["github.example.com"])

    assert activity.pr_url == pr_url
    assert activity.pr_number == 42
    assert activity.pr_title == "Ship review polling"
    assert activity.pr_description == "PR body"
    assert activity.pr_author == "pr-author"
    assert activity.state == "OPEN"
    assert activity.review_decision == "APPROVED"
    assert activity.mergeable == "CONFLICTING"
    assert activity.merge_state_status == "DIRTY"
    assert activity.head_ref_name == "feature/review-polling"
    assert activity.base_ref_name == "main"
    assert activity.head_ref_oid == "head-sha"
    assert activity.base_ref_oid == "base-sha"
    assert activity.is_cross_repository == false
    assert activity.latest_activity_at == ~U[2026-05-01 10:00:00Z]
    assert activity.latest_review_activity_at == ~U[2026-05-01 09:05:00Z]
    assert Enum.map(activity.comments, & &1.kind) == ["review", "inline_comment"]
    assert Enum.map(activity.comments, & &1.id) == ["PRR_kw1", "123"]
    assert List.last(activity.comments).path == "lib/example.ex"
    assert List.last(activity.comments).line == 42
  end

  test "current_user returns the authenticated gh login and falls back gracefully" do
    success_runner = fn ["api", "user", "--jq", ".login"], opts ->
      assert opts[:stderr_to_stdout]
      {"symphony-operator\n", 0}
    end

    assert {:ok, "symphony-operator"} = PullRequest.current_user(gh_runner: success_runner)

    empty_runner = fn ["api", "user", "--jq", ".login"], _opts -> {"", 0} end
    assert {:error, :empty_current_user} = PullRequest.current_user(gh_runner: empty_runner)

    failing_runner = fn ["api", "user", "--jq", ".login"], _opts -> {"not authenticated", 4} end

    assert {:error, {:gh_failed, ["api", "user", "--jq", ".login"], 4, "not authenticated"}} =
             PullRequest.current_user(gh_runner: failing_runner)
  end

  test "fetch_activity ignores a stale cwd when the workspace was already removed" do
    pr_url = "https://github.com/org/repo/pull/17"
    missing_cwd = Path.join(System.tmp_dir!(), "missing-symphony-workspace-#{System.unique_integer([:positive])}")

    runner = fn
      ["pr", "view", ^pr_url, "--json", _fields], opts ->
        refute Keyword.has_key?(opts, :cd)

        {Jason.encode!(%{
           "number" => 17,
           "state" => "MERGED",
           "reviewDecision" => nil,
           "updatedAt" => "2026-05-05T09:34:09Z",
           "comments" => [],
           "reviews" => [],
           "url" => pr_url
         }), 0}

      ["api", "repos/org/repo/pulls/17/comments"], opts ->
        refute Keyword.has_key?(opts, :cd)

        {Jason.encode!([]), 0}
    end

    assert {:ok, activity} = PullRequest.fetch_activity(pr_url, cwd: missing_cwd, gh_runner: runner)
    assert activity.state == "MERGED"
  end

  test "fetch_ci_status reads status rollup and failed GitHub Actions run ids" do
    pr_url = "https://github.com/org/repo/pull/17"

    runner = fn
      ["pr", "view", ^pr_url, "--json", fields], opts ->
        assert fields == "number,state,title,url,headRefName,headRefOid,baseRefName,isCrossRepository,headRepository,mergeable,mergeStateStatus,statusCheckRollup"
        assert opts[:stderr_to_stdout]

        {Jason.encode!(%{
           "state" => "OPEN",
           "title" => "Fix CI",
           "url" => pr_url,
           "headRefName" => "feature/fix-ci",
           "headRefOid" => "abc123",
           "isCrossRepository" => false,
           "headRepository" => %{"nameWithOwner" => "org/repo"},
           "baseRefName" => "main",
           "mergeable" => "CONFLICTING",
           "mergeStateStatus" => "DIRTY",
           "statusCheckRollup" => [
             %{
               "name" => "test",
               "status" => "COMPLETED",
               "conclusion" => "FAILURE",
               "detailsUrl" => "https://github.com/org/repo/actions/runs/987/jobs/654",
               "workflowName" => "CI"
             }
           ]
         }), 0}
    end

    assert {:ok, status} = PullRequest.fetch_ci_status(pr_url, gh_runner: runner)
    assert status.pr_url == pr_url
    assert status.pr_title == "Fix CI"
    assert status.head_ref_name == "feature/fix-ci"
    assert status.commit_sha == "abc123"
    assert status.is_cross_repository == false
    assert status.head_repository == %{"nameWithOwner" => "org/repo"}
    assert status.base_ref_name == "main"
    assert status.mergeable == "CONFLICTING"
    assert status.merge_state_status == "DIRTY"
    assert [%{name: "test", conclusion: "FAILURE", run_id: "987"}] = status.checks
  end

  test "conflicting? reads mergeable and mergeStateStatus" do
    assert PullRequest.conflicting?(%{mergeable: "CONFLICTING", merge_state_status: "DIRTY"})
    assert PullRequest.conflicting?(%{mergeable: " conflicting ", merge_state_status: nil})
    assert PullRequest.conflicting?(%{mergeable: "UNKNOWN", merge_state_status: "dirty"})
    refute PullRequest.conflicting?(%{mergeable: "MERGEABLE", merge_state_status: "CLEAN"})
    refute PullRequest.conflicting?(%{mergeable: "UNKNOWN", merge_state_status: "UNKNOWN"})
    refute PullRequest.conflicting?(%{})
  end

  test "fetch_ci_status maps status context state into status and conclusion" do
    pr_url = "https://github.com/org/repo/pull/17"

    runner = fn ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,baseRefName,isCrossRepository,headRepository,mergeable,mergeStateStatus,statusCheckRollup"], _opts ->
      {Jason.encode!(%{
         "state" => "OPEN",
         "title" => "Fix legacy contexts",
         "url" => pr_url,
         "headRefOid" => "abc123",
         "statusCheckRollup" => [
           %{"context" => "ci/failure", "state" => "FAILURE", "targetUrl" => "https://ci.example.test/failure"},
           %{"context" => "ci/error", "state" => "ERROR", "targetUrl" => "https://ci.example.test/error"},
           %{"context" => "ci/pending", "state" => "PENDING", "targetUrl" => "https://ci.example.test/pending"},
           %{"context" => "ci/success", "state" => "SUCCESS", "targetUrl" => "https://ci.example.test/success"}
         ]
       }), 0}
    end

    assert {:ok, status} = PullRequest.fetch_ci_status(pr_url, gh_runner: runner)

    assert [
             %{name: "ci/failure", status: "FAILURE", conclusion: "FAILURE", details_url: "https://ci.example.test/failure"},
             %{name: "ci/error", status: "ERROR", conclusion: "ERROR", details_url: "https://ci.example.test/error"},
             %{name: "ci/pending", status: "PENDING", conclusion: "PENDING", details_url: "https://ci.example.test/pending"},
             %{name: "ci/success", status: "SUCCESS", conclusion: "SUCCESS", details_url: "https://ci.example.test/success"}
           ] = status.checks
  end

  test "fetch_failed_log and rerun_failed use gh run commands" do
    runner = fn
      ["run", "view", "987", "--log-failed"], opts ->
        assert opts[:stderr_to_stdout]
        {"failed log", 0}

      ["run", "rerun", "987", "--failed"], opts ->
        assert opts[:stderr_to_stdout]
        {"", 0}
    end

    assert {:ok, "failed log"} = PullRequest.fetch_failed_log("987", gh_runner: runner)
    assert :ok = PullRequest.rerun_failed("987", gh_runner: runner)

    other_repo = fn ["run", "view", "987", "--log-failed", "-R", "acme/cycle"], _opts -> {"other log", 0} end
    assert {:ok, "other log"} = PullRequest.fetch_failed_log("987", gh_runner: other_repo, repo: "acme/cycle")
  end

  test "list_branch_runs reads the latest workflow runs on a branch in one request" do
    runner = fn
      ["run", "list", "-R", "acme/cycle", "--branch", "main", "--limit", "50", "--json", "databaseId,workflowName,status,conclusion,url,createdAt"], opts ->
        assert opts[:stderr_to_stdout]

        {Jason.encode!([
           %{
             "databaseId" => 12,
             "workflowName" => "Release",
             "status" => "completed",
             "conclusion" => "failure",
             "url" => "https://github.com/acme/cycle/actions/runs/12",
             "createdAt" => "2026-10-04T10:00:00Z"
           },
           %{"databaseId" => 11, "workflowName" => "CI", "status" => "in_progress", "conclusion" => ""},
           "not a run"
         ]), 0}

      ["run", "list", "-R", "acme/web", "--branch", "trunk", "--limit", "5" | _rest], _opts ->
        {"not json", 0}
    end

    assert {:ok, [release, ci]} = PullRequest.list_branch_runs("acme/cycle", "main", gh_runner: runner)

    assert release == %{
             id: "12",
             workflow_name: "Release",
             status: "COMPLETED",
             conclusion: "FAILURE",
             url: "https://github.com/acme/cycle/actions/runs/12",
             created_at: ~U[2026-10-04 10:00:00Z]
           }

    assert %{id: "11", status: "IN_PROGRESS", conclusion: "", created_at: nil} = ci
    assert {:error, :invalid_workflow_runs_payload} = PullRequest.list_branch_runs("acme/web", "trunk", gh_runner: runner, limit: 5)

    failing = fn _args, _opts -> {"HTTP 404", 1} end
    assert {:error, {:gh_failed, _args, 1, "HTTP 404"}} = PullRequest.list_branch_runs("acme/cycle", "main", gh_runner: failing)
  end

  test "fetch_pr_comments reads paginated top-level PR comments" do
    pr_url = "https://github.example.com/org/repo/pull/42"

    runner = fn
      ["api", "--hostname", "github.example.com", "--paginate", "--slurp", "repos/org/repo/issues/42/comments"], opts ->
        assert opts[:stderr_to_stdout]

        {Jason.encode!([
           [
             %{
               "id" => 1,
               "node_id" => "IC_1",
               "user" => %{"login" => "reviewer"},
               "author_association" => "MEMBER",
               "body" => "Please update the docs.",
               "html_url" => "#{pr_url}#issuecomment-1",
               "created_at" => "2026-05-01T09:00:00Z",
               "updated_at" => "2026-05-01T09:01:00Z"
             }
           ],
           [
             %{
               "id" => 2,
               "user" => %{"login" => "bot"},
               "body" => "CI note.",
               "html_url" => "#{pr_url}#issuecomment-2"
             }
           ]
         ]), 0}
    end

    assert {:ok, comments} =
             PullRequest.fetch_pr_comments(pr_url,
               gh_runner: runner,
               github_enterprise_hosts: ["github.example.com"]
             )

    assert Enum.map(comments, & &1.id) == ["1", "2"]
    assert List.first(comments).kind == "comment"
    assert List.first(comments).author == "reviewer"
    assert List.first(comments).author_association == "MEMBER"
  end

  test "fetch_pr_review_comments preserves file position and review id" do
    pr_url = "https://github.com/org/repo/pull/17"

    runner = fn
      ["api", "--paginate", "--slurp", "repos/org/repo/pulls/17/comments"], opts ->
        assert opts[:stderr_to_stdout]

        {Jason.encode!([
           [
             %{
               "id" => 123,
               "node_id" => "PRRC_123",
               "user" => %{"login" => "reviewer"},
               "body" => "Use the helper here.",
               "html_url" => "#{pr_url}#discussion_r123",
               "path" => "lib/example.ex",
               "position" => 8,
               "original_position" => 6,
               "line" => 42,
               "pull_request_review_id" => 987,
               "commit_id" => "abc123",
               "diff_hunk" => "@@ -1 +1 @@",
               "created_at" => "2026-05-01T09:03:00Z",
               "updated_at" => "2026-05-01T09:05:00Z"
             }
           ]
         ]), 0}
    end

    assert {:ok, [comment]} = PullRequest.fetch_pr_review_comments(pr_url, gh_runner: runner)
    assert comment.kind == "inline_comment"
    assert comment.path == "lib/example.ex"
    assert comment.position == 8
    assert comment.original_position == 6
    assert comment.review_id == "987"
  end

  test "fetch_pr_reviews reads paginated review summaries" do
    pr_url = "https://github.com/org/repo/pull/17"

    runner = fn
      ["api", "--paginate", "--slurp", "repos/org/repo/pulls/17/reviews"], _opts ->
        {Jason.encode!([
           [
             %{
               "id" => 987,
               "node_id" => "PRR_987",
               "user" => %{"login" => "reviewer"},
               "state" => "CHANGES_REQUESTED",
               "body" => "One issue.",
               "html_url" => "#{pr_url}#pullrequestreview-987",
               "commit_id" => "abc123",
               "submitted_at" => "2026-05-01T09:00:00Z"
             }
           ]
         ]), 0}
    end

    assert {:ok, [review]} = PullRequest.fetch_pr_reviews(pr_url, gh_runner: runner)
    assert review.id == "987"
    assert review.author == "reviewer"
    assert review.state == "CHANGES_REQUESTED"
    assert review.submitted_at == ~U[2026-05-01 09:00:00Z]
  end

  test "reply_to_comment posts inline replies and request_review re-requests reviewers" do
    pr_url = "https://github.example.com/org/repo/pull/42"

    runner = fn
      ["api", "--hostname", "github.example.com", "repos/org/repo/pulls/42/comments/123/replies", "-f", "body=Addressed.\n\n<!-- symphony:agent -->"], opts ->
        assert opts[:stderr_to_stdout]
        {"{}", 0}

      ["pr", "edit", ^pr_url, "--add-reviewer", "reviewer", "--add-reviewer", "maintainer"], opts ->
        assert opts[:stderr_to_stdout]
        {"", 0}
    end

    assert :ok =
             PullRequest.reply_to_comment(
               pr_url,
               %{id: "123", kind: "inline_comment"},
               "Addressed.",
               gh_runner: runner,
               github_enterprise_hosts: ["github.example.com"]
             )

    assert :ok =
             PullRequest.request_review(pr_url, ["reviewer", "reviewer", "maintainer"],
               gh_runner: runner,
               github_enterprise_hosts: ["github.example.com"]
             )
  end

  test "reply_to_comment can fall back to an inline comment node id" do
    pr_url = "https://github.example.com/org/repo/pull/42"

    runner = fn
      ["api", "--hostname", "github.example.com", "repos/org/repo/pulls/42/comments/PRRC_kwDO/replies", "-f", "body=Addressed.\n\n<!-- symphony:agent -->"], opts ->
        assert opts[:stderr_to_stdout]
        {"{}", 0}
    end

    assert :ok =
             PullRequest.reply_to_comment(
               pr_url,
               %{node_id: "PRRC_kwDO", kind: "inline_comment"},
               "Addressed.",
               gh_runner: runner,
               github_enterprise_hosts: ["github.example.com"]
             )
  end

  test "fetch_activity rejects non-allowlisted github-like hosts before gh commands" do
    pr_url = "https://github-evil.attacker.tld/org/repo/pull/42"

    runner = fn args, _opts ->
      send(self(), {:gh_called, args})
      {"", 1}
    end

    assert {:error, :invalid_pr_url} =
             PullRequest.fetch_activity(pr_url, gh_runner: runner, github_enterprise_hosts: [])

    refute_receive {:gh_called, _args}
  end

  test "fetch_activity accepts www.github.com through the public GitHub API host" do
    pr_url = "https://www.github.com/org/repo/pull/42"

    runner = fn
      ["pr", "view", ^pr_url, "--json", _fields], _opts ->
        {Jason.encode!(%{
           "number" => 42,
           "state" => "OPEN",
           "updatedAt" => "2026-05-01T10:00:00Z",
           "comments" => [],
           "reviews" => []
         }), 0}

      ["api", "repos/org/repo/pulls/42/comments"], _opts ->
        send(self(), :used_public_github_api_host)
        {Jason.encode!([]), 0}
    end

    assert {:ok, _activity} = PullRequest.fetch_activity(pr_url, gh_runner: runner)
    assert_receive :used_public_github_api_host
  end

  test "reply and review commands reject non-allowlisted github-like hosts" do
    pr_url = "https://www.github.com.evil.tld/org/repo/pull/42"

    runner = fn args, _opts ->
      send(self(), {:gh_called, args})
      {"", 1}
    end

    assert {:error, :invalid_pr_url} =
             PullRequest.reply_to_comment(pr_url, %{id: "123", kind: "inline_comment"}, "Addressed.",
               gh_runner: runner,
               github_enterprise_hosts: []
             )

    assert {:error, :invalid_pr_url} =
             PullRequest.reply_to_comment(pr_url, %{id: "123", kind: "comment"}, "Addressed.",
               gh_runner: runner,
               github_enterprise_hosts: []
             )

    assert {:error, :invalid_pr_url} =
             PullRequest.request_review(pr_url, ["reviewer"], gh_runner: runner, github_enterprise_hosts: [])

    refute_receive {:gh_called, _args}
  end

  describe "auto-merge" do
    @request %{pr_node_id: "PR_node", head_sha: "head-1", pr_number: 42, pr_title: "Ship it", pr_description: "Body"}

    test "enable_auto_merge sends a squash auto-merge for the observed head with the PR title and body" do
      pr_url = "https://github.example.com/org/repo/pull/42"

      runner = fn ["api", "--hostname", "github.example.com", "graphql" | fields], opts ->
        assert opts[:stderr_to_stdout]
        assert ["-f", "query=" <> query | rest] = fields
        assert query =~ "enablePullRequestAutoMerge"
        assert query =~ "mergeMethod: SQUASH"

        assert rest == [
                 "-f",
                 "pullRequestId=PR_node",
                 "-f",
                 "expectedHeadOid=head-1",
                 "-f",
                 "commitHeadline=Ship it (#42)",
                 "-f",
                 "commitBody=Body"
               ]

        {~s({"data":{}}), 0}
      end

      assert :ok = PullRequest.enable_auto_merge(pr_url, @request, gh_runner: runner, github_enterprise_hosts: ["github.example.com"])
    end

    test "enable_auto_merge reports a PR that can already merge, and other failures as they are" do
      pr_url = "https://github.com/org/repo/pull/42"
      clean = fn ["api", "graphql" | _fields], _opts -> {"gh: Pull request Pull request is in clean status (enablePullRequestAutoMerge)", 1} end
      denied = fn ["api", "graphql" | _fields], _opts -> {"gh: Auto merge is not allowed for this repository", 1} end

      assert {:error, :clean_status} = PullRequest.enable_auto_merge(pr_url, @request, gh_runner: clean)

      moved = fn ["api", "graphql" | _fields], _opts ->
        {~s(gh: Failed to add PR #164: expected head oid does not match the current head oid \(enablePullRequestAutoMerge\)), 1}
      end

      assert {:error, :head_moved} = PullRequest.enable_auto_merge(pr_url, @request, gh_runner: moved)

      assert {:error, {:gh_failed, _args, 1, "gh: Auto merge is not allowed" <> _}} =
               PullRequest.enable_auto_merge(pr_url, @request, gh_runner: denied)

      assert {:error, :invalid_pr_url} = PullRequest.enable_auto_merge("https://example.com/nope", @request, gh_runner: clean)
    end

    test "disable_auto_merge turns auto-merge off for the PR node, and reports failures as they are" do
      pr_url = "https://github.com/org/repo/pull/42"

      runner = fn ["api", "graphql", "-f", "query=" <> query, "-f", "pullRequestId=PR_node"], _opts ->
        assert query =~ "disablePullRequestAutoMerge"
        {~s({"data":{}}), 0}
      end

      denied = fn ["api", "graphql" | _fields], _opts -> {"gh: Resource not accessible by integration", 1} end

      assert :ok = PullRequest.disable_auto_merge(pr_url, "PR_node", gh_runner: runner)
      assert {:error, {:gh_failed, _args, 1, "gh: Resource not accessible" <> _}} = PullRequest.disable_auto_merge(pr_url, "PR_node", gh_runner: denied)
      assert {:error, :invalid_pr_url} = PullRequest.disable_auto_merge("https://example.com/nope", "PR_node", gh_runner: runner)
    end

    test "squash_merge merges the observed head and falls back to the bare title or an empty headline" do
      pr_url = "https://github.com/org/repo/pull/42"
      test_pid = self()

      runner = fn ["api", "graphql", "-f", "query=" <> query | fields], _opts ->
        send(test_pid, {:mutation, query, fields})
        {"{}", 0}
      end

      assert :ok = PullRequest.squash_merge(pr_url, %{@request | pr_number: nil}, gh_runner: runner)
      assert_received {:mutation, query, fields}
      assert query =~ "mergePullRequest"
      assert "commitHeadline=Ship it" in fields

      assert :ok = PullRequest.squash_merge(pr_url, %{pr_node_id: "PR_node", head_sha: "head-1"}, gh_runner: runner)
      assert_received {:mutation, _query, fields}
      assert "commitHeadline=" in fields
      assert "commitBody=" in fields
    end

    test "update_branch asks GitHub to merge the base in for the expected head" do
      pr_url = "https://github.com/org/repo/pull/42"

      ok = fn ["api", "repos/org/repo/pulls/42/update-branch", "--method", "PUT", "-f", "expected_head_sha=head-1"], _opts -> {~s({"message":"Updating pull request branch."}), 0} end
      conflict = fn _args, _opts -> {"{\"message\":\"merge conflict between base and head\"}\ngh: merge conflict between base and head (HTTP 422)", 1} end
      stale = fn _args, _opts -> {"gh: expected head sha didn't match current head ref. (HTTP 422)", 1} end
      unavailable = fn _args, _opts -> {:error, :enoent} end

      assert :ok = PullRequest.update_branch(pr_url, "head-1", gh_runner: ok)
      assert {:error, :conflict} = PullRequest.update_branch(pr_url, "head-1", gh_runner: conflict)
      assert {:error, {:gh_failed, _args, 1, _output}} = PullRequest.update_branch(pr_url, "head-1", gh_runner: stale)
      assert {:error, :enoent} = PullRequest.update_branch(pr_url, "head-1", gh_runner: unavailable)
      assert {:error, :invalid_pr_url} = PullRequest.update_branch("https://github.com/org/repo/issues/42", "head-1", gh_runner: ok)
    end
  end

  describe "merge_commit_sha/2" do
    test "returns the merge commit of a merged pull request and nil for an open one" do
      runner = fn
        ["api", "repos/acme/symphony/pulls/132"], _opts -> {~s({"merged": true, "merge_commit_sha": "9f54098b96666e6e"}), 0}
        ["api", "repos/acme/symphony/pulls/133"], _opts -> {~s({"merged": false, "merge_commit_sha": "abc"}), 0}
        ["api", "--hostname", "ghe.example.com", "repos/acme/symphony/pulls/7"], _opts -> {~s({"merged": true, "merge_commit_sha": "def"}), 0}
      end

      assert {:ok, "9f54098b96666e6e"} = PullRequest.merge_commit_sha("https://github.com/acme/symphony/pull/132", gh_runner: runner)
      assert {:ok, nil} = PullRequest.merge_commit_sha("https://github.com/acme/symphony/pull/133", gh_runner: runner)

      assert {:ok, "def"} =
               PullRequest.merge_commit_sha("https://ghe.example.com/acme/symphony/pull/7", gh_runner: runner, github_enterprise_hosts: ["ghe.example.com"])
    end

    test "reports a bad URL, payload or gh failure" do
      pr_url = "https://github.com/a/b/pull/1"
      answer = fn output, status -> [gh_runner: fn _args, _opts -> {output, status} end] end

      assert {:error, :invalid_pr_url} = PullRequest.merge_commit_sha("https://github.com/acme/symphony", answer.("", 0))
      assert {:error, :invalid_pr_payload} = PullRequest.merge_commit_sha(pr_url, answer.("[]", 0))
      assert {:error, {:invalid_pr_payload, _message}} = PullRequest.merge_commit_sha(pr_url, answer.("nope", 0))
      assert {:error, {:gh_failed, _args, 1, "boom"}} = PullRequest.merge_commit_sha(pr_url, answer.("boom", 1))
    end
  end

  describe "commit_included?/4" do
    test "compares the commit with the head in the pull request's repository" do
      pr_url = "https://github.com/acme/symphony/pull/132"

      runner = fn args, _opts ->
        assert ["api", "repos/acme/symphony/compare/" <> range, "--jq", ".status"] = args

        case range do
          "m1...b" -> {"ahead\n", 0}
          "m2...b" -> {"identical\n", 0}
          "m3...b" -> {"behind\n", 0}
          "m4...b" -> {"diverged\n", 0}
          "m5...b" -> {"sideways\n", 0}
          "m6...b" -> {"Not Found", 1}
        end
      end

      assert {:ok, true} = PullRequest.commit_included?(pr_url, "m1", "b", gh_runner: runner)
      assert {:ok, true} = PullRequest.commit_included?(pr_url, "m2", "b", gh_runner: runner)
      assert {:ok, false} = PullRequest.commit_included?(pr_url, "m3", "b", gh_runner: runner)
      assert {:ok, false} = PullRequest.commit_included?(pr_url, "m4", "b", gh_runner: runner)

      assert {:error, {:unexpected_compare_status, "sideways"}} =
               PullRequest.commit_included?(pr_url, "m5", "b", gh_runner: runner)

      assert {:error, {:gh_failed, _args, 1, "Not Found"}} = PullRequest.commit_included?(pr_url, "m6", "b", gh_runner: runner)
      assert {:error, :invalid_pr_url} = PullRequest.commit_included?("not a url", "m1", "b", gh_runner: runner)
    end
  end
end
