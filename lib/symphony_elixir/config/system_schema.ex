defmodule SymphonyElixir.Config.SystemSchema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workspace

  # `defaults_to_struct: true` bakes each embed's struct into this schema at
  # compile time, but Ecto only records a runtime reference to the embed. The
  # requires make Mix recompile this module when an embed's defaults change,
  # instead of keeping the old default after an incremental build.
  require Schema.Agent
  require Schema.AutoReview
  require Schema.Ci
  require Schema.Dependencies
  require Schema.GitHub
  require Schema.HumanActions
  require Schema.Learnings
  require Schema.Notifications
  require Schema.Observability
  require Schema.Poller
  require Schema.Polling
  require Schema.PrReview
  require Schema.QualityGate
  require Schema.ReviewAgent
  require Schema.Server
  require Schema.Tracker
  require Schema.Verification
  require Schema.Watchdog
  require Schema.Worker
  require Schema.Workspace

  @primary_key false
  @allowed_keys ~w(
    agent auto_review dashboard dependency_audit github human_actions issue_gate issues notifications poller pre_push_review
    pull_requests
    repositories verification watchdog workers workspaces
  )

  @removed_top_level_keys %{
    "ci" => "use `pull_requests.checks`",
    "dependencies" => "use `dependency_audit`",
    "dispatch" => "remove it; use `agent.concurrency.max_total`",
    "learnings" => "use `pull_requests.learnings`",
    "observability" => "use `dashboard`",
    "polling" => "use `issues.poll_interval_ms`",
    "pr_review" => "use `pull_requests.review_comments`",
    "quality_gate" => "use `issue_gate`",
    "repos" => "use `repositories`",
    "review_agent" => "use `pre_push_review`",
    "self_review" => "use `pre_push_review`",
    "server" => "use `dashboard`",
    "token_budget" => "remove it; use `agent.limits.tokens_per_issue` and `agent.limits.tokens_per_day`",
    "tracker" => "use `issues`",
    "worker" => "use `workers`",
    "workspace" => "use `workspaces`"
  }

  @operator_error_paths %{
    "ci" => "pull_requests.checks",
    "dependencies" => "dependency_audit",
    "learnings" => "pull_requests.learnings",
    "observability" => "dashboard",
    "polling" => "issues",
    "pr_review" => "pull_requests",
    "quality_gate" => "issue_gate",
    "review_agent" => "pre_push_review",
    "server" => "dashboard",
    "tracker" => "issues",
    "worker" => "workers",
    "workspace" => "workspaces",
    "agent.kind" => "agent.runtime",
    "agent.max_concurrent_agents" => "agent.concurrency.max_total",
    "agent.max_concurrent_agents_by_state" => "agent.concurrency.max_by_issue_state",
    "agent.max_consecutive_identical_tool_failures" => "agent.limits.max_consecutive_identical_tool_failures",
    "agent.max_retry_backoff_ms" => "agent.limits.retry_backoff_max_ms",
    "agent.max_tokens_per_day" => "agent.limits.tokens_per_day",
    "agent.max_tokens_per_issue" => "agent.limits.tokens_per_issue",
    "agent.max_turns" => "agent.limits.max_turns",
    "agent.network_access" => "agent.permissions.network",
    "agent.network_access.allowed_domains" => "agent.permissions.network.allowed_domains",
    "agent.network_access.denied_domains" => "agent.permissions.network.denied_domains",
    "agent.network_access.mode" => "agent.permissions.network.mode",
    "agent.approval_policy" => "agent.permissions.approval_policy",
    "agent.project_guide_files" => "agent.prompts.project_guide_files",
    "agent.include_project_guides" => "agent.prompts.include_project_guides",
    "agent.read_timeout_ms" => "agent.timeouts.read_ms",
    "agent.sandbox_runtime" => "agent.permissions.outer_sandbox",
    "agent.sandbox_runtime.command" => "agent.permissions.outer_sandbox.command",
    "agent.sandbox_runtime.enable_weaker_network_isolation" => "agent.permissions.outer_sandbox.enable_weaker_network_isolation",
    "agent.sandbox_runtime.kind" => "agent.permissions.outer_sandbox.runtime",
    "agent.stall_timeout_ms" => "agent.timeouts.stall_ms",
    "agent.thread_sandbox" => "agent.permissions.filesystem.sandbox",
    "agent.turn_sandbox_policy" => "agent.permissions.filesystem.turn_policy",
    "agent.turn_timeout_ms" => "agent.timeouts.turn_ms",
    "agent.command_timeout_ms" => "agent.timeouts.command_ms",
    "auto_review.kind" => "auto_review.runtime",
    "ci.enabled" => "pull_requests.checks.enabled",
    "ci.escalation_state" => "pull_requests.checks.escalate_to_state",
    "ci.flaky_retry" => "pull_requests.checks.retry_failed_once",
    "ci.log_excerpt_lines" => "pull_requests.checks.log_excerpt_lines",
    "ci.max_retries" => "pull_requests.checks.max_fix_attempts",
    "ci.merging_wait_timeout_ms" => "pull_requests.checks.landing_wait_timeout_ms",
    "ci.poll_interval_ms" => "pull_requests.poll_interval_ms",
    "dependencies.allow_git_sources" => "dependency_audit.allow_git_sources",
    "dependencies.allow_path_sources" => "dependency_audit.allow_path_sources",
    "dependencies.allow_registries" => "dependency_audit.allow_registries",
    "learnings.enabled" => "pull_requests.learnings.enabled",
    "learnings.max_per_run" => "pull_requests.learnings.max_per_run",
    "learnings.max_total_per_repo" => "pull_requests.learnings.max_total_per_repo",
    "learnings.model" => "pull_requests.learnings.model",
    "learnings.provider" => "pull_requests.learnings.provider",
    "observability.dashboard_enabled" => "dashboard.enabled",
    "observability.refresh_ms" => "dashboard.refresh_ms",
    "observability.render_interval_ms" => "dashboard.render_interval_ms",
    "observability.snapshot_publish_ms" => "dashboard.snapshot_publish_ms",
    "observability.transcript_buffer_size" => "dashboard.transcript_buffer_size",
    "polling.interval_ms" => "issues.poll_interval_ms",
    "pr_review.auto_merge" => "pull_requests.auto_merge",
    "pr_review.auto_reply" => "pull_requests.review_comments.reply_after_addressing",
    "pr_review.auto_request_review" => "pull_requests.review_comments.request_review_after_push",
    "pr_review.cooldown_minutes" => "pull_requests.review_comments.rework_delay_minutes",
    "pr_review.ignored_users" => "pull_requests.review_comments.ignored_reviewers",
    "pr_review.mode" => "pull_requests.enabled",
    "pr_review.poll_interval_ms" => "pull_requests.poll_interval_ms",
    "pr_review.stale_days" => "pull_requests.review_comments.stale_after_days",
    "quality_gate.clarification_floor" => "issue_gate.clarification_floor",
    "quality_gate.enabled" => "issue_gate.enabled",
    "quality_gate.max_clarification_rounds" => "issue_gate.max_clarification_rounds",
    "quality_gate.min_score" => "issue_gate.pass_threshold",
    "quality_gate.model" => "issue_gate.model",
    "quality_gate.on_error" => "issue_gate.on_error",
    "quality_gate.pass_threshold" => "issue_gate.pass_threshold",
    "quality_gate.provider" => "issue_gate.provider",
    "repos" => "repositories",
    "repos.assignee" => "repositories.route.assignee",
    "repos.base_branch" => "repositories.base_branch",
    "repos.default" => "repositories.default",
    "repos.labels" => "repositories.route.labels",
    "repos.name" => "repositories.key",
    "repos.projects" => "repositories.route.projects",
    "repos.team" => "repositories.route.team",
    "repos.workflow" => "repositories.workflow",
    "repos.workspace" => "repositories.workspace",
    "repos.workspace.fetch_before_dispatch" => "repositories.workspace.fetch_before_dispatch",
    "repos.workspace.repo" => "repositories.workspace.repo",
    "repos.workspace.strategy" => "repositories.workspace.strategy",
    "review_agent.command" => "pre_push_review.command",
    "review_agent.enabled" => "pre_push_review.enabled",
    "review_agent.effort" => "pre_push_review.effort",
    "review_agent.kind" => "pre_push_review.runtime",
    "review_agent.max_iterations" => "pre_push_review.max_iterations",
    "review_agent.model" => "pre_push_review.model",
    "review_agent.run_on" => "pre_push_review.run_on",
    "server.host" => "dashboard.host",
    "server.port" => "dashboard.port",
    "tracker.active_states" => "issues.states.active",
    "tracker.api_key" => "issues.linear.api_key",
    "tracker.assignee" => "issues.linear.assignee",
    "tracker.endpoint" => "issues.linear.endpoint",
    "tracker.kind" => "issues.provider",
    "tracker.labels" => "issues.linear.scope.labels",
    "tracker.project_slug" => "issues.linear.scope.project_slug",
    "tracker.team" => "issues.linear.scope.team",
    "tracker.terminal_states" => "issues.states.terminal",
    "watchdog.no_progress_threshold_ms" => "watchdog.no_progress_threshold_ms",
    "watchdog.tick_interval_ms" => "watchdog.tick_interval_ms",
    "worker.max_concurrent_agents_per_host" => "workers.max_concurrent_agents_per_host",
    "worker.ssh_hosts" => "workers.ssh_hosts",
    "workspace.attachments" => "workspaces.attachments",
    "workspace.attachments.allowed_hosts" => "workspaces.attachments.allowed_hosts",
    "workspace.attachments.public_upload_extensions" => "workspaces.attachments.public_upload_extensions",
    "workspace.fetch_before_dispatch" => "workspaces.fetch_before_dispatch",
    "workspace.lifecycle" => "workspaces.cleanup",
    "workspace.lifecycle.age_gc_enabled" => "workspaces.cleanup.enabled",
    "workspace.lifecycle.gc_interval_ms" => "workspaces.cleanup.interval_ms",
    "workspace.lifecycle.max_age_days" => "workspaces.cleanup.max_age_days",
    "workspace.lifecycle.min_free_bytes" => "workspaces.cleanup.min_free_bytes",
    "workspace.lifecycle.orphan_action" => "workspaces.cleanup.orphan_action",
    "workspace.lifecycle.trash_dir" => "workspaces.cleanup.trash_dir",
    "workspace.repo" => "workspaces.repo",
    "workspace.root" => "workspaces.root",
    "workspace.sandbox" => "agent.permissions.filesystem",
    "workspace.sandbox.allow_read_paths" => "agent.permissions.filesystem.allow_read_paths",
    "workspace.sandbox.allow_write_paths" => "agent.permissions.filesystem.allow_write_paths",
    "workspace.strategy" => "workspaces.strategy"
  }

  @operator_error_message_rewrites [
    {"quality_gate.", "issue_gate."},
    {"quality_gate", "issue_gate"},
    {"review_agent.", "pre_push_review."},
    {"review_agent", "pre_push_review"},
    {"learnings.", "pull_requests.learnings."},
    {"pr_review.", "pull_requests."},
    {"ci.", "pull_requests.checks."},
    {"tracker.", "issues."},
    {"polling.", "issues."},
    {"worker.", "workers."},
    {"workspace.", "workspaces."}
  ]

  defmodule Repo do
    @moduledoc false

    use Ecto.Schema

    import Ecto.Changeset

    @primary_key false
    @fields [
      :name,
      :path,
      :workflow,
      :workflow_source,
      :base_branch,
      :team,
      :labels,
      :projects,
      :assignee,
      :default,
      :agent
    ]

    defmodule Workspace do
      @moduledoc false

      use Ecto.Schema

      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:strategy, :string)
        field(:repo, :string)
        field(:fetch_before_dispatch, :boolean)
      end

      @type t :: %__MODULE__{}

      @spec changeset(t(), map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:strategy, :repo, :fetch_before_dispatch], empty_values: [])
        |> validate_inclusion(:strategy, ["clone", "worktree"])
      end
    end

    embedded_schema do
      field(:name, :string)
      field(:path, :string)
      field(:workflow, :string, default: "WORKFLOW.md")
      field(:workflow_source, :string, default: "ref")
      field(:base_branch, :string)
      field(:team, :string)
      field(:labels, {:array, :string}, default: [])
      field(:projects, {:array, :string}, default: [])
      field(:assignee, :string)
      field(:default, :boolean, default: false)
      # The raw `agent` block until `SystemSchema.parse/1` replaces it with a `Schema.RepoAgent`.
      field(:agent, :map)
      embeds_one(:workspace, Workspace, on_replace: :update)
    end

    @type t :: %__MODULE__{}

    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> cast_embed(:workspace, with: &Workspace.changeset/2)
      |> validate_required([:name, :workflow])
      |> validate_string(:name)
      |> validate_optional_string(:path)
      |> validate_string(:workflow)
      |> validate_inclusion(:workflow_source, ["ref", "local"])
      |> validate_optional_string(:base_branch)
      |> validate_string(:team)
      |> normalize_string_list(:labels)
      |> normalize_string_list(:projects)
    end

    defp validate_string(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        if is_binary(value) and String.trim(value) != "" do
          []
        else
          [{field, "must be a non-empty string"}]
        end
      end)
    end

    defp validate_optional_string(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        cond do
          is_nil(value) ->
            []

          is_binary(value) and String.trim(value) != "" ->
            []

          true ->
            [{field, "must be a non-empty string"}]
        end
      end)
    end

    defp normalize_string_list(changeset, field) do
      update_change(changeset, field, fn
        values when is_list(values) ->
          values
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        nil ->
          []
      end)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Schema.Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Schema.Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:poller, Schema.Poller, on_replace: :update, defaults_to_struct: true)
    embeds_one(:watchdog, Schema.Watchdog, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Schema.Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Schema.Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:github, Schema.GitHub, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Schema.Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Schema.Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pr_review, Schema.PrReview, on_replace: :update, defaults_to_struct: true)
    embeds_one(:ci, Schema.Ci, on_replace: :update, defaults_to_struct: true)
    embeds_one(:verification, Schema.Verification, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Schema.Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:quality_gate, Schema.QualityGate, on_replace: :update, defaults_to_struct: true)
    embeds_one(:learnings, Schema.Learnings, on_replace: :update, defaults_to_struct: true)
    embeds_one(:review_agent, Schema.ReviewAgent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:auto_review, Schema.AutoReview, on_replace: :update, defaults_to_struct: true)
    embeds_one(:dependencies, Schema.Dependencies, on_replace: :update, defaults_to_struct: true)
    embeds_one(:notifications, Schema.Notifications, on_replace: :update, defaults_to_struct: true)
    embeds_one(:human_actions, Schema.HumanActions, on_replace: :update, defaults_to_struct: true)
    embeds_many(:repos, Repo, on_replace: :delete)
  end

  @type t :: %__MODULE__{}

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_symphony_config, String.t()}}
  def parse(config) when is_map(config) do
    config = normalize_keys(config)

    with :ok <- reject_removed_keys(config),
         :ok <- reject_unknown_keys(config),
         {:ok, config} <- normalize_operator_config(config) do
      config
      |> drop_nil_values()
      |> changeset()
      |> apply_action(:validate)
      |> case do
        {:ok, system_config} -> system_config |> finalize_repos() |> parse_repo_agents()
        {:error, changeset} -> {:error, {:invalid_symphony_config, format_errors(changeset)}}
      end
    end
  end

  @spec to_config_map(t()) :: map()
  def to_config_map(%__MODULE__{} = system_config) do
    %{
      "tracker" => struct_to_map(system_config.tracker),
      "polling" => struct_to_map(system_config.polling),
      "poller" => struct_to_map(system_config.poller),
      "watchdog" => struct_to_map(system_config.watchdog),
      "workspace" => workspace_to_map(system_config.workspace),
      "worker" => struct_to_map(system_config.worker),
      "github" => struct_to_map(system_config.github),
      "agent" => agent_to_map(system_config.agent),
      "observability" => struct_to_map(system_config.observability),
      "pr_review" => struct_to_map(system_config.pr_review),
      "ci" => struct_to_map(system_config.ci),
      "verification" => struct_to_map(system_config.verification),
      "server" => struct_to_map(system_config.server),
      "quality_gate" => struct_to_map(system_config.quality_gate),
      "learnings" => struct_to_map(system_config.learnings),
      "review_agent" => struct_to_map(system_config.review_agent),
      "auto_review" => struct_to_map(system_config.auto_review),
      "dependencies" => struct_to_map(system_config.dependencies),
      "notifications" => notifications_to_map(system_config.notifications),
      "human_actions" => struct_to_map(system_config.human_actions)
    }
    |> drop_nil_values()
  end

  @spec primary_repo(t()) :: Repo.t() | nil
  def primary_repo(%__MODULE__{repos: repos}) when is_list(repos) do
    Enum.find(repos, & &1.default) || List.first(repos)
  end

  def primary_repo(%__MODULE__{}), do: nil

  @spec repo_workflow_path(Repo.t() | map()) :: Path.t()
  def repo_workflow_path(%Repo{} = repo) do
    repo
    |> Map.from_struct()
    |> repo_workflow_path()
  end

  def repo_workflow_path(repo) when is_map(repo) do
    path = repo_value(repo, :path)
    workflow = repo_value(repo, :workflow, "WORKFLOW.md")

    cond do
      non_empty_string?(path) and non_empty_string?(workflow) ->
        Workflow.repo_workflow_file_path(%{path: path, workflow: workflow})

      non_empty_string?(workflow) ->
        workflow_path_from_symphony_file(workflow)

      true ->
        raise ArgumentError,
              "repo workflow path requires non-empty `workflow`; got: #{inspect(repo)}"
    end
  end

  def repo_workflow_path(repo) do
    raise ArgumentError,
          "repo workflow path requires a repo map or #{inspect(Repo)} struct; got: #{inspect(repo)}"
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Schema.Tracker.changeset/2)
    |> cast_embed(:polling, with: &Schema.Polling.changeset/2)
    |> cast_embed(:poller, with: &Schema.Poller.changeset/2)
    |> cast_embed(:watchdog, with: &Schema.Watchdog.changeset/2)
    |> cast_embed(:workspace, with: &Schema.Workspace.changeset/2)
    |> cast_embed(:worker, with: &Schema.Worker.changeset/2)
    |> cast_embed(:github, with: &Schema.GitHub.changeset/2)
    |> cast_embed(:agent, with: &Schema.Agent.changeset/2)
    |> cast_embed(:observability, with: &Schema.Observability.changeset/2)
    |> cast_embed(:pr_review, with: &Schema.PrReview.changeset/2)
    |> cast_embed(:ci, with: &Schema.Ci.changeset/2)
    |> cast_embed(:verification, with: &Schema.Verification.changeset/2)
    |> cast_embed(:server, with: &Schema.Server.changeset/2)
    |> cast_embed(:quality_gate, with: &Schema.QualityGate.changeset/2)
    |> cast_embed(:learnings, with: &Schema.Learnings.changeset/2)
    |> cast_embed(:review_agent, with: &Schema.ReviewAgent.changeset/2)
    |> cast_embed(:auto_review, with: &Schema.AutoReview.changeset/2)
    |> cast_embed(:dependencies, with: &Schema.Dependencies.changeset/2)
    |> cast_embed(:notifications, with: &Schema.Notifications.changeset/2)
    |> cast_embed(:human_actions, with: &Schema.HumanActions.changeset/2)
    |> Schema.validate_profile_command_flags()
    |> cast_embed(:repos, with: &Repo.changeset/2, required: true)
    |> validate_length(:repos, min: 1)
    |> validate_unique_repo_names()
    |> validate_unique_repo_workspace_keys()
    |> validate_single_default_repo()
  end

  defp reject_unknown_keys(config) do
    unknown_keys = Map.keys(config) -- @allowed_keys

    case unknown_keys do
      [] -> :ok
      [key | _rest] -> {:error, {:invalid_symphony_config, "unknown symphony.yml key `#{key}`"}}
    end
  end

  defp reject_removed_keys(config) do
    case Enum.find(Map.keys(config), &Map.has_key?(@removed_top_level_keys, &1)) do
      nil ->
        :ok

      key ->
        {:error, {:invalid_symphony_config, "`#{key}` is not valid; #{@removed_top_level_keys[key]}"}}
    end
  end

  defp normalize_operator_config(config) do
    with {:ok, issue_config} <- normalize_issues(Map.get(config, "issues", %{})),
         {:ok, repos} <- normalize_repositories(Map.get(config, "repositories")),
         {:ok, workspace} <- normalize_workspaces(Map.get(config, "workspaces", %{})),
         {:ok, agent_config} <- normalize_agent(Map.get(config, "agent", %{})),
         {:ok, worker} <- normalize_workers(Map.get(config, "workers", %{})),
         {:ok, pre_push_review} <- normalize_pre_push_review(Map.get(config, "pre_push_review", %{})),
         {:ok, auto_review} <- normalize_auto_review(Map.get(config, "auto_review", %{})),
         {:ok, pull_requests} <- normalize_pull_requests(Map.get(config, "pull_requests", %{})),
         {:ok, poller} <- normalize_poller(Map.get(config, "poller", %{})),
         {:ok, issue_gate} <- normalize_issue_gate(Map.get(config, "issue_gate", %{})),
         {:ok, dependency_audit} <- normalize_dependency_audit(Map.get(config, "dependency_audit", %{})),
         {:ok, dashboard} <- normalize_dashboard(Map.get(config, "dashboard", %{})),
         {:ok, human_actions} <- normalize_human_actions(Map.get(config, "human_actions", %{})) do
      workspace = merge_section(workspace, "sandbox", Map.get(agent_config, "workspace_sandbox"))

      {:ok,
       %{}
       |> merge_sections(issue_config)
       |> maybe_put("repos", repos)
       |> maybe_put("workspace", workspace)
       |> maybe_put("worker", worker)
       |> maybe_put("github", Map.get(config, "github"))
       |> maybe_put("agent", Map.get(agent_config, "agent"))
       |> maybe_put("verification", Map.get(config, "verification"))
       |> maybe_put("review_agent", pre_push_review)
       |> maybe_put("auto_review", auto_review)
       |> merge_sections(pull_requests)
       |> maybe_put("poller", poller)
       |> maybe_put("quality_gate", issue_gate)
       |> maybe_put("dependencies", dependency_audit)
       |> maybe_put("watchdog", Map.get(config, "watchdog"))
       |> merge_sections(dashboard)
       |> maybe_put("notifications", Map.get(config, "notifications"))
       |> maybe_put("human_actions", human_actions)}
    end
  end

  defp normalize_issues(config) do
    with {:ok, config} <- section_map(config, "issues"),
         :ok <- reject_unknown_section_keys(config, ~w(provider poll_interval_ms linear memory states), "issues"),
         {:ok, linear} <- section_map(Map.get(config, "linear", %{}), "issues.linear"),
         {:ok, memory} <- section_map(Map.get(config, "memory", %{}), "issues.memory"),
         :ok <- reject_unknown_section_keys(memory, ~w(issues_file), "issues.memory"),
         :ok <- reject_unknown_section_keys(linear, ~w(endpoint api_key assignee scope), "issues.linear"),
         {:ok, scope} <- section_map(Map.get(linear, "scope", %{}), "issues.linear.scope"),
         :ok <- reject_unknown_section_keys(scope, ~w(project_slug team labels), "issues.linear.scope"),
         {:ok, states} <- section_map(Map.get(config, "states", %{}), "issues.states"),
         :ok <- reject_unknown_section_keys(states, ~w(active terminal waiting_on_sub_issues), "issues.states") do
      tracker =
        %{}
        |> maybe_put("kind", Map.get(config, "provider"))
        |> maybe_put("endpoint", Map.get(linear, "endpoint"))
        |> maybe_put("api_key", Map.get(linear, "api_key"))
        |> maybe_put("assignee", Map.get(linear, "assignee"))
        |> maybe_put("project_slug", Map.get(scope, "project_slug"))
        |> maybe_put("team", Map.get(scope, "team"))
        |> maybe_put("labels", Map.get(scope, "labels"))
        |> maybe_put("memory_issues_file", memory_issues_file(Map.get(memory, "issues_file")))
        |> maybe_put("active_states", Map.get(states, "active"))
        |> maybe_put("terminal_states", Map.get(states, "terminal"))
        |> maybe_put_configured("waiting_on_sub_issues_state", Map.get(states, "waiting_on_sub_issues"), Map.has_key?(states, "waiting_on_sub_issues"))

      polling = %{} |> maybe_put("interval_ms", Map.get(config, "poll_interval_ms"))

      {:ok, %{} |> maybe_put("tracker", tracker) |> maybe_put("polling", polling)}
    end
  end

  # Relative to the folder holding symphony.yml, like a repository's workflow.
  defp memory_issues_file(path) when is_binary(path), do: workflow_path_from_symphony_file(path)
  defp memory_issues_file(value), do: value

  defp normalize_repositories(nil), do: {:ok, nil}

  defp normalize_repositories(repos) when is_list(repos) do
    repos
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {repo, index}, {:ok, acc} ->
      case normalize_repository(repo, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_repositories(_repos), do: {:error, {:invalid_symphony_config, "`repositories` must be a list"}}

  defp normalize_repository(repo, index) do
    path = "repositories[#{index}]"

    with {:ok, repo} <- section_map(repo, path),
         :ok <- reject_unknown_section_keys(repo, ~w(key workflow workflow_source base_branch route workspace default agent), path),
         {:ok, route} <- section_map(Map.get(repo, "route", %{}), path <> ".route"),
         :ok <- reject_unknown_section_keys(route, ~w(team projects labels assignee), path <> ".route"),
         {:ok, workspace} <- optional_section_map(Map.get(repo, "workspace"), path <> ".workspace"),
         :ok <- reject_unknown_section_keys(workspace || %{}, ~w(strategy repo fetch_before_dispatch), path <> ".workspace"),
         {:ok, agent} <- section_map(Map.get(repo, "agent"), repo_agent_path(Map.get(repo, "key"), index)),
         :ok <- reject_unknown_section_keys(agent, ~w(provider model effort run_profiles), repo_agent_path(Map.get(repo, "key"), index)) do
      normalized =
        %{}
        |> maybe_put("name", Map.get(repo, "key"))
        |> maybe_put("workflow", Map.get(repo, "workflow"))
        |> maybe_put("workflow_source", Map.get(repo, "workflow_source"))
        |> maybe_put("base_branch", Map.get(repo, "base_branch"))
        |> maybe_put("default", Map.get(repo, "default"))
        |> maybe_put("team", Map.get(route, "team"))
        |> maybe_put("projects", Map.get(route, "projects"))
        |> maybe_put("labels", Map.get(route, "labels"))
        |> maybe_put("assignee", Map.get(route, "assignee"))
        |> maybe_put("workspace", workspace)
        |> maybe_put("agent", agent)

      {:ok, normalized}
    end
  end

  defp repo_agent_path(key, _index) when is_binary(key) and key != "", do: "repositories[#{key}].agent"
  defp repo_agent_path(_key, index), do: "repositories[#{index}].agent"

  defp normalize_workspaces(config) do
    with {:ok, config} <- section_map(config, "workspaces"),
         :ok <- reject_unknown_section_keys(config, ~w(root strategy repo fetch_before_dispatch cleanup attachments), "workspaces"),
         {:ok, cleanup} <- section_map(Map.get(config, "cleanup", %{}), "workspaces.cleanup"),
         :ok <- reject_unknown_section_keys(cleanup, ~w(enabled max_age_days interval_ms min_free_bytes orphan_action trash_dir), "workspaces.cleanup"),
         {:ok, attachments} <- section_map(Map.get(config, "attachments", %{}), "workspaces.attachments"),
         :ok <- reject_unknown_section_keys(attachments, ~w(allowed_hosts public_upload_extensions), "workspaces.attachments") do
      lifecycle =
        %{}
        |> maybe_put("age_gc_enabled", Map.get(cleanup, "enabled"))
        |> maybe_put("max_age_days", Map.get(cleanup, "max_age_days"))
        |> maybe_put("gc_interval_ms", Map.get(cleanup, "interval_ms"))
        |> maybe_put("min_free_bytes", Map.get(cleanup, "min_free_bytes"))
        |> maybe_put("orphan_action", Map.get(cleanup, "orphan_action"))
        |> maybe_put("trash_dir", Map.get(cleanup, "trash_dir"))

      workspace =
        %{}
        |> maybe_put("root", Map.get(config, "root"))
        |> maybe_put("strategy", Map.get(config, "strategy"))
        |> maybe_put("repo", Map.get(config, "repo"))
        |> maybe_put("fetch_before_dispatch", Map.get(config, "fetch_before_dispatch"))
        |> maybe_put("lifecycle", lifecycle)
        |> maybe_put("attachments", attachments)

      {:ok, workspace}
    end
  end

  defp normalize_agent(config) do
    with {:ok, config} <- section_map(config, "agent"),
         :ok <- reject_unknown_section_keys(config, ~w(runtime command model effort provider run_profiles concurrency limits timeouts prompts permissions mcp usage_limit), "agent"),
         {:ok, concurrency} <- section_map(Map.get(config, "concurrency", %{}), "agent.concurrency"),
         :ok <- reject_unknown_section_keys(concurrency, ~w(max_total max_by_issue_state epic_lanes finishing_max force_label forced_max forced_stale_after_hours), "agent.concurrency"),
         {:ok, limits} <- section_map(Map.get(config, "limits", %{}), "agent.limits"),
         :ok <-
           reject_unknown_section_keys(
             limits,
             ~w(max_turns retry_backoff_max_ms tokens_per_issue tokens_per_day max_consecutive_identical_tool_failures),
             "agent.limits"
           ),
         {:ok, timeouts} <- section_map(Map.get(config, "timeouts", %{}), "agent.timeouts"),
         :ok <- reject_unknown_section_keys(timeouts, ~w(turn_ms read_ms stall_ms command_ms), "agent.timeouts"),
         {:ok, prompts} <- section_map(Map.get(config, "prompts", %{}), "agent.prompts"),
         :ok <-
           reject_unknown_section_keys(
             prompts,
             ~w(include_project_guides project_guide_files codex_stdio_soft_limit_bytes),
             "agent.prompts"
           ),
         {:ok, permissions} <- section_map(Map.get(config, "permissions", %{}), "agent.permissions"),
         :ok <- reject_unknown_section_keys(permissions, ~w(approval_policy filesystem network outer_sandbox), "agent.permissions"),
         {:ok, filesystem} <- section_map(Map.get(permissions, "filesystem", %{}), "agent.permissions.filesystem"),
         :ok <- reject_unknown_section_keys(filesystem, ~w(sandbox turn_policy allow_read_paths allow_write_paths), "agent.permissions.filesystem"),
         {:ok, network} <- section_map(Map.get(permissions, "network", %{}), "agent.permissions.network"),
         :ok <- reject_unknown_section_keys(network, ~w(mode allowed_domains denied_domains), "agent.permissions.network"),
         {:ok, outer_sandbox} <- section_map(Map.get(permissions, "outer_sandbox", %{}), "agent.permissions.outer_sandbox"),
         :ok <- reject_unknown_section_keys(outer_sandbox, ~w(runtime command enable_weaker_network_isolation), "agent.permissions.outer_sandbox"),
         {:ok, mcp} <- section_map(Map.get(config, "mcp", %{}), "agent.mcp"),
         :ok <- reject_unknown_section_keys(mcp, ~w(inherit allowed_servers servers), "agent.mcp"),
         {:ok, usage_limit} <- section_map(Map.get(config, "usage_limit", %{}), "agent.usage_limit"),
         :ok <-
           reject_unknown_section_keys(
             usage_limit,
             ~w(auto_pause resume_margin_seconds unknown_reset_retry_seconds headroom_utilization),
             "agent.usage_limit"
           ) do
      sandbox_runtime =
        %{}
        |> maybe_put("kind", Map.get(outer_sandbox, "runtime"))
        |> maybe_put("command", Map.get(outer_sandbox, "command"))
        |> maybe_put("enable_weaker_network_isolation", Map.get(outer_sandbox, "enable_weaker_network_isolation"))

      agent =
        %{}
        |> maybe_put("kind", Map.get(config, "runtime"))
        |> maybe_put("command", Map.get(config, "command"))
        |> maybe_put("model", Map.get(config, "model"))
        |> maybe_put("effort", Map.get(config, "effort"))
        |> maybe_put("provider", Map.get(config, "provider"))
        |> maybe_put("run_profiles", Map.get(config, "run_profiles"))
        |> maybe_put("max_concurrent_agents", Map.get(concurrency, "max_total"))
        |> maybe_put("max_concurrent_agents_by_state", Map.get(concurrency, "max_by_issue_state"))
        |> maybe_put("epic_lanes", Map.get(concurrency, "epic_lanes"))
        |> maybe_put("finishing_max", Map.get(concurrency, "finishing_max"))
        |> maybe_put("force_label", Map.get(concurrency, "force_label"))
        |> maybe_put("forced_max", Map.get(concurrency, "forced_max"))
        |> maybe_put("forced_stale_after_hours", Map.get(concurrency, "forced_stale_after_hours"))
        |> maybe_put("max_turns", Map.get(limits, "max_turns"))
        |> maybe_put("max_retry_backoff_ms", Map.get(limits, "retry_backoff_max_ms"))
        |> maybe_put("max_consecutive_identical_tool_failures", Map.get(limits, "max_consecutive_identical_tool_failures"))
        |> maybe_put_configured("max_tokens_per_issue", Map.get(limits, "tokens_per_issue"), Map.has_key?(limits, "tokens_per_issue"))
        |> maybe_put_configured("max_tokens_per_day", Map.get(limits, "tokens_per_day"), Map.has_key?(limits, "tokens_per_day"))
        |> maybe_put("turn_timeout_ms", Map.get(timeouts, "turn_ms"))
        |> maybe_put("read_timeout_ms", Map.get(timeouts, "read_ms"))
        |> maybe_put("stall_timeout_ms", Map.get(timeouts, "stall_ms"))
        |> maybe_put("command_timeout_ms", Map.get(timeouts, "command_ms"))
        |> maybe_put("include_project_guides", Map.get(prompts, "include_project_guides"))
        |> maybe_put("project_guide_files", Map.get(prompts, "project_guide_files"))
        |> maybe_put("codex_stdio_prompt_soft_limit", Map.get(prompts, "codex_stdio_soft_limit_bytes"))
        |> maybe_put("approval_policy", Map.get(permissions, "approval_policy"))
        |> maybe_put("thread_sandbox", Map.get(filesystem, "sandbox"))
        |> maybe_put("turn_sandbox_policy", Map.get(filesystem, "turn_policy"))
        |> maybe_put("network_access", network)
        |> maybe_put("sandbox_runtime", sandbox_runtime)
        |> maybe_put("mcp", mcp)
        |> maybe_put("usage_limit", usage_limit)

      workspace_sandbox =
        %{}
        |> maybe_put("allow_read_paths", Map.get(filesystem, "allow_read_paths"))
        |> maybe_put("allow_write_paths", Map.get(filesystem, "allow_write_paths"))

      {:ok, %{"agent" => agent, "workspace_sandbox" => workspace_sandbox}}
    end
  end

  defp normalize_workers(config) do
    with {:ok, config} <- section_map(config, "workers"),
         :ok <- reject_unknown_section_keys(config, ~w(ssh_hosts max_concurrent_agents_per_host), "workers") do
      {:ok, config}
    end
  end

  defp normalize_pre_push_review(config) do
    with {:ok, config} <- section_map(config, "pre_push_review"),
         :ok <- reject_unknown_section_keys(config, ~w(enabled runtime command model effort max_iterations run_on), "pre_push_review") do
      {:ok,
       %{}
       |> maybe_put("enabled", Map.get(config, "enabled"))
       |> maybe_put("kind", Map.get(config, "runtime"))
       |> maybe_put("command", Map.get(config, "command"))
       |> maybe_put("model", Map.get(config, "model"))
       |> maybe_put("effort", Map.get(config, "effort"))
       |> maybe_put("max_iterations", Map.get(config, "max_iterations"))
       |> maybe_put("run_on", Map.get(config, "run_on"))}
    end
  end

  defp normalize_auto_review(config) do
    with {:ok, config} <- section_map(config, "auto_review"),
         :ok <-
           reject_unknown_section_keys(
             config,
             ~w(enabled state runtime command model effort max_turns timeout_ms max_concurrent max_fix_attempts run_on skip_globs playbooks worker_host),
             "auto_review"
           ) do
      {:ok,
       config
       |> Map.delete("runtime")
       |> maybe_put("kind", Map.get(config, "runtime"))}
    end
  end

  defp normalize_pull_requests(config) do
    with {:ok, config} <- section_map(config, "pull_requests"),
         :ok <- reject_unknown_section_keys(config, ~w(enabled poll_interval_ms auto_merge review_comments checks learnings), "pull_requests"),
         {:ok, review_comments} <- section_map(Map.get(config, "review_comments", %{}), "pull_requests.review_comments"),
         :ok <-
           reject_unknown_section_keys(
             review_comments,
             ~w(rework_delay_minutes stale_after_days ignored_reviewers reply_after_addressing request_review_after_push),
             "pull_requests.review_comments"
           ),
         {:ok, checks} <- section_map(Map.get(config, "checks", %{}), "pull_requests.checks"),
         :ok <- reject_unknown_section_keys(checks, ~w(enabled log_excerpt_lines retry_failed_once max_fix_attempts escalate_to_state landing_wait_timeout_ms), "pull_requests.checks"),
         {:ok, learnings} <- section_map(Map.get(config, "learnings", %{}), "pull_requests.learnings"),
         :ok <- reject_unknown_section_keys(learnings, ~w(enabled provider model max_total_per_repo max_per_run), "pull_requests.learnings"),
         {:ok, mode} <- pr_review_mode(Map.get(config, "enabled")) do
      pr_enabled = mode

      pr_review =
        %{}
        |> maybe_put("mode", pr_enabled)
        |> maybe_put("poll_interval_ms", Map.get(config, "poll_interval_ms"))
        |> maybe_put("auto_merge", Map.get(config, "auto_merge"))
        |> maybe_put("cooldown_minutes", Map.get(review_comments, "rework_delay_minutes"))
        |> maybe_put("stale_days", Map.get(review_comments, "stale_after_days"))
        |> maybe_put("ignored_users", Map.get(review_comments, "ignored_reviewers"))
        |> maybe_put("auto_reply", Map.get(review_comments, "reply_after_addressing"))
        |> maybe_put("auto_request_review", Map.get(review_comments, "request_review_after_push"))

      ci =
        %{}
        |> maybe_put("enabled", Map.get(checks, "enabled"))
        |> maybe_put("log_excerpt_lines", Map.get(checks, "log_excerpt_lines"))
        |> maybe_put("flaky_retry", Map.get(checks, "retry_failed_once"))
        |> maybe_put("max_retries", Map.get(checks, "max_fix_attempts"))
        |> maybe_put("escalation_state", Map.get(checks, "escalate_to_state"))
        |> maybe_put("merging_wait_timeout_ms", Map.get(checks, "landing_wait_timeout_ms"))

      {:ok,
       %{}
       |> maybe_put("pr_review", pr_review)
       |> maybe_put("ci", ci)
       |> maybe_put("learnings", learnings)}
    end
  end

  defp pr_review_mode(true), do: {:ok, "polling"}
  defp pr_review_mode(false), do: {:ok, "tracker"}
  defp pr_review_mode(nil), do: {:ok, nil}

  defp pr_review_mode(_invalid),
    do: {:error, {:invalid_symphony_config, "`pull_requests.enabled` must be a boolean"}}

  defp normalize_poller(config) do
    with {:ok, config} <- section_map(config, "poller"),
         :ok <- reject_unknown_section_keys(config, ~w(backoff_base_ms max_backoff_ms degraded_threshold), "poller") do
      {:ok, config}
    end
  end

  defp normalize_issue_gate(config) do
    with {:ok, config} <- section_map(config, "issue_gate"),
         :ok <- reject_unknown_section_keys(config, ~w(enabled provider model pass_threshold clarification_floor max_clarification_rounds on_error), "issue_gate") do
      {:ok, config}
    end
  end

  defp normalize_dependency_audit(config) do
    with {:ok, config} <- section_map(config, "dependency_audit"),
         :ok <- reject_unknown_section_keys(config, ~w(allow_registries allow_git_sources allow_path_sources), "dependency_audit") do
      {:ok, config}
    end
  end

  defp normalize_human_actions(config) do
    with {:ok, config} <- section_map(config, "human_actions"),
         :ok <- reject_unknown_section_keys(config, ~w(enabled label interval_ms min_update_interval_ms), "human_actions") do
      {:ok, config}
    end
  end

  defp normalize_dashboard(config) do
    with {:ok, config} <- section_map(config, "dashboard"),
         :ok <- reject_unknown_section_keys(config, ~w(enabled host port refresh_ms render_interval_ms snapshot_publish_ms transcript_buffer_size), "dashboard") do
      observability =
        %{}
        |> maybe_put("dashboard_enabled", Map.get(config, "enabled"))
        |> maybe_put("refresh_ms", Map.get(config, "refresh_ms"))
        |> maybe_put("render_interval_ms", Map.get(config, "render_interval_ms"))
        |> maybe_put("snapshot_publish_ms", Map.get(config, "snapshot_publish_ms"))
        |> maybe_put("transcript_buffer_size", Map.get(config, "transcript_buffer_size"))

      server =
        %{}
        |> maybe_put("host", Map.get(config, "host"))
        |> maybe_put("port", Map.get(config, "port"))

      {:ok, %{} |> maybe_put("observability", observability) |> maybe_put("server", server)}
    end
  end

  defp section_map(nil, _path), do: {:ok, %{}}
  defp section_map(value, _path) when is_map(value), do: {:ok, value}
  defp section_map(_value, path), do: {:error, {:invalid_symphony_config, "`#{path}` must be an object"}}

  defp optional_section_map(nil, _path), do: {:ok, nil}
  defp optional_section_map(value, path), do: section_map(value, path)

  defp reject_unknown_section_keys(map, allowed_keys, path) do
    unknown_keys = Map.keys(map) -- allowed_keys

    case unknown_keys do
      [] -> :ok
      [key | _rest] -> {:error, {:invalid_symphony_config, "unknown symphony.yml key `#{path}.#{key}`"}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_configured(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put_configured(map, _key, _value, false), do: map

  defp merge_sections(map, %{} = sections), do: Map.merge(map, sections)

  defp merge_section(map, _key, nil), do: map
  defp merge_section(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp merge_section(map, key, %{} = value), do: Map.update(map, key, value, &Map.merge(&1, value))

  defp validate_unique_repo_names(changeset) do
    duplicate_names =
      changeset
      |> repo_names()
      |> duplicate_values()

    case duplicate_names do
      [] -> changeset
      _duplicates -> add_error(changeset, :repos, "keys must be unique")
    end
  end

  defp validate_unique_repo_workspace_keys(changeset) do
    duplicate_workspace_keys =
      changeset
      |> repo_names()
      |> Enum.map(&repo_workspace_key/1)
      |> duplicate_values()

    case duplicate_workspace_keys do
      [] -> changeset
      _duplicates -> add_error(changeset, :repos, "keys must not collide after workspace normalization")
    end
  end

  defp validate_single_default_repo(changeset) do
    default_count =
      changeset
      |> get_change(:repos, [])
      |> Enum.count(&truthy_change?(&1, :default))

    if default_count <= 1 do
      changeset
    else
      add_error(changeset, :repos, "can include at most one default repo")
    end
  end

  defp truthy_change?(changeset, field), do: get_field(changeset, field) == true

  # Mirror the real workspace path normalization so validation predicts the same
  # collisions that Workspace.safe_identifier/1 would produce on disk.
  defp repo_workspace_key(name), do: Workspace.safe_identifier(name)

  defp repo_names(changeset) do
    changeset
    |> get_change(:repos, [])
    |> Enum.flat_map(fn repo_changeset ->
      case get_field(repo_changeset, :name) do
        name when is_binary(name) and name != "" -> [name]
        _name -> []
      end
    end)
  end

  defp duplicate_values(values) do
    {_seen, duplicates} =
      Enum.reduce(values, {MapSet.new(), MapSet.new()}, fn value, {seen, duplicates} ->
        if MapSet.member?(seen, value) do
          {seen, MapSet.put(duplicates, value)}
        else
          {MapSet.put(seen, value), duplicates}
        end
      end)

    MapSet.to_list(duplicates)
  end

  defp finalize_repos(%__MODULE__{} = system_config) do
    repos =
      Enum.map(system_config.repos, fn %Repo{} = repo ->
        repo_path = resolve_optional_path(repo.path)
        %{repo | path: repo_path}
      end)

    %{system_config | repos: repos}
  end

  defp parse_repo_agents(%__MODULE__{} = system_config) do
    sections = Map.take(system_config, [:agent, :review_agent, :auto_review, :worker])

    {repos, errors} =
      Enum.map_reduce(system_config.repos, [], fn
        %Repo{agent: nil} = repo, errors ->
          {repo, errors}

        %Repo{agent: agent, name: name} = repo, errors ->
          case Schema.RepoAgent.parse(agent, sections, repo_agent_path(name, nil)) do
            {:ok, repo_agent} -> {%{repo | agent: repo_agent}, errors}
            {:error, repo_errors} -> {repo, errors ++ repo_errors}
          end
      end)

    case errors do
      [] -> {:ok, %{system_config | repos: repos}}
      errors -> {:error, {:invalid_symphony_config, Enum.join(errors, ", ")}}
    end
  end

  defp resolve_path(path) when is_binary(path), do: Path.expand(path)
  defp resolve_optional_path(path) when is_binary(path), do: resolve_path(path)
  defp resolve_optional_path(_path), do: nil

  defp workflow_path_from_symphony_file(workflow) do
    case Path.type(workflow) do
      :absolute -> Path.expand(workflow)
      _type -> Path.expand(workflow, Path.dirname(Workflow.symphony_file_path()))
    end
  end

  defp repo_value(repo, key, default \\ nil) do
    string_key = to_string(key)

    cond do
      Map.has_key?(repo, key) -> Map.get(repo, key)
      Map.has_key?(repo, string_key) -> Map.get(repo, string_key)
      true -> default
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp agent_to_map(%Schema.Agent{} = agent) do
    agent
    |> struct_to_map()
    |> Map.update("network_access", nil, &struct_to_map/1)
    |> Map.update("sandbox_runtime", nil, &struct_to_map/1)
    |> Map.update("usage_limit", nil, &struct_to_map/1)
  end

  defp workspace_to_map(%Schema.Workspace{} = workspace) do
    workspace
    |> struct_to_map()
    |> Map.update("sandbox", nil, &struct_to_map/1)
    |> Map.update("lifecycle", nil, &struct_to_map/1)
  end

  defp notifications_to_map(%Schema.Notifications{} = notifications) do
    %{
      "enabled" => notifications.enabled,
      "redact_titles" => notifications.redact_titles,
      "channels" => Enum.map(notifications.channels || [], &struct_to_map/1)
    }
  end

  defp struct_to_map(nil), do: nil

  defp struct_to_map(struct) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), struct_to_map(value))
    end)
  end

  defp struct_to_map(values) when is_list(values), do: Enum.map(values, &struct_to_map/1)

  defp struct_to_map(values) when is_map(values) do
    Map.new(values, fn {key, value} -> {to_string(key), struct_to_map(value)} end)
  end

  defp struct_to_map(value), do: value

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value), do: drop_nil_values(value, [])

  defp drop_nil_values(value, path) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      child_path = path ++ [key]

      case drop_nil_values(nested, child_path) do
        nil -> put_non_nil_or_preserved_value(acc, key, child_path, nil)
        dropped -> Map.put(acc, key, dropped)
      end
    end)
  end

  defp drop_nil_values(value, path) when is_list(value), do: Enum.map(value, &drop_nil_values(&1, path))
  defp drop_nil_values(value, _path), do: value

  defp put_non_nil_or_preserved_value(acc, key, path, nil) do
    if preserve_explicit_nil_path?(path), do: Map.put(acc, key, nil), else: acc
  end

  defp preserve_explicit_nil_path?(["agent", key]) when key in ["max_tokens_per_issue", "max_tokens_per_day"],
    do: true

  defp preserve_explicit_nil_path?(["tracker", "waiting_on_sub_issues_state"]), do: true
  defp preserve_explicit_nil_path?(["watchdog", "stray_process_cpu_minutes"]), do: true
  defp preserve_explicit_nil_path?(_path), do: false

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix = if is_nil(prefix), do: to_string(key), else: prefix <> "." <> to_string(key)
      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.flat_map(errors, fn
      error when is_binary(error) -> [format_error(prefix, error)]
      nested -> flatten_errors(nested, prefix)
    end)
  end

  defp format_error(nil, error), do: rewrite_operator_error_message(error)

  defp format_error(prefix, error) do
    operator_error_path(prefix) <> " " <> rewrite_operator_error_message(error)
  end

  defp operator_error_path(prefix) do
    Map.get(@operator_error_paths, prefix, prefix)
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", inspect(value))
    end)
  end

  defp rewrite_operator_error_message(message) do
    Enum.reduce(@operator_error_message_rewrites, message, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end
end
