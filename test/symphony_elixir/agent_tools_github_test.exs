defmodule SymphonyElixir.AgentTools.GitHubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.GitHub
  alias SymphonyElixir.AgentTools.SecretScanner
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workspace

  test "public defaults fail closed when required scope is missing" do
    assert {:error, :missing_github_origin_repo} = GitHub.get_pull_request(%{})
    assert {:error, :missing_github_origin_repo} = GitHub.get_pull_request(:invalid_context)
    assert {:error, :missing_github_origin_repo} = GitHub.create_pull_request(%{}, "Title", "Body")
    assert {:error, :missing_github_origin_repo} = GitHub.update_pull_request_body(%{}, "Body")
    assert {:error, :missing_github_origin_repo} = GitHub.add_pr_comment(%{}, "Body")
    assert {:error, :missing_github_origin_repo} = GitHub.reply_to_review_comment(%{}, 123, "Body")
    assert {:error, :missing_github_origin_repo} = GitHub.get_pr_checks(%{})
    assert {:error, :missing_github_origin_repo} = GitHub.list_pr_comments(%{})
    assert {:error, :missing_github_origin_repo} = GitHub.list_pr_review_comments(%{})
    assert {:error, :missing_github_origin_repo} = GitHub.list_pr_reviews(%{})
    assert {:error, :missing_github_origin_repo} = GitHub.get_failed_run_log(%{})
    assert {:error, :missing_current_issue} = GitHub.merge_pull_request(%{})
    assert {:error, :missing_workspace} = GitHub.fetch_origin(%{})
    assert {:error, :missing_workspace} = GitHub.push_branch(%{})
  end

  test "validates explicit inputs and workspace context" do
    missing_workspace = Path.join(System.tmp_dir!(), "github-agent-tool-missing-#{System.unique_integer([:positive])}")

    assert {:error, :invalid_title} =
             GitHub.create_pull_request(scoped_context(System.tmp_dir!()), :bad, "Body", nil, [])

    assert {:error, :invalid_body} =
             GitHub.update_pull_request_body(scoped_context(System.tmp_dir!()), :bad, [])

    assert {:error, :invalid_draft} =
             GitHub.create_pull_request(scoped_context(System.tmp_dir!()), "Title", "Body", "yes", [])

    assert {:error, :workspace_not_found} =
             GitHub.push_branch(%{command_security: %{origin_repo: "acme/symphony", workspace: missing_workspace}}, [])

    assert {:error, :workspace_not_found} =
             GitHub.fetch_origin(%{command_security: %{origin_repo: "acme/symphony", workspace: missing_workspace}}, [])
  end

  test "pull request body tools reject high-confidence secret prefixes before calling GitHub" do
    workspace = tmp_workspace!("github-agent-secret-scan")
    audit_dir = Path.join(workspace, "audit")
    context = scoped_context(workspace) |> Map.put(:issue, %{"id" => "issue-secret", "identifier" => "ACME-3189"})

    try do
      for token <- secret_fixtures() do
        body = "leaked credential: " <> token

        assert {:error, :secret_pattern_detected} =
                 GitHub.create_pull_request(context, "Title", body, false, dir: audit_dir)
      end

      assert {:error, :secret_pattern_detected} =
               GitHub.create_pull_request(context, "title " <> openai_fixture(), "clean body", false,
                 dir: audit_dir,
                 gh_runner: fn _args, _opts ->
                   flunk("GitHub should not be called for secret-bearing PR titles")
                 end
               )

      assert {:error, :secret_pattern_detected} =
               GitHub.update_pull_request_body(context, "body " <> openai_fixture(), dir: audit_dir)

      assert {:error, :secret_pattern_detected} =
               GitHub.add_pr_comment(context, "body " <> openai_fixture(), dir: audit_dir)

      assert {:error, :secret_pattern_detected} =
               GitHub.reply_to_review_comment(context, 123, "reply " <> openai_fixture(),
                 dir: audit_dir,
                 gh_runner: fn _args, _opts ->
                   flunk("GitHub should not be called for secret-bearing reply bodies")
                 end
               )

      assert [%{"event_type" => "refused_agent_action", "reason" => "secret_pattern_detected"} | _rest] =
               audit_events(audit_dir)

      assert "title" in Enum.map(audit_events(audit_dir), & &1["field"])
      refute inspect(audit_events(audit_dir)) =~ openai_fixture()
    after
      File.rm_rf(workspace)
    end
  end

  test "secret scanner handles clean, invalid, and audit-failure paths without content disclosure" do
    workspace = tmp_workspace!("github-agent-secret-scanner")
    audit_dir = Path.join(workspace, "audit")
    blocked_audit_path = Path.join(workspace, "blocked-audit")
    File.write!(blocked_audit_path, "not a directory")

    try do
      assert :ok = SecretScanner.reject_if_secret_pattern("ordinary comment", %{}, "tool", "body")
      assert :ok = SecretScanner.reject_if_secret_pattern(:not_binary, %{}, "tool", "body", [])
      refute SecretScanner.detect("ordinary comment")
      refute SecretScanner.detect(<<255>>)

      assert {:error, :secret_pattern_detected} =
               SecretScanner.reject_if_secret_pattern(openai_fixture(), %{}, "tool", "body", dir: audit_dir)

      assert [%{"event_type" => "refused_agent_action", "reason" => "secret_pattern_detected", "tool" => "tool"}] =
               audit_events(audit_dir)

      log =
        capture_log(fn ->
          assert {:error, :secret_pattern_detected} =
                   SecretScanner.reject_if_secret_pattern(openai_fixture(), %{}, "tool", "body", dir: blocked_audit_path)
        end)

      assert log =~ "Audit log failed to record secret-pattern rejection"
      refute log =~ openai_fixture()
    after
      File.rm_rf(workspace)
    end
  end

  test "create_pull_request resolves draft from explicit arg, then configured default" do
    workspace = tmp_workspace!("github-agent-create-draft")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      # Assert on the trailing arg (`--draft` or its absence). The body is unique
      # per case so a missing/extra `--draft` fails to match loudly.
      gh_runner = fn args, opts ->
        assert opts[:cd] == workspace
        drafted? = List.last(args) == "--draft"
        body = Enum.at(args, Enum.find_index(args, &(&1 == "--body")) + 1)

        case {body, drafted?} do
          {"explicit true", true} -> {"https://github.com/acme/symphony/pull/3051\n", 0}
          {"explicit false", false} -> {"https://github.com/acme/symphony/pull/3051\n", 0}
          {"nil + no settings", true} -> {"https://github.com/acme/symphony/pull/3051\n", 0}
          {"nil + default settings", true} -> {"https://github.com/acme/symphony/pull/3051\n", 0}
          {"nil + opt-out settings", false} -> {"https://github.com/acme/symphony/pull/3051\n", 0}
        end
      end

      base_opts = [git_runner: git_runner, gh_runner: gh_runner]
      draft_off = put_in(%Schema{}.github.open_pull_requests_as_draft, false)

      # Explicit boolean always wins, regardless of config.
      assert {:ok, %{"draft" => true, "head" => "auto/ACME-3051"}} =
               GitHub.create_pull_request(scoped_context(workspace), "Title", "explicit true", true, base_opts)

      assert {:ok, %{"draft" => false, "head" => "auto/ACME-3051"}} =
               GitHub.create_pull_request(
                 scoped_context(workspace),
                 "Title",
                 "explicit false",
                 false,
                 [settings: draft_off] ++ base_opts
               )

      # Omitted draft with no settings in opts falls back to global Config defaults
      # (draft-on out of the box).
      assert {:ok, %{"draft" => true, "head" => "auto/ACME-3051"}} =
               GitHub.create_pull_request(scoped_context(workspace), "Title", "nil + no settings", nil, base_opts)

      # Omitted draft with settings present uses the configured default.
      assert {:ok, %{"draft" => true, "head" => "auto/ACME-3051"}} =
               GitHub.create_pull_request(
                 scoped_context(workspace),
                 "Title",
                 "nil + default settings",
                 nil,
                 [settings: %Schema{}] ++ base_opts
               )

      # ...and a repo can opt out via github.open_pull_requests_as_draft: false.
      assert {:ok, %{"draft" => false, "head" => "auto/ACME-3051"}} =
               GitHub.create_pull_request(
                 scoped_context(workspace),
                 "Title",
                 "nil + opt-out settings",
                 nil,
                 [settings: draft_off] ++ base_opts
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "current branch detection rejects empty and detached heads" do
    workspace = tmp_workspace!("github-agent-branch-errors")

    try do
      empty_branch_runner = fn
        ["branch", "--show-current"], _opts -> {"\n", 0}
      end

      detached_runner = fn
        ["branch", "--show-current"], _opts -> {"HEAD\n", 0}
      end

      assert {:error, :missing_current_branch} =
               GitHub.push_branch(scoped_context(workspace), git_runner: empty_branch_runner)

      assert {:error, :detached_head} =
               GitHub.push_branch(scoped_context(workspace), git_runner: detached_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "push_branch handles supported git runner return shapes" do
    workspace = tmp_workspace!("github-agent-git-runner-shapes")

    try do
      ok_tuple_runner = fn
        ["branch", "--show-current"], _opts -> {:ok, "auto/ACME-3051\n"}
        ["remote", "get-url", "origin"], _opts -> {:ok, "git@github.com:acme/symphony.git\n"}
        ["remote", "get-url", "--push", "--all", "origin"], _opts -> {:ok, "git@github.com:acme/symphony.git\n"}
        ["push", "origin", "auto/ACME-3051"], _opts -> {:ok, "pushed\n"}
      end

      error_tuple_runner = fn
        ["branch", "--show-current"], _opts -> {:error, :git_boom}
      end

      nonzero_runner = fn
        ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0}
        ["remote", "get-url", "origin"], _opts -> {"git@github.com:acme/symphony.git\n", 0}
        ["remote", "get-url", "--push", "--all", "origin"], _opts -> {"git@github.com:acme/symphony.git\n", 0}
        ["push", "origin", "auto/ACME-3051"], _opts -> {"rejected\n", 1}
      end

      raising_runner = fn _args, _opts -> :erlang.error(:enoent) end

      assert {:ok, %{"output" => "pushed"}} =
               GitHub.push_branch(scoped_context(workspace), git_runner: ok_tuple_runner)

      assert {:error, :git_boom} =
               GitHub.push_branch(scoped_context(workspace), git_runner: error_tuple_runner)

      assert {:error, {:git_failed, ["push", "origin", "auto/ACME-3051"], 1, "rejected\n"}} =
               GitHub.push_branch(scoped_context(workspace), git_runner: nonzero_runner)

      assert {:error, {:git_unavailable, _message}} =
               GitHub.push_branch(scoped_context(workspace), git_runner: raising_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "push_branch can use the default git runner" do
    workspace = tmp_workspace!("github-agent-default-git-runner")

    try do
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {:error, :origin_url_mismatch} =
               GitHub.push_branch(scoped_context(workspace))
    after
      File.rm_rf(workspace)
    end
  end

  test "fetch_origin fetches the configured origin only" do
    workspace = tmp_workspace!("github-agent-fetch-origin")

    try do
      git_runner = fn
        ["remote", "get-url", "origin"], opts ->
          assert opts[:cd] == workspace
          {"git@github.com:acme/symphony.git\n", 0}

        ["fetch", "origin"], opts ->
          assert opts[:cd] == workspace
          {"From github.com:acme/symphony\n   abc123..def456  main -> origin/main\n", 0}
      end

      assert {:ok, %{"remote" => "origin", "output" => output}} =
               GitHub.fetch_origin(scoped_context(workspace), git_runner: git_runner)

      assert output =~ "main -> origin/main"
    after
      File.rm_rf(workspace)
    end
  end

  test "fetch_origin refuses when current origin differs from captured session origin" do
    workspace = tmp_workspace!("github-agent-fetch-retargeted-origin")

    try do
      git_runner = fn
        ["remote", "get-url", "origin"], _opts -> {"ssh://attacker.example/repo.git\n", 0}
        ["fetch", "origin"], _opts -> flunk("fetch should not run when origin is retargeted")
      end

      assert {:error, :origin_url_mismatch} =
               GitHub.fetch_origin(scoped_context(workspace), git_runner: git_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "fetch_origin sanitizes fetch failure output" do
    workspace = tmp_workspace!("github-agent-fetch-origin-failure")
    home_path = Path.join(Path.expand("~"), ".ssh/config")
    raw_output = "Bad owner or permissions on #{home_path}\n" <> <<255>> <> String.duplicate("x", 5_000)

    try do
      git_runner = fn
        ["remote", "get-url", "origin"], _opts -> {"git@github.com:acme/symphony.git\n", 0}
        ["fetch", "origin"], _opts -> {raw_output, 128}
      end

      assert {:error, {:git_fetch_failed, 128, output}} =
               GitHub.fetch_origin(scoped_context(workspace), git_runner: git_runner)

      assert output =~ "~/.ssh/config"
      assert output =~ "... (truncated)"
      refute output =~ Path.expand("~")
      refute output =~ <<255>>
    after
      File.rm_rf(workspace)
    end
  end

  test "fetch_origin surfaces git runner errors" do
    workspace = tmp_workspace!("github-agent-fetch-origin-runner-error")

    try do
      git_runner = fn
        ["remote", "get-url", "origin"], _opts -> {"git@github.com:acme/symphony.git\n", 0}
        ["fetch", "origin"], _opts -> {:error, :git_boom}
      end

      assert {:error, :git_boom} =
               GitHub.fetch_origin(scoped_context(workspace), git_runner: git_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "push_branch default git runner ignores malicious repo fsmonitor and verifies origin" do
    test_root = tmp_workspace!("github-agent-safe-push")
    workspace = Path.join(test_root, "workspace")
    origin = Path.join(test_root, "origin.git")
    proof = Path.join(test_root, "SYMPHONY_PWNED")

    try do
      File.mkdir_p!(workspace)
      git!(test_root, ["init", "--bare", origin])
      git!(workspace, ["init", "-b", "auto/ACME-3051"])
      git!(workspace, ["config", "user.name", "Test User"])
      git!(workspace, ["config", "user.email", "test@example.com"])
      File.write!(Path.join(workspace, "README.md"), "safe push\n")
      git!(workspace, ["add", "README.md"])
      git!(workspace, ["commit", "-m", "initial"])
      git!(workspace, ["remote", "add", "origin", origin])
      git!(workspace, ["config", "core.fsmonitor", "sh -c 'touch \"#{proof}\"'"])

      context = %{
        workspace: workspace,
        command_security: %{
          origin_url: origin,
          workspace: workspace
        }
      }

      assert {:ok, %{"branch" => "auto/ACME-3051", "remote" => "origin"}} = GitHub.push_branch(context)
      refute File.exists?(proof)
      assert String.trim(git!(origin, ["rev-parse", "refs/heads/auto/ACME-3051"])) != ""
    after
      File.rm_rf(test_root)
    end
  end

  test "fetch_origin default git runner ignores a planted repo credential helper" do
    test_root = tmp_workspace!("github-agent-safe-credential")
    workspace = Path.join(test_root, "workspace")
    proof = Path.join(test_root, "SYMPHONY_PWNED")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    server = Task.async(fn -> serve_unauthorized(listener) end)
    origin = "http://127.0.0.1:#{port}/acme/symphony.git"

    try do
      File.mkdir_p!(workspace)
      git!(workspace, ["init"])
      git!(workspace, ["remote", "add", "origin", origin])
      git!(workspace, ["config", "credential.helper", "!touch \"#{proof}\""])
      git!(workspace, ["config", "credential.http://127.0.0.1.helper", "!touch \"#{proof}\""])

      context = %{workspace: workspace, command_security: %{origin_url: origin, workspace: workspace}}

      git_runner = fn args, opts ->
        Workspace.safe_git(args, Keyword.put(opts, :env, [{"GIT_TERMINAL_PROMPT", "0"}]))
      end

      assert {:error, {:git_fetch_failed, _status, _output}} = GitHub.fetch_origin(context, git_runner: git_runner)
      refute File.exists?(proof)
    after
      :gen_tcp.close(listener)
      Task.shutdown(server, :brutal_kill)
      File.rm_rf(test_root)
    end
  end

  test "push_branch default git runner refuses planted pushurl and url rewrites" do
    for {key, value_fun} <- [
          {"remote.origin.pushurl", fn _origin, decoy -> {"remote.origin.pushurl", decoy} end},
          {"pushInsteadOf", fn origin, decoy -> {"url.#{decoy}.pushInsteadOf", origin} end},
          {"insteadOf", fn origin, decoy -> {"url.#{decoy}.insteadOf", origin} end}
        ] do
      test_root = tmp_workspace!("github-agent-push-redirect")
      workspace = Path.join(test_root, "workspace")
      origin = Path.join(test_root, "origin.git")
      decoy = Path.join(test_root, "decoy.git")

      try do
        File.mkdir_p!(workspace)
        git!(test_root, ["init", "--bare", origin])
        git!(test_root, ["init", "--bare", decoy])
        git!(workspace, ["init", "-b", "auto/ACME-3051"])
        git!(workspace, ["config", "user.name", "Test User"])
        git!(workspace, ["config", "user.email", "test@example.com"])
        File.write!(Path.join(workspace, "README.md"), "redirect\n")
        git!(workspace, ["add", "README.md"])
        git!(workspace, ["commit", "-m", "initial"])
        git!(workspace, ["remote", "add", "origin", origin])
        {config_key, config_value} = value_fun.(origin, decoy)
        git!(workspace, ["config", config_key, config_value])

        context = %{workspace: workspace, command_security: %{origin_url: origin, workspace: workspace}}

        assert {:error, :origin_url_mismatch} = GitHub.push_branch(context), "planted #{key} was not refused"
        assert git!(decoy, ["for-each-ref"]) == ""
        assert git!(origin, ["for-each-ref"]) == ""
      after
        File.rm_rf(test_root)
      end
    end
  end

  test "push_branch refuses when current origin differs from captured session origin" do
    workspace = tmp_workspace!("github-agent-retargeted-origin")

    try do
      git_runner = fn
        ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0}
        ["remote", "get-url", "origin"], _opts -> {"ssh://attacker.example/repo.git\n", 0}
        ["push", "origin", "auto/ACME-3051"], _opts -> flunk("push should not run when origin is retargeted")
      end

      assert {:error, :origin_url_mismatch} =
               GitHub.push_branch(scoped_context(workspace), git_runner: git_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "push_branch refuses when current origin is unavailable" do
    workspace = tmp_workspace!("github-agent-missing-origin")

    try do
      git_runner = fn
        ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0}
        ["remote", "get-url", "origin"], _opts -> {"\n", 0}
        ["push", "origin", "auto/ACME-3051"], _opts -> flunk("push should not run without a provable origin")
      end

      assert {:error, :origin_url_mismatch} =
               GitHub.push_branch(scoped_context(workspace), git_runner: git_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "pull request payload failures are surfaced" do
    workspace = tmp_workspace!("github-agent-pr-payload-errors")

    try do
      git_runner = branch_runner(workspace)

      list_payload_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {"[]", 0}
      end

      invalid_json_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {"not json", 0}
      end

      gh_error_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {:error, :gh_failed}
      end

      assert {:error, :invalid_pull_request_payload} =
               GitHub.get_pull_request(scoped_context(workspace),
                 git_runner: git_runner,
                 gh_runner: list_payload_runner
               )

      assert {:error, {:invalid_pull_request_payload, _message}} =
               GitHub.get_pull_request(scoped_context(workspace),
                 git_runner: git_runner,
                 gh_runner: invalid_json_runner
               )

      assert {:error, :gh_failed} =
               GitHub.get_pull_request(scoped_context(workspace), git_runner: git_runner, gh_runner: gh_error_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "pull request lookup preserves enterprise host in repo selector" do
    workspace = tmp_workspace!("github-agent-enterprise-host")

    try do
      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "github.example.com/acme/symphony", "--json", _fields], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!(%{"number" => 3051, "url" => "https://github.example.com/acme/symphony/pull/3051"}), 0}
      end

      context = %{
        workspace: workspace,
        command_security: %{
          origin_repo: "acme/symphony",
          origin_gh_repo: "github.example.com/acme/symphony",
          workspace: workspace
        }
      }

      assert {:ok, %{"url" => "https://github.example.com/acme/symphony/pull/3051"}} =
               GitHub.get_pull_request(context, git_runner: branch_runner(workspace), gh_runner: gh_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "pull request tools use captured remote branch without a local workspace" do
    remote_workspace = "/remote/workspaces/MT-3187"
    pr_url = "https://github.com/acme/symphony/pull/3187"
    test_pid = self()

    context = %{
      workspace: remote_workspace,
      command_security: %{
        origin_repo: "acme/symphony",
        origin_url: "git@github.com:acme/symphony.git",
        current_branch: "auto/ACME-3187",
        workspace: remote_workspace,
        worker_host: "worker-01"
      }
    }

    git_runner = fn _args, _opts -> flunk("remote PR tools should not shell out to local git") end

    gh_runner = fn
      ["pr", "view", "auto/ACME-3187", "--repo", "acme/symphony", "--json", fields], opts ->
        refute Keyword.has_key?(opts, :cd)
        assert fields == "number,state,title,body,url,headRefName,baseRefName"
        send(test_pid, :viewed_remote_pr)

        {Jason.encode!(%{
           "number" => 3187,
           "state" => "OPEN",
           "title" => "Remote PR",
           "body" => "Body",
           "url" => pr_url,
           "headRefName" => "auto/ACME-3187",
           "baseRefName" => "main"
         }), 0}

      ["pr", "create", "--repo", "acme/symphony", "--head", "auto/ACME-3187", "--title", "Title", "--body", "Body"], opts ->
        refute Keyword.has_key?(opts, :cd)
        send(test_pid, :created_remote_pr)
        {pr_url <> "\n", 0}

      ["pr", "edit", ^pr_url, "--body", "Updated body"], opts ->
        refute Keyword.has_key?(opts, :cd)
        send(test_pid, :updated_remote_pr)
        {"", 0}

      ["pr", "comment", ^pr_url, "--body", "Validation passed\n\n<!-- symphony:agent -->"], opts ->
        refute Keyword.has_key?(opts, :cd)
        send(test_pid, :commented_remote_pr)
        {"", 0}

      ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], opts ->
        refute Keyword.has_key?(opts, :cd)
        send(test_pid, :checked_remote_pr)

        {Jason.encode!(%{
           "number" => 3187,
           "state" => "OPEN",
           "title" => "Remote PR",
           "url" => pr_url,
           "headRefOid" => "abc123",
           "statusCheckRollup" => []
         }), 0}
    end

    assert {:ok, %{"url" => ^pr_url}} = GitHub.get_pull_request(context, git_runner: git_runner, gh_runner: gh_runner)

    assert {:ok, %{"url" => ^pr_url, "head" => "auto/ACME-3187"}} =
             GitHub.create_pull_request(context, "Title", "Body", false, git_runner: git_runner, gh_runner: gh_runner)

    assert {:ok, %{"url" => ^pr_url}} =
             GitHub.update_pull_request_body(context, "Updated body", git_runner: git_runner, gh_runner: gh_runner)

    assert {:ok, %{"url" => ^pr_url}} =
             GitHub.add_pr_comment(context, "Validation passed", git_runner: git_runner, gh_runner: gh_runner)

    assert {:ok, %{pr_url: ^pr_url, commit_sha: "abc123", checks: []}} =
             GitHub.get_pr_checks(context, git_runner: git_runner, gh_runner: gh_runner)

    assert_received :viewed_remote_pr
    assert_received :created_remote_pr
    assert_received :updated_remote_pr
    assert_received :commented_remote_pr
    assert_received :checked_remote_pr
  end

  test "read-only PR feedback tools resolve current branch PR and return paginated payloads" do
    workspace = tmp_workspace!("github-agent-feedback-tools")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["api", "--paginate", "--slurp", "repos/acme/symphony/issues/3051/comments"], _opts ->
          {Jason.encode!([[issue_comment(pr_url)]]), 0}

        ["api", "--paginate", "--slurp", "repos/acme/symphony/pulls/3051/comments"], _opts ->
          {Jason.encode!([[review_comment(pr_url)]]), 0}

        ["api", "--paginate", "--slurp", "repos/acme/symphony/pulls/3051/reviews"], _opts ->
          {Jason.encode!([[review_summary(pr_url)]]), 0}
      end

      opts = [git_runner: branch_runner(workspace), gh_runner: gh_runner]

      assert {:ok, %{"pr_url" => ^pr_url, "comments" => [%{kind: "comment", body: "Top-level note."}]}} =
               GitHub.list_pr_comments(scoped_context(workspace), opts)

      assert {:ok,
              %{
                "pr_url" => ^pr_url,
                "comments" => [%{kind: "inline_comment", path: "lib/example.ex", position: 8, review_id: "987"}]
              }} = GitHub.list_pr_review_comments(scoped_context(workspace), opts)

      assert {:ok, %{"pr_url" => ^pr_url, "reviews" => [%{state: "APPROVED", author: "reviewer"}]}} =
               GitHub.list_pr_reviews(scoped_context(workspace), opts)
    after
      File.rm_rf(workspace)
    end
  end

  test "get_failed_run_log selects a failed check and clamps log output" do
    workspace = tmp_workspace!("github-agent-failed-run-log")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], _opts ->
          {Jason.encode!(%{
             "state" => "OPEN",
             "title" => "Add tools",
             "url" => pr_url,
             "headRefOid" => "abc123",
             "statusCheckRollup" => [
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "FAILURE",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}

        ["run", "view", "987", "--log-failed"], _opts ->
          {"0123456789abcdef", 0}
      end

      assert {:ok,
              %{
                "run_id" => "987",
                "log" => "0123456789",
                "truncated" => true,
                "max_bytes" => 10
              }} =
               GitHub.get_failed_run_log(scoped_context(workspace),
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner,
                 failed_run_log_max_bytes: 10
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "get_failed_run_log uses configured max bytes and preserves valid UTF-8" do
    workspace = tmp_workspace!("github-agent-failed-run-log-utf8")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], _opts ->
          {Jason.encode!(%{
             "url" => pr_url,
             "statusCheckRollup" => [
               %{"name" => "queued", "status" => "QUEUED"},
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => " timed_out ",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}

        ["run", "view", "987", "--log-failed"], _opts ->
          {"aéz", 0}
      end

      settings = %Schema{github: %Schema.GitHub{failed_run_log_max_bytes: 2}}

      assert {:ok, %{"log" => "a", "truncated" => true, "max_bytes" => 2}} =
               GitHub.get_failed_run_log(scoped_context(workspace),
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner,
                 settings: settings
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "get_failed_run_log returns untruncated logs with default config max bytes" do
    workspace = tmp_workspace!("github-agent-failed-run-log-default-config")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], _opts ->
          {Jason.encode!(%{
             "url" => pr_url,
             "statusCheckRollup" => [
               %{
                 "name" => "failed external check",
                 "status" => "COMPLETED",
                 "conclusion" => "FAILURE",
                 "detailsUrl" => "https://ci.example.com/build/987"
               },
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "FAILURE",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}

        ["run", "view", "987", "--log-failed"], _opts ->
          {"short log", 0}
      end

      assert {:ok, %{"log" => "short log", "truncated" => false, "max_bytes" => 65_536}} =
               GitHub.get_failed_run_log(scoped_context(workspace),
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "get_failed_run_log rejects invalid max bytes before fetching logs" do
    workspace = tmp_workspace!("github-agent-failed-run-log-invalid-max")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], _opts ->
          {Jason.encode!(%{
             "url" => pr_url,
             "statusCheckRollup" => [
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "FAILURE",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}

        ["run", "view", "987", "--log-failed"], _opts ->
          flunk("failed logs should not be fetched with an invalid clamp")
      end

      assert {:error, :invalid_failed_run_log_max_bytes} =
               GitHub.get_failed_run_log(scoped_context(workspace),
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner,
                 failed_run_log_max_bytes: 0
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "get_failed_run_log rejects non-binary log payloads" do
    workspace = tmp_workspace!("github-agent-failed-run-log-invalid-payload")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], _opts ->
          {Jason.encode!(%{
             "url" => pr_url,
             "statusCheckRollup" => [
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "FAILURE",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}

        ["run", "view", "987", "--log-failed"], _opts ->
          {:ok, :not_binary}
      end

      assert {:error, :invalid_failed_run_log} =
               GitHub.get_failed_run_log(scoped_context(workspace),
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner,
                 failed_run_log_max_bytes: 65_536
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "get_failed_run_log errors cleanly when no failed run is present" do
    workspace = tmp_workspace!("github-agent-no-failed-run")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], _opts ->
          {Jason.encode!(%{
             "url" => pr_url,
             "statusCheckRollup" => [
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "SUCCESS",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}
      end

      assert {:error, :no_failed_github_actions_run} =
               GitHub.get_failed_run_log(scoped_context(workspace),
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "push_branch is explicitly unsupported for ssh workers" do
    remote_workspace = "/remote/workspaces/MT-3187"

    context = %{
      workspace: remote_workspace,
      command_security: %{
        origin_repo: "acme/symphony",
        origin_url: "git@github.com:acme/symphony.git",
        current_branch: "auto/ACME-3187",
        workspace: remote_workspace,
        worker_host: "worker-01"
      }
    }

    assert {:error, {:unsupported_for_ssh_worker, :github_push_branch}} = GitHub.push_branch(context)
  end

  test "fetch_origin is explicitly unsupported for ssh workers" do
    remote_workspace = "/remote/workspaces/MT-3187"

    context = %{
      workspace: remote_workspace,
      command_security: %{
        origin_repo: "acme/symphony",
        origin_url: "git@github.com:acme/symphony.git",
        current_branch: "auto/ACME-3187",
        workspace: remote_workspace,
        worker_host: "worker-01"
      }
    }

    assert {:error, {:unsupported_for_ssh_worker, :github_fetch_origin}} = GitHub.fetch_origin(context)
  end

  test "captured remote branch errors are surfaced before pull request lookup" do
    remote_workspace = "/remote/workspaces/MT-3187"

    context = %{
      workspace: remote_workspace,
      command_security: %{
        origin_repo: "acme/symphony",
        current_branch: "HEAD",
        workspace: remote_workspace,
        worker_host: "worker-01"
      }
    }

    assert {:error, :detached_head} =
             GitHub.get_pull_request(context,
               git_runner: fn _args, _opts -> flunk("captured branch should skip local git") end,
               gh_runner: fn _args, _opts -> flunk("invalid captured branch should skip gh") end
             )
  end

  test "pull request write and check tools require a resolved PR URL" do
    workspace = tmp_workspace!("github-agent-missing-pr-url")

    try do
      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "headRefName" => "auto/ACME-3051"}), 0}
      end

      opts = [git_runner: branch_runner(workspace), gh_runner: gh_runner]

      assert {:error, :missing_pull_request_url} =
               GitHub.update_pull_request_body(scoped_context(workspace), "Body", opts)

      assert {:error, :missing_pull_request_url} =
               GitHub.add_pr_comment(scoped_context(workspace), "Body", opts)

      assert {:error, :missing_pull_request_url} =
               GitHub.reply_to_review_comment(scoped_context(workspace), 123, "Body", opts)

      assert {:error, :missing_pull_request_url} =
               GitHub.get_pr_checks(scoped_context(workspace), opts)

      assert {:error, :missing_pull_request_url} =
               GitHub.list_pr_comments(scoped_context(workspace), opts)

      assert {:error, :missing_pull_request_url} =
               GitHub.list_pr_review_comments(scoped_context(workspace), opts)

      assert {:error, :missing_pull_request_url} =
               GitHub.list_pr_reviews(scoped_context(workspace), opts)

      assert {:error, :missing_pull_request_url} =
               GitHub.get_failed_run_log(scoped_context(workspace), opts)
    after
      File.rm_rf(workspace)
    end
  end

  test "reply_to_review_comment posts under the named inline thread for the current PR" do
    workspace = tmp_workspace!("github-agent-reply-review-comment")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], opts ->
          assert opts[:cd] == workspace

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["api", "repos/acme/symphony/pulls/3051/comments/123/replies", "-f", "body=Addressed.\n\n<!-- symphony:agent -->"], opts ->
          assert opts[:cd] == workspace

          {Jason.encode!(%{
             "id" => 4242,
             "node_id" => "PRRC_4242",
             "html_url" => "#{pr_url}#discussion_r4242",
             "body" => "Addressed."
           }), 0}
      end

      assert {:ok,
              %{
                "pr_url" => ^pr_url,
                "comment_id" => "123",
                "reply_id" => 4242,
                "url" => reply_url
              }} =
               GitHub.reply_to_review_comment(scoped_context(workspace), 123, "Addressed.",
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner
               )

      assert reply_url == "#{pr_url}#discussion_r4242"
    after
      File.rm_rf(workspace)
    end
  end

  test "reply_to_review_comment accepts numeric-string comment ids and trims surrounding whitespace" do
    workspace = tmp_workspace!("github-agent-reply-review-comment-string-id")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["api", "repos/acme/symphony/pulls/3051/comments/9876543210/replies", "-f", "body=Addressed.\n\n<!-- symphony:agent -->"], _opts ->
          {Jason.encode!(%{"id" => 11, "html_url" => "#{pr_url}#discussion_r11"}), 0}
      end

      assert {:ok, %{"comment_id" => "9876543210", "reply_id" => 11}} =
               GitHub.reply_to_review_comment(scoped_context(workspace), " 9876543210 ", "Addressed.",
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "reply_to_review_comment rejects blank, non-numeric, and invalid comment ids before calling gh" do
    workspace = tmp_workspace!("github-agent-reply-review-comment-invalid-id")

    try do
      gh_runner = fn _args, _opts -> flunk("gh should not run for invalid comment ids") end
      git_runner = fn _args, _opts -> flunk("git should not run for invalid comment ids") end

      opts = [git_runner: git_runner, gh_runner: gh_runner]
      ctx = scoped_context(workspace)

      for bad <- ["", "   ", "abc", "12abc", nil, 0, -3, %{}, ["1"]] do
        assert {:error, :invalid_comment_id} =
                 GitHub.reply_to_review_comment(ctx, bad, "Addressed.", opts)
      end
    after
      File.rm_rf(workspace)
    end
  end

  test "reply_to_review_comment requires a string body" do
    workspace = tmp_workspace!("github-agent-reply-review-comment-invalid-body")

    try do
      gh_runner = fn _args, _opts -> flunk("gh should not run for invalid body") end
      git_runner = fn _args, _opts -> flunk("git should not run for invalid body") end

      assert {:error, :invalid_body} =
               GitHub.reply_to_review_comment(scoped_context(workspace), 123, :not_a_string,
                 git_runner: git_runner,
                 gh_runner: gh_runner
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "reply_to_review_comment surfaces GitHub 404 for foreign comment ids as a clean error" do
    workspace = tmp_workspace!("github-agent-reply-review-comment-404")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["api", "repos/acme/symphony/pulls/3051/comments/999/replies", "-f", "body=Hi\n\n<!-- symphony:agent -->"], _opts ->
          {"not found\n", 1}
      end

      assert {:error, {:gh_failed, ["api", "repos/acme/symphony/pulls/3051/comments/999/replies", "-f", "body=Hi\n\n<!-- symphony:agent -->"], 1, "not found\n"}} =
               GitHub.reply_to_review_comment(scoped_context(workspace), 999, "Hi",
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "reply_to_review_comment surfaces invalid JSON payloads from gh without raising" do
    workspace = tmp_workspace!("github-agent-reply-review-comment-invalid-json")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["api", "repos/acme/symphony/pulls/3051/comments/123/replies", "-f", "body=Hi\n\n<!-- symphony:agent -->"], _opts ->
          {"not json", 0}
      end

      assert {:error, {:invalid_reply_payload, _message}} =
               GitHub.reply_to_review_comment(scoped_context(workspace), 123, "Hi",
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "reply_to_review_comment works for remote SSH-worker contexts without local git access" do
    remote_workspace = "/remote/workspaces/MT-3187"
    pr_url = "https://github.com/acme/symphony/pull/3187"

    context = %{
      workspace: remote_workspace,
      command_security: %{
        origin_repo: "acme/symphony",
        origin_url: "git@github.com:acme/symphony.git",
        current_branch: "auto/ACME-3187",
        workspace: remote_workspace,
        worker_host: "worker-01"
      }
    }

    git_runner = fn _args, _opts -> flunk("remote SSH-worker reply must not shell out to local git") end

    gh_runner = fn
      ["pr", "view", "auto/ACME-3187", "--repo", "acme/symphony", "--json", _fields], opts ->
        refute Keyword.has_key?(opts, :cd)

        {Jason.encode!(%{
           "number" => 3187,
           "state" => "OPEN",
           "url" => pr_url,
           "headRefName" => "auto/ACME-3187",
           "baseRefName" => "main"
         }), 0}

      ["api", "repos/acme/symphony/pulls/3187/comments/42/replies", "-f", "body=Acked.\n\n<!-- symphony:agent -->"], opts ->
        refute Keyword.has_key?(opts, :cd)
        {Jason.encode!(%{"id" => 7, "html_url" => "#{pr_url}#discussion_r7"}), 0}
    end

    assert {:ok, %{"pr_url" => ^pr_url, "comment_id" => "42", "reply_id" => 7}} =
             GitHub.reply_to_review_comment(context, 42, "Acked.", git_runner: git_runner, gh_runner: gh_runner)
  end

  test "merge_pull_request squash-merges the pull request at the head commit whose checks passed" do
    workspace = tmp_workspace!("github-agent-merge")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"
      passing_check = %{"name" => "mix test", "status" => "COMPLETED", "conclusion" => "SUCCESS"}

      gh_runner =
        merge_gh_runner(pr_url, "OPEN", [passing_check], fn args ->
          assert args == [
                   "pr",
                   "merge",
                   pr_url,
                   "--squash",
                   "--match-head-commit",
                   "abc123",
                   "--subject",
                   "Add tools",
                   "--body",
                   "Body"
                 ]
        end)

      assert {:ok, %{"url" => ^pr_url, "merged" => true, "already_merged" => false, "head_sha" => "abc123"}} =
               GitHub.merge_pull_request(merge_context(workspace),
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner,
                 linear_client: issue_state_client("Merging")
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "merge_pull_request refuses until a human moves the issue to Merging" do
    workspace = tmp_workspace!("github-agent-merge-unapproved")

    try do
      gh_runner = fn args, _opts -> flunk("gh must not run before approval: #{inspect(args)}") end
      opts = [git_runner: branch_runner(workspace), gh_runner: gh_runner, linear_client: issue_state_client("In Review")]

      assert {:error, {:issue_not_in_merging_state, "In Review"}} =
               GitHub.merge_pull_request(merge_context(workspace), opts)

      assert {:error, :missing_current_issue} = GitHub.merge_pull_request(scoped_context(workspace), opts)
    after
      File.rm_rf(workspace)
    end
  end

  test "merge_pull_request refuses failing or pending checks and merges a pull request without checks" do
    workspace = tmp_workspace!("github-agent-merge-checks")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"
      failing_check = %{"name" => "mix test", "status" => "COMPLETED", "conclusion" => "FAILURE"}
      pending_check = %{"name" => "mix test", "status" => "IN_PROGRESS", "conclusion" => nil}
      refuse_merge = fn args -> flunk("merge must not run: #{inspect(args)}") end

      merge_with_checks = fn checks, on_merge ->
        GitHub.merge_pull_request(merge_context(workspace),
          git_runner: branch_runner(workspace),
          gh_runner: merge_gh_runner(pr_url, "OPEN", checks, on_merge),
          linear_client: issue_state_client("Merging")
        )
      end

      assert {:error, {:checks_not_passing, {:failure, [%{name: "mix test"}]}}} =
               merge_with_checks.([failing_check], refuse_merge)

      assert {:error, {:checks_not_passing, :pending}} = merge_with_checks.([pending_check], refuse_merge)
      assert {:ok, %{"merged" => true, "head_sha" => "abc123"}} = merge_with_checks.([], fn _args -> :ok end)
    after
      File.rm_rf(workspace)
    end
  end

  test "merge_pull_request needs the head commit to pin the merge" do
    workspace = tmp_workspace!("github-agent-merge-head")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"state" => "OPEN", "title" => "Add tools", "body" => "Body", "url" => pr_url}), 0}

        ["pr", "view", ^pr_url, "--json", _fields], _opts ->
          {Jason.encode!(%{"state" => "OPEN", "url" => pr_url, "statusCheckRollup" => []}), 0}
      end

      assert {:error, :missing_head_commit_sha} =
               GitHub.merge_pull_request(merge_context(workspace),
                 git_runner: branch_runner(workspace),
                 gh_runner: gh_runner,
                 linear_client: issue_state_client("Merging")
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "merge_pull_request reports merged pull requests as done and refuses closed ones" do
    workspace = tmp_workspace!("github-agent-merge-state")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"
      refuse_merge = fn args -> flunk("merge must not run: #{inspect(args)}") end

      merge_in_state = fn pr_state ->
        GitHub.merge_pull_request(merge_context(workspace),
          git_runner: branch_runner(workspace),
          gh_runner: merge_gh_runner(pr_url, pr_state, [], refuse_merge),
          linear_client: issue_state_client("Merging")
        )
      end

      assert {:ok, %{"url" => ^pr_url, "merged" => true, "already_merged" => true}} = merge_in_state.("MERGED")
      assert {:error, {:pull_request_not_open, "CLOSED"}} = merge_in_state.("CLOSED")
    after
      File.rm_rf(workspace)
    end
  end

  defp merge_context(workspace), do: Map.put(scoped_context(workspace), :issue_id, "issue-3051")

  defp issue_state_client(state_name) do
    fn _query, %{id: "issue-3051"}, _opts ->
      {:ok, %{"data" => %{"issue" => %{"id" => "issue-3051", "identifier" => "ACME-3051", "state" => %{"name" => state_name}}}}}
    end
  end

  defp merge_gh_runner(pr_url, pr_state, status_check_rollup, on_merge) do
    fn
      ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
        {Jason.encode!(%{"state" => pr_state, "title" => "Add tools", "body" => "Body", "url" => pr_url}), 0}

      ["pr", "view", ^pr_url, "--json", _fields], _opts ->
        {Jason.encode!(%{"state" => pr_state, "url" => pr_url, "headRefOid" => "abc123", "statusCheckRollup" => status_check_rollup}), 0}

      ["pr", "merge" | _rest] = args, _opts ->
        on_merge.(args)
        {"", 0}
    end
  end

  defp issue_comment(pr_url) do
    %{
      "id" => 11,
      "user" => %{"login" => "maintainer"},
      "body" => "Top-level note.",
      "html_url" => "#{pr_url}#issuecomment-11"
    }
  end

  defp review_comment(pr_url) do
    %{
      "id" => 22,
      "user" => %{"login" => "reviewer"},
      "body" => "Inline note.",
      "html_url" => "#{pr_url}#discussion_r22",
      "path" => "lib/example.ex",
      "position" => 8,
      "pull_request_review_id" => 987
    }
  end

  defp review_summary(pr_url) do
    %{
      "id" => 987,
      "user" => %{"login" => "reviewer"},
      "body" => "Looks good.",
      "html_url" => "#{pr_url}#pullrequestreview-987",
      "state" => "APPROVED"
    }
  end

  defp scoped_context(workspace) do
    %{
      workspace: workspace,
      command_security: %{
        origin_repo: "acme/symphony",
        origin_url: "git@github.com:acme/symphony.git",
        workspace: workspace
      }
    }
  end

  defp branch_runner(workspace) do
    fn
      ["branch", "--show-current"], opts ->
        assert opts[:cd] == workspace
        {"auto/ACME-3051\n", 0}
    end
  end

  defp serve_unauthorized(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 5_000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"symphony\"\r\n" <>
            "Content-Length: 0\r\nConnection: close\r\n\r\n"
        )

        :gen_tcp.close(socket)
        serve_unauthorized(listener)

      {:error, _reason} ->
        :ok
    end
  end

  defp tmp_workspace!(name) do
    workspace = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp secret_fixtures do
    [
      "sk-ant-" <> String.duplicate("a", 24),
      openai_fixture(),
      "sk-proj-" <> String.duplicate("a", 24),
      "sk-svcacct-" <> String.duplicate("a", 24),
      "ghp_" <> String.duplicate("A", 24),
      "ghu_" <> String.duplicate("B", 24),
      "gho_" <> String.duplicate("C", 24),
      "ghs_" <> String.duplicate("D", 24),
      "ghr_" <> String.duplicate("E", 24),
      "AKIA" <> String.duplicate("A", 16),
      "ASIA" <> String.duplicate("B", 16),
      "AIza" <> String.duplicate("A", 35)
    ]
  end

  defp openai_fixture, do: "sk-" <> String.duplicate("a", 48)

  defp audit_events(dir) do
    dir
    |> Path.join("*.ndjson")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end)
  end
end
