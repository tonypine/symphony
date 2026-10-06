defmodule SymphonyElixir.WorkspaceSafeGitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workspace

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-safe-git-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    {:ok, test_root: test_root}
  end

  test "safe_git applies defensive config overrides and env", %{test_root: test_root} do
    fake_git = Path.join(test_root, "fake-git")
    trace = Path.join(test_root, "trace")

    File.write!(fake_git, """
    #!/bin/sh
    {
      printf 'ARGV:%s\\n' "$*"
      printf 'GIT_CONFIG_GLOBAL:%s\\n' "$GIT_CONFIG_GLOBAL"
      printf 'GIT_CONFIG_SYSTEM:%s\\n' "$GIT_CONFIG_SYSTEM"
      printf 'GIT_OPTIONAL_LOCKS:%s\\n' "$GIT_OPTIONAL_LOCKS"
      printf 'GIT_TERMINAL_PROMPT:%s\\n' "$GIT_TERMINAL_PROMPT"
    } > "#{trace}"
    """)

    File.chmod!(fake_git, 0o755)

    assert {_output, 0} =
             Workspace.safe_git(fake_git, ["status"],
               env: [
                 {"GIT_CONFIG_GLOBAL", "/tmp/hostile-global"},
                 {"GIT_CONFIG_SYSTEM", "/tmp/hostile-system"},
                 {"GIT_OPTIONAL_LOCKS", "1"},
                 {"GIT_TERMINAL_PROMPT", "1"}
               ]
             )

    output = File.read!(trace)
    assert output =~ "-c core.sshCommand=ssh"
    assert output =~ "-c core.fsmonitor="
    assert output =~ "-c core.hooksPath="
    assert output =~ "-c credential.helper= "
    assert output =~ "-c core.askPass= "
    assert output =~ "-c protocol.ext.allow=never"
    assert output =~ "-c protocol.file.allow=user"
    assert output =~ "-c diff.ignoreSubmodules=dirty"
    assert output =~ "-c submodule.recurse=false"
    assert output =~ "-c core.alternateRefsCommand=true"
    assert output =~ "-c protocol.git.allow=never"
    assert output =~ "-c log.showSignature=false"
    assert output =~ "-c merge.verifySignatures=false"
    assert output =~ "-c push.gpgSign=false"
    assert output =~ "ARGV:"
    assert output =~ " status"
    assert output =~ "GIT_CONFIG_GLOBAL:/dev/null"
    assert output =~ "GIT_CONFIG_SYSTEM:/dev/null"
    assert output =~ "GIT_OPTIONAL_LOCKS:0"
    assert output =~ "GIT_TERMINAL_PROMPT:0"
  end

  test "safe_git does not execute repo-local core.fsmonitor", %{test_root: test_root} do
    repo = Path.join(test_root, "repo")
    proof = Path.join(test_root, "SYMPHONY_PWNED")

    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "safe git\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["config", "core.fsmonitor", "sh -c 'touch \"#{proof}\"'"])

    File.rm(proof)

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "status", "--short"])
    refute File.exists?(proof)
  end

  test "safe_git does not execute repo-local core.hooksPath hooks", %{test_root: test_root} do
    repo = Path.join(test_root, "repo")
    hooks = Path.join(test_root, "evil-hooks")
    proof = Path.join(test_root, "SYMPHONY_HOOK_PWNED")

    File.mkdir_p!(repo)
    File.mkdir_p!(hooks)

    for hook <- ["post-checkout", "post-commit", "pre-commit"] do
      hook_path = Path.join(hooks, hook)
      File.write!(hook_path, "#!/bin/sh\ntouch \"#{proof}\"\n")
      File.chmod!(hook_path, 0o755)
    end

    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "safe git\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["config", "core.hooksPath", hooks])

    File.rm(proof)

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "checkout", "-b", "feature"])
    refute File.exists?(proof)
  end

  test "safe_git refuses to execute ext:: remote helpers", %{test_root: test_root} do
    repo = Path.join(test_root, "repo")
    proof = Path.join(test_root, "SYMPHONY_EXT_PWNED")

    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])

    File.rm(proof)

    hostile = "ext::sh -c 'touch \"#{proof}\" >&2; false'"
    assert {_output, status} = Workspace.safe_git(["-C", repo, "ls-remote", hostile])
    assert status != 0
    refute File.exists?(proof)
  end

  test "safe_git_stdout returns stdout and stderr apart, with the safe overrides", %{test_root: test_root} do
    repo = Path.join(test_root, "repo")
    proof = Path.join(test_root, "SYMPHONY_STDOUT_PWNED")

    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "safe git\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["config", "core.fsmonitor", "sh -c 'touch \"#{proof}\"'"])

    File.rm(proof)

    assert {"safe git\n", 0, ""} = Workspace.safe_git_stdout(["-C", repo, "show", "HEAD:README.md"])
    assert {"", status, stderr} = Workspace.safe_git_stdout(["-C", repo, "show", "HEAD:missing.md"])
    assert status != 0
    assert stderr =~ "fatal: path 'missing.md' does not exist in 'HEAD'"

    assert {_stdout, 0, _stderr} = Workspace.safe_git_stdout(["-C", repo, "status", "--short"])
    refute File.exists?(proof)
  end

  test "safe_git runs no filter driver that only a new worktree's include loads", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    included = Path.join(test_root, "worktree-only.cfg")
    proof = Path.join(test_root, "SYMPHONY_INCLUDE_PWNED")

    git!(repo, ["checkout", "-b", "agent"])
    File.write!(Path.join(repo, ".gitattributes"), "notes.txt filter=hidden\n")
    File.write!(Path.join(repo, "notes.txt"), "stored\n")
    git!(repo, ["add", ".gitattributes", "notes.txt"])
    git!(repo, ["commit", "-m", "agent attributes"])
    git!(repo, ["checkout", "main"])

    # The driver applies only in a linked worktree, so the repo's own config shows none.
    File.write!(included, "[filter \"hidden\"]\n\tsmudge = touch '#{proof}'; cat\n")
    git!(repo, ["config", "includeIf.gitdir:**/worktrees/**.path", included])

    worktree = Path.join(test_root, "worktree")
    assert {_output, 0} = Workspace.safe_git(["-C", repo, "worktree", "add", worktree, "agent"])
    assert File.read!(Path.join(worktree, "notes.txt")) == "stored\n"
    refute File.exists?(proof)

    git!(repo, ["worktree", "add", Path.join(test_root, "plain-worktree"), "-b", "plain", "agent"])
    assert File.exists?(proof), "plain git runs the driver, so the setup above is a real attack"
  end

  test "safe_git runs no filter driver from a nested repo's own config", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    nested = init_repo!(Path.join(repo, "nested"))
    proof = Path.join(test_root, "SYMPHONY_NESTED_PWNED")

    File.write!(Path.join(nested, ".gitattributes"), "notes.txt filter=evil\n")
    File.write!(Path.join(nested, "notes.txt"), "stored\n")
    git!(nested, ["add", ".gitattributes", "notes.txt"])
    git!(nested, ["commit", "-m", "nested attributes"])
    git!(repo, ["add", "nested"])
    git!(repo, ["commit", "-m", "nested repo"])
    git!(nested, ["config", "filter.evil.clean", "touch '#{proof}'; cat"])

    # A new mtime makes git read the file back through its clean filter to see whether it changed.
    stale = fn -> File.touch!(Path.join(nested, "notes.txt"), System.os_time(:second) + 60) end
    stale.()

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "status", "--porcelain"])
    # The orphan backup's `add -A` starts from an empty index, like this one.
    index_env = [{"GIT_INDEX_FILE", Path.join(test_root, "backup.index")}]
    assert {_output, 0} = Workspace.safe_git(["-C", repo, "add", "-A"], env: index_env)
    refute File.exists?(proof)

    stale.()
    git!(repo, ["status", "--porcelain"])
    assert File.exists?(proof), "plain git runs the driver, so the setup above is a real attack"
  end

  test "safe_git runs no filter driver a new worktree's relative include loads, run from a subdirectory", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    sub = Path.join(repo, "sub")
    proof = Path.join(test_root, "SYMPHONY_RELATIVE_INCLUDE_PWNED")

    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "kept.txt"), "kept\n")
    git!(repo, ["add", "sub/kept.txt"])
    git!(repo, ["commit", "-m", "subdirectory"])
    git!(repo, ["checkout", "-b", "agent"])
    File.write!(Path.join(repo, ".gitattributes"), "notes.txt filter=hidden\n")
    File.write!(Path.join(repo, "notes.txt"), "stored\n")
    git!(repo, ["add", ".gitattributes", "notes.txt"])
    git!(repo, ["commit", "-m", "agent attributes"])
    git!(repo, ["checkout", "main"])

    # Git reads the relative include from `.git/`, next to the config that names it, whatever
    # directory the command starts in.
    File.write!(Path.join([repo, ".git", "worktree-only.cfg"]), "[filter \"hidden\"]\n\tsmudge = touch '#{proof}'; cat\n")
    git!(repo, ["config", "includeIf.gitdir:**/worktrees/**.path", "worktree-only.cfg"])

    worktree = Path.join(test_root, "worktree")
    assert {_output, 0} = Workspace.safe_git(["-C", sub, "worktree", "add", worktree, "agent"])
    assert File.read!(Path.join(worktree, "notes.txt")) == "stored\n"
    refute File.exists?(proof)

    git!(sub, ["worktree", "add", Path.join(test_root, "plain-worktree"), "-b", "plain", "agent"])
    assert File.exists?(proof), "plain git runs the driver, so the setup above is a real attack"
  end

  test "safe_git diffs run no diff driver the repo config sets", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    proof = Path.join(test_root, "SYMPHONY_DIFF_PWNED")

    File.write!(Path.join(repo, ".gitattributes"), "notes.txt diff=evil\n")
    File.write!(Path.join(repo, "notes.txt"), "one\n")
    git!(repo, ["add", ".gitattributes", "notes.txt"])
    git!(repo, ["commit", "-m", "notes"])
    File.write!(Path.join(repo, "notes.txt"), "two\n")
    git!(repo, ["commit", "-am", "change notes"])

    for {key, command} <- [
          {"diff.evil.command", "touch '#{proof}'; true"},
          {"diff.evil.textconv", "touch '#{proof}'; cat"},
          {"diff.external", "touch '#{proof}'; true"}
        ] do
      git!(repo, ["config", key, command])
      File.rm(proof)

      assert {diff, 0} = Workspace.safe_git(["-C", repo, "diff", "HEAD~1", "HEAD"])
      assert diff =~ "-one\n+two"
      assert {_output, 0} = Workspace.safe_git(["-C", repo, "log", "-p", "-1"])
      assert {_output, 0} = Workspace.safe_git(["-C", repo, "show", "HEAD"])
      assert {_stdout, 0, _stderr} = Workspace.safe_git_stdout(["-C", repo, "show", "HEAD"])
      assert {blame, 0} = Workspace.safe_git(["-C", repo, "blame", "notes.txt"])
      assert blame =~ "two"
      assert {patch, 0} = Workspace.safe_git(["-C", repo, "format-patch", "--stdout", "-1"])
      assert patch =~ "-one\n+two"
      assert {output, 128} = Workspace.safe_git(["-C", repo, "range-diff", "HEAD~2..HEAD~1", "HEAD~1..HEAD"])
      assert output =~ "symphony: refusing to run git, range-diff runs the repo's textconv drivers"
      refute File.exists?(proof), "safe_git ran #{key}"

      git!(repo, ["diff", "HEAD~1", "HEAD"])
      git!(repo, ["show", "HEAD"])
      assert File.exists?(proof), "plain git runs #{key}, so the setup above is a real attack"
      git!(repo, ["config", "--unset", key])
    end

    # `blame` and `range-diff` run a textconv driver too, the latter whatever options it gets.
    git!(repo, ["config", "diff.evil.textconv", "touch '#{proof}'; cat"])
    File.rm(proof)
    git!(repo, ["blame", "notes.txt"])
    assert File.exists?(proof), "plain git blame runs textconv, so the setup above is a real attack"
    File.rm(proof)
    git!(repo, ["range-diff", "--no-ext-diff", "--no-textconv", "HEAD~2..HEAD~1", "HEAD~1..HEAD"])
    assert File.exists?(proof), "range-diff runs textconv despite both options, so safe_git refuses it"
  end

  test "safe_git merges run no merge driver the repo config sets, and merge as git does without one", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    proof = Path.join(test_root, "SYMPHONY_MERGE_PWNED")

    File.write!(Path.join(repo, ".gitattributes"), "notes.txt merge=evil\n")
    File.write!(Path.join(repo, "notes.txt"), "a\nb\nc\nd\ne\n")
    git!(repo, ["add", ".gitattributes", "notes.txt"])
    git!(repo, ["commit", "-m", "notes"])
    git!(repo, ["checkout", "-b", "side"])
    File.write!(Path.join(repo, "notes.txt"), "a\nB\nc\nd\ne\n")
    git!(repo, ["commit", "-am", "side"])
    git!(repo, ["checkout", "main"])
    File.write!(Path.join(repo, "notes.txt"), "a\nb\nc\nd\nE\n")
    git!(repo, ["commit", "-am", "main"])
    git!(repo, ["checkout", "-b", "conflict", "main~1"])
    File.write!(Path.join(repo, "notes.txt"), "a\nb\nc\nd\nX\n")
    git!(repo, ["commit", "-am", "conflict"])
    git!(repo, ["checkout", "main"])
    git!(repo, ["config", "merge.evil.driver", "touch '#{proof}'; exit 0"])

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "merge", "--no-commit", "--no-ff", "side"])
    assert File.read!(Path.join(repo, "notes.txt")) == "a\nB\nc\nd\nE\n"
    git!(repo, ["merge", "--abort"])

    assert {_output, 1} = Workspace.safe_git(["-C", repo, "merge", "--no-commit", "--no-ff", "conflict"])
    assert File.read!(Path.join(repo, "notes.txt")) =~ ~r/\Aa\nb\nc\nd\n<<<<<<< .*\nE\n=======\nX\n>>>>>>> .*\n\z/s
    assert {"notes.txt\n", 0} = Workspace.safe_git(["-C", repo, "diff", "--name-only", "--diff-filter=U"])
    git!(repo, ["merge", "--abort"])
    refute File.exists?(proof)

    git!(repo, ["merge", "--no-commit", "--no-ff", "side"])
    assert File.exists?(proof), "plain git runs the driver, so the setup above is a real attack"
  end

  test "safe_git fetches and pushes run no pack, alternate refs or signing command the repo config sets", %{test_root: test_root} do
    origin = Path.join(test_root, "origin.git")
    source = init_repo!(Path.join(test_root, "source"))
    git!(test_root, ["clone", "--bare", source, origin])
    # The origin takes signed pushes, so a push signs when the repo config asks it to.
    git!(origin, ["config", "receive.certNonceSeed", "seed"])
    repo = Path.join(test_root, "repo")
    git!(test_root, ["clone", origin, repo])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    proof = Path.join(test_root, "SYMPHONY_TRANSPORT_PWNED")

    git!(repo, ["config", "remote.origin.uploadpack", "touch '#{proof}'; git-upload-pack"])
    git!(repo, ["config", "remote.origin.receivepack", "touch '#{proof}'; git-receive-pack"])
    git!(repo, ["config", "core.alternateRefsCommand", "touch '#{proof}'; true"])
    git!(repo, ["config", "push.gpgSign", "true"])
    git!(repo, ["config", "gpg.program", proof_script!(test_root, proof)])
    File.write!(Path.join([repo, ".git", "objects", "info", "alternates"]), Path.join([source, ".git", "objects"]) <> "\n")

    git!(source, ["commit", "--allow-empty", "-m", "upstream"])
    git!(origin, ["fetch", source, "main:main"])
    File.rm(proof)

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "fetch", "origin"])
    assert git!(repo, ["rev-parse", "origin/main"]) == git!(source, ["rev-parse", "HEAD"])
    assert {_output, 0} = Workspace.safe_git(["-C", repo, "ls-remote", "origin", "main"])
    git!(repo, ["commit", "--allow-empty", "-m", "agent"])
    assert {_output, 0} = Workspace.safe_git(["-C", repo, "push", "origin", "HEAD:refs/heads/agent"])
    assert git!(origin, ["rev-parse", "agent"]) == git!(repo, ["rev-parse", "HEAD"])
    refute File.exists?(proof)

    git!(repo, ["ls-remote", "origin", "main"])
    assert File.exists?(proof), "plain git runs the config's upload pack, so the setup above is a real attack"
    File.rm(proof)
    git!(repo, ["config", "--unset", "remote.origin.receivepack"])
    System.cmd("git", ["-C", repo, "push", "origin", "HEAD:refs/heads/signed"], stderr_to_stdout: true)
    assert File.exists?(proof), "plain git signs the push with gpg.program, so the setup above is a real attack"
  end

  test "safe_git checks no signature with the repo config's gpg.program", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    proof = Path.join(test_root, "SYMPHONY_GPG_PWNED")

    # An agent can commit a signature without a key: git hands it to `gpg.program` to check.
    git!(repo, ["checkout", "-b", "signed"])
    git!(repo, ["-c", "gpg.program=#{proof_script!(test_root, Path.join(test_root, "signed"))}", "commit", "-S", "--allow-empty", "-m", "signed"])
    git!(repo, ["checkout", "main"])
    git!(repo, ["config", "gpg.program", proof_script!(test_root, proof)])
    git!(repo, ["config", "log.showSignature", "true"])
    git!(repo, ["config", "merge.verifySignatures", "true"])

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "log", "-1", "--format=%H", "signed"])
    assert {_output, 0} = Workspace.safe_git(["-C", repo, "show", "signed"])
    assert {_output, 0} = Workspace.safe_git(["-C", repo, "merge", "--no-commit", "--no-ff", "signed"])
    refute File.exists?(proof)

    git!(repo, ["log", "-1", "--format=%H", "signed"])
    assert File.exists?(proof), "plain git checks the signature, so the setup above is a real attack"
  end

  test "safe_git reaches no git:// remote, which would run the config's core.gitProxy", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    proof = Path.join(test_root, "SYMPHONY_PROXY_PWNED")

    git!(repo, ["remote", "add", "origin", "https://example.invalid/repo.git"])
    git!(repo, ["config", "url.git://example.invalid/.insteadOf", "https://example.invalid/"])
    git!(repo, ["config", "core.gitProxy", proof_script!(test_root, proof)])

    assert {output, status} = Workspace.safe_git(["-C", repo, "ls-remote", "origin"])
    assert status != 0
    assert output =~ "transport 'git' not allowed"
    refute File.exists?(proof)

    System.cmd("git", ["-C", repo, "ls-remote", "origin"], stderr_to_stdout: true)
    assert File.exists?(proof), "plain git runs the proxy, so the setup above is a real attack"
  end

  test "safe_git runs no core.askPass the repo config sets when an HTTPS remote asks for credentials", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    proof = Path.join(test_root, "SYMPHONY_ASKPASS_PWNED")
    askpass = proof_script!(test_root, proof)
    # No askpass of the operator's stands in for the config's command.
    env = [{"GIT_ASKPASS", nil}, {"SSH_ASKPASS", nil}]

    git!(repo, ["remote", "add", "origin", "https://127.0.0.1:#{credentials_remote!()}/repo.git"])
    git!(repo, ["config", "http.sslVerify", "false"])
    git!(repo, ["config", "core.askPass", askpass])

    for args <- [["ls-remote", "origin"], ["fetch", "origin"]] do
      assert {output, status} = Workspace.safe_git(["-C", repo | args], env: env)
      assert status != 0
      assert output =~ "could not read Username"
      refute File.exists?(proof)
    end

    System.cmd("git", ["-C", repo, "ls-remote", "origin"], env: [{"GIT_TERMINAL_PROMPT", "0"} | env], stderr_to_stdout: true)
    assert File.exists?(proof), "plain git runs the askpass, so the setup above is a real attack"
  end

  test "safe_git refuses to run git when a merge driver's name holds `=`", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    git!(repo, ["config", "merge.a=b.driver", "touch '#{Path.join(test_root, "pwned")}'"])

    assert {message, 128} = Workspace.safe_git(["-C", repo, "merge", "main"])
    assert message =~ ~s(merge driver "a=b")
  end

  test "safe_git raises like System.cmd/3 when git is missing", %{test_root: test_root} do
    missing = Path.join(test_root, "missing-git")
    assert_raise ErlangError, fn -> Workspace.safe_git(missing, ["-C", test_root, "status"]) end
    assert_raise ErlangError, fn -> Workspace.safe_git("symphony-no-such-git", ["status"]) end
  end

  test "safe_git refuses to run git when a filter driver's name holds `=`", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    git!(repo, ["config", "filter.a=b.smudge", "touch '#{Path.join(test_root, "pwned")}'"])

    assert {message, 128} = Workspace.safe_git(["-C", repo, "status"])
    assert message =~ ~s(filter driver "a=b")
    assert {"", 128, ^message} = Workspace.safe_git_stdout(["-C", repo, "status"])
  end

  describe "network calls" do
    setup %{test_root: test_root} do
      {listener, port} = silent_remote!()
      repo = init_repo!(Path.join(test_root, "repo"))
      git!(repo, ["remote", "add", "origin", "http://127.0.0.1:#{port}/stalled.git"])

      %{repo: repo, listener: listener}
    end

    test "a fetch or push to a remote that never answers is stopped at the timeout", %{repo: repo} do
      for args <- [["fetch", "origin"], ["push", "origin", "main"]] do
        log =
          capture_log(fn ->
            {elapsed_us, result} = :timer.tc(fn -> Workspace.safe_git(["-C", repo | args], network_timeout_ms: 300) end)

            assert {output, 124} = result
            assert output =~ "symphony: git #{Enum.join(args, " ")} timed out after 300 ms and was stopped"
            assert elapsed_us < 5_000_000
          end)

        assert log =~ ~s(Git network call timed out repo=#{repo} command="git #{Enum.join(args, " ")}" timeout_ms=300)
      end
    end

    test "the timeout defaults to the application env", %{repo: repo} do
      Application.put_env(:symphony_elixir, :git_network_timeout_ms, 200)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :git_network_timeout_ms) end)

      capture_log(fn -> assert {_output, 124} = Workspace.safe_git(["ls-remote", "origin"], cd: repo) end)
    end

    test "a network call that ends logs its status and duration", %{test_root: test_root, repo: repo} do
      git!(repo, ["remote", "set-url", "origin", init_repo!(Path.join(test_root, "upstream"))])

      log = capture_log([level: :info], fn -> assert {_output, 0} = Workspace.safe_git(["-C", repo, "-c", "fetch.prune=false", "fetch", "origin"]) end)

      assert log =~ ~r/Git network call completed repo=#{Regex.escape(repo)} command="git fetch origin" status=0 duration_ms=\d+/
    end

    test "a network call is stopped when its caller exits", %{repo: repo, listener: listener} do
      caller = spawn(fn -> Workspace.safe_git(["-C", repo, "fetch", "origin"]) end)
      {:ok, connection} = :gen_tcp.accept(listener, 5_000)

      Process.exit(caller, :kill)

      assert {:error, :closed} = :gen_tcp.recv(connection, 0, 5_000) |> drain(connection)
    end
  end

  # A remote that takes the connection and never answers it.
  defp silent_remote! do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  # An HTTPS remote, with a self-signed certificate, that answers every request with a Basic
  # auth challenge. Returns its port.
  defp credentials_remote! do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    # RSA keys: the LibreSSL in Apple's git turns down the default test key.
    rsa = [key: {:rsa, 2048, 65_537}]

    %{server_config: server_config} =
      :public_key.pkix_test_data(%{server_chain: %{root: rsa, peer: rsa}, client_chain: %{root: rsa, peer: rsa}})

    {:ok, listener} =
      :ssl.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true] ++ Keyword.take(server_config, [:cert, :key]))

    {:ok, {_address, port}} = :ssl.sockname(listener)
    server = spawn(fn -> challenge(listener) end)
    on_exit(fn -> Process.exit(server, :kill) end)
    port
  end

  defp challenge(listener) do
    case :ssl.transport_accept(listener) do
      {:ok, transport} ->
        with {:ok, connection} <- :ssl.handshake(transport, 5_000) do
          _request = :ssl.recv(connection, 0, 5_000)

          :ssl.send(
            connection,
            "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"repo\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

          :ssl.close(connection)
        end

        challenge(listener)

      {:error, _closed} ->
        :ok
    end
  end

  # The client's request comes first; the connection closes once git is stopped.
  defp drain({:ok, _request}, connection), do: connection |> :gen_tcp.recv(0, 5_000) |> drain(connection)
  defp drain(result, _connection), do: result

  # A command that leaves `proof` behind and acts as a signing `gpg.program` would.
  defp proof_script!(dir, proof) do
    script = Path.join(dir, "proof-#{System.unique_integer([:positive])}")

    File.write!(script, """
    #!/bin/sh
    touch '#{proof}'
    echo '[GNUPG:] SIG_CREATED ' >&2
    printf -- '-----BEGIN PGP SIGNATURE-----\\nx\\n-----END PGP SIGNATURE-----\\n'
    """)

    File.chmod!(script, 0o755)
    script
  end

  defp init_repo!(repo) do
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "safe git\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    repo
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
