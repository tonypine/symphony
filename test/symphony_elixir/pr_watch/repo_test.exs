defmodule SymphonyElixir.PrWatch.RepoTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{
    IdlePark,
    Pauses,
    PrWatch,
    Questions,
    TicketEvents,
    TicketObservation,
    TicketPullRequest,
    TicketState
  }

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.Repo
  alias SymphonyElixir.Situation.Recorder
  alias SymphonyElixirWeb.ObservabilityPubSub

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

  # Linear for R18's question: FakeTracker's reads and the comment the question posts, each reported
  # to the test. A ticket read by id is reported and fails: the watcher never makes one.
  defmodule AskingTracker do
    alias SymphonyElixir.PrWatch.RepoTest.FakeTracker

    defdelegate fetch_issues_by_states_with_failures(states), to: FakeTracker
    defdelegate set_machine_label(issue_id, label), to: FakeTracker
    defdelegate clear_machine_label(issue_id, label), to: FakeTracker

    def fetch_issue_states_by_ids(ids) do
      send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:linear_read_by_id, ids})
      {:error, :linear_must_not_be_read}
    end

    def create_comment(issue_id, body), do: send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:comment, issue_id, body}) && :ok
    def update_issue_state(issue_id, state), do: send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:moved, issue_id, state}) && :ok
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

  # GitHub for a PR that lands: FakeGitHub's reads, and the squash merge reported to the test.
  defmodule LandingGitHub do
    alias SymphonyElixir.PrWatch.RepoTest.FakeGitHub

    defdelegate list_open_pull_requests(pr_url, opts), to: FakeGitHub

    def squash_merge(pr_url, request, _opts), do: send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:merged, pr_url, request.head_sha}) && :ok
  end

  # The self-heal lane: the ticket it is given is reported to the test, and it files nothing.
  defmodule FakeSelfHeal do
    def heal(issue, _opts), do: send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:heal, issue}) && :held
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
    def get_github_updates(_key), do: {:error, :store_down}
    def put_github_updates(_key, _value), do: {:error, :store_down}
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
        past_human_only: nil,
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
      now: fn -> @now end,
      follow_records: false
    ]

    start_supervised!({Repo, Keyword.merge(defaults, opts)})
  end

  defp watch(_repo_key, issue_id), do: RunStore.get_ticket_state(issue_id) |> TicketState.pr_watch()

  # The registry drops a stopped watcher's name only once it handles the exit, so until then Check
  # Now still lists the watcher and calls a process that is gone.
  defp stop_registered!(pid) do
    GenServer.stop(pid)
    await_live_watchers!()
  end

  defp await_live_watchers!, do: eventually(fn -> registered_watchers() |> Enum.all?(fn {_repo_key, pid} -> Process.alive?(pid) end) end)

  defp registered_watchers, do: Registry.select(SymphonyElixir.Repo.Registry, [{{{:pr_watch, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

  defp reporting_timer(test_pid), do: fn message, delay_ms -> send(test_pid, {:timer, message, delay_ms}) && make_ref() end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  # The QA pre-build: every request is reported to the test.
  defmodule FakeQaBuild do
    def request(repo_key, head, ticket), do: send(Application.fetch_env!(:symphony_elixir, :pr_watch_test_pid), {:qa_build, repo_key, head, ticket}) && :ok
  end

  describe "the QA pre-build" do
    test "a head recorded for a ticket in Code Review or QA is asked for once, and a new head again", %{repo_key: repo_key} do
      watched = [{"1", "Code Review"}, {"2", "QA"}, {"3", "Merging"}]
      issues!(for {id, state} <- watched, do: with_pr(repo_key, issue(id, state), String.to_integer(id)))
      pid = start_repo!(repo_key, qa_build: FakeQaBuild)

      assert {:ok, _summary} = Repo.poll(pid)
      assert_received {:qa_build, ^repo_key, "sha-1", %{identifier: "TP-1", issue_id: "1"}}
      assert_received {:qa_build, ^repo_key, "sha-2", %{identifier: "TP-2", issue_id: "2"}}
      refute_received {:qa_build, _repo_key, _head, _ticket}

      # The same head on the next read asks for nothing.
      assert {:ok, _summary} = Repo.poll(pid)
      refute_received {:qa_build, _repo_key, _head, _ticket}

      # Branch upkeep or a push moved the head.
      reads!(%{pr_url(2) => {:ok, read_of(pr_url(2), %{head_sha: "sha-2b"})}})
      assert {:ok, _summary} = Repo.poll(pid)
      assert_received {:qa_build, ^repo_key, "sha-2b", %{identifier: "TP-2"}}
      refute_received {:qa_build, _repo_key, _head, _ticket}
    end

    test "a ticket that comes back to Code Review on a head it already had is asked for, and one with no identifier is not", %{repo_key: repo_key} do
      issues!([repo_key |> with_pr(issue("1", "Rework"), 1), repo_key |> with_pr(issue("2", "QA", identifier: nil), 2)])
      pid = start_repo!(repo_key, qa_build: FakeQaBuild)
      assert {:ok, _summary} = Repo.poll(pid)
      refute_received {:qa_build, _repo_key, _head, _ticket}

      issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
      assert {:ok, _summary} = Repo.poll(pid)
      assert_received {:qa_build, ^repo_key, "sha-1", %{identifier: "TP-1"}}
    end

    test "without the builder a new head asks nothing of anyone", %{repo_key: repo_key} do
      issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
      pid = start_repo!(repo_key)
      assert {:ok, _summary} = Repo.poll(pid)
      assert %{head_sha: "sha-1"} = watch(repo_key, "1")
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

  test "started as at boot, the watcher decides on a green reviewed PR before its first timed tick", %{repo_key: repo_key} do
    :ok = ObservabilityPubSub.subscribe_ticket_records()
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    pid = start_repo!(repo_key, auto: true, interval_ms: 3_600_000)

    # The first tick runs at start, not one interval on: the reviewer is asked for at once, and the
    # orchestrator is told so it dispatches the reviewer in its next cycle, not at its next tick.
    assert_receive {:read, "https://github.com/acme/app/pull/1", _opts}
    assert_receive {:ticket_record, ^repo_key, "1", :changed, [:pr_watch]}
    assert %{decision: %{rule: "R27", kind: :dispatch}} = watch(repo_key, "1")

    # The same decision on the next tick tells nobody again.
    assert {:ok, _summary} = Repo.poll(pid)
    refute_received {:ticket_record, ^repo_key, "1", :changed, [:pr_watch]}
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
    log = capture_log(fn -> assert {:ok, _summary} = Repo.poll(pid) end)
    assert %{decision: %{rule: "R27"}, stay: :code_review} = watch(repo_key, "1")

    # A new decision logs one line; the same decision on the next tick logs none.
    assert log =~ "pr_watch.decision issue_id=1 issue_identifier=TP-1 repo_key=#{repo_key} phase=code_review rule=R27 action=dispatch"
    refute capture_log(fn -> assert {:ok, _summary} = Repo.poll(pid) end) =~ "pr_watch.decision"
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

    assert RunStore.get_ticket_state("1") == nil
    pid = start_repo!(repo_key)

    assert {:ok, %{watched: 3, errors: 0, rate_limited: nil, next_tick_ms: 30_000}} = Repo.poll(pid)

    assert_received {:linear_read, ["In Progress", "Code Review", "QA", "Rework", "CI Fix", "Merging"]}
    assert %{issue_identifier: "TP-1"} = RunStore.get_ticket_state("1")

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

    assert RunStore.get_ticket_state("5") == nil
    assert RunStore.get_ticket_state("4") == nil
    # Ticket 6 is the other repo's: its one record, which this repo reads too, is that repo's.
    refute match?(%{repo_key: ^repo_key}, RunStore.get_ticket_state("6"))
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
    leader = %{issue_id: "2", issue_identifier: "TP-2", pr_number: 2, pr_url: "https://github.com/acme/app/pull/2", title: nil, head_sha: "sha-2", files: ["SPEC.md"]}
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

  test "a read's pull request stays on the ticket's record, past a read that failed and past the watch", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
    reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{pull_request: %{number: 1, url: pr_url(1), checks: []}})}})
    pid = start_repo!(repo_key)

    assert {:ok, _summary} = Repo.poll(pid)
    assert %{pr_watch: %{}, pull_request: %{number: 1, read_at: @now}} = RunStore.get_ticket_state("1")

    # Reads that bring none leave it as it was.
    reads!(%{pr_url(1) => {:ok, read_of(pr_url(1))}})
    assert {:ok, _summary} = Repo.poll(pid)
    assert %{pull_request: %{number: 1}} = RunStore.get_ticket_state("1")

    reads!(%{pr_url(1) => {:error, :offline}})
    capture_log(fn -> assert {:ok, _summary} = Repo.poll(pid) end)
    assert %{pull_request: %{number: 1}} = RunStore.get_ticket_state("1")

    issues!([])
    assert {:ok, _summary} = Repo.poll(pid)
    assert %{pr_watch: nil, pull_request: %{number: 1}} = RunStore.get_ticket_state("1")
  end

  test "never writes to Linear or GitHub, reading PRs with the real Fetch", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Merging"), 1), repo_key |> with_pr(issue("2", "Code Review"), 2)])

    body =
      Jason.encode!(%{
        "data" => %{
          "repository" => %{
            "defaultBranchRef" => %{"name" => "main"},
            "pullRequest" => %{"number" => 1, "state" => "OPEN", "baseRefName" => "main", "headRefOid" => "abc", "mergeStateStatus" => "BLOCKED", "commits" => %{"nodes" => []}}
          }
        }
      })

    test_pid = self()

    gh_runner = fn args, _opts ->
      send(test_pid, {:gh, args})

      if Enum.any?(args, &(&1 in ["-X", "--method", "merge", "close", "edit", "rerun", "update-branch"])) or Enum.any?(args, &(&1 =~ "mutation")),
        do: flunk("PrWatch wrote to GitHub: #{inspect(args)}")

      case args do
        # The base branch has no workflow files: the head with no checks has no CI.
        ["api", "repos/acme/app/contents/.github/workflows?ref=main"] -> {"[]", 0}
        _other -> {"HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 10\r\n\r\n" <> body, 0}
      end
    end

    pid = start_repo!(repo_key, fetch: SymphonyElixir.PrWatch.Fetch, gh_runner: gh_runner)
    assert {:ok, %{watched: 2, errors: 0}} = Repo.poll(pid)
    assert %{facts: %Facts{phase: :merging, mergeable: :blocked, ci: :none, base_ref: "main"}} = watch(repo_key, "1")
    assert_received {:gh, ["api", "--include", "graphql" | _rest]}
    assert_received {:gh, ["api", "repos/acme/app/contents/.github/workflows?ref=main"]}

    # What the base has is kept: the next tick doesn't read it again.
    flush()
    assert {:ok, %{errors: 0}} = Repo.poll(pid)
    refute_received {:gh, ["api", "repos/acme/app/contents/.github/workflows?ref=main"]}
  end

  test "a newest-release read that fails doesn't count as a failed tick", %{repo_key: repo_key} do
    issues!([])
    test_pid = self()

    gh_runner = fn args, _opts ->
      send(test_pid, {:gh, args})
      {"gh: Bad credentials (HTTP 401)", 1}
    end

    pid = start_repo!(repo_key, app_release: true, gh_runner: gh_runner)

    assert {:ok, %{errors: 0}} = Repo.poll(pid)
    assert_received {:gh, ["api", "--include", "repos/tonypine/symphony/releases/latest"]}
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

    # The record stays; only its silence is added. The clock stands still, so it counts no tick.
    assert %{silent: %{since: @now, ticks: 1}} = after_errors = watch(repo_key, "1")
    assert %{before | silent: nil} == %{after_errors | silent: nil}

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

  test "a tick writes every repo's watched tickets it read into their records, and watches only its own", %{repo_key: repo_key} do
    own = repo_key |> with_pr(issue("1", "Code Review", repo_key: repo_key, updated_at: ~U[2026-10-16 11:00:00Z]), 1)
    other = issue("2", "QA", repo_key: "observed-other-repo", url: "https://linear.app/acme/issue/TP-2", updated_at: ~U[2026-10-16 11:30:00Z])
    issues!([own, other])
    pid = start_repo!(repo_key)

    assert {:ok, %{watched: 1}} = Repo.poll(pid)

    assert %{phase: "Code Review", issue_identifier: "TP-1", linear_updated_at: ~U[2026-10-16 11:00:00Z]} = RunStore.get_ticket_state("1")
    assert %{phase: "QA", url: "https://linear.app/acme/issue/TP-2", pr_watch: nil} = RunStore.get_ticket_state("2")
  end

  test "a store that can't be read or written leaves the tick going", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "Code Review"), 1), issue("2", "In Progress")])
    pid = start_repo!(repo_key, run_store: FailingStore, settings: Config.settings!())

    log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{watched: 2, errors: 0}} = Repo.poll(pid) end)
    assert log =~ "PR watch could not write the facts issue_id=1 issue_identifier=TP-1 reason=:store_down"
    assert log =~ "PR watch could not keep the GitHub delivery health repo_key=#{repo_key} reason=:store_down"
    assert RunStore.get_ticket_state("1") == nil
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

    assert %{issue_identifier: "TP-1", pr_watch: nil} = RunStore.get_ticket_state("1")
    assert %{pr_watch: %{}} = RunStore.get_ticket_state("2")
    assert %{phase: "Todo", pr_watch: nil} = RunStore.get_ticket_state("9")
  end

  describe "TP-1204: Code Review's verdict on the head" do
    defp approved_on!(repo_key, head), do: :ok = put_verdict(repo_key, "1", "code_review", head, "approve")

    setup %{repo_key: repo_key} do
      issues!([with_pr(repo_key, issue("1", "Code Review"), 1)])
      red = %{head_sha: "sha-1", ci: :red, failing_check: "specs", failed_checks: [], check_names: ["specs"]}
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), red)}})
      %{pid: start_repo!(repo_key)}
    end

    test "a red head with no verdict is reviewed first", %{repo_key: repo_key, pid: pid} do
      assert {:ok, _summary} = Repo.poll(pid)
      assert %{facts: %Facts{review: :pending, ci: :red}, decision: %{rule: "R27", kind: :dispatch}} = watch(repo_key, "1")
    end

    test "an approve on the red head lets the CI rules act", %{repo_key: repo_key, pid: pid} do
      approved_on!(repo_key, "sha-1")

      assert {:ok, _summary} = Repo.poll(pid)
      assert %{facts: %Facts{review: :approved}, decision: %{rule: "R22"}} = watch(repo_key, "1")
    end

    test "an approve on another head, or a newer verdict on this one, is no approval of it", %{repo_key: repo_key, pid: pid} do
      approved_on!(repo_key, "sha-0")
      assert {:ok, _summary} = Repo.poll(pid)
      assert %{facts: %Facts{review: :pending}, decision: %{rule: "R27"}} = watch(repo_key, "1")

      approved_on!(repo_key, "sha-1")
      :ok = put_verdict(repo_key, "1", "code_review", "sha-1", "inconclusive")
      assert {:ok, _summary} = Repo.poll(pid)
      assert %{facts: %Facts{review: :pending}, decision: %{rule: "R27"}} = watch(repo_key, "1")
    end

    test "a verdict on the head says nothing in another phase", %{repo_key: repo_key, pid: pid} do
      approved_on!(repo_key, "sha-1")
      issues!([with_pr(repo_key, issue("1", "QA"), 1)])

      assert {:ok, _summary} = Repo.poll(pid)
      assert %{facts: %Facts{phase: :qa, review: :pending}, decision: %{rule: "R22"}} = watch(repo_key, "1")
    end
  end

  describe "the ticket's situation" do
    setup %{repo_key: repo_key} do
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :pending})}})
      %{issue: with_pr(repo_key, issue("1", "QA"), 1), recorder: start_supervised!(Recorder)}
    end

    test "a ticket that left the watched states with its CI pending gets the event of its new kind when the watcher drops its facts",
         %{repo_key: repo_key, issue: issue, recorder: recorder} do
      issues!([issue])
      pid = start_repo!(repo_key)
      assert {:ok, _summary} = Repo.poll(pid)
      publish_snapshot(recorder)
      assert situation_kinds() == ["waiting_for_ci"]

      # Cancelled while its CI is pending, with no webhook to say the PR closed: the facts still hold it.
      :ok = RunStore.update_ticket_state("1", %{phase: "Canceled"})

      issues!([])
      assert {:ok, %{watched: 0}} = Repo.poll(pid)
      settle_recorder(recorder)

      assert %{pr_watch: nil} = RunStore.get_ticket_state("1")
      assert situation_kinds() == ["waiting_for_ci", "cancelled"]
    end

    test "a read that changes only the phase the facts were read in is a reason to compute it", %{repo_key: repo_key, issue: issue, recorder: recorder} do
      issues!([%{issue | state: "Rework"}])
      pid = start_repo!(repo_key)
      assert {:ok, _summary} = Repo.poll(pid)
      publish_snapshot(recorder, %{running: [%{issue_id: "1", run_kind: "rework", started_at: @now}]})
      assert situation_kinds() == ["working"]

      # Handed off with a run still on the ticket: the head now waits for its checks.
      issues!([issue])
      assert {:ok, _summary} = Repo.poll(pid)
      settle_recorder(recorder)

      assert situation_kinds() == ["working", "waiting_for_ci"]
    end

    defp publish_snapshot(recorder, overrides \\ %{}) do
      Recorder.snapshot_published(Map.merge(%{running: [], retrying: [], slot_waiting: [], dispatch_skipped: []}, overrides))
      settle_recorder(recorder)
    end

    # The notice in its mailbox, then the flush it queued behind it.
    defp settle_recorder(recorder) do
      :sys.get_state(recorder)
      :sys.get_state(recorder)
    end

    defp situation_kinds do
      for %{payload: payload} <- TicketEvents.query("1", types: ["situation.changed"], limit: :all), do: payload.to
    end
  end

  test "holds, the CI Fix origin and an active run are read from Symphony's records", %{repo_key: repo_key} do
    issues!([
      repo_key |> with_pr(issue("1", "CI Fix"), 1),
      repo_key |> with_pr(issue("2", "CI Fix"), 2),
      repo_key |> with_pr(issue("3", "Rework"), 3)
    ])

    :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "1", %{ci_fix_origin: "QA"}))
    {:ok, _pause} = SymphonyElixir.Pauses.set({:ticket, repo_key, "1"}, SymphonyElixir.SelfHeal.environment_reason("dev_server"))

    :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "2", %{ci_fix_origin: "Todo"}))
    {:ok, _question} = Questions.ask({:ticket, repo_key, "2"}, decision_request("Which base?"), request: true)
    {:ok, _pause} = SymphonyElixir.Pauses.set({:ticket, repo_key, "2"}, SymphonyElixir.SelfHeal.environment_reason("dev_server"))

    :ok = RunStore.put_run(%{repo_key: repo_key, run_id: "run-3", issue_id: "3", status: "running"})
    :ok = RunStore.put_run(%{repo_key: "other-repo", run_id: "run-other", issue_id: "1", status: "running"})

    assert {:ok, _summary} = repo_key |> start_repo!() |> Repo.poll()

    assert %{facts: %Facts{phase: :ci_fix, origin: :qa, hold: :blocked, run: :none}} = watch(repo_key, "1")
    assert %{facts: %Facts{phase: :ci_fix, origin: nil, hold: :question}} = watch(repo_key, "2")
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

  test "TP-1073: keeps how a red head compared with the base for 10 minutes, and names the base run R23 waits on", %{repo_key: repo_key} do
    issues!([repo_key |> with_pr(issue("1", "QA"), 1)])
    key = {"https://github.com/acme/app/actions/runs/100/job/4", "74"}
    base_red = %{check: "specs", sha: "c1c4ae62", run_id: "38988095659", basis: :tests}
    red = %{ci: :red, red_kind: :also_red_on_base, failing_check: "specs", base_red: base_red, comparisons: %{key => :tests}}
    reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), red)}})
    clock = :counters.new(1, [])
    pid = start_repo!(repo_key, now: fn -> DateTime.add(@now, :counters.get(clock, 1), :second) end)

    log = capture_log(fn -> assert {:ok, _summary} = Repo.poll(pid) end)
    assert log =~ "the `specs` check is red on main too"
    assert log =~ "base_run_id=38988095659 base_sha=c1c4ae62 compared_by=tests"
    assert %{decision: %{rule: "R23", reason: "The `specs` check is red on the base branch too: it failed the same tests on main at c1c4ae62 (run 38988095659)"}} = watch(repo_key, "1")
    assert_received {:read, _url, opts}
    assert opts[:base_comparisons] == %{}

    Application.delete_env(:symphony_elixir, :pr_watch_test_reads)
    :counters.put(clock, 1, 599)
    assert {:ok, _summary} = Repo.poll(pid)
    assert_received {:read, _url, opts}
    assert opts[:base_comparisons] == %{key => :tests}

    :counters.put(clock, 1, 600)
    assert {:ok, _summary} = Repo.poll(pid)
    assert_received {:read, _url, opts}
    assert opts[:base_comparisons] == %{}
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
    stop_registered!(pid)

    # A repo whose settings can't be read reports it, and its own ticks wait the longest backoff.
    {:ok, pid} = Repo.start_link(repo_key: "no-such-repo", auto: false, tracker: FakeTracker)
    assert {:error, _reason} = Repo.poll(pid)
    stop_registered!(pid)

    {:ok, pid} = Repo.start_link(repo_key: "no-such-repo", tracker: FakeTracker)
    assert %{timer: timer} = :sys.get_state(pid)
    assert is_reference(timer)
    assert {:error, _reason} = Repo.poll(pid)
    assert Process.read_timer(:sys.get_state(pid).timer) > 290_000
    stop_registered!(pid)
  end

  describe "silent waits (TP-945)" do
    setup %{repo_key: repo_key} do
      clock = start_supervised!({Agent, fn -> @now end})
      %{clock: clock, pid: start_repo!(repo_key, name: Repo.name(repo_key), now: fn -> Agent.get(clock, & &1) end)}
    end

    defp advance!(clock, ms), do: Agent.update(clock, &DateTime.add(&1, ms, :millisecond))

    defp silent_lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "pr_watch.silent_wait"))

    defp tick_logged!(pid) do
      capture_log(fn -> assert {:ok, _summary} = Repo.poll(pid) end) |> silent_lines()
    end

    test "a Rework ticket with no run and no wait is listed on its second tick, logged once, and leaves when a run starts",
         %{repo_key: repo_key, clock: clock, pid: pid} do
      issues!([repo_key |> with_pr(issue("1", "Rework"), 1)])

      # The watcher decides to dispatch the rework run (R26), and no run starts.
      assert tick_logged!(pid) == []
      assert %{decision: %{rule: "R26", kind: :dispatch}, silent: %{ticks: 1, since: @now}} = watch(repo_key, "1")
      assert PrWatch.silent_waits(repo_key: repo_key) == []

      advance!(clock, 30_000)
      assert [line] = tick_logged!(pid)

      assert line =~
               "pr_watch.silent_wait issue_id=1 issue_identifier=TP-1 repo_key=#{repo_key} phase=rework since=2026-10-16T12:00:00Z rule=R26 bound=none " <>
                 ~s(reason="R26 decided `dispatch`, but no run started and no wait is recorded")

      assert [listed] = PrWatch.silent_waits(repo_key: repo_key)

      assert %{issue_id: "1", issue_identifier: "TP-1", repo_key: ^repo_key, phase: :rework} = listed
      assert %{since: @now, rule: "R26", bound: nil} = listed
      assert listed.pr_url == pr_url(1)

      # Still silent on the next tick: listed, not logged again.
      advance!(clock, 30_000)
      assert tick_logged!(pid) == []
      assert [%{since: @now}] = PrWatch.silent_waits(repo_key: repo_key)

      # A run starts: the ticket leaves on the next tick.
      :ok = RunStore.put_run(%{repo_key: repo_key, run_id: "run-1", issue_id: "1", status: "running"})
      assert tick_logged!(pid) == []
      assert %{silent: nil, decision: %{rule: "R9"}} = watch(repo_key, "1")
      assert PrWatch.silent_waits(repo_key: repo_key) == []
    end

    test "a ticket an idle run held stays watched, listed with its reason and age, and its PR's checks reporting lift the hold (TP-1175)",
         %{repo_key: repo_key, pid: pid} do
      ticket = {:ticket, repo_key, "1"}
      issues!([repo_key |> with_pr(issue("1", "In Progress"), 1)])
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :pending})}})
      assert {:ok, _summary} = Repo.poll(pid)

      :ok = IdlePark.hold(ticket, "TP-1", "In Progress", 2, watch(repo_key, "1"))

      # Still running: it stays held and watched, and the report lists it with the reason.
      assert {:ok, _summary} = Repo.poll(pid)
      assert %{decision: %{rule: "R4"}} = watch(repo_key, "1")
      assert [%{id: question_id}] = Questions.open(ticket)

      assert [%{issue_identifier: "TP-1", bound: "no_progress", since: %DateTime{}, rule: "R4", reason: "No progress: the last 2 turns in In Progress" <> _rest}] =
               PrWatch.silent_waits(repo_key: repo_key)

      # The checks report: the hold lifts, the question is withdrawn, the report no longer lists it.
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :green})}})
      assert {:ok, _summary} = Repo.poll(pid)
      assert Questions.open(ticket) == []
      assert %{state: :withdrawn} = Questions.find(ticket, question_id)
      assert {:ok, nil} = Pauses.get(ticket)
      assert PrWatch.silent_waits(repo_key: repo_key) == []
    end

    test "a hold whose park pushed a commit stays through the watcher's reads of that push and of the head before it, and a further head lifts it (TP-1175)",
         %{repo_key: repo_key, pid: pid} do
      ticket = {:ticket, repo_key, "1"}
      issues!([repo_key |> with_pr(issue("1", "In Progress"), 1)])
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :green})}})
      assert {:ok, _summary} = Repo.poll(pid)

      # The park pushed "sha-wip" after the watcher read "sha-1".
      :ok = IdlePark.hold(ticket, "TP-1", "In Progress", 2, watch(repo_key, "1"), "sha-wip")
      assert [%{id: question_id}] = Questions.open(ticket)

      for held_read <- [%{ci: :green}, %{ci: :pending, head_sha: "sha-wip"}] do
        reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), held_read)}})
        assert {:ok, _summary} = Repo.poll(pid)
        assert %{decision: %{rule: "R4"}} = watch(repo_key, "1")
        assert [%{id: ^question_id}] = Questions.open(ticket)
      end

      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :pending, head_sha: "sha-further"})}})
      assert {:ok, _summary} = Repo.poll(pid)
      assert %{state: :withdrawn} = Questions.find(ticket, question_id)
      assert {:ok, nil} = Pauses.get(ticket)
    end

    test "a held ticket lifts on a new head, and a hold with no read or no question lifts when its checks report (TP-1175)",
         %{repo_key: repo_key, pid: pid} do
      ticket = {:ticket, repo_key, "1"}
      issues!([repo_key |> with_pr(issue("1", "In Progress"), 1)])
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :pending})}})
      assert {:ok, _summary} = Repo.poll(pid)

      :ok = IdlePark.hold(ticket, "TP-1", "In Progress", 2, watch(repo_key, "1"))
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :pending, head_sha: "a-new-head"})}})
      assert {:ok, _summary} = Repo.poll(pid)
      assert {:ok, nil} = Pauses.get(ticket)

      # An identifier the question's plain-words check refuses: only the reason holds it.
      capture_log(fn -> :ok = IdlePark.hold(ticket, "`TP-1`", "In Progress", 2, nil) end)
      assert Questions.open(ticket) == []
      record = TicketState.normalize(RunStore.get_ticket_state("1"))

      # A read with no head (the PR is gone) changes nothing.
      assert IdlePark.settle(ticket, record, %{head_sha: nil, facts: %{ci: :none}}) == :held

      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :red, red_kind: :also_red_on_base, failing_check: "specs"})}})
      assert {:ok, _summary} = Repo.poll(pid)
      assert {:ok, nil} = Pauses.get(ticket)
    end

    test "a ticket no rule decides on is silent from its second tick", %{repo_key: repo_key, clock: clock, pid: pid} do
      issues!([repo_key |> with_pr(issue("1", "QA"), 1)])
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{mergeable: :bogus})}})

      assert tick_logged!(pid) == []

      # A poll inside the interval (a webhook, Check Now) is no second tick.
      advance!(clock, 5_000)
      assert tick_logged!(pid) == []
      assert PrWatch.silent_waits(repo_key: repo_key) == []

      advance!(clock, 25_000)
      assert [line] = tick_logged!(pid)
      assert line =~ ~s(phase=qa since=2026-10-16T12:00:00Z rule=none bound=none reason="the watcher has no decision on it")
    end

    test "TP-1196: a failed check in a run still going waits on CI, and the CI label says running", %{repo_key: repo_key, pid: pid} do
      issues!([repo_key |> with_pr(issue("1", "QA"), 1)])
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :red, red_kind: :run_in_progress, failing_check: "coverage (4/4)"})}})

      assert {:ok, _summary} = Repo.poll(pid)
      assert %{decision: %{rule: "R19b", owner: :ci}, facts: %Facts{ci: :red, failing_check: "coverage (4/4)"}} = watch(repo_key, "1")
      assert_received {:label_set, "1", "CI running"}
    end

    test "a silent ticket leaves once a wait is recorded on it", %{repo_key: repo_key, clock: clock, pid: pid} do
      issues!([repo_key |> with_pr(issue("1", "Rework"), 1)])
      assert {:ok, _summary} = Repo.poll(pid)
      advance!(clock, 30_000)
      assert {:ok, _summary} = Repo.poll(pid)
      assert [%{issue_identifier: "TP-1"}] = PrWatch.silent_waits(repo_key: repo_key)

      # The same check is red on the base: the ticket waits on CI (R23), a reason anybody can read.
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :red, red_kind: :also_red_on_base, failing_check: "specs"})}})
      assert {:ok, _summary} = Repo.poll(pid)
      assert %{silent: nil, decision: %{rule: "R23", owner: :ci, clears_when: clears_when}} = watch(repo_key, "1")
      assert is_binary(clears_when)
      assert PrWatch.silent_waits(repo_key: repo_key) == []
    end

    test "a wait owned by GitHub past its reset and a tick is listed with that bound", %{repo_key: repo_key, pid: pid} do
      issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])

      # Due to reset half a tick ago: still a reason.
      reads!(%{pr_url(1) => {:error, {:rate_limited, DateTime.add(@now, -15, :second)}}})
      assert tick_logged!(pid) == []
      assert %{decision: %{rule: "R1", owner: :github}, silent: nil} = watch(repo_key, "1")

      reset_at = DateTime.add(@now, -31, :second)
      reads!(%{pr_url(1) => {:error, {:rate_limited, reset_at}}})
      assert [line] = tick_logged!(pid)
      assert line =~ "rule=R1 bound=rate_limit_reset"

      assert [%{issue_identifier: "TP-1", bound: "rate_limit_reset", since: ^reset_at, reason: "R1: GitHub's rate limit was due to reset at 2026-10-16T11:59:29Z"}] =
               PrWatch.silent_waits(repo_key: repo_key)
    end

    test "a wait on CI keeps since when it began and is listed past ci.merging_wait_timeout_ms", %{repo_key: repo_key, clock: clock, pid: pid} do
      issues!([repo_key |> with_pr(issue("1", "QA"), 1)])
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :pending})}})

      assert {:ok, _summary} = Repo.poll(pid)
      assert %{decision: %{rule: "R24", owner: :ci, since: @now}, silent: nil} = watch(repo_key, "1")

      advance!(clock, Config.settings!().ci.merging_wait_timeout_ms + 1)
      assert [line] = tick_logged!(pid)
      assert line =~ "rule=R24 bound=ci.merging_wait_timeout_ms"
      assert %{decision: %{since: @now, decided_at: decided_at}, silent: silent} = watch(repo_key, "1")
      assert %{bound: "ci.merging_wait_timeout_ms", since: @now} = silent
      assert decided_at != @now

      # Green: a new decision, standing since this tick.
      reads!(%{})
      advance!(clock, 30_000)
      assert {:ok, _summary} = Repo.poll(pid)
      assert %{decision: %{rule: "R27", since: since}} = watch(repo_key, "1")
      assert since == Agent.get(clock, & &1)
    end

    test "Check Now reads and decides within the call, and names a ticket the watcher doesn't watch", %{repo_key: repo_key, clock: clock, pid: pid} do
      issues!([repo_key |> with_pr(issue("1", "Rework"), 1)])
      # Check Now calls every watcher the registry lists. This one stays up until the test stops it.
      await_live_watchers!()
      assert {repo_key, pid} in registered_watchers()
      watcher = Process.monitor(pid)

      # No record yet: every running watcher ticks, and the new record is the answer.
      assert {:ok, %{issue_identifier: "TP-1", pr_watch: %{decision: %{rule: "R26", decided_at: @now}}}} = PrWatch.check("TP-1", repo_key: repo_key)

      advance!(clock, 60_000)
      later = Agent.get(clock, & &1)
      assert {:ok, %{pr_watch: %{decision: %{rule: "R26", decided_at: ^later}}}} = PrWatch.check("TP-1", repo_key: repo_key)

      assert PrWatch.check("TP-404", repo_key: repo_key) == {:error, :not_watched}
      assert PrWatch.check("TP-404") == {:error, :not_watched}

      issues!({:error, :unauthorized})
      assert capture_log(fn -> assert PrWatch.check("TP-1", repo_key: repo_key) == {:error, :unauthorized} end) =~ "PR watch tick failed"
      refute_received {:DOWN, ^watcher, :process, ^pid, _reason}

      stop_supervised!({Repo, repo_key})
      await_live_watchers!()
      assert PrWatch.check("TP-1", repo_key: repo_key) == {:error, :watcher_not_running}
      assert PrWatch.check("TP-404", repo_key: repo_key) == {:error, :not_watched}
    end

    test "under a tenth of GitHub's rate limit left, the tick waits up to four intervals, or until the reset", %{repo_key: repo_key, pid: pid} do
      issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])

      low = fn reset_at ->
        rate_limit = %{remaining: 499, limit: 5000, reset_at: reset_at}
        reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{rate_limit: rate_limit})}})
      end

      low.(DateTime.add(@now, 600, :second))
      assert capture_log(fn -> assert {:ok, %{next_tick_ms: 120_000}} = Repo.poll(pid) end) =~ "pr_watch.rate_limit_low repo_key=#{repo_key} remaining=499 limit=5000 next_tick_ms=120000"

      low.(DateTime.add(@now, 45, :second))
      assert {:ok, %{next_tick_ms: 45_000}} = Repo.poll(pid)

      low.(DateTime.add(@now, -5, :second))
      assert {:ok, %{next_tick_ms: 30_000}} = Repo.poll(pid)

      low.(nil)
      assert {:ok, %{next_tick_ms: 120_000}} = Repo.poll(pid)

      assert %{remaining: 499, limit: 5000, reset_at: nil} = PrWatch.rate_limit(repo_key: repo_key)

      # A tenth or more left: the interval.
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{rate_limit: %{remaining: 500, limit: 5000, reset_at: nil}})}})
      assert {:ok, %{next_tick_ms: 30_000}} = Repo.poll(pid)
    end

    test "an action applied joins the last five, with how its facts arrived", %{repo_key: repo_key, clock: clock, pid: pid} do
      write_workflow_file!(Workflow.workflow_file_path(), ci: %{enabled: true})
      issues!([repo_key |> with_pr(issue("1", "QA"), 1)])

      for n <- 1..6 do
        # Each red head is rerun once (R22); its failed checks carry no run id, so nothing is called.
        red = %{head_sha: "sha-#{n}", ci: :red, failing_check: "specs", failed_checks: [], check_names: ["specs"]}
        reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), red)}})
        assert {:ok, _summary} = Repo.poll(pid)
        advance!(clock, 1_000)
      end

      assert %{actions: actions} = watch(repo_key, "1")
      assert Enum.map(actions, & &1.head_sha) == ["sha-6", "sha-5", "sha-4", "sha-3", "sha-2"]
      assert [%{rule: "R22", kind: :rerun_failed, source: :poll, at: %DateTime{}} | _older] = actions
    end
  end

  describe "a check GitHub left running after it finished (TP-1426)" do
    test "the ticket's history names it past the grace, once per head and check", %{repo_key: repo_key} do
      issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
      url = pr_url(1)
      recent = DateTime.add(@now, -30, :second)
      long_ago = DateTime.add(@now, -600, :second)

      notes = fn ->
        for %{payload: %{text: "GitHub still shows" <> _rest = text}} <- RunStore.list_ticket_events("1", types: ["note"]),
            do: text
      end

      stale = fn head, checks -> {:ok, read_of(url, %{head_sha: head, stale_checks: checks})} end

      pid = start_repo!(repo_key)

      # Within the grace: GitHub normally closes it, so nothing is recorded.
      reads!(%{url => stale.("sha-1", [%{name: "changes", since: recent}])})
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert notes.() == []
      assert %{stale_checks_noted: %{head_sha: "sha-1", names: []}} = watch(repo_key, "1")

      # Past it, one note names the check, and the next read adds none.
      reads!(%{url => stale.("sha-1", [%{name: "changes", since: long_ago}])})
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert [note] = notes.()
      assert note =~ "check changes"
      assert note =~ "head sha-1"
      assert note =~ "(stale_check)"
      assert %{stale_checks_noted: %{head_sha: "sha-1", names: ["changes"]}} = watch(repo_key, "1")

      # A new head notes it again, at once when GitHub gave no time.
      reads!(%{url => stale.("sha-2", [%{name: "changes", since: nil}])})
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert length(notes.()) == 2

      # A read that says nothing of them keeps what the record holds.
      reads!(%{url => {:ok, read_of(url, %{head_sha: "sha-2"})}})
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert %{stale_checks_noted: %{head_sha: "sha-2", names: ["changes"]}} = watch(repo_key, "1")
    end
  end

  describe "dispatch.source: record" do
    setup do
      on_exit(&Client.reset_viewer_cache_for_test/0)
      :ok
    end

    defp record_source!(opts \\ []) do
      write_workflow_file!(Workflow.workflow_file_path(), opts)
      File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "dispatch:\n  source: record\n")
      Cache.clear()
    end

    defp watched_ids(repo_key) do
      for %{pr_watch: %{}, issue_id: id} <- RunStore.list_ticket_states(repo_key), do: id
    end

    defp observed!(repo_key, %Issue{} = issue), do: {:ok, _outcome} = TicketObservation.observe(repo_key, %{issue | updated_at: @now})

    test "a tick watches the records in the watched states the Linear read would have returned, and reads no Linear", %{repo_key: repo_key} do
      issues =
        for issue <- [
              repo_key |> with_pr(issue("1", "Code Review"), 1),
              issue("2", "In Progress"),
              repo_key |> with_pr(issue("3", "In Progress"), 3),
              issue("4", "Todo"),
              issue("5", "Rework", labels: ["plan"]),
              issue("6", "Code Review", repo_key: "other-repo")
            ],
            do: %{issue | repo_key: issue.repo_key || repo_key, updated_at: @now}

      # Polling, the Linear read observes every ticket into its record and picks the watched ones.
      issues!(issues)
      pid = start_repo!(repo_key)
      assert {:ok, %{watched: 3}} = Repo.poll(pid)
      assert_received {:linear_read, _states}
      polled = Enum.sort(watched_ids(repo_key))
      assert polled == ["1", "2", "3"]

      # From the records: the same tickets, decided as before, and no Linear read.
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      flush()
      assert {:ok, %{watched: 3, errors: 0}} = Repo.poll(pid)
      refute_received {:linear_read, _states}
      assert Enum.sort(watched_ids(repo_key)) == polled
      assert %{facts: %Facts{phase: :code_review, pr_number: 1}, decision: %{rule: "R27"}} = watch(repo_key, "1")
      assert_received {:read, "https://github.com/acme/app/pull/3", _opts}
    end

    test "a ticket a Director move put in Code Review is watched on the next tick, with no Linear read", %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, with_pr(repo_key, issue("7", "Todo"), 7))
      pid = start_repo!(repo_key)

      assert {:ok, %{watched: 0}} = Repo.poll(pid)

      # The move writes the record first (TP-1217); Linear's board may not show it yet.
      :ok = SymphonyElixir.TicketSignals.record_phase(repo_key, "7", "Code Review")
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert %{stay: :code_review, facts: %Facts{phase: :code_review, pr_number: 7}} = watch(repo_key, "7")
      refute_received {:linear_read, _states}
    end

    test "the confirm read after a delivery reads GitHub only", %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, with_pr(repo_key, issue("1", "Code Review"), 1))
      test_pid = self()
      pid = start_repo!(repo_key, timer: fn message, _delay_ms -> send(test_pid, {:timer, message}) && make_ref() end)
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      flush()

      delivery =
        {:ci,
         %{
           event: "check_suite",
           action: "completed",
           head_sha: "sha-1",
           conclusion: "success",
           completed_at: @now,
           pr_urls: [pr_url(1)],
           merged: false,
           base_ref: "main"
         }}

      Repo.ingest(pid, delivery, "https://github.com/acme/app")
      assert_receive {:timer, :confirm}
      send(pid, :confirm)
      :sys.get_state(pid)

      assert_received {:read, "https://github.com/acme/app/pull/1", _opts}
      refute_received {:linear_read, _states}
    end

    # Ticket 1's PR #1, whose head is red only on `protected paths`, which a person clears, and which
    # changes `WORKFLOW.md`: in Merging, R18 asks about it. Puts the ticket's workspace and the PR's
    # read, and returns the git runner the gate reads the PR with.
    defp protected_paths_head!(repo_key) do
      workspace = Path.join(System.tmp_dir!(), "repo-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)
      run = %{repo_key: repo_key, run_id: "run-1", issue_id: "1", status: "success", started_at: @now}
      :ok = RunStore.put_run(Map.put(run, :workspace_path, workspace))

      check = "protected paths"
      failed = [%{name: check, run_id: "5"}]
      red = %{ci: :red, red_kind: :human_only, past_human_only: :green, failing_check: check, failed_checks: failed}
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), Map.merge(red, %{base_sha: "base-1", pr_node_id: "node-1"}))}})

      # Every commit is there, and the PR changes `WORKFLOW.md` among the protected paths, unless a
      # grant leaves it out.
      fn
        ["diff", "--name-only", "--no-renames", _range, "--" | paths], _cwd -> {Enum.join(Enum.filter(["WORKFLOW.md"], &(&1 in paths)), "\n"), 0}
        _args, _cwd -> {"", 0}
      end
    end

    # The question as the Director reads it: each ask is a Question of its own, whose id the hidden
    # last line names.
    defp question(issue_id) do
      assert_received {:comment, ^issue_id, "## Decision needed: Protected files changed on TP-" <> body}
      String.replace(body, ~r/\n\n<!-- symphony:question \S+ -->\z/, "")
    end

    test "R18's question recommends what it did under poll, from the record's description and the store's rulings, with no Linear read",
         %{repo_key: repo_key} do
      write_workflow_file!(Workflow.workflow_file_path(), pr_review_mode: "polling", ci: %{enabled: true})
      git = protected_paths_head!(repo_key)
      ticket = %{with_pr(repo_key, issue("1", "Merging", description: "Add the hook to `WORKFLOW.md`."), 1) | repo_key: repo_key, updated_at: @now}

      # Polling, the Linear read carries the description, which names the protected path.
      issues!([ticket])
      pid = start_repo!(repo_key, tracker: AskingTracker, git: git)
      assert {:ok, %{errors: 0}} = Repo.poll(pid)
      polled = question("1")
      assert polled =~ "**Allow the change** (recommended)"

      # From the record, as if the watcher had not asked yet: the record's description gives the
      # same question, and no Linear is read.
      ask_again = fn ->
        withdraw_questions(repo_key, "1")
        :ok = RunStore.put_ticket_pr_watch(repo_key, "1", "TP-1", nil)
        flush()
        assert {:ok, %{errors: 0}} = Repo.poll(pid)
        refute_received {:linear_read, _states}
        refute_received {:linear_read_by_id, _ids}
        question("1")
      end

      record_source!(pr_review_mode: "polling", ci: %{enabled: true})
      issues!({:error, :linear_must_not_be_read})
      assert ask_again.() == polled

      # A description that names no protected path recommends dropping the change, as under poll...
      observed!(repo_key, %{ticket | description: "Add the hook."})
      assert ask_again.() =~ "**Drop the change in Rework** (recommended)"

      # ...unless a ruling the store recorded on the ticket names it.
      ruling = SymphonyElixir.Decisions.entry("ruling-c1", ~D[2026-10-16], "Change workflow.md too.", nil, "Change workflow.md too.")
      {:ok, projected} = SymphonyElixir.Decisions.put("Add the hook.", [ruling])
      :ok = SymphonyElixir.Decisions.record("1", [ruling], repo_key: repo_key, description: projected)
      assert ask_again.() == polled

      # Asked, the ticket waits on its hold: the next tick reads no Linear and asks nothing.
      assert {:ok, %{errors: 0}} = Repo.poll(pid)
      refute_received {:linear_read, _states}
      refute_received {:linear_read_by_id, _ids}
      refute_received {:comment, "1", _body}
    end

    test "R18 in Merging: picking Allow grants the PR's protected paths from the store, and the head then lands, with no Linear read",
         %{repo_key: repo_key} do
      record_source!(pr_review_mode: "polling", ci: %{enabled: true})
      issues!({:error, :linear_must_not_be_read})
      git = protected_paths_head!(repo_key)
      observed!(repo_key, with_pr(repo_key, issue("1", "Merging", description: "Ship it."), 1))
      pid = start_repo!(repo_key, tracker: AskingTracker, github: LandingGitHub, git: git)

      assert {:ok, %{errors: 0}} = Repo.poll(pid)
      assert %{} = decision = Questions.deciding({:ticket, repo_key, "1"})
      assert question("1") =~ "**Drop the change in Rework** (recommended)"
      unlocks = SymphonyElixir.PathUnlock.picked_paths(decision, ["Allow the change"])
      assert unlocks == ["WORKFLOW.md"]

      # The person picks Allow: the answer goes into the ticket's store record with its paths, and the
      # hold clears. The record's description, not observed again, never shows it.
      picked = SymphonyElixir.Decisions.entry("request-1", ~D[2026-10-16], decision.title, decision.question, "Allow the change", unlocks)
      {:ok, projected} = SymphonyElixir.Decisions.put("Ship it.", [picked])
      :ok = SymphonyElixir.Decisions.record("1", [picked], repo_key: repo_key, description: projected)
      {:ok, _answered} = Questions.answer({:ticket, repo_key, "1"}, decision.id, "Allow the change")
      assert %{description: "Ship it."} = RunStore.get_ticket_state("1")

      # The head is still red only on that check: the grant covers it, so it reads as green and lands,
      # and nothing is asked again.
      flush()
      assert {:ok, %{errors: 0}} = Repo.poll(pid)
      assert %{facts: %Facts{ci: :green}, decision: %{rule: "R29"}} = watch(repo_key, "1")
      assert_received {:merged, "https://github.com/acme/app/pull/1", "sha-1"}
      # The merge closes the ticket out in the same step (TP-1305).
      assert_received {:moved, "1", "Done"}
      assert %{phase: "Done", phase_owner: :symphony} = RunStore.get_ticket_state("1")
      refute Questions.deciding({:ticket, repo_key, "1"})
      refute_received {:comment, "1", _body}
      refute_received {:linear_read, _states}
      refute_received {:linear_read_by_id, _ids}
    end

    test "the self-heal lane gets the ticket with its record's team and project, with no Linear read", %{repo_key: repo_key} do
      record_source!(pr_review_mode: "polling", ci: %{enabled: true, max_retries: 1})
      issues!({:error, :linear_must_not_be_read})
      team = %{key: "ENG", name: "Engineering"}
      project = %{id: "project-1", name: "App", slug_id: "app-1"}
      observed!(repo_key, with_pr(repo_key, issue("1", "QA", team: team, project: project), 1))

      # Red on `specs` after its one CI Fix run: the red backstop hands the ticket to the self-heal lane.
      failure = %{check: "specs", error: "ERROR: specs failed", head_sha: "sha-1"}
      SymphonyElixir.PrWatchSupport.put_watch!(repo_key, "1", head_sha: "sha-1", attempts: %{PrWatch.Attempts.new() | red: 1, failure: failure})
      red = %{ci: :red, failing_check: "specs", failed_checks: [%{name: "specs", run_id: "5"}]}
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), red)}})
      pid = start_repo!(repo_key, self_heal: FakeSelfHeal)

      assert {:ok, %{errors: 0}} = Repo.poll(pid)
      assert %{decision: %{rule: "R20"}} = watch(repo_key, "1")
      assert_received {:heal, %Issue{id: "1", team: ^team, project: ^project}}
      refute_received {:linear_read, _states}
    end

    test "records that can't be read fail the tick instead of reading as tickets that left", %{repo_key: repo_key} do
      record_source!()
      pid = start_repo!(repo_key, run_store: FailingStore)

      log = capture_log(fn -> assert {:error, :store_down} = Repo.poll(pid) end)
      assert log =~ "PR watch tick failed repo_key=#{repo_key} reason=:store_down"
      refute_received {:linear_read, _states}
    end

    test "with assignee me, the tick waits until a poll learned the viewer, then watches the viewer's tickets", %{repo_key: repo_key} do
      record_source!(linear_tracker(tracker_assignee: "me"))
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, with_pr(repo_key, issue("1", "Code Review", assignee_id: "user-2"), 1))
      observed!(repo_key, with_pr(repo_key, issue("2", "Code Review", assignee_id: "someone-else"), 2))
      SymphonyElixir.PrWatchSupport.put_watch!(repo_key, "1", phase: :code_review)
      pid = start_repo!(repo_key)

      # No record can count as the viewer's yet: the tick fails and keeps what it watched.
      log = capture_log(fn -> assert {:error, :linear_viewer_unknown} = Repo.poll(pid) end)
      assert log =~ "reason=:linear_viewer_unknown"
      assert watched_ids(repo_key) == ["1"]

      graphql_fun = fn query, _variables ->
        if query =~ "SymphonyLinearViewer",
          do: {:ok, %{"data" => %{"viewer" => %{"id" => "user-2"}}}},
          else: {:ok, %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}
      end

      assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun)
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert watched_ids(repo_key) == ["1"]
      refute_received {:linear_read, _states}
    end

    # The watcher has handled every record change sent before this call, and the re-decision they
    # queued: the change queues it as a message to itself, which a second call waits behind.
    defp redecided!(pid) do
      :sys.get_state(pid)
      :sys.get_state(pid)
    end

    defp dispatch_reason(repo_key, issue_id, state) do
      issue = %Issue{id: issue_id, identifier: "TP-#{issue_id}", state: state, repo_key: repo_key}
      PrWatch.dispatch_reason(issue, Config.settings!())
    end

    defp no_reads! do
      refute_received {:read, _pr_url, _opts}
      refute_received {:list_open_pull_requests, _pr_url}
      refute_received {:linear_read, _states}
      refute_received {:linear_read_by_id, _ids}
    end

    test "TP-1223: a move to Code Review re-decides the ticket at once on the read the watcher holds, with no GitHub or Linear read",
         %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, with_pr(repo_key, issue("1", "In Progress"), 1))
      pid = start_repo!(repo_key, follow_records: true)
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert %{facts: %Facts{phase: :in_progress}, read_at: read_at, source: :poll} = watch(repo_key, "1")
      flush()

      # The Director's move writes the record's phase, which announces it: the watcher decides on
      # the PR it read, and the run may start.
      :ok = SymphonyElixir.TicketSignals.record_phase(repo_key, "1", "Code Review")
      redecided!(pid)

      redecided = watch(repo_key, "1")
      assert %{stay: :code_review, facts: %Facts{phase: :code_review, pr_number: 1}} = redecided
      assert %{decision: %{kind: :dispatch}} = redecided
      assert %{read_at: ^read_at, source: :poll} = redecided

      assert dispatch_reason(repo_key, "1", "Code Review") == nil
      no_reads!()
    end

    test "TP-1223: a ticket with no PR is re-decided with nothing to read", %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, issue("2", "In Progress"))
      pid = start_repo!(repo_key, tracker: AskingTracker, follow_records: true)
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      flush()

      # In Rework with no PR, the watcher asks how the ticket continues.
      :ok = SymphonyElixir.TicketSignals.record_phase(repo_key, "2", "Rework")
      redecided!(pid)

      assert %{stay: :rework, facts: %Facts{phase: :rework, pr: :missing}, pr_url: nil} = watch(repo_key, "2")
      assert_received {:comment, "2", "## Decision needed: No pull request on TP-2" <> _body}
      no_reads!()
    end

    test "TP-1223: a ticket the watcher holds no read of has its one PR read, as a confirm read does", %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, with_pr(repo_key, issue("1", "Todo"), 1))
      observed!(repo_key, with_pr(repo_key, issue("2", "Code Review"), 2))
      pid = start_repo!(repo_key, follow_records: true)
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert dispatch_reason(repo_key, "1", "Code Review") == "the PR watcher hasn't read its PR yet"
      flush()

      :ok = SymphonyElixir.TicketSignals.record_phase(repo_key, "1", "Code Review")
      redecided!(pid)

      assert %{facts: %Facts{phase: :code_review}, decision: %{kind: :dispatch}, source: :webhook} = watch(repo_key, "1")
      assert dispatch_reason(repo_key, "1", "Code Review") == nil
      assert_received {:read, "https://github.com/acme/app/pull/1", _opts}
      no_reads!()

      # A delivery about the PR makes the read stale: the next re-decision reads it again.
      completed = %{event: "check_suite", action: "completed", head_sha: "sha-1", conclusion: "success", completed_at: @now}
      delivery = {:ci, Map.merge(completed, %{pr_urls: [pr_url(1)], merged: false, base_ref: "main"})}
      Repo.ingest(pid, delivery, "https://github.com/acme/app")
      {:ok, _pause} = SymphonyElixir.Pauses.set({:ticket, repo_key, "1"}, SymphonyElixir.Pauses.ticket_reason(:dependency, "TP-9"))
      redecided!(pid)

      assert %{facts: %Facts{hold: :blocked}} = watch(repo_key, "1")
      assert_received {:read, "https://github.com/acme/app/pull/1", _opts}
      no_reads!()
    end

    test "TP-1223: an answer that clears a question's hold re-decides the ticket at once, and it proceeds", %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, with_pr(repo_key, issue("1", "Code Review"), 1))
      {:ok, question} = Questions.ask({:ticket, repo_key, "1"}, decision_request("Which base?"), request: true)
      pid = start_repo!(repo_key, follow_records: true)
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert %{facts: %Facts{hold: :question}, decision: %{kind: kind}} = watch(repo_key, "1")
      refute kind == :dispatch
      assert dispatch_reason(repo_key, "1", "Code Review") =~ "the PR watcher ("
      flush()

      {:ok, _answered} = Questions.answer({:ticket, repo_key, "1"}, question.id, "Keep main")
      redecided!(pid)

      assert %{facts: %Facts{hold: :none}, decision: %{kind: :dispatch}} = watch(repo_key, "1")
      assert dispatch_reason(repo_key, "1", "Code Review") == nil
      no_reads!()
    end

    test "TP-1223: a change of a title or a priority, another repo's change and any change under dispatch from the poll re-decide nothing",
         %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      ticket = %{with_pr(repo_key, issue("1", "Code Review"), 1) | repo_key: repo_key, updated_at: @now}
      observed!(repo_key, ticket)
      # The clock moves after the tick, so a re-decision would write a decision made later.
      clock = :counters.new(1, [])
      pid = start_repo!(repo_key, follow_records: true, now: fn -> DateTime.add(@now, :counters.get(clock, 1), :second) end)
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      before = watch(repo_key, "1")
      :counters.put(clock, 1, 60)
      flush()

      # A webhook delivery's title and priority change is announced with those fields only.
      renamed = %{ticket | title: "Renamed", priority: 1, updated_at: DateTime.add(@now, 60)}
      {:ok, :updated} = TicketObservation.observe(repo_key, renamed, source: :webhook)
      send(pid, {:ticket_record, "other-repo", "1", :changed, [:phase]})
      redecided!(pid)
      assert watch(repo_key, "1") == before

      write_workflow_file!(Workflow.workflow_file_path())
      Cache.clear()
      :ok = SymphonyElixir.TicketSignals.record_phase(repo_key, "1", "QA")
      redecided!(pid)

      assert watch(repo_key, "1") == before
      no_reads!()
    end

    test "TP-1163: a review's approval on a green PR: the run's end has the PR read at once, with no timed tick, and QA's dispatch announced",
         %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, with_pr(repo_key, issue("1", "Code Review"), 1))
      :ok = RunStore.put_run(%{repo_key: repo_key, run_id: "run-1", issue_id: "1", status: "running"})
      # A timed tick an hour away: only the read the run's end asks for can answer in this test.
      pid = start_repo!(repo_key, auto: true, interval_ms: 3_600_000, follow_records: true)
      assert_receive {:read, _pr_url, _opts}
      :sys.get_state(pid)
      :ok = ObservabilityPubSub.subscribe_ticket_records()

      # The reviewer approves while its run still works: the move alone leaves R9.
      :ok = SymphonyElixir.TicketSignals.record_phase(repo_key, "1", "QA")
      redecided!(pid)
      assert %{stay: :qa, decision: %{rule: "R9"}} = watch(repo_key, "1")
      assert dispatch_reason(repo_key, "1", "QA") =~ "the PR watcher (R9)"
      flush()

      :ok = RunStore.update_run(repo_key, "run-1", %{status: "completed"})
      assert Repo.poll_now(pid) == :ok

      assert_receive {:ticket_record, ^repo_key, "1", :changed, [:pr_watch]}, 1_000
      assert_received {:read, "https://github.com/acme/app/pull/1", _opts}
      assert %{stay: :qa, decision: %{kind: :dispatch}} = watch(repo_key, "1")
      assert dispatch_reason(repo_key, "1", "QA") == nil
    end

    test "TP-1163: a rework run that pushed and ended has the PR read at once, and the reviewer then waits only on CI", %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, with_pr(repo_key, issue("1", "QA"), 1))
      :ok = RunStore.put_run(%{repo_key: repo_key, run_id: "run-1", issue_id: "1", status: "running"})
      test_pid = self()
      pid = start_repo!(repo_key, timer: reporting_timer(test_pid))
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      assert %{decision: %{rule: "R9"}} = watch(repo_key, "1")
      flush()

      # The run's end is written, then the read is asked for: it comes with no delay, and CI is what it finds.
      :ok = RunStore.update_run(repo_key, "run-1", %{status: "stopped"})
      reads!(%{pr_url(1) => {:ok, read_of(pr_url(1), %{ci: :pending})}})
      assert Repo.read_ticket(pid, "1") == :ok
      assert_receive {:timer, :confirm, 0}
      send(pid, :confirm)
      :sys.get_state(pid)

      assert_received {:read, "https://github.com/acme/app/pull/1", _opts}
      refute match?(%{decision: %{rule: "R9"}}, watch(repo_key, "1"))
      assert dispatch_reason(repo_key, "1", "QA") =~ "Checks"
    end

    test "TP-1163: a read Symphony asks for costs nothing for a ticket the watcher doesn't follow", %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      test_pid = self()
      pid = start_repo!(repo_key, timer: reporting_timer(test_pid))

      assert Repo.read_ticket(pid, "never-seen") == :ok
      :sys.get_state(pid)
      refute_received {:timer, :confirm, _delay_ms}
      no_reads!()

      observed!(repo_key, with_pr(repo_key, issue("2", "Backlog"), 2))
      assert Repo.read_ticket(pid, "2") == :ok
      :sys.get_state(pid)
      refute_received {:timer, :confirm, _delay_ms}
      no_reads!()
    end

    test "TP-1163: under dispatch from the poll, a hold cleared has the PR read at once; a phase announced before Linear moved waits for the move's own read",
         %{repo_key: repo_key} do
      write_workflow_file!(Workflow.workflow_file_path())
      Cache.clear()
      issues!([repo_key |> with_pr(issue("1", "Code Review"), 1)])
      test_pid = self()
      pid = start_repo!(repo_key, follow_records: true, timer: reporting_timer(test_pid))
      assert {:ok, %{watched: 1}} = Repo.poll(pid)
      flush()

      :ok = SymphonyElixir.TicketSignals.record_phase(repo_key, "1", "QA")
      :sys.get_state(pid)
      refute_received {:timer, :confirm, _delay_ms}

      {:ok, _pause} = SymphonyElixir.Pauses.set({:ticket, repo_key, "1"}, SymphonyElixir.Pauses.ticket_reason(:dependency, "TP-9"))
      assert_receive {:timer, :confirm, 0}
    end

    test "TP-1223: a burst of changes to one ticket is one re-decision; a change after it is another", %{repo_key: repo_key} do
      record_source!()
      issues!({:error, :linear_must_not_be_read})
      observed!(repo_key, with_pr(repo_key, issue("1", "Code Review"), 1))
      # A read that fails leaves the watcher holding none, so each re-decision reads the PR once.
      reads!(%{pr_url(1) => {:error, :boom}})
      pid = start_repo!(repo_key, follow_records: true)

      capture_log(fn ->
        :ok = :sys.suspend(pid)
        {:ok, _pause} = SymphonyElixir.Pauses.set({:ticket, repo_key, "1"}, SymphonyElixir.Pauses.ticket_reason(:dependency, "TP-9"))
        {:ok, nil} = SymphonyElixir.Pauses.clear({:ticket, repo_key, "1"})
        :ok = SymphonyElixir.TicketSignals.record_phase(repo_key, "1", "QA")
        :ok = :sys.resume(pid)
        redecided!(pid)

        assert_received {:read, "https://github.com/acme/app/pull/1", _opts}
        refute_received {:read, _pr_url, _opts}

        :ok = SymphonyElixir.TicketSignals.record_phase(repo_key, "1", "Code Review")
        redecided!(pid)
        assert_received {:read, "https://github.com/acme/app/pull/1", _opts}
        refute_received {:read, _pr_url, _opts}
      end)
    end

    test "TP-1223: R18's question on a re-decision reads the record's description, with no GitHub or Linear read", %{repo_key: repo_key} do
      record_source!(pr_review_mode: "polling", ci: %{enabled: true})
      issues!({:error, :linear_must_not_be_read})
      git = protected_paths_head!(repo_key)
      observed!(repo_key, with_pr(repo_key, issue("1", "Merging", description: "Add the hook to `WORKFLOW.md`."), 1))
      pid = start_repo!(repo_key, tracker: AskingTracker, git: git, follow_records: true)

      assert {:ok, %{errors: 0}} = Repo.poll(pid)
      asked = question("1")
      assert asked =~ "**Allow the change** (recommended)"
      flush()

      # As if the watcher had not asked yet: the hold's clear re-decides, and the description the
      # record holds gives the same question.
      :ok = :sys.suspend(pid)
      withdraw_questions(repo_key, "1")
      :ok = RunStore.put_ticket_pr_watch(repo_key, "1", "TP-1", nil)
      :ok = :sys.resume(pid)
      redecided!(pid)

      assert question("1") == asked
      no_reads!()
    end
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

  # A decision request a rule asks, written to the standard.
  defp decision_request(title) do
    %{
      title: title,
      question: title,
      why: "The pull request merges somewhere else.",
      if_unanswered: "The ticket waits.",
      options: [%{label: "Keep main", effect: "It merges into main.", recommended: true}, %{label: "Accept it", effect: "It merges there."}],
      recommendation_reason: "Main is where it belongs."
    }
  end

  # Withdraws every open question on the ticket, as if none was asked yet.
  defp withdraw_questions(repo_key, issue_id) do
    ticket = {:ticket, repo_key, issue_id}
    for question <- Questions.open(ticket), do: {:ok, _withdrawn} = Questions.withdraw(ticket, question.id, "The test asks again.")
    :ok
  end
end
