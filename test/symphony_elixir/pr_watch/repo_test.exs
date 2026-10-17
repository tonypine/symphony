defmodule SymphonyElixir.PrWatch.RepoTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.{PrWatch, TicketPullRequest, TicketState}
  alias SymphonyElixir.PrWatch.Repo

  @now ~U[2026-10-16 12:00:00Z]

  # Linear: the watched states' issues from the test's env. The CI label the watcher projects is
  # reported to the test; every other write fails it.
  defmodule FakeTracker do
    def fetch_issues_by_states_with_failures(states) do
      send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:linear_read, states})

      case Application.get_env(:symphony_elixir, :pr_watch_test_issues, []) do
        {:error, _reason} = error -> error
        {issues, failures} -> {:ok, issues, failures}
        issues -> {:ok, issues, []}
      end
    end

    @writes [
      create_comment: 2,
      update_issue_state: 2,
      add_issue_label: 2,
      remove_issue_label: 2,
      create_reply: 3
    ]

    for {name, arity} <- @writes do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: raise("PrWatch wrote to Linear: #{unquote(name)} #{inspect([unquote_splicing(args)])}")
    end

    def set_machine_label(issue_id, label), do: send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:label_set, issue_id, label}) && :ok
    def clear_machine_label(_issue_id, _label), do: :ok
  end

  # GitHub: the open PRs from the test's env. Every write fails the test.
  defmodule FakeGitHub do
    def list_open_pull_requests(pr_url, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:list_open_pull_requests, pr_url})
      Application.get_env(:symphony_elixir, :pr_watch_test_open_pulls, {:ok, []})
    end

    @writes [
      enable_auto_merge: 3,
      disable_auto_merge: 3,
      squash_merge: 3,
      close: 2,
      update_branch: 3,
      rerun_failed: 2,
      request_review: 3,
      cancel_stale_runs: 3,
      reply_to_comment: 4
    ]

    for {name, arity} <- @writes do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: raise("PrWatch wrote to GitHub: #{unquote(name)} #{inspect([unquote_splicing(args)])}")
    end
  end

  # The PR reads, by URL, from the test's env.
  defmodule FakeFetch do
    alias SymphonyElixir.PrWatch.RepoTest

    def read(pr_url, opts) do
      send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:read, pr_url, opts})

      case Map.fetch(Application.get_env(:symphony_elixir, :pr_watch_test_reads, %{}), pr_url) do
        {:ok, result} -> result
        :error -> {:ok, RepoTest.read_of(pr_url)}
      end
    end
  end

  # The run store, failing every read and write the watcher makes.
  defmodule FailingStore do
    def list_ticket_states(_repo_key), do: {:error, :store_down}
    def list_runs_with_status(_status), do: {:error, :store_down}
    def put_ticket_pr_watch(_repo_key, _issue_id, _identifier, _watch), do: {:error, :store_down}
    def list_pr_reviews(_repo_key), do: {:error, :store_down}
  end

  setup do
    Application.put_env(:symphony_elixir, :pr_watch_test_pid, self())

    on_exit(fn ->
      for key <- [:pr_watch_test_pid, :pr_watch_test_issues, :pr_watch_test_open_pulls, :pr_watch_test_reads],
          do: Application.delete_env(:symphony_elixir, key)
    end)

    %{repo_key: Config.repo_key!()}
  end

  @doc false
  def read_of(pr_url, attrs \\ %{}) do
    number = pr_url |> String.split("/") |> List.last() |> String.to_integer()

    Map.merge(
      %{
        pr_url: pr_url,
        pr_number: number,
        pr: :open,
        base: :ok,
        base_ref: "main",
        head_sha: "sha-#{number}",
        auto_merge: :off,
        review_comments: :none,
        mergeable: :clean,
        ci: :green,
        missing_checks: [],
        red_kind: :failure,
        failing_check: nil,
        rate_limit: %{remaining: 4000, reset_at: ~U[2026-10-16 13:00:00Z]},
        required: nil
      },
      attrs
    )
  end

  defp issue(id, state, attrs \\ []) do
    struct!(%Issue{id: id, identifier: "TP-#{id}", title: "Ticket #{id}", state: state, labels: []}, attrs)
  end

  defp pr_url(number), do: "https://github.com/acme/app/pull/#{number}"

  defp with_pr(repo_key, %Issue{id: id} = issue, number) do
    :ok = TicketPullRequest.put(repo_key, id, %{pr_url: pr_url(number), branch: "auto/#{id}"})
    issue
  end

  defp issues!(issues), do: Application.put_env(:symphony_elixir, :pr_watch_test_issues, issues)
  defp reads!(reads), do: Application.put_env(:symphony_elixir, :pr_watch_test_reads, reads)

  defp start_repo!(repo_key, opts \\ []) do
    defaults = [
      repo_key: repo_key,
      name: nil,
      auto: false,
      tracker: FakeTracker,
      github: FakeGitHub,
      fetch: FakeFetch,
      interval_ms: 30_000,
      now: fn -> @now end
    ]

    start_supervised!({Repo, Keyword.merge(defaults, opts)})
  end

  defp watch(repo_key, issue_id), do: repo_key |> RunStore.get_ticket_state(issue_id) |> TicketState.pr_watch()

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  test "poll_now/1 makes a running watcher tick at once", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    pid = start_repo!(repo_key)

    assert Repo.poll_now(pid) == :ok
    :sys.get_state(pid)
    refute_received {:read, _url, _opts}

    # A watcher that ticks on its own timer ticks at once.
    stop_supervised!({Repo, repo_key})
    pid = start_repo!(repo_key, auto: true, interval_ms: 3_600_000)
    assert_receive {:read, "https://github.com/acme/app/pull/1", _opts}
    assert Repo.poll_now(pid) == :ok
    assert_receive {:read, "https://github.com/acme/app/pull/1", _opts}
  end

  test "a fact no rule matches is logged and leaves no decision, and a record from before stays counts its phase", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{mergeable: :bogus})}})
    pid = start_repo!(repo_key)

    log = capture_log(fn -> assert {:ok, _summary} = Repo.poll(pid) end)
    assert log =~ "PR watch has no rule for issue_id=1 issue_identifier=TP-1"
    assert %{decision: nil, stay: :code_review} = watch(repo_key, "1")

    # A record written before the watcher kept its stay reads its facts' phase.
    SymphonyElixir.PrWatchSupport.put_watch!(repo_key, "1", phase: :code_review)
    reads!(%{})
    assert {:ok, _summary} = Repo.poll(pid)
    assert %{decision: %{rule: "R27"}, stay: :code_review} = watch(repo_key, "1")
  end

  test "a ticket moved into Code Review by hand, with no run, is watched from the next tick", %{repo_key: repo_key} do
    issues!([
      repo_key |> with_pr(issue("1", "Code Review"), 1),
      issue("2", "In Progress"),
      repo_key |> with_pr(issue("3", "In Progress"), 3),
      issue("4", "Todo"),
      issue("5", "Rework", labels: ["plan"]),
      issue("6", "Code Review", repo_key: "other-repo")
    ])

    assert RunStore.get_ticket_state(repo_key, "1") == nil
    pid = start_repo!(repo_key)

    assert {:ok, %{watched: 3, errors: 0, rate_limited: nil, next_tick_ms: 30_000}} = Repo.poll(pid)

    assert_received {:linear_read, ["In Progress", "Code Review", "QA", "Rework", "CI Fix", "Merging"]}
    assert %{issue_identifier: "TP-1"} = RunStore.get_ticket_state(repo_key, "1")

    assert %{facts: %Facts{phase: :code_review, pr: :open, pr_number: 1, ci: :green}} = watch(repo_key, "1")
    assert %{facts: %Facts{mergeable: :clean}} = watch(repo_key, "1")
    assert %{facts: %Facts{run: :none, hold: :none, max_red_attempts: 10, ahead: []}} = watch(repo_key, "1")

    assert %{
             pr_url: "https://github.com/acme/app/pull/1",
             head_sha: "sha-1",
             source: :poll,
             read_at: @now,
             github: :ok,
             rate_limit: %{remaining: 4000},
             landing: %{state: "Code Review", head_sha: "sha-1", state_since: @now, progress_at: @now},
             decision: %{rule: "R27", kind: :dispatch, reason: "The head is green, so the reviewer runs", head_sha: "sha-1", outcome: :recorded},
             applied: [],
             links: []
           } = watch(repo_key, "1")

    # The head's CI label follows the facts.
    assert_received {:label_set, "1", "CI green"}

    # A watched state with no PR is watched without a read: In Progress waits for the agent to open
    # one (R5). A plan parent never opens one, so it isn't watched.
    assert %{facts: %Facts{phase: :in_progress, pr: :open}} = watch(repo_key, "3")

    assert %{facts: %Facts{phase: :in_progress, pr: :missing}, pr_url: nil, landing: nil} = watch(repo_key, "2")
    assert %{decision: %{rule: "R5", kind: :wait, owner: :agent}} = watch(repo_key, "2")

    assert RunStore.get_ticket_state(repo_key, "5") == nil
    assert RunStore.get_ticket_state(repo_key, "4") == nil
    assert RunStore.get_ticket_state(repo_key, "6") == nil
  end

  test "one read per watched PR per tick, plus one open-PR list per repo per tick", %{repo_key: repo_key} do
    issues!([
      repo_key |> with_pr(issue("1", "Code Review"), 1),
      repo_key |> with_pr(issue("2", "QA"), 2),
      repo_key |> with_pr(issue("3", "Merging"), 3)
    ])

    pid = start_repo!(repo_key)

    for _tick <- 1..2 do
      flush()
      assert {:ok, %{watched: 3}} = Repo.poll(pid)

      assert_received {:read, "https://github.com/acme/app/pull/1", _opts}
      assert_received {:read, "https://github.com/acme/app/pull/2", _opts}
      assert_received {:read, "https://github.com/acme/app/pull/3", _opts}
      assert_received {:list_open_pull_requests, _pr_url}
      refute_received {:read, _pr_url, _opts}
      refute_received {:list_open_pull_requests, _pr_url}
    end
  end

  test "ahead: the QA PR waits for the Merging PR that shares SPEC.md; the Merging PR and a forced PR wait for none", %{repo_key: repo_key} do
    issues!([
      repo_key |> with_pr(issue("1", "QA"), 1),
      repo_key |> with_pr(issue("2", "Merging"), 2),
      repo_key |> with_pr(issue("3", "Code Review", labels: ["expedite"]), 3),
      repo_key |> with_pr(issue("4", "Code Review"), 4)
    ])

    Application.put_env(
      :symphony_elixir,
      :pr_watch_test_open_pulls,
      {:ok,
       [
         %{number: 1, url: pr_url(1), head_sha: "sha-1", files: ["SPEC.md", "lib/a.ex"]},
         %{number: 2, url: pr_url(2), head_sha: "sha-2", files: ["README.md", "SPEC.md"]},
         %{number: 3, url: pr_url(3), head_sha: "sha-3", files: ["SPEC.md"]},
         %{number: 4, url: pr_url(4), head_sha: "sha-4", files: ["lib/other.ex"]},
         %{number: nil, url: nil, head_sha: nil, files: []}
       ]}
    )

    pid = start_repo!(repo_key)
    assert {:ok, %{watched: 4}} = Repo.poll(pid)

    assert %{facts: %Facts{ahead: []}} = watch(repo_key, "2")
    leader = %{issue_identifier: "TP-2", pr_number: 2, pr_url: "https://github.com/acme/app/pull/2", files: ["SPEC.md"]}
    assert %{facts: %Facts{ahead: [^leader]}} = watch(repo_key, "1")
    assert %{facts: %Facts{ahead: [], competing: []}} = watch(repo_key, "3")
    assert %{facts: %Facts{ahead: []}} = watch(repo_key, "4")

    # Waiting for its leader counts as moving.
    later = DateTime.add(@now, 60, :second)
    stop_supervised!({Repo, repo_key})
    pid = start_repo!(repo_key, now: fn -> later end)
    assert {:ok, _summary} = Repo.poll(pid)
    assert %{landing: %{state_since: @now, progress_at: ^later}} = watch(repo_key, "1")
    assert %{landing: %{state_since: @now, progress_at: @now}} = watch(repo_key, "2")

    # The open PRs can't be read: each ticket keeps the PR it waited for.
    Application.put_env(:symphony_elixir, :pr_watch_test_open_pulls, {:error, :boom})
    assert {:ok, %{errors: 0}} = Repo.poll(pid)
    assert %{facts: %Facts{ahead: [%{issue_identifier: "TP-2"}]}} = watch(repo_key, "1")
    assert %{facts: %Facts{ahead: []}} = watch(repo_key, "2")
  end

  test "a ticket that moved or whose head moved starts its landing again", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    pid = start_repo!(repo_key)
    assert {:ok, _summary} = Repo.poll(pid)

    later = DateTime.add(@now, 60, :second)
    stop_supervised!({Repo, repo_key})
    pid = start_repo!(repo_key, now: fn -> later end)

    reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{head_sha: "new"})}})
    assert {:ok, _summary} = Repo.poll(pid)
    assert %{landing: %{state_since: @now, progress_at: ^later, head_sha: "new"}} = watch(repo_key, "1")

    issues!([repo_key |> with_pr(issue("1", "QA"), 1)])
    assert {:ok, _summary} = Repo.poll(pid)
    assert %{landing: %{state: "QA", state_since: ^later}} = watch(repo_key, "1")
  end

  test "the fact record survives a RunStore reload", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    assert {:ok, _summary} = repo_key |> start_repo!() |> Repo.poll()
    stop_supervised!({Repo, repo_key})

    before = watch(repo_key, "1")
    assert %{facts: %Facts{phase: :code_review, ci: :green}, source: :poll} = before

    restart_run_store()

    assert watch(repo_key, "1") == before
  end

  test "never writes to Linear or GitHub, reading PRs with the real Fetch", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Merging"), 1), repo_key |> with_pr(issue("2", "Code Review"), 2)])

    body =
      Jason.encode!(%{
        "data" => %{
          "repository" => %{
            "defaultBranchRef" => %{"name" => "main"},
            "pullRequest" => %{"number" => 1, "state" => "OPEN", "baseRefName" => "main", "headRefOid" => "abc", "mergeStateStatus" => "BEHIND", "commits" => %{"nodes" => []}}
          }
        }
      })

    test_pid = self()

    gh_runner = fn args, _opts ->
      send(test_pid, {:gh, args})

      if Enum.any?(args, &(&1 in ["-X", "--method", "merge", "close", "edit", "rerun", "update-branch"])) or Enum.any?(args, &(&1 =~ "mutation")),
        do: flunk("PrWatch wrote to GitHub: #{inspect(args)}")

      {"HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 10\r\n\r\n" <> body, 0}
    end

    pid = start_repo!(repo_key, fetch: SymphonyElixir.PrWatch.Fetch, gh_runner: gh_runner)
    assert {:ok, %{watched: 2, errors: 0}} = Repo.poll(pid)
    assert %{facts: %Facts{phase: :merging, mergeable: :behind, ci: :none}} = watch(repo_key, "1")
    assert_received {:gh, ["api", "--include", "graphql" | _rest]}
  end

  test "a rate-limited read backs off until the reset and marks the tickets it didn't read", %{repo_key: repo_key} do
    reset_at = DateTime.add(@now, 600, :second)
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1), repo_key |> with_pr(issue("2", "QA"), 2)])
    pid = start_repo!(repo_key)
    assert {:ok, _summary} = Repo.poll(pid)

    reads!(%{pr_url(1) => {:error, {:rate_limited, reset_at}}})
    flush()

    assert {:ok, %{rate_limited: {:rate_limited, ^reset_at}, next_tick_ms: 600_000}} = Repo.poll(pid)
    assert_received {:read, "https://github.com/acme/app/pull/1", _opts}
    refute_received {:read, "https://github.com/acme/app/pull/2", _opts}

    for id <- ["1", "2"] do
      assert %{github: {:rate_limited, ^reset_at}, facts: facts, head_sha: "sha-" <> ^id} = watch(repo_key, id)
      assert %Facts{github: :rate_limited, ci: :green, pr: :open} = facts
    end

    # A ticket GitHub refused before its first read is recorded with what its ticket gives.
    issues!([repo_key |> with_pr(issue("3", "Rework"), 3)])
    reads!(%{pr_url(3) => {:error, {:gh_failed, [], 1, "API rate limit exceeded"}}})

    assert {:ok, %{rate_limited: {:rate_limited, nil}, next_tick_ms: 120_000}} = Repo.poll(pid)
    assert %{github: {:rate_limited, nil}, facts: facts, pr_url: "https://github.com/acme/app/pull/3"} = watch(repo_key, "3")
    assert %Facts{phase: :rework, github: :rate_limited, pr: :missing} = facts

    # A reset far away waits at most an hour; one already passed waits one interval.
    reads!(%{pr_url(3) => {:error, {:rate_limited, DateTime.add(@now, 86_400, :second)}}})
    assert {:ok, %{next_tick_ms: 3_600_000}} = Repo.poll(pid)

    reads!(%{pr_url(3) => {:error, {:rate_limited, DateTime.add(@now, -5, :second)}}})
    assert {:ok, %{next_tick_ms: 30_000}} = Repo.poll(pid)
  end

  test "a GitHub error keeps the facts and backs off exponentially up to 5 minutes", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    pid = start_repo!(repo_key)
    assert {:ok, %{next_tick_ms: 30_000}} = Repo.poll(pid)
    before = watch(repo_key, "1")

    reads!(%{pr_url(1) => {:error, :timeout}})

    assert {:ok, %{errors: 1, next_tick_ms: 60_000}} = Repo.poll(pid)
    assert {:ok, %{next_tick_ms: 120_000}} = Repo.poll(pid)
    assert {:ok, %{next_tick_ms: 240_000}} = Repo.poll(pid)
    assert {:ok, %{next_tick_ms: 300_000}} = Repo.poll(pid)
    assert watch(repo_key, "1") == before

    Application.delete_env(:symphony_elixir, :pr_watch_test_reads)
    assert {:ok, %{errors: 0, next_tick_ms: 30_000}} = Repo.poll(pid)
  end

  test "a failed Linear read is an error, never tickets leaving the set", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    pid = start_repo!(repo_key)
    assert {:ok, _summary} = Repo.poll(pid)

    issues!({[], [{repo_key, :timeout}]})
    assert {:error, {:linear_read_failed, ^repo_key}} = Repo.poll(pid)

    issues!({:error, :unauthorized})
    assert {:error, :unauthorized} = Repo.poll(pid)

    assert %{facts: %Facts{phase: :code_review}} = watch(repo_key, "1")

    # Another repo's failed read is not this one's.
    issues!({[], [{"other-repo", :timeout}]})
    assert {:ok, %{watched: 0}} = Repo.poll(pid)
    assert watch(repo_key, "1") == nil
  end

  test "a store that can't be read or written leaves the tick going", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1), issue("2", "In Progress")])
    pid = start_repo!(repo_key, run_store: FailingStore, settings: Config.settings!())

    log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{watched: 2, errors: 0}} = Repo.poll(pid) end)
    assert log =~ "PR watch could not write the facts issue_id=1 issue_identifier=TP-1 reason=:store_down"
    assert RunStore.get_ticket_state(repo_key, "1") == nil
  end

  test "open PRs that can't be read on the first tick leave nobody ahead", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "QA"), 1), repo_key |> with_pr(issue("2", "Merging"), 2)])
    Application.put_env(:symphony_elixir, :pr_watch_test_open_pulls, {:error, :boom})

    assert {:ok, %{watched: 2}} = repo_key |> start_repo!() |> Repo.poll()
    assert %{facts: %Facts{ahead: []}} = watch(repo_key, "1")
  end

  test "a ticket that leaves the watched states loses its fact record", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Merging"), 1), repo_key |> with_pr(issue("2", "QA"), 2)])
    :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "9", %{issue_identifier: "TP-9", phase: "Todo"}))
    pid = start_repo!(repo_key)
    assert {:ok, _summary} = Repo.poll(pid)

    issues!([repo_key |> with_pr(issue("2", "QA"), 2)])
    assert {:ok, %{watched: 1}} = Repo.poll(pid)

    assert %{issue_identifier: "TP-1", pr_watch: nil} = RunStore.get_ticket_state(repo_key, "1")
    assert %{pr_watch: %{}} = RunStore.get_ticket_state(repo_key, "2")
    assert %{phase: "Todo", pr_watch: nil} = RunStore.get_ticket_state(repo_key, "9")
  end

  test "holds, the CI Fix origin and an active run are read from Symphony's records", %{repo_key: repo_key} do
    issues!([
      repo_key |> with_pr(issue("1", "CI Fix"), 1),
      repo_key |> with_pr(issue("2", "CI Fix"), 2),
      repo_key |> with_pr(issue("3", "Rework"), 3)
    ])

    :ok = RunStore.put_ticket_state(repo_key |> TicketState.new("1", %{ci_fix_origin: "QA"}) |> TicketState.set_hold(:blocked, %{reason: "tooling"}))

    :ok =
      RunStore.put_ticket_state(
        repo_key
        |> TicketState.new("2", %{ci_fix_origin: "Todo"})
        |> TicketState.set_hold(:blocked, %{})
        |> TicketState.set_hold(:needs_decision, %{})
      )

    :ok = RunStore.put_run(%{repo_key: repo_key, run_id: "run-3", issue_id: "3", status: "running"})
    :ok = RunStore.put_run(%{repo_key: "other-repo", run_id: "run-other", issue_id: "1", status: "running"})

    assert {:ok, _summary} = repo_key |> start_repo!() |> Repo.poll()

    assert %{facts: %Facts{phase: :ci_fix, origin: :qa, hold: :blocked, run: :none}} = watch(repo_key, "1")
    assert %{facts: %Facts{phase: :ci_fix, origin: nil, hold: :needs_decision}} = watch(repo_key, "2")
    assert %{facts: %Facts{phase: :rework, origin: nil, hold: :none, run: :active}} = watch(repo_key, "3")
  end

  test "keeps the checks a base requires for 10 minutes", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{required: {"main", ["make all"]}})}})
    clock = :counters.new(1, [])
    pid = start_repo!(repo_key, now: fn -> DateTime.add(@now, :counters.get(clock, 1), :second) end)

    assert {:ok, _summary} = Repo.poll(pid)
    assert_received {:read, _url, opts}
    assert opts[:required_checks] == %{}

    Application.delete_env(:symphony_elixir, :pr_watch_test_reads)
    :counters.put(clock, 1, 599)
    assert {:ok, _summary} = Repo.poll(pid)
    assert_received {:read, _url, opts}
    assert opts[:required_checks] == %{"main" => ["make all"]}

    :counters.put(clock, 1, 600)
    assert {:ok, _summary} = Repo.poll(pid)
    assert_received {:read, _url, opts}
    assert opts[:required_checks] == %{}
  end

  test "ticks by itself every poll interval", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    start_repo!(repo_key, auto: true, interval_ms: 20)

    assert_receive {:read, _url, _opts}, 1_000
    assert_receive {:read, _url, _opts}, 1_000

    # A tick whose Linear read fails tries again after a longer wait.
    issues!({:error, :unauthorized})
    flush()
    assert_receive {:linear_read, _states}, 1_000
    assert_receive {:linear_read, _states}, 1_000
  end

  test "reads its settings from the repo's config and registers under the repo's name", %{repo_key: repo_key} do
    issues!([])
    fakes = [tracker: FakeTracker, fetch: FakeFetch, github: FakeGitHub]
    {:ok, pid} = Repo.start_link([repo_key: repo_key, auto: false] ++ fakes)
    assert GenServer.whereis(Repo.name(repo_key)) == pid
    assert {:ok, %{watched: 0, next_tick_ms: interval}} = Repo.poll(Repo.name(repo_key))
    assert interval == Config.settings!().polling.interval_ms
    GenServer.stop(pid)

    # A repo whose settings can't be read reports it, and its own ticks wait the longest backoff.
    {:ok, pid} = Repo.start_link(repo_key: "no-such-repo", auto: false, tracker: FakeTracker)
    assert {:error, _reason} = Repo.poll(pid)
    GenServer.stop(pid)

    {:ok, pid} = Repo.start_link(repo_key: "no-such-repo", tracker: FakeTracker)
    assert %{timer: timer} = :sys.get_state(pid)
    assert is_reference(timer)
    assert {:error, _reason} = Repo.poll(pid)
    assert Process.read_timer(:sys.get_state(pid).timer) > 290_000
    GenServer.stop(pid)
  end

  describe "PrWatch" do
    test "starts a watcher per repo that polls its PRs", %{repo_key: repo_key} do
      issues!([])
      opts = [repo_keys: [repo_key], name: :pr_watch_test_supervisor, auto: false, tracker: FakeTracker]
      pid = start_supervised!({PrWatch, opts})
      assert [{{Repo, ^repo_key}, child, :worker, [Repo]}] = Supervisor.which_children(pid)
      assert {:ok, %{watched: 0}} = Repo.poll(child)
    end
  end

  defp restart_run_store do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, RunStore) do
      :ok ->
        {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, RunStore)
        :ok

      {:error, :not_found} ->
        if pid = Process.whereis(RunStore), do: GenServer.stop(pid)
        {:ok, _pid} = GenServer.start(RunStore, [], name: RunStore)
        :ok
    end
  end
end
