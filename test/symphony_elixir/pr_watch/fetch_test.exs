defmodule SymphonyElixir.PrWatch.FetchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrDecision
  alias SymphonyElixir.PrDecision.{Action, Facts}
  alias SymphonyElixir.PrWatch.Fetch

  @pr_url "https://github.com/acme/app/pull/42"
  @rules "repos/acme/app/rules/branches/main?per_page=100"
  @branch "repos/acme/app/branches/main"
  @workflows "repos/acme/app/contents/.github/workflows?ref=main"
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
        "headRef" => %{"name" => "auto/TP-1"},
        "autoMergeRequest" => nil,
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
      "detailsUrl" => "https://github.com/acme/app/actions/runs/#{Keyword.get(opts, :run, 100)}/job/#{Keyword.get(opts, :job, 1)}",
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
        ["run", "view", run_id, "--json", "headSha,jobs" | _rest] -> Map.fetch!(rest, {:jobs, run_id})
        ["run", "view", run_id, "--log-failed" | _rest] -> Map.fetch!(rest, {:log, run_id})
      end
    end
  end

  # The base's latest runs, `{workflow, conclusion, run id}` each, newest first.
  defp base_runs(runs) do
    {Jason.encode!(
       for {workflow, conclusion, id} <- runs do
         %{"databaseId" => id, "workflowName" => workflow, "status" => "completed", "conclusion" => conclusion, "url" => "u", "createdAt" => "2026-10-16T00:00:00Z"}
       end
     ), 0}
  end

  # A run's commit and jobs, `{name, conclusion, job id}` each.
  defp jobs(sha, jobs) do
    {Jason.encode!(%{"headSha" => sha, "jobs" => for({name, conclusion, id} <- jobs, do: %{"databaseId" => id, "name" => name, "conclusion" => conclusion})}), 0}
  end

  # A run's `gh run view --log-failed`: each `{job, line}` as gh prints it.
  defp failed_log(lines), do: {Enum.map_join(lines, "\n", fn {job, line} -> "#{job}\tRun mix test\t2026-10-16T21:02:11.4Z #{line}" end), 0}

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

    test "reads the PR's lifecycle, auto-merge and merge state" do
      cases = [
        {%{"merged" => true, "state" => "MERGED"}, :pr, :merged},
        {%{"merged" => nil, "state" => "MERGED"}, :pr, :merged},
        {%{"state" => "CLOSED"}, :pr, :closed},
        {%{"state" => "CLOSED", "headRef" => nil}, :pr, :closed},
        {%{"headRef" => nil}, :pr, :closed},
        {%{"isDraft" => true, "headRef" => nil}, :pr, :closed},
        {%{"isDraft" => true}, :pr, :draft},
        {%{"baseRefName" => "release"}, :base, :changed},
        {%{"autoMergeRequest" => %{"enabledAt" => "2026-10-16T00:00:00Z"}}, :auto_merge, :armed},
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

    test "the base is compared with the repo's base branch when the caller names one, else the default branch" do
      on_develop = {response(pull(%{"baseRefName" => "develop"}), "main"), 0}
      known = %{"develop" => []}

      assert {:ok, %{base: :changed, base_branch: "develop"}} = read({response(pull(), "main"), 0}, %{}, base_branch: "develop")
      assert {:ok, %{base: :ok, base_branch: "develop"}} = read(on_develop, %{}, base_branch: "develop", required_checks: known)
      assert {:ok, %{base: :changed, base_branch: "main"}} = read(on_develop, %{}, required_checks: known)
    end

    test "a PR whose base is the default branch of a repo that doesn't name one is on its base" do
      assert {:ok, %{base: :ok}} = read({headers() <> Jason.encode!(%{"data" => %{"repository" => %{"defaultBranchRef" => nil, "pullRequest" => pull(%{"baseRefName" => "dev"})}}}), 0})
    end

    test "reads pending, no CI and status contexts" do
      assert {:ok, %{ci: :pending, awaiting_checks: false}} = read({response(pull(rollup([check("make all", nil)]))), 0})
      no_workflows = [base_workflows: %{"main" => false}]
      no_rollup = %{"commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => nil}}]}}

      assert {:ok, %{ci: :none, no_ci: :not_configured, workflows: nil}} =
               read({response(pull(rollup([]))), 0}, %{}, no_workflows)

      assert {:ok, %{ci: :none}} = read({response(pull(no_rollup)), 0}, %{}, no_workflows)

      status = %{"__typename" => "StatusContext", "context" => "deploy/preview", "state" => "SUCCESS", "targetUrl" => "https://ci.example/1"}
      assert {:ok, %{ci: :green}} = read({response(pull(rollup([status]))), 0})
      assert {:ok, %{ci: :pending}} = read({response(pull(rollup([%{status | "state" => "PENDING"}]))), 0})
    end

    test "a head with no checks: no CI only when the base has no workflow files (D2)" do
      no_checks = {response(pull(rollup([]))), 0}
      listing = fn names -> {Jason.encode!(Enum.map(names, &%{"type" => "file", "name" => &1})), 0} end

      # Not known yet: read now, and handed back for the caller to keep.
      assert {:ok, %{ci: :none, awaiting_checks: false, workflows: {"main", false}}} =
               read(no_checks, %{@workflows => listing.(["README.md"])})

      assert_received {:gh, ["api", @workflows]}
      assert {:ok, %{ci: :none, workflows: {"main", false}}} = read(no_checks, %{@workflows => {"gh: Not Found (HTTP 404)", 1}})

      # Workflows on the base: the head waits for its first check.
      assert {:ok, %{ci: :pending, awaiting_checks: true, workflows: {"main", true}}} =
               read(no_checks, %{@workflows => listing.(["ci.yml"])})

      assert {:ok, %{ci: :pending, awaiting_checks: true, workflows: nil}} =
               read(no_checks, %{}, base_workflows: %{"main" => true})

      assert {:ok, %{workflows: {"main", true}}} = read(no_checks, %{@workflows => listing.(["lint.yaml"])})

      # A base that can't be read counts as having workflows; so does a listing that isn't one.
      assert {:ok, %{ci: :pending, awaiting_checks: true, workflows: nil}} = read(no_checks, %{@workflows => {"gh: boom", 1}})
      assert {:ok, %{ci: :pending, workflows: nil}} = read(no_checks, %{@workflows => {"{}", 0}})

      # A head with checks, or one a required check is missing on, never reads the workflows.
      flush_gh()
      assert {:ok, %{ci: :green}} = read({response(pull()), 0})
      assert {:ok, %{ci: :required_missing}} = read(no_checks, %{}, required_checks: %{"main" => ["build"]})
      refute_received {:gh, ["api", @workflows]}

      # Without a base branch there is none to read.
      assert {:ok, %{ci: :pending, workflows: nil}} = read({response(pull(Map.merge(rollup([]), %{"baseRefName" => nil}))), 0})
    end

    test "carries every workflow run id of the head, for a rerun" do
      checks = rollup([check("make all", "SUCCESS", run: 100), check("lint", "SUCCESS", run: 100), check("test", nil, run: 101, workflow: "test")])
      assert {:ok, %{run_ids: ["100", "101"]}} = read({response(pull(checks)), 0})
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
      failing = rollup([check("make all", "SUCCESS"), check("test", "FAILURE", workflow: "ci"), check("lint", "FAILURE", workflow: "lint", run: 200, job: 2)])

      green_on_base = %{:runs => base_runs([{"ci", "success", 1}, {"lint", "failure", 2}])}

      assert {:ok, %{ci: :red, red_kind: :failure, base_red: nil, failing_check: "test"}} =
               read({response(pull(failing)), 0}, green_on_base)

      assert_received {:gh, ["run", "list", "-R", "acme/app", "--branch", "main", "--limit", "30" | _rest]}
      refute_received {:gh, ["run", "view" | _rest]}

      # Both checks failed on the base, and neither log names a failing test: compared by name only.
      red_head = {response(pull(failing)), 0}

      red_on_base = %{
        :runs => base_runs([{"ci", "failure", 1}, {"lint", "failure", 2}, {"ci", "success", 3}]),
        {:jobs, "1"} => jobs("base1", [{"build", "success", 10}, {"test", "failure", 11}]),
        {:jobs, "2"} => jobs("base1", [{"lint", "failure", 12}]),
        {:log, "100"} => failed_log([{"test", "** (CompileError) lib/app.ex:3: undefined function boom/0"}]),
        {:log, "200"} => failed_log([{"lint", "lib/app.ex:3 Line is too long"}])
      }

      assert {:ok, %{red_kind: :also_red_on_base, base_red: base_red} = read} = read(red_head, red_on_base)
      comparisons = read.comparisons
      assert base_red == %{check: "test", sha: "base1", run_id: "1", basis: :name}

      assert comparisons == %{{"https://github.com/acme/app/actions/runs/100/job/1", "11"} => :name, {"https://github.com/acme/app/actions/runs/200/job/2", "12"} => :name}
      assert_received {:gh, ["run", "view", "1", "--json", "headSha,jobs", "-R", "acme/app"]}
      assert_received {:gh, ["run", "view", "100", "--log-failed", "-R", "acme/app"]}

      # The base's runs, or its run's jobs, can't be read: a plain failure.
      assert {:ok, %{red_kind: :failure}} = read({response(pull(failing)), 0}, %{runs: {"boom", 1}})
      no_jobs = %{red_on_base | {:jobs, "1"} => {"boom", 1}}
      assert {:ok, %{red_kind: :failure, base_red: nil}} = read({response(pull(failing)), 0}, no_jobs)

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

      # Red only on a check a person clears: what the other checks say is kept for the phases before
      # Merging, running while no other check reported.
      protected = rollup([check("protected paths", "FAILURE", workflow: "protected-paths")])

      assert {:ok, %{ci: :red, red_kind: :human_only, failing_check: "protected paths", past_human_only: :pending}} =
               read({response(pull(protected)), 0})

      refute_received {:gh, ["run", "list" | _rest]}

      passed = rollup([check("protected paths", "FAILURE", workflow: "protected-paths"), check("test", "SUCCESS")])
      assert {:ok, %{ci: :red, red_kind: :human_only, past_human_only: :green}} = read({response(pull(passed)), 0})

      running = rollup([check("protected paths", "FAILURE", workflow: "protected-paths"), check("test", nil)])
      assert {:ok, %{ci: :red, red_kind: :human_only, past_human_only: :pending}} = read({response(pull(running)), 0})

      assert {:ok, %{red_kind: :cancelled, past_human_only: nil}} = read({response(pull(cancelled)), 0})
    end

    test "TP-1170: a cancellation beside a real failure is never named as the failure" do
      mixed = rollup([check("e2e", "CANCELLED", workflow: "macos-e2e", run: 300, job: 7), check("test", "FAILURE", run: 100, job: 8)])
      rest = %{:runs => base_runs([{"ci", "success", 1}]), {:log, "100"} => failed_log([{"test", "** (MatchError) no match"}])}

      assert {:ok, read} = read({response(pull(mixed)), 0}, rest)
      assert %{ci: :red, red_kind: :failure, failing_check: "test", past_cancelled: nil} = read
      assert [%{name: "e2e", run_id: "300", job_id: 7, conclusion: "CANCELLED"}, %{name: "test", job_id: 8}] = read.failed_checks

      # The failure is read from the failed run only, not the cancelled one.
      read = Fetch.failure(read, nil, gh_runner: runner({response(pull(mixed)), 0}, rest))
      assert %{failure: %{check: "test", error: "** (MatchError) no match"}} = read
      assert_received {:gh, ["run", "view", "100", "--log-failed" | _rest]}
      refute_received {:gh, ["run", "view", "300", "--log-failed" | _rest]}

      assert Fetch.failures([%{name: "e2e", conclusion: "CANCELLED"}]) == [%{name: "e2e", conclusion: "CANCELLED"}]
    end

    test "TP-1170: a head red only on cancellations reads the required checks, to set aside the ones the base doesn't require" do
      rest = %{
        @rules => {Jason.encode!([%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "make all"}]}}]), 0},
        @branch => {Jason.encode!(%{"name" => "main"}), 0}
      }

      install = check("install script", "CANCELLED", workflow: "macos", run: 300)
      passed = rollup([check("make all", "SUCCESS"), install])
      assert {:ok, read} = read({response(pull(passed)), 0}, rest, required_checks: %{})
      assert %{ci: :red, red_kind: :cancelled, past_cancelled: :green, required: {"main", ["make all"]}} = read
      assert_received {:gh, ["api", @rules]}

      # What the other checks say: running while one runs, waiting on a required check never reported.
      known = [required_checks: %{"main" => ["make all"]}]
      running = rollup([check("make all", nil), install])
      assert {:ok, %{past_cancelled: :pending}} = read({response(pull(running)), 0}, %{}, known)
      missing = rollup([check("lint", "SUCCESS"), install])
      assert {:ok, %{past_cancelled: :required_missing}} = read({response(pull(missing)), 0}, %{}, known)
      assert {:ok, %{past_cancelled: :green}} = read({response(pull(rollup([install]))), 0})

      # A required check cancelled, or required checks that can't be read: never set aside.
      required = [required_checks: %{"main" => ["install script"]}]
      assert {:ok, %{red_kind: :cancelled, past_cancelled: nil}} = read({response(pull(passed)), 0}, %{}, required)

      ExUnit.CaptureLog.capture_log(fn ->
        unreadable = %{@rules => {"boom", 1}}

        assert {:ok, %{red_kind: :cancelled, past_cancelled: nil}} =
                 read({response(pull(passed)), 0}, unreadable, required_checks: %{})
      end)

      # A real failure reads no required checks.
      flush_gh()
      failed = rollup([check("make all", "FAILURE"), install])

      assert {:ok, %{red_kind: :failure, past_cancelled: nil}} =
               read({response(pull(failed)), 0}, %{runs: base_runs([])}, required_checks: %{})

      refute_received {:gh, ["api", @rules]}
    end

    test "TP-1073: a check that passed on the base isn't red there because another job of its workflow failed" do
      head = rollup([check("coverage (3/4)", "SUCCESS", workflow: "make-all"), check("coverage (4/4)", "FAILURE", workflow: "make-all")])

      base = %{
        :runs => base_runs([{"make-all", "failure", 38_988_095_659}]),
        {:jobs, "38988095659"} => jobs("c1c4ae62", [{"coverage (3/4)", "failure", 1}, {"coverage (4/4)", "success", 2}])
      }

      assert {:ok, %{ci: :red, red_kind: :failure, base_red: nil} = read} = read({response(pull(head)), 0}, base)
      assert read.failing_check == "coverage (4/4)"
      refute_received {:gh, ["run", "view", _run_id, "--log-failed" | _rest]}
    end

    test "the same check is red on the base only when it failed the same tests there" do
      head =
        rollup([
          check("coverage (2/4)", "FAILURE", workflow: "make-all", job: 2),
          check("coverage (4/4)", "FAILURE", workflow: "make-all", job: 4)
        ])

      graphql = {response(pull(head)), 0}
      flaky = "1) test a tick that races the clock (SymphonyElixir.OrchestratorTest)"
      own = "1) test the watch block renders (SymphonyElixirWeb.WatchPayloadTest)"
      other = "2) test the clock (SymphonyElixir.ClockTest)"

      base = fn base_log ->
        %{
          :runs => base_runs([{"make-all", "failure", 7}]),
          {:jobs, "7"} => jobs("c1c4ae62", [{"coverage (2/4)", "failure", 72}, {"coverage (4/4)", "failure", 74}]),
          {:log, "100"} => failed_log([{"coverage (2/4)", "  " <> flaky}, {"coverage (4/4)", flaky}, {"coverage (4/4)", "  " <> flaky}]),
          {:log, "7"} => failed_log(base_log)
        }
      end

      # Both checks failed the tests they failed on the base, which read its jobs once.
      same = base.([{"coverage (2/4)", flaky}, {"coverage (4/4)", flaky}, {"coverage (4/4)", other}])

      assert {:ok, %{red_kind: :also_red_on_base, base_red: base_red, comparisons: comparisons}} = read(graphql, same)
      assert base_red == %{check: "coverage (2/4)", sha: "c1c4ae62", run_id: "7", basis: :tests}

      assert comparisons |> Map.values() |> Enum.uniq() == [:tests]
      assert_received {:gh, ["run", "view", "7", "--json" | _rest]}
      refute_received {:gh, ["run", "view", "7", "--json" | _rest]}

      # A test of the head's own that the base never failed: the head's failure, not the base's.
      different = base.([{"coverage (2/4)", flaky}, {"coverage (4/4)", other}])
      assert {:ok, %{red_kind: :failure, base_red: nil, comparisons: comparisons}} = read(graphql, different)
      assert comparisons[{"https://github.com/acme/app/actions/runs/100/job/4", "74"}] == :different

      # The head's own new test, failing in the job of the same name on the base for another test.
      own_test = Map.put(different, {:log, "100"}, failed_log([{"coverage (2/4)", flaky}, {"coverage (4/4)", own}]))
      assert {:ok, %{red_kind: :failure}} = read(graphql, own_test)

      # A comparison already made isn't read again.
      flush_gh()
      known = Map.new(comparisons, fn {key, _basis} -> {key, :tests} end)

      assert {:ok, %{red_kind: :also_red_on_base, comparisons: %{}}} =
               read(graphql, different, base_comparisons: known)

      refute_received {:gh, ["run", "view", _run_id, "--log-failed" | _rest]}

      # A log that can't be read leaves the names compared, and isn't kept.
      unread = Map.put(same, {:log, "7"}, {"HTTP 410", 1})
      assert {:ok, %{red_kind: :also_red_on_base, base_red: %{basis: :name}} = read} = read(graphql, unread)
      assert read.comparisons == %{}
    end

    test "a GitHub Enterprise red head reads the base's runs on its host" do
      pr_url = "https://github.example.com/acme/app/pull/7"
      runs = {Jason.encode!([%{"databaseId" => 5, "workflowName" => "ci", "status" => "completed", "conclusion" => "failure"}]), 0}
      base = %{:runs => runs, {:jobs, "5"} => jobs("base1", [{"test", "failure", 50}]), {:log, "100"} => failed_log([{"test", "boom"}])}
      gh = runner({response(pull(rollup([check("test", "FAILURE")]))), 0}, base)

      assert {:ok, %{red_kind: :also_red_on_base}} =
               Fetch.read(pr_url, gh_runner: gh, github_enterprise_hosts: ["github.example.com"], required_checks: %{})

      assert_received {:gh, ["run", "list", "-R", "github.example.com/acme/app" | _rest]}
      assert_received {:gh, ["run", "view", "5", "--json", "headSha,jobs", "-R", "github.example.com/acme/app"]}
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

  describe "failure/3" do
    defmodule Logs do
      def fetch_failed_log(run_id, opts) do
        send(self(), {:log, run_id, opts[:repo]})

        case run_id do
          "500" -> {:error, :gone}
          _other -> {:ok, "setup\nERROR: test failed in run #{run_id}\nstack"}
        end
      end
    end

    defp red_read(attrs \\ %{}) do
      Map.merge(
        %{
          pr_url: @pr_url,
          head_sha: "abc123",
          ci: :red,
          red_kind: :failure,
          failing_check: "test",
          failed_checks: [%{name: "test", run_id: "100"}]
        },
        attrs
      )
    end

    test "reads a plain red head's failed check and first error line once, with the log for the fix run" do
      read = Fetch.failure(red_read(), nil, github: Logs, line_limit: 5)
      assert %{failure: %{check: "test", error: "ERROR: test failed in run 100", head_sha: "abc123"}, failed_log: %{excerpt: excerpt}} = read
      assert excerpt =~ "ERROR: test failed in run 100"
      assert_received {:log, "100", "acme/app"}

      # Known for this head: not read again.
      known = %{check: "test", error: "ERROR: earlier", head_sha: "abc123"}
      assert %{failure: ^known} = read = Fetch.failure(red_read(), known, github: Logs)
      refute Map.has_key?(read, :failed_log)
      refute_received {:log, _run_id, _repo}

      # Known for another head: read.
      assert %{failure: %{error: "ERROR: test failed in run 100"}} = Fetch.failure(red_read(), %{known | head_sha: "old"}, github: Logs)
    end

    test "names a check when the read names none, the host of an Enterprise PR, and nothing when the log can't be read" do
      assert %{failure: %{check: "a check"}} = Fetch.failure(red_read(%{failing_check: nil}), nil, github: Logs)

      enterprise = red_read(%{pr_url: "https://github.example.com/acme/app/pull/7"})
      assert %{failure: %{}} = Fetch.failure(enterprise, nil, github: Logs, github_enterprise_hosts: ["github.example.com"])
      assert_received {:log, "100", "github.example.com/acme/app"}

      assert %{failure: nil} = Fetch.failure(red_read(%{failed_checks: [%{name: "test", run_id: "500"}]}), nil, github: Logs)
      assert %{failure: %{}} = Fetch.failure(red_read(%{pr_url: "not a url"}), nil, github: Logs)
    end

    test "repo_opts names the repository `gh run` acts on" do
      assert Fetch.repo_opts(@pr_url) == [repo: "acme/app"]
      assert Fetch.repo_opts("https://github.example.com/acme/app/pull/7", github_enterprise_hosts: ["github.example.com"]) == [repo: "github.example.com/acme/app"]
      assert Fetch.repo_opts("not a url") == []
      assert Fetch.repo_opts(nil) == []
    end

    test "a head that isn't a plain red has no failure" do
      for attrs <- [%{ci: :green}, %{red_kind: :cancelled}, %{red_kind: :human_only}, %{head_sha: nil}] do
        assert %{failure: nil} = Fetch.failure(red_read(attrs), nil, github: Logs)
      end

      refute_received {:log, _run_id, _repo}
    end
  end

  describe "facts/2" do
    @ticket %{phase: :code_review, origin: :qa, hold: :none, run: :none, max_red_attempts: 3, ahead: []}

    test "builds the facts from the ticket and its PR's read" do
      assert {:ok, read} = read({response(pull(%{"mergeStateStatus" => "BEHIND"})), 0})
      ahead = [%{issue_identifier: "TP-2", pr_number: 2, pr_url: "u", files: ["SPEC.md"]}]

      facts = Fetch.facts(%{@ticket | ahead: ahead}, read)
      assert %Facts{phase: :code_review, origin: nil, pr: :open, pr_number: 42, ci: :green, mergeable: :behind} = facts
      assert %Facts{max_red_attempts: 3, ahead: ^ahead, competing: [], review_comments: :none} = facts
    end

    test "takes the review comments to address from the ticket, not from the read" do
      assert {:ok, read} = read({response(pull()), 0})
      assert %Facts{review_comments: :unaddressed} = Fetch.facts(Map.put(@ticket, :review_comments, :unaddressed), read)
    end

    test "TP-1154: a rerun still waiting for a runner reads as pending, and the watcher waits rather than rerunning it" do
      # Rule R19 reran the macos workflow's run 300: attempt 1's jobs (1, 2) were cancelled, and
      # attempt 2's build (3) is queued for a runner, its test job not created yet.
      attempt_1 = [check("build", "CANCELLED", run: 300, job: 1, workflow: "macos"), check("test", "CANCELLED", run: 300, job: 2, workflow: "macos")]
      queued = Map.put(check("build", nil, run: 300, job: 3, workflow: "macos"), "status", "QUEUED")

      assert {:ok, read} = read({response(pull(rollup([check("make all", "SUCCESS") | attempt_1] ++ [queued]))), 0})
      assert %{ci: :pending, failed_checks: [], run_ids: ["100", "300"]} = read

      assert %Action{rule: "R24", kind: :wait, owner: :ci, reason: "Checks are running on PR #42's head"} =
               @ticket |> Fetch.facts(read) |> PrDecision.decide()

      # Once attempt 2's every check was cancelled too, with nothing queued, the upkeep (U2) reruns
      # the run once and R19 waits for it.
      attempt_2 = [check("build", "CANCELLED", run: 300, job: 3, workflow: "macos"), check("test", "CANCELLED", run: 300, job: 4, workflow: "macos")]
      assert {:ok, read} = read({response(pull(rollup([check("make all", "SUCCESS") | attempt_1] ++ attempt_2))), 0})
      assert %{ci: :red, red_kind: :cancelled, failed_checks: [%{name: "build", run_id: "300"}, %{name: "test", run_id: "300"}]} = read
      assert [%Action{rule: "U2", kind: :rerun_failed}] = @ticket |> Fetch.facts(read) |> PrDecision.upkeep()
      assert %Action{rule: "R19", kind: :wait} = @ticket |> Fetch.facts(read) |> PrDecision.decide()
    end

    test "keeps the origin only in CI Fix, and reads a ticket without a PR as missing" do
      assert %Facts{phase: :ci_fix, origin: :qa, pr: :missing, hold: :blocked, run: :active} =
               Fetch.facts(%{@ticket | phase: :ci_fix, hold: :blocked, run: :active}, nil)
    end
  end
end
