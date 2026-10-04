defmodule SymphonyElixir.PrePushHookTest do
  use ExUnit.Case, async: true

  # Drives .githooks/pre-push the way git does (remote name and URL as arguments, one
  # `<local ref> <local sha> <remote ref> <remote sha>` line per pushed ref on stdin) in a
  # scratch repo, with a stub `mix` that records its arguments.

  @hook Path.expand(".githooks/pre-push")
  @zero_sha String.duplicate("0", 40)
  @git_env [
    {"GIT_AUTHOR_NAME", "Symphony Test"},
    {"GIT_AUTHOR_EMAIL", "test@example.com"},
    {"GIT_COMMITTER_NAME", "Symphony Test"},
    {"GIT_COMMITTER_EMAIL", "test@example.com"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"}
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-pre-push-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    bin = Path.join(root, "bin")
    log = Path.join(root, "mix.log")
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf(root) end)

    # An empty template keeps sample hooks out of .git/hooks, which agent sandboxes deny.
    git!(repo, ["init", "-q", "--template=", "-b", "main"])
    commit!(repo, %{"README.md" => "# repo\n", "lib/a.ex" => "defmodule A do\nend\n"})
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    git!(repo, ["switch", "-q", "-c", "feature"])

    {:ok, root: root, repo: repo, bin: bin, log: log}
  end

  test "the hook is executable" do
    assert %File.Stat{mode: mode} = File.stat!(@hook)
    assert Bitwise.band(mode, 0o111) != 0
  end

  test "skips the checks when the push changes no Elixir file", ctx do
    stub_mix!(ctx)
    sha = commit!(ctx.repo, %{"README.md" => "# repo\n\nMore.\n", "docs/x.md" => "x\n"})

    assert {output, 0} = run_hook(ctx, [push_line(sha, @zero_sha)])
    assert output =~ "pre-push: no Elixir file changed; skipping format, compile and credo checks."
    refute File.exists?(ctx.log)
  end

  test "runs format, compile and credo on the Elixir files of the pushed range", ctx do
    stub_mix!(ctx)
    pushed = commit!(ctx.repo, %{"lib/pushed_before.ex" => "defmodule P do\nend\n"})

    sha =
      commit!(ctx.repo, %{
        "lib/b.ex" => "defmodule B do\nend\n",
        "test/b_test.exs" => "defmodule BTest do\nend\n",
        "README.md" => "# changed\n"
      })

    assert {output, 0} = run_hook(ctx, [push_line(sha, pushed)])
    assert output =~ "pre-push: format, compile and credo checks passed."

    assert mix_calls(ctx) == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "credo --strict lib/b.ex test/b_test.exs"
           ]
  end

  test "checks everything since the merge-base with origin/main for a new branch", ctx do
    stub_mix!(ctx)
    commit!(ctx.repo, %{"lib/b.ex" => "defmodule B do\nend\n"})
    sha = commit!(ctx.repo, %{"lib/c.ex" => "defmodule C do\nend\n"})

    assert {_output, 0} = run_hook(ctx, [push_line(sha, @zero_sha)])
    assert List.last(mix_calls(ctx)) == "credo --strict lib/b.ex lib/c.ex"
  end

  test "falls back to the merge-base when the remote commit is unknown here", ctx do
    stub_mix!(ctx)
    sha = commit!(ctx.repo, %{"lib/b.ex" => "defmodule B do\nend\n"})

    assert {_output, 0} = run_hook(ctx, [push_line(sha, String.duplicate("a", 40))])
    assert List.last(mix_calls(ctx)) == "credo --strict lib/b.ex"
  end

  test "skips credo but still checks format and compile when only mix.lock changed", ctx do
    stub_mix!(ctx)
    sha = commit!(ctx.repo, %{"mix.lock" => "%{}\n"})

    assert {_output, 0} = run_hook(ctx, [push_line(sha, @zero_sha)])
    assert mix_calls(ctx) == ["format --check-formatted", "compile --warnings-as-errors"]
  end

  test "a deleted ref runs no checks", ctx do
    stub_mix!(ctx)
    commit!(ctx.repo, %{"lib/b.ex" => "defmodule B do\nend\n"})

    assert {output, 0} = run_hook(ctx, [push_line(@zero_sha, @zero_sha)])
    assert output =~ "no Elixir file changed"
    refute File.exists?(ctx.log)
  end

  test "rejects the push naming the failed check and the command that fixes it", ctx do
    stub_mix!(ctx, "format")
    sha = commit!(ctx.repo, %{"lib/b.ex" => "defmodule B do\nend\n"})

    assert {output, 1} = run_hook(ctx, [push_line(sha, @zero_sha)])
    assert output =~ "pre-push: mix format --check-formatted failed"
    assert output =~ "run `mix format`, commit, and push again"
    assert output =~ "Do not bypass this hook with `git push --no-verify`."
    refute output =~ "checks passed"
    assert length(mix_calls(ctx)) == 3
  end

  test "rejects the push on a compile or credo failure", ctx do
    sha = commit!(ctx.repo, %{"lib/b.ex" => "defmodule B do\nend\n"})

    stub_mix!(ctx, "compile")
    assert {output, 1} = run_hook(ctx, [push_line(sha, @zero_sha)])
    assert output =~ "pre-push: mix compile --warnings-as-errors failed"

    stub_mix!(ctx, "credo")
    assert {output, 1} = run_hook(ctx, [push_line(sha, @zero_sha)])
    assert output =~ "pre-push: mix credo --strict failed"
  end

  test "notes uncommitted Elixir changes in the working tree", ctx do
    stub_mix!(ctx)
    sha = commit!(ctx.repo, %{"lib/b.ex" => "defmodule B do\nend\n"})
    File.write!(Path.join(ctx.repo, "lib/b.ex"), "defmodule B do\n  # wip\nend\n")

    assert {output, 0} = run_hook(ctx, [push_line(sha, @zero_sha)])
    assert output =~ "the working tree has uncommitted Elixir changes"
  end

  test "runs mix through mise exec when mix is not on PATH", ctx do
    write_executable!(Path.join(ctx.bin, "mise"), """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$MIX_LOG"
    """)

    sha = commit!(ctx.repo, %{"lib/b.ex" => "defmodule B do\nend\n"})

    assert {_output, 0} = run_hook(ctx, [push_line(sha, @zero_sha)], path: "#{ctx.bin}:/usr/bin:/bin")
    assert hd(mix_calls(ctx)) == "exec -- mix format --check-formatted"
  end

  test "fails with the fix when neither mix nor mise is on PATH", ctx do
    sha = commit!(ctx.repo, %{"lib/b.ex" => "defmodule B do\nend\n"})

    assert {output, 1} = run_hook(ctx, [push_line(sha, @zero_sha)], path: "#{ctx.bin}:/usr/bin:/bin")
    assert output =~ "pre-push: mix is not on PATH and mise is not installed"
  end

  defp stub_mix!(ctx, failing_task \\ nil) do
    write_executable!(Path.join(ctx.bin, "mix"), """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$MIX_LOG"
    [ "$1" = "#{failing_task}" ] && exit 1
    exit 0
    """)
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp run_hook(ctx, lines, opts \\ []) do
    stdin = Path.join(ctx.root, "stdin")
    File.write!(stdin, Enum.join(lines))
    path = Keyword.get(opts, :path, "#{ctx.bin}:#{System.get_env("PATH")}")

    System.cmd("/bin/sh", ["-c", ~s("$0" origin git@example.com:org/repo.git < "$1"), @hook, stdin],
      cd: ctx.repo,
      env: [{"PATH", path}, {"MIX_LOG", ctx.log} | @git_env],
      stderr_to_stdout: true
    )
  end

  defp push_line(local_sha, remote_sha) do
    "refs/heads/feature #{local_sha} refs/heads/feature #{remote_sha}\n"
  end

  defp mix_calls(ctx) do
    ctx.log |> File.read!() |> String.split("\n", trim: true)
  end

  defp commit!(repo, files) do
    Enum.each(files, fn {path, contents} ->
      full_path = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, contents)
    end)

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "change"])
    repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true, env: @git_env) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
