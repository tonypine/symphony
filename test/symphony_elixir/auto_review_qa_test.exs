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

  defmodule FailingTracker do
    def update_issue_state(issue_id, state) do
      send(Application.fetch_env!(:symphony_elixir, :qa_flow_recipient), {:failed_state_update, issue_id, state})
      {:error, :linear_down}
    end
  end

  defmodule FailingStore do
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
      for key <- [:qa_flow_recipient, :qa_flow_agent_result, :qa_flow_runner_result, :memory_tracker_recipient] do
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

      assert {:auto_review_qa, "issue-qa-flow", :pass, "In Review"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["lib/symphony_elixir/cli.ex"]), qa_agent: FakeQaAgent)

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

      assert {:auto_review_qa, "issue-qa-flow", :skip, "In Review"} =
               AutoReview.run_qa(job(record), git: git_with_paths(["README.md", "docs/configuration.md"]), qa_agent: FakeQaAgent)

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
        assert_receive {:qa_runner_request, %{sha: @sha, pr_url: "https://github.com/example/repo/pull/901"}, runner_opts}
        refute Keyword.has_key?(runner_opts, :now)
      end

      assert {:qa_waiting, "issue-qa-flow", :missing_head_sha} =
               AutoReview.on_green(issue(), record, %{commit_sha: nil}, settings, [])
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
      job = %{issue: issue(), record: %{}, sha: @sha, settings: settings}

      assert :started = QaRunner.request(job, qa_runner_server: name, tracker: :fake)
      assert_receive {:pass_started, "issue-qa-flow", pass_pid, [tracker: :fake]}
      assert QaRunner.running(name) == %{"issue-qa-flow" => @sha}
      assert :running = QaRunner.request(job, qa_runner_server: name)
      assert :busy = QaRunner.request(%{job | issue: issue(%{id: "other"})}, qa_runner_server: name)

      send(pass_pid, :finish)
      wait_until(fn -> QaRunner.running(name) == %{} end)

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

      {:ok, pid} = QaRunner.start_link()
      assert QaRunner.running() == %{}
      GenServer.stop(pid)

      supervisor = start_supervised!({Task.Supervisor, max_children: 0})
      name = :"qa_runner_#{System.unique_integer([:positive])}"
      start_supervised!({QaRunner, name: name, task_supervisor: supervisor})

      assert {:error, :max_children} = QaRunner.request(job, qa_runner_server: name)
      assert QaRunner.running(name) == %{}
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
