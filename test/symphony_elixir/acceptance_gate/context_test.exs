defmodule SymphonyElixir.AcceptanceGate.ContextTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AcceptanceGate.{Context, OpenPrCache}

  @repo_url "https://github.com/org/app"

  @app_ex """
  defmodule App do
    def alpha(x) do
      x
      |> step_one()
      |> step_two()
      |> step_three()
    end

    def beta(y) do
      y
      |> inc()
      |> double()
    end
  end
  """

  @app_js """
  function render(props) {
    const a = props.a;
    const b = props.b;
    return a + b;
  }
  """

  @readme "# App\n\nIntro.\n"

  defmodule FakeGitHub do
    def list_open_pull_requests(pr_url, opts) do
      send(self(), {:open_pull_requests, pr_url, opts})

      case Process.get(:open_prs, {:ok, []}) do
        :raise -> raise "GitHub is down"
        result -> result
      end
    end
  end

  defmodule FakeRunStore do
    def list_ci_checks(repo_key) do
      send(self(), {:list_ci_checks, repo_key})
      Process.get(:ci_checks, [])
    end

    def list_pr_reviews(_repo_key), do: Process.get(:pr_reviews, [])
  end

  defmodule FakeTracker do
    def fetch_issue_states_by_ids(ids) do
      send(self(), {:issue_states, ids})
      Process.get(:issue_states, {:ok, []})
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "acceptance-gate-context-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    settings = put_in(Config.settings!().workspace.root, Path.join(root, "workspaces"))
    %{root: root, settings: settings}
  end

  describe "the merged diff and overlaps" do
    setup %{root: root} do
      fixture = fixture!(root)
      %{author: author} = fixture

      gated =
        branch!(author, "pr-1", "main", %{
          "lib/app.ex" => String.replace(@app_ex, "|> step_one()", "|> step_one(:fast)"),
          "web/app.js" => String.replace(@app_js, "const a = props.a;", "const a = props.a || 0;"),
          "README.md" => String.replace(@readme, "# App", "# The app"),
          "logo.png" => <<0, 1, 2, 3, 0, 255>>
        })

      same_function =
        branch!(author, "pr-2", "main", %{
          "lib/app.ex" => String.replace(@app_ex, "|> step_three()", "|> step_three(:slow)"),
          "web/app.js" => String.replace(@app_js, "const b = props.b;", "const b = props.b || 1;")
        })

      other_function = branch!(author, "pr-3", "main", %{"lib/app.ex" => String.replace(@app_ex, "|> inc()", "|> inc(2)")})
      in_progress = branch!(author, "pr-4", "main", %{"lib/app.ex" => String.replace(@app_ex, "|> step_two()", "|> step_two(:x)")})
      other_file = branch!(author, "pr-5", "main", %{"lib/other.ex" => "defmodule Other do\nend\n"})
      merged = branch!(author, "pr-6", "main", %{"lib/app.ex" => String.replace(@app_ex, "|> double()", "|> triple()")})

      # The base moves on after every PR branched.
      base = branch!(author, "main", "main", %{"README.md" => String.replace(@readme, "Intro.", "Intro, updated.")})
      git!(fixture.workspace, ["fetch", "--quiet", "origin", "pr-1", "pr-2", "pr-3", "pr-4", "pr-6"])

      Process.put(:ci_checks, [
        %{issue_id: "issue-1", issue_identifier: "TP-1", pr_url: pr_url(1), last_observed_sha: gated},
        %{issue_id: "issue-2", issue_identifier: "TP-2", pr_url: pr_url(2), last_observed_sha: same_function, pr_state: "OPEN"},
        %{issue_id: "issue-4", issue_identifier: "TP-4", pr_url: pr_url(4), commit_sha: in_progress},
        %{issue_id: "issue-6", issue_identifier: "TP-6", pr_url: pr_url(6), last_observed_sha: merged, pr_state: "MERGED"},
        %{issue_identifier: "TP-7", pr_url: pr_url(7)}
      ])

      Process.put(:pr_reviews, [
        %{issue_id: "issue-2", head_ref_oid: "stale-head", auto_merge: nil},
        %{issue_id: "issue-3", issue_identifier: "TP-3", pr_url: pr_url(3), head_ref_oid: other_function},
        # Its head isn't fetched yet: the build fetches it.
        %{issue_id: "issue-5", issue_identifier: "TP-5", pr_url: pr_url(5), auto_merge: %{head_sha: other_file}}
      ])

      Process.put(
        :issue_states,
        {:ok,
         [
           %Issue{id: "issue-2", state: "Auto Review"},
           %Issue{id: "issue-3", state: "In Review"},
           %Issue{id: "issue-4", state: "In Progress"},
           %Issue{id: "issue-5", state: "Merging"}
         ]}
      )

      Process.put(
        :open_prs,
        {:ok,
         [
           open_pr(1, ["lib/app.ex"]),
           %{open_pr(2, ["lib/app.ex"]) | url: pr_url(2) <> "/"},
           open_pr(9, ["lib/app.ex", "docs/guide.md"]),
           open_pr(10, ["lib/unrelated.ex"]),
           %{open_pr(11, ["lib/app.ex"]) | url: nil}
         ]}
      )

      Map.merge(fixture, %{gated: gated, base: base, other_file: other_file})
    end

    test "lists the other open PRs that change the same file, with the function they both change", ctx do
      assert {:ok, context} = build(ctx, ctx.gated)

      assert Enum.sort_by(context.overlaps, & &1.pr_url) == [
               %{
                 pr_url: pr_url(2),
                 issue_identifier: "TP-2",
                 files: ["lib/app.ex", "web/app.js"],
                 functions: [%{path: "lib/app.ex", name: "def alpha"}, %{path: "web/app.js", name: "function render"}]
               },
               %{pr_url: pr_url(3), issue_identifier: "TP-3", files: ["lib/app.ex"], functions: []},
               %{pr_url: pr_url(9), issue_identifier: nil, files: ["lib/app.ex"], functions: []}
             ]

      # Only the other issues with a live PR head are asked for their state.
      assert_received {:issue_states, ids}
      assert Enum.sort(ids) == ["issue-2", "issue-3", "issue-4", "issue-5"]
      assert_received {:list_ci_checks, "app"}
      gated_url = pr_url(1)
      assert_received {:open_pull_requests, ^gated_url, [cwd: _workspace]}

      # The Merging PR's head was missing locally and got fetched.
      assert {_output, 0} = System.cmd("git", ["-C", ctx.workspace, "cat-file", "-e", ctx.other_file <> "^{commit}"])
    end

    test "diffs the merge result against the current base tip, and removes its worktree", ctx do
      assert {:ok, context} = build(ctx, ctx.gated)

      assert context.base_branch == "main"
      assert context.base_sha == ctx.base
      assert git!(ctx.workspace, ["rev-parse", context.merged_sha <> "^1"]) == ctx.base
      assert git!(ctx.workspace, ["rev-parse", context.merged_sha <> "^2"]) == ctx.gated

      assert context.numstat == [
               %{path: "README.md", additions: 1, deletions: 1},
               %{path: "lib/app.ex", additions: 1, deletions: 1},
               %{path: "logo.png", additions: 0, deletions: 0},
               %{path: "web/app.js", additions: 1, deletions: 1}
             ]

      assert context.diff =~ "+# The app"
      # Against the PR head or the merge-base, the base's newer README line would show up.
      refute context.diff =~ ~r/^[-+]Intro/m
      refute context.diff_truncated?

      assert %{path: "lib/app.ex", additions: 1, deletions: 1, added_lines: ["    |> step_one(:fast)"]} = Enum.find(context.diff_summary.files, &(&1.path == "lib/app.ex"))
      assert %{added_lines: []} = Enum.find(context.diff_summary.files, &(&1.path == "logo.png"))
      refute Enum.any?(context.diff_summary.files, &Map.has_key?(&1, :base))

      assert_no_worktree(ctx, ctx.gated)
    end

    test "skips a tracked PR whose head can't be fetched", ctx do
      Process.put(:ci_checks, [%{issue_id: "issue-2", issue_identifier: "TP-2", pr_url: pr_url(2), last_observed_sha: String.duplicate("e", 40)}])
      Process.put(:issue_states, {:ok, [%Issue{id: "issue-2", state: "In Review"}]})
      Process.put(:open_prs, {:ok, []})

      log = capture_log(fn -> assert {:ok, %{overlaps: []}} = build(ctx, ctx.gated) end)
      assert log =~ "Acceptance gate context skipped open PR #{pr_url(2)} issue_identifier=TP-2"
    end

    test "fails on a run store, tracker or GitHub error, and still removes its worktree", ctx do
      Process.put(:open_prs, {:error, :rate_limited})
      assert {:error, {:open_pull_requests_failed, :rate_limited}} = build(ctx, ctx.gated)
      assert_no_worktree(ctx, ctx.gated)

      Process.put(:issue_states, {:error, :linear_down})
      assert {:error, {:issue_states_failed, :linear_down}} = build(ctx, ctx.gated)

      Process.put(:ci_checks, {:error, :closed})
      assert {:error, {:run_store_failed, :closed}} = build(ctx, ctx.gated)
      assert_no_worktree(ctx, ctx.gated)

      Process.put(:ci_checks, [])
      Process.put(:pr_reviews, [])
      assert {:error, :missing_pr_url} = build(%{ctx | record: Map.delete(ctx.record, :pr_url)}, ctx.gated)

      Process.put(:open_prs, :raise)
      assert_raise RuntimeError, "GitHub is down", fn -> build(ctx, ctx.gated) end
      assert_no_worktree(ctx, ctx.gated)
    end
  end

  test "a PR that conflicts with the current base returns its conflicted files and leaves no worktree", ctx do
    fixture = fixture!(ctx.root)
    conflicting = branch!(fixture.author, "pr-1", "main", %{"README.md" => String.replace(@readme, "Intro.", "Intro, from the PR.")})
    branch!(fixture.author, "main", "main", %{"README.md" => String.replace(@readme, "Intro.", "Intro, from main.")})
    git!(fixture.workspace, ["fetch", "--quiet", "origin", "pr-1"])
    ctx = Map.merge(ctx, fixture)

    assert {:conflict, ["README.md"]} = build(ctx, conflicting)
    assert_no_worktree(ctx, conflicting)
    refute_received {:open_pull_requests, _pr_url, _opts}
  end

  test "ranks the busy files by commit count inside the window", ctx do
    old = DateTime.utc_now() |> DateTime.add(-30 * 86_400) |> DateTime.to_iso8601()
    fixture = fixture!(ctx.root, date: old)
    %{author: author} = fixture

    for n <- 1..4, do: branch!(author, "main", "main", %{"lib/old.ex" => "# #{n}\n"}, date: old)
    for n <- 1..3, do: branch!(author, "main", "main", %{"lib/hot.ex" => "# #{n}\n"})
    for n <- 1..2, do: branch!(author, "main", "main", %{"lib/warm.ex" => "# #{n}\n"})
    for n <- 1..2, do: branch!(author, "main", "main", %{"lib/also_warm.ex" => "# #{n}\n"})
    branch!(author, "main", "main", %{"lib/app.ex" => @app_ex <> "# touched\n"})

    gated = branch!(author, "pr-1", "main", %{"lib/new.ex" => "# new\n"})
    git!(fixture.workspace, ["fetch", "--quiet", "origin", "pr-1"])
    ctx = Map.merge(ctx, fixture)

    assert {:ok, %{busy_files: busy_files}} = build(ctx, gated)
    assert busy_files == ["lib/hot.ex", "lib/also_warm.ex", "lib/warm.ex", "lib/app.ex"]

    top_two = put_in(ctx.settings.auto_review.acceptance_gate.escalate.busy_files.top, 2)
    assert {:ok, %{busy_files: ["lib/hot.ex", "lib/also_warm.ex"]}} = build(top_two, gated)

    sixty_days = put_in(ctx.settings.auto_review.acceptance_gate.escalate.busy_files.window_days, 60)
    assert {:ok, %{busy_files: ["lib/old.ex", "lib/hot.ex" | _rest]}} = build(sixty_days, gated)
  end

  test "asks GitHub for the untracked open PRs once for two builds on the same heads", ctx do
    fixture = fixture!(ctx.root)
    gated = branch!(fixture.author, "pr-1", "main", %{"lib/app.ex" => String.replace(@app_ex, "|> inc()", "|> inc(3)")})
    git!(fixture.workspace, ["fetch", "--quiet", "origin", "pr-1"])
    ctx = Map.merge(ctx, fixture)
    Process.put(:open_prs, {:ok, [open_pr(9, ["lib/app.ex"])]})

    cache = :"acceptance_gate_context_test_#{System.unique_integer([:positive])}"
    start_supervised!({OpenPrCache, name: cache})

    assert {:ok, first} = build(ctx, gated, cache: cache)
    assert {:ok, second} = build(ctx, gated, cache: cache)
    assert first.overlaps == [%{pr_url: pr_url(9), issue_identifier: nil, files: ["lib/app.ex"], functions: []}]
    assert second.overlaps == first.overlaps
    assert_received {:open_pull_requests, _pr_url, _opts}
    refute_received {:open_pull_requests, _pr_url, _opts}

    # A moved base asks again.
    branch!(fixture.author, "main", "main", %{"README.md" => "# Moved\n"})
    assert {:ok, _context} = build(ctx, gated, cache: cache)
    assert_received {:open_pull_requests, _pr_url, _opts}
  end

  test "summarises the whole diff for the escalation rules, with the manifests on both sides", ctx do
    fixture = fixture!(ctx.root)
    branch!(fixture.author, "main", "main", %{"mix.lock" => ~s(%{"jason": {:hex, :jason, "1.4.0"}}\n), "old.txt" => "old\n"})
    big = Enum.map_join(1..20_000, &"generated line #{&1}\n")
    git!(fixture.author, ["rm", "--quiet", "old.txt"])

    gated =
      branch!(fixture.author, "pr-1", "main", %{
        "mix.lock" => ~s(%{"jason": {:hex, :jason, "2.0.0"}}\n),
        "assets/package.json" => ~s({"dependencies": {"left-pad": "^1.0.0"}}\n),
        "priv/big.txt" => big,
        "lib/tail.ex" => "+++ b/not-a-path\n"
      })

    git!(fixture.workspace, ["fetch", "--quiet", "origin", "pr-1"])

    assert {:ok, context} = build(Map.merge(ctx, fixture), gated)
    assert context.diff_truncated?
    files = Map.new(context.diff_summary.files, &{&1.path, &1})

    assert files["mix.lock"].base == ~s(%{"jason": {:hex, :jason, "1.4.0"}}\n)
    assert files["mix.lock"].head == ~s(%{"jason": {:hex, :jason, "2.0.0"}}\n)
    assert files["assets/package.json"].base == nil
    assert files["assets/package.json"].head =~ "left-pad"
    assert files["old.txt"] == %{path: "old.txt", additions: 0, deletions: 1, added_lines: []}
    # Read before the diff is cut: every added line of the big file is there.
    assert length(files["priv/big.txt"].added_lines) == 20_000
    assert files["lib/tail.ex"].added_lines == ["+++ b/not-a-path"]
  end

  test "caps the diff at 120 KB and keeps the numstat whole", ctx do
    fixture = fixture!(ctx.root)
    big = Enum.map_join(1..20_000, &"generated line #{&1}\n")
    gated = branch!(fixture.author, "pr-1", "main", %{"priv/big.txt" => big})
    git!(fixture.workspace, ["fetch", "--quiet", "origin", "pr-1"])

    assert {:ok, context} = build(Map.merge(ctx, fixture), gated)
    assert context.diff_truncated?
    assert byte_size(context.diff) <= 120_000
    assert String.ends_with?(context.diff, "\n")
    assert context.numstat == [%{path: "priv/big.txt", additions: 20_000, deletions: 0}]
  end

  test "runs the base and commit fetches once more after cannot lock ref", ctx do
    fixture = fixture!(ctx.root)
    gated = branch!(fixture.author, "pr-1", "main", %{"lib/new.ex" => "# new\n"})
    ctx = Map.merge(ctx, fixture)
    {:ok, failed} = Agent.start_link(fn -> MapSet.new() end)
    test_pid = self()

    # Each fetch fails once, as when another fetch of the repo holds the ref lock.
    git = fn args, cwd ->
      first? = "fetch" in args and Agent.get_and_update(failed, &{not MapSet.member?(&1, args), MapSet.put(&1, args)})
      send(test_pid, {:git, args, first?})

      if first?,
        do: {"error: cannot lock ref 'refs/remotes/origin/main': is at 784f59f4 but expected a2d3de89\n", 1},
        else: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)
    end

    assert {:ok, context} = build(ctx, gated, git: git)
    assert context.base_branch == "main"

    for args <- [["fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main"], ["fetch", "--quiet", "origin", gated]] do
      assert_received {:git, ^args, true}
      assert_received {:git, ^args, false}
    end
  end

  test "reports a missing workspace, base branch or PR head, and a failed merge", ctx do
    fixture = fixture!(ctx.root)
    gated = branch!(fixture.author, "pr-1", "main", %{"lib/new.ex" => "# new\n"})
    git!(fixture.workspace, ["fetch", "--quiet", "origin", "pr-1"])
    ctx = Map.merge(ctx, fixture)

    assert {:error, :missing_workspace_path} = build(%{ctx | record: %{}}, gated)
    assert {:error, :missing_workspace_path} = Context.build(issue(), %{}, gated, ctx.settings)

    lone = Path.join(ctx.root, "lone")
    File.mkdir_p!(lone)
    git!(lone, ["init", "--quiet"])
    assert {:error, {:git_failed, "fetch", _status, _output}} = build(%{ctx | record: %{ctx.record | workspace_path: lone}}, gated)

    assert {:error, {:commit_unavailable, _sha, _status, _output}} = build(ctx, String.duplicate("d", 40))

    failing_merge = fn args, cwd ->
      if "merge" in args, do: {"merge: refusing", 128}, else: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)
    end

    assert {:error, {:git_failed, "merge", 128, "merge: refusing"}} = build(ctx, gated, git: failing_merge)
    assert_no_worktree(ctx, gated)
  end

  test "worktree_path/4 nests the build under the workspace root by repo and issue", %{settings: settings} do
    sha = String.duplicate("a", 40)
    root = Path.expand(settings.workspace.root)

    assert Context.worktree_path(settings, "app", "TP-1", sha) == Path.join([root, ".acceptance-gate", "app", "TP-1-aaaaaaaaaaaa"])
    assert Context.worktree_path(settings, nil, nil, sha) == Path.join([root, ".acceptance-gate", "default", "issue-aaaaaaaaaaaa"])
  end

  defp build(ctx, sha, opts \\ []) do
    opts = Keyword.merge([run_store: FakeRunStore, tracker: FakeTracker, github: FakeGitHub, cache: :acceptance_gate_context_test_no_cache], opts)
    Context.build(issue(), ctx.record, sha, ctx.settings, opts)
  end

  defp issue, do: %Issue{id: "issue-1", identifier: "TP-1", title: "Gate me", state: "Auto Review"}

  defp assert_no_worktree(ctx, sha) do
    worktree = Context.worktree_path(ctx.settings, "app", "TP-1", sha)
    refute File.exists?(worktree)
    refute File.exists?(worktree <> ".attributes")
    assert git!(ctx.workspace, ["worktree", "list", "--porcelain"]) |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "worktree ")) == 1
  end

  defp pr_url(number), do: "#{@repo_url}/pull/#{number}"

  defp open_pr(number, files), do: %{number: number, url: pr_url(number), title: "PR #{number}", head_sha: "head-#{number}", files: files}

  # A bare `origin`, an author clone that pushes branches to it, and the issue workspace: a clone
  # made before any PR branch exists, so it has to fetch what it needs.
  defp fixture!(root, opts \\ []) do
    origin = Path.join(root, "origin.git")
    author = Path.join(root, "author")
    workspace = Path.join(root, "workspace")

    git!(root, ["init", "--quiet", "--bare", "-b", "main", origin])
    git!(root, ["init", "--quiet", "-b", "main", author])
    git!(author, ["remote", "add", "origin", origin])
    branch!(author, "main", "main", %{"lib/app.ex" => @app_ex, "web/app.js" => @app_js, "README.md" => @readme}, Keyword.put(opts, :start, :orphan))
    git!(root, ["clone", "--quiet", origin, workspace])

    record = %{issue_id: "issue-1", issue_identifier: "TP-1", repo_key: "app", pr_url: pr_url(1), workspace_path: workspace}
    %{author: author, workspace: workspace, record: record}
  end

  defp branch!(author, name, from, files, opts \\ []) do
    if Keyword.get(opts, :start) != :orphan, do: git!(author, ["checkout", "--quiet", "-B", name, from])

    Enum.each(files, fn {path, content} ->
      path = Path.join(author, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    env = for date <- List.wrap(Keyword.get(opts, :date)), key <- ["GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE"], do: {key, date}
    git!(author, ["add", "-A"])
    git!(author, ["commit", "--quiet", "-m", "#{name}: #{Enum.join(Map.keys(files), ", ")}"], env)
    git!(author, ["push", "--quiet", "--force", "origin", "HEAD:refs/heads/#{name}"])
    git!(author, ["rev-parse", "HEAD"])
  end

  defp git!(dir, args, env \\ []) do
    identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgSign=false"]
    env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"} | env]

    case System.cmd("git", ["-C", dir | identity ++ args], stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
