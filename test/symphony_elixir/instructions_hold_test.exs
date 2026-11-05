defmodule SymphonyElixir.InstructionsHoldTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{BuildInfo, InstructionsHold, Pauses}

  @repo_key "default"
  @build_sha "e44298c8123456789abcdef0123456789abcdef0"
  @main_sha "d20a8a83123456789abcdef0123456789abcdef0"
  @newer_sha "65b63d4d123456789abcdef0123456789abcdef0"
  @build %{version: "0.0.1.838", sha: @build_sha, repo: "https://github.com/acme/symphony"}
  @setter %{kind: :rule, name: "Instructions update hold"}

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> :ok = RunStore.clear() end)
  end

  describe "check/2" do
    test "is behind when the base branch changed a renderer file since the build's commit" do
      compare = fn "acme/symphony", @build_sha, "main" -> ahead(["lib/symphony_elixir/prompt_builder.ex", "README.md"]) end

      assert {:ok, behind} = InstructionsHold.check(@repo_key, opts(compare: compare))

      assert behind == %{
               commit: @main_sha,
               commits: ["aaaaaaa", @main_sha],
               total_commits: 2,
               files: ["lib/symphony_elixir/prompt_builder.ex"],
               branch: "main"
             }
    end

    test "a file under a renderer folder counts, on a diverged build and the repo's base branch" do
      {:ok, result} = ahead(["lib/symphony_elixir/playbook/assembly.ex"])
      compare = fn _repo, _sha, "trunk" -> {:ok, %{result | status: "diverged"}} end

      assert {:ok, %{files: ["lib/symphony_elixir/playbook/assembly.ex"], branch: "trunk"}} =
               InstructionsHold.check(@repo_key, opts(compare: compare, base_branch: fn @repo_key -> "trunk" end))
    end

    test "is current when no renderer file changed, the build is not behind, or nothing is new" do
      for result <- [
            ahead(["README.md", "lib/symphony_elixir/workflow_preview.ex"]),
            {:ok, %{status: "behind", files: ["lib/symphony_elixir/workflow.ex"], commits: [], total_commits: 0}},
            {:ok, %{status: "identical", files: [], commits: [], total_commits: 0}},
            {:ok, %{status: "ahead", files: ["lib/symphony_elixir/workflow.ex"], commits: [], total_commits: 0}}
          ] do
        assert InstructionsHold.check(@repo_key, opts(compare: fn _repo, _sha, _branch -> result end)) == {:ok, nil}
      end
    end

    test "compares nothing for another repository, a build without a sha, or no repo key" do
      no_compare = fn _repo, _sha, _branch -> flunk("nothing to compare") end

      assert InstructionsHold.check(@repo_key, opts(compare: no_compare, github_repo: fn _key -> "acme/web-app" end)) == {:ok, nil}
      assert InstructionsHold.check(@repo_key, opts(compare: no_compare, github_repo: fn _key -> nil end)) == {:ok, nil}
      assert InstructionsHold.check(@repo_key, opts(compare: no_compare, build: %{@build | sha: nil})) == {:ok, nil}
      assert InstructionsHold.check(nil, opts(compare: no_compare)) == {:ok, nil}
    end

    test "reads the repo's GitHub repository and base branch from the configuration" do
      # The test repo's checkout is not acme/symphony, so nothing is compared.
      assert InstructionsHold.check(@repo_key, build: @build, compare: fn _repo, _sha, _branch -> flunk("not the build's repository") end) == {:ok, nil}
      assert InstructionsHold.check("unknown", build: @build) == {:ok, nil}

      # The base branch is the configured repo's, `main` for a repo the configuration lacks.
      compare = fn _repo, _sha, branch -> send(self(), {:branch, branch}) && {:ok, %{status: "identical", files: [], commits: [], total_commits: 0}} end
      github_repo = fn _key -> "acme/symphony" end
      configured = Config.repos() |> elem(1) |> Enum.find(&(&1.name == @repo_key))

      assert InstructionsHold.check(@repo_key, build: @build, github_repo: github_repo, compare: compare) == {:ok, nil}
      assert_received {:branch, branch}
      assert branch == (configured.base_branch || "main")

      assert InstructionsHold.check("unknown", build: @build, github_repo: github_repo, compare: compare) == {:ok, nil}
      assert_received {:branch, "main"}
    end

    test "a failed compare is an error" do
      assert InstructionsHold.check(@repo_key, opts(compare: fn _repo, _sha, _branch -> {:error, :github_down} end)) == {:error, :github_down}
    end
  end

  describe "resolve/3" do
    test "holds every polled ticket, skip-update-hold or not, until the build is current" do
      labelled = ticket("a", labels: [SymphonyElixir.UpdateHold.skip_label()])
      plain = ticket("b", state: "Rework")

      log = capture_log(fn -> assert {:ok, %{commit: @main_sha}} = resolve([labelled, plain], ahead_on_renderer()) end)
      assert log =~ "Holding for an app update: issue_id=a"

      for id <- ["a", "b"] do
        assert [%{kind: :build, waits_on: %{commit: @main_sha}, set_by: @setter, text: text}] = InstructionsHold.reasons(@repo_key, id)
        assert text == "Holding for the build of d20a8a8: the instructions on main need it"
      end

      # Still behind on the next poll, with a newer commit on main: the reason stays as it is.
      newer = fn _repo, _sha, _branch -> {:ok, %{status: "ahead", files: ["lib/symphony_elixir/workflow.ex"], commits: [@main_sha, @newer_sha], total_commits: 2}} end
      assert {:ok, %{commit: @newer_sha}} = resolve([labelled], newer)
      assert [%{waits_on: %{commit: @main_sha}}] = InstructionsHold.reasons(@repo_key, "a")

      # The app updates: the next poll clears every reason.
      log = capture_log(fn -> assert {:ok, nil} = resolve([labelled, plain], fn _repo, _sha, _branch -> {:ok, %{status: "identical", files: [], commits: [], total_commits: 0}} end) end)
      assert log =~ "Released from the instructions update hold: issue_id=a"
      assert Pauses.get({:ticket, @repo_key, "a"}) == {:ok, nil}
      assert Pauses.get({:ticket, @repo_key, "b"}) == {:ok, nil}
    end

    test "a build that has the waited commit but is still behind waits on the newer head" do
      issue = ticket("a")
      resolve([issue], ahead_on_renderer())

      still_behind = fn _repo, _sha, _branch -> {:ok, %{status: "ahead", files: ["lib/symphony_elixir/prompt_builder.ex"], commits: [@newer_sha], total_commits: 1}} end
      resolve([issue], still_behind)

      assert [%{waits_on: %{commit: @newer_sha}}] = InstructionsHold.reasons(@repo_key, "a")
    end

    test "a cut-short commit list keeps the reason it can't answer for" do
      issue = ticket("a")
      resolve([issue], ahead_on_renderer())

      cut_short = fn _repo, _sha, _branch -> {:ok, %{status: "ahead", files: ["lib/symphony_elixir/prompt_builder.ex"], commits: [@newer_sha], total_commits: 300}} end
      resolve([issue], cut_short)

      assert [%{waits_on: %{commit: @main_sha}}] = InstructionsHold.reasons(@repo_key, "a")
    end

    test "a failed compare changes nothing, and no tickets compare nothing" do
      issue = ticket("a")
      resolve([issue], ahead_on_renderer())

      assert {:error, :github_down} = resolve([issue], fn _repo, _sha, _branch -> {:error, :github_down} end)
      assert [_held] = InstructionsHold.reasons(@repo_key, "a")

      assert {:ok, nil} = resolve([], fn _repo, _sha, _branch -> flunk("nothing to compare") end)
      assert {:ok, nil} = resolve([%Issue{id: nil}], fn _repo, _sha, _branch -> flunk("nothing to compare") end)
    end

    test "a current build leaves a ticket without the hold untouched" do
      assert {:ok, nil} = resolve([ticket("a")], fn _repo, _sha, _branch -> {:ok, %{status: "identical", files: [], commits: [], total_commits: 0}} end)
      assert Pauses.get({:ticket, @repo_key, "a"}) == {:ok, nil}
    end
  end

  describe "hold/3, reasons and lines" do
    test "holds a ticket once, and names the build once its release run is known" do
      behind = %{commit: @main_sha, commits: [@main_sha], total_commits: 1, files: [], branch: "main"}

      capture_log(fn -> assert :ok = InstructionsHold.hold(@repo_key, %{id: "a", identifier: "TP-1396"}, behind) end)
      assert :ok = InstructionsHold.hold(@repo_key, %{id: "a", identifier: "TP-1396"}, behind)
      assert [reason] = InstructionsHold.reasons(@repo_key, "a")

      :ok = RunStore.put_github_updates({:release_build, @main_sha}, %{sha: @main_sha, state: :running, number: 839})
      version = BuildInfo.release_version(839)
      assert InstructionsHold.lines([reason]) == ["Holding for the v#{version} build: the instructions on main need it"]
      assert InstructionsHold.line(@main_sha) == "Holding for the v#{version} build: the instructions on main need it"
    end

    test "a reason the store refuses, or no repo key, is an error" do
      behind = %{commit: "not-a-sha", commits: [], total_commits: 0, files: [], branch: "main"}

      capture_log(fn -> assert {:error, _reason} = InstructionsHold.hold(@repo_key, %{id: "a", identifier: "TP-1"}, behind) end)
      assert {:error, :no_ticket} = InstructionsHold.hold(nil, %{id: "a"}, behind)
      assert InstructionsHold.reasons(nil, "a") == []
    end

    test "only its own reasons count" do
      refute InstructionsHold.reason?(%{kind: :build, waits_on: %{commit: @main_sha}, set_by: %{kind: :rule, name: "App update hold"}})
      refute InstructionsHold.reason?(%{kind: :build, waits_on: %{pull_request: 12}, set_by: @setter})
      assert InstructionsHold.reason?(%{kind: :build, waits_on: %{commit: @main_sha}, set_by: @setter})
      assert InstructionsHold.renderer_paths() |> Enum.member?("lib/symphony_elixir/prompt_builder.ex")
    end

    test "a pause reason waiting on a commit has a default line" do
      assert {:ok, %{reasons: [%{text: "Waiting for a Symphony build that includes d20a8a8"}]}} =
               Pauses.set({:ticket, @repo_key, "c"}, %{kind: :build, waits_on: %{commit: @main_sha}})
    end
  end

  describe "the dispatch gate" do
    test "a held ticket is not dispatched and says which build it waits on, until the hold lifts" do
      issue = %Issue{ticket("held") | identifier: "TP-1396", title: "QA report", labels: ["skip-update-hold"], state: "Todo"}
      resolve([issue], ahead_on_renderer())

      state = Orchestrator.put_blocked_for_test(orchestrator_state(), [issue])
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      line = "Holding for the build of d20a8a8: the instructions on main need it"

      assert state.blocked == [
               %{issue_id: "held", identifier: "TP-1396", title: "QA report", state: "Todo", kind: :app_update, reason: line, build_line: nil, blockers: []}
             ]

      skipped = Orchestrator.dispatch_chosen_issues_for_test([issue], state)
      assert skipped.dispatch_skipped["held"].reason == line

      resolve([issue], fn _repo, _sha, _branch -> {:ok, %{status: "identical", files: [], commits: [], total_commits: 0}} end)
      state = Orchestrator.put_blocked_for_test(orchestrator_state(), [issue])
      assert state.blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end
  end

  describe "a run whose prompt fails to render" do
    test "exits as the hold when the build is behind main" do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: "Step: {{ run.no_such_variable }}")
      behind = %{commit: @main_sha, commits: [@main_sha], total_commits: 1, files: [], branch: "main"}
      check = fn @repo_key -> {:ok, behind} end

      capture_log(fn ->
        assert {:instructions_behind, %{commit: @main_sha, error: error}} =
                 catch_exit(AgentRunner.build_first_turn_prompt(render_issue(), repo_key: @repo_key, instructions_check: check))

        assert error =~ "Undefined variable"
      end)
    end

    test "fails as before on a current build, a failed check, or another error" do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: "Step: {{ run.no_such_variable }}")

      for result <- [{:ok, nil}, {:error, :github_down}] do
        assert_raise Solid.RenderError, fn ->
          AgentRunner.build_first_turn_prompt(render_issue(), repo_key: @repo_key, instructions_check: fn _key -> result end)
        end
      end

      write_workflow_file!(Workflow.workflow_file_path(), prompt: ~s(Step: {% render "no_such_partial" %}))

      assert_raise RuntimeError, ~r/template_render_error/, fn ->
        AgentRunner.build_first_turn_prompt(render_issue(), instructions_check: fn _key -> {:ok, nil} end)
      end

      assert_raise RuntimeError, ~r/workflow_unavailable/, fn ->
        AgentRunner.build_first_turn_prompt(render_issue(), workflow: {:error, :boom}, instructions_check: fn _key -> flunk("not a render error") end)
      end
    end
  end

  describe "the orchestrator" do
    test "holds a run that exits as the hold, with no retry scheduled" do
      {pid, ref, issue_id} = start_orchestrator_with_running(:HoldOrchestrator, "issue-render-held")
      behind = %{commit: @main_sha, commits: [@main_sha], total_commits: 1, files: [], branch: "main", error: "1 error(s) found while rendering"}

      capture_log(fn ->
        send(pid, {:DOWN, ref, :process, self(), {:instructions_behind, behind}})
        Process.sleep(50)
      end)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.retry_attempts, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert [%{waits_on: %{commit: @main_sha}}] = InstructionsHold.reasons(@repo_key, issue_id)
    end

    test "a hold the store refuses leaves the run a plain failure, retried" do
      {pid, ref, issue_id} = start_orchestrator_with_running(:RefusedHoldOrchestrator, "issue-render-refused")
      behind = %{commit: "not-a-sha", commits: [], total_commits: 0, files: [], branch: "main"}

      capture_log(fn ->
        send(pid, {:DOWN, ref, :process, self(), {:instructions_behind, behind}})
        Process.sleep(50)
      end)

      state = :sys.get_state(pid)
      assert %{error: "agent exited: Holding for the build of not-a-s: the instructions on main need it (the instructions did not render)"} = state.retry_attempts[issue_id]
    end
  end

  defp start_orchestrator_with_running(name, issue_id) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    ref = make_ref()
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    running_entry = %{
      pid: self(),
      ref: ref,
      repo_key: @repo_key,
      identifier: "TP-1396",
      issue: %Issue{id: issue_id, identifier: "TP-1396", state: "In Progress", repo_key: @repo_key},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    {pid, ref, issue_id}
  end

  defp render_issue do
    %Issue{id: "render", identifier: "TP-1396", title: "Render", description: "", state: "In Progress", url: "https://example.org/TP-1396", labels: []}
  end

  defp resolve(issues, compare), do: InstructionsHold.resolve(issues, @repo_key, opts(compare: compare))

  defp opts(overrides) do
    Keyword.merge([build: @build, github_repo: fn @repo_key -> "acme/symphony" end, base_branch: fn @repo_key -> nil end], overrides)
  end

  defp ahead(files), do: {:ok, %{status: "ahead", files: files, commits: ["aaaaaaa", @main_sha], total_commits: 2}}

  defp ahead_on_renderer, do: fn _repo, _sha, _branch -> ahead(["lib/symphony_elixir/prompt_builder.ex"]) end

  defp ticket(id, fields \\ []) do
    struct(%Issue{id: id, identifier: "TP-" <> id, title: "Ticket", state: "Todo", labels: []}, fields)
  end

  defp orchestrator_state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
