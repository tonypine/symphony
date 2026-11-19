defmodule SymphonyElixir.CLICheckTest do
  use ExUnit.Case

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias SymphonyElixir.CLI
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.OpenRouter.{Models, Stub}
  alias SymphonyElixir.Secret
  alias SymphonyElixir.Workflow

  @secret "lin_api_check_secret_value"

  setup do
    original_symphony_path = Application.get_env(:symphony_elixir, :symphony_file_path)
    original_cache_watch = Application.get_env(:symphony_elixir, :config_cache_watch)
    root = Path.join(System.tmp_dir!(), "symphony-cli-check-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "app"))
    File.write!(Path.join([root, "app", "WORKFLOW.md"]), "Repo prompt\n")
    Application.put_env(:symphony_elixir, :config_cache_watch, false)
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      restore_app_env(:symphony_file_path, original_symphony_path)
      restore_app_env(:config_cache_watch, original_cache_watch)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "exits 0 and prints the resolved path for a valid config", %{root: root} do
    path = write_symphony!(root, valid_symphony(root))

    {result, output} = check(["--config", path])

    assert result == {:halt, 0}
    assert output == "Config OK: #{path}\n"
    assert Workflow.symphony_file_path() == path
    refute_received :runtime_started
  end

  test "prints the build it runs on stderr, with its commit when the build has one", %{root: root} do
    path = write_symphony!(root, valid_symphony(root))
    original_build = Application.get_env(:symphony_elixir, :build)
    on_exit(fn -> restore_app_env(:build, original_build) end)
    version = :symphony_elixir |> Application.spec(:vsn) |> to_string()

    Application.put_env(:symphony_elixir, :build, [])
    assert check_io(["--config", path]) == {{:halt, 0}, "Config OK: #{path}\n", "Symphony #{version}\n"}

    Application.put_env(:symphony_elixir, :build, sha: "ABCDEF1234567890abcdef1234567890abcdef12")
    assert check_io(["--config", path]) == {{:halt, 0}, "Config OK: #{path}\n", "Symphony #{version} (abcdef1)\n"}
  end

  test "defaults to symphony.yml in the current folder", %{root: root} do
    path = write_symphony!(root, valid_symphony(root))

    {result, output} = File.cd!(root, fn -> check([]) end)

    assert result == {:halt, 0}
    assert output == "Config OK: #{path}\n"
  end

  test "accepts the forced-ticket concurrency keys and rejects forced_max below 1", %{root: root} do
    forced = "command: codex app-server\n  concurrency:\n    force_label: Rush\n    forced_max: 2\n    forced_stale_after_hours: 24"
    path = write_symphony!(root, String.replace(valid_symphony(root), "command: codex app-server", forced))

    assert check(["--config", path]) == {{:halt, 0}, "Config OK: #{path}\n"}
    assert %{force_label: "Rush", forced_max: 2, forced_stale_after_hours: 24} = Config.settings!().execution

    path = write_symphony!(root, String.replace(valid_symphony(root), "command: codex app-server", "command: codex app-server\n  concurrency:\n    forced_max: 0"))

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "forced_max"
  end

  test "loads linear.webhooks turned on, its secret resolved from the environment, and refuses it without a secret", %{root: root} do
    env = "SYMPHONY_LINEAR_WEBHOOK_SECRET"
    previous = System.get_env(env)
    on_exit(fn -> if previous, do: System.put_env(env, previous), else: System.delete_env(env) end)
    System.put_env(env, "linear-signing-secret")

    path = write_symphony!(root, valid_symphony(root) <> "linear:\n  webhooks:\n    enabled: true\n    secret: $#{env}\n")

    assert check(["--config", path]) == {{:halt, 0}, "Config OK: #{path}\n"}
    assert %{enabled: true, secret: secret} = Config.linear_webhook_settings()
    assert Secret.unwrap(secret) == "linear-signing-secret"

    path = write_symphony!(root, valid_symphony(root) <> "linear:\n  webhooks:\n    enabled: true\n")

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "linear.webhooks.secret is required when linear.webhooks.enabled is true"
  end

  describe "a workspace.source repo" do
    test "passes with a warning before Symphony has cloned it", %{root: root} do
      path = write_symphony!(root, managed_symphony(root))
      clone = Path.join([root, "clones", "octo", "hello"])

      {result, output} = check(["--config", path])

      assert result == {:halt, 0}

      assert output ==
               "Config OK: #{path}\nWarning: repo hello is not cloned yet: Symphony clones octo/hello into #{clone} when it starts, then reads its WORKFLOW.md\n"

      # Symphony's own boot check still needs the clone, which it makes first.
      assert {:error, {:missing_workflow_file, _path, :enoent}} = Config.validate_repo_workflows()
    end

    test "reads WORKFLOW.md from the clone once it exists", %{root: root} do
      path = write_symphony!(root, managed_symphony(root))
      File.mkdir_p!(Path.join([root, "clones", "octo", "hello", ".git"]))

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ "Missing WORKFLOW.md at #{Path.join([root, "clones", "octo", "hello", "WORKFLOW.md"])}"
    end
  end

  describe "a strategy: worktree repo" do
    test "fails when its workspace repo does not exist", %{root: root} do
      missing = Path.join(root, "does-not-exist")
      path = write_symphony!(root, worktree_symphony(root, missing))

      assert {{:error, message}, ""} = check(["--config", path])
      assert message == "Config error in #{path}: Invalid merged Symphony config: repo app: workspaces.repo does not exist: #{missing}"
    end

    test "fails when its workspace repo is not a git repository", %{root: root} do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)
      path = write_symphony!(root, worktree_symphony(root, plain))

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ "repo app: workspaces.repo is not a valid git repository: #{plain}"
    end

    test "passes when its workspace repo is a git repository", %{root: root} do
      primary = Path.join(root, "primary")
      File.mkdir_p!(primary)
      {_output, 0} = System.cmd("git", ["init", "-q", primary])
      path = write_symphony!(root, worktree_symphony(root, primary))

      assert check(["--config", path]) == {{:halt, 0}, "Config OK: #{path}\n"}
    end

    test "fails a global worktree strategy shared by several repos", %{root: root} do
      config =
        managed_symphony(root) <>
          """
            strategy: worktree
            repo: #{root}
          """

      path = write_symphony!(root, config)

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ "workspaces.strategy is global but repositories is multi-repo"
    end
  end

  test "reports invalid YAML with its location", %{root: root} do
    path = write_symphony!(root, "issues: [unclosed\n")

    assert {{:error, message}, ""} = check(["--config", path])
    assert message == "Config error in #{path}: Failed to parse symphony.yml: Unfinished flow collection (line: 1, column: 18)"
  end

  test "reports an unknown key", %{root: root} do
    path = write_symphony!(root, valid_symphony(root) <> "bogus_top: 1\n")

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "Config error in #{path}: "
    assert message =~ "unknown symphony.yml key `bogus_top`"
  end

  test "reports an invalid value without echoing it", %{root: root} do
    content = String.replace(valid_symphony(root), "provider: memory", "provider: memory\n  poll_interval_ms: #{@secret}")
    path = write_symphony!(root, content)

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "issues.poll_interval_ms is invalid"
    refute message =~ @secret
  end

  test "reports runs errors naming the key", %{root: root} do
    codex = "    codex:\n      command: codex app-server\n"
    default = "  default: {harness: codex, provider: openai, model: gpt-test}\n"

    cases = [
      {default, default <> "  bogus: {effort: low}\n",
       "runs.bogus is not a run kind; expected default or one of: implementation, breakdown, rework, landing, code_review, epic_review, ci_fix, review_feedback, qa, conductor"},
      {default, default <> "  pre_push_review: {effort: low}\n", "runs.pre_push_review is not a run kind"},
      {default, "  default: {harness: codex, provider: openai, model: gpt-test, effort: extreme}\n", "runs.default.effort must be one of: low, medium, high, xhigh, max"},
      {codex, "    codex:\n      command: codex app-server --effort high\n", "execution.harnesses.codex.command must not pass --effort; the run's entry sets the model and effort"},
      {default, "  default: {harness: codex, provider: bedrock, model: gpt-test}\n", "runs.default.provider must be one of: anthropic, openrouter, opencode-go, openai"},
      {default, "  default: {harness: codex, provider: openai, model: gpt-test, command: codex app-server}\n",
       "runs.default.command is a run kind's own; a harness's command for every run is execution.harnesses.<harness>.command"},
      {default, default <> "  landing: {provider: openrouter, model: openai/gpt-5}\n", "runs.landing runs the codex harness on openrouter, which it cannot reach; codex runs on: openai, opencode-go"},
      {default, "  default: {harness: codex, provider: openai}\n", "runs.implementation resolves no model; set `model` there or in runs.default"},
      {default, "", "resolves no harness"}
    ]

    for {old, new, expected} <- cases do
      Cache.clear()
      path = write_symphony!(root, String.replace(valid_symphony(root), old, new))

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ "Config error in #{path}: "
      assert message =~ expected
    end
  end

  test "refuses the old agent section", %{root: root} do
    path = write_symphony!(root, valid_symphony(root) <> "agent:\n  runtime: codex\n")

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "unknown symphony.yml key `agent`"
  end

  describe "OpenRouter key" do
    setup do
      previous = System.get_env("OPENROUTER_API_KEY")
      previous_request = Application.get_env(:symphony_elixir, :openrouter_models_request)
      System.delete_env("OPENROUTER_API_KEY")
      Models.clear_cache()

      on_exit(fn ->
        if previous, do: System.put_env("OPENROUTER_API_KEY", previous), else: System.delete_env("OPENROUTER_API_KEY")
        restore_app_env(:openrouter_models_request, previous_request)
        Models.clear_cache()
      end)
    end

    test "warns when a profile uses openrouter and OPENROUTER_API_KEY is unset", %{root: root} do
      path = write_symphony!(root, openrouter_symphony(root))

      {result, output} = check(["--config", path])

      assert result == {:halt, 0}

      assert output ==
               "Config OK: #{path}\nWarning: OPENROUTER_API_KEY is not set; runs that use provider openrouter will fail to start (landing, ci_fix)\n"
    end

    test "warns when a run uses opencode-go and OPENCODE_API_KEY is unset, and not once it is set", %{root: root} do
      previous = System.get_env("OPENCODE_API_KEY")
      System.delete_env("OPENCODE_API_KEY")
      on_exit(fn -> if previous, do: System.put_env("OPENCODE_API_KEY", previous), else: System.delete_env("OPENCODE_API_KEY") end)

      runs = "  default: {harness: claude, provider: anthropic, model: claude-test}\n  qa: {provider: opencode-go, model: kimi-test, small_model: kimi-small}\n"
      path = write_symphony!(root, claude_symphony(root, runs))

      assert check(["--config", path]) ==
               {{:halt, 0}, "Config OK: #{path}\nWarning: OPENCODE_API_KEY is not set; runs that use provider opencode-go will fail to start (qa)\n"}

      System.put_env("OPENCODE_API_KEY", "oc-check-key")
      assert check(["--config", path]) == {{:halt, 0}, "Config OK: #{path}\n"}
    end

    test "does not warn, or print the key, when OPENROUTER_API_KEY is set and the model supports tools", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()
      path = write_symphony!(root, openrouter_symphony(root))

      {result, output} = check(["--config", path])

      assert result == {:halt, 0}
      assert output == "Config OK: #{path}\n"
      refute inspect(Config.settings!(), limit: :infinity) =~ "sk-or-v1-check-secret"
    end

    test "rejects openrouter on SSH workers naming the key", %{root: root} do
      path = write_symphony!(root, openrouter_symphony(root) <> "workers:\n  ssh_hosts: [worker-01]\n")

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ "runs.landing.provider openrouter is not supported with workers.ssh_hosts; OpenRouter runs start on the local host only"
    end

    test "check_findings is empty when the config does not load", %{root: root} do
      write_symphony!(root, "issues: [unclosed\n")
      Workflow.set_symphony_file_path(Path.join(resolved(root), "symphony.yml"))

      assert Config.check_findings() == %{errors: [], warnings: []}
    end

    test "does not ask the models API when no run uses openrouter", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      Application.put_env(:symphony_elixir, :openrouter_models_request, fn _url, _opts -> flunk("models API called") end)
      path = write_symphony!(root, valid_symphony(root))

      assert check(["--config", path]) == {{:halt, 0}, "Config OK: #{path}\n"}
    end

    test "rejects a model without tools, naming the key and the model id", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()
      path = write_symphony!(root, openrouter_symphony(root, "acme/chat-only"))

      assert {{:error, message}, ""} = check(["--config", path])

      assert message ==
               "Config error in #{path}: runs.landing.model: OpenRouter model `acme/chat-only` does not support tools; Symphony runs need tool use"
    end

    test "rejects a model id OpenRouter does not list", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()
      path = write_symphony!(root, openrouter_symphony(root, "acme/typo"))

      assert {{:error, message}, ""} = check(["--config", path])
      assert message == "Config error in #{path}: runs.landing.model: OpenRouter has no model `acme/typo`"
    end

    test "checks the harness's OpenRouter small model against OpenRouter's models, without asking for tools", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()

      path = write_symphony!(root, openrouter_symphony(root, "anthropic/claude-haiku-4.5", "acme/chat-only"))
      assert check(["--config", path]) == {{:halt, 0}, "Config OK: #{path}\n"}

      Cache.clear()
      path = write_symphony!(root, openrouter_symphony(root, "anthropic/claude-haiku-4.5", "acme/typo"))
      assert {{:error, message}, ""} = check(["--config", path])
      assert message == "Config error in #{path}: execution.harnesses.claude.small_model.openrouter: OpenRouter has no model `acme/typo`"
    end

    test "names a run entry's own small model", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()

      content = String.replace(openrouter_symphony(root), "landing: {provider: openrouter,", "landing: {small_model: acme/typo, provider: openrouter,")
      path = write_symphony!(root, content)

      assert {{:error, message}, ""} = check(["--config", path])
      assert message == "Config error in #{path}: runs.landing.small_model: OpenRouter has no model `acme/typo`"
    end

    test "rejects a blank small model", %{root: root} do
      path = write_symphony!(root, openrouter_symphony(root, "anthropic/claude-haiku-4.5", "\"  \""))

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ "execution.harnesses.claude.small_model.openrouter must not be blank"
    end

    test "rejects an OpenRouter run on a harness with no small model for it", %{root: root} do
      content = String.replace(openrouter_symphony(root), ", openrouter: anthropic/claude-haiku-4.5}", "}")
      path = write_symphony!(root, content)

      assert {{:error, message}, ""} = check(["--config", path])

      assert message =~
               "runs.landing runs the claude harness on openrouter with no small model for its background calls; set execution.harnesses.claude.small_model.openrouter"
    end

    test "warns when effort is set for a model without reasoning", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()

      content =
        claude_symphony(root, """
          default: {harness: claude, provider: openrouter, model: acme/tools-only, effort: high}
          landing: {effort: low}
        """)

      path = write_symphony!(root, content)

      assert check(["--config", path]) ==
               {{:halt, 0},
                """
                Config OK: #{path}
                Warning: runs.default.effort: OpenRouter model `acme/tools-only` does not support reasoning; its runs start without --effort high
                Warning: runs.landing.effort: OpenRouter model `acme/tools-only` does not support reasoning; its runs start without --effort low
                """}
    end

    test "names Code Review's reviewer and QA agent keys", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()

      content =
        claude_symphony(root, """
          default: {harness: claude, provider: openrouter, model: anthropic/claude-haiku-4.5}
          code_review: {model: acme/chat-only}
          qa: {model: acme/tools-only, effort: low}
        """)

      path = write_symphony!(root, content)

      assert check(["--config", path]) ==
               {{:error, "Config error in #{path}: runs.code_review.model: OpenRouter model `acme/chat-only` does not support tools; Symphony runs need tool use"},
                "Warning: runs.qa.effort: OpenRouter model `acme/tools-only` does not support reasoning; its runs start without --effort low\n"}
    end

    test "names the repository key that set the model", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()

      content =
        claude_symphony(root, """
          default: {harness: claude, provider: anthropic, model: claude-opus-5-5}
          ci_fix: {model: anthropic/claude-haiku-4.5}
        """) <>
          """
              runs:
                default: {provider: openrouter, model: acme/chat-only}
          """

      path = write_symphony!(root, content)

      assert check(["--config", path]) ==
               {{:error, "Config error in #{path}: repositories[app].runs.default.model: OpenRouter model `acme/chat-only` does not support tools; Symphony runs need tool use"}, ""}
    end

    test "names the repository run entry key that set the model or effort", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()

      content =
        claude_symphony(root, """
          default: {harness: claude, provider: openrouter, model: anthropic/claude-haiku-4.5}
          landing: {model: acme/tools-only}
        """) <>
          """
              runs:
                default: {effort: high}
                landing: {model: acme/chat-only}
                ci_fix: {model: acme/tools-only}
          """

      path = write_symphony!(root, content)

      assert check(["--config", path]) ==
               {{:error, "Config error in #{path}: repositories[app].runs.landing.model: OpenRouter model `acme/chat-only` does not support tools; Symphony runs need tool use"},
                "Warning: repositories[app].runs.default.effort: OpenRouter model `acme/tools-only` does not support reasoning; " <>
                  "its runs start without --effort high\n"}
    end

    test "names the key that set the effort when a repository run entry picked the model or the provider", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()

      content =
        claude_symphony(root, """
          default: {harness: claude, provider: anthropic, model: acme/tools-only}
          breakdown: {model: claude-opus-5-5, effort: xhigh}
          landing: {effort: high}
        """) <>
          """
              runs:
                breakdown: {provider: openrouter, model: acme/tools-only}
                landing: {provider: openrouter}
          """

      path = write_symphony!(root, content)

      assert check(["--config", path]) ==
               {{:halt, 0},
                """
                Config OK: #{path}
                Warning: runs.breakdown.effort: OpenRouter model `acme/tools-only` does not support reasoning; its runs start without --effort xhigh
                Warning: runs.landing.effort: OpenRouter model `acme/tools-only` does not support reasoning; its runs start without --effort high
                """}
    end

    test "names the key that set the model when a repository run entry picked openrouter", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()

      content =
        claude_symphony(root, """
          default: {harness: claude, provider: anthropic, model: claude-sonnet-5-5}
        """) <>
          """
              runs:
                landing: {provider: openrouter}
          """

      path = write_symphony!(root, content)

      assert check(["--config", path]) ==
               {{:error, "Config error in #{path}: runs.default.model: OpenRouter has no model `claude-sonnet-5-5`"}, ""}
    end

    test "names the key that set the model when the run entry that picked openrouter has none and it lacks tools", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      stub_models_api()

      content =
        claude_symphony(root, """
          default: {harness: claude, provider: anthropic, model: acme/chat-only}
          ci_fix: {provider: openrouter}
        """)

      path = write_symphony!(root, content)

      assert check(["--config", path]) ==
               {{:error, "Config error in #{path}: runs.default.model: OpenRouter model `acme/chat-only` does not support tools; Symphony runs need tool use"}, ""}
    end

    test "checks models against the QA stub in QA mode", %{root: root} do
      {:ok, stub, port} = Stub.start_link(log: fn _line -> :ok end)
      saved = Map.new(~w(SYMPHONY_BAR_QA_ROOT SYMPHONY_QA_OPENROUTER_URL), &{&1, System.get_env(&1)})

      on_exit(fn ->
        Stub.stop(stub)

        Enum.each(saved, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      System.put_env("SYMPHONY_BAR_QA_ROOT", root)
      System.put_env("SYMPHONY_QA_OPENROUTER_URL", Stub.url(port))
      System.put_env("OPENROUTER_API_KEY", Stub.valid_key())
      Application.put_env(:symphony_elixir, :openrouter_models_request, fn url, opts -> Req.get(url, opts) end)

      content =
        openrouter_symphony(root, "symphony-qa/no-tools")
        |> String.replace("anthropic/claude-haiku-4.5", "symphony-qa/tools-only")
        |> String.replace("model: claude-test}", "model: claude-test, effort: high}")

      path = write_symphony!(root, content)

      assert check(["--config", path]) ==
               {{:error, "Config error in #{path}: runs.landing.model: OpenRouter model `symphony-qa/no-tools` does not support tools; Symphony runs need tool use"},
                "Warning: runs.default.effort: OpenRouter model `symphony-qa/tools-only` does not support reasoning; " <>
                  "its runs start without --effort high\n"}
    end

    test "only warns when the models API cannot be reached", %{root: root} do
      System.put_env("OPENROUTER_API_KEY", "sk-or-v1-check-secret")
      unreachable = fn _url, _opts -> {:error, %Req.TransportError{reason: :nxdomain}} end
      Application.put_env(:symphony_elixir, :openrouter_models_request, unreachable)
      path = write_symphony!(root, openrouter_symphony(root, "acme/chat-only"))

      assert check(["--config", path]) ==
               {{:halt, 0}, "Config OK: #{path}\nWarning: could not reach the OpenRouter models API (non-existing domain); OpenRouter models were not checked\n"}
    end
  end

  defp stub_models_api do
    models = [
      %{"id" => "anthropic/claude-haiku-4.5", "supported_parameters" => ["tools", "reasoning"], "context_length" => 200_000},
      %{"id" => "acme/tools-only", "supported_parameters" => ["tools"], "context_length" => 32_000},
      %{"id" => "acme/chat-only", "supported_parameters" => ["max_tokens"], "context_length" => 8_192}
    ]

    Application.put_env(:symphony_elixir, :openrouter_models_request, fn "https://openrouter.ai/api/v1/models", _opts ->
      {:ok, %{status: 200, body: %{"data" => models}}}
    end)
  end

  defp openrouter_symphony(root, landing_model \\ "anthropic/claude-haiku-4.5", small_model \\ "anthropic/claude-haiku-4.5") do
    claude_symphony(
      root,
      """
        default: {harness: claude, provider: anthropic, model: claude-test}
        landing: {provider: openrouter, model: #{landing_model}}
        ci_fix: {provider: openrouter, model: anthropic/claude-haiku-4.5}
      """,
      small_model
    )
  end

  # `valid_symphony/1` on the claude harness, with `runs` as the lines of its `runs:` section.
  defp claude_symphony(root, runs, openrouter_small_model \\ "anthropic/claude-haiku-4.5") do
    valid_symphony(root)
    |> String.replace(
      "    codex:\n      command: codex app-server\n",
      "    claude:\n      command: claude\n      small_model: {anthropic: claude-haiku-test, openrouter: #{openrouter_small_model}}\n"
    )
    |> String.replace("  default: {harness: codex, provider: openai, model: gpt-test}\n", runs)
  end

  test "reports Code Review's reviewer and QA agent run errors naming the key", %{root: root} do
    cases = [
      {"  code_review: {effort: extreme}\n", "runs.code_review.effort must be one of: low, medium, high, xhigh, max"},
      {"  qa: {effort: extreme}\n", "runs.qa.effort must be one of: low, medium, high, xhigh, max"},
      {"  code_review: {command: codex app-server --model x, effort: low}\n", "runs.code_review.command must not pass --model"},
      {"  qa: {command: codex app-server --effort high, model: y}\n", "runs.qa.command must not pass --effort"}
    ]

    for {entry, expected} <- cases do
      Cache.clear()
      path = write_symphony!(root, String.replace(valid_symphony(root), "repositories:\n", entry <> "repositories:\n"))

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ "Config error in #{path}: "
      assert message =~ expected
    end
  end

  test "refuses a reviewer's or QA agent's run settings in its own section", %{root: root} do
    cases = [
      {"code_review:\n  effort: low\n", "unknown symphony.yml key `code_review.effort`"},
      {"code_review:\n  runtime: codex\n", "unknown symphony.yml key `code_review.runtime`"},
      {"auto_review:\n  model: y\n", "unknown symphony.yml key `auto_review.model`"},
      {"auto_review:\n  command: codex app-server\n", "unknown symphony.yml key `auto_review.command`"}
    ]

    for {section, expected} <- cases do
      Cache.clear()
      path = write_symphony!(root, valid_symphony(root) <> section)

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ expected
    end
  end

  test "refuses a pre_push_review section as an unknown key", %{root: root} do
    path = write_symphony!(root, valid_symphony(root) <> "pre_push_review:\n  enabled: true\n  run_on: first_push\n")

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "Config error in #{path}: "
    assert message =~ "unknown symphony.yml key `pre_push_review`"
  end

  test "reports a broken repo WORKFLOW.md", %{root: root} do
    File.write!(Path.join([root, "app", "WORKFLOW.md"]), "---\nbogus_workflow_key: 1\n---\nPrompt\n")
    path = write_symphony!(root, valid_symphony(root))

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "Config error in #{path}: "
    assert message =~ "repo app"
    assert message =~ "bogus_workflow_key"
  end

  test "reports a missing config file without validating", %{root: root} do
    path = Path.join(root, "missing.yml")

    assert {{:error, message}, ""} = check(["--config", path], check_config: fn -> flunk("validated a missing file") end)
    assert message == "Symphony config file not found: #{path}"
  end

  test "rejects unexpected arguments with check usage" do
    assert {{:error, message}, ""} = check(["extra"])
    assert message == "Usage: symphony check [--migrate] [--config <path-to-symphony.yml>]"

    assert {{:error, ^message}, ""} = check(["--port", "4000"])
  end

  test "lists check in the service usage" do
    assert {:error, message} = CLI.evaluate(["--bogus"])
    assert message =~ "symphony check [--migrate] [--config <path-to-symphony.yml>]"
  end

  describe "Config.format_error/1" do
    test "renders YAML parse errors for workflow files readably" do
      error = %YamlElixir.ParsingError{line: 2, column: 3, type: :x, message: "Bad indent"}

      assert Config.format_error({:workflow_parse_error, error}) ==
               "Failed to parse WORKFLOW.md: Bad indent (line: 2, column: 3)"
    end

    test "keeps inspecting non-YAML parse reasons" do
      assert Config.format_error({:symphony_parse_error, :eof}) == "Failed to parse symphony.yml: :eof"
    end

    test "falls back to inspect for reasons without a dedicated message" do
      assert Config.format_error(:missing_linear_api_token) == ":missing_linear_api_token"
    end
  end

  # A reviewer block as the file carried it before the rename: one the new build can run.
  @pre_push_review "pre_push_review:\n  enabled: true\n"

  describe "check --migrate" do
    test "checks a migrated copy, says what moved and leaves the file alone", %{root: root} do
      content = valid_symphony(root) <> @pre_push_review <> "  run_on: first_push\n"
      path = write_symphony!(root, content)

      {result, output} = check(["--migrate", "--config", path])

      assert result == {:halt, 0}
      assert output =~ "Migrated: v0.0.1.691 renamed `pre_push_review` to `code_review` in your settings\n"
      assert output =~ "Config OK: #{path}\n"
      assert File.read!(path) == content
      assert Workflow.symphony_file_path() == path
      assert File.ls!(resolved(root)) |> Enum.sort() == ["app", "symphony.yml"]
    end

    test "migrates a file from before the agent section moved, old run profiles and all", %{root: root} do
      content = """
      issues:
        provider: memory
      agent:
        runtime: codex
        command: codex app-server
        model: gpt-5
        run_profiles:
          pre_push_review:
            effort: high
      repositories:
        - key: app
          workflow: #{Path.join([root, "app", "WORKFLOW.md"])}
          default: true
          agent:
            run_profiles:
              pre_push_review:
                model: gpt-5-mini
          route:
            team: Test
      """

      path = write_symphony!(root, content)

      {result, output} = check(["--migrate", "--config", path])

      assert result == {:halt, 0}
      assert output =~ "`agent.run_profiles.pre_push_review` to `code_review`"
      assert output =~ "`repositories[].agent.run_profiles.pre_push_review` to `code_review`"
      assert output =~ "moved `agent` to `execution` and `runs` in your settings\n"
      assert output =~ "Config OK: #{path}\n"
      assert File.read!(path) == content
    end

    test "passes a file with nothing to migrate as the plain check does", %{root: root} do
      path = write_symphony!(root, valid_symphony(root))

      assert check(["--migrate", "--config", path]) == {{:halt, 0}, "Config OK: #{path}\n"}
    end

    test "refuses what it can't migrate, naming every key and its line, and removes its copy", %{root: root} do
      content = "pre_push_review:\n  enabled: true\n" <> valid_symphony(root) <> "tracker:\n  kind: linear\ndispatch: {max_concurrent: 3}\n"
      path = write_symphony!(root, content)
      tracker_line = content |> String.split("\n") |> Enum.find_index(&(&1 == "tracker:")) |> Kernel.+(1)

      {{:error, message}, _output, _stderr} = check_io(["--migrate", "--config", path])

      assert message =~ "Config error in #{path}: "
      assert message =~ "Lines it can't read: "
      assert message =~ "`dispatch.max_concurrent`"
      assert message =~ "#{tracker_line} (`tracker`)"
      refute message =~ "pre_push_review"
      refute message =~ ".migrate-"
      assert File.read!(path) == content
      assert File.ls!(resolved(root)) |> Enum.sort() == ["app", "symphony.yml"]
    end

    test "names the lines when nothing migrates too", %{root: root} do
      content = valid_symphony(root) <> "tracker:\n  kind: linear\n"
      path = write_symphony!(root, content)

      {{:error, message}, _output, _stderr} = check_io(["--migrate", "--config", path])

      assert message =~ "(`tracker`)"
    end

    test "migrates a block whose only key is removed, beside a rename", %{root: root} do
      content = @pre_push_review <> valid_symphony(root) <> "ledger:\n  artifact_retention_days: 30\n"
      path = write_symphony!(root, content)

      {result, output} = check(["--migrate", "--config", path])

      assert result == {:halt, 0}
      assert output =~ "removed `ledger.artifact_retention_days`"
      assert File.read!(path) == content

      assert {{:halt, 0}, _output, _stderr} = evaluate_io(["config", "migrate", "--config", path])
      assert File.read!(path) =~ "\nledger: {}\n"
      assert {{:halt, 0}, _output} = check(["--config", path])
    end

    test "refuses a migratable key that isn't on a line of its own", %{root: root} do
      path = write_symphony!(root, valid_symphony(root) <> "ledger: {artifact_retention_days: 3}\n")

      {{:error, message}, _output, _stderr} = check_io(["--migrate", "--config", path])

      assert message =~ "Config error in #{path}: Lines it can't rewrite: "
    end
  end

  describe "config" do
    test "migrate rewrites the file, with a backup, and says so", %{root: root} do
      path = write_symphony!(root, valid_symphony(root) <> @pre_push_review)

      {result, output, _stderr} = evaluate_io(["config", "migrate", "--config", path])

      assert result == {:halt, 0}
      assert output =~ "Migrated: v0.0.1.691 renamed `pre_push_review` to `code_review` in your settings\n"
      assert output =~ "Backup: #{path}.before-v"
      assert File.read!(path) =~ "\ncode_review:\n"
      assert {{:halt, 0}, _output} = check(["--config", path])
    end

    test "migrate says when there is nothing to do", %{root: root} do
      path = write_symphony!(root, valid_symphony(root))

      assert {{:halt, 0}, "Nothing to migrate: " <> _rest, ""} = evaluate_io(["config", "migrate", "--config", path])
    end

    test "migrate reports what it can't rewrite and a missing file", %{root: root} do
      path = write_symphony!(root, "ledger: {artifact_retention_days: 3}\n")

      assert {{:error, message}, "", ""} = evaluate_io(["config", "migrate", "--config", path])
      assert message =~ "Config error in #{path}: Lines it can't rewrite: "

      missing = Path.join(resolved(root), "missing.yml")
      assert {{:error, "Symphony config file not found: " <> _rest}, "", ""} = evaluate_io(["config", "migrate", "--config", missing])
    end

    test "migrations prints the table", _context do
      {{:halt, 0}, output, ""} = evaluate_io(["config", "migrations"])

      assert [%{"key" => "pre_push_review", "to" => "code_review"} | _rest] = Jason.decode!(output)
    end

    test "anything else prints its usage", _context do
      for args <- [[], ["nope"], ["migrate", "--nope"], ["migrate", "extra"]] do
        assert {{:error, "Usage: symphony config migrate" <> _rest}, "", ""} = evaluate_io(["config" | args])
      end
    end
  end

  describe "at start" do
    @start_overrides [
      set_state_root_from_env: &__MODULE__.ok/0,
      set_logs_root_from_env: &__MODULE__.ok/0,
      set_server_port_override: &__MODULE__.ok/1,
      set_server_host_override: &__MODULE__.ok/1
    ]

    test "the service migrates the file once and logs a note", %{root: root} do
      path = write_symphony!(root, valid_symphony(root) <> "pre_push_review:\n  enabled: true\n")

      log =
        capture_log(fn ->
          assert CLI.configure(["--config", path], cli_deps(@start_overrides)) == :ok
        end)

      assert log =~ "symphony.yml migrated: v0.0.1.691 renamed `pre_push_review` to `code_review` in your settings"
      assert log =~ "the file as it was: #{path}.before-v"
      assert File.read!(path) =~ "\ncode_review:\n"

      assert capture_log(fn -> assert CLI.configure(["--config", path], cli_deps(@start_overrides)) == :ok end) == "",
             "once: the file has nothing left to move"
    end

    test "the service refuses a file it can't rewrite", %{root: root} do
      path = write_symphony!(root, "ledger: {artifact_retention_days: 3}\n")

      assert {:error, message} = CLI.configure(["--config", path], cli_deps(@start_overrides))
      assert message =~ "Config error in #{path}: Lines it can't rewrite: "
    end

    test "symphony run migrates the file too", %{root: root} do
      path = write_symphony!(root, "ledger: {artifact_retention_days: 3}\n")
      deps = cli_deps(@start_overrides)

      assert {{:error, message, 2}, "", ""} = evaluate_io(["run", "TP-1", "--config", path], deps)
      assert message =~ "Lines it can't rewrite: "
    end
  end

  @doc false
  def ok, do: :ok
  @doc false
  def ok(_value), do: :ok

  defp check(args, overrides \\ []) do
    {result, output, _stderr} = check_io(args, overrides)
    {result, output}
  end

  # Also returns what the check printed on stderr: the build line, then any error.
  defp check_io(args, overrides \\ []) do
    {result, output, stderr} = evaluate_io(["check" | args], cli_deps(overrides))
    refute_received :runtime_started
    {result, output, stderr}
  end

  defp evaluate_io(args, deps \\ cli_deps([])) do
    {{result, output}, stderr} = with_io(:stderr, fn -> with_io(fn -> CLI.evaluate(args, deps) end) end)
    {result, output, stderr}
  end

  defp cli_deps(overrides) do
    parent = self()

    %{
      check_config: &Config.check_repo_workflows/0,
      check_findings: &Config.check_findings/0,
      file_regular?: &File.regular?/1,
      init: fn _args -> flunk("init called") end,
      set_symphony_file_path: &Workflow.set_symphony_file_path/1,
      set_state_root: fn _path -> flunk("state root set") end,
      set_state_root_from_env: fn -> flunk("state root env read") end,
      set_logs_root: fn _path -> flunk("logs root set") end,
      set_logs_root_from_env: fn -> flunk("logs root env read") end,
      set_server_host_override: fn _host -> flunk("host set") end,
      set_server_port_override: fn _port -> flunk("port set") end,
      ensure_all_started: fn ->
        send(parent, :runtime_started)
        {:ok, []}
      end,
      run_one_shot: fn _identifier, _opts ->
        send(parent, :runtime_started)
        {:ok, %{}}
      end
    }
    |> Map.merge(Map.new(overrides))
  end

  defp write_symphony!(root, content) do
    path = Path.join(resolved(root), "symphony.yml")
    File.write!(path, content)
    path
  end

  # macOS tmp dirs live behind a /private symlink; the CLI reports the path it expanded.
  defp resolved(root), do: File.cd!(root, &File.cwd!/0)

  defp valid_symphony(root) do
    """
    issues:
      provider: memory
    execution:
      harnesses:
        codex:
          command: codex app-server
    runs:
      default: {harness: codex, provider: openai, model: gpt-test}
    repositories:
      - key: app
        workflow: #{Path.join([root, "app", "WORKFLOW.md"])}
        default: true
        route:
          team: Test
    """
  end

  defp worktree_symphony(root, repo) do
    valid_symphony(root) <>
      """
          workspace:
            strategy: worktree
            repo: #{repo}
      """
  end

  defp managed_symphony(root) do
    valid_symphony(root) <>
      """
        - key: hello
          route:
            team: Other
          workspace:
            source: https://github.com/octo/hello
      workspaces:
        clones_root: #{Path.join(root, "clones")}
      """
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
