defmodule SymphonyElixir.ReleaseGateTest do
  @moduledoc """
  The release gate's failure: one Urgent fix ticket with what an agent needs to start, the next
  failure added to it while it is open, a new one once it is closed, and the file the workflow and
  Symphony must agree on.
  """

  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{BuildInfo, ReleaseGate}

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
        state -> {:ok, %{identifier: identifier, state: state}}
      end
    end
  end

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> :ok = RunStore.clear() end)
    Process.put(:release_gate_test, self())
    {:ok, opts: [fixer: Fixer, tracker: Tracker, gh_runner: gh(), symphony_repo_key: "symphony", terminal_states: ["Done", "Canceled"]]}
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

    assert RunStore.get_github_updates({:release_gate, :fix}) == %{identifier: "TP-1520", sha: @sha, step: "Test the update"}
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

    no_run = build(%{run_id: nil, repo: nil})
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(no_run, Keyword.put(opts, :gh_runner, gh(%{commit: {"HTTP 404", 1}}))) end)

    silent = Keyword.put(opts, :gh_runner, gh(%{log: {"", 0}, commit: {Jason.encode!(%{message: "subject only", files: []}), 0}}))
    capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), silent) end)
    assert_received {:create, _no_run, _opts}
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
    assert RunStore.get_github_updates({:release_gate, :fix}) == nil

    Process.delete({:release_gate_reply, :create})

    defmodule DownStore do
      @moduledoc false
      def get_github_updates(_key), do: nil
      def put_github_updates(_key, _value), do: {:error, :disk_full}
    end

    log = capture_log(fn -> assert {:filed, "TP-1520"} = ReleaseGate.failed(build(), Keyword.put(opts, :run_store, DownStore)) end)
    assert log =~ "Could not record the release gate's fix ticket TP-1520"
  end

  test "the scope defaults to the build's repository key, then the configured one", %{opts: opts} do
    opts = Keyword.delete(opts, :symphony_repo_key)
    capture_log(fn -> assert {:filed, _id} = ReleaseGate.failed(build(%{repo_key: "own"}), opts) end)
    assert_received {:create, %{scope: "own"}, _opts}
  end
end
