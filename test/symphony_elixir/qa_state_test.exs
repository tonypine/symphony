defmodule SymphonyElixir.QaStateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{QaState, TicketChecks, TicketEvents, TicketPlan}

  @repo_key "qa-state-repo"
  @issue_id "qa-state-issue"

  # The test's own small seed and fixtures, never the repository's: a seed file with content, an
  # empty one, a directory of empty files and a fixture directory.
  @base_files %{
    "priv/qa_seed/demo/seed.json" => ~s({"tickets": 1}),
    "priv/qa_seed/demo/empty.json" => "",
    "priv/qa_seed/demo/blank/.gitkeep" => "",
    "macos/Tests/Fixtures/demo/state/state.json" => ~s({"running": true})
  }

  @live %{source: "live", page: "Home", window: %{width: 1440, height: 900}, appearance: "dark"}

  setup do
    :ok = RunStore.clear()
    :ok
  end

  defp issue(attrs \\ %{}), do: struct!(%Issue{id: @issue_id, identifier: "QAS-1", repo_key: @repo_key}, attrs)

  defp qa_check(id, extra) do
    Map.merge(%{id: id, kind: "qa", statement: "The panel\nshows #{id}.", proof: "qa", action: "Open it", expect: "It shows"}, extra)
  end

  defp plan!(checks) do
    plan = %{
      reason: "Grooming",
      by: "grooming",
      shape: "single",
      layers: ["logic"],
      summary: "Check the seed.",
      text: "Check the seed.",
      # A first plan numbers its checks in order, so the QA checks keep the ids the test gives them
      # and the outcome check comes last.
      checks: checks ++ [%{id: "c#{length(checks) + 1}", kind: "outcome", statement: "It works.", proof: "test"}],
      size: %{tokens: 1_000, runs: 1}
    }

    {:ok, _event} = TicketPlan.write(@repo_key, @issue_id, plan)
    :ok
  end

  defp walked(path, holds), do: %{path: path, holds: holds}
  defp fixture(dir), do: %{source: "fixture", fixture: dir, page: "Home", window: %{width: 1440, height: 900}, appearance: "light"}

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-c", "user.email=t@example.com", "-c", "user.name=t" | args], cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit!(dir, files, message) do
    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "--allow-empty", "-m", message])
    git!(dir, ["rev-parse", "HEAD"])
  end

  # A checkout whose base branch (`origin/main`) holds the small seed and fixtures, and whose head
  # adds `changes` on top: the pull request.
  defp workspace!(changes \\ %{}, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "qa-state-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    git!(dir, ["init", "-q"])
    base = commit!(dir, @base_files, "base")
    if Keyword.get(opts, :origin, true), do: git!(dir, ["update-ref", "refs/remotes/origin/main", base])
    head = commit!(dir, changes, "change")
    # An untracked file is not what the head holds.
    File.write!(Path.join(dir, "priv/qa_seed/demo/untracked.json"), "{}")
    {dir, head}
  end

  defp step_events, do: Enum.filter(RunStore.list_ticket_events(@issue_id, []), &(&1.type in ["step.started", "step.completed"]))
  defp findings, do: @issue_id |> RunStore.list_ticket_events([]) |> TicketEvents.findings()

  describe "judge/4" do
    test "a ticket with no plan, or no QA check QA still walks, has nothing to judge" do
      {dir, head} = workspace!()
      assert QaState.judge(issue(), dir, head) == :none

      plan!([qa_check("c1", %{walked_on: [walked("priv/qa_seed/demo/missing.json", "present")]})])
      {:ok, _proof} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c1", by: "test", test: "test/panel_test.exs"}, actor: {:agent, "run-1", "implementation"})
      assert QaState.judge(issue(), dir, head) == :none
    end

    test "a present path with content, and a fixture directory the head holds, are held" do
      {dir, head} = workspace!()

      plan!([
        qa_check("c1", %{walked_on: [walked("priv/qa_seed/demo/seed.json", "present"), walked("priv/qa_seed/demo/", "present")]}),
        qa_check("c2", %{setting: fixture("macos/Tests/Fixtures/demo/state")}),
        # A fixture setting that a walked-on entry names already is judged once.
        qa_check("c3", %{setting: fixture("macos/Tests/Fixtures/demo/state/"), walked_on: [walked("macos/Tests/Fixtures/demo/state", "present")]})
      ])

      assert {:ok, [c1, c2, c3]} = QaState.judge(issue(), dir, head, repo_key: @repo_key)

      assert %{check_id: "c1", status: "held", paths: [%{path: "priv/qa_seed/demo/seed.json", holds: "present", held: true}, %{path: "priv/qa_seed/demo", held: true}]} = c1
      assert %{check_id: "c2", status: "held", paths: [%{path: "macos/Tests/Fixtures/demo/state", holds: "fixture", held: true}]} = c2
      assert %{check_id: "c3", status: "held", paths: [%{path: "macos/Tests/Fixtures/demo/state", holds: "present"}]} = c3
    end

    test "an absent path, an empty file, a directory of empty files and an untracked file are missing" do
      {dir, head} = workspace!()

      plan!([
        qa_check("c1", %{
          walked_on: [
            walked("priv/qa_seed/demo/split.json", "present"),
            walked("priv/qa_seed/demo/empty.json", "present"),
            walked("priv/qa_seed/demo/blank", "present"),
            walked("priv/qa_seed/demo/untracked.json", "present")
          ]
        })
      ])

      assert {:ok, [%{check_id: "c1", status: "missing", paths: paths}]} = QaState.judge(issue(), dir, head)

      assert Enum.map(paths, &{&1.path, &1.held, &1.why}) == [
               {"priv/qa_seed/demo/split.json", false, "absent"},
               {"priv/qa_seed/demo/empty.json", false, "empty"},
               {"priv/qa_seed/demo/blank", false, "empty"},
               {"priv/qa_seed/demo/untracked.json", false, "absent"}
             ]
    end

    test "an added path is held only when the pull request changes it" do
      {dir, head} = workspace!(%{"priv/qa_seed/demo/split/ticket.json" => ~s({"split": true})})

      plan!([
        qa_check("c1", %{walked_on: [walked("priv/qa_seed/demo/split", "added"), walked("priv/qa_seed/demo/split/ticket.json", "added")]}),
        qa_check("c2", %{walked_on: [walked("priv/qa_seed/demo/seed.json", "added")]})
      ])

      assert {:ok, [c1, c2]} = QaState.judge(issue(), dir, head, repo_key: @repo_key)
      assert %{status: "held", paths: [%{held: true}, %{held: true}]} = c1
      assert %{status: "missing", paths: [%{path: "priv/qa_seed/demo/seed.json", holds: "added", held: false, why: "unchanged"}]} = c2
    end

    test "a fixture setting whose directory the head does not hold is missing" do
      {dir, head} = workspace!()
      plan!([qa_check("c1", %{setting: fixture("macos/Tests/Fixtures/demo/split")})])

      assert {:ok, [%{status: "missing", paths: [%{path: "macos/Tests/Fixtures/demo/split", holds: "fixture", held: false, why: "absent"}]}]} =
               QaState.judge(issue(), dir, head)
    end

    test "a QA check that names no state, or only the live server, is not judged" do
      {dir, head} = workspace!()
      plan!([qa_check("c1", %{}), qa_check("c2", %{setting: @live}), qa_check("c3", %{setting: Map.delete(fixture("x"), :fixture)})])

      assert {:ok, results} = QaState.judge(issue(), dir, head)
      assert Enum.map(results, &{&1.check_id, &1.status, &1.paths}) == [{"c1", "unjudged", []}, {"c2", "unjudged", []}, {"c3", "unjudged", []}]
    end

    test "a head git cannot read is an error, and so is a base branch it cannot find for an added path" do
      plan!([qa_check("c1", %{walked_on: [walked("priv/qa_seed/demo/seed.json", "added")]})])
      not_git = Path.join(System.tmp_dir!(), "qa-state-none-#{System.unique_integer([:positive])}")
      File.mkdir_p!(not_git)
      on_exit(fn -> File.rm_rf(not_git) end)

      assert {:error, {:git_failed, _status, _output}} = QaState.judge(issue(), not_git, "abc123")

      {dir, head} = workspace!(%{}, origin: false)
      assert {:error, {:git_failed, _status, _output}} = QaState.judge(issue(), dir, head)
    end
  end

  describe "gate/4" do
    test "missing state ends the step failed on the head, with a finding per check, and sends the ticket to Rework" do
      {dir, head} = workspace!()

      plan!([
        qa_check("c1", %{walked_on: [walked("priv/qa_seed/demo/seed.json", "present"), walked("priv/qa_seed/demo/split.json", "present")]}),
        qa_check("c2", %{walked_on: [walked("priv/qa_seed/demo/seed.json", "added")], setting: fixture("macos/Tests/Fixtures/demo/split")}),
        qa_check("c3", %{walked_on: [walked("priv/qa_seed/demo/seed.json", "present")]}),
        qa_check("c4", %{})
      ])

      capture_log(fn -> send(self(), {:gate, QaState.gate(issue(), dir, head, repo_key: @repo_key, run_id: "run-cr-1")}) end)
      assert_received {:gate, {:rework, reason}}
      assert reason =~ "do not hold the state QA check(s) c1, c2 are walked on"
      assert reason =~ "priv/qa_seed/demo/split.json (the plan says the seed or fixtures hold it already; the head does not hold it)"

      assert [started, completed] = step_events()
      assert %{type: "step.started", run_id: "run-cr-1", head_sha: ^head, actor: %{kind: :machine}, payload: started_payload} = started
      assert %{step_id: "qa_state", mode: "machine", command: "symphony qa-state"} = started_payload

      assert %{type: "step.completed", run_id: "run-cr-1", head_sha: ^head, payload: completed_payload} = completed
      assert %{outcome: "failed", returns_to: "code", qa_state: state} = completed_payload

      assert [
               %{
                 check_id: "c1",
                 status: "missing",
                 paths: [%{held: true}, %{path: "priv/qa_seed/demo/split.json", holds: "present", held: false, why: "absent"}]
               },
               %{check_id: "c2", status: "missing", paths: [%{holds: "added", why: "unchanged"}, %{holds: "fixture", why: "absent"}]},
               %{check_id: "c3", status: "held"},
               %{check_id: "c4", status: "unjudged", paths: []}
             ] = state

      # The rework run reads them with the open findings: each names the check and each missing path.
      assert [%{state: :open, finding: f1}, %{state: :open, finding: f2}] = findings()
      assert %{actor: %{kind: :machine}, head_sha: ^head, payload: %{class: "qa_state", description: d1}} = f1

      assert d1 ==
               "QA check c1 (The panel shows c1.) is walked on state the pull request's head does not hold: priv/qa_seed/demo/split.json (the plan says the seed or fixtures hold it already; the head does not hold it). Add it to the QA seed or the fixtures in this pull request, or correct the paths the plan names."

      assert f2.payload.description =~
               "priv/qa_seed/demo/seed.json (the plan says this change adds it; the pull request does not change it); macos/Tests/Fixtures/demo/split (the check's fixture setting; the head does not hold it)"
    end

    test "state the head holds ends the step passed, and a head it passed on is not checked again" do
      {dir, head} = workspace!(%{"priv/qa_seed/demo/split.json" => "{}"})
      plan!([qa_check("c1", %{walked_on: [walked("priv/qa_seed/demo/split.json", "added")]}), qa_check("c2", %{})])

      assert QaState.gate(issue(), dir, head, repo_key: @repo_key, run_id: "run-cr-1") == :go
      assert [_started, %{head_sha: ^head, payload: %{outcome: "passed", qa_state: state}}] = step_events()
      assert [%{check_id: "c1", status: "held"}, %{check_id: "c2", status: "unjudged"}] = state
      assert findings() == []
      assert QaState.passed_on?(@issue_id, head)

      assert QaState.gate(issue(), dir, head, repo_key: @repo_key, run_id: "run-qa-1") == :go
      assert length(step_events()) == 2
    end

    test "a head that cannot be read goes on to QA, the step skipped with why" do
      plan!([qa_check("c1", %{walked_on: [walked("priv/qa_seed/demo/split.json", "present")]})])
      not_git = Path.join(System.tmp_dir!(), "qa-state-none-#{System.unique_integer([:positive])}")
      File.mkdir_p!(not_git)
      on_exit(fn -> File.rm_rf(not_git) end)

      capture_log(fn -> assert QaState.gate(issue(), not_git, "abc123", repo_key: @repo_key) == :go end)
      assert [_started, %{payload: %{outcome: "skipped", reason: "the head could not be read: git exited " <> _rest}}] = step_events()

      log = capture_log(fn -> assert QaState.gate(issue(%{identifier: nil}), not_git, nil, []) == :go end)
      assert log =~ "QA state check for #{@issue_id} head=nil did not run: the head of the pull request could not be read; QA runs"
      assert [_, _, _, %{head_sha: nil, payload: %{outcome: "skipped", reason: "the head of the pull request could not be read; QA runs"}}] = step_events()
    end

    test "a ticket with no QA check to walk gets no step, and a ticket with no repository records none" do
      {dir, head} = workspace!()
      assert QaState.gate(issue(), dir, head, repo_key: @repo_key) == :go
      assert step_events() == []

      plan!([qa_check("c1", %{walked_on: [walked("priv/qa_seed/demo/split.json", "present")]})])
      capture_log(fn -> assert {:rework, _reason} = QaState.gate(issue(%{repo_key: nil}), dir, head, []) end)
      assert step_events() == []
    end
  end
end
