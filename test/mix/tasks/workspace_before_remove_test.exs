defmodule Mix.Tasks.Workspace.BeforeRemoveTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Workspace.BeforeRemove
  alias SymphonyElixir.GitHub.Repo, as: GitHubRepo
  alias SymphonyElixir.Workflow

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("workspace.before_remove")
    configured_repo = "chihsuan/symphony"
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-config-#{System.unique_integer([:positive, :monotonic])}")
    primary_repo = configured_primary_repo!(root, configured_repo)

    write_workflow_config!(root, primary_repo)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :symphony_file_path)
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm_rf(root)
      System.delete_env("SYMPHONY_REPO")
      System.delete_env("SYMPHONY_BRANCH")
      System.delete_env("SYMPHONY_REMOVE_REASON")
      System.delete_env("SYMPHONY_ISSUE_STATE")
    end)

    {:ok, configured_repo: configured_repo}
  end

  test "prints help" do
    output =
      capture_io(fn ->
        BeforeRemove.run(["--help"])
      end)

    assert output =~ "mix workspace.before_remove"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      BeforeRemove.run(["--wat"])
    end
  end

  test "GitHub repo parser accepts supported GitHub origin forms" do
    assert GitHubRepo.from_url("git@github.com:acme/symphony.git") == "acme/symphony"
    assert GitHubRepo.from_url("https://github.com/acme/symphony.git") == "acme/symphony"
    assert GitHubRepo.from_url("ssh://git@github.com/acme/symphony.git") == "acme/symphony"
    assert GitHubRepo.from_url("git@gitlab.com:acme/symphony.git") == nil
    assert GitHubRepo.from_url("not-a-url") == nil
    assert GitHubRepo.from_url(nil) == nil
    assert GitHubRepo.same?("Acme/Symphony.git", "acme/symphony")
    refute GitHubRepo.same?("acme/symphony", "other/symphony")
    refute GitHubRepo.same?(nil, "acme/symphony")
  end

  test "no-ops when repo and branch are unavailable" do
    with_path([], fn ->
      in_temp_dir(fn ->
        output =
          capture_io(fn ->
            BeforeRemove.run([])
          end)

        assert output == ""
      end)
    end)
  end

  test "no-ops when repo resolves blank while branch is supplied" do
    System.put_env("SYMPHONY_REPO", " ")

    output =
      capture_io(fn ->
        BeforeRemove.run(["--branch", "feature/no-repo"])
      end)

    assert output == ""
  end

  test "no-ops when branch resolves blank" do
    System.put_env("SYMPHONY_BRANCH", " ")

    output =
      capture_io(fn ->
        BeforeRemove.run(["--repo", "chihsuan/symphony"])
      end)

    assert output == ""
  end

  test "no-ops when gh is unavailable" do
    with_fake_git_only(fn log_path ->
      output =
        capture_io(fn ->
          BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/no-gh"])
        end)

      assert output == ""
      assert File.read!(log_path) == ""
    end)
  end

  test "no-ops when branch is supplied but repo is unavailable" do
    output =
      capture_io(fn ->
        BeforeRemove.run(["--branch", "feature/no-repo"])
      end)

    assert output == ""
  end

  test "blank env values fall through to manual flags" do
    System.put_env("SYMPHONY_REPO", " ")
    System.put_env("SYMPHONY_BRANCH", " ")

    with_fake_gh(fn log_path ->
      capture_task_output(fn ->
        BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/flag"])
      end)

      assert File.read!(log_path) =~ "pr list --repo chihsuan/symphony --head feature/flag"
    end)
  end

  test "uses env repo and branch for lookup and ignores cwd git state" do
    with_fake_gh(fn log_path ->
      in_temp_dir(fn ->
        write_fake_gitdir!("git@github.com:attacker/important.git", "feature/attacker")
        System.put_env("SYMPHONY_REPO", "chihsuan/symphony")
        System.put_env("SYMPHONY_BRANCH", "feature/workpad")

        {output, error_output} =
          capture_task_output(fn ->
            BeforeRemove.run([])
          end)

        assert output =~ "Closed PR #101 for branch feature/workpad"
        assert error_output =~ "Failed to close PR #102 for branch feature/workpad"

        log = File.read!(log_path)

        assert log =~
                 "pr list --repo chihsuan/symphony --head feature/workpad --state open --json number --jq .[].number"

        refute log =~ "attacker/important"
        refute log =~ "feature/attacker"
        assert log =~ "pr close 101 --repo chihsuan/symphony"
        assert log =~ "pr close 102 --repo chihsuan/symphony"
      end)
    end)
  end

  test "closes open pull requests for the branch and tolerates close failures" do
    with_fake_gh(fn log_path ->
      File.write!(log_path, "")

      {output, error_output} =
        capture_task_output(fn ->
          BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/workpad"])
        end)

      assert output =~ "Closed PR #101 for branch feature/workpad"
      assert error_output =~ "Failed to close PR #102 for branch feature/workpad"

      log = File.read!(log_path)

      assert log =~ "auth status"
      assert log =~ "pr list --repo chihsuan/symphony --head feature/workpad --state open --json number --jq .[].number"
      assert log =~ "pr close 101 --repo chihsuan/symphony"
      assert log =~ "pr close 102 --repo chihsuan/symphony"

      {second_output, second_error_output} =
        capture_task_output(fn ->
          Mix.Task.reenable("workspace.before_remove")
          BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/workpad"])
        end)

      assert second_output =~ "Closed PR #101 for branch feature/workpad"
      assert second_error_output =~ "Failed to close PR #102 for branch feature/workpad"
    end)
  end

  test "closes the pull requests of a terminal removal, naming the state in the comment" do
    System.put_env("SYMPHONY_REMOVE_REASON", "terminal")
    System.put_env("SYMPHONY_ISSUE_STATE", "Canceled")

    with_fake_gh(fn log_path ->
      {output, _error_output} =
        capture_task_output(fn ->
          BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/workpad"])
        end)

      assert output =~ "Closed PR #101 for branch feature/workpad"
      assert File.read!(log_path) =~ "pr close 101 --repo chihsuan/symphony --comment Closing because the Linear issue for branch feature/workpad moved to Canceled without merge."
    end)
  end

  test "keeps the pull requests open when the workspace goes for another reason than a terminal state" do
    for reason <- ["stop", "cleanup"] do
      System.put_env("SYMPHONY_REMOVE_REASON", reason)

      with_fake_gh(fn log_path ->
        File.write!(log_path, "")

        {output, error_output} =
          capture_task_output(fn ->
            Mix.Task.reenable("workspace.before_remove")
            BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/workpad"])
          end)

        assert output == ""
        assert error_output == ""
        assert File.read!(log_path) == ""
      end)
    end
  end

  test "formats close failures without command stderr output" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        printf '102\\n'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "102" ]; then
        exit 17
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            Mix.Task.reenable("workspace.before_remove")
            BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/no-output"])
          end)

        assert error_output =~ "Failed to close PR #102 for branch feature/no-output: exit 17"
        refute error_output =~ "output="
        log = File.read!(log_path)
        assert log =~ "pr list --repo chihsuan/symphony --head feature/no-output --state open --json number --jq .[].number"
        assert log =~ "pr close 102 --repo chihsuan/symphony"
      end
    )
  end

  test "no-ops when PR list fails for current branch" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        exit 1
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/list-fails"])
          end)

        assert output == ""

        log = File.read!(log_path)
        assert log =~ "auth status"

        assert log =~
                 "pr list --repo chihsuan/symphony --head feature/list-fails --state open --json number --jq .[].number"

        refute log =~ "pr close"
      end
    )
  end

  test "no-ops when repo and branch are not supplied even if cwd git reports values" do
    with_fake_gh(fn log_path ->
      in_temp_dir(fn ->
        write_fake_gitdir!("git@github.com:attacker/important.git", "feature/attacker")

        output =
          capture_io(fn ->
            BeforeRemove.run([])
          end)

        assert output == ""

        log = File.read!(log_path)
        assert log == ""
      end)
    end)
  end

  test "refuses repos outside configured Symphony repos" do
    with_fake_gh(fn log_path ->
      {_output, error_output} =
        capture_task_output(fn ->
          BeforeRemove.run(["--repo", "bobthebuilder/things", "--branch", "feature/auto-detect"])
        end)

      log = File.read!(log_path)

      assert error_output =~ "Refusing to close PRs for unconfigured repo bobthebuilder/things"
      assert log == ""
    end)
  end

  test "refuses when configured repos cannot be resolved from config" do
    previous_symphony_file = Application.get_env(:symphony_elixir, :symphony_file_path)

    try do
      Workflow.set_symphony_file_path(Path.join(System.tmp_dir!(), "missing-symphony-#{System.unique_integer([:positive])}.yml"))

      {_output, error_output} =
        capture_task_output(fn ->
          BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/config-error"])
        end)

      assert error_output =~ "Refusing to close PRs for unconfigured repo chihsuan/symphony"
    after
      case previous_symphony_file do
        nil -> Application.delete_env(:symphony_elixir, :symphony_file_path)
        value -> Application.put_env(:symphony_elixir, :symphony_file_path, value)
      end
    end
  end

  test "refuses when configured repo paths have no GitHub origin" do
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-no-origin-#{System.unique_integer([:positive, :monotonic])}")
    primary_repo = configured_primary_repo!(root, "chihsuan/symphony")
    {_output, 0} = System.cmd("git", ["-C", primary_repo, "remote", "remove", "origin"], stderr_to_stdout: true)
    write_workflow_config!(root, primary_repo)

    on_exit(fn -> File.rm_rf(root) end)

    {_output, error_output} =
      capture_task_output(fn ->
        BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/no-origin"])
      end)

    assert error_output =~ "Refusing to close PRs for unconfigured repo chihsuan/symphony"
  end

  test "refuses when git is unavailable while resolving configured repos" do
    with_path([], fn ->
      {_output, error_output} =
        capture_task_output(fn ->
          BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/no-git"])
        end)

      assert error_output =~ "Refusing to close PRs for unconfigured repo chihsuan/symphony"
    end)
  end

  test "env repo takes precedence over repo flag" do
    with_fake_gh(fn log_path ->
      System.put_env("SYMPHONY_REPO", "chihsuan/symphony")
      System.put_env("SYMPHONY_BRANCH", "feature/env")

      capture_task_output(fn ->
        BeforeRemove.run(["--repo", "bobthebuilder/things", "--branch", "feature/flag"])
      end)

      log = File.read!(log_path)

      assert log =~ "pr list --repo chihsuan/symphony --head feature/env"
      refute log =~ "bobthebuilder/things"
      refute log =~ "feature/flag"
    end)
  end

  test "fake worktree gitdir cannot select attacker repo without env or flags" do
    with_fake_gh(fn log_path ->
      in_temp_dir(fn ->
        write_fake_gitdir!("git@github.com:attacker/important-repo.git", "main")

        capture_task_output(fn ->
          BeforeRemove.run([])
        end)

        assert File.read!(log_path) == ""
      end)
    end)
  end

  test "configured repo may be supplied via HTTPS origin URL" do
    configured_repo = "octocat/widgets"
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-https-#{System.unique_integer([:positive, :monotonic])}")
    primary_repo = configured_primary_repo!(root, configured_repo)

    {_output, 0} =
      System.cmd(
        "git",
        ["-C", primary_repo, "remote", "set-url", "origin", "https://github.com/#{configured_repo}.git"],
        stderr_to_stdout: true
      )

    write_workflow_config!(root, primary_repo)

    on_exit(fn -> File.rm_rf(root) end)

    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        printf '101\\n'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ]; then
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        capture_task_output(fn ->
          BeforeRemove.run(["--repo", configured_repo, "--branch", "feature/https-origin"])
        end)

        log = File.read!(log_path)

        assert log =~ "pr list --repo octocat/widgets --head feature/https-origin"
        assert log =~ "pr close 101 --repo octocat/widgets"
      end
    )
  end

  test "no-ops when gh auth is unavailable" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "$GH_LOG"
      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 1
      fi
      exit 99
      """,
      fn log_path ->
        BeforeRemove.run(["--repo", "chihsuan/symphony", "--branch", "feature/no-auth"])

        log = File.read!(log_path)
        assert log =~ "auth status"
        refute log =~ "pr list"
      end
    )
  end

  defp configured_primary_repo!(root, github_repo) do
    primary_repo = Path.join(root, "primary")

    File.rm_rf!(root)
    File.mkdir_p!(primary_repo)
    {_output, 0} = System.cmd("git", ["-C", primary_repo, "init", "-b", "main"], stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["-C", primary_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["-C", primary_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["-C", primary_repo, "commit", "--allow-empty", "-m", "initial"], stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["-C", primary_repo, "remote", "add", "origin", "git@github.com:#{github_repo}.git"], stderr_to_stdout: true)

    primary_repo
  end

  defp write_workflow_config!(root, primary_repo) do
    workflow_file = Path.join(root, "WORKFLOW.md")
    symphony_file = Path.join(root, "symphony.yml")

    Workflow.set_workflow_file_path(workflow_file)
    Workflow.set_symphony_file_path(symphony_file)

    File.write!(workflow_file, "Test prompt\n")

    File.write!(symphony_file, """
    issues:
      provider: memory
    workspaces:
      strategy: "worktree"
      repo: #{inspect(primary_repo)}
      fetch_before_dispatch: false
    repositories:
      - key: "default"
        workflow: "WORKFLOW.md"
        default: true
    """)
  end

  defp write_fake_gitdir!(origin_url, branch) do
    File.mkdir_p!("fake-git")
    File.write!(".git", "gitdir: ./fake-git\n")
    File.write!("fake-git/HEAD", "ref: refs/heads/#{branch}\n")

    File.write!("fake-git/config", """
    [remote "origin"]
      url = #{origin_url}
    """)
  end

  defp with_fake_gh(fun) do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        printf '101\\n102\\n'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "101" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "102" ]; then
        printf 'boom\\n' >&2
        exit 17
      fi

      exit 99
      """,
      fun
    )
  end

  defp with_fake_gh(script, fun) do
    with_fake_binaries(%{"gh" => script}, fun)
  end

  defp with_fake_git_only(fun) do
    git = System.find_executable("git")

    with_fake_binaries(
      %{
        "git" => """
        #!/bin/sh
        exec #{git} "$@"
        """
      },
      fun,
      include_original_path?: false
    )
  end

  defp with_fake_binaries(scripts, fun, opts \\ []) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-task-test-#{unique}")
    bin_dir = Path.join(root, "bin")
    log_path = Path.join(root, "gh.log")

    try do
      File.rm_rf!(root)
      File.mkdir_p!(bin_dir)
      File.write!(log_path, "")
      original_path = System.get_env("PATH") || ""

      path_with_binaries =
        if Keyword.get(opts, :include_original_path?, true) do
          Enum.join([bin_dir, original_path], ":")
        else
          bin_dir
        end

      Enum.each(scripts, fn {name, script} ->
        path = Path.join(bin_dir, name)
        File.write!(path, script)
        File.chmod!(path, 0o755)
      end)

      with_env(
        %{
          "GH_LOG" => log_path,
          "PATH" => path_with_binaries
        },
        fn ->
          fun.(log_path)
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  defp with_path(paths, fun) do
    with_env(%{"PATH" => Enum.join(paths, ":")}, fun)
  end

  defp with_env(overrides, fun) do
    keys = Map.keys(overrides)
    previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(overrides, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp in_temp_dir(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-empty-dir-#{unique}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp capture_task_output(fun) do
    parent = self()
    ref = make_ref()

    error_output =
      capture_io(:stderr, fn ->
        output =
          capture_io(fn ->
            fun.()
          end)

        send(parent, {ref, output})
      end)

    output =
      receive do
        {^ref, output} -> output
      after
        1_000 -> flunk("Timed out waiting for captured task output")
      end

    {output, error_output}
  end
end
