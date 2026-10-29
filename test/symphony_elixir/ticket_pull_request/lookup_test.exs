defmodule SymphonyElixir.TicketPullRequest.LookupTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.TicketPullRequest.Lookup

  @repo_key "repo-a"
  @slug "acme/repo"
  @auto_pr "https://github.com/acme/repo/pull/11"
  @linear_pr "https://github.com/acme/repo/pull/12"
  @recorded_pr "https://github.com/acme/repo/pull/1"

  setup do
    :ok = RunStore.clear()
  end

  test "records a PR opened by hand on the ticket's Symphony branch or its Linear branch name" do
    pulls = [
      pull(11, "auto/ACME-1"),
      pull(12, "tony/acme-2-hand-made"),
      pull(13, "feature/unrelated")
    ]

    issues = [issue("issue-1", "ACME-1"), issue("issue-2", "ACME-2", "tony/acme-2-hand-made"), issue("issue-3", "ACME-3")]

    log = capture_log(fn -> assert :ok = Lookup.sweep(@repo_key, issues, github_repo: @slug, gh_runner: github(pulls)) end)

    assert_received {:gh, :list, "acme", "repo"}
    assert %{pr_url: @auto_pr, branch: "auto/ACME-1", state: "open", source: "github_lookup"} = TicketPullRequest.get(@repo_key, "issue-1")
    assert %{pr_url: @linear_pr, branch: "tony/acme-2-hand-made", source: "github_lookup"} = TicketPullRequest.get(@repo_key, "issue-2")
    assert TicketPullRequest.get(@repo_key, "issue-3") == nil
    assert log =~ "Found the pull request #{@auto_pr} of issue_identifier=ACME-1 on GitHub by its branch auto/ACME-1"

    # TP-1008's read function answers the found PR rather than the attachment.
    assert TicketPullRequest.current_url(issue("issue-1", "ACME-1")) == @auto_pr
    assert TicketPullRequest.current_url(issue("issue-2", "ACME-2")) == @linear_pr
  end

  test "runs no GitHub listing when every active ticket has an open record" do
    :ok = TicketPullRequest.put(@repo_key, "issue-1", %{pr_url: @recorded_pr, source: "created"})
    refuse = fn args, _opts -> flunk("unexpected gh call: #{inspect(args)}") end
    resolve = fn -> flunk("the GitHub repo is resolved only for a listing") end

    assert :ok = Lookup.sweep(@repo_key, [issue("issue-1", "ACME-1")], github_repo: resolve, gh_runner: refuse)
    assert :ok = Lookup.sweep(@repo_key, [], github_repo: resolve, gh_runner: refuse)
  end

  test "marks a recorded open PR GitHub no longer lists closed or merged, and keeps one still open" do
    merged = "https://github.com/acme/repo/pull/2"
    closed = "https://github.com/acme/repo/pull/3"
    beyond_listing = "https://github.com/acme/repo/pull/4"
    listed = "https://github.com/acme/repo/pull/5"

    for {issue_id, url} <- [{"issue-2", merged}, {"issue-3", closed}, {"issue-4", beyond_listing}, {"issue-5", listed}] do
      :ok = TicketPullRequest.put(@repo_key, issue_id, %{pr_url: url, source: "created"})
    end

    states = %{merged => "MERGED", closed => "CLOSED", beyond_listing => "OPEN"}
    runner = github([pull(5, "auto/ACME-5"), pull(11, "auto/ACME-2")], states)

    # ACME-9 has no record, so the listing runs; ACME-2's PR merged and a new one is open on its branch.
    assert :ok = Lookup.sweep(@repo_key, [issue("issue-9", "ACME-9"), issue("issue-2", "ACME-2")], github_repo: @slug, gh_runner: runner)

    assert %{pr_url: @auto_pr, state: "open", source: "github_lookup"} = TicketPullRequest.get(@repo_key, "issue-2")
    assert %{state: "closed"} = TicketPullRequest.get(@repo_key, "issue-3")
    assert %{state: "open"} = TicketPullRequest.get(@repo_key, "issue-4")
    assert %{state: "open"} = TicketPullRequest.get(@repo_key, "issue-5")

    assert_received {:gh, :view, ^merged}
    assert_received {:gh, :view, ^closed}
    assert_received {:gh, :view, ^beyond_listing}
    refute_received {:gh, :view, ^listed}
  end

  test "a GitHub failure leaves the records unchanged and logs once" do
    :ok = TicketPullRequest.put(@repo_key, "issue-1", %{pr_url: @recorded_pr, source: "created"})
    denied = fn _args, _opts -> {"gh: Bad credentials", 1} end

    log = capture_log(fn -> assert :ok = Lookup.sweep(@repo_key, [issue("issue-2", "ACME-2")], github_repo: @slug, gh_runner: denied) end)

    assert [_one] = Regex.scan(~r/Failed to list the open pull requests of acme\/repo for repo_key=repo-a/, log)
    assert %{state: "open", pr_url: @recorded_pr} = TicketPullRequest.get(@repo_key, "issue-1")
    assert TicketPullRequest.get(@repo_key, "issue-2") == nil
  end

  test "a failed re-check leaves the record open" do
    :ok = TicketPullRequest.put(@repo_key, "issue-1", %{pr_url: @recorded_pr, source: "created"})

    runner = fn
      ["api", "graphql" | _fields], _opts -> {listing([]), 0}
      ["pr", "view" | _fields], _opts -> {"gh: timeout", 1}
    end

    log = capture_log(fn -> assert :ok = Lookup.sweep(@repo_key, [issue("issue-2", "ACME-2")], github_repo: @slug, gh_runner: runner) end)

    assert log =~ "Failed to re-check the pull request #{@recorded_pr} for repo_key=repo-a"
    assert %{state: "open"} = TicketPullRequest.get(@repo_key, "issue-1")
  end

  test "skips a repo with no GitHub repository, and a store it cannot read" do
    refuse = fn args, _opts -> flunk("unexpected gh call: #{inspect(args)}") end

    assert :ok = Lookup.sweep(@repo_key, [issue("issue-1", "ACME-1")], github_repo: fn -> nil end, gh_runner: refuse)

    log = capture_log(fn -> assert :ok = Lookup.sweep("  ", [issue("issue-1", "ACME-1")], github_repo: @slug, gh_runner: refuse) end)
    assert log =~ "Failed to read the ticket pull request records repo_key=  "
  end

  test "logs a found PR it cannot record, and ignores tickets without an id or identifier" do
    issues = [issue("issue-1", "ACME-1"), %Issue{id: nil, identifier: "ACME-2"}, %Issue{id: "issue-3", branch_name: ""}]

    log =
      capture_log(fn ->
        assert :ok = Lookup.sweep(@repo_key, issues, github_repo: @slug, gh_runner: github([%{pull(11, "auto/ACME-1") | url: " "}, pull(13, "")]))
      end)

    assert log =~ "Failed to record the pull request found on GitHub for issue_id=issue-1: :invalid_pr_url"
    assert TicketPullRequest.get(@repo_key, "issue-1") == nil
    assert TicketPullRequest.get(@repo_key, "issue-3") == nil
  end

  describe "start/3" do
    setup do
      previous = Application.fetch_env(:symphony_elixir, :ticket_pull_request_gh_runner)

      on_exit(fn ->
        case previous do
          {:ok, runner} -> Application.put_env(:symphony_elixir, :ticket_pull_request_gh_runner, runner)
          :error -> Application.delete_env(:symphony_elixir, :ticket_pull_request_gh_runner)
        end
      end)
    end

    test "sweeps the polled repo off the poll, through the app's gh runner" do
      Application.put_env(:symphony_elixir, :ticket_pull_request_gh_runner, github([pull(11, "auto/ACME-1")]))
      result = {@repo_key, {:ok, [issue("issue-1", "ACME-1")]}}

      assert {:ok, pid} = Lookup.start(repo(), result)
      assert_sweep_ends(pid)

      assert %{pr_url: @auto_pr, source: "github_lookup"} = TicketPullRequest.get(@repo_key, "issue-1")
    end

    test "uses the real gh when no runner is configured, and starts nothing without a due repo or a supervisor" do
      Application.delete_env(:symphony_elixir, :ticket_pull_request_gh_runner)
      :ok = TicketPullRequest.put(@repo_key, "issue-1", %{pr_url: @recorded_pr, source: "created"})

      # Every ticket has an open record: the sweep makes no GitHub request.
      assert {:ok, pid} = Lookup.start(repo(), {@repo_key, {:ok, [issue("issue-1", "ACME-1")]}})
      assert_sweep_ends(pid)

      assert :ok = Lookup.start(nil, :not_due)
      assert :ok = Lookup.start(repo(), {@repo_key, {:error, :rate_limited}})
      assert :ok = Lookup.start(repo(), {@repo_key, {:ok, []}}, :no_such_task_supervisor)
    end
  end

  # Waits for a sweep started by `Lookup.start/3` to end. A sweep with nothing to wait on can exit
  # before `Process.monitor/1` runs, and the DOWN then carries `:noproc`; a crash carries its
  # `{exception, stacktrace}` and still fails.
  defp assert_sweep_ends(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc], 5_000
  end

  defp repo, do: %SystemSchema.Repo{name: @repo_key, workspace: %{github: @slug}}

  defp issue(id, identifier, branch_name \\ nil) do
    %Issue{id: id, identifier: identifier, branch_name: branch_name, repo_key: @repo_key}
  end

  defp pull(number, branch), do: %{number: number, url: "https://github.com/acme/repo/pull/#{number}", head_branch: branch}

  defp listing(pulls) do
    nodes = for %{number: number, url: url, head_branch: branch} <- pulls, do: %{"number" => number, "url" => url, "headRefName" => branch}
    Jason.encode!(%{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => nodes}}}})
  end

  # A stubbed `gh`: the repo's open PR listing, and a `pr view` answering each URL's state.
  defp github(pulls, states \\ %{}) do
    test_pid = self()

    fn
      ["api", "graphql", "-f", "query=" <> _query, "-f", "owner=" <> owner, "-f", "name=" <> name], _opts ->
        send(test_pid, {:gh, :list, owner, name})
        {listing(pulls), 0}

      ["pr", "view", url, "--json", _fields], _opts ->
        send(test_pid, {:gh, :view, url})
        {Jason.encode!(%{"url" => url, "state" => Map.fetch!(states, url)}), 0}
    end
  end
end
