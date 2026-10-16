defmodule SymphonyElixir.PrWatch.FetchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.Fetch

  @pr_url "https://github.com/acme/app/pull/42"
  @rules "repos/acme/app/rules/branches/main?per_page=100"
  @branch "repos/acme/app/branches/main"
  @reset 1_800_000_000

  defp headers(remaining \\ 4321), do: "HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: #{remaining}\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Reset: #{@reset}\r\n\r\n"

  defp pull(attrs \\ %{}) do
    Map.merge(
      %{
        "number" => 42,
        "url" => @pr_url,
        "state" => "OPEN",
        "isDraft" => false,
        "merged" => false,
        "baseRefName" => "main",
        "headRefName" => "auto/TP-1",
        "headRefOid" => "abc123",
        "mergeable" => "MERGEABLE",
        "mergeStateStatus" => "CLEAN",
        "reviewDecision" => nil,
        "autoMergeRequest" => nil,
        "reviewThreads" => %{"nodes" => []},
        "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"contexts" => %{"nodes" => [check("make all", "SUCCESS")]}}}}]}
      },
      attrs
    )
  end

  defp check(name, conclusion, opts \\ []) do
    %{
      "__typename" => "CheckRun",
      "name" => name,
      "status" => if(conclusion, do: "COMPLETED", else: "IN_PROGRESS"),
      "conclusion" => conclusion,
      "detailsUrl" => "https://github.com/acme/app/actions/runs/#{Keyword.get(opts, :run, 100)}/job/1",
      "checkSuite" => %{"workflowRun" => %{"workflow" => %{"name" => Keyword.get(opts, :workflow, "ci")}}}
    }
  end

  defp rollup(checks), do: %{"commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"contexts" => %{"nodes" => checks}}}}]}}

  defp response(pull, default_branch \\ "main") do
    headers() <> Jason.encode!(%{"data" => %{"repository" => %{"defaultBranchRef" => %{"name" => default_branch}, "pullRequest" => pull}}})
  end

  # A `gh` that answers the PR query with `graphql` and the REST reads from `rest`, reports each
  # call to the test, and fails the test on anything that writes.
  defp runner(graphql, rest \\ %{}) do
    test_pid = self()

    fn args, _opts ->
      send(test_pid, {:gh, args})
      refute Enum.any?(args, &(&1 in ["-X", "--method", "merge", "close", "edit"]))

      case args do
        ["api", "--include" | _rest] -> graphql
        ["api", endpoint] -> Map.fetch!(rest, endpoint)
        ["run", "list" | _rest] -> Map.fetch!(rest, :runs)
      end
    end
  end

  defp flush_gh do
    receive do
      {:gh, _args} -> flush_gh()
    after
      0 -> :ok
    end
  end

  defp read(graphql, rest \\ %{}, opts \\ []) do
    Fetch.read(@pr_url, Keyword.merge([gh_runner: runner(graphql, rest), required_checks: %{"main" => []}], opts))
  end

  describe "read/2" do
    test "reads a green, mergeable PR in one GraphQL query, with the rate limit GitHub reported" do
      assert {:ok, read} = read({response(pull()), 0})

      assert %{
               pr: :open,
               pr_number: 42,
               base: :ok,
               base_ref: "main",
               head_sha: "abc123",
               auto_merge: :off,
               review_comments: :none,
               mergeable: :clean,
               ci: :green,
               missing_checks: [],
               failing_check: nil,
               required: nil,
               rate_limit: %{remaining: 4321, limit: 5000, reset_at: reset_at}
             } = read

      assert DateTime.to_unix(reset_at) == @reset
      assert_received {:gh, ["api", "--include", "graphql", "-f", "query=" <> _query, "-f", "owner=acme", "-f", "name=app", "-F", "number=42"]}
      refute_received {:gh, _args}
    end

    test "names the host for a GitHub Enterprise PR" do
      pr_url = "https://github.example.com/acme/app/pull/7"
      opts = [gh_runner: runner({response(pull()), 0}), github_enterprise_hosts: ["github.example.com"], required_checks: %{"main" => []}]

      assert {:ok, %{ci: :green}} = Fetch.read(pr_url, opts)
      assert_received {:gh, ["api", "--include", "--hostname", "github.example.com", "graphql" | _rest]}
    end

    test "reads the PR's lifecycle, auto-merge, review and merge state" do
      cases = [
        {%{"merged" => true, "state" => "MERGED"}, :pr, :merged},
        {%{"merged" => nil, "state" => "MERGED"}, :pr, :merged},
        {%{"state" => "CLOSED"}, :pr, :closed},
        {%{"isDraft" => true}, :pr, :draft},
        {%{"baseRefName" => "release"}, :base, :changed},
        {%{"autoMergeRequest" => %{"enabledAt" => "2026-10-16T00:00:00Z"}}, :auto_merge, :armed},
        {%{"reviewThreads" => %{"nodes" => [%{"isResolved" => false, "isOutdated" => false}]}}, :review_comments, :unaddressed},
        {%{"reviewThreads" => %{"nodes" => [%{"isResolved" => false, "isOutdated" => true}, %{"isResolved" => true}]}}, :review_comments, :none},
        {%{"reviewDecision" => "CHANGES_REQUESTED"}, :review_comments, :unaddressed},
        {%{"mergeable" => "CONFLICTING", "mergeStateStatus" => "BLOCKED"}, :mergeable, :dirty},
        {%{"mergeStateStatus" => "DIRTY"}, :mergeable, :dirty},
        {%{"mergeStateStatus" => "BEHIND"}, :mergeable, :behind},
        {%{"mergeStateStatus" => "HAS_HOOKS"}, :mergeable, :clean},
        {%{"mergeStateStatus" => "UNSTABLE"}, :mergeable, :unstable},
        {%{"mergeStateStatus" => "BLOCKED"}, :mergeable, :blocked},
        {%{"mergeStateStatus" => "DRAFT"}, :mergeable, :blocked},
        {%{"mergeStateStatus" => "UNKNOWN"}, :mergeable, :unknown}
      ]

      for {attrs, field, expected} <- cases do
        assert {:ok, read} = read({response(pull(attrs)), 0})
        assert Map.fetch!(read, field) == expected, "#{inspect(attrs)} → #{field}"
      end
    end

    test "a PR whose base is the default branch of a repo that doesn't name one is on its base" do
      assert {:ok, %{base: :ok}} = read({headers() <> Jason.encode!(%{"data" => %{"repository" => %{"defaultBranchRef" => nil, "pullRequest" => pull(%{"baseRefName" => "dev"})}}}), 0})
    end

    test "reads pending, no CI and status contexts" do
      assert {:ok, %{ci: :pending}} = read({response(pull(rollup([check("make all", nil)]))), 0})
      assert {:ok, %{ci: :none}} = read({response(pull(rollup([]))), 0})
      assert {:ok, %{ci: :none}} = read({response(pull(%{"commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => nil}}]}})), 0})

      status = %{"__typename" => "StatusContext", "context" => "deploy/preview", "state" => "SUCCESS", "targetUrl" => "https://ci.example/1"}
      assert {:ok, %{ci: :green}} = read({response(pull(rollup([status]))), 0})
      assert {:ok, %{ci: :pending}} = read({response(pull(rollup([%{status | "state" => "PENDING"}]))), 0})
    end

    test "a check the base branch requires that never reported keeps the head from green" do
      rest = %{
        @rules => {Jason.encode!([%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "make all"}, %{"context" => "e2e"}]}}]), 0},
        @branch => {Jason.encode!(%{"name" => "main"}), 0}
      }

      # Not known yet: read now, and handed back for the caller to keep.
      assert {:ok, %{ci: :required_missing, missing_checks: ["e2e"], required: {"main", ["make all", "e2e"]}}} =
               read({response(pull()), 0}, rest, required_checks: %{})

      assert_received {:gh, ["api", @rules]}

      # Known: not read again.
      assert {:ok, %{ci: :green, required: nil}} = read({response(pull()), 0}, %{}, required_checks: %{"main" => ["make all"]})
      refute_received {:gh, ["api", @rules]}

      # Not read while a check runs or failed: they can't make the head green yet.
      running = {response(pull(rollup([check("make all", nil)]))), 0}
      assert {:ok, %{ci: :pending, required: nil}} = read(running, %{}, required_checks: %{})
      refute_received {:gh, ["api", @rules]}

      # A failed read waits on the checks that reported.
      failed = %{@rules => {"boom", 1}}
      assert {:ok, %{ci: :green, required: nil}} = read({response(pull()), 0}, failed, required_checks: %{})

      # With no base branch there is nothing to require.
      assert {:ok, %{ci: :green}} = read({response(pull(%{"baseRefName" => nil})), 0}, %{}, required_checks: %{})
    end

    test "classifies a red head: plain, cancelled, a person's check, red on the base too" do
      runs = fn conclusions ->
        {Jason.encode!(
           for {workflow, conclusion} <- conclusions do
             %{"databaseId" => 1, "workflowName" => workflow, "status" => "completed", "conclusion" => conclusion, "url" => "u", "createdAt" => "2026-10-16T00:00:00Z"}
           end
         ), 0}
      end

      failing = rollup([check("make all", "SUCCESS"), check("test", "FAILURE", workflow: "ci"), check("lint", "FAILURE", workflow: "lint", run: 200)])

      green_on_base = %{runs: runs.([{"ci", "success"}, {"lint", "failure"}])}

      assert {:ok, %{ci: :red, red_kind: :failure, failing_check: "test"}} =
               read({response(pull(failing)), 0}, green_on_base)

      assert_received {:gh, ["run", "list", "-R", "acme/app", "--branch", "main", "--limit", "30" | _rest]}

      assert {:ok, %{red_kind: :also_red_on_base}} =
               read({response(pull(failing)), 0}, %{runs: runs.([{"ci", "failure"}, {"lint", "failure"}, {"ci", "success"}])})

      # The base's runs can't be read: a plain failure.
      assert {:ok, %{red_kind: :failure}} = read({response(pull(failing)), 0}, %{runs: {"boom", 1}})

      flush_gh()

      # A failing status context names no workflow: nothing to compare on the base.
      status = %{"__typename" => "StatusContext", "context" => "deploy", "state" => "FAILURE"}
      assert {:ok, %{red_kind: :failure, failing_check: "deploy"}} = read({response(pull(rollup([status]))), 0})
      refute_received {:gh, ["run", "list" | _rest]}

      # Without a base branch there is nothing to compare.
      assert {:ok, %{red_kind: :failure}} = read({response(pull(Map.merge(failing, %{"baseRefName" => nil}))), 0})
      refute_received {:gh, ["run", "list" | _rest]}

      cancelled = rollup([check("test", "CANCELLED", run: 300)])
      assert {:ok, %{ci: :red, red_kind: :cancelled}} = read({response(pull(cancelled)), 0})

      protected = rollup([check("protected paths", "FAILURE", workflow: "protected-paths")])
      assert {:ok, %{ci: :red, red_kind: :human_only, failing_check: "protected paths"}} = read({response(pull(protected)), 0})
      refute_received {:gh, ["run", "list" | _rest]}
    end

    test "a GitHub Enterprise red head reads the base's runs on its host" do
      pr_url = "https://github.example.com/acme/app/pull/7"
      runs = {Jason.encode!([%{"workflowName" => "ci", "status" => "completed", "conclusion" => "failure"}]), 0}
      gh = runner({response(pull(rollup([check("test", "FAILURE")]))), 0}, %{runs: runs})

      assert {:ok, %{red_kind: :also_red_on_base}} =
               Fetch.read(pr_url, gh_runner: gh, github_enterprise_hosts: ["github.example.com"], required_checks: %{})

      assert_received {:gh, ["run", "list", "-R", "github.example.com/acme/app" | _rest]}
    end

    test "only the newest run of a workflow counts" do
      superseded = rollup([check("test", "FAILURE", run: 100), check("test", "SUCCESS", run: 101)])
      assert {:ok, %{ci: :green}} = read({response(pull(superseded)), 0})
    end

    test "a PR GitHub doesn't have reads as missing" do
      missing = headers() <> Jason.encode!(%{"data" => %{"repository" => %{"defaultBranchRef" => %{"name" => "main"}, "pullRequest" => nil}}})
      assert {:ok, %{pr: :missing, pr_number: 42, head_sha: nil}} = read({missing, 0})

      # `gh` exits non-zero on GraphQL errors and appends its own line.
      not_found =
        headers() <>
          Jason.encode!(%{
            "data" => %{"repository" => %{"defaultBranchRef" => %{"name" => "main"}, "pullRequest" => nil}},
            "errors" => [%{"type" => "NOT_FOUND", "message" => "Could not resolve to a PullRequest with the number of 42."}]
          }) <> "\ngh: Could not resolve to a PullRequest with the number of 42.\n"

      assert {:ok, %{pr: :missing}} = read({not_found, 1})
    end

    test "GitHub's rate limit: headers, the GraphQL error type, or the REST message" do
      limited = "HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: #{@reset}\r\n\r\n{\"message\":\"forbidden\"}\ngh: HTTP 403\n"
      assert {:error, {:rate_limited, reset_at}} = read({limited, 1})
      assert DateTime.to_unix(reset_at) == @reset

      graphql = headers(0) <> Jason.encode!(%{"errors" => [%{"type" => "RATE_LIMITED", "message" => "API rate limit exceeded"}]})
      assert {:error, {:rate_limited, %DateTime{}}} = read({graphql, 0})

      assert {:error, {:rate_limited, nil}} = read({"gh: API rate limit exceeded for user ID 1. (HTTP 403)", 1})
    end

    test "other failures are errors" do
      assert {:error, :invalid_pr_url} = Fetch.read("https://example.com/acme/app/pull/1", [])
      assert {:error, {:gh_failed, _args, 1, "gh: connection refused"}} = read({"gh: connection refused", 1})
      assert {:error, {:gh_failed, _args, 1, _output}} = read({headers() <> "{\"data\":null}\ngh: oops", 1})
      assert {:error, {:gh_unavailable, _message}} = Fetch.read(@pr_url, gh_runner: fn _args, _opts -> raise ErlangError, original: :enoent end)

      graphql_error = headers() <> Jason.encode!(%{"errors" => [%{"type" => "FORBIDDEN", "message" => "no access"}, %{"oops" => 1}]})
      assert {:error, {:graphql_errors, ["no access", "%{\"oops\" => 1}"]}} = read({graphql_error, 0})

      assert {:error, :invalid_pr_payload} = read({headers() <> "{\"data\":{}}", 0})
      assert {:error, {:invalid_pr_payload, _message}} = read({headers() <> "not json", 0})

      # Output without headers is read as the body.
      assert {:ok, %{ci: :green, rate_limit: %{remaining: nil, reset_at: nil}}} =
               read({Jason.encode!(%{"data" => %{"repository" => %{"pullRequest" => pull()}}}), 0})

      assert {:ok, %{rate_limit: %{remaining: nil, reset_at: nil}}} =
               read({"HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: lots\r\n\r\n" <> Jason.encode!(%{"data" => %{"repository" => %{"pullRequest" => pull()}}}), 0})
    end
  end

  describe "rate_limited/1" do
    test "reads only GitHub's rate limit" do
      assert {:rate_limited, nil} = Fetch.rate_limited({:rate_limited, nil})
      assert {:rate_limited, nil} = Fetch.rate_limited({:gh_failed, [], 1, "You have exceeded a secondary rate limit"})
      assert Fetch.rate_limited({:gh_failed, [], 1, "HTTP/2.0 404 Not Found\r\nX-Ratelimit-Remaining: 10\r\n\r\n{}"}) == nil
      assert Fetch.rate_limited(:timeout) == nil
    end
  end

  describe "facts/2" do
    @ticket %{phase: :code_review, origin: :qa, hold: :none, run: :none, max_red_attempts: 3, ahead: []}

    test "builds the facts from the ticket and its PR's read" do
      assert {:ok, read} = read({response(pull(%{"mergeStateStatus" => "BEHIND"})), 0})
      ahead = [%{issue_identifier: "TP-2", pr_number: 2, pr_url: "u", files: ["SPEC.md"]}]

      facts = Fetch.facts(%{@ticket | ahead: ahead}, read)
      assert %Facts{phase: :code_review, origin: nil, pr: :open, pr_number: 42, ci: :green, mergeable: :behind} = facts
      assert %Facts{max_red_attempts: 3, ahead: ^ahead, competing: []} = facts
    end

    test "keeps the origin only in CI Fix, and reads a ticket without a PR as missing" do
      assert %Facts{phase: :ci_fix, origin: :qa, pr: :missing, hold: :blocked, run: :active} =
               Fetch.facts(%{@ticket | phase: :ci_fix, hold: :blocked, run: :active}, nil)
    end
  end
end
