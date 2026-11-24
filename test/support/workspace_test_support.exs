defmodule SymphonyElixir.WorkspaceTestSupport do
  @moduledoc """
  The git repositories and the stand-in `ssh` that the workspace tests share: a primary clone with
  one commit (and its bare origin), and an `ssh` on `PATH` that runs the remote script on this
  host, so the scripts `SymphonyElixir.Workspace` sends to a worker run for real.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]
  import SymphonyElixir.TestSupport, only: [restore_env: 2]

  # Runs `fun` with a fake `ssh` on PATH that actually executes the remote
  # `bash -lc <script>` payload against the local filesystem, so the
  # workspace.ex containment script is exercised rather than stubbed out.
  def with_real_exec_fake_ssh(fun) do
    raw_test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-containment-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(raw_test_root)

    # Canonicalize so generated workspace paths match what `pwd -P` returns on
    # the remote (macOS' /tmp and /var are symlinks under /private).
    {:ok, test_root} = SymphonyElixir.PathSafety.canonicalize(raw_test_root)

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(raw_test_root)
    end)

    trace_file = Path.join(test_root, "ssh.trace")
    fake_ssh = Path.join(test_root, "ssh")
    write_real_exec_fake_ssh!(fake_ssh)

    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    fun.(%{test_root: test_root, trace_file: trace_file})
  end

  # `path_prefix` puts directories ahead of the system ones on the remote's PATH, and
  # `global_git_config` stands in for the worker operator's global git config.
  def write_real_exec_fake_ssh!(path, path_prefix \\ "", login_dir \\ nil, global_git_config \\ nil) do
    File.write!(path, """
    #!/usr/bin/env bash
    set -u
    #{if login_dir, do: "cd #{login_dir}"}
    #{if global_git_config, do: "export GIT_CONFIG_GLOBAL=#{global_git_config}"}
    trace_file="${SYMP_TEST_SSH_TRACE:-/dev/null}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"
    export PATH="#{path_prefix}/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

    # SSH.run passes the remote `bash -lc <script>` as a single argv entry.
    # Execute that locally so workspace.ex containment checks run against a real
    # filesystem instead of a canned string fixture. Drop the login-shell flag
    # because local shell profiles can install cd hooks that break these tests
    # under `set -u`.
    args=("$@")
    script="${args[$((${#args[@]} - 1))]}"

    if [ -n "$script" ]; then
      case "$script" in
        "bash -lc "*) script="bash -c ${script#bash -lc }" ;;
      esac
      /bin/bash -c "$script"
      exit $?
    fi

    exit 0
    """)

    File.chmod!(path, 0o755)
    :ok
  end

  def create_primary_repo!(primary_repo, origin_repo \\ nil) do
    File.mkdir_p!(primary_repo)
    git!(primary_repo, ["init", "-b", "main"])
    configure_git_user!(primary_repo)
    File.write!(Path.join(primary_repo, "README.md"), "initial\n")
    git!(primary_repo, ["add", "README.md"])
    git!(primary_repo, ["commit", "-m", "initial"])

    if is_binary(origin_repo) do
      File.mkdir_p!(Path.dirname(origin_repo))
      {_output, 0} = System.cmd("git", ["init", "--bare", origin_repo])
      git!(primary_repo, ["remote", "add", "origin", origin_repo])
      git!(primary_repo, ["push", "-u", "origin", "main"])
      {_output, 0} = System.cmd("git", ["-C", origin_repo, "symbolic-ref", "HEAD", "refs/heads/main"])
      git!(primary_repo, ["fetch", "origin"])
    end

    :ok
  end

  def configure_git_user!(repo) do
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
  end

  def git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with status #{status}: #{output}")
    end
  end

  def git_branch_exists?(repo, branch) do
    case System.cmd("git", ["-C", repo, "rev-parse", "--verify", "refs/heads/#{branch}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
