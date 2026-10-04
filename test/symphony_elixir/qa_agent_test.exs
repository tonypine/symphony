defmodule SymphonyElixir.QaAgentTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.LeftoverProcesses.Table
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.QaAgent.{Report, Selection}

  @sha "0123456789abcdef0123456789abcdef01234567"
  @env_keys [
    :qa_test_recipient,
    :qa_test_start_result,
    :qa_test_messages,
    :qa_test_turn_result,
    :qa_test_turn_results,
    :qa_test_dev_server_result
  ]

  defmodule FakeSession do
    def start_session(workspace, opts) do
      send(recipient(), {:qa_session_started, workspace, opts})

      case Application.get_env(:symphony_elixir, :qa_test_start_result) do
        nil -> {:ok, %{workspace: workspace}}
        result -> result
      end
    end

    def run_turn(session, prompt, issue, opts) do
      send(recipient(), {:qa_turn, session, prompt, issue, opts})
      on_message = Keyword.fetch!(opts, :on_message)
      Enum.each(Application.get_env(:symphony_elixir, :qa_test_messages, []), on_message)

      # `:qa_test_turn_results` answers successive turns; the last answer repeats.
      case Application.get_env(:symphony_elixir, :qa_test_turn_results) do
        [result | [_ | _] = rest] ->
          Application.put_env(:symphony_elixir, :qa_test_turn_results, rest)
          result

        [result] ->
          result

        nil ->
          Application.get_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: pass_json()}})
      end
    end

    def stop_session(session) do
      send(recipient(), {:qa_session_stopped, session})
      :ok
    end

    def pass_json do
      Jason.encode!(%{
        verdict: "pass",
        summary: "The CLI behaves as described.",
        steps: [%{name: "symphony check", status: "pass", details: "$ bin/symphony check\nexit: 0", evidence: ["https://uploads.linear.test/t.md"]}]
      })
    end

    defp recipient, do: Application.fetch_env!(:symphony_elixir, :qa_test_recipient)
  end

  # Stands in for `SymphonyElixir.Verification` in web passes.
  defmodule FakeVerification do
    def start_qa_dev_server(issue, run_id, worktree, opts) do
      send(recipient(), {:dev_server_started, issue.identifier, run_id, worktree, opts})

      case Application.get_env(:symphony_elixir, :qa_test_dev_server_result) do
        nil -> {:ok, %{context: %{run_id: run_id}, pid: self(), port: 4321, url: "http://localhost:4321/"}}
        result -> result
      end
    end

    def stop_qa_dev_server(dev_server) do
      send(recipient(), {:dev_server_stopped, dev_server.port})
      :ok
    end

    defp recipient, do: Application.fetch_env!(:symphony_elixir, :qa_test_recipient)
  end

  # Starts `setsid nohup sleep` in the worktree, outside the agent's process group.
  defmodule DetachingSession do
    def start_session(workspace, opts) do
      pid = SymphonyElixir.QaAgentTest.detached_sleep(workspace)
      send(Application.fetch_env!(:symphony_elixir, :qa_test_recipient), {:detached, pid})
      FakeSession.start_session(workspace, opts)
    end

    defdelegate run_turn(session, prompt, issue, opts), to: FakeSession
    defdelegate stop_session(session), to: FakeSession
  end

  # Exports the PR to `$TMPDIR/qa/checkout` and starts a detached `sleep` there, outside the
  # worktree, as the TP-413 pass did with `./bin/symphony`.
  defmodule TmpDirDetachingSession do
    def start_session(workspace, opts) do
      tmp_dir = Path.join(Map.fetch!(opts[:extra_env], "TMPDIR"), "qa")
      checkout = Path.join(tmp_dir, "checkout")
      File.mkdir_p!(checkout)
      pid = SymphonyElixir.QaAgentTest.detached_sleep(checkout)
      send(Application.fetch_env!(:symphony_elixir, :qa_test_recipient), {:detached, pid, checkout})
      FakeSession.start_session(workspace, opts)
    end

    defdelegate run_turn(session, prompt, issue, opts), to: FakeSession
    defdelegate stop_session(session), to: FakeSession
  end

  @doc false
  def detached_sleep(cwd) do
    script = ~S"""
    nohup perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec "sleep", "600"' >/dev/null 2>&1 &
    echo $!
    """

    {pid, 0} = System.cmd("sh", ["-c", script], cd: cwd)
    String.to_integer(String.trim(pid))
  end

  defp base_tmp_dir(base) do
    [tmp_dir] = QaAgent.tmp_dirs(QaAgent.worktree_path(Config.settings!(), "default", "TP-900", @sha), [base])
    tmp_dir
  end

  # A zombie waiting for init to reap it counts as gone.
  defp running?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_output, _status} -> false
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :qa_test_recipient, self())

    on_exit(fn ->
      for key <- @env_keys do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    :ok
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-qa",
        identifier: "TP-900",
        title: "Add a check command",
        description: "Adds `symphony check`.",
        state: "Auto Review",
        labels: []
      },
      attrs
    )
  end

  defp playbooks, do: Selection.playbooks(%{playbooks: %{}})

  defp job(attrs \\ %{}) do
    Map.merge(
      %{
        issue: issue(),
        sha: @sha,
        workspace_path: Path.join(System.tmp_dir!(), "qa-agent-test-workspace"),
        worker_host: nil,
        repo_key: "default",
        run_id: "qa-run-1",
        playbooks: playbooks(),
        token_limit: nil
      },
      attrs
    )
  end

  # Records each git call and creates the worktree directory on `worktree add`.
  defp fake_git(overrides \\ %{}) do
    recipient = self()

    fn args, cwd ->
      send(recipient, {:git, args, cwd})

      case {args, overrides} do
        {["worktree", "add", "--detach", path, _sha], %{add_dev_server: result}} ->
          add_unless_dev_server(path, result)

        {["worktree", "add", "--detach", path, _sha], %{add: result}} ->
          File.mkdir_p!(path)
          result

        {["worktree", "add", "--detach", path, _sha], _overrides} ->
          File.mkdir_p!(path)
          {"", 0}

        {["cat-file" | _rest], %{cat_file: result}} ->
          result

        {["fetch" | _rest], %{fetch: result}} ->
          result

        _other ->
          {"", 0}
      end
    end
  end

  defp add_unless_dev_server(path, result) do
    if String.ends_with?(path, "-dev-server") do
      result
    else
      File.mkdir_p!(path)
      {"", 0}
    end
  end

  describe "Selection.decide/4" do
    test "skips an internal lib refactor with no walkthrough or entry-point change" do
      assert {:skip, reason} =
               Selection.decide(issue(), ["lib/symphony_elixir/orchestrator.ex", "lib/symphony_elixir/run_store.ex"], %{playbooks: %{}})

      assert reason =~ "no QA playbook applies"
    end

    test "skips docs-only and test-only changes, including configured skip globs" do
      assert {:skip, reason} = Selection.decide(issue(), ["README.md", "docs/configuration.md", "test/foo_test.exs"], %{})
      assert reason =~ "only changes docs, tests"

      assert {:skip, _reason} = Selection.decide(issue(), ["priv/static/app.css"], %{skip_globs: ["priv/static/**"]})
      assert {:skip, "the PR changes no files"} = Selection.decide(issue(), [], %{})
    end

    test "selects the cli playbook for entry points and for a user walkthrough" do
      for path <- ["bin/symphony", "lib/symphony_elixir/cli.ex", "lib/mix/tasks/symphony.init.ex"] do
        assert {:run, [%{kind: "cli", prompt: prompt}]} = Selection.decide(issue(), [path], %{playbooks: %{}})
        assert prompt =~ "### Playbook: cli"
      end

      walkthrough = issue(%{description: "Intro\n\n## User walkthrough\n\n1. Run `symphony check`."})
      assert Selection.user_walkthrough?(walkthrough)
      refute Selection.user_walkthrough?(issue(%{description: nil}))
      assert {:run, [%{kind: "cli"}]} = Selection.decide(walkthrough, ["lib/symphony_elixir/orchestrator.ex"], %{})
    end

    test "labels skip QA or force a playbook" do
      assert {:skip, "the issue has the `qa:skip` label"} =
               Selection.decide(issue(%{labels: [" QA:Skip "]}), ["lib/symphony_elixir/cli.ex"], %{})

      assert {:run, [%{kind: "cli"}]} = Selection.decide(issue(%{labels: ["qa:cli"]}), ["README.md"], %{})
    end

    test "config overrides built-in paths, disables playbooks and adds new kinds" do
      config = %{
        playbooks: %{
          :cli => %{"paths" => ["scripts/**"]},
          "api" => %{paths: ["api/**"], prompt: "### Playbook: api"},
          "empty" => %{paths: ["x/**"], prompt: "  "},
          "odd" => "not a map"
        }
      }

      assert [%{kind: "cli", paths: ["scripts/**"]}, %{kind: "api", paths: ["api/**"]}] = Selection.playbooks(config)
      assert {:run, [%{kind: "api"}]} = Selection.decide(issue(), ["api/app.js"], config)
      assert {:skip, _reason} = Selection.decide(issue(), ["lib/symphony_elixir/cli.ex"], config)

      assert [] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false, "paths" => "bin/**"}}})
    end

    test "the macos_app playbook runs only when its build command and app bundle are configured" do
      swift = ["macos/Sources/SymphonyBar/SettingsView.swift"]

      refute Enum.any?(Selection.playbooks(%{playbooks: %{}}), &(&1.kind == "macos_app"))
      assert {:skip, _reason} = Selection.decide(issue(), swift, %{playbooks: %{}})
      assert [] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app"}}})

      config = %{
        playbooks: %{
          "macos_app" => %{"build" => "make -C macos app", "app" => "macos/build/Symphony.app", "build_timeout_ms" => 600_000}
        }
      }

      assert {:run, [%{kind: "macos_app", build: "make -C macos app", app: "macos/build/Symphony.app", build_timeout_ms: 600_000, prompt: prompt}]} =
               Selection.decide(issue(), swift, config)

      assert prompt =~ "### Playbook: macos_app"
      assert prompt =~ "wait about 10 seconds"
      assert prompt =~ "qa_permission_missing"

      assert {:run, [%{kind: "macos_app"}]} = Selection.decide(issue(%{labels: ["qa:macos_app"]}), ["README.md"], config)
      assert {:skip, _reason} = Selection.decide(issue(), ["macos/Tests/SymphonyBarCoreTests/QAModeTests.swift"], config)

      odd_timeout = put_in(config, [:playbooks, "macos_app", "build_timeout_ms"], "soon")
      assert [_cli, %{kind: "macos_app", build_timeout_ms: nil}] = Selection.playbooks(odd_timeout)
    end

    test "the web playbook runs only when the verification dev server is configured" do
      dashboard = ["lib/symphony_elixir_web/live/dashboard_live.ex", "priv/static/dashboard.css"]

      refute Enum.any?(Selection.playbooks(%{playbooks: %{}}), &(&1.kind == "web"))
      assert {:skip, _reason} = Selection.decide(issue(), dashboard, %{playbooks: %{}})

      assert {:run, [%{kind: "web", prompt: prompt} = web]} = Selection.decide(issue(), dashboard, %{playbooks: %{}}, dev_server?: true)
      refute Map.has_key?(web, :browser_mcp)
      assert prompt =~ "### Playbook: web"
      assert prompt =~ "browser_console_messages"
      assert prompt =~ "qa-evidence/console.md"

      for path <- ["lib/my_app_web.ex", "assets/js/app.tsx", "src/components/Card.vue"] do
        assert {:run, [%{kind: "web"}]} = Selection.decide(issue(), [path], %{}, dev_server?: true)
      end

      assert {:run, [%{kind: "web"}]} = Selection.decide(issue(%{labels: ["qa:web"]}), ["README.md"], %{}, dev_server?: true)

      glance = %{playbooks: %{"web" => %{browser_mcp: %{command: "glance-mcp", args: ["--headless"]}}}}

      assert [_cli, %{kind: "web", browser_mcp: %{"command" => "glance-mcp", "args" => ["--headless"]}}] =
               Selection.playbooks(glance, dev_server?: true)

      assert [_cli] = Selection.playbooks(%{playbooks: %{"web" => %{"enabled" => false}}}, dev_server?: true)
    end

    test "glob matching keeps single stars inside one directory" do
      assert Selection.glob_match?("lib/mix/tasks/a/b.ex", "lib/mix/tasks/**")
      assert Selection.glob_match?("a.md", "**/*.md")
      assert Selection.glob_match?("docs/x/a.md", "**/*.md")
      refute Selection.glob_match?("lib/a/b.ex", "lib/*.ex")
      assert Selection.glob_match?("lib/a.ex", "lib/?.ex")
      refute Selection.glob_match?("lib/a+b.ex", "lib/a.b.ex")
    end
  end

  describe "parse_response/1" do
    test "reads pass, fail and blocked verdicts with steps" do
      assert {:ok, %{verdict: :pass, summary: "The CLI behaves as described.", steps: [step], findings: []}} =
               QaAgent.parse_response("Done.\n```json\n" <> FakeSession.pass_json() <> "\n```")

      assert step == %{name: "symphony check", status: "pass", details: "$ bin/symphony check\nexit: 0", evidence: ["https://uploads.linear.test/t.md"]}

      fail = ~s({"verdict":"fail","steps":[{"name":"bad config","status":"fail","details":"exit 0"}]})
      assert {:ok, %{verdict: :fail, summary: "", findings: []} = result} = QaAgent.parse_response(fail)
      assert QaAgent.failure_findings(result) == ["bad config: exit 0"]

      with_findings = ~s({"verdict":"fail","findings":["exit status is 0", " "],"steps":null})
      assert {:ok, %{findings: ["exit status is 0"], steps: []} = result} = QaAgent.parse_response(with_findings)
      assert QaAgent.failure_findings(result) == ["exit status is 0"]

      assert {:ok, %{verdict: :blocked, reason: "mix is missing"}} = QaAgent.parse_response(~s({"verdict":"blocked","reason":" mix is missing "}))
    end

    test "rejects answers that do not follow the contract" do
      for {text, reason} <- [
            {"no json here", :no_verdict_object},
            {~s({"other": 1}), :no_verdict_object},
            {~s({"verdict":"maybe"}), :invalid_verdict},
            {~s({"verdict":"pass","steps":"all good"}), :invalid_steps},
            {~s({"verdict":"pass","steps":[{"name":"x","status":"great"}]}), :invalid_steps},
            {~s({"verdict":"pass","steps":[{"name":" ","status":"pass"}]}), :invalid_steps},
            {~s({"verdict":"fail","findings":[]}), :missing_fail_findings},
            {~s({"verdict":"blocked","reason":""}), :missing_blocked_reason}
          ] do
        assert {:error, {:malformed_qa_response, ^reason}} = QaAgent.parse_response(text)
      end

      assert {:error, {:malformed_qa_response, :empty_response}} = QaAgent.parse_response(nil)
    end
  end

  describe "prompt/2 and settings" do
    test "includes the ticket, the parent's criteria and the playbooks" do
      prompt = QaAgent.prompt(job(), %{"identifier" => "TP-243", "title" => "Parent", "description" => "- [ ] parent criterion"})

      assert prompt =~ "TP-900"
      assert prompt =~ "Adds `symphony check`."
      assert prompt =~ "Parent issue (this is a sub-ticket"
      assert prompt =~ "- [ ] parent criterion"
      assert prompt =~ ~r/<linear_issue_title>\s*Parent\s*<\/linear_issue_title>/
      assert prompt =~ ~r/<linear_issue_body>\s*- \[ \] parent criterion\s*<\/linear_issue_body>/
      assert prompt =~ "### Playbook: cli"
      assert prompt =~ @sha
      assert prompt =~ ~s("verdict": "pass" | "fail" | "blocked")
      assert prompt =~ "Ending your turn ends the session"
      assert prompt =~ ~r/Do not leave\s+work running in the background/

      refute QaAgent.prompt(job(%{issue: issue(%{title: nil, description: nil})}), nil) =~ "Parent issue"
    end

    test "a parent walkthrough tests the parent at the base branch head against the verification checklist" do
      verification = issue(%{id: "issue-fv", identifier: "TP-910", title: "Final verification: Parent", description: "- [ ] child criterion"})
      parent = issue(%{id: "issue-parent", identifier: "TP-243", title: "Parent", description: "## User walkthrough\n1. Run it"})
      prompt = QaAgent.prompt(job(%{issue: parent, verification_issue: verification, base_ref: "origin/main"}), nil)

      assert prompt =~ "running the parent walkthrough"
      assert prompt =~ "TP-910 asks for a final check"
      assert prompt =~ "checked out at `#{@sha}`,\nthe head of `origin/main`"
      assert prompt =~ "Identifier: TP-243"
      assert prompt =~ "Verification checklist (TP-910, the parent's final verification sub-ticket)"
      assert prompt =~ ~r/<linear_issue_body>\s*- \[ \] child criterion\s*<\/linear_issue_body>/
      assert prompt =~ "so a follow-up ticket can fix it"
      refute prompt =~ "The executor agent opened a PR"
      refute prompt =~ "Parent issue (this is a sub-ticket"

      untitled = issue(%{identifier: "TP-911", title: nil, description: nil})
      assert QaAgent.prompt(job(%{issue: parent, verification_issue: untitled, base_ref: "origin/main"}), nil) =~ "Verification checklist (TP-911"
      assert QaAgent.prompt(job(), nil) =~ "so the executor can fix it"
    end

    test "a walkthrough with cli and macos_app keeps running the CLI checks when the app part is blocked" do
      config = %{playbooks: %{"macos_app" => %{"build" => "make -C macos app", "app" => "macos/build/Symphony.app"}}}
      assert [%{kind: "cli"}, %{kind: "macos_app"}] = playbooks = Selection.playbooks(config)

      verification = issue(%{id: "issue-fv", identifier: "TP-910", title: "Final verification: Parent", description: "- [ ] child criterion"})
      parent = issue(%{id: "issue-parent", identifier: "TP-243", title: "Parent", description: "- [ ] parent criterion"})
      prompt = QaAgent.prompt(job(%{issue: parent, verification_issue: verification, base_ref: "origin/main", playbooks: playbooks}), nil)

      assert prompt =~ "### Playbook: cli"
      assert prompt =~ ~r/When one playbook is blocked, mark its steps `blocked` and continue with the other playbooks'\s+steps: report `pass` or `fail` for every step that could run\./
      assert prompt =~ ~r/The verdict stays `blocked` while\s+any step is blocked/
      assert prompt =~ ~r/When a tool returns `qa_permission_missing`, stop this playbook: mark each app step you\s+could not check `blocked`/
      assert prompt =~ ~r/continue with the\s+steps of the other playbooks offered to you \(such as `cli` or `web`\) and report each of\s+them as `pass` or `fail`/
      refute prompt =~ "stop and answer `blocked`"
    end

    test "QA prompts and built-in playbooks leave the test suite to CI" do
      parent = issue(%{id: "issue-parent", identifier: "TP-243", title: "Parent", description: "- [ ] parent criterion"})
      verification = issue(%{id: "issue-fv", identifier: "TP-910", title: "Final verification: Parent", description: "- [ ] child criterion"})

      pr_prompt = QaAgent.prompt(job(), nil)
      assert pr_prompt =~ ~r/Do not run the test suite, `make all`, coverage or static analysis such as Dialyzer: CI already\s+ran them green on this PR head/

      walkthrough = QaAgent.prompt(job(%{issue: parent, verification_issue: verification, base_ref: "origin/main"}), nil)
      assert walkthrough =~ ~r/Do not run the test suite, `make all`, coverage or static analysis such as Dialyzer: CI runs\s+them on every merge to `origin\/main`/
      refute walkthrough =~ "covered by CI on"
      refute walkthrough =~ "ran them green on this PR head"

      macos_app = %{build: "make app", app: "build/App.app"}
      built_ins = Selection.playbooks(%{playbooks: %{macos_app: macos_app}}, dev_server?: true)
      assert Enum.map(built_ins, & &1.kind) == ["cli", "macos_app", "web"]

      for %{kind: kind, prompt: prompt} <- built_ins do
        assert prompt =~ ~r/Do not run the project's test suite, `make all`, coverage or (Dialyzer|static analysis): CI already\s+ran them/,
               "#{kind} playbook must leave the test suite to CI"
      end
    end

    test "a parent walkthrough judges test, coverage and CI criteria by CI's run on the base branch head" do
      parent = issue(%{id: "issue-parent", identifier: "TP-243", title: "Parent", description: "- [ ] make all is green"})
      verification = issue(%{id: "issue-fv", identifier: "TP-910", title: "Final verification: Parent", description: "- [ ] CI is green"})
      walkthrough = QaAgent.prompt(job(%{issue: parent, verification_issue: verification, base_ref: "origin/main"}), nil)

      [_intro, rule] = String.split(walkthrough, "Do not run the test suite", parts: 2)
      [rule, _rest] = String.split(rule, "Write every artifact", parts: 2)

      assert "Do not run the test suite" <> rule == """
             Do not run the test suite, `make all`, coverage or static analysis such as Dialyzer: CI runs
             them on every merge to `origin/main`. Judge a criterion that asks for tests, coverage or CI to
             pass by CI's runs on `#{@sha}`, the commit you are on:

             - Read the runs with `gh run list --commit #{@sha} --json databaseId,workflowName,status,conclusion,url`
               where `gh` is allowed, else through GitHub's public API:
               `curl -fsS "https://api.github.com/repos/<owner>/<repo>/actions/runs?head_sha=#{@sha}"`, with
               `<owner>/<repo>` from `git remote get-url origin`.
             - Every run completed with conclusion `success`: mark the criterion `pass` and put each run's URL
               and conclusion in `details`.
             - A run failed (any conclusion other than `success`, `skipped` or `neutral`): mark the criterion
               `fail`, and in `details` and `findings` name the failing workflow and job (`gh run view <id>
               --json jobs`, or the run's `jobs_url`) with the run URL. A red `origin/main` is a defect.
             - Mark it `skipped` only when no run can be read (the commands are refused, or CI has no run for
               this commit) or a run is still in progress, and say which in `details`, with the run URL when
               there is one.

             Build only what you need to use the feature, and judge it by what a user sees.

             """

      refute QaAgent.prompt(job(), nil) =~ "actions/runs"
    end

    test "a parent walkthrough does not look up the parent of the parent" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      linear_client = fn query, _variables, _opts -> flunk("unexpected Linear query: #{query}") end
      walkthrough = job(%{issue: issue(%{identifier: "TP-243"}), verification_issue: issue(%{identifier: "TP-910"}), base_ref: "origin/main"})

      assert {:ok, _result} = QaAgent.run(walkthrough, Config.settings!(), git: fake_git(), qa_agent_module: FakeSession, linear_client: linear_client)
      assert_receive {:qa_turn, _session, prompt, %Issue{identifier: "TP-243"}, _opts}
      assert prompt =~ "Verification checklist (TP-910"
    end

    test "QA settings take the auto_review runtime, turns and timeout" do
      write_workflow_file!(Workflow.workflow_file_path(),
        auto_review: %{runtime: "codex", command: "codex app-server", max_turns: 3, timeout_ms: 5_000}
      )

      settings = QaAgent.qa_settings(Config.settings!())

      assert %{kind: "codex", command: "codex app-server", max_turns: 3, turn_timeout_ms: 5_000} = settings.agent

      write_workflow_file!(Workflow.workflow_file_path())
      base = Config.settings!()
      assert QaAgent.qa_settings(base).agent.command == base.agent.command
    end

    test "worktrees live under the workspace root, outside the repository directories" do
      settings = Config.settings!()
      path = QaAgent.worktree_path(settings, nil, nil, @sha)

      assert path == Path.join([Path.expand(settings.workspace.root), ".qa", "default", "issue-0123456789ab"])
    end
  end

  describe "run/3" do
    test "runs the agent in a detached worktree with the QA tool scope and cleans up" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [
        %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 100, "output_tokens" => 20, "total_tokens" => 120}}},
        %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 300, "output_tokens" => 50, "total_tokens" => 350}}},
        %{event: :notification, payload: %{"method" => "other"}}
      ])

      forwarded = self()
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)
      workspace = job().workspace_path

      assert {:ok, %{result: %{verdict: :pass}, tokens: tokens}} =
               QaAgent.run(job(), settings,
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 on_message: &send(forwarded, {:forwarded, &1})
               )

      assert tokens.total_tokens == 350
      assert tokens.output_tokens == 50
      assert_receive {:git, ["worktree", "remove", "--force", ^worktree], ^workspace}
      assert_receive {:git, ["cat-file", "-e", _object], ^workspace}
      assert_receive {:git, ["worktree", "add", "--detach", ^worktree, @sha], ^workspace}
      assert_receive {:qa_session_started, ^worktree, session_opts}
      assert session_opts[:tool_scope] == :qa
      assert_receive {:qa_turn, _session, prompt, %Issue{id: "issue-qa"}, _opts}
      assert prompt =~ "### Playbook: cli"
      assert_receive {:forwarded, _message}
      assert_receive {:qa_session_stopped, _session}
      refute File.exists?(worktree)
    end

    test "stops processes left running under the worktree before removing it" do
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)
      test_pid = self()
      left = %{pid: 4242, start_time: "Sat Oct  3 08:00:00 2026", command: "sleep 600", cwd: worktree}
      unrelated = %{left | pid: 4343, cwd: System.tmp_dir!()}
      {:ok, reads} = Agent.start_link(fn -> [{:ok, [left, unrelated]}, {:ok, [unrelated]}] end)

      leftover_processes = [
        table: fn -> Agent.get_and_update(reads, fn [next | rest] -> {next, rest} end) end,
        signal: fn pid, signal -> send(test_pid, {:signal, pid, signal, File.exists?(worktree)}) end
      ]

      log =
        capture_log(fn ->
          assert {:ok, %{result: %{verdict: :pass}}} =
                   QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, leftover_processes: leftover_processes)
        end)

      assert_received {:signal, 4242, "TERM", true}
      refute_received {:signal, 4343, _signal, _exists}
      assert log =~ "Stopping leftover process issue_id=issue-qa issue_identifier=TP-900 pid=4242 cwd=#{worktree}"
    end

    @tag :process_table
    test "a detached process started in the worktree is gone once the pass ends" do
      unrelated = detached_sleep(System.tmp_dir!())
      on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(unrelated)]) end)

      log =
        capture_log(fn ->
          assert {:ok, %{result: %{verdict: :pass}}} =
                   QaAgent.run(job(), Config.settings!(),
                     git: fake_git(),
                     qa_agent_module: DetachingSession,
                     leftover_processes: [table: &Table.read/0, grace_ms: 2_000]
                   )
        end)

      assert_received {:detached, left}
      refute running?(left)
      assert log =~ "Stopping leftover process issue_id=issue-qa issue_identifier=TP-900 pid=#{left} "
      assert running?(unrelated)
      refute log =~ "pid=#{unrelated} "
    end

    @tag :process_table
    test "a detached process started under the pass's $TMPDIR, outside the worktree, is gone once the pass ends" do
      # Another session's process in the shared temp folder, as another run or Tony's own.
      shared = Path.join(System.tmp_dir!(), "qa-agent-test-shared/qa/checkout")
      File.mkdir_p!(shared)
      unrelated = detached_sleep(shared)

      on_exit(fn ->
        System.cmd("kill", ["-KILL", Integer.to_string(unrelated)])
        File.rm_rf(Path.join(System.tmp_dir!(), "qa-agent-test-shared"))
      end)

      worktree = QaAgent.worktree_path(Config.settings!(), "default", "TP-900", @sha)

      log =
        capture_log(fn ->
          assert {:ok, %{result: %{verdict: :pass}}} =
                   QaAgent.run(job(), Config.settings!(),
                     git: fake_git(),
                     qa_agent_module: TmpDirDetachingSession,
                     leftover_processes: [table: &Table.read/0, grace_ms: 2_000]
                   )
        end)

      assert_received {:detached, left, checkout}
      refute String.starts_with?(checkout, worktree)
      refute running?(left)
      assert log =~ "Stopping leftover process issue_id=issue-qa issue_identifier=TP-900 pid=#{left} "
      assert running?(unrelated)
      refute log =~ "pid=#{unrelated} "
      refute File.exists?(checkout)
    end

    test "gives the agent a private temp folder of its own, stops what runs under it and removes it" do
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)
      base = Path.join(System.tmp_dir!(), "qa-agent-test-tmp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      [tmp_dir] = QaAgent.tmp_dirs(worktree, [base])
      # A folder left by an interrupted pass doesn't carry over.
      File.mkdir_p!(Path.join(tmp_dir, "stale"))
      test_pid = self()
      left = %{pid: 4242, start_time: "Sun Oct  4 08:00:00 2026", command: "./bin/symphony --port 47413", cwd: Path.join(tmp_dir, "qa/checkout")}
      shared = %{left | pid: 4343, cwd: Path.join(System.tmp_dir!(), "qa/checkout")}
      {:ok, reads} = Agent.start_link(fn -> [{:ok, [left, shared]}, {:ok, [shared]}] end)

      leftover_processes = [
        table: fn -> Agent.get_and_update(reads, fn [next | rest] -> {next, rest} end) end,
        signal: fn pid, signal -> send(test_pid, {:signal, pid, signal}) end
      ]

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, tmp_bases: [base], leftover_processes: leftover_processes)

      assert_received {:qa_session_started, ^worktree, session_opts}
      assert session_opts[:extra_env] == %{"TMPDIR" => tmp_dir}
      assert List.last(session_opts[:settings].workspace.sandbox.allow_write_paths) == tmp_dir
      assert String.length(tmp_dir) == String.length(base) + String.length("/symphony-qa-") + 12
      assert_received {:signal, 4242, "TERM"}
      refute_received {:signal, 4343, _signal}
      refute File.exists?(tmp_dir)
    end

    test "makes the temp folder private and falls back to the next base when one can't hold it" do
      base = Path.join(System.tmp_dir!(), "qa-agent-test-tmp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      not_a_dir = Path.join(base, "file")
      File.write!(not_a_dir, "")
      test_pid = self()

      assert {:ok, _result} =
               QaAgent.run(job(), Config.settings!(),
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 tmp_bases: [not_a_dir, base],
                 leftover_processes: [
                   table: fn ->
                     send(test_pid, {:mode, File.stat!(base_tmp_dir(base)).mode})
                     {:ok, []}
                   end
                 ]
               )

      assert_received {:qa_session_started, _worktree, session_opts}
      assert %{"TMPDIR" => tmp_dir} = session_opts[:extra_env]
      assert Path.dirname(tmp_dir) == base
      assert_received {:mode, mode}
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    test "gives a Claude pass its temp folder as CLAUDE_CODE_TMPDIR" do
      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{runtime: "claude"})
      base = Path.join(System.tmp_dir!(), "qa-agent-test-tmp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      assert {:ok, _result} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession, tmp_bases: [base], leftover_processes: [table: fn -> {:ok, []} end])

      assert_received {:qa_session_started, _worktree, session_opts}
      assert %{"CLAUDE_CODE_TMPDIR" => tmp_dir} = session_opts[:extra_env]
      refute Map.has_key?(session_opts[:extra_env], "TMPDIR")
      assert Path.dirname(tmp_dir) == base
    end

    test "is blocked without starting the agent when no temp folder can be made" do
      not_a_dir = Path.join(System.tmp_dir!(), "qa-agent-test-file-#{System.unique_integer([:positive])}")
      File.write!(not_a_dir, "")
      on_exit(fn -> File.rm(not_a_dir) end)
      worktree = QaAgent.worktree_path(Config.settings!(), "default", "TP-900", @sha)
      [tmp_dir] = QaAgent.tmp_dirs(worktree, [not_a_dir])

      assert {:error, {:qa_tmp_dir_failed, [^tmp_dir]}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession, tmp_bases: [not_a_dir])

      refute_received {:qa_session_started, _worktree, _opts}
      refute File.exists?(worktree)
    end

    test "gives a macos_app pass a QA driver and stops it when the pass ends" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 qa_driver_opts: [host: %{kill: fn _pid -> :ok end}]
               )

      assert_receive {:qa_session_started, _worktree, session_opts}
      driver = session_opts[:qa_driver]
      assert is_pid(driver)
      assert_receive {:qa_turn, _session, prompt, _issue, turn_opts}
      assert turn_opts[:qa_driver] == driver
      assert prompt =~ "### Playbook: macos_app"
      refute Process.alive?(driver)

      assert {:ok, _result} = QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
      assert_receive {:qa_session_started, _worktree, cli_opts}
      assert cli_opts[:qa_driver] == nil
    end

    test "gives a web pass the dev server and a browser MCP server limited to localhost, then stops the server" do
      [web] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}}}, dev_server?: true)
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{playbooks: [web]}), settings,
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 verification: FakeVerification,
                 npx: fake_npx({"Version 0.0.83\n", 0})
               )

      assert_receive {:npx, ["--no", "@playwright/mcp@0.0.83", "--version"]}
      server_worktree = worktree <> "-dev-server"
      workspace = job().workspace_path
      assert_receive {:git, ["worktree", "add", "--detach", ^server_worktree, @sha], ^workspace}
      assert_receive {:dev_server_started, "TP-900", "qa-run-1", ^server_worktree, start_opts}
      assert start_opts[:repo_key] == "default"
      assert start_opts[:settings] == settings
      assert_receive {:qa_session_started, ^worktree, session_opts}
      assert %{servers: %{"browser" => browser}} = session_opts[:settings].agent.mcp
      assert browser.command == "npx"
      assert browser.runtimes == [settings.agent.kind]

      assert ["--no", "@playwright/mcp@0.0.83", "--browser", "chromium", "--headless", "--isolated", "--allowed-origins", origins, "--output-dir", output] =
               browser.args

      assert origins == "http://localhost:4321;http://127.0.0.1:4321"
      assert QaAgent.playwright_mcp_package() == "@playwright/mcp@0.0.83"
      refute Enum.any?(browser.args, &String.contains?(&1, "@latest"))
      assert output == Path.join(worktree, "qa-evidence")
      assert settings.agent.network_access.mode == "allowlist"
      assert ["localhost", "127.0.0.1"] -- session_opts[:settings].agent.network_access.allowed_domains == []
      refute "localhost" in settings.agent.network_access.allowed_domains

      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      assert prompt =~ "### Playbook: web"
      assert prompt =~ "dev server for this PR head at http://localhost:4321/"
      assert_receive {:dev_server_stopped, 4321}
      assert_receive {:git, ["worktree", "remove", "--force", ^server_worktree], ^workspace}
      refute File.exists?(server_worktree)

      # Executor-style passes get neither the dev server nor the browser.
      assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, verification: FakeVerification)
      refute_receive {:dev_server_started, _identifier, _run_id, _worktree, _opts}
      assert_receive {:qa_session_started, _worktree, cli_opts}
      refute Map.has_key?(cli_opts[:settings].agent.mcp.servers, "browser")
      refute QaAgent.prompt(job(), nil) =~ "Dev server:"
    end

    test "uses the operator's browser MCP server and leaves other network modes alone" do
      glance = %{playbooks: %{"cli" => %{"enabled" => false}, "web" => %{"browser_mcp" => %{"command" => "glance-mcp", "args" => ["--stdio"]}}}}
      [web] = Selection.playbooks(glance, dev_server?: true)
      settings = Config.settings!()
      open_settings = put_in(settings.agent.network_access.mode, "open")

      assert {:ok, _result} =
               QaAgent.run(job(%{playbooks: [web], run_id: nil, repo_key: nil}), open_settings,
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 verification: FakeVerification
               )

      assert_receive {:dev_server_started, "TP-900", "qa-TP-900-0123456789ab", server_worktree, start_opts}
      assert String.ends_with?(server_worktree, "-dev-server")
      refute Keyword.has_key?(start_opts, :repo_key)
      assert_receive {:qa_session_started, _worktree, session_opts}
      assert %{command: "glance-mcp", args: ["--stdio"]} = session_opts[:settings].agent.mcp.servers["browser"]
      assert session_opts[:settings].agent.network_access == open_settings.agent.network_access
      assert_receive {:dev_server_stopped, 4321}
    end

    test "a dev server that does not start, or an invalid browser server, ends the pass before the agent runs" do
      [web] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}}}, dev_server?: true)
      unhealthy = {:verification_failed, :health_timeout}
      Application.put_env(:symphony_elixir, :qa_test_dev_server_result, {:error, unhealthy})

      assert {:error, {:qa_dev_server_failed, ^unhealthy}, %{total_tokens: 0}} =
               run_web(web)

      assert_receive {:dev_server_started, "TP-900", _run_id, _worktree, _opts}
      refute_receive {:qa_session_started, _worktree, _opts}
      refute_receive {:dev_server_stopped, _port}

      Application.delete_env(:symphony_elixir, :qa_test_dev_server_result)
      remote = %{"web" => %{"browser_mcp" => %{"transport" => "http", "url" => "http://glance.test/mcp", "runtimes" => ["codex"]}}}
      [web] = Selection.playbooks(%{playbooks: Map.put(remote, "cli", %{"enabled" => false})}, dev_server?: true)

      assert {:error, {:qa_browser_mcp_invalid, errors}, _tokens} =
               run_web(web)

      assert errors =~ "runtimes"
      assert_receive {:dev_server_started, "TP-900", _run_id, _worktree, _opts}
      refute_receive {:qa_session_started, _worktree, _opts}
      assert_receive {:dev_server_stopped, 4321}

      assert {:error, {:qa_dev_server_failed, {:qa_worktree_failed, 128, "fatal: no space"}}, _tokens} =
               QaAgent.run(job(%{playbooks: [web]}), Config.settings!(),
                 git: fake_git(%{add_dev_server: {"fatal: no space\n", 128}}),
                 qa_agent_module: FakeSession,
                 verification: FakeVerification
               )

      refute_receive {:dev_server_started, _identifier, _run_id, _worktree, _opts}
      refute_receive {:qa_session_started, _worktree, _opts}
    end

    test "a missing npx or pinned Playwright MCP package ends the pass before the agent runs, without fetching it" do
      [web] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}}}, dev_server?: true)

      for {npx_result, reason} <- [
            {{:error, :enoent}, :no_npx},
            {{"npx canceled due to missing packages and no YES option\n", 1}, "@playwright/mcp@0.0.83"}
          ] do
        assert {:error, {:qa_browser_mcp_unavailable, ^reason}, %{total_tokens: 0}} =
                 QaAgent.run(job(%{playbooks: [web]}), Config.settings!(),
                   git: fake_git(),
                   qa_agent_module: FakeSession,
                   verification: FakeVerification,
                   npx: fake_npx(npx_result)
                 )

        assert_receive {:npx, ["--no", "@playwright/mcp@0.0.83", "--version"]}
        refute_receive {:qa_session_started, _worktree, _opts}
        assert_receive {:dev_server_stopped, 4321}
      end
    end

    test "npx runs the npx found on PATH and reports when there is none" do
      assert QaAgent.npx(["--version"], fn "npx" -> nil end) == {:error, :enoent}
      assert {_output, 0} = QaAgent.npx(["--version"], fn "npx" -> System.find_executable("true") end)

      case System.find_executable("npx") do
        nil -> assert QaAgent.npx(["--version"]) == {:error, :enoent}
        _npx -> assert {_output, 0} = QaAgent.npx(["--version"])
      end
    end

    test "falls back to the streamed agent text when the turn result has no verdict" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [{:agent_text, FakeSession.pass_json()}])
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: "I tested it."}})

      assert {:ok, %{result: %{verdict: :pass}}} = QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "asks for the verdict in a follow-up turn of the same session when the answer has none" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [{:session_started, "sess-qa"}, {:agent_text, "Testing."}])

      Application.put_env(:symphony_elixir, :qa_test_turn_results, [
        {:ok, %{result: "I'll wait for the live run to finish before writing the transcript."}},
        {:ok, %{result: FakeSession.pass_json()}}
      ])

      log =
        capture_log(fn ->
          assert {:ok, %{result: %{verdict: :pass, follow_ups: 1}}} =
                   QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
        end)

      assert log =~ "QA agent answered without a verdict for TP-900"
      assert_receive {:qa_turn, session, first_prompt, _issue, first_opts}
      assert first_prompt =~ "### Playbook: cli"
      assert first_opts[:resume_session_id] == nil
      assert_receive {:qa_turn, ^session, follow_up, _issue, follow_up_opts}
      assert follow_up == QaAgent.follow_up_prompt()
      assert follow_up =~ ~r/Return only the JSON\s+verdict object/
      assert follow_up_opts[:resume_session_id] == "sess-qa"
      refute_receive {:qa_turn, _session, _prompt, _issue, _opts}
      assert_receive {:qa_session_stopped, ^session}
    end

    test "records blocked with no_verdict_object when the follow-up has no verdict either" do
      Application.put_env(:symphony_elixir, :qa_test_turn_results, [{:ok, %{result: "Still waiting."}}, {:ok, %{result: "Still waiting."}}])

      capture_log(fn ->
        assert {:error, {:malformed_qa_response, :no_verdict_object}, _tokens} =
                 QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
      end)

      assert_receive {:qa_turn, _session, _prompt, _issue, _opts}
      assert_receive {:qa_turn, _session, follow_up, _issue, follow_up_opts}
      assert follow_up == QaAgent.follow_up_prompt()
      assert follow_up_opts[:resume_session_id] == nil
      refute_receive {:qa_turn, _session, _prompt, _issue, _opts}

      Application.put_env(:symphony_elixir, :qa_test_turn_results, [{:ok, %{result: "Still waiting."}}, {:error, :turn_timeout}])

      capture_log(fn ->
        assert {:error, {:qa_agent_failed, :turn_timeout}, _tokens} =
                 QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
      end)
    end

    test "reports malformed answers and agent failures as errors with the tokens spent" do
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: ~s({"verdict":"maybe"})}})

      assert {:error, {:malformed_qa_response, :invalid_verdict}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      # Only a missing verdict object earns a follow-up; a malformed one does not.
      assert_receive {:qa_turn, _session, _prompt, _issue, _opts}
      refute_receive {:qa_turn, _session, _prompt, _issue, _opts}

      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{}})

      assert {:error, {:malformed_qa_response, :empty_response}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:error, :turn_timeout})

      assert {:error, {:qa_agent_failed, :turn_timeout}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      Application.put_env(:symphony_elixir, :qa_test_start_result, {:error, :port_failed})

      assert {:error, {:qa_agent_failed, :port_failed}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "stops the turn at the per-issue token limit" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [
        %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 900, "output_tokens" => 200, "total_tokens" => 1_100}}}
      ])

      assert {:error, {:qa_token_limit, 1_100, 1_000}, %{total_tokens: 1_100}} =
               QaAgent.run(job(%{token_limit: 1_000}), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      assert_receive {:qa_session_stopped, _session}
    end

    test "fetches a missing commit and reports worktree failures" do
      git = fake_git(%{cat_file: {"missing", 1}, fetch: {"fatal: no such ref", 128}})

      assert {:error, {:qa_commit_unavailable, @sha, 128, "fatal: no such ref"}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: git, qa_agent_module: FakeSession)

      git = fake_git(%{cat_file: {"missing", 1}, fetch: {"", 0}, add: {"fatal: busy\n", 128}})

      assert {:error, {:qa_worktree_failed, 128, "fatal: busy"}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: git, qa_agent_module: FakeSession)

      assert_receive {:git, ["fetch", "--quiet", "origin", @sha], _workspace}
    end

    test "keeps the first parse error when every candidate is malformed" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [{:agent_text, ~s({"verdict":"pass","steps":"x"})}])
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: ~s({"verdict":"maybe"})}})

      assert {:error, {:malformed_qa_response, :invalid_verdict}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "runs against a real git workspace without a parent lookup on other trackers" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      repo = Path.join(System.tmp_dir!(), "qa-agent-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf(repo) end)

      git! = fn args ->
        {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
        String.trim(output)
      end

      git!.(["init", "--quiet"])
      git!.(["config", "user.email", "qa@example.test"])
      git!.(["config", "user.name", "QA"])
      File.write!(Path.join(repo, "a.txt"), "a\n")
      git!.(["add", "."])
      git!.(["commit", "--quiet", "-m", "a"])
      head = git!.(["rev-parse", "HEAD"])
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", head)

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{workspace_path: repo, sha: head}), settings, qa_agent_module: FakeSession)

      assert_receive {:qa_session_started, ^worktree, _opts}
      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      refute prompt =~ "Parent issue"
      refute File.exists?(worktree)
      assert git!.(["worktree", "list"]) =~ repo
      refute git!.(["worktree", "list"]) =~ worktree
    end

    test "maps runtimes to agent modules" do
      assert {:ok, SymphonyElixir.Codex.AppServer} = QaAgent.agent_module("codex")
      assert {:ok, SymphonyElixir.ClaudeCode.AppServer} = QaAgent.agent_module("claude")
      assert {:error, {:unsupported_qa_agent_kind, nil}} = QaAgent.agent_module(nil)
    end

    test "does not run on remote workers or unknown runtimes" do
      assert {:error, {:remote_worker_unsupported, "worker-1"}, %{total_tokens: 0}} =
               QaAgent.run(job(%{worker_host: "worker-1"}), Config.settings!())

      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{runtime: "claude"})
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | kind: "gpt"}}

      assert {:error, {:unsupported_qa_agent_kind, "gpt"}, _tokens} = QaAgent.run(job(), settings, git: fake_git())
    end

    test "reads the parent issue from Linear for sub-tickets and survives a failed read" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      settings = Config.settings!()
      recipient = self()

      linear_client = fn query, _variables, _opts ->
        send(recipient, {:linear_query, query})
        {:ok, %{"data" => %{"issue" => %{"parent" => %{"identifier" => "TP-243", "title" => "Parent", "description" => "parent criterion"}}}}}
      end

      assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, linear_client: linear_client)
      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      assert prompt =~ "parent criterion"

      failing_client = fn _query, _variables, _opts -> {:error, :linear_down} end

      log =
        capture_log(fn ->
          assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, linear_client: failing_client)
        end)

      assert log =~ "QA could not read the parent issue for TP-900"

      no_parent = fn _query, _variables, _opts -> {:ok, %{"data" => %{"issue" => %{"parent" => nil}}}} end
      assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, linear_client: no_parent)
    end
  end

  defp run_web(web) do
    QaAgent.run(job(%{playbooks: [web]}), Config.settings!(),
      git: fake_git(),
      qa_agent_module: FakeSession,
      verification: FakeVerification,
      npx: fake_npx({"Version 0.0.83\n", 0})
    )
  end

  defp fake_npx(result) do
    test_pid = self()

    fn args ->
      send(test_pid, {:npx, args})
      result
    end
  end

  describe "Report" do
    test "renders a passing report with steps, evidence and accounting" do
      body =
        Report.render(%{
          verdict: :pass,
          sha: @sha,
          target_state: "In Review",
          summary: "All good.",
          steps: [
            %{name: "check", status: "pass", details: "$ bin/symphony check\n```\nexit: 0", evidence: ["https://u/t.md"]},
            %{name: "help", status: "skipped", details: " ", evidence: []}
          ],
          findings: [],
          playbooks: ["cli"],
          runtime_seconds: 83,
          tokens: %{total_tokens: 85_412}
        })

      assert body =~ "## Symphony QA Report"
      assert body =~ "**Verdict:** pass → In Review"
      assert body =~ "`0123456789ab` · playbooks: cli · 1m 23s · 85412 tokens"
      assert body =~ "All good."
      assert body =~ "- **pass** check (evidence: https://u/t.md)"
      assert body =~ "  exit: 0"
      assert body =~ "'''"
      assert body =~ "- **skipped** help\n"
    end

    test "renders fail, escalation, skip and blocked outcomes" do
      fail =
        Report.render(%{verdict: :fail, sha: @sha, target_state: "In Progress", fix_attempt: 1, max_fix_attempts: 2, findings: ["exit 0 on bad config"]})

      assert fail =~ "fail (fix attempt 1 of 2) → In Progress"
      assert fail =~ "### Findings\n\n- exit 0 on bad config"

      escalated = Report.render(%{verdict: :fail, sha: @sha, target_state: "In Review", escalated: true, tokens: %{}, runtime_seconds: 0})
      assert escalated =~ "fix attempts used up"
      refute escalated =~ "follow-up"

      followed_up = Report.render(%{verdict: :fail, sha: @sha, target_state: "In Progress", findings: ["x"], follow_ups: 2})
      assert followed_up =~ "`0123456789ab` · verdict after 2 follow-ups"

      skip = Report.render(%{verdict: :skip, sha: nil, target_state: "In Review", reason: "docs only"})
      assert skip =~ "**Verdict:** skipped → In Review"
      assert skip =~ "Reason: docs only"

      blocked = Report.render(%{verdict: :blocked, sha: @sha, target_state: "In Review", reason: "no mix", summary: "ignored"})
      assert blocked =~ "Reason: no mix"
      refute blocked =~ "ignored"

      long = Report.render(%{verdict: :pass, sha: @sha, target_state: "In Review", steps: [%{name: "x", status: "pass", details: String.duplicate("a", 2_100), evidence: []}]})
      assert long =~ "[... truncated ...]"
    end

    test "renders a parent walkthrough with the base branch commit, the verification ticket and filed tickets" do
      body =
        Report.render(%{
          verdict: :fail,
          sha: @sha,
          ref: "origin/main",
          target_state: "Backlog",
          target_issue: "TP-910",
          findings: ["Settings is empty"],
          filed: [%{identifier: "TP-912", title: "Parent walkthrough fails: open Settings"}]
        })

      assert body =~ "**Verdict:** fail → TP-910 Backlog"
      assert body =~ "**Commit:** `0123456789ab` (head of `origin/main`)"
      refute body =~ "PR head"
      assert body =~ "### Filed tickets\n\n- TP-912 Parent walkthrough fails: open Settings"
    end

    test "creates the report comment on Linear and then rewrites it in place" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      recipient = self()

      client = fn comments ->
        fn query, variables, _opts ->
          send(recipient, {:linear, query, variables})

          cond do
            query =~ "comments(" ->
              {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => comments}}}}}

            query =~ "commentCreate" ->
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-new"}}}}}

            query =~ "commentUpdate" ->
              {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
          end
        end
      end

      assert :ok = Report.publish(issue(), "## Symphony QA Report\n\nnew", linear_client: client.([%{"id" => "w", "body" => "## Symphony Workpad"}, %{"body" => nil}]))
      assert_receive {:linear, create, %{body: "## Symphony QA Report\n\nnew"}}
      assert create =~ "commentCreate"

      existing = [%{"id" => "c-qa", "body" => "## Symphony QA Report\n\nold"}]
      assert :ok = Report.publish(issue(), "## Symphony QA Report\n\nv2", linear_client: client.(existing))
      assert_receive {:linear, update, %{id: "c-qa", body: "## Symphony QA Report\n\nv2"}}
      assert update =~ "commentUpdate"

      failing = fn _query, _variables, _opts -> {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}, "x" => 1}} end
      assert {:error, _reason} = Report.publish(issue(), "## Symphony QA Report", linear_client: failing)
    end

    test "posts a new comment on other trackers" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
      assert :ok = Report.publish(issue(), "## Symphony QA Report\n")
      assert_receive {:memory_tracker_comment, "issue-qa", "## Symphony QA Report\n"}
      assert Report.heading() == "## Symphony QA Report"
    end
  end
end
