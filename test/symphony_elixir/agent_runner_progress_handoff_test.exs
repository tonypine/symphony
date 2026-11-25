defmodule SymphonyElixir.AgentRunnerProgressHandoffTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.AgentRunnerProgressSupport

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.Questions
  alias SymphonyElixir.RunStore

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

  test "a Rework run whose new commits are the PR head moves to Code Review without another turn" do
    run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework")

    assert turns() == 1
    assert_received {:pr_head_fetched, @pr_url}
    assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    assert_signal("handoff", %{to: "Code Review", reason: "after rework", head: "sha-rework", move: true})
  end

  test "the head a ticket enters Code Review with is asked of the QA pre-build" do
    # Stands in for the builder: the request is a cast to its name.
    Process.register(self(), SymphonyElixir.QaBuild)

    run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework")

    assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    # With the ticket's issue: the builder builds only a head whose QA pass selects the app.
    assert_received {:"$gen_cast", {:request, "default", "sha-rework", %{identifier: identifier, issue_id: "issue-progress", issue: %Issue{id: "issue-progress"}}}}
    assert is_binary(identifier)
  end

  describe "the designed handoff signal" do
    test "a Rework run whose head reached its PR past the tool hooks records the signal and moves to Code Review" do
      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_signal("handoff", %{to: "Code Review", reason: "after rework", head: "sha-rework", move: true})
      assert_handoff_recorded("sha-rework", "pushed_pr_head")
      refute missing_handoff_recorded?()
    end

    test "a Rework run whose handoff step pushed the head ends in Code Review, with no retry" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:by_turn, [pr_status("sha-old"), pr_status("sha-new")]})

      assert :ok =
               run_issue!("Rework",
                 heads: ["sha-old", "sha-new"],
                 repos: designed_repos(),
                 runner_opts: [step_command_runner: step_runner(), run_id: "run-progress"]
               )

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_handoff_recorded("sha-new", "pushed_pr_head")
      refute missing_handoff_recorded?()
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "a list's machine handoff step records the signal for the head it pushed and moves the ticket in the same run" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))

      assert :ok = run_machine_handoff!(step_runner(pushes: "sha-new"))

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_signal("handoff", %{to: "Code Review", reason: "after its handoff step", head: "sha-new", move: true})
      assert_handoff_recorded("sha-new", "machine_handoff")
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "a machine handoff step that left the PR on another head moves nothing" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))

      assert :ok = run_machine_handoff!(step_runner())

      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      refute Handoff.emitted?("default", "issue-progress", "sha-new")
    end

    test "a failed move after a machine handoff step fails the run" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})

      assert_raise RuntimeError, ~r/machine_handoff_failed/, fn ->
        run_machine_handoff!(step_runner(pushes: "sha-new"))
      end
    end

    test "a machine handoff step on a Rework head that never moved hands that head off (TP-1186)" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))

      assert :ok = run_machine_handoff!(step_runner(), heads: ["sha-old"])

      assert_received :machine_push
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_handoff_recorded("sha-old", "machine_handoff")
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "a machine handoff step with review comments pending emits nothing and moves nothing, in Rework or In Progress" do
      # In Progress, the pending comments make the run a `review_feedback` one, so its list sits there.
      for {state, list} <- [{"Rework", "rework"}, {"In Progress", "review_feedback"}] do
        put_pending_review()
        Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))

        assert :ok = run_machine_handoff!(step_runner(pushes: "sha-new"), state: state, list: list)

        assert_received :machine_push
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
        refute Handoff.emitted?("default", "issue-progress", "sha-new")
        Application.delete_env(:symphony_elixir, :progress_agent_turns)
      end
    end

    test "an In Progress list's machine handoff step moves the ticket with nothing pending and the PR on its head" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))

      assert :ok = run_machine_handoff!(step_runner(pushes: "sha-new"), state: "In Progress", list: "implementation")

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_handoff_recorded("sha-new", "machine_handoff")
    end

    test "a hold raised while the machine handoff step ran keeps the ticket where it is" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))
      ticket = {:ticket, "default", "issue-progress"}
      hold = fn -> {:ok, _pause} = Pauses.set(ticket, Pauses.ticket_reason(:dependency, "TP-12")) end

      assert :ok = run_machine_handoff!(step_runner(pushes: "sha-new", on_push: hold))

      assert_received :machine_push
      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      refute Handoff.emitted?("default", "issue-progress", "sha-new")
    end

    test "a ticket moved to another phase while the machine handoff step ran stays there" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))
      fetcher = refreshes([{:ok, [progress_issue("Rework")]}, {:ok, [progress_issue("Merging")]}])

      assert :ok = run_machine_handoff!(step_runner(pushes: "sha-new"), issue_state_fetcher: fetcher)

      assert_received :machine_push
      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      refute Handoff.emitted?("default", "issue-progress", "sha-new")
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "a ticket gone from the tracker while the machine handoff step ran moves nothing" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))
      fetcher = refreshes([{:ok, [progress_issue("Rework")]}, {:ok, []}])

      assert :ok = run_machine_handoff!(step_runner(pushes: "sha-new"), issue_state_fetcher: fetcher)

      assert_received :machine_push
      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      refute Handoff.emitted?("default", "issue-progress", "sha-new")
    end

    test "a failed read of the ticket after the machine handoff step fails the run" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))
      fetcher = refreshes([{:ok, [progress_issue("Rework")]}, {:error, :boom}])

      assert_raise RuntimeError, ~r/issue_state_refresh_failed/, fn ->
        run_machine_handoff!(step_runner(pushes: "sha-new"), issue_state_fetcher: fetcher)
      end

      refute_received {:memory_tracker_state_update, "issue-progress", _state}
    end

    test "going on past a machine handoff step that hung moves the ticket in the run that resumes it" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))
      ticket = {:ticket, "default", "issue-progress"}

      assert :ok = run_machine_handoff!(step_runner(hangs: true))

      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      assert [%{id: question_id, step: "handoff"}] = Questions.open(ticket)

      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-new"))
      {:ok, _answered} = Questions.answer(ticket, question_id, "Go on past it")

      assert :ok = run_machine_handoff!(step_runner())

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_handoff_recorded("sha-new", "machine_handoff")
    end

    test "a pushed head an In Progress run left with no signal does not advance, on a pending rework signal" do
      :ok = put_pending_conflict()
      green = [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: green}})

      assert_raise RuntimeError, ~r/pushed_head_handoff_failed.*handoff_signal_missing/, fn ->
        run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], repos: designed_repos())
      end

      refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert missing_handoff_recorded?()
    end

    test "a groomed ticket with an open check a test proves is not handed off, and is once the check is proved" do
      plan = %{
        reason: "Grooming",
        by: "grooming",
        shape: "single",
        layers: ["engine"],
        summary: "The handoff waits for the plan's checks.",
        text: "Refuse the handoff while a check is open.",
        checks: [
          %{id: "c1", kind: "outcome", statement: "The handoff waits.", proof: "test"},
          %{id: "c2", kind: "qa", statement: "The page shows it.", proof: "qa", action: "Open it", expect: "It shows"}
        ],
        size: %{tokens: 100_000, runs: 1}
      }

      {:ok, _plan} = SymphonyElixir.TicketPlan.write("default", "issue-progress", plan)
      assert :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: "sha-rework", branch: "auto/TP-337"})

      log =
        capture_log(fn ->
          assert_raise RuntimeError, ~r/rework_handoff_failed.*checks_unproved.*c1/, fn ->
            run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())
          end
        end)

      assert log =~ "its plan's checks c1 are open"
      refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}

      assert [%{payload: %{text: note}}] = SymphonyElixir.TicketEvents.query("issue-progress", types: ["note"])
      assert note =~ "- [c1] The handoff waits. (proof: test)"

      proof = %{check_id: "c1", by: "test", test: "test/handoff_test.exs"}
      {:ok, _proved} = SymphonyElixir.TicketChecks.prove("default", "issue-progress", proof, actor: {:agent, "run-1", "rework"})

      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    end

    test "the second run in a row refused for open checks asks the person what to do" do
      checks = [%{id: "c1", kind: "outcome", statement: "The handoff waits.", proof: "test"}]
      plan = %{reason: "Grooming", by: "grooming", shape: "single", layers: ["engine"], summary: "s", text: "t", checks: checks}
      {:ok, _plan} = SymphonyElixir.TicketPlan.write("default", "issue-progress", Map.put(plan, :size, %{tokens: 1, runs: 1}))
      assert :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: "sha-rework", branch: "auto/TP-337"})
      ticket = {:ticket, "default", "issue-progress"}

      for run_id <- ["run-a", "run-b"] do
        started = %{run_id: run_id, run_kind: "rework"}
        {:ok, _started} = SymphonyElixir.TicketEvents.record("default", "issue-progress", "run.started", started, run_id: run_id)

        capture_log(fn ->
          assert_raise RuntimeError, ~r/checks_unproved.*c1/, fn ->
            run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos(), runner_opts: [run_id: run_id])
          end
        end)

        if run_id == "run-a", do: assert(SymphonyElixir.Questions.open(ticket) == [])
      end

      assert [%{title: "TP-337: checks of its plan are still not proved", options: [_back, waive, _cancel]}] = SymphonyElixir.Questions.open(ticket)
      assert %{label: "Waive them and pass it on", move: %{to: "Code Review", waive: [%{check_id: "c1"}]}} = waive
      refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    end

    test "the explicit handoff signal moves the ticket to Code Review" do
      assert :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: "sha-rework", branch: "auto/TP-337"})

      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_signal("handoff", %{to: "Code Review", reason: "after rework", head: "sha-rework", move: true})
    end

    test "a signal for another head does not stand in for this head's own" do
      assert :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: "sha-other", branch: "auto/TP-337"})

      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())

      assert_handoff_recorded("sha-rework", "pushed_pr_head")
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    end

    test "an In Progress run whose PR is already on its head hands off to Code Review after one quiet turn" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: []}})

      assert :ok = run_issue!("In Progress", heads: ["sha-pushed"], repos: designed_repos())

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_signal("handoff", %{to: "Code Review", reason: "with its PR already on its head", head: "sha-pushed", move: true})
    end

    test "a quiet In Progress run whose PR head can't be read hands nothing off" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:error, :unavailable})

      assert :ok = run_issue!("In Progress", heads: ["sha-pushed"], repos: designed_repos())

      assert turns() == 1
      refute_received {:memory_tracker_state_update, "issue-progress", _state}
    end

    test "a failed move after the quiet handoff fails the run" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: []}})
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})

      assert_raise RuntimeError, ~r/pushed_pr_head_handoff_failed/, fn ->
        run_issue!("In Progress", heads: ["sha-pushed"], repos: designed_repos())
      end
    end

    test "an earlier run's own move record does not stand in for a later head's signal" do
      # First cycle: a real handoff signal advances the ticket to Code Review, and the run records
      # its own move in the ledger.
      assert :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: "sha-rework", branch: "auto/TP-337"})
      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}

      # Second cycle: a later Rework run pushes a new head to the PR through no tool hook. The earlier
      # run's move record is bound to the earlier head, so the runner records this head's own signal.
      next_run()
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-new", checks: []}})
      refute Handoff.emitted?("default", "issue-progress", "sha-new")

      assert :ok = run_issue!("Rework", heads: ["sha-rework", "sha-new"], repos: designed_repos())

      assert_handoff_recorded("sha-new", "pushed_pr_head")
    end

    defp pr_status(head), do: {:ok, %{commit_sha: head, checks: []}}

    # A list whose last step is a machine `handoff`: the agent commits `sha-new` in the code turn, and
    # the step's command is the push.
    defp run_machine_handoff!(runner, opts \\ []) do
      list = Keyword.get(opts, :list, "rework")
      steps = machine_handoff_steps(list)

      run_issue!(
        Keyword.get(opts, :state, "Rework"),
        [
          heads: Keyword.get(opts, :heads, ["sha-old", "sha-new"]),
          repos: designed_repos(),
          symphony_steps: steps,
          runner_opts: [step_command_runner: runner, run_id: "run-progress"]
        ] ++ Keyword.take(opts, [:issue_state_fetcher])
      )
    end

    defp machine_handoff_steps(list) do
      """
      phases:
        #{list}:
          steps:
            - {id: code, title: Write the code, mode: delegated}
            - {id: handoff, title: Push, mode: machine, command: make push, on_fail: code}
      """
    end

    # The step commands: the changed-files script reports an Elixir change, `make push` tells the test,
    # runs `:on_push`, hangs with `:hangs` and puts the PR on `:pushes` when given, and every other
    # command passes.
    defp step_runner(opts \\ []) do
      parent = self()

      fn command, _env, _timeout_ms ->
        cond do
          command =~ "git merge-base" -> {:ok, {"M\tlib/app.ex\n", 0}}
          command == "make push" -> machine_push(parent, opts)
          true -> {:ok, {"", 0}}
        end
      end
    end

    defp machine_push(parent, opts) do
      send(parent, :machine_push)
      if on_push = opts[:on_push], do: on_push.()
      if pushed = opts[:pushes], do: Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status(pushed))
      if opts[:hangs], do: {:timeout, "hanging"}, else: {:ok, {"pushed", 0}}
    end

    # The ticket as each read in turn finds it (the last one repeating).
    defp refreshes(results) do
      calls = :counters.new(1, [])

      fn _ids ->
        :counters.add(calls, 1, 1)
        Enum.at(results, :counters.get(calls, 1) - 1) || List.last(results)
      end
    end

    defp progress_issue(state) do
      %Issue{id: "issue-progress", identifier: "TP-337", title: "Leave Rework", description: "Fix the PR", state: state, repo_key: "default"}
    end

    defp put_pending_review do
      :ok =
        RunStore.put_pr_review(%{
          repo_key: "default",
          issue_id: "issue-progress",
          issue_identifier: "TP-337",
          pr_url: @pr_url,
          workspace_path: "/tmp",
          status: "rework_requested",
          pending_last_addressed_comment_id: "comment-337",
          pending_reviewer_comments: [%{id: "comment-337", kind: "inline_comment", author: "Reviewer", body: "Rename this."}],
          updated_at: ~U[2026-10-03 12:00:00Z]
        })
    end

    defp missing_handoff_recorded?, do: "issue-progress" |> ticket_signals() |> Enum.any?(&(&1.name == "handoff_missing"))
  end

  test "a re-dispatched Rework run whose rework an earlier run pushed moves on after one empty turn" do
    run_issue!("Rework", heads: ["sha-old"], handoff: "sha-old", max_turns: 1)

    assert RunStore.get_rework_base("default", "issue-progress") == "sha-old"
    refute_received {:memory_tracker_state_update, _issue_id, _state}

    next_run()
    run_issue!("Rework", heads: ["sha-rework"], handoff: "sha-rework")

    assert turns() == 1
    assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    assert RunStore.get_rework_base("default", "issue-progress") == nil
  end

  test "a fresh Rework run that starts on the PR head does not move on after an empty turn" do
    run_issue!("Rework", heads: ["sha-rework"], states: ["Rework", "Todo"])

    assert turns() == 2
    refute_received {:memory_tracker_state_update, _issue_id, _state}
    assert RunStore.get_rework_base("default", "issue-progress") == nil
  end

  describe "a Rework whose fix needs no commit (TP-1186)" do
    # The agent's push or PR tool call on the unchanged head, as the tool hook records it: in the
    # run's registry, and as the ledger's signal, which the ticket's first handoff already holds.
    defp push_unchanged_head(head) do
      Application.put_env(:symphony_elixir, :progress_turn_hook, fn opts ->
        :ok = CommentRegistry.record_handoff(Keyword.fetch!(opts, :linear_comment_registry), head)
        :ok = Handoff.emit("default", "issue-progress", %{head: head, branch: "auto/TP-337"})
      end)
    end

    test "a Rework run that pushes its unchanged PR head moves to Code Review in that run" do
      push_unchanged_head("sha-rework")

      assert :ok = run_issue!("Rework", heads: ["sha-rework"], handoff: "sha-rework")

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_signal("handoff", %{to: "Code Review", reason: "after rework", head: "sha-rework", move: true})
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "a handoff signal recorded before the run started does not hand off the unchanged head" do
      run_issue!("Rework", heads: ["sha-rework"], handoff: "sha-rework", states: ["Rework", "Todo"])

      assert turns() == 2
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "a pushed unchanged head with a review comment, a CI failure or a conflict pending stays in Rework" do
      pending = [
        &put_pending_review_comment/0,
        fn -> :ok = put_pending_ci_failure(approved: false, commit_sha: "sha-rework") end,
        fn -> :ok = put_pending_conflict(head_sha: "sha-rework") end
      ]

      for put_pending <- pending do
        next_run()
        put_pending.()
        push_unchanged_head("sha-rework")

        run_issue!("Rework", heads: ["sha-rework"], states: ["Rework", "Done"])

        refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}
      end
    end

    defp put_pending_review_comment do
      :ok =
        RunStore.put_pr_review(%{
          repo_key: "default",
          issue_id: "issue-progress",
          issue_identifier: "TP-337",
          pr_url: @pr_url,
          workspace_path: "/tmp",
          status: "rework_requested",
          pending_last_addressed_comment_id: "comment-337",
          pending_reviewer_comments: [%{id: "comment-337", kind: "inline_comment", author: "Reviewer", body: "Rename this."}],
          updated_at: ~U[2026-10-03 12:00:00Z]
        })
    end
  end

  describe "a Rework that answers every finding without a code change (TP-1579)" do
    # The Rework came from QA failing the head Code Review approved.
    setup do
      :ok = put_verdict("default", "issue-progress", "code_review", "sha-rework", "approve", %{}, ~U[2026-11-21 03:00:00Z])
      :ok = put_verdict("default", "issue-progress", "qa", "sha-rework", "fail", %{}, ~U[2026-11-21 03:10:00Z])
      :ok
    end

    # A finding QA recorded, and `resolved` when the rework recorded its fix (`:confirmed` once a
    # QA pass confirmed it too).
    defp found!(state) do
      {:ok, finding} =
        SymphonyElixir.TicketEvents.record("default", "issue-progress", "finding.recorded", %{class: "proof", severity: "major", description: "No test named c2."}, actor: {:agent, "run-qa", "qa"})

      if state in [:resolved, :confirmed] do
        {:ok, resolution} =
          SymphonyElixir.TicketEvents.record("default", "issue-progress", "finding.resolved", %{finding_id: finding.id, how: "Recorded the proof again"},
            actor: {:agent, "run-rw", "rework"},
            head_sha: "sha-rework"
          )

        if state == :confirmed do
          {:ok, _confirmed} =
            SymphonyElixir.TicketEvents.record("default", "issue-progress", "finding.confirmed", %{finding_id: finding.id, resolution: resolution.id, head: "sha-rework"})
        end
      end

      finding
    end

    defp in_code_review?, do: Enum.any?(ticket_signals("issue-progress"), &match?(%{details: %{to: "Code Review"}}, &1))

    test "goes back to QA on the same head, without Code Review, a park or a question" do
      found!(:resolved)
      found!(:confirmed)

      assert :ok = run_issue!("Rework", heads: ["sha-rework"], max_turns: 5)

      assert turns() == 1
      assert_received {:pr_head_fetched, @pr_url}
      assert_received {:memory_tracker_state_update, "issue-progress", "QA"}
      refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}
      assert_signal("rework answered", %{to: "QA", head: "sha-rework", move: true})
      assert [%{payload: %{to: "QA", signal: "rework answered"}, head_sha: "sha-rework"} | _] = SymphonyElixir.TicketEvents.query("issue-progress", types: ["phase.entered"])
      refute in_code_review?()
      refute idle_parked?()
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "goes back to QA even when the run also pushed the unchanged head" do
      found!(:resolved)
      push_unchanged_head("sha-rework")

      assert :ok = run_issue!("Rework", heads: ["sha-rework"], handoff: "sha-rework")

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "QA"}
      refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}
    end

    # Today's end of a fresh Rework run that changed nothing: two empty turns, and no move.
    defp assert_ends_as_today(runner_opts \\ []) do
      run_issue!("Rework", heads: ["sha-rework"], states: ["Rework", "Todo"], runner_opts: runner_opts)

      assert turns() == 2
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "with a finding still open, ends as it does today" do
      found!(:resolved)
      found!(:open)

      assert_ends_as_today()
    end

    test "with no finding at all, ends as it does today" do
      assert_ends_as_today()
    end

    test "with uncommitted edits in the workspace, ends as it does today" do
      found!(:resolved)

      assert_ends_as_today(workspace_tree_reader: fn _workspace, nil -> "uncommitted-digest" end)
    end

    # Today a HEAD the PR does not show yet is waited on (`await_pr_head/2`), not parked, so the run
    # keeps turning: what matters is that it does not move to QA.
    test "after Code Review requested changes on that head, ends as it does today" do
      found!(:resolved)
      :ok = put_verdict("default", "issue-progress", "code_review", "sha-rework", "request_changes", %{}, ~U[2026-11-21 03:20:00Z])

      assert_ends_as_today()
    end

    test "when Code Review approved the head again after QA's fail, ends as it does today" do
      found!(:resolved)
      :ok = put_verdict("default", "issue-progress", "code_review", "sha-rework", "approve", %{}, ~U[2026-11-21 03:20:00Z])

      assert_ends_as_today()
    end

    test "when QA's newest fail is on another head, ends as it does today" do
      found!(:resolved)
      :ok = put_verdict("default", "issue-progress", "qa", "sha-other", "fail", %{}, ~U[2026-11-21 03:30:00Z])

      assert_ends_as_today()
    end

    test "with the PR on another head, does not move to QA" do
      found!(:resolved)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-other", checks: []}})

      run_issue!("Rework", heads: ["sha-rework"], states: ["Rework", "Todo"])

      refute_received {:memory_tracker_state_update, _issue_id, "QA"}
      refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}
      refute Enum.any?(ticket_signals("issue-progress"), &match?(%{details: %{to: "QA"}}, &1))
    end

    test "a run that pushed its unchanged head with a finding open still goes to Code Review" do
      found!(:open)
      push_unchanged_head("sha-rework")

      assert :ok = run_issue!("Rework", heads: ["sha-rework"], handoff: "sha-rework")

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, _issue_id, "QA"}
    end

    test "a pending review comment keeps today's rules" do
      found!(:resolved)
      put_pending_review_comment()

      run_issue!("Rework", heads: ["sha-rework"], states: ["Rework", "Done"])

      refute_received {:memory_tracker_state_update, _issue_id, "QA"}
    end

    test "a rework that moved the head with a code change still goes to Code Review" do
      found!(:resolved)

      run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework")

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, _issue_id, "QA"}
      assert_signal("handoff", %{to: "Code Review", reason: "after rework", head: "sha-rework", move: true})
    end

    test "a failed move to QA fails the run" do
      found!(:resolved)
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})

      assert_raise RuntimeError, ~r/rework_handoff_failed/, fn ->
        run_issue!("Rework", heads: ["sha-rework"])
      end
    end
  end

  describe "a Rework a person answered a question in, whose run changes nothing (TP-1596)" do
    @reading %{
      title: "How to read check c3",
      question: "Should PR #337 go back to Code Review as it is?",
      why: "The check reads two ways.",
      if_unanswered: "The ticket waits.",
      recommendation_reason: "The code already does it.",
      options: [%{label: "Back to Code Review unchanged", effect: "PR #337 goes back to Code Review.", recommended: true}, %{label: "Change it", effect: "The rework changes it."}]
    }

    defp entered_rework! do
      {:ok, _event} = SymphonyElixir.TicketEvents.record("default", "issue-progress", "phase.entered", %{to: "Rework", from: "Code Review"})
    end

    defp answered! do
      ticket = {:ticket, "default", "issue-progress"}
      {:ok, question} = Questions.ask(ticket, @reading, request: true)
      {:ok, _answered} = Questions.answer(ticket, question.id, "Back to Code Review unchanged", by: Pauses.director())
    end

    test "hands its unchanged PR head back to Code Review with the answer as the reason, with no park and no second question" do
      entered_rework!()
      answered!()

      assert :ok = run_issue!("Rework", heads: ["sha-rework"], max_turns: 5)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      reason = "after the answer “Back to Code Review unchanged”"
      assert_signal("handoff", %{to: "Code Review", reason: reason, head: "sha-rework", move: true})
      phases = SymphonyElixir.TicketEvents.query("issue-progress", types: ["phase.entered"])
      assert %{payload: %{to: "Code Review", reason: ^reason}, head_sha: "sha-rework"} = List.last(phases)
      assert_handoff_recorded("sha-rework", "answered_rework")
      refute idle_parked?()
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "a handoff the run already emitted for the head is kept, and the move still carries the answer" do
      entered_rework!()
      answered!()

      assert :ok = run_issue!("Rework", heads: ["sha-rework"], max_turns: 5, handoff: "sha-rework")

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_signal("handoff", %{to: "Code Review", reason: "after the answer “Back to Code Review unchanged”", head: "sha-rework", move: true})
      refute Enum.any?(ticket_signals("issue-progress"), &match?(%{name: "handoff", details: %{source: "answered_rework"}}, &1))
      refute idle_parked?()
    end

    test "an answer from before the ticket last entered Rework parks the run as before" do
      answered!()
      entered_rework!()

      assert :ok = run_issue!("Rework", heads: ["sha-rework"], max_turns: 5)

      refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}
      assert idle_parked?()
    end

    test "the answer to the idle park's own question parks the run again, never hands the head back" do
      entered_rework!()
      ticket = {:ticket, "default", "issue-progress"}
      {:ok, question} = Questions.ask(ticket, SymphonyElixir.IdlePark.hold_question_attrs("TP-1", "Rework", 2))
      run_again = SymphonyElixir.DispatchLoop.option_label(:unblock)
      {:ok, _answered} = Questions.answer(ticket, question.id, run_again, by: Pauses.director())

      assert :ok = run_issue!("Rework", heads: ["sha-rework"], max_turns: 5)

      refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}
      assert idle_parked?()
    end

    test "with uncommitted edits, or the PR on another head, the run is not handed back" do
      entered_rework!()
      answered!()

      run_issue!("Rework", heads: ["sha-rework"], max_turns: 5, runner_opts: [workspace_tree_reader: fn _workspace, nil -> "uncommitted-digest" end])
      refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}

      Application.delete_env(:symphony_elixir, :progress_agent_turns)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-other", checks: []}})
      run_issue!("Rework", heads: ["sha-rework"], states: ["Rework", "Todo"])
      refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}
    end

    test "a failed move to Code Review fails the run" do
      entered_rework!()
      answered!()
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})

      assert_raise RuntimeError, ~r/rework_handoff_failed/, fn ->
        run_issue!("Rework", heads: ["sha-rework"], max_turns: 5)
      end
    end
  end

  describe "a Rework whose findings need no code change, after a blocked QA pass the Conductor routed (TP-1655)" do
    # QA could not judge the head Code Review approved (its drag steps were blocked), and the
    # Conductor waived the check and routed the ticket to Rework with a finding.
    setup do
      :ok = put_verdict("default", "issue-progress", "code_review", "sha-rework", "approve", %{}, ~U[2026-11-24 03:00:00Z])
      :ok = put_verdict("default", "issue-progress", "qa", "sha-rework", "blocked", %{}, ~U[2026-11-24 03:10:00Z])
      :ok
    end

    # The Conductor's finding, as QA records it for its route; ruled by the rework run to need no
    # change when `ruled?`.
    defp routed_finding!(ruled?) do
      {:ok, finding} =
        SymphonyElixir.TicketEvents.record("default", "issue-progress", "finding.recorded", %{class: "unclassified", severity: "unrated", description: "The drag check was waived."},
          actor: {:agent, "run-qa", "qa"}
        )

      if ruled? do
        {:ok, _resolution} =
          SymphonyElixir.TicketEvents.record("default", "issue-progress", "finding.resolved", %{finding_id: finding.id, how: "Needs no change: the Conductor waived the drag check."},
            actor: {:agent, "run-rw", "rework"},
            head_sha: "sha-rework"
          )
      end

      finding
    end

    test "goes back to QA on the same head, with no hold and no question" do
      routed_finding!(true)

      assert :ok = run_issue!("Rework", heads: ["sha-rework"], max_turns: 5)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "QA"}
      refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}
      assert_signal("rework answered", %{to: "QA", head: "sha-rework", move: true})
      refute idle_parked?()
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
    end

    # The PR shows the rework's head only once the list's handoff step pushed it, so the answered
    # rework is first seen there, not at the end of the code turn.
    test "goes back to QA from the step list's machine handoff step, ahead of Code Review" do
      routed_finding!(true)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))

      assert :ok = run_machine_handoff!(step_runner(pushes: "sha-rework"), heads: ["sha-rework"])

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "QA"}
      refute_received {:memory_tracker_state_update, _issue_id, "Code Review"}
      assert_signal("rework answered", %{to: "QA", head: "sha-rework", move: true})
      refute Handoff.emitted?("default", "issue-progress", "sha-rework")
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "a hold raised while the machine handoff step ran keeps the ticket in Rework" do
      routed_finding!(true)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))
      hold = fn -> {:ok, _pause} = Pauses.set({:ticket, "default", "issue-progress"}, Pauses.ticket_reason(:dependency, "TP-12")) end

      assert :ok = run_machine_handoff!(step_runner(pushes: "sha-rework", on_push: hold), heads: ["sha-rework"])

      refute_received {:memory_tracker_state_update, "issue-progress", _state}
    end

    test "with uncommitted edits left by the machine steps, hands off to Code Review as before" do
      routed_finding!(true)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_status("sha-old"))
      dirty = :counters.new(1, [])

      # Clean until the handoff step ran, dirty after it.
      reader = fn _workspace, nil -> if :counters.get(dirty, 1) > 0, do: "uncommitted-digest" end

      assert :ok =
               run_issue!("Rework",
                 heads: ["sha-rework"],
                 repos: designed_repos(),
                 symphony_steps: machine_handoff_steps("rework"),
                 runner_opts: [
                   step_command_runner: step_runner(pushes: "sha-rework", on_push: fn -> :counters.add(dirty, 1, 1) end),
                   run_id: "run-progress",
                   workspace_tree_reader: reader
                 ]
               )

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}

      refute_received {:memory_tracker_state_update, _issue_id, "QA"}
    end

    test "with the finding still open, is parked for no progress, with its hold and its question" do
      routed_finding!(false)

      run_issue!("Rework", heads: ["sha-rework"], max_turns: 5)

      assert turns() == 2
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert idle_parked?()

      assert {:ok, %{reasons: reasons}} = Pauses.get({:ticket, "default", "issue-progress"})
      assert %{text: "No progress: the last 2 turns in Rework made no new commit and no state change"} = Enum.find(reasons, &(&1.kind == :environment))
      assert [%{title: "TP-337 is paused in Rework: its last 2 turns changed nothing"}] = Questions.open({:ticket, "default", "issue-progress"})
    end

    test "after Code Review requested changes on that head, does not move to QA" do
      routed_finding!(true)
      :ok = put_verdict("default", "issue-progress", "code_review", "sha-rework", "request_changes", %{}, ~U[2026-11-24 03:20:00Z])

      run_issue!("Rework", heads: ["sha-rework"], states: ["Rework", "Todo"])

      refute_received {:memory_tracker_state_update, _issue_id, "QA"}
    end
  end

  test "a Rework run with unresolved review comments on the current head keeps going" do
    assert :ok =
             RunStore.put_pr_review(%{
               repo_key: "default",
               issue_id: "issue-progress",
               issue_identifier: "TP-337",
               pr_url: @pr_url,
               workspace_path: "/tmp",
               status: "rework_requested",
               pending_last_addressed_comment_id: "comment-337",
               pending_reviewer_comments: [%{id: "comment-337", kind: "inline_comment", author: "Reviewer", body: "Rename this."}],
               updated_at: ~U[2026-10-03 12:00:00Z]
             })

    run_issue!("Rework", heads: ["sha-old", "sha-rework", "sha-rework-2"], states: ["Rework", "Done"])

    assert turns() == 2
    refute_received {:pr_head_fetched, _pr_url}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "a Rework run keeps going while its commits are not the PR head or the head is unreadable" do
    for pr_head_result <- [{:ok, %{commit_sha: "sha-old", checks: []}}, {:error, :gh_unavailable}] do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
      next_run()

      run_issue!("Rework", heads: ["sha-old", "sha-rework", "sha-rework-2"], states: ["Rework", "Done"])

      assert turns() == 2
      assert_received {:pr_head_fetched, @pr_url}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end
  end

  test "two consecutive empty turns stop the run and hold the issue in its phase, never moving it to Backlog" do
    run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5)

    assert turns() == 2
    refute_received {:memory_tracker_state_update, _issue_id, _state}
    assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue where it is, in In Progress" <> _note}

    # The hold is the idle park rule's action on the ticket.
    assert [%{rule: "Idle park", action: "paused", text: "2 turns in In Progress changed nothing, so it was held where it is"}] =
             "issue-progress" |> SymphonyElixir.TicketEvents.query(types: ["rule.action"]) |> Enum.map(& &1.payload) |> Enum.filter(&(&1.rule == "Idle park"))
  end

  describe "a run whose workspace head was never pushed, with steps left to do (TP-1568)" do
    # A list whose code step a failing check sends back once, so the code step takes two turns that
    # change nothing, then the handoff step. `unpushed` is what the workspace's unpushed-head read
    # gives; `states` the ticket after each turn, as `run_issue!/2` takes it.
    defp unpushed_step_command(command, checks) do
      cond do
        command =~ "git merge-base" -> {:ok, {"M\tlib/app.ex\n", 0}}
        command == "make check" -> first_check_fails(checks)
        true -> {:ok, {"", 0}}
      end
    end

    defp first_check_fails(checks) do
      :counters.add(checks, 1, 1)
      if :counters.get(checks, 1) == 1, do: {:ok, {"1 failure", 1}}, else: {:ok, {"ok", 0}}
    end

    defp run_unpushed!(unpushed, opts \\ []) do
      checks = :counters.new(1, [])
      runner = fn command, _env, _timeout_ms -> unpushed_step_command(command, checks) end

      steps = """
      phases:
        implementation:
          steps:
            - {id: code, title: Write the code, mode: delegated}
            - {id: checks, title: Run the checks, mode: machine, command: make check, on_fail: code}
            - {id: handoff, title: Hand off, mode: delegated}
      """

      runner_opts = [
        step_command_runner: runner,
        run_id: "run-progress",
        workspace_unpushed_head_reader: fn _workspace, nil -> unpushed end,
        workspace_pusher: Keyword.get(opts, :pusher, fn _workspace, nil, _repo -> :nothing end)
      ]

      capture_log(fn ->
        run_issue!("In Progress",
          heads: ["sha-unpushed"],
          states: Keyword.get(opts, :states, ["In Progress"]),
          pr_url: nil,
          max_turns: 5,
          repos: designed_repos(),
          symphony_steps: steps,
          runner_opts: runner_opts
        )
      end)
    end

    defp passed_steps do
      "issue-progress"
      |> SymphonyElixir.TicketEvents.query(types: ["step.completed"])
      |> Enum.map(& &1.payload)
      |> Enum.filter(&(&1[:outcome] == "passed" and &1[:step_id] in ["code", "handoff"]))
      |> Enum.map(& &1[:step_id])
    end

    defp idle_parked? do
      case Pauses.get({:ticket, "default", "issue-progress"}) do
        {:ok, %{reasons: reasons}} -> Enum.any?(reasons, &match?(%{waits_on: %{condition: "idle_park"}}, &1))
        _no_pause -> false
      end
    end

    test "is not parked after two turns that change nothing, and goes on to its next step" do
      # The handoff turn pushes and the ticket leaves the active states.
      log = run_unpushed!("sha-unpushed", states: ["In Progress", "In Progress", "Done"])

      assert log =~ "Not parking issue_id=issue-progress issue_identifier=TP-337; its head sha-unpushed was never pushed and its step list goes on from code to checks"
      assert turns() == 3
      assert passed_steps() == ["code", "code", "handoff"]
      refute idle_parked?()
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
    end

    test "a ticket parked with its commit still unpushed reaches its handoff step when it is run again" do
      # The first run idles out on its last step, and the park's push of the commit fails.
      log = run_unpushed!("sha-unpushed", pusher: fn _workspace, nil, _repo -> {:error, :rejected} end)

      assert turns() == 3
      assert log =~ "Could not push issue_id=issue-progress issue_identifier=TP-337's unpushed commits before parking it"
      assert idle_parked?()

      # The person's "Run it again" lifts the park; the new run starts on the same unpushed head.
      next_run()
      log = run_unpushed!("sha-unpushed", states: ["In Progress", "In Progress", "Done"])

      assert log =~ "its head sha-unpushed was never pushed and its step list goes on from code to checks"
      assert turns() == 3
      assert passed_steps() |> Enum.take(-3) == ["code", "code", "handoff"]
      refute idle_parked?()
    end

    test "a run whose head is pushed is still parked after two turns that change nothing" do
      log = run_unpushed!(nil)

      assert turns() == 2
      refute log =~ "Not parking"
      assert passed_steps() == ["code", "code"]
      assert idle_parked?()
    end
  end

  test "a run on its last step is parked after two turns that change nothing, its head unpushed or not" do
    steps = """
    phases:
      implementation:
        steps:
          - {id: code, title: Write the code, mode: delegated}
          - {id: handoff, title: Hand off, mode: delegated}
    """

    for unpushed <- ["sha-unpushed", nil] do
      next_run()
      test_pid = self()

      runner_opts = [
        run_id: "run-progress",
        workspace_unpushed_head_reader: fn _workspace, nil -> unpushed end,
        workspace_pusher: fn _workspace, nil, _repo -> send(test_pid, :park_pushed) && :nothing end
      ]

      log =
        capture_log(fn ->
          run_issue!("In Progress",
            heads: ["sha-same"],
            pr_url: nil,
            max_turns: 5,
            repos: designed_repos(),
            symphony_steps: steps,
            runner_opts: runner_opts
          )
        end)

      assert turns() == 2
      refute log =~ "Not parking"
      assert_received :park_pushed
      assert {:ok, %{reasons: [_ | _]}} = Pauses.get({:ticket, "default", "issue-progress"})
    end
  end
end
