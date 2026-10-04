defmodule SymphonyElixir.MixProject do
  use Mix.Project

  @version "0.0.1"

  def project do
    [
      app: :symphony_elixir,
      version: @version,
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          SymphonyElixir.Config,
          SymphonyElixir.Config.Cache,
          SymphonyElixir.Config.RepoWorkflowSchema,
          SymphonyElixir.Config.Schema,
          SymphonyElixir.Config.SystemSchema,
          SymphonyElixir.Config.SystemSchema.Repo,
          SymphonyElixir.ControlClient,
          SymphonyElixir.GitHub.PullRequest,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.Notifications,
          SymphonyElixir.Notifications.Channels.Slack,
          SymphonyElixir.Notifications.Channels.Webhook,
          SymphonyElixir.Notifications.Event,
          SymphonyElixir.Notifications.Notifier,
          SymphonyElixir.Repo.Supervisor,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.OneShot,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.CiPoller,
          SymphonyElixir.PrReviewPoller,
          SymphonyElixir.McpServer,
          SymphonyElixir.Quality,
          SymphonyElixir.QualityGate.Anthropic,
          SymphonyElixir.QualityGate.OpenAI,
          SymphonyElixir.Learnings.Reflection,
          SymphonyElixir.Learnings.Store,
          SymphonyElixir.RunStore,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.ReviewAgent,
          SymphonyElixir.AuditLog,
          SymphonyElixir.ReviewAgent.Context,
          SymphonyElixir.Verification,
          SymphonyElixir.Verification.DevServer,
          SymphonyElixir.Verification.PortPool,
          SymphonyElixir.CLI,
          SymphonyElixir.ClaudeCode.AppServer,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.Codex.MessageHumanizer,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard,
          SymphonyElixir.StatusDashboard.Renderer,
          SymphonyElixir.TerminalDashboard.Terminal,
          SymphonyElixir.LeftoverProcesses.Table,
          SymphonyElixir.LogFile,
          SymphonyElixir.Workflow,
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.Workspace,
          SymphonyElixirWeb.AuditController,
          SymphonyElixirWeb.AuditLive,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.ControlApiController,
          SymphonyElixirWeb.LearningsLive,
          SymphonyElixirWeb.ObservabilityApiController,
          SymphonyElixirWeb.Presenter,
          SymphonyElixirWeb.QualityLive,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.TranscriptLive,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers,
          Mix.Tasks.Symphony.Pause,
          Mix.Tasks.Symphony.Init,
          Mix.Tasks.Symphony.Audit,
          Mix.Tasks.Symphony.Resume,
          Mix.Tasks.Symphony.Stop,
          SymphonyElixir.Init,
          SymphonyElixir.AgentTools.Linear,
          SymphonyElixir.AgentTools.Linear.CommentRegistry,
          SymphonyElixir.QaDriver.Host
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix, :mnesia]
      ],
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger],
      included_applications: [:mnesia],
      env: [build: build_env()]
    ]
  end

  # The release workflow sets these when it builds the binary, so the running app knows the
  # commit it was built from (see `SymphonyElixir.BuildInfo`). A build from a checkout has none.
  defp build_env do
    [
      sha: System.get_env("SYMPHONY_BUILD_SHA"),
      repo: System.get_env("SYMPHONY_BUILD_REPO"),
      number: System.get_env("SYMPHONY_BUILD_NUMBER")
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.13", only: :test},
      {:phoenix, "~> 1.8.15"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.33"},
      {:req, "~> 0.7.4"},
      {:jason, "~> 1.4"},
      {:file_system, "~> 1.1"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.3"},
      {:ecto, "~> 3.14"},
      {:burrito, "~> 1.5", only: :prod, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      "audit.run_store": ["cmd elixir scripts/audit_run_store_repo_key.exs"],
      lint: ["specs.check", "audit.run_store", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: SymphonyElixir.CLI,
      name: "symphony",
      path: "bin/symphony"
    ]
  end

  defp releases do
    [
      symphony: [
        version: release_version(),
        include_executables_for: [:unix],
        applications: [
          symphony_elixir: :permanent
        ],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Burrito unpacks into a directory named after the release version and reuses
  # it when it already exists, so each packaged build needs its own version. The
  # build number goes in as a semver pre-release (0.0.1-42): Burrito's launcher
  # must parse the version as semver and orders numeric pre-releases by value, so
  # it still deletes the directories of older builds. A pre-release sorts below
  # the plain version, so an unsuffixed build's directory (such as one from
  # before build numbers) is never deleted and has to be removed by hand.
  defp release_version do
    case System.get_env("SYMPHONY_BUILD_NUMBER", "") do
      "" -> @version
      build -> "#{@version}-#{build}"
    end
  end
end
