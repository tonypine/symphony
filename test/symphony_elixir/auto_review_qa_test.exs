defmodule SymphonyElixir.AutoReviewQaTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AgentRunner, AutoReview, CiPoller, QaAgent, QaRunner}

  @sha "feedface00112233445566778899aabbccddeeff"
  @repo_key "default"

  defmodule FakeQaAgent do
    def run(job, settings, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :qa_flow_recipient), {:qa_agent_run, job, settings})
      Application.fetch_env!(:symphony_elixir, :qa_flow_agent_result)
    end
  end

  defmodule FakeRunner do
    def request(job, opts) do
      send(Application.fetch_env!(:symphony_elixir, :qa_flow_recipient), {:qa_runner_request, job, opts})
      Application.fetch_env!(:symphony_elixir, :qa_flow_runner_result)
    end
  end

  defmodule UnusedSession do
    def start_session(_workspace, _opts), do: raise("a blocked web pass must not start the QA agent")
  end

  defmodule FailingTracker do
    def update_issue_state(issue_id, state) do
      send(Application.fetch_env!(:symphony_elixir, :qa_flow_recipient), {:failed_state_update, issue_id, state})
      {:error, :linear_down}
    end

    def fetch_issue_states_by_ids(_issue_ids), do: {:error, :linear_down}
  end

  defmodule FailingStore do
    def list_ci_checks(_repo_key), do: {:error, :disk_full}
    def put_run(_record), do: {:error, :disk_full}
    def update_run(_repo_key, _run_id, _attrs), do: {:error, :disk_full}
    def update_ci_check(_repo_key, _issue_id, _attrs), do: {:error, :disk_full}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true},
      auto_review: %{enabled: true, max_fix_attempts: 2}
    )

    Application.put_env(:symphony_elixir, :qa_flow_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      keys = ~w(qa_flow_recipient qa_flow_agent_result qa_flow_runner_result memory_tracker_recipient memory_tracker_issues)a

      for key <- keys do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    :ok
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-qa-flow",
        identifier: "TP-901",
        title: "Add `symphony check`",
        description: "Adds a check command.",
        state: "Auto Review",
        url: "https://linear.test/TP-901",
        labels: []
      },
      attrs
    )
  end

  defp put_record(attrs \\ %{}) do
    record =
      Map.merge(
        %{
          repo_key: @repo_key,
          issue_id: "issue-qa-flow",
          issue_identifier: "TP-901",
          pr_url: "https://github.com/example/repo/pull/901",
          workspace_path: "/tmp/workspaces/TP-901",
          worker_host: nil,
          status: "green"
        },
        attrs
      )

    :ok = RunStore.put_ci_check(record)
    record
  end

  defp stored_record, do: Enum.find(RunStore.list_ci_checks(), &(&1.issue_id == "issue-qa-flow"))

  defp git_with_paths(paths) do
    fn
      ["merge-base", "origin/" <> _base, @sha], "/tmp/workspaces/TP-901" -> {"base123\n", 0}
      ["diff", "--name-only", "base123", @sha], "/tmp/workspaces/TP-901" -> {Enum.join(paths, "\n") <> "\n", 0}
    end
  end

  defp job(record, attrs \\ %{}) do
    Map.merge(%{issue: issue(), record: record, sha: @sha, pr_url: record.pr_url, settings: Config.settings!()}, attrs)
  end

  defp pass_result do
    {:ok,
     %{
       result: %{
         verdict: :pass,
         summary: "`symphony check` validates the config.",
         steps: [%{name: "check a valid config", status: "pass", details: "$ bin/symphony check --config x.yml\nexit: 0\nConfig OK", evidence: ["https://uploads.linear.test/cli-transcript.md"]}],
         findings: []
       },
       tokens: %{QaAgent.empty_tokens() | total_tokens: 91_000, output_tokens: 4_000}
     }}
  end

  defp fail_result do
    {:ok,
     %{
       result: %{
         verdict: :fail,
         summary: "A broken config is accepted.",
         steps: [%{name: "check a broken config", status: "fail", details: "$ bin/symphony check --config bad.yml\nexit: 0", evidence: []}],
         findings: ["`symphony check --config bad.yml` exits 0; it should print the error and exit 1"]
       },
       tokens: %{QaAgent.empty_tokens() | total_tokens: 70_000}
     }}
  end

  describe "run_qa/2" do
    test "a CLI change that passes QA gets a report with the transcript and moves to In Review" do
      record = put_record()
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, pass_result())

      log =
        capture_log(fn ->
          assert {:auto_review_qa, "issue-qa-flow", :pass, "In Review"} =
                   AutoReview.run_qa(job(record), git: git_with_paths(["lib/symphony_elixir/cli.ex"]), qa_agent: FakeQaAgent)
        end)

      assert log =~ "QA selection issue_id=issue-qa-flow issue_identifier=TP-901 sha=#{@sha} decision=run playbooks=cli not_selected=\"macos_app: needs"
      assert log =~ "web: needs `verification.dev_server`\" workflow_refresh=:skipped"
      assert_receive {:qa_agent_run, agent_job, _settings}
      assert [%{kind: "cli"}] = agent_job.playbooks
      assert agent_job.token_limit == Config.settings!().agent.max_tokens_per_issue

      assert_receive {:memory_tracker_comment, "issue-qa-flow", report}
      assert report =~ "## Symphony QA Report"
      assert report =~ "**Verdict:** pass → In Review"
      assert report =~ "$ bin/symphony check --config x.yml"
      assert report =~ "https://uploads.linear.test/cli-transcript.md"
      assert_receive {:memory_tracker_state_update, "issue-qa-flow", "In Review"}

      assert %{qa_sha: @sha, qa_verdict: "pass", qa_passed: true, qa_applied: true, qa_fix_attempts: 0, qa_failure: nil} =
               stored_record()

      assert [%{kind: "qa", status: "qa_pass", head_sha: @sha, playbooks: ["cli"], tokens: %{total_tokens: 91_000}} = run] =
               RunStore.list_runs(@repo_key, :all)

      assert is_integer(run.runtime_seconds)
      assert run.ended_at
    end

    test "the report notes a verdict that took a follow-up turn" do
      record = put_record()
      {:ok, %{result: result} = run} = pass_result()
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, {:ok, %{run | result: Map.put(result, :follow_ups, 1)}})

      assert {:auto_review_qa, "issue-qa-flow", :pass, "In Review"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["lib/symphony_elixir/cli.ex"]), qa_agent: FakeQaAgent)

      assert_receive {:memory_tracker_comment, "issue-qa-flow", report}
      assert report =~ "· verdict after 1 follow-up"
    end

    test "the QA run starts with the QA profile and records its kind, model and effort" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        pr_review_mode: "polling",
        ci: %{enabled: true},
        agent_effort: "low",
        auto_review: %{enabled: true, max_fix_attempts: 2, model: "claude-haiku-4-5"}
      )

      record = put_record()
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, pass_result())

      AutoReview.run_qa(job(record), git: git_with_paths(["lib/symphony_elixir/cli.ex"]), qa_agent: FakeQaAgent)

      assert_receive {:qa_agent_run, %{run_profile: %{kind: :qa, model: "claude-haiku-4-5", effort: "low", provider: "anthropic"}}, _settings}
      assert [%{kind: "qa", run_kind: "qa", model: "claude-haiku-4-5", effort: "low"}] = RunStore.list_runs(@repo_key, :all)
    end

    test "a failing CLI behaviour returns to In Progress with the finding in the continuation prompt" do
      record = put_record()
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, fail_result())

      assert {:auto_review_qa, "issue-qa-flow", :fail, "In Progress"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["lib/symphony_elixir/cli.ex"]), qa_agent: FakeQaAgent)

      assert_receive {:memory_tracker_comment, "issue-qa-flow", report}
      assert report =~ "fail (fix attempt 1 of 2) → In Progress"
      assert_receive {:memory_tracker_state_update, "issue-qa-flow", "In Progress"}

      assert %{qa_fix_attempts: 1, qa_failure: %{commit_sha: @sha, findings: [finding]}} = stored_record()
      assert finding =~ "exits 0"

      prompt_opts = [repo_key: @repo_key, settings: Config.settings!()]
      prompt = AgentRunner.build_first_turn_prompt(issue(%{state: "In Progress"}), prompt_opts)
      assert prompt =~ "Auto Review QA failure:"
      assert prompt =~ "BEGIN UNTRUSTED QA FINDINGS"
      assert prompt =~ "`symphony check --config bad.yml` exits 0"

      assert :ok = CiPoller.complete_pending_qa_failure("issue-qa-flow")
      refute AgentRunner.build_first_turn_prompt(issue(), prompt_opts) =~ "Auto Review QA failure:"

      assert {:auto_review_qa, "issue-qa-flow", :fail, "In Progress"} =
               AutoReview.on_green(issue(), stored_record(), %{commit_sha: @sha}, Config.settings!(), [])

      prompt = AgentRunner.build_first_turn_prompt(issue(%{state: "In Progress"}), prompt_opts)
      assert prompt =~ "The fix run ended without pushing a commit"
      assert prompt =~ "`symphony check --config bad.yml` exits 0"
      refute prompt =~ "No findings were recorded."
    end

    test "a forced ticket that fails QA comes back for a fix exactly as an unforced one does" do
      record = put_record()
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, fail_result())
      forced_job = job(record, %{issue: issue(%{labels: ["expedite"]}), forced: true})

      assert {:auto_review_qa, "issue-qa-flow", :fail, "In Progress"} =
               AutoReview.run_qa(forced_job, git: git_with_paths(["lib/symphony_elixir/cli.ex"]), qa_agent: FakeQaAgent)

      assert_receive {:memory_tracker_comment, "issue-qa-flow", report}
      assert report =~ "fail (fix attempt 1 of 2) → In Progress"
      assert_receive {:memory_tracker_state_update, "issue-qa-flow", "In Progress"}
      assert %{qa_fix_attempts: 1, qa_failure: %{commit_sha: @sha, findings: [_finding]}} = stored_record()
    end

    test "a failure after max_fix_attempts escalates to In Review" do
      record = put_record(%{qa_fix_attempts: 2})
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, fail_result())

      assert {:auto_review_qa, "issue-qa-flow", :fail, "In Review"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)

      assert_receive {:memory_tracker_comment, _issue_id, report}
      assert report =~ "fix attempts used up"
      assert %{qa_failure: nil, qa_fix_attempts: 2} = stored_record()
    end

    test "a docs-only PR is skipped straight to In Review without an agent run" do
      record = put_record()

      log =
        capture_log(fn ->
          assert {:auto_review_qa, "issue-qa-flow", :skip, "In Review"} =
                   AutoReview.run_qa(job(record), git: git_with_paths(["README.md", "docs/configuration.md"]), qa_agent: FakeQaAgent)
        end)

      assert log =~ ~s(QA selection issue_id=issue-qa-flow issue_identifier=TP-901 sha=#{@sha} decision=skip reason="the PR only changes docs)
      assert log =~ ~s(not_selected="cli: not triggered; macos_app: needs)
      refute_receive {:qa_agent_run, _job, _settings}
      assert_receive {:memory_tracker_comment, _issue_id, report}
      assert report =~ "skipped → In Review"
      assert report =~ "only changes docs, tests"
      assert RunStore.list_runs(@repo_key, :all) == []
    end

    test "an internal lib refactor with no walkthrough and no entry-point change is skipped" do
      record = put_record()

      assert {:auto_review_qa, "issue-qa-flow", :skip, "In Review"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["lib/symphony_elixir/orchestrator.ex"]), qa_agent: FakeQaAgent)

      refute_receive {:qa_agent_run, _job, _settings}
      assert_receive {:memory_tracker_comment, _issue_id, report}
      assert report =~ "no QA playbook applies"
    end

    test "keeps the settings it was started with when the repo's workflow can't be read" do
      record = put_record(%{repo_key: "removed"})
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, pass_result())
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | playbooks: %{"cli" => %{"paths" => ["scripts/**"]}}}}

      job = job(record, %{settings: settings})
      opts = [git: git_with_paths(["scripts/release"]), qa_agent: FakeQaAgent]
      log = capture_log(fn -> assert {:auto_review_qa, _id, :pass, "In Review"} = AutoReview.run_qa(job, opts) end)

      assert_receive {:qa_agent_run, %{playbooks: [%{kind: "cli", paths: ["scripts/**"]}]}, ^settings}
      assert log =~ ~s(workflow_refresh={:error, {:unknown_repo_key, "removed"}})
    end

    test "run_on first_pass skips QA once a push has passed" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", auto_review: %{enabled: true, run_on: "first_pass"})
      record = put_record(%{qa_passed: true})

      assert {:auto_review_qa, _issue_id, :skip, "In Review"} = AutoReview.run_qa(job(record), qa_agent: FakeQaAgent)
      assert_receive {:memory_tracker_comment, _issue_id, report}
      assert report =~ "run_on: first_pass"
    end

    test "lists changed files with git against the repository's base branch" do
      repo = Path.join(System.tmp_dir!(), "qa-flow-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf(repo) end)

      git! = fn args ->
        {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
        String.trim(output)
      end

      git!.(["init", "--quiet", "--initial-branch=main"])
      git!.(["config", "user.email", "qa@example.test"])
      git!.(["config", "user.name", "QA"])
      File.write!(Path.join(repo, "lib.ex"), "defmodule A do\nend\n")
      git!.(["add", "."])
      git!.(["commit", "--quiet", "-m", "base"])
      git!.(["update-ref", "refs/remotes/origin/main", "HEAD"])
      File.write!(Path.join(repo, "README.md"), "docs\n")
      git!.(["add", "."])
      git!.(["commit", "--quiet", "-m", "docs"])
      head = git!.(["rev-parse", "HEAD"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        auto_review: %{enabled: true},
        repos: [
          %{
            "name" => @repo_key,
            "path" => Path.dirname(Workflow.workflow_file_path()),
            "workflow" => Path.basename(Workflow.workflow_file_path()),
            "team" => "Test",
            "base_branch" => "main"
          }
        ]
      )

      record = put_record(%{workspace_path: repo})

      assert {:auto_review_qa, _issue_id, :skip, "In Review"} =
               AutoReview.run_qa(job(record, %{sha: head}), qa_agent: FakeQaAgent)

      assert_receive {:memory_tracker_comment, _issue_id, report}
      assert report =~ "only changes docs, tests"
    end

    test "a blocked verdict only a person can clear goes to Human Review, one an agent can fix to In Review" do
      blocked = fn needs_person ->
        result = %{verdict: :blocked, summary: "No OpenRouter key.", steps: [], findings: [], reason: "OPENROUTER_API_KEY is not set"}
        result = if needs_person, do: Map.put(result, :needs_person, true), else: result
        {:ok, %{result: result, tokens: QaAgent.empty_tokens()}}
      end

      Application.put_env(:symphony_elixir, :qa_flow_agent_result, blocked.(true))
      record = put_record()

      assert {:auto_review_qa, "issue-qa-flow", :blocked, "Human Review"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)

      assert_receive {:memory_tracker_comment, "issue-qa-flow", report}
      assert report =~ "**Verdict:** blocked → Human Review"
      assert_receive {:memory_tracker_state_update, "issue-qa-flow", "Human Review"}
      assert %{qa_verdict: "blocked", qa_target_state: "Human Review", qa_applied: true} = stored_record()

      Application.put_env(:symphony_elixir, :qa_flow_agent_result, blocked.(false))
      record = put_record()

      assert {:auto_review_qa, "issue-qa-flow", :blocked, "In Review"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)

      # A pass that names a person is still the supervisor's to review.
      {:ok, %{result: result} = run} = pass_result()
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, {:ok, %{run | result: Map.put(result, :needs_person, true)}})
      record = put_record()

      assert {:auto_review_qa, "issue-qa-flow", :pass, "In Review"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)
    end

    test "with human_review: null, a blocked verdict that needs a person goes to In Review" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_human_review_state: nil,
        pr_review_mode: "polling",
        ci: %{enabled: true},
        auto_review: %{enabled: true, max_fix_attempts: 2}
      )

      result = %{verdict: :blocked, summary: "", steps: [], findings: [], reason: "no key", needs_person: true}
      run = %{result: result, tokens: QaAgent.empty_tokens()}
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, {:ok, run})
      record = put_record()

      assert {:auto_review_qa, "issue-qa-flow", :blocked, "In Review"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)
    end

    test "agent errors and unreadable diffs are reported as blocked" do
      for {error, text} <- [
            {{:qa_token_limit, 600, 500}, "per-issue token limit (600 of 500 tokens)"},
            {{:remote_worker_unsupported, "w1"}, "remote workers"},
            {{:malformed_qa_response, :invalid_verdict}, "could not be read"},
            {:boom, "could not finish: :boom"}
          ] do
        record = put_record()
        Application.put_env(:symphony_elixir, :qa_flow_agent_result, {:error, error, QaAgent.empty_tokens()})

        assert {:auto_review_qa, _issue_id, :blocked, "In Review"} =
                 AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)

        assert_receive {:memory_tracker_comment, _issue_id, report}
        assert report =~ text
      end

      record = put_record()
      git = fn _args, _cwd -> {"fatal: bad object", 128} end

      assert {:auto_review_qa, _issue_id, :blocked, "In Review"} =
               AutoReview.run_qa(job(record), git: git, qa_agent: FakeQaAgent)

      assert_receive {:memory_tracker_comment, _issue_id, report}
      assert report =~ "could not list the PR's changed files"
    end

    test "a pass that hits the usage limit stores no verdict, keeps the issue in Auto Review and runs again once the hold lifts" do
      record = put_record()
      on_exit(fn -> RunStore.put_usage_limits(%{}) end)
      resets_at = DateTime.add(DateTime.utc_now(), 3600)
      # The QA agent runs Codex here, so its limit is the openai one.
      info = %{provider: "openai", scope: :all, window: "primary", resets_at: resets_at, source: :rate_limit_event}
      error = {:qa_agent_failed, {:usage_limited, info}}
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, {:error, error, QaAgent.empty_tokens()})
      resume_at = DateTime.add(resets_at, 120)
      test_pid = self()

      hold = fn held_info, identifier ->
        send(test_pid, {:usage_limit_hold, held_info, identifier})
        entry = %{provider: "openai", scope: :all, resume_at: resume_at}
        :ok = RunStore.put_usage_limits(%{{"openai", :all} => entry})
        {:ok, entry}
      end

      assert {:qa_usage_limited, "issue-qa-flow", ^resume_at} =
               AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent, usage_limit_hold: hold)

      assert_receive {:usage_limit_hold, ^info, "TP-901"}
      refute_received {:memory_tracker_comment, _issue_id, _report}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      refute Map.get(stored_record(), :qa_verdict)
      assert [%{kind: "qa", status: "qa_usage_limited", error: "the QA agent hit the openai primary limit"}] = RunStore.list_runs(@repo_key, :all)

      # The next green poll waits for the hold, then asks for the same pass again.
      settings = Config.settings!()
      ci_status = %{commit_sha: @sha, pr_url: nil}

      assert {:qa_waiting, "issue-qa-flow", :usage_limited} =
               AutoReview.on_green(issue(), stored_record(), ci_status, settings, qa_runner: FakeRunner)

      refute_received {:qa_runner_request, _job, _opts}

      :ok = RunStore.put_usage_limits(%{})
      Application.put_env(:symphony_elixir, :qa_flow_runner_result, :started)

      assert {:qa_started, "issue-qa-flow", @sha} =
               AutoReview.on_green(issue(), stored_record(), ci_status, settings, qa_runner: FakeRunner)

      assert_receive {:qa_runner_request, %{sha: @sha}, _opts}
    end

    test "a usage-limited pass whose hold could not be recorded still stores no verdict" do
      record = put_record()
      error = {:usage_limited, %{provider: "anthropic", scope: :all, window: "five_hour"}}
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, {:error, error, QaAgent.empty_tokens()})

      log =
        capture_log(fn ->
          # No orchestrator runs in this test, so the hold has nowhere to go.
          assert {:qa_usage_limited, "issue-qa-flow", nil} =
                   AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)
        end)

      assert log =~ "the hold was not recorded: :unavailable"
      refute_received {:memory_tracker_comment, _issue_id, _report}
      refute Map.get(stored_record(), :qa_verdict)
    end

    test "with auto_pause off, a usage-limited pass is blocked like any other agent error" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        pr_review_mode: "polling",
        ci: %{enabled: true},
        agent_usage_limit: %{auto_pause: false},
        auto_review: %{enabled: true, max_fix_attempts: 2}
      )

      record = put_record()
      error = {:qa_agent_failed, {:usage_limited, %{provider: "anthropic", scope: :all, window: "five_hour"}}}
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, {:error, error, QaAgent.empty_tokens()})

      no_hold = fn _info, _identifier -> flunk("a usage limit must not be held with auto_pause off") end

      opts = [git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent, usage_limit_hold: no_hold]
      assert {:auto_review_qa, "issue-qa-flow", :blocked, "In Review"} = AutoReview.run_qa(job(record), opts)

      assert_receive {:memory_tracker_comment, _issue_id, report}
      assert report =~ "could not finish: {:qa_agent_failed, {:usage_limited"
    end

    test "a dashboard change whose dev server fails its health check is blocked, not failed" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        pr_review_mode: "polling",
        ci: %{enabled: true},
        auto_review: %{enabled: true, max_fix_attempts: 2},
        verification: %{
          enabled: true,
          port_allocation: %{range: [4190, 4199]},
          dev_server: %{
            start_cmd: "sleep 1",
            health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state",
            health_timeout_ms: 50,
            stop_timeout_ms: 100
          }
        }
      )

      stop_verification_port_pool()
      on_exit(&stop_verification_port_pool/0)
      record = put_record()
      paths = ["lib/symphony_elixir_web/live/dashboard_live.ex"]

      git = fn
        ["worktree", "add", "--detach", path, @sha], _cwd ->
          File.mkdir_p!(path)
          {"", 0}

        args, cwd when hd(args) in ["merge-base", "diff"] ->
          git_with_paths(paths).(args, cwd)

        _args, _cwd ->
          {"", 0}
      end

      assert {:auto_review_qa, "issue-qa-flow", :blocked, "In Review"} =
               AutoReview.run_qa(job(record), git: git, qa_agent_module: __MODULE__.UnusedSession)

      assert_receive {:memory_tracker_comment, "issue-qa-flow", report}
      assert report =~ "**Verdict:** blocked → In Review"
      assert report =~ "playbooks: web"
      assert report =~ "the dev server failed its health check, so the web playbook could not run"
      assert %{qa_verdict: "blocked", qa_failure: nil} = stored_record()
      refute Map.has_key?(stored_record(), :qa_fix_attempts)
      assert [%{status: "released", release_reason: "qa dev server did not start"}] = RunStore.list_verification_allocations()
    end

    test "other dev server and browser server errors are blocked with their cause" do
      for {error, text} <- [
            {{:qa_dev_server_failed, :exhausted}, "the dev server did not start: :exhausted"},
            {{:qa_browser_mcp_invalid, "url can't be blank"}, "`auto_review.playbooks.web.browser_mcp` is invalid: url can't be blank"},
            {{:qa_browser_mcp_unavailable, :no_npx}, "`npx` (Node.js) is not on Symphony's PATH"},
            {{:qa_browser_mcp_unavailable, "@playwright/mcp@0.0.83"}, "`@playwright/mcp@0.0.83` is not installed on the Symphony host; run `npx -y @playwright/mcp@0.0.83 --version` there once"}
          ] do
        record = put_record()
        Application.put_env(:symphony_elixir, :qa_flow_agent_result, {:error, error, QaAgent.empty_tokens()})

        assert {:auto_review_qa, _issue_id, :blocked, "In Review"} =
                 AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)

        assert_receive {:memory_tracker_comment, _issue_id, report}
        assert report =~ text
      end
    end

    test "store, report and tracker failures are logged and the move is retried later" do
      record = put_record()
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, pass_result())
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", auto_review: %{enabled: true})

      log =
        capture_log(fn ->
          assert {:state_transition_error, "issue-qa-flow", :auto_review, :linear_down} =
                   AutoReview.run_qa(job(record),
                     git: git_with_paths(["bin/symphony"]),
                     qa_agent: FakeQaAgent,
                     run_store: FailingStore,
                     tracker: FailingTracker,
                     linear_client: fn _query, _variables, _opts -> {:error, :linear_down} end
                   )
        end)

      assert log =~ "Failed to store the QA run"
      assert log =~ "Failed to update the QA run"
      assert log =~ "Failed to store the QA result"
      assert log =~ "Failed to publish the QA report for TP-901"
      assert log =~ "Failed to move TP-901 to In Review after QA"
      assert_receive {:failed_state_update, "issue-qa-flow", "In Review"}
    end

    test "a pass that ends after its issue moved to Merging or Done writes its report and leaves the state alone" do
      for state <- ["Merging", "Done"] do
        record = put_record(%{last_observed_sha: @sha, pr_state: "OPEN"})
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{state: state})])
        Application.put_env(:symphony_elixir, :qa_flow_agent_result, {:error, :adb_offline, QaAgent.empty_tokens()})

        log =
          capture_log([level: :info], fn ->
            assert {:auto_review_qa_not_applied, "issue-qa-flow", :blocked, reason} =
                     AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)

            assert reason == "the issue moved to #{state}"
          end)

        assert log =~ "QA outcome not applied: the issue moved to #{state} issue_id=issue-qa-flow issue_identifier=TP-901 verdict=blocked"
        assert_receive {:memory_tracker_comment, "issue-qa-flow", report}
        assert report =~ "**Verdict:** blocked → no move (the issue moved to #{state})"
        assert report =~ ":adb_offline"
        refute_received {:memory_tracker_state_update, _issue_id, _state}
        refute Map.has_key?(stored_record(), :qa_verdict)
        assert Enum.any?(RunStore.list_runs(@repo_key, :all), &(&1.status == "qa_blocked"))
      end
    end

    test "a pass whose PR merged, closed or got a new head while it ran leaves the state alone" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, fail_result())

      for {attrs, reason} <- [
            {%{pr_state: "MERGED"}, "the PR is merged"},
            {%{pr_state: "closed"}, "the PR is closed"},
            {%{pr_state: "OPEN", last_observed_sha: "0123456789abcdef0123"}, "the PR head moved to `0123456789ab`"}
          ] do
        record = put_record(attrs)

        assert {:auto_review_qa_not_applied, "issue-qa-flow", :fail, ^reason} =
                 AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)

        assert_receive {:memory_tracker_comment, "issue-qa-flow", report}
        assert report =~ "**Verdict:** fail → no move (#{reason})"
        refute_received {:memory_tracker_state_update, _issue_id, _state}
        refute Map.has_key?(stored_record(), :qa_failure)
      end
    end

    test "a pass on an issue still in Auto Review on the tested head applies its outcome as before" do
      record = put_record(%{last_observed_sha: @sha, pr_state: "OPEN"})
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{state: " auto review "})])
      Application.put_env(:symphony_elixir, :qa_flow_agent_result, fail_result())

      assert {:auto_review_qa, "issue-qa-flow", :fail, "In Progress"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["bin/symphony"]), qa_agent: FakeQaAgent)

      assert_receive {:memory_tracker_comment, "issue-qa-flow", report}
      assert report =~ "**Verdict:** fail (fix attempt 1 of 2) → In Progress"
      assert_receive {:memory_tracker_state_update, "issue-qa-flow", "In Progress"}
      assert %{qa_sha: @sha, qa_verdict: "fail", qa_applied: true, qa_fix_attempts: 1} = stored_record()
    end
  end

  describe "on_green/5" do
    test "asks the runner for a pass and maps its answer" do
      record = put_record()
      settings = Config.settings!()

      for {answer, action} <- [
            {:started, {:qa_started, "issue-qa-flow", @sha}},
            {:running, {:qa_running, "issue-qa-flow"}},
            {:busy, {:qa_queued, "issue-qa-flow"}},
            {{:error, :qa_runner_unavailable}, {:qa_request_error, "issue-qa-flow", :qa_runner_unavailable}}
          ] do
        Application.put_env(:symphony_elixir, :qa_flow_runner_result, answer)
        ci_status = %{commit_sha: @sha, pr_url: nil}
        assert AutoReview.on_green(issue(), record, ci_status, settings, qa_runner: FakeRunner, now: 1) == action
        assert_receive {:qa_runner_request, %{sha: @sha, pr_url: "https://github.com/example/repo/pull/901", forced: false}, runner_opts}
        refute Keyword.has_key?(runner_opts, :now)
      end

      Application.put_env(:symphony_elixir, :qa_flow_runner_result, :busy)

      assert {:qa_queued, "issue-qa-flow"} =
               AutoReview.on_green(issue(%{labels: ["Expedite"]}), record, %{commit_sha: @sha}, settings, qa_runner: FakeRunner)

      assert_receive {:qa_runner_request, %{forced: true}, _runner_opts}
    end

    test "a forced parent's current sub-ticket waits at the front, then starts on the forced allowance with every QA slot busy" do
      test_pid = self()

      # The orchestrator's published snapshot names the issue as a forced parent's current part.
      owner =
        spawn(fn ->
          :ets.new(:symphony_orchestrator_snapshot, [:named_table, :public, read_concurrency: true])

          snapshot = %{
            running: [],
            forced: [
              %{issue_id: "epic-other", sub_issue: nil},
              %{issue_id: "epic-1", sub_issue: %{issue_id: "issue-qa-flow", identifier: "TP-901", state: "Auto Review"}}
            ]
          }

          :ets.insert(:symphony_orchestrator_snapshot, {:current, snapshot, System.monotonic_time(:millisecond), System.system_time(:millisecond)})
          Process.register(self(), SymphonyElixir.Orchestrator)
          send(test_pid, :snapshot_published)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :snapshot_published

      on_exit(fn ->
        ref = Process.monitor(owner)
        send(owner, :stop)
        assert_receive {:DOWN, ^ref, :process, ^owner, _reason}
      end)

      run_fun = fn job, _opts ->
        send(test_pid, {:pass_started, job.issue.id, self()})

        receive do
          :finish -> :ok
        end
      end

      start_supervised!({QaRunner, run_fun: run_fun})
      record = put_record()
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | max_concurrent: 1}, agent: %{settings.agent | forced_max: 0}}

      normal = %{issue: issue(%{id: "normal", identifier: "TP-902"}), record: record, sha: @sha, settings: settings}
      assert :started = QaRunner.request(normal)
      assert_receive {:pass_started, "normal", normal_pid}

      # No forced allowance left: the pass waits at the front of the queue.
      assert {:qa_queued, "issue-qa-flow"} = AutoReview.on_green(issue(), record, %{commit_sha: @sha}, settings, [])
      assert %{queued: [%{issue_id: "issue-qa-flow", forced: true}]} = QaRunner.snapshot()

      settings = %{settings | agent: %{settings.agent | forced_max: 1}}

      log =
        capture_log(fn ->
          assert {:qa_started, "issue-qa-flow", @sha} = AutoReview.on_green(issue(), record, %{commit_sha: @sha}, settings, [])
        end)

      assert_receive {:pass_started, "issue-qa-flow", forced_pid}
      assert log =~ "QA pass started on the forced allowance issue_id=issue-qa-flow issue_identifier=TP-901 sha=#{@sha} forced=true"
      assert %{running: [%{issue_id: "issue-qa-flow", forced: true}, %{issue_id: "normal", forced: false}]} = QaRunner.snapshot()

      for pid <- [normal_pid, forced_pid], do: send(pid, :finish)

      assert {:qa_waiting, "issue-qa-flow", :missing_head_sha} =
               AutoReview.on_green(issue(), record, %{commit_sha: nil}, settings, [])
    end

    test "waits without asking the runner while the QA provider is held by a usage limit" do
      record = put_record()
      # The QA agent runs Codex here, so only the openai hold applies to it.
      settings = Config.settings!()
      on_exit(fn -> RunStore.put_usage_limits(%{}) end)
      resume_at = DateTime.add(DateTime.utc_now(), 3600)
      :ok = RunStore.put_usage_limits(%{{"openai", :all} => %{provider: "openai", scope: :all, resume_at: resume_at}})

      assert {:qa_waiting, "issue-qa-flow", :usage_limited} =
               AutoReview.on_green(issue(), record, %{commit_sha: @sha, pr_url: nil}, settings, qa_runner: FakeRunner)

      refute_received {:qa_runner_request, _job, _opts}

      :ok = RunStore.put_usage_limits(%{{"anthropic", :all} => %{provider: "anthropic", scope: :all, resume_at: resume_at}})
      Application.put_env(:symphony_elixir, :qa_flow_runner_result, :started)

      assert {:qa_started, "issue-qa-flow", @sha} =
               AutoReview.on_green(issue(), record, %{commit_sha: @sha, pr_url: nil}, settings, qa_runner: FakeRunner)
    end

    test "re-applies a stored verdict and counts a return without a new commit as another failed attempt" do
      settings = Config.settings!()
      record = put_record(%{qa_sha: @sha, qa_verdict: "blocked", qa_target_state: "In Review", qa_applied: false})

      assert {:auto_review_qa, "issue-qa-flow", :blocked, "In Review"} =
               AutoReview.on_green(issue(), record, %{commit_sha: @sha}, settings, [])

      assert_receive {:memory_tracker_state_update, "issue-qa-flow", "In Review"}

      record =
        put_record(%{
          qa_sha: @sha,
          qa_verdict: "fail",
          qa_target_state: "In Progress",
          qa_applied: true,
          qa_fix_attempts: 1,
          qa_failure: %{findings: ["still broken"]}
        })

      assert {:auto_review_qa, "issue-qa-flow", :fail, "In Progress"} =
               AutoReview.on_green(issue(), record, %{commit_sha: @sha}, settings, [])

      assert_receive {:memory_tracker_comment, _issue_id, report}
      assert report =~ "fix attempt 2 of 2"
      assert report =~ "still broken"
      assert %{qa_fix_attempts: 2} = stored_record()
    end
  end

  describe "QaRunner" do
    test "runs one pass per issue up to max_concurrent and forgets finished passes" do
      test_pid = self()
      name = :"qa_runner_#{System.unique_integer([:positive])}"

      run_fun = fn job, opts ->
        send(test_pid, {:pass_started, job.issue.id, self(), opts})

        receive do
          :finish -> :ok
          :crash -> exit(:boom)
        end
      end

      start_supervised!({QaRunner, name: name, run_fun: run_fun})
      settings = Config.settings!()
      job = %{issue: issue(), record: %{workspace_path: "/workspaces/symphony/TP-901", repo_key: "symphony"}, sha: @sha, settings: settings}

      assert :started = QaRunner.request(job, qa_runner_server: name, tracker: :fake)
      assert_receive {:pass_started, "issue-qa-flow", pass_pid, [tracker: :fake]}
      assert QaRunner.running(name) == %{"issue-qa-flow" => @sha}
      worktree = QaAgent.worktree_path(settings, "symphony", "TP-901", @sha)
      assert QaRunner.workspaces(name) == ["/workspaces/symphony/TP-901", worktree | QaAgent.tmp_dirs(worktree)]
      assert :running = QaRunner.request(job, qa_runner_server: name)
      assert :busy = QaRunner.request(%{job | issue: issue(%{id: "other", identifier: "TP-902"})}, qa_runner_server: name)
      assert QaRunner.queued_passes(name) == [%{issue_id: "other", identifier: "TP-902", waiting_on: :max_concurrent}]

      send(pass_pid, :finish)
      wait_until(fn -> QaRunner.running(name) == %{} end)
      assert QaRunner.workspaces(name) == []

      log =
        capture_log(fn ->
          assert :started = QaRunner.request(job, qa_runner_server: name)
          assert_receive {:pass_started, _issue_id, crash_pid, _opts}
          send(crash_pid, :crash)
          wait_until(fn -> QaRunner.running(name) == %{} end)
        end)

      assert log =~ "QA pass crashed issue_id=issue-qa-flow"

      send(name, :unrelated)
      send(name, {:DOWN, make_ref(), :process, self(), :normal})
      assert QaRunner.running(name) == %{}
    end

    test "uses the default server name and reports a task that cannot start" do
      job = %{issue: issue(), record: %{}, sha: @sha, settings: Config.settings!()}

      assert {:error, :qa_runner_unavailable} = QaRunner.request(job)
      assert QaRunner.running() == %{}
      assert QaRunner.workspaces() == []

      {:ok, pid} = QaRunner.start_link()
      assert QaRunner.running() == %{}
      GenServer.stop(pid)

      supervisor = start_supervised!({Task.Supervisor, max_children: 0})
      name = :"qa_runner_#{System.unique_integer([:positive])}"
      start_supervised!({QaRunner, name: name, task_supervisor: supervisor})

      assert {:error, :max_children} = QaRunner.request(job, qa_runner_server: name)
      assert QaRunner.running(name) == %{}
    end

    test "caps passes at finishing_max and remembers queued issues until they start or go quiet" do
      test_pid = self()
      name = :"qa_runner_#{System.unique_integer([:positive])}"

      run_fun = fn job, _opts ->
        send(test_pid, {:pass_started, job.issue.id, self()})

        receive do
          :finish -> :ok
        end
      end

      start_supervised!({QaRunner, name: name, run_fun: run_fun})
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | max_concurrent: 5}, agent: %{settings.agent | finishing_max: 1}}
      job = %{issue: issue(), record: %{}, sha: @sha, settings: settings}

      assert :started = QaRunner.request(job, qa_runner_server: name)
      assert_receive {:pass_started, "issue-qa-flow", pass_pid}
      assert :busy = QaRunner.request(%{job | issue: issue(%{id: "other", identifier: "TP-902"})}, qa_runner_server: name)
      assert QaRunner.queued(name) == ["other"]
      assert QaRunner.queued_passes(name) == [%{issue_id: "other", identifier: "TP-902", waiting_on: :finishing_max}]

      send(pass_pid, :finish)
      wait_until(fn -> QaRunner.running(name) == %{} end)
      assert :started = QaRunner.request(%{job | issue: issue(%{id: "other"})}, qa_runner_server: name)
      assert QaRunner.queued(name) == []

      quiet = :"qa_runner_#{System.unique_integer([:positive])}"
      start_supervised!({QaRunner, name: quiet, run_fun: run_fun, queued_ttl_ms: 0}, id: quiet)
      assert :started = QaRunner.request(job, qa_runner_server: quiet)
      assert :busy = QaRunner.request(%{job | issue: issue(%{id: "other"})}, qa_runner_server: quiet)
      assert QaRunner.queued(quiet) == []
      assert QaRunner.queued_passes(quiet) == []
      assert QaRunner.queued(:missing_qa_runner) == []
      assert QaRunner.queued_passes(:missing_qa_runner) == []
    end

    test "with every slot busy a forced pass starts on the forced allowance and the next forced one goes to the front" do
      test_pid = self()
      name = :"qa_runner_#{System.unique_integer([:positive])}"

      run_fun = fn job, _opts ->
        send(test_pid, {:pass_started, job.issue.id, self()})

        receive do
          :finish -> :ok
        end
      end

      start_supervised!({QaRunner, name: name, run_fun: run_fun})
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | max_concurrent: 1}, agent: %{settings.agent | finishing_max: 2, forced_max: 1}}
      job = fn id, forced? -> %{issue: issue(%{id: id, identifier: String.upcase(id)}), record: %{}, sha: @sha, settings: settings, forced: forced?} end

      assert :started = QaRunner.request(job.("normal", false), qa_runner_server: name)
      assert_receive {:pass_started, "normal", normal_pid}
      assert :busy = QaRunner.request(job.("waiting", false), qa_runner_server: name)

      log =
        capture_log(fn ->
          assert :started = QaRunner.request(job.("forced", true), qa_runner_server: name)
        end)

      assert_receive {:pass_started, "forced", _forced_pid}
      assert log =~ "QA pass started on the forced allowance issue_id=forced issue_identifier=FORCED sha=#{@sha} forced=true"
      assert Process.alive?(normal_pid)
      assert %{running: [%{issue_id: "forced", forced: true}, %{issue_id: "normal", forced: false}]} = QaRunner.snapshot(name)

      # The allowance is taken: a second forced ticket gets no extra pass, but goes to the front.
      assert :busy = QaRunner.request(job.("forced-2", true), qa_runner_server: name)

      assert QaRunner.snapshot(name) == %{
               running: [
                 %{issue_id: "forced", identifier: "FORCED", sha: @sha, forced: true},
                 %{issue_id: "normal", identifier: "NORMAL", sha: @sha, forced: false}
               ],
               queued: [
                 %{issue_id: "forced-2", identifier: "FORCED-2", forced: true},
                 %{issue_id: "waiting", identifier: "WAITING", forced: false}
               ]
             }

      send(normal_pid, :finish)
      wait_until(fn -> map_size(QaRunner.running(name)) == 1 end)

      assert :busy = QaRunner.request(job.("waiting", false), qa_runner_server: name)
      assert :started = QaRunner.request(job.("forced-2", true), qa_runner_server: name)
      assert_receive {:pass_started, "forced-2", _pid}
      assert %{running: [%{issue_id: "forced", forced: true}, %{issue_id: "forced-2", forced: false}]} = QaRunner.snapshot(name)
      assert QaRunner.queued(name) == ["waiting"]
      assert QaRunner.snapshot(:missing_qa_runner) == %{running: [], queued: []}
    end

    test "a forced pass waits at the front when the orchestrator's forced runs use forced_max" do
      test_pid = self()
      name = :"qa_runner_#{System.unique_integer([:positive])}"

      run_fun = fn job, _opts ->
        send(test_pid, {:pass_started, job.issue.id, self()})

        receive do
          :finish -> :ok
        end
      end

      # The orchestrator's published snapshot shows one forced run.
      owner =
        spawn(fn ->
          :ets.new(:symphony_orchestrator_snapshot, [:named_table, :public, read_concurrency: true])
          snapshot = %{running: [%{issue_id: "forced-agent", forced: true}, %{issue_id: "agent", forced: false}]}
          :ets.insert(:symphony_orchestrator_snapshot, {:current, snapshot, System.monotonic_time(:millisecond), System.system_time(:millisecond)})
          Process.register(self(), SymphonyElixir.Orchestrator)
          send(test_pid, :snapshot_published)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :snapshot_published

      on_exit(fn ->
        ref = Process.monitor(owner)
        send(owner, :stop)
        assert_receive {:DOWN, ^ref, :process, ^owner, _reason}
      end)

      start_supervised!({QaRunner, name: name, run_fun: run_fun})
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | max_concurrent: 1}, agent: %{settings.agent | forced_max: 1}}

      job = fn id, forced? ->
        %{issue: issue(%{id: id}), record: %{}, sha: @sha, settings: settings, forced: forced?}
      end

      assert :started = QaRunner.request(job.("normal", false), qa_runner_server: name)
      assert_receive {:pass_started, "normal", normal_pid}
      assert :busy = QaRunner.request(job.("forced", true), qa_runner_server: name)
      assert QaRunner.running(name) == %{"normal" => @sha}
      assert %{queued: [%{issue_id: "forced", forced: true}]} = QaRunner.snapshot(name)

      send(normal_pid, :finish)
      wait_until(fn -> QaRunner.running(name) == %{} end)

      assert :busy = QaRunner.request(job.("other", false), qa_runner_server: name)
      assert :started = QaRunner.request(job.("forced", true), qa_runner_server: name)
      assert_receive {:pass_started, "forced", _pid}
      assert %{running: [%{issue_id: "forced", forced: false}]} = QaRunner.snapshot(name)
    end

    test "a forced request that stopped asking no longer holds a free slot" do
      test_pid = self()
      name = :"qa_runner_#{System.unique_integer([:positive])}"

      run_fun = fn job, _opts ->
        send(test_pid, {:pass_started, job.issue.id, self()})

        receive do
          :finish -> :ok
        end
      end

      start_supervised!({QaRunner, name: name, run_fun: run_fun, forced_hold_ms: 0, forced_runs_fun: fn -> 0 end})
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | max_concurrent: 1}, agent: %{settings.agent | forced_max: 0}}

      job = fn id, forced? ->
        %{issue: issue(%{id: id}), record: %{}, sha: @sha, settings: settings, forced: forced?}
      end

      assert :started = QaRunner.request(job.("normal", false), qa_runner_server: name)
      assert_receive {:pass_started, "normal", normal_pid}
      assert :busy = QaRunner.request(job.("forced", true), qa_runner_server: name)

      send(normal_pid, :finish)
      wait_until(fn -> QaRunner.running(name) == %{} end)

      # The forced ticket has not asked again within the hold, so the free slot goes to the next request.
      assert :started = QaRunner.request(job.("other", false), qa_runner_server: name)
      assert_receive {:pass_started, "other", _pid}
      assert %{queued: [%{issue_id: "forced", forced: true}]} = QaRunner.snapshot(name)
    end

    test "reports an unavailable runner" do
      assert {:error, :qa_runner_unavailable} =
               QaRunner.request(%{issue: issue()}, qa_runner_server: :missing_qa_runner)

      assert QaRunner.running(:missing_qa_runner) == %{}
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
