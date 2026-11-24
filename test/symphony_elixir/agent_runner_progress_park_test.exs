defmodule SymphonyElixir.AgentRunnerProgressParkTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.AgentRunnerProgressSupport

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.IdlePark
  alias SymphonyElixir.Inbox.FromRecord
  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.PrWatchSupport
  alias SymphonyElixir.Questions
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.TicketState

  @pr_url "https://github.com/example/repo/pull/337"

  setup do
    Application.put_env(:symphony_elixir, :progress_agent_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-rework", checks: []}})
    RunStore.delete_ticket_state("issue-progress")

    on_exit(fn ->
      RunStore.delete_ticket_state("issue-progress")

      for key <- [
            :progress_agent_recipient,
            :progress_agent_turns,
            :progress_pr_head_result,
            :progress_api_unreachable,
            :progress_turn_hook,
            :progress_turn_extra,
            :memory_tracker_update_issue_state_result,
            :memory_tracker_create_comment_result
          ] do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    :ok
  end

  describe "a parked ticket (TP-1326)" do
    test "asks its question in its phase, held until a person answers it or its PR changes" do
      run_issue!("Rework", heads: ["sha-same"], pr_url: nil, max_turns: 5)

      assert [%{title: "TP-337 is paused in Rework: its last 2 turns changed nothing", options: [%{label: "Run it again"} | _]} = question] =
               Questions.open({:ticket, "default", "issue-progress"})

      assert {:ok, %{reasons: reasons}} = Pauses.get({:ticket, "default", "issue-progress"})
      assert %{waits_on: %{question_id: id}} = Enum.find(reasons, &(&1.kind == :question))
      assert id == question.id

      assert %{waits_on: %{condition: "idle_park"}, releasable: true, text: "No progress: the last 2 turns in Rework made no new commit and no state change"} =
               Enum.find(reasons, &(&1.kind == :environment))

      record = TicketState.normalize(RunStore.get_ticket_state("issue-progress"))
      refute record.phase == "Backlog"
      assert %{kind: :action} = Item.from_question(record, question)
    end

    test "is paused on a reason Unblock releases when its question can't be asked" do
      # An identifier the question's plain-words check refuses.
      issue = %Issue{id: "issue-progress", identifier: "`TP-337`", state: "In Progress", repo_key: "default"}
      fetcher = fn _ids -> {:ok, [issue]} end

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, issue_state_fetcher: fetcher) end)

      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}

      assert {:ok, %{reasons: [%{kind: :environment, waits_on: %{condition: "idle_park"}, releasable: true}]}} =
               Pauses.get({:ticket, "default", "issue-progress"})

      assert Questions.open({:ticket, "default", "issue-progress"}) == []
      assert log =~ "Failed to ask the hold's question"
    end

    test "pushes its unpushed commits first, and parks whatever the push says" do
      test_pid = self()

      for {result, logged} <- [
            {{:pushed, "auto/TP-337"}, "Pushed issue_id=issue-progress issue_identifier=TP-337's unpushed commits to origin auto/TP-337 before parking it"},
            {{:error, :origin_mismatch}, "they stay in its workspace reason=:origin_mismatch"},
            {:nothing, "Parking"}
          ] do
        next_run()
        pusher = fn workspace, nil, _source_repo -> send(test_pid, {:pushed_from, workspace}) && result end

        opts = [heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: [workspace_pusher: pusher]]
        log = capture_log(fn -> run_issue!("In Progress", opts) end)

        assert_received {:pushed_from, workspace}
        assert workspace =~ "TP-337"
        refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        assert log =~ logged
      end
    end
  end

  describe "a park from each run kind that can idle out (TP-1336)" do
    @red_park_checks [%{name: "coverage (3/4)", status: "COMPLETED", conclusion: "FAILURE"}]

    test "leaves the record in its phase with its question and its pause, from every run kind" do
      for {kind, state, setup, run_opts} <- [
            {:implementation, "In Progress", fn -> :ok end, pr_url: nil},
            {:implementation_with_pr, "In Progress", fn -> :ok end, []},
            {:rework, "Rework", fn -> :ok end, pr_url: nil},
            {:ci_fix, "CI Fix", &red_ci_failure/0, repos: designed_repos()},
            {:merge_conflict, "In Progress", &unresolved_conflict/0, []}
          ] do
        next_run()
        withdraw_open_questions()
        since = DateTime.utc_now()
        :ok = setup.()
        :ok = put_record_phase(state)

        capture_log(fn -> run_issue!(state, [heads: ["sha-same"], max_turns: 5] ++ run_opts) end)

        refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue where it is" <> _note}
        assert_parked_on_record(state, kind, since)
      end
    end

    test "a parked CI Fix run's question is in the Inbox, and Unblock resumes it in CI Fix" do
      :ok = red_ci_failure()
      capture_log(fn -> run_issue!("CI Fix", heads: ["sha-same"], max_turns: 5, repos: designed_repos()) end)

      [question] = Questions.open({:ticket, "default", "issue-progress"})
      record = TicketState.normalize(RunStore.get_ticket_state("issue-progress"))
      assert %{kind: :action} = Item.from_question(record, question)

      server = :"park_unblock_#{System.unique_integer([:positive])}"
      start_supervised!({SymphonyElixir.DirectorMoves, name: server})
      held = %Issue{id: "issue-progress", identifier: "TP-337", title: "Leave Rework", state: "CI Fix", repo_key: "default", labels: []}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [held])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

      assert {:ok, %{move: "unblock"}} = SymphonyElixir.DirectorMoves.move(:unblock, "TP-337", %{}, server: server)

      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      assert {:ok, nil} = Pauses.get({:ticket, "default", "issue-progress"})
      assert %{state: :answered} = Questions.find({:ticket, "default", "issue-progress"}, question.id)
    end

    test "a run stopped mid-park leaves the park to finish: the hold and the note" do
      # A person can stop the run mid-park. A slow Linear note gives the stop time to land.
      :ok = red_ci_failure()
      :ok = put_record_phase("CI Fix")
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_sleep_ms, 300)
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()
      test_pid = self()

      {runner, ref} =
        spawn_monitor(fn ->
          capture_log(fn -> run_issue!("CI Fix", heads: ["sha-same"], max_turns: 5, repos: designed_repos()) end)
          send(test_pid, :runner_finished)
        end)

      assert_receive {:ticket_record, "default", "issue-progress", :changed, [:pause]}, 5_000
      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^runner, :killed}

      assert_receive {:memory_tracker_comment, "issue-progress", "Symphony parked this issue where it is" <> _note}, 5_000
      refute_received :runner_finished
      assert_parked_on_record("CI Fix", :ci_fix, ~U[2000-01-01 00:00:00Z])
    end

    # The question an earlier park asked, which a person's Unblock would have answered.
    defp withdraw_open_questions do
      ticket = {:ticket, "default", "issue-progress"}
      for %{id: id} <- Questions.open(ticket), do: {:ok, _withdrawn} = Questions.withdraw(ticket, id, "The next park asks again.")
      {:ok, nil} = Pauses.clear_reasons(ticket, fn _reason -> true end)
    end

    defp red_ci_failure do
      :ok = put_pending_ci_failure(approved: false)
      red_head = %{commit_sha: "sha-same", checks: @red_park_checks}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, red_head})
    end

    defp unresolved_conflict do
      :ok = put_pending_conflict(approved: true, head_sha: "sha-same")
      conflicting_head = %{commit_sha: "sha-same", mergeable: "CONFLICTING", checks: []}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, conflicting_head})
    end

    # The phase a read of the ticket writes on its record before a run starts: the park must leave it.
    defp put_record_phase(state) do
      record = RunStore.get_ticket_state("issue-progress") || TicketState.new("default", "issue-progress")
      record |> TicketState.put_phase(state) |> RunStore.put_ticket_state()
    end

    defp assert_parked_on_record(from_state, kind, since) do
      ticket = {:ticket, "default", "issue-progress"}
      record = TicketState.normalize(RunStore.get_ticket_state("issue-progress"))
      assert record.phase == from_state, "#{kind}: the record is in #{inspect(record.phase)}"

      title = "TP-337 is paused in #{from_state}: its last 2 turns changed nothing"
      assert [%{title: ^title} = question] = Questions.open(ticket)
      assert {:ok, %{reasons: reasons}} = Pauses.get(ticket)
      assert %{waits_on: %{question_id: id}} = Enum.find(reasons, &(&1.kind == :question))
      assert id == question.id

      events = "issue-progress" |> SymphonyElixir.TicketEvents.query(limit: :all) |> Enum.filter(&(DateTime.compare(&1.at, since) != :lt))
      refute Enum.any?(events, &(&1.type == "phase.entered" and &1.payload[:to] == "Backlog"))
      assert [_asked] = Enum.filter(events, &(&1.type == "question.asked"))

      # Unblock answers it, and the Inbox lists it.
      assert Questions.held(ticket).id == question.id
      snapshot = %{running: [], watching: [%{issue_id: "issue-progress", state: from_state}]}

      assert [%{kind: :action, ask: ^title}] =
               RunStore.list_all_ticket_states() |> FromRecord.items(snapshot) |> Enum.filter(&(&1.issue_id == "issue-progress"))
    end
  end

  describe "a turn that waited on its own background command (TP-1570)" do
    test "does not count toward the turns that changed nothing, so the run is not parked for it" do
      wait = %{outcome: :ended, waited_ms: 720_000}
      Application.put_env(:symphony_elixir, :progress_turn_extra, %{background_wait: wait})
      tree = fn _workspace, nil -> "tree-dirty" end

      run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 3, runner_opts: [workspace_tree_reader: tree])

      assert turns() == 3
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
    end

    test "counts as usual once the wait reached its bound, and the ticket's history says the command was stopped" do
      wait = %{outcome: :bound, waited_ms: 1_800_000}
      Application.put_env(:symphony_elixir, :progress_turn_extra, %{background_wait: wait})
      tree = fn _workspace, nil -> "tree-dirty" end

      log =
        capture_log(fn ->
          run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: [workspace_tree_reader: tree])
        end)

      assert turns() == 2
      assert log =~ "Stopped a background command of"
      notes = SymphonyElixir.TicketEvents.query("issue-progress", types: ["note"], limit: :all)
      assert Enum.any?(notes, &(inspect(&1.payload) =~ "the wait's limit, then stopped it"))
    end
  end

  describe "a park's uncommitted work (TP-1351)" do
    test "two turns that change files without committing them do not park the ticket" do
      tree = fn _workspace, nil -> "tree-#{turns()}" end

      run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 3, runner_opts: [workspace_tree_reader: tree])

      assert turns() == 3
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
    end

    test "a tree left as it was for two turns still parks" do
      tree = fn _workspace, nil -> "tree-dirty" end

      run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: [workspace_tree_reader: tree])

      assert turns() == 2
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end

    test "the park commits and pushes first, and its note says what it committed and pushed, or that nothing was" do
      for {committed, pushed, said} <- [
            {{:committed, "sha-wip"}, {:pushed, "auto/TP-337"}, ["committed the workspace's uncommitted changes as `sha-wip`", "pushed the branch `auto/TP-337` to origin"]},
            {:nothing, :nothing, ["no uncommitted changes, so nothing was committed", "Nothing was left unpushed, so nothing was pushed"]},
            {{:error, :index_locked}, {:error, :origin_mismatch}, ["could not commit the workspace's uncommitted changes", "The push to origin failed"]}
          ] do
        next_run()
        test_pid = self()
        committer = fn workspace, nil -> send(test_pid, {:committed_in, workspace}) && committed end
        pusher = fn _workspace, nil, _source_repo -> send(test_pid, :pushed_after_commit) && pushed end

        runner_opts = [workspace_committer: committer, workspace_pusher: pusher]
        capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: runner_opts) end)

        assert_received {:committed_in, workspace}
        assert workspace =~ "TP-337"
        assert_received :pushed_after_commit
        assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue where it is" <> note}
        for line <- said, do: assert(note =~ line)
        refute note =~ "Its work is on its branch"
      end
    end

    test "the park's own push lifts no hold: only a later head, or that head's checks reporting, does (TP-1175)" do
      ticket = {:ticket, "default", "issue-progress"}
      read = fn head, ci -> %{head_sha: head, facts: %{ci: ci}} end

      # The park commits and pushes past the watcher's read: that read's CI is another head's.
      record = park_after_read("sha-same", {:committed, "sha-wip"}, {:pushed, "auto/TP-337"})
      assert %{waits_on: %{head: "sha-wip", earlier_head: "sha-same"} = waits_on} = IdlePark.reason(record)
      refute Map.has_key?(waits_on, :ci)

      assert IdlePark.settle(ticket, record, read.("sha-wip", :pending)) == :held
      assert IdlePark.settle(ticket, record, read.("sha-same", :green)) == :held
      assert IdlePark.settle(ticket, record, read.("sha-same", :red)) == :held
      assert [%{id: question_id}] = Questions.open(ticket)

      assert IdlePark.settle(ticket, record, read.("sha-further", :pending)) == :lifted
      assert Questions.open(ticket) == []
      assert %{state: :withdrawn} = Questions.find(ticket, question_id)
      assert {:ok, nil} = Pauses.get(ticket)

      # The head it pushed reporting lifts it too.
      record = park_after_read("sha-same", {:committed, "sha-wip"}, {:pushed, "auto/TP-337"})
      assert IdlePark.settle(ticket, record, read.("sha-wip", :green)) == :lifted

      # Commits the agent left unpushed: the head the park pushed is the run's.
      record = park_after_read("sha-earlier", :nothing, {:pushed, "auto/TP-337"})
      assert %{waits_on: %{head: "sha-same", earlier_head: "sha-earlier"}} = IdlePark.reason(record)

      # Nothing to push: the watcher's read is the head left, and its CI stands.
      record = park_after_read("sha-same", :nothing, :nothing)
      assert %{waits_on: %{head: "sha-same", ci: "green"} = waits_on} = IdlePark.reason(record)
      refute Map.has_key?(waits_on, :earlier_head)
      assert IdlePark.settle(ticket, record, read.("sha-same", :green)) == :held

      # A push that failed left the PR as the watcher read it.
      record = park_after_read("sha-same", {:committed, "sha-wip"}, {:error, :origin_mismatch})
      assert %{waits_on: %{head: "sha-same", ci: "green"} = waits_on} = IdlePark.reason(record)
      refute Map.has_key?(waits_on, :earlier_head)
      assert IdlePark.settle(ticket, record, read.("sha-same", :red)) == :lifted
    end

    # The ticket's record once a run on head "sha-same" parked, the watcher's last read being
    # `read_head` with green checks, and the park's commit and push answering as given.
    defp park_after_read(read_head, committed, pushed) do
      next_run()
      withdraw_open_questions()
      :ok = PrWatchSupport.put_watch!("default", "issue-progress", phase: :in_progress, head_sha: read_head, identifier: "TP-337")

      runner_opts = [
        workspace_committer: fn _workspace, nil -> committed end,
        workspace_pusher: fn _workspace, nil, _source_repo -> pushed end
      ]

      capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: runner_opts) end)
      TicketState.normalize(RunStore.get_ticket_state("issue-progress"))
    end

    test "a real workspace's uncommitted files are committed and its branch is on origin after the park" do
      root = Path.join(System.tmp_dir!(), "symphony-park-git-#{System.unique_integer([:positive])}")
      remote = Path.join(root, "remote.git")
      source = Path.join(root, "source")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      git!(root, ["init", "--bare", "-b", "main", remote])
      git!(root, ["clone", remote, source])
      File.write!(Path.join(source, "README.md"), "readme")
      git!(source, ["add", "README.md"])
      git!(source, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "readme"])
      git!(source, ["push", "origin", "main"])

      setup_workspace = fn workspace ->
        File.rm_rf!(workspace)
        git!(root, ["clone", remote, workspace])
        git!(workspace, ["checkout", "-b", "auto/TP-337"])
        # The agent's turns left 117 files' worth of edits uncommitted: here, two files.
        File.write!(Path.join(workspace, "README.md"), "edited")
        File.write!(Path.join(workspace, "new.ex"), "new")
      end

      pusher = fn workspace, nil, _source_repo -> SymphonyElixir.WorkspaceHead.push_unpushed(workspace, nil, source) end

      opts = [heads: ["sha-same"], pr_url: nil, max_turns: 5, workspace_setup: setup_workspace]
      capture_log(fn -> run_issue!("In Progress", opts ++ [runner_opts: [workspace_pusher: pusher]]) end)

      assert turns() == 2
      assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue where it is" <> note}
      assert [_line, sha] = Regex.run(~r/uncommitted changes as `([0-9a-f]{40})`/, note)
      assert git!(root, ["ls-remote", remote, "refs/heads/auto/TP-337"]) =~ sha
      assert git!(remote, ["log", "-1", "--format=%s", "auto/TP-337"]) == "WIP: parked by Symphony\n"
      assert git!(remote, ["show", "auto/TP-337:new.ex"]) == "new"
    end
  end

  describe "a run whose ticket waits on a decision" do
    test "ends after the turn that asked a decision request, without parking it or handing it off" do
      request = %{
        title: "Which reading is right?",
        question: "Which reading is right?",
        why: "The ticket reads two ways.",
        if_unanswered: "The ticket waits.",
        recommendation_reason: "It is the narrower reading.",
        options: [%{label: "The first", effect: "It builds the first.", recommended: true}, %{label: "The second", effect: "It builds the second."}]
      }

      Application.put_env(:symphony_elixir, :progress_turn_hook, fn _opts ->
        {:ok, _question} = SymphonyElixir.Questions.ask({:ticket, "default", "issue-progress"}, request, request: true)
      end)

      on_exit(fn -> SymphonyElixir.RunStore.delete_ticket_state("issue-progress") end)

      run_issue!("In Progress", heads: ["sha-rework"], repos: designed_repos(), max_turns: 5)

      assert turns() == 1
      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
    end

    test "ends after the turn that posted the request, even before its question is in the store" do
      Application.put_env(:symphony_elixir, :progress_turn_hook, fn opts ->
        CommentRegistry.record_human_action_request(Keyword.fetch!(opts, :linear_comment_registry))
      end)

      run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5)

      assert turns() == 1
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
    end
  end

  test "a turn that can't reach the model API ends the run on the provider hold, so outage turns never park the issue" do
    info = outage_info()
    Application.put_env(:symphony_elixir, :progress_api_unreachable, info)

    # Two runs in a row during the outage: each ends on its first turn, before the empty-turn check.
    for run <- 1..2 do
      assert {:model_api_unreachable, ^info} = catch_exit(run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5))
      assert turns() == run
    end

    refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
  end

  test "an issue refreshed from Linear with no PR recorded is parked, saying it has no PR" do
    fetcher = linear_issue_fetcher()

    log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, issue_state_fetcher: fetcher) end)

    assert turns() == 2
    refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    refute_received {:pr_head_fetched, _pr_url}

    assert log =~
             "Parking issue_id=issue-progress issue_identifier=TP-337 where it is, in In Progress, after 2 turns with no new commit, file change or state change; " <>
               "Symphony has no open PR recorded for it, so CI on its head was not checked"

    refute log =~ "at dispatch"
  end

  test "a run whose issue had a PR at dispatch warns after each refresh that shows no PR" do
    fetcher = linear_issue_fetcher()

    Application.put_env(:symphony_elixir, :progress_turn_hook, fn _opts ->
      :ok = TicketPullRequest.mark_finished("default", @pr_url, "closed")
    end)

    log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 5, issue_state_fetcher: fetcher) end)

    warning =
      "issue_id=issue-progress issue_identifier=TP-337 had PR #{@pr_url} at dispatch, " <>
        "but Symphony's record of its PR now shows no open PR; checks on its PR will not run"

    # The PR URL dropping out of the first refresh counts as a change, so the run parks after three turns.
    assert turns() == 3
    assert log |> String.split(warning) |> length() == turns() + 1
    refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
  end

  test "a run whose refreshed issue still has its PR does not warn about a lost PR" do
    log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 5) end)

    assert turns() == 2
    refute log =~ "at dispatch"
  end

  test "empty Rework turns while CI on the pushed PR head is pending do not park the issue" do
    pending = [%{name: "macos-e2e", status: "IN_PROGRESS", conclusion: nil}]
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: pending}})

    run_issue!("Rework", heads: ["sha-pushed"], max_turns: 4)

    assert turns() == 4
    assert_received {:pr_head_fetched, @pr_url}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "empty Rework turns with no pending CI on the PR head still park the issue" do
    pending = [%{name: "macos-e2e", status: "IN_PROGRESS", conclusion: nil}]
    green = [%{name: "macos-e2e", status: "COMPLETED", conclusion: "SUCCESS"}]

    for pr_head_result <- [
          {:ok, %{commit_sha: "sha-pushed", checks: green}},
          {:ok, %{commit_sha: "sha-pushed", checks: []}},
          {:ok, %{commit_sha: "sha-other", checks: pending}},
          {:error, :gh_unavailable}
        ] do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
      next_run()

      run_issue!("Rework", heads: ["sha-pushed"], max_turns: 4)

      assert turns() == 2
      assert_received {:pr_head_fetched, @pr_url}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  # What Claude's turn reports when it can't reach the model API.
  defp outage_info do
    %{provider: "anthropic", scope: :all, window: nil, resets_at: nil, utilization: nil, source: :api_unreachable, error: "ENOTFOUND"}
  end
end
