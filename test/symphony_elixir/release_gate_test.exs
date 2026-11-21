defmodule SymphonyElixir.ReleaseGateTest do
  @moduledoc """
  The release gate's failure: one Urgent fix ticket with what an agent needs to start, the next
  failure added to it while it is open, a new one once it is closed, and the file the workflow and
  Symphony must agree on.
  """

  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{BuildInfo, ReleaseGate}
  alias SymphonyElixir.Config.SystemSchema

  @repo "acme/symphony"
  @sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
  @run_id "41086214847"
  @url "https://github.com/acme/symphony/actions/runs/41086214847"

  defmodule Fixer do
    @moduledoc false
    def create(attrs, opts), do: reply({:create, attrs, opts})
    def attach(identifier, body, _opts), do: reply({:attach, identifier, body})

    defp reply(message) do
      send(Process.get(:release_gate_test), message)
      Process.get({:release_gate_reply, elem(message, 0)}, default(elem(message, 0)))
    end

    defp default(:create), do: {:ok, %{id: "issue-1520", identifier: "TP-1520", url: "https://linear.app/t/TP-1520"}}
    defp default(:attach), do: :ok
  end

  defmodule Tracker do
    @moduledoc false
    def fetch_issue_by_identifier(identifier) do
      case Process.get({:release_gate_issue, identifier}) do
        nil -> {:error, :not_found}
        state -> {:ok, %{id: "id-" <> identifier, identifier: identifier, state: state}}
      end
    end

    def update_issue_state(issue_id, state) do
      send(Process.get(:release_gate_test), {:moved, issue_id, state})
      Process.get(:release_gate_move_reply, :ok)
    end
  end

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> :ok = RunStore.clear() end)
    Process.put(:release_gate_test, self())
    refresh = fn repo_key -> send(Process.get(:release_gate_test), {:refresh, repo_key}) end
    opts = [fixer: Fixer, tracker: Tracker, gh_runner: gh(), repos: {:ok, repos()}, terminal_states: ["Done", "Canceled"]]
    {:ok, opts: opts ++ [refresh: refresh]}
  end

  # A config whose primary repo is Cycle, with Symphony's own repository configured beside it.
  defp repos do
    [
      %SystemSchema.Repo{name: "cycle", default: true, team: "MOT", workspace: %SystemSchema.Repo.Workspace{github: "acme/cycle"}},
      %SystemSchema.Repo{name: "symphony", team: "TP", workspace: %SystemSchema.Repo.Workspace{github: "Acme/Symphony"}}
    ]
  end

  # `gh` as GitHub answers the failed log of the run and the commit.
  defp gh(overrides \\ %{}) do
    fn
      ["run", "view", @run_id, "--log-failed" | _rest], _opts ->
        Map.get(
          overrides,
          :log,
          {"release gate\tTest the update\t2026-11-13T16:00:01.0Z ok [build]\nrelease gate\tTest the update\t2026-11-13T16:00:02.0Z 1 failed: rollback ```\nrelease gate\tTest the update\t2026-11-13T16:00:03.0Z ##[error]Process completed with exit code 1.\n",
           0}
        )

      ["api", "repos/" <> _path, "--jq", _filter], _opts ->
        Map.get(overrides, :commit, {Jason.encode!(%{message: "TP-1507 Shared Row (#914)\n\nbody", url: "https://github.com/acme/symphony/commit/9f54098", files: ["macos/Sources/A.swift", 7]}), 0})
    end
  end

  defp put_build(sha, fields),
    do: :ok = RunStore.put_github_updates({:release_build, sha}, Map.merge(%{sha: sha, repo: @repo, number: 950, state: :built}, fields))

  defp build(overrides \\ %{}) do
    Map.merge(
      %{
        sha: @sha,
        repo: @repo,
        repo_key: nil,
        url: @url,
        run_id: @run_id,
        number: 950,
        attempt: 1,
        failure: %{job: "release gate", step: "Test the update"}
      },
      overrides
    )
  end

  test "the gate's job, and which failures are the gate's" do
    assert ReleaseGate.job() == "release gate"
    assert ReleaseGate.gate_failure?(build())
    assert ReleaseGate.gate_failure?(build(%{failure: %{job: "release gate / mac checks", step: "Run tests"}}))
    # The gate's jobs (TP-1591): the scripts on Linux and the two Mac jobs, one per runner.
    for job <- ["release gate / mac checks (scripts)", "release gate / mac checks (app)", "release gate / mac checks (tests)"],
        do: assert(ReleaseGate.gate_failure?(build(%{failure: %{job: job, step: "Run tests"}})))

    refute ReleaseGate.gate_failure?(build(%{failure: %{job: "release", step: "Build Symphony.app"}}))
    refute ReleaseGate.gate_failure?(build(%{failure: nil}))
    refute ReleaseGate.gate_failure?(nil)
    assert ReleaseGate.failed(%{}, []) == {:error, :invalid_build}
  end

  test "the release workflow has the job Symphony reads" do
    workflow = File.read!(Path.join(File.cwd!(), ".github/workflows/release.yml"))
    assert workflow =~ ~r/^    name: #{Regex.escape(ReleaseGate.job())}$/m
  end

  test "a failed gate files one Urgent ticket in Symphony's repository with the failure", %{opts: opts} do
    log = capture_log(fn -> assert ReleaseGate.failed(build(), opts) == {:filed, "TP-1520"} end)
    assert log =~ "filed TP-1520"

    assert_received {:create, attrs, create_opts}
    assert create_opts[:priority] == 1
    assert %{scope: "symphony", repo_key: "symphony", component: "release_gate"} = attrs
    assert attrs.title == "Release gate failed on main: Test the update (v#{BuildInfo.release_version(950)} build not published)"

    for part <- [
          "was not published",
          "* Run: #{@url}\n",
          "* Commit: `9f54098b` TP-1507 Shared Row (#914) ([commit](https://github.com/acme/symphony/commit/9f54098))",
          "* Job “release gate”, step “Test the update”",
          "* First error: `1 failed: rollback '''`",
          "```text\n1 failed: rollback '''\n##[error]Process completed with exit code 1.\n```",
          "## What the commit changed\n\n* `macos/Sources/A.swift`",
          "* The step “Test the update” passes on this ticket's pull request.",
          "never skipped, loosened or removed"
        ] do
      assert attrs.description =~ part
    end

    assert RunStore.get_github_updates({:release_gate_fix, "symphony"}) ==
             %{identifier: "TP-1520", sha: @sha, step: "Test the update", number: 950, attempt: 1, red: true}
  end

  test "while that ticket is open, the next failure is added to it; once it is closed, a new one is filed", %{opts: opts} do
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), opts) end)
    assert_received {:create, _attrs, _opts}

    Process.put({:release_gate_issue, "TP-1520"}, "In Progress")
    later = build(%{sha: "1111111122222222333333334444444455555555", attempt: 2})
    log = capture_log(fn -> assert ReleaseGate.failed(later, opts) == {:attached, "TP-1520"} end)
    assert log =~ "added it to TP-1520"
    assert_received {:attach, "TP-1520", body}
    assert body =~ "failed again on `main`"
    assert body =~ "(attempt 2)"
    assert body =~ "* Commit: `11111111`"
    refute_received {:create, _attrs, _opts}

    Process.put({:release_gate_reply, :attach}, {:error, :linear_down})
    assert capture_log(fn -> assert ReleaseGate.failed(later, opts) == {:error, :linear_down} end) =~ "Could not add"

    Process.put({:release_gate_issue, "TP-1520"}, " done ")
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(later, opts) end)
    assert_received {:create, _attrs, _opts}

    Process.put({:release_gate_issue, "TP-1520"}, nil)
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(later, opts) end)

    # A ticket whose state Linear does not say is not written on either.
    Process.put({:release_gate_issue, "TP-1520"}, :unknown)
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(later, opts) end)
  end

  test "what GitHub cannot say is left out, and the ticket is filed all the same", %{opts: opts} do
    opts = Keyword.put(opts, :gh_runner, gh(%{log: {"HTTP 502", 1}, commit: {"not json", 0}}))
    unknown = build(%{url: nil, number: nil, failure: %{job: "release gate", step: nil}})
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(unknown, opts) end)
    assert_received {:create, attrs, _opts}
    assert attrs.title == "Release gate failed on main: the job “release gate” (release build not published)"
    assert attrs.description =~ "* Run: not known\n* Commit: `9f54098b`\n* Job “release gate”, GitHub does not say which step\n\n## Goal"
    assert attrs.description =~ "* The job `release gate` passes on this ticket's pull request."
    refute attrs.description =~ "## The end of the failed step's log"
    refute attrs.description =~ "## What the commit changed"

    no_run = build(%{run_id: nil})
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(no_run, Keyword.put(opts, :gh_runner, gh(%{commit: {"HTTP 404", 1}}))) end)

    silent = Keyword.put(opts, :gh_runner, gh(%{log: {"", 0}, commit: {Jason.encode!(%{message: "subject only", files: []}), 0}}))
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), silent) end)
    assert_received {:create, %{description: no_run_description}, _opts}
    refute no_run_description =~ "## The end of the failed step's log"
    assert_received {:create, attrs, _opts}
    assert attrs.description =~ "* Commit: `9f54098b` subject only\n"
  end

  test "a commit with many files names the first forty", %{opts: opts} do
    files = for n <- 1..43, do: "lib/file_#{n}.ex"
    opts = Keyword.put(opts, :gh_runner, gh(%{commit: {Jason.encode!(%{message: "big", url: nil, files: files}), 0}}))
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), opts) end)
    assert_received {:create, attrs, _opts}
    assert attrs.description =~ "* `lib/file_40.ex`\n* and 3 more"
    refute attrs.description =~ "file_41"
  end

  test "a ticket that cannot be filed, or recorded, is said in the log", %{opts: opts} do
    Process.put({:release_gate_reply, :create}, {:error, {:self_heal_team_unknown, "symphony"}})
    assert capture_log(fn -> assert ReleaseGate.failed(build(), opts) == {:error, {:self_heal_team_unknown, "symphony"}} end) =~ "Could not file"

    Process.put({:release_gate_reply, :create}, {:ok, %{}})
    assert capture_log(fn -> assert ReleaseGate.failed(build(), opts) == {:error, :fix_ticket_not_filed} end) =~ "Could not file"
    assert RunStore.get_github_updates({:release_gate_fix, "symphony"}) == nil

    Process.delete({:release_gate_reply, :create})

    defmodule DownStore do
      @moduledoc false
      def get_github_updates(_key), do: nil
      def put_github_updates(_key, _value), do: {:error, :disk_full}
    end

    log = capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), Keyword.put(opts, :run_store, DownStore)) end)
    assert log =~ "Could not record the release gate's fix ticket TP-1520"
  end

  test "the ticket is filed under the configured repo whose repository sent the delivery, never the primary one", %{opts: opts} do
    # The build's own repo key (the primary's, from a held ticket) does not decide either.
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(%{repo_key: "cycle"}), opts) end)
    assert_received {:create, %{scope: "symphony", repo_key: "symphony"}, _opts}

    Process.put({:release_gate_issue, "TP-1520"}, "In Progress")

    # Symphony's ticket is open, and a failure from Cycle's repository files Cycle's own ticket.
    Process.put({:release_gate_reply, :create}, {:ok, %{identifier: "MOT-104"}})
    cycle = build(%{repo: "acme/cycle"})
    capture_log(fn -> assert {:filed, "MOT-104"} = ReleaseGate.failed(cycle, opts) end)
    assert_received {:create, %{scope: "cycle", repo_key: "cycle"}, _opts}
    refute_received {:attach, _identifier, _body}
    assert RunStore.get_github_updates({:release_gate_fix, "cycle"}).identifier == "MOT-104"
    assert RunStore.get_github_updates({:release_gate_fix, "symphony"}).identifier == "TP-1520"

    # Each repo's next failure is added to its own open ticket.
    Process.put({:release_gate_issue, "MOT-104"}, "Todo")
    capture_log(fn -> assert {:attached, "TP-1520"} = ReleaseGate.failed(build(%{attempt: 2}), opts) end)
    assert_received {:attach, "TP-1520", _body}
    capture_log(fn -> assert {:attached, "MOT-104"} = ReleaseGate.failed(%{cycle | attempt: 2}, opts) end)
    assert_received {:attach, "MOT-104", _body}
    refute_received {:create, _attrs, _opts}
  end

  test "a delivery from a repository no configured repo has files nothing and names it", %{opts: opts} do
    for {build, repos} <- [
          {build(%{repo: "acme/other"}), {:ok, repos()}},
          {build(%{repo: nil}), {:ok, repos()}},
          {build(), {:error, :missing_symphony_config}}
        ] do
      {result, log} = with_log(fn -> ReleaseGate.failed(build, Keyword.put(opts, :repos, repos)) end)
      assert result == {:error, {:unknown_repo, build.repo}}
      assert log =~ "no configured repo is its repository #{inspect(build.repo)}; filed no fix ticket"
    end

    refute_received {:create, _attrs, _opts}
    refute_received {:attach, _identifier, _body}
  end

  test "without injected repos the configured ones are read, and the test config has no acme/symphony", %{opts: opts} do
    opts = Keyword.delete(opts, :repos)
    assert capture_log(fn -> assert {:error, {:unknown_repo, @repo}} = ReleaseGate.failed(build(), opts) end) =~ "filed no fix ticket"
  end

  describe "the fix ticket is the one thing a red gate lets run (TP-1528)" do
    test "a fix ticket Linear left in Backlog is moved to Todo at once, and on the next failure", %{opts: opts} do
      Process.put({:release_gate_issue, "TP-1520"}, "Backlog")
      log = capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), opts) end)
      assert_received {:moved, "id-TP-1520", "Todo"}
      assert log =~ "TP-1520 was in Backlog; moved it to Todo so it is dispatched"

      # In Todo already, it is left where it is.
      Process.put({:release_gate_issue, "TP-1520"}, "Todo")
      capture_log(fn -> assert {:attached, "TP-1520"} = ReleaseGate.failed(build(%{attempt: 2}), opts) end)
      refute_received {:moved, _id, _state}

      # In Triage on a later failure, and a move Linear refuses is said in the log.
      Process.put({:release_gate_issue, "TP-1520"}, "Triage")
      Process.put(:release_gate_move_reply, {:error, :linear_down})
      log = capture_log(fn -> assert {:attached, "TP-1520"} = ReleaseGate.failed(build(%{attempt: 3}), opts) end)
      assert_received {:moved, "id-TP-1520", "Todo"}
      assert log =~ "Could not move the release gate's fix ticket TP-1520 to Todo: :linear_down"
    end

    test "while the gate is red every ticket of the repo but the fix ticket is held, and no update hold waits on it", %{opts: opts} do
      assert ReleaseGate.hold_reason("symphony", "TP-1") == nil
      refute ReleaseGate.fix_ticket?("symphony", "TP-1520")

      capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), opts) end)

      assert ReleaseGate.hold_reason("symphony", "TP-1") == "Holding while the release gate on main is red: TP-1520 is fixing it"
      assert ReleaseGate.hold_reason("symphony", "TP-1520") == nil
      assert ReleaseGate.hold_reason("cycle", "MOT-1") == nil
      assert ReleaseGate.hold_reason(nil, "TP-1") == nil
      assert ReleaseGate.fix_ticket?("symphony", "TP-1520")
      refute ReleaseGate.fix_ticket?("symphony", "TP-1")
      refute ReleaseGate.fix_ticket?(nil, "TP-1520")
    end

    test "a later build that passes the gate lifts the hold and tells the open fix ticket what it still asks for", %{opts: opts} do
      capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), opts) end)
      Process.put({:release_gate_issue, "TP-1520"}, "In Progress")

      # The failed attempt of the failed commit's own run, an older build, and another repository's say nothing.
      assert ReleaseGate.passed(build(%{number: 951}), opts) == :ok
      assert ReleaseGate.passed(build(%{sha: "0000000011111111222222223333333344444444", number: 949}), opts) == :ok
      assert ReleaseGate.passed(build(%{sha: "0000000011111111222222223333333344444444", repo: "acme/other"}), opts) == :ok
      assert ReleaseGate.passed(%{}, opts) == :ok
      refute_received {:attach, _identifier, _body}

      passing = build(%{sha: "6f280e7e11111111222222223333333344444444", number: 955})
      log = capture_log(fn -> assert ReleaseGate.passed(passing, opts) == :green end)
      assert log =~ "The release gate passed again on 6f280e7e"
      assert ReleaseGate.hold_reason("symphony", "TP-1") == nil
      assert_received {:refresh, "symphony"}
      assert ReleaseGate.fix_ticket?("symphony", "TP-1520")

      assert_received {:attach, "TP-1520", body}
      assert body =~ "passed again on `main` with the v#{BuildInfo.release_version(955)} build (commit `6f280e7e`)"
      assert body =~ "The step “Test the update” failed on `9f54098b` and passed here with no change made for it."
      assert body =~ "A check that fails at random is a defect in the check"

      # Green already: the next build says nothing.
      assert ReleaseGate.passed(%{passing | number: 956}, opts) == :ok
      refute_received {:attach, _identifier, _body}
    end

    test "a passing build tells nothing to a fix ticket that already landed, and a comment Linear refuses is logged", %{opts: opts} do
      unknown_step = build(%{failure: %{job: "release gate", step: nil}, number: nil})
      capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(unknown_step, opts) end)
      Process.put({:release_gate_issue, "TP-1520"}, "Done")
      later = build(%{sha: "6f280e7e11111111222222223333333344444444", number: nil})
      capture_log(fn -> assert ReleaseGate.passed(later, opts) == :green end)
      refute_received {:attach, _identifier, _body}

      :ok = RunStore.put_github_updates({:release_gate_fix, "symphony"}, %{identifier: "TP-1520", red: true})
      Process.put({:release_gate_issue, "TP-1520"}, "Todo")
      Process.put({:release_gate_reply, :attach}, {:error, :linear_down})
      log = capture_log(fn -> assert ReleaseGate.passed(later, opts) == :green end)
      assert_received {:attach, "TP-1520", body}
      assert body =~ "The job “release gate” failed and passed here"
      assert body =~ "release build (commit `6f280e7e`)"
      assert log =~ "Could not tell TP-1520 that the release gate passed again: :linear_down"
    end

    test "each poll moves a fix ticket out of Backlog, and a terminal one lifts the hold", %{opts: opts} do
      # Nothing red: nothing is read.
      assert ReleaseGate.reconcile([], "symphony", opts) == :ok
      assert ReleaseGate.reconcile([], nil, opts) == :ok
      refute_received {:moved, _id, _state}

      capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), opts) end)

      # Polled among the active tickets: it is dispatchable as it is.
      Process.put({:release_gate_issue, "TP-1520"}, "Backlog")
      assert ReleaseGate.reconcile([%{identifier: "TP-1520"}], "symphony", opts) == :ok
      refute_received {:moved, _id, _state}

      # Not polled: read by identifier and moved to Todo from Backlog.
      capture_log(fn -> assert ReleaseGate.reconcile([%{identifier: "TP-1"}], "symphony", opts) == :ok end)
      assert_received {:moved, "id-TP-1520", "Todo"}

      # A read that fails changes nothing.
      Process.put({:release_gate_issue, "TP-1520"}, nil)
      assert ReleaseGate.reconcile([], "symphony", opts) == :ok
      assert ReleaseGate.hold_reason("symphony", "TP-1") =~ "TP-1520 is fixing it"

      # Terminal: the hold lifts.
      Process.put({:release_gate_issue, "TP-1520"}, "Canceled")
      log = capture_log(fn -> assert ReleaseGate.reconcile([], "symphony", opts) == :ok end)
      assert log =~ "fix ticket TP-1520 is Canceled; the gate no longer holds the tickets of symphony"
      assert ReleaseGate.hold_reason("symphony", "TP-1") == nil
    end

    test "a rerun that passes on the commit that failed lifts the hold at once, the fix ticket still open (TP-1583)", %{opts: opts} do
      capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), opts) end)
      Process.put({:release_gate_issue, "TP-1520"}, "In Progress")
      assert ReleaseGate.hold_reason("symphony", "TP-1") =~ "TP-1520 is fixing it"

      # Attempt 2 of the same run, on the same commit and run number, passes.
      rerun = build(%{attempt: 2})
      log = capture_log(fn -> assert ReleaseGate.passed(rerun, opts) == :green end)
      assert log =~ "The release gate passed again on 9f54098b"
      assert_received {:refresh, "symphony"}

      # Every ticket dispatches again; the fix ticket stays the fix ticket, open, neither moved nor closed.
      assert ReleaseGate.hold_reason("symphony", "TP-1") == nil
      assert ReleaseGate.hold_reason("symphony", "TP-1520") == nil
      assert ReleaseGate.fix_ticket?("symphony", "TP-1520")
      refute_received {:moved, _id, _state}
      assert_received {:attach, "TP-1520", body}
      assert body =~ "The step “Test the update” failed on `9f54098b` and passed when the same run was run again with no change made for it."

      # A poll with the fix ticket open among the active tickets changes nothing more.
      assert ReleaseGate.reconcile([%{identifier: "TP-1520"}], "symphony", opts) == :ok
      refute_received {:refresh, _repo_key}
      refute_received {:moved, _id, _state}

      # A fix record kept before attempts were kept: any pass of the failed commit is a rerun.
      :ok = RunStore.put_github_updates({:release_gate_fix, "symphony"}, %{identifier: "TP-1520", sha: @sha, number: 950, red: true})
      capture_log(fn -> assert ReleaseGate.passed(build(), opts) == :green end)
    end

    test "a poll turns the gate green from the builds kept, when the delivery was missed (TP-1583)", %{opts: opts} do
      capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), opts) end)
      Process.put({:release_gate_issue, "TP-1520"}, "In Progress")

      # Nothing built since the failure: the poll reads the fix ticket as before and the gate stays red.
      put_build(@sha, %{state: :failed, attempt: 1})
      :ok = RunStore.put_github_updates({:release_build, :latest}, %{sha: "older", number: 949})
      put_build("older", %{state: :built, number: 949, attempt: 1})
      put_build("other", %{state: :built, number: 960, attempt: 1, repo: "acme/other"})
      assert ReleaseGate.reconcile([], "symphony", opts) == :ok
      assert ReleaseGate.hold_reason("symphony", "TP-1") =~ "TP-1520 is fixing it"

      # Another repository's newer build says nothing about this gate.
      :ok = RunStore.put_github_updates({:release_build, :latest}, %{sha: "other", number: 960})
      assert ReleaseGate.reconcile([], "symphony", opts) == :ok
      assert ReleaseGate.hold_reason("symphony", "TP-1") =~ "TP-1520 is fixing it"
      refute_received {:refresh, _repo_key}

      # The failed commit's run, rerun and published: green at the poll, with a dispatch pass asked for.
      put_build(@sha, %{state: :built, attempt: 2})
      log = capture_log(fn -> assert ReleaseGate.reconcile([%{identifier: "TP-1"}], "symphony", opts) == :ok end)
      assert log =~ "The release gate passed again on 9f54098b"
      assert ReleaseGate.hold_reason("symphony", "TP-1") == nil
      assert ReleaseGate.fix_ticket?("symphony", "TP-1520")
      assert_received {:refresh, "symphony"}
      assert_received {:attach, "TP-1520", _body}
      refute_received {:moved, _id, _state}

      # The newest merge's build, later than the failure, turns it green too.
      :ok = RunStore.put_github_updates({:release_gate_fix, "symphony"}, %{identifier: "TP-1520", red: true, number: 950, attempt: 1})
      put_build("newer", %{state: :built, number: 955, attempt: 1})
      :ok = RunStore.put_github_updates({:release_build, :latest}, %{sha: "newer", number: 955})
      capture_log(fn -> assert ReleaseGate.reconcile([], "symphony", opts) == :ok end)
      assert ReleaseGate.hold_reason("symphony", "TP-1") == nil
      assert_received {:refresh, "symphony"}
    end

    test "red_bases lists a red gate with the tickets it holds, until it is green (TP-1583)", %{opts: opts} do
      skipped = [
        %{identifier: "TP-2", repo_key: "symphony", rule: :release_gate},
        %{identifier: "TP-1", repo_key: nil, rule: :release_gate},
        %{identifier: nil, issue_id: "issue-3", repo_key: "symphony", rule: :release_gate},
        %{identifier: "TP-4", repo_key: "symphony", rule: :priority},
        %{identifier: "MOT-1", repo_key: "cycle", rule: :release_gate}
      ]

      assert ReleaseGate.red_bases(skipped, opts) == []

      capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), opts) end)
      assert ReleaseGate.red_bases(skipped, opts) == [%{base: "main", check: "release gate", issue_identifiers: ["TP-1", "TP-2", "issue-3"]}]
      assert ReleaseGate.red_bases(nil, opts) == [%{base: "main", check: "release gate", issue_identifiers: []}]
      assert ReleaseGate.red_bases(skipped, repos: {:error, :no_config}) == []

      # A failure reported with no attempt keeps none.
      capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(%{attempt: nil}), opts) end)
      assert %{attempt: nil, red: true} = RunStore.get_github_updates({:release_gate_fix, "symphony"})

      Process.put({:release_gate_issue, "TP-1520"}, "In Progress")
      capture_log(fn -> assert ReleaseGate.passed(build(%{attempt: 2}), opts) == :green end)
      assert ReleaseGate.red_bases(skipped, opts) == []
    end
  end
end
