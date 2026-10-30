defmodule SymphonyElixir.QaServerScriptsTest do
  # The live QA server's start script (scripts/qa-server-start.sh, TP-1311), run against a stand-in
  # for the escript that records what it was started with: the real server's start is proved on
  # the QA host, by the QA pass's health check.
  use ExUnit.Case, async: true

  @repo Path.expand("../..", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "qa-server-scripts-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    checkout = Path.join(root, "checkout")
    for dir <- ["scripts", "bin", "priv/qa_seed"], do: File.mkdir_p!(Path.join(checkout, dir))
    for script <- ["qa-server-start.sh", "qa-server-gh.sh"], do: File.cp!(Path.join(@repo, "scripts/#{script}"), Path.join(checkout, "scripts/#{script}"))
    File.cp_r!(Path.join(@repo, "priv/qa_seed/symphony"), Path.join(checkout, "priv/qa_seed/symphony"))

    # Records its arguments, its environment and what `gh` answers, as the server would call it.
    File.write!(Path.join(checkout, "bin/symphony"), """
    #!/bin/sh
    out="$SYMPHONY_TEST_OUT"
    printf '%s\\n' "$@" > "$out/args"
    env > "$out/env"
    gh pr view https://github.com/symphony-qa/seed/pull/450 --json id,number,state > "$out/gh-seed" 2>&1; echo "status:$?" >> "$out/gh-seed"
    gh api repos/symphony-qa/seed/pulls/450 --method PATCH -f state=closed > "$out/gh-close" 2>&1; echo "status:$?" >> "$out/gh-close"
    gh api repos/symphony-qa/seed/pulls/450/comments > "$out/gh-comments" 2>&1
    gh pr view https://github.com/tonypine/symphony/pull/1 > "$out/gh-other" 2>&1; echo "status:$?" >> "$out/gh-other"
    """)

    File.chmod!(Path.join(checkout, "bin/symphony"), 0o755)
    out = Path.join(root, "out")
    File.mkdir_p!(out)
    %{checkout: checkout, out: out, tmp: Path.join(root, "tmp") |> tap(&File.mkdir_p!/1)}
  end

  defp start(%{checkout: checkout, out: out, tmp: tmp}, env) do
    base = [
      {"PATH", "/usr/bin:/bin"},
      {"TMPDIR", tmp},
      {"SYMPHONY_TEST_OUT", out},
      {"SYMPHONY_VERIFICATION_PORT", "8095"},
      {"LINEAR_API_KEY", "lin_should_not_cross"},
      {"GH_TOKEN", "gh_should_not_cross"},
      {"GITHUB_TOKEN", "gh_should_not_cross"},
      {"SYMPHONY_DISABLE_ORCHESTRATOR", "1"}
    ]

    System.cmd("/bin/sh", [Path.join(checkout, "scripts/qa-server-start.sh")], env: base ++ env, stderr_to_stdout: true)
  end

  defp lines(out, name), do: out |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)

  test "starts the escript on the port over the memory tracker and the seed, with the pass's control token", ctx do
    assert {_output, 0} = start(ctx, [{"SYMPHONY_QA_CONTROL_TOKEN", "pass-token"}])

    args = lines(ctx.out, "args")
    [config] = for {"--config", path} <- Enum.zip(args, tl(args)), do: path
    root = Path.dirname(config)
    assert Enum.drop(args, 6) == ["--host", "127.0.0.1", "--port", "8095", "--qa-seed", Path.join(ctx.checkout, "priv/qa_seed/symphony")]

    config_text = File.read!(config)
    assert config_text =~ "provider: memory"
    assert config_text =~ "issues_file: #{root}/issues.json"
    assert config_text =~ ~s(command: "false")
    refute config_text =~ "webhooks"
    assert File.read!(Path.join(root, "issues.json")) == File.read!(Path.join(ctx.checkout, "priv/qa_seed/symphony/issues.json"))
    assert File.read!(Path.join(root, "state/control_token")) == "pass-token"
    assert Bitwise.band(File.stat!(Path.join(root, "state/control_token")).mode, 0o077) == 0
  end

  test "no Linear or GitHub token reaches the server, and its gh answers only for the seed's pull requests", ctx do
    assert {_output, 0} = start(ctx, [{"SYMPHONY_QA_CONTROL_TOKEN", "pass-token"}])

    env = File.read!(Path.join(ctx.out, "env"))
    refute env =~ "should_not_cross"
    refute env =~ "SYMPHONY_DISABLE_ORCHESTRATOR"

    assert %{"number" => 450, "state" => "OPEN", "url" => "https://github.com/symphony-qa/seed/pull/450", "comments" => []} =
             ctx.out |> lines("gh-seed") |> hd() |> Jason.decode!()

    assert lines(ctx.out, "gh-seed") |> List.last() == "status:0"
    assert lines(ctx.out, "gh-close") == ["{}", "status:0"]
    assert lines(ctx.out, "gh-comments") == ["[]"]
    assert lines(ctx.out, "gh-other") == ["gh: the QA server reaches no GitHub", "status:1"]
  end

  test "makes and prints a control token for a run by hand, and refuses to start without the escript or a port", ctx do
    assert {output, 0} = start(ctx, [])
    assert [_line, token] = Regex.run(~r/control token ([0-9a-f]{48})/, output)
    [config] = for {"--config", path} <- ctx.out |> lines("args") |> then(&Enum.zip(&1, tl(&1))), do: path
    assert File.read!(Path.join(Path.dirname(config), "state/control_token")) == token

    assert {output, status} = start(ctx, [{"SYMPHONY_VERIFICATION_PORT", ""}])
    assert status != 0 and output =~ "SYMPHONY_VERIFICATION_PORT is not set"

    File.rm!(Path.join(ctx.checkout, "bin/symphony"))
    assert {output, 1} = start(ctx, [])
    assert output =~ "bin/symphony is missing; build it first with scripts/qa-server-build.sh"
  end
end
