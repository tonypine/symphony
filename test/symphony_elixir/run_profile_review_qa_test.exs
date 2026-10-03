defmodule SymphonyElixir.RunProfileReviewQaTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.{QaAgent, ReviewAgent, RunKind}

  @sha "0123456789abcdef0123456789abcdef01234567"

  defp symphony(sections) do
    Map.merge(
      %{
        "issues" => %{"provider" => "memory"},
        "agent" => %{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"},
        "repositories" => [%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}]
      },
      sections
    )
  end

  defp settings!(sections) do
    {:ok, system} = SystemSchema.parse(symphony(sections))
    {:ok, settings} = Schema.parse(SystemSchema.to_config_map(system))
    settings
  end

  defp error!(sections) do
    assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(symphony(sections))
    message
  end

  defp agent(fields), do: Map.merge(%{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"}, fields)

  describe "profile precedence" do
    test "nothing set resolves to nil model and effort" do
      settings = settings!(%{})

      assert Config.pre_push_review_profile(settings) == %{kind: :pre_push_review, model: nil, effort: nil}
      assert Config.qa_profile(settings) == %{kind: :qa, model: nil, effort: nil}
    end

    test "own field, then agent.run_profiles.<kind>, then agent.model / agent.effort" do
      base = %{
        "agent" =>
          agent(%{
            "model" => "claude-sonnet-5-5",
            "effort" => "medium",
            "run_profiles" => %{"pre_push_review" => %{"effort" => "high"}, "qa" => %{"model" => "claude-haiku-4-5"}}
          })
      }

      settings = settings!(base)
      assert Config.pre_push_review_profile(settings) == %{kind: :pre_push_review, model: "claude-sonnet-5-5", effort: "high"}
      assert Config.qa_profile(settings) == %{kind: :qa, model: "claude-haiku-4-5", effort: "medium"}

      settings =
        settings!(
          Map.merge(base, %{
            "pre_push_review" => %{"model" => " claude-opus-5-5 ", "effort" => "max"},
            "auto_review" => %{"effort" => "low"}
          })
        )

      assert Config.pre_push_review_profile(settings) == %{kind: :pre_push_review, model: "claude-opus-5-5", effort: "max"}
      assert Config.qa_profile(settings) == %{kind: :qa, model: "claude-haiku-4-5", effort: "low"}
    end
  end

  describe "validation errors name the key" do
    test "unknown or blank reviewer and QA fields" do
      assert error!(%{"pre_push_review" => %{"effort" => "extreme"}}) =~ "pre_push_review.effort must be one of: low, medium, high, xhigh, max"
      assert error!(%{"auto_review" => %{"effort" => "extreme"}}) =~ "auto_review.effort must be one of: low, medium, high, xhigh, max"
      assert error!(%{"pre_push_review" => %{"model" => " "}}) =~ "pre_push_review.model must not be blank"
      assert error!(%{"auto_review" => %{"model" => 5}}) =~ "auto_review.model is invalid"
    end

    test "--model / --effort in the reviewer command when a profile reaches it" do
      message = error!(%{"pre_push_review" => %{"command" => "claude --model x --effort=high", "effort" => "low"}})

      assert message =~ "pre_push_review.command must not pass --model when a model or effort is set for the pre-push reviewer"
      assert message =~ "pre_push_review.command must not pass --effort when"

      assert error!(%{
               "agent" => agent(%{"run_profiles" => %{"pre_push_review" => %{"model" => "y"}}}),
               "pre_push_review" => %{"command" => "claude --effort high"}
             }) =~ "pre_push_review.command must not pass --effort"

      assert error!(%{"agent" => agent(%{"effort" => "low"}), "pre_push_review" => %{"command" => "claude --model x"}}) =~
               "pre_push_review.command must not pass --model"
    end

    test "--model / --effort in the QA command when a profile reaches it" do
      assert error!(%{"auto_review" => %{"command" => "claude --model x", "model" => "y"}}) =~
               "auto_review.command must not pass --model when a model or effort is set for the QA agent"

      assert error!(%{
               "agent" => agent(%{"run_profiles" => %{"qa" => %{"effort" => "low"}}}),
               "auto_review" => %{"command" => "claude --effort high"}
             }) =~ "auto_review.command must not pass --effort"
    end

    test "the QA fallback to agent.command conflicts only through the QA agent's own fields" do
      message = error!(%{"agent" => agent(%{"command" => "claude --model x"}), "auto_review" => %{"effort" => "low"}})

      assert message =~ "auto_review.command is not set, and agent.command passes --model while auto_review.model or auto_review.effort is set"

      message = error!(%{"agent" => agent(%{"command" => "claude --model x", "effort" => "low"}), "auto_review" => %{"effort" => "low"}})

      assert message =~ "agent.command must not pass --model"
      refute message =~ "auto_review.command"
    end

    test "flags without a profile, and a profile without flags, load" do
      settings =
        settings!(%{
          "agent" => agent(%{"command" => "claude --model x"}),
          "pre_push_review" => %{"command" => "claude --model x --effort high"},
          "auto_review" => %{"command" => "claude --effort high"}
        })

      assert settings.review_agent.command == "claude --model x --effort high"

      settings =
        settings!(%{
          "agent" => agent(%{"effort" => "low"}),
          "pre_push_review" => %{"command" => "claude --model-hint x"},
          "auto_review" => %{"command" => "claude"}
        })

      assert settings.auto_review.command == "claude"
    end

    test "a flag conflict is reported with other errors in the same section" do
      message = error!(%{"pre_push_review" => %{"command" => "claude --model x", "model" => "y", "run_on" => "never"}})

      assert message =~ "pre_push_review.command must not pass --model"
      assert message =~ "pre_push_review.run_on is invalid"
    end

    test "the merged workflow schema checks the reviewer command too" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 "tracker" => %{"kind" => "memory"},
                 "agent" => %{"kind" => "claude", "command" => "claude"},
                 "review_agent" => %{"command" => "claude --effort low", "effort" => "high"}
               })

      assert message =~ "review_agent.command must not pass --effort"
    end
  end

  test "RunKind.label/1 reads profiles and run records" do
    assert RunKind.label(%{kind: :qa, model: "m", effort: nil}) == "qa · m · default"
    assert RunKind.label(%{run_kind: "landing", model: nil, effort: "low"}) == "landing · default · low"
    assert RunKind.label(%{status: "success"}) == nil
    assert RunKind.label(nil) == nil
  end

  describe "argv" do
    setup do
      test_root = Path.join(System.tmp_dir!(), "symphony-review-qa-profile-#{System.unique_integer([:positive])}")
      workspace_root = Path.join(test_root, "workspaces")
      fake_claude = Path.join(test_root, "fake-claude")
      argv_trace = Path.join(test_root, "argv.trace")
      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf(test_root) end)

      %{test_root: test_root, workspace_root: workspace_root, fake_claude: fake_claude, argv_trace: argv_trace}
    end

    # A Claude stand-in that records its argv and answers with `answer` as the turn result.
    defp write_fake_claude!(ctx, answer) do
      assistant = Jason.encode!(%{type: "assistant", message: %{content: [%{type: "text", text: answer}]}})
      result = Jason.encode!(%{type: "result", subtype: "success", is_error: false, num_turns: 1, session_id: "sess-profile"})

      File.write!(ctx.fake_claude, """
      #!/bin/sh
      cat > /dev/null
      printf '%s\\n' "$*" >> "#{ctx.argv_trace}"
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-profile","cwd":"/tmp","tools":[],"mcp_servers":[]}'
      printf '%s\\n' '#{assistant}'
      printf '%s\\n' '#{result}'
      exit 0
      """)

      File.chmod!(ctx.fake_claude, 0o755)
    end

    defp write_workflow!(ctx, overrides) do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(
          [
            tracker_kind: "memory",
            workspace_root: ctx.workspace_root,
            agent_kind: "claude",
            agent_command: ctx.fake_claude,
            review_agent: %{enabled: true, kind: "claude", command: ctx.fake_claude},
            auto_review: %{"runtime" => "claude", "command" => ctx.fake_claude}
          ],
          overrides
        )
      )
    end

    defp argv!(ctx) do
      [line] = ctx.argv_trace |> File.read!() |> String.split("\n", trim: true)
      File.rm!(ctx.argv_trace)
      line
    end

    defp review!(ctx) do
      repo = Path.join(ctx.workspace_root, "MT-REVIEW")
      File.mkdir_p!(repo)

      for args <- [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "t@example.test"],
            ["config", "user.name", "T"],
            ["commit", "-q", "--allow-empty", "-m", "base"],
            ["update-ref", "refs/remotes/origin/main", "HEAD"],
            ["commit", "-q", "--allow-empty", "-m", "change"]
          ] do
        {_output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
      end

      issue = %Issue{id: "issue-review", identifier: "MT-REVIEW", title: "Review", description: "Review it", state: "In Progress"}

      assert {:ok, %{verdict: :approve}} = ReviewAgent.evaluate(issue, repo, Config.settings!(), base_branch: "main")
      argv!(ctx)
    end

    defp qa!(ctx) do
      git = fn
        ["worktree", "add", "--detach", path, _sha], _cwd ->
          File.mkdir_p!(path)
          {"", 0}

        _args, _cwd ->
          {"", 0}
      end

      job = %{
        issue: %Issue{id: "issue-qa", identifier: "MT-QA", title: "QA", description: "Test it", state: "Auto Review", labels: []},
        sha: @sha,
        workspace_path: ctx.workspace_root,
        worker_host: nil,
        repo_key: "default",
        run_id: "qa-run",
        playbooks: [],
        token_limit: nil
      }

      assert {:ok, %{result: %{verdict: :pass}}} = QaAgent.run(job, Config.settings!(), git: git)
      argv!(ctx)
    end

    test "the reviewer and QA argv carry their own model and effort", ctx do
      write_fake_claude!(ctx, ~s({"verdict":"approve","findings":[]}))

      write_workflow!(ctx,
        agent_model: "claude-sonnet-5-5",
        agent_effort: "medium",
        agent_run_profiles: %{"pre_push_review" => %{"effort" => "xhigh"}, "qa" => %{"model" => "claude-haiku-4-5"}},
        review_agent: %{enabled: true, kind: "claude", command: ctx.fake_claude, model: "claude-opus-5-5"},
        auto_review: %{"runtime" => "claude", "command" => ctx.fake_claude, "effort" => "low"}
      )

      assert review!(ctx) =~ ~r/--print --model claude-opus-5-5 --effort xhigh$/

      write_fake_claude!(ctx, ~s({"verdict":"pass","summary":"ok","steps":[]}))
      assert qa!(ctx) =~ ~r/--print --model claude-haiku-4-5 --effort low$/
    end

    test "with nothing set the reviewer and QA argv are unchanged", ctx do
      write_fake_claude!(ctx, ~s({"verdict":"approve","findings":[]}))
      write_workflow!(ctx, [])

      argv = review!(ctx)
      assert argv =~ ~r/--print$/
      refute argv =~ "--model"
      refute argv =~ "--effort"

      write_fake_claude!(ctx, ~s({"verdict":"pass","summary":"ok","steps":[]}))
      argv = qa!(ctx)
      assert argv =~ ~r/--print$/
      refute argv =~ "--model"
      refute argv =~ "--effort"
    end

    test "the reviewer uses the profile resolved at dispatch when one is passed", ctx do
      write_fake_claude!(ctx, ~s({"verdict":"approve","findings":[]}))
      write_workflow!(ctx, agent_effort: "low")

      repo = Path.join(ctx.workspace_root, "MT-DISPATCH")
      File.mkdir_p!(repo)

      for args <- [
            ["init", "-q", "-b", "main"],
            ["-c", "user.email=t@e.t", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "a"],
            ["update-ref", "refs/remotes/origin/main", "HEAD"]
          ] do
        {_output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
      end

      issue = %Issue{id: "issue-dispatch", identifier: "MT-DISPATCH", title: "Review", description: "Review it", state: "In Progress"}
      profile = %{kind: :pre_push_review, model: "claude-opus-5-5", effort: nil}

      assert {:ok, %{verdict: :approve}} =
               ReviewAgent.evaluate(issue, repo, Config.settings!(), base_branch: "main", reviewer_run_profile: profile)

      assert argv!(ctx) =~ ~r/--print --model claude-opus-5-5$/
    end
  end
end
