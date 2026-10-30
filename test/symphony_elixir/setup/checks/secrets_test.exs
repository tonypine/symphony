defmodule SymphonyElixir.Setup.Checks.SecretsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Paths
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Checks.Secrets

  @variables ~w(LINEAR_API_KEY SETUP_TEST_LINEAR_KEY OPENROUTER_API_KEY SETUP_TEST_SLACK_URL SETUP_TEST_BAR SETUP_TEST_TOKEN SETUP_TEST_HOOK_URL SETUP_TEST_AUTH SETUP_TEST_WEBHOOK_SECRET)
  @settings_fix %{kind: "open", target: "settings", url: nil}

  # A Linear-side check, to see where Setup lists it.
  defmodule LinearCheck do
    @behaviour SymphonyElixir.Setup.Check

    def id, do: "linear_check"
    def title, do: "Linear check"
    def needs_linear?, do: true
    def run(_context), do: []
  end

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)
    secret_file = Paths.github_webhook_secret_file()
    previous_secret_file = File.read(secret_file)
    File.rm(secret_file)
    Application.put_env(:symphony_elixir, :setup_gh_runner, fn ["auth", "status"], _opts -> {"Logged in to github.com\n", 0} end)

    on_exit(fn ->
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
      Application.delete_env(:symphony_elixir, :setup_gh_runner)

      case previous_secret_file do
        {:ok, contents} -> File.write!(secret_file, contents)
        {:error, _reason} -> File.rm(secret_file)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path())
    :ok
  end

  defp problems, do: Setup.check(checks: [Secrets], linear_api_key?: true).problems

  defp append_symphony!(lines) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> lines)
    Cache.clear()
  end

  # A second repo, `app`, that Symphony clones itself from `acme/app`.
  defp add_managed_repo! do
    path = Workflow.symphony_file_path()
    managed = ~s({"key": "app", "route": {"team": "Ops"}, "workspace": {"source": "acme/app"}})
    File.write!(path, String.replace(File.read!(path), ~r/^repositories: \[(.*)\]$/m, "repositories: [\\1, #{managed}]"))
    Cache.clear()
  end

  defp detail(problem, label), do: Enum.find_value(problem.details, &(&1.label == label && &1.value))

  test "names itself, reads no Linear and has nothing to report on a config without secrets" do
    assert Secrets.id() == "secret"
    assert is_binary(Secrets.title())
    refute Secrets.needs_linear?()
    assert problems() == []
  end

  test "an unset $VAR in a notification channel url is an error naming the key and variable; setting it clears it" do
    write_workflow_file!(Workflow.workflow_file_path(),
      notifications: %{enabled: true, channels: [%{kind: "slack", url: "$SETUP_TEST_SLACK_URL", events: ["run_failed"]}]}
    )

    assert [problem] = problems()
    assert problem.id == "secret:notifications.channels[0].url"
    assert problem.severity == "error"
    assert problem.category == "secrets"
    assert problem.title =~ "notifications.channels[0].url"
    assert problem.title =~ "SETUP_TEST_SLACK_URL"
    assert problem.consequence == "Notifications to the slack channel notifications.channels[0] never send."
    assert detail(problem, "Key") == "notifications.channels[0].url"
    assert detail(problem, "Variable") == "SETUP_TEST_SLACK_URL"
    assert problem.fix == @settings_fix

    System.put_env("SETUP_TEST_SLACK_URL", "https://hooks.slack.test/services/T000/B000/sekret")
    assert problems() == []
  end

  test "an unset $VAR in an MCP server's env is an error, and the agent still gets the literal reference" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{
        servers: %{
          "docs" => %{transport: "http", url: "https://docs.example/mcp", headers: %{Authorization: "$SETUP_TEST_AUTH", Plain: "value"}, runtimes: ["claude"]},
          "search" => %{transport: "stdio", command: "node", env: %{FOO: "$SETUP_TEST_BAR", LEVEL: "info"}}
        }
      }
    )

    assert [headers, env] = problems()
    assert env.id == "secret:agent.mcp.servers.search.env.FOO"
    assert detail(env, "Variable") == "SETUP_TEST_BAR"
    assert env.consequence == "The search MCP server starts without a value for FOO, so its calls may fail."
    assert headers.id == "secret:agent.mcp.servers.docs.headers.Authorization"
    assert headers.consequence == "The docs MCP server is called without a value for Authorization, so its calls may fail."
    assert Config.settings!().agent.mcp.servers["search"].env["FOO"] == "$SETUP_TEST_BAR"

    # An empty variable resolves to nothing too.
    System.put_env("SETUP_TEST_BAR", " ")
    assert [_headers, %{id: "secret:agent.mcp.servers.search.env.FOO"}] = problems()

    System.put_env("SETUP_TEST_BAR", "bar")
    System.put_env("SETUP_TEST_AUTH", "Bearer sekret")
    assert problems() == []
  end

  test "an unset webhook_url or header of a channel is an error naming what fails" do
    write_workflow_file!(Workflow.workflow_file_path(),
      notifications: %{
        enabled: true,
        channels: [
          %{kind: "webhook", url: "https://notify.test/events", events: ["run_failed"], headers: %{"X-Token" => "$SETUP_TEST_TOKEN", "X-Plain" => "on"}},
          %{kind: "slack", webhook_url: "$SETUP_TEST_HOOK_URL", events: ["run_failed"]}
        ]
      }
    )

    assert [header, hook] = problems()
    assert header.id == "secret:notifications.channels[0].headers.X-Token"
    assert header.consequence == "Notifications to the webhook channel notifications.channels[0] are sent without their X-Token header."
    assert hook.id == "secret:notifications.channels[1].webhook_url"
    assert hook.consequence =~ "never send"
  end

  test "an unset github.webhooks.secret is an error until a handed-off secret file stands in for it" do
    append_symphony!(~s(github: {"webhooks": {"secret": "$SETUP_TEST_WEBHOOK_SECRET"}}\n))

    assert [problem] = problems()
    assert problem.id == "secret:github.webhooks.secret"
    assert detail(problem, "Variable") == "SETUP_TEST_WEBHOOK_SECRET"
    assert problem.consequence =~ "webhook deliveries"

    File.mkdir_p!(Path.dirname(Paths.github_webhook_secret_file()))
    File.write!(Paths.github_webhook_secret_file(), "handed-off")
    assert problems() == []
  end

  test "a symphony.yml it can't read has no references to report" do
    append_symphony!(~s(github: {"webhooks": {"secret": "$SETUP_TEST_WEBHOOK_SECRET"}}\n))
    context = %{system: Config.system!(), symphony_path: Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.yml")}

    assert Secrets.run(context) == []
  end

  test "an openrouter run profile without OPENROUTER_API_KEY is an error naming the run kinds" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      agent_command: "claude",
      agent_run_profiles: %{
        "landing" => %{provider: "openrouter", model: "anthropic/claude-haiku-4.5"},
        "ci_fix" => %{provider: "openrouter", model: "anthropic/claude-haiku-4.5"}
      }
    )

    assert [problem] = problems()
    assert problem.id == "secret:OPENROUTER_API_KEY"
    assert problem.severity == "error"
    assert problem.repos == ["default"]
    assert detail(problem, "Variable") == "OPENROUTER_API_KEY"
    kinds = detail(problem, "Run kinds")
    assert kinds =~ "landing" and kinds =~ "ci_fix"
    assert problem.consequence =~ kinds
    assert problem.fix == @settings_fix

    System.put_env("OPENROUTER_API_KEY", "sk-or-sekret")
    assert problems() == []
  end

  describe "the Linear API key" do
    test "missing is one error, and the Linear-side checks are not checked" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

      refute Secrets.linear_api_key?()
      assert %{problems: [problem], not_checked: [%{id: "linear_check"}]} = Setup.check(checks: [LinearCheck, Secrets])
      assert problem.id == "secret:LINEAR_API_KEY"
      assert problem.title == "Symphony can't read Linear: no ticket is picked up"
      assert detail(problem, "Variable") == "LINEAR_API_KEY"
      assert problem.fix == @settings_fix

      System.put_env("LINEAR_API_KEY", "lin_api_sekret")
      Cache.clear()
      assert Secrets.linear_api_key?()
      assert problems() == []
    end

    test "names the variable issues.linear.api_key refers to, then the fallback" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: "$SETUP_TEST_LINEAR_KEY")

      assert [problem] = problems()
      assert detail(problem, "Variable") == "SETUP_TEST_LINEAR_KEY or LINEAR_API_KEY"
    end

    test "a config that doesn't load reports nothing and counts as no key" do
      File.write!(Workflow.symphony_file_path(), "pull_request: 1\n")
      Cache.clear()

      refute Secrets.linear_api_key?()
      assert problems() == []
    end
  end

  describe "GitHub auth for managed repos" do
    setup do
      add_managed_repo!()
      :ok
    end

    test "a signed-in gh is no problem" do
      assert problems() == []
    end

    test "a gh that isn't signed in is an error naming the repos" do
      Application.put_env(:symphony_elixir, :setup_gh_runner, fn ["auth", "status"], _opts -> {"You are not logged into any GitHub hosts.\n", 1} end)

      assert [problem] = problems()
      assert problem.id == "secret:github_auth"
      assert problem.title == "The GitHub CLI isn't signed in to GitHub"
      assert problem.repos == ["app"]
      assert problem.consequence =~ "app"
      assert problem.fix == @settings_fix
    end

    test "a missing gh is an error saying so" do
      missing_gh = fn _args, _opts -> raise ErlangError, original: :enoent end
      Application.put_env(:symphony_elixir, :setup_gh_runner, missing_gh)

      assert [%{title: "The GitHub CLI (gh) isn't installed"}] = problems()
    end
  end

  test "the payload names variables, never their values, and with every secret set there is no problem" do
    System.put_env("SETUP_TEST_SLACK_URL", "https://hooks.slack.test/services/sekret-1")
    System.put_env("SETUP_TEST_AUTH", "Bearer sekret-2")

    Application.put_env(:symphony_elixir, :setup_gh_runner, fn ["auth", "status"], _opts ->
      {"github.com\n  X Failed to log in using token (GH_TOKEN)\n  - Token: gho_sekret-3\n", 1}
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      notifications: %{
        enabled: true,
        channels: [
          %{kind: "slack", url: "$SETUP_TEST_SLACK_URL", events: ["run_failed"]},
          %{kind: "slack", webhook_url: "$SETUP_TEST_HOOK_URL", events: ["run_failed"]}
        ]
      },
      agent_mcp: %{servers: %{"docs" => %{transport: "http", url: "https://docs.example/mcp", headers: %{Authorization: "$SETUP_TEST_AUTH"}, runtimes: ["claude"]}}}
    )

    add_managed_repo!()

    payload = Setup.check(checks: [Secrets])

    assert Enum.map(payload.problems, & &1.id) == ["secret:LINEAR_API_KEY", "secret:notifications.channels[1].webhook_url", "secret:github_auth"]
    refute Jason.encode!(payload) =~ "sekret"

    System.put_env("LINEAR_API_KEY", "lin_api_sekret-4")
    System.put_env("SETUP_TEST_HOOK_URL", "https://hooks.slack.test/services/sekret-5")
    Application.put_env(:symphony_elixir, :setup_gh_runner, fn ["auth", "status"], _opts -> {"Logged in to github.com\n", 0} end)
    Cache.clear()

    assert problems() == []
  end
end
