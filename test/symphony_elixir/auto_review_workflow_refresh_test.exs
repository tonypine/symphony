defmodule SymphonyElixir.AutoReviewWorkflowRefreshTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AutoReview, CiPoller, Paths, QaAgent, QaRunner, WorkflowSource}

  @repo_key "cycle"
  @kotlin "core/designsystem/src/main/kotlin/com/tonypine/cycle/MonthCalendar.kt"

  @git_env [
    {"GIT_AUTHOR_NAME", "Symphony Test"},
    {"GIT_AUTHOR_EMAIL", "symphony@example.com"},
    {"GIT_COMMITTER_NAME", "Symphony Test"},
    {"GIT_COMMITTER_EMAIL", "symphony@example.com"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"}
  ]

  @android_workflow """
  ---
  auto_review:
    playbooks:
      android_app:
        build: ./gradlew :app:assembleDebug
        apk_path: app/build/outputs/apk/debug/app-debug.apk
        application_ids: ["com.tonypine.cycle"]
  ---
  Cycle prompt
  """

  defmodule FakeTracker do
    def fetch_issues_by_states(_states), do: {:ok, Application.fetch_env!(:symphony_elixir, :refresh_test_issues)}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, Application.fetch_env!(:symphony_elixir, :refresh_test_issues)}

    def update_issue_state(issue_id, state) do
      send(Application.fetch_env!(:symphony_elixir, :refresh_test_recipient), {:issue_state_update, issue_id, state})
      :ok
    end

    def create_comment(_issue_id, _body), do: :ok
  end

  defmodule FakeGitHub do
    def fetch_ci_status(_pr_url, _opts), do: {:ok, Application.fetch_env!(:symphony_elixir, :refresh_test_ci_status)}
  end

  defmodule FakeQaAgent do
    def run(job, settings, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :refresh_test_recipient), {:qa_agent_run, job, settings})
      {:ok, %{result: %{verdict: :pass, summary: "The calendar renders.", steps: [], findings: []}, tokens: QaAgent.empty_tokens()}}
    end
  end

  # The real runner, under a name of this test's own.
  defmodule NamedQaRunner do
    def request(job, opts), do: QaRunner.request(job, Keyword.put(opts, :qa_runner_server, Application.fetch_env!(:symphony_elixir, :refresh_test_runner)))
  end

  setup do
    original_state_root = Application.get_env(:symphony_elixir, :state_root_override)
    root = Path.join(System.tmp_dir!(), "symphony-qa-workflow-refresh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Paths.set_state_root(Path.join(root, "state"))

    runner = :"qa_runner_#{System.unique_integer([:positive])}"
    run_fun = fn job, opts -> AutoReview.run_qa(job, Keyword.put(opts, :qa_agent, FakeQaAgent)) end
    start_supervised!({QaRunner, name: runner, run_fun: run_fun})

    Application.put_env(:symphony_elixir, :refresh_test_runner, runner)
    Application.put_env(:symphony_elixir, :refresh_test_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      restore_app_env(:state_root_override, original_state_root)

      for key <- [:refresh_test_runner, :refresh_test_recipient, :refresh_test_issues, :refresh_test_ci_status] do
        Application.delete_env(:symphony_elixir, key)
      end

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "a QA pass selects a playbook merged into the repo's WORKFLOW.md after its snapshot was written", %{root: root} do
    origin = Path.join(root, "origin.git")
    checkout = Path.join(root, "cycle")
    upstream = Path.join(root, "upstream")

    git!(root, ["init", "-q", "--bare", "-b", "main", origin])
    git!(root, ["clone", "-q", origin, checkout])
    File.write!(Path.join(checkout, "WORKFLOW.md"), "Cycle prompt\n")
    File.mkdir_p!(Path.join(checkout, Path.dirname(@kotlin)))
    File.write!(Path.join(checkout, @kotlin), "class MonthCalendar\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-q", "-m", "base"])
    git!(checkout, ["push", "-q", "origin", "HEAD:main"])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true},
      auto_review: %{enabled: true, android: %{avd: "Pixel_3a_API_34"}},
      repos: [%{key: @repo_key, workflow: Path.join(checkout, "WORKFLOW.md"), base_branch: "main", team: "Test", default: true}]
    )

    # Symphony's snapshot is taken (as at startup) before the playbook is merged and fetched.
    {:ok, repo} = Config.repo(@repo_key)
    assert WorkflowSource.refresh(repo) == :ok

    git!(root, ["clone", "-q", origin, upstream])
    File.write!(Path.join(upstream, "WORKFLOW.md"), @android_workflow)
    git!(upstream, ["commit", "-q", "-am", "Enable the android_app QA playbook"])
    git!(upstream, ["push", "-q", "origin", "HEAD:main"])

    assert Config.settings_for_repo!(@repo_key).auto_review.playbooks == %{}

    # The PR head changes Kotlin source.
    git!(checkout, ["checkout", "-q", "-b", "feature/month-calendar"])
    File.write!(Path.join(checkout, @kotlin), "class MonthCalendar(val weeks: Int)\n")
    git!(checkout, ["commit", "-q", "-am", "Month calendar"])
    sha = checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()

    issue = %Issue{
      id: "issue-mot-32",
      identifier: "MOT-32",
      title: "Design system: month calendar",
      state: "Auto Review",
      url: "https://linear.test/MOT-32",
      pr_urls: ["https://github.com/example/cycle/pull/27"],
      labels: []
    }

    Application.put_env(:symphony_elixir, :refresh_test_issues, [issue])
    Application.put_env(:symphony_elixir, :refresh_test_ci_status, green_status(sha))
    now = DateTime.utc_now()

    :ok =
      RunStore.put_run(%{
        repo_key: @repo_key,
        run_id: "run-mot-32",
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        status: "success",
        workspace_path: checkout,
        worker_host: nil,
        started_at: DateTime.add(now, -2, :minute),
        ended_at: DateTime.add(now, -1, :minute)
      })

    log =
      capture_log(fn ->
        poll_opts = [repo_key: @repo_key, tracker: FakeTracker, github: FakeGitHub, qa_runner: NamedQaRunner, now: now]
        assert {:ok, %{actions: [{:qa_started, "issue-mot-32", ^sha}]}} = CiPoller.poll_once(poll_opts)

        assert_receive {:qa_agent_run, %{playbooks: playbooks}, settings}, 5_000
        assert [%{kind: "android_app", application_ids: ["com.tonypine.cycle"]}] = playbooks
        assert %{"android_app" => %{"build" => "./gradlew :app:assembleDebug"}} = settings.auto_review.playbooks
        assert_receive {:issue_state_update, "issue-mot-32", "In Review"}, 5_000
      end)

    assert log =~ "QA selection issue_id=issue-mot-32 issue_identifier=MOT-32 sha=#{sha} decision=run playbooks=android_app"
    assert log =~ "workflow_refresh=:ok"
    assert Config.settings_for_repo!(@repo_key).auto_review.playbooks["android_app"]["apk_path"] == "app/build/outputs/apk/debug/app-debug.apk"
  end

  defp green_status(sha) do
    %{
      pr_url: "https://github.com/example/cycle/pull/27",
      pr_title: "Design system: month calendar",
      state: "OPEN",
      head_ref_name: "feature/month-calendar",
      is_cross_repository: false,
      head_repository: %{"nameWithOwner" => "example/cycle"},
      commit_sha: sha,
      checks: [%{name: "build", status: "COMPLETED", conclusion: "SUCCESS", run_id: "27"}]
    }
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], env: @git_env, stderr_to_stdout: true)
    output
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
