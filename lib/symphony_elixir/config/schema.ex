defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.{PathSafety, RunKind, Secret}

  require Logger

  @primary_key false

  @type t :: %__MODULE__{}

  # api.github.com and api.linear.app intentionally omitted: agents reach these
  # only through brokered MCP / DynamicTool calls in the orchestrator process.
  # Workspaces that need direct access can opt in via network_access.allowed_domains.
  @shared_built_in_network_allowed_domains [
    "bitbucket.org",
    "codeload.github.com",
    "crates.io",
    "dl.google.com",
    "files.pythonhosted.org",
    "github-cloud.githubusercontent.com",
    "github-cloud.s3.amazonaws.com",
    "github.com",
    "gist.githubusercontent.com",
    "hex.pm",
    "index.crates.io",
    "index.rubygems.org",
    "maven.google.com",
    "npm.pkg.github.com",
    "objects.githubusercontent.com",
    "packagist.org",
    "plugins.gradle.org",
    "proxy.golang.org",
    "pypi.org",
    "raw.githubusercontent.com",
    "registry.npmjs.org",
    "registry.yarnpkg.com",
    "release-assets.githubusercontent.com",
    "repo.hex.pm",
    "repo.maven.apache.org",
    "repo.packagist.org",
    "rubygems.global.ssl.fastly.net",
    "rubygems.org",
    "services.gradle.org",
    "static.crates.io",
    "sum.golang.org"
  ]

  @codex_built_in_network_allowed_domains @shared_built_in_network_allowed_domains ++
                                            [
                                              "api.openai.com",
                                              "auth.openai.com",
                                              "chatgpt.com"
                                            ]

  @claude_built_in_network_allowed_domains @shared_built_in_network_allowed_domains ++
                                             [
                                               "api.anthropic.com"
                                             ]

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @derive {Inspect, except: [:api_key]}

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:team, :string)
      field(:labels, {:array, :string}, default: [])
      field(:assignee, :string)
      field(:memory_issues_file, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
      field(:waiting_on_sub_issues_state, :string, default: "Waiting on sub-tickets")
    end

    @fields [
      :kind,
      :endpoint,
      :api_key,
      :project_slug,
      :team,
      :labels,
      :assignee,
      :memory_issues_file,
      :active_states,
      :terminal_states,
      :waiting_on_sub_issues_state
    ]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> normalize_optional_string(:project_slug)
      |> normalize_optional_string(:team)
      |> normalize_string_list(:labels)
      |> normalize_optional_string(:waiting_on_sub_issues_state)
      |> put_waiting_on_sub_issues_state_active()
    end

    # Breakdown parents wait in this state and are dispatched from it for close-out, so it is active.
    defp put_waiting_on_sub_issues_state_active(changeset) do
      active_states = get_field(changeset, :active_states) || []

      case get_field(changeset, :waiting_on_sub_issues_state) do
        state when is_binary(state) ->
          if Enum.any?(active_states, &(is_binary(&1) and String.downcase(String.trim(&1)) == String.downcase(state))),
            do: changeset,
            else: put_change(changeset, :active_states, active_states ++ [state])

        nil ->
          changeset
      end
    end

    defp normalize_optional_string(changeset, field) do
      update_change(changeset, field, fn
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            normalized -> normalized
          end

        nil ->
          nil
      end)
    end

    defp normalize_string_list(changeset, field) do
      update_change(changeset, field, fn
        values when is_list(values) ->
          values
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        nil ->
          []
      end)
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Poller do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:backoff_base_ms, :integer)
      field(:max_backoff_ms, :integer, default: 300_000)
      field(:degraded_threshold, :integer, default: 3)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:backoff_base_ms, :max_backoff_ms, :degraded_threshold], empty_values: [])
      |> validate_number(:backoff_base_ms, greater_than: 0)
      |> validate_number(:max_backoff_ms, greater_than: 0)
      |> validate_number(:degraded_threshold, greater_than: 0)
    end
  end

  defmodule Watchdog do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:tick_interval_ms, :integer, default: 60_000)
      field(:no_progress_threshold_ms, :integer, default: 600_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :tick_interval_ms, :no_progress_threshold_ms], empty_values: [])
      |> validate_number(:tick_interval_ms, greater_than: 0)
      |> validate_number(:no_progress_threshold_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    defmodule Sandbox do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:allow_read_paths, {:array, :string}, default: [])
        field(:allow_write_paths, {:array, :string}, default: [])
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:allow_read_paths, :allow_write_paths], empty_values: [])
        |> normalize_string_list(:allow_read_paths)
        |> normalize_string_list(:allow_write_paths)
      end

      defp normalize_string_list(changeset, field) do
        update_change(changeset, field, fn
          values when is_list(values) ->
            values
            |> Enum.map(&to_string/1)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.uniq()

          nil ->
            []
        end)
      end
    end

    defmodule Lifecycle do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      @orphan_actions ["log", "delete", "trash"]

      embedded_schema do
        field(:age_gc_enabled, :boolean, default: true)
        field(:max_age_days, :integer, default: 14)
        field(:gc_interval_ms, :integer, default: 3_600_000)
        field(:min_free_bytes, :integer)
        field(:orphan_action, :string, default: "log")
        field(:trash_dir, :string, default: ".trash")
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(
          attrs,
          [:age_gc_enabled, :max_age_days, :gc_interval_ms, :min_free_bytes, :orphan_action, :trash_dir],
          empty_values: []
        )
        |> validate_number(:max_age_days, greater_than: 0)
        |> validate_number(:gc_interval_ms, greater_than: 0)
        |> validate_number(:min_free_bytes, greater_than_or_equal_to: 0)
        |> validate_inclusion(:orphan_action, @orphan_actions)
        |> normalize_trash_dir()
        |> validate_trash_dir()
      end

      defp normalize_trash_dir(changeset) do
        update_change(changeset, :trash_dir, fn
          value when is_binary(value) ->
            case String.trim(value) do
              "" -> ".trash"
              normalized -> normalized
            end

          nil ->
            ".trash"
        end)
      end

      defp validate_trash_dir(changeset) do
        validate_change(changeset, :trash_dir, fn :trash_dir, value ->
          cond do
            !is_binary(value) ->
              [trash_dir: "must be a relative directory name"]

            Path.type(value) != :relative ->
              [trash_dir: "must be a relative directory name"]

            String.contains?(value, ["\n", "\r", <<0>>]) ->
              [trash_dir: "must not contain control characters"]

            ".." in Path.split(value) ->
              [trash_dir: "must not contain parent directory segments"]

            true ->
              []
          end
        end)
      end
    end

    defmodule Attachments do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      @default_allowed_hosts ["github.com"]
      @default_public_upload_extensions [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf"]

      @type t :: %__MODULE__{allowed_hosts: [String.t()], public_upload_extensions: [String.t()]}

      @doc false
      @spec default_public_upload_extensions() :: [String.t()]
      def default_public_upload_extensions, do: @default_public_upload_extensions

      embedded_schema do
        field(:allowed_hosts, {:array, :string}, default: @default_allowed_hosts)
        field(:public_upload_extensions, {:array, :string}, default: @default_public_upload_extensions)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:allowed_hosts, :public_upload_extensions], empty_values: [])
        |> update_change(:allowed_hosts, &allowed_hosts_or_default/1)
        |> normalize_public_upload_extensions()
        |> validate_public_upload_extensions()
      end

      defp allowed_hosts_or_default(hosts) do
        case Schema.normalize_domain_list(hosts) do
          [] -> @default_allowed_hosts
          normalized -> normalized
        end
      end

      defp normalize_public_upload_extensions(changeset) do
        update_change(changeset, :public_upload_extensions, fn
          extensions when is_list(extensions) ->
            extensions
            |> Enum.map(&normalize_extension/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.uniq()
        end)
      end

      defp normalize_extension(extension) when is_binary(extension) do
        extension = extension |> String.trim() |> String.downcase()

        cond do
          extension == "" -> ""
          String.starts_with?(extension, ".") -> extension
          true -> "." <> extension
        end
      end

      defp validate_public_upload_extensions(changeset) do
        validate_change(changeset, :public_upload_extensions, fn :public_upload_extensions, extensions ->
          invalid_extensions =
            Enum.reject(extensions, fn
              "." <> rest when rest != "" ->
                not String.contains?(rest, ["/", "\\", <<0>>, "\n", "\r"])

              _extension ->
                false
            end)

          case invalid_extensions do
            [] -> []
            _ -> [public_upload_extensions: "must contain only file extensions like .png"]
          end
        end)
      end
    end

    @primary_key false
    embedded_schema do
      field(:root, :string)
      field(:strategy, :string, default: "clone")
      field(:repo, :string)
      field(:fetch_before_dispatch, :boolean, default: true)
      embeds_one(:attachments, Attachments, on_replace: :update, defaults_to_struct: true)
      embeds_one(:sandbox, Sandbox, on_replace: :update, defaults_to_struct: true)
      embeds_one(:lifecycle, Lifecycle, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root, :strategy, :repo, :fetch_before_dispatch], empty_values: [])
      |> cast_embed(:attachments, with: &Attachments.changeset/2)
      |> cast_embed(:sandbox, with: &Sandbox.changeset/2)
      |> cast_embed(:lifecycle, with: &Lifecycle.changeset/2)
      |> validate_inclusion(:strategy, ["clone", "worktree"])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule GitHub do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    defmodule Webhooks do
      @moduledoc false
      # GitHub webhooks delivered through a relay to `POST /api/v1/github/webhook`. They only
      # speed up the CI poller; polling stays on and catches up on anything a relay drops.
      use Ecto.Schema
      import Ecto.Changeset

      @relays ["smee", "cloudflare_tunnel", "gh_webhook_forward"]
      @events ["check_suite", "check_run", "workflow_run", "pull_request"]

      @type t :: %__MODULE__{}

      @derive {Inspect, except: [:secret]}
      @primary_key false
      embedded_schema do
        field(:enabled, :boolean, default: false)
        field(:relay, :string, default: "smee")
        field(:secret, :string)
        field(:events, {:array, :string}, default: @events)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:enabled, :relay, :secret, :events], empty_values: [])
        |> validate_inclusion(:relay, @relays)
        |> validate_subset(:events, @events)
      end
    end

    @primary_key false
    embedded_schema do
      field(:enterprise_hosts, {:array, :string}, default: [])
      field(:failed_run_log_max_bytes, :integer, default: 65_536)
      field(:open_pull_requests_as_draft, :boolean, default: true)
      embeds_one(:webhooks, Webhooks, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enterprise_hosts, :failed_run_log_max_bytes, :open_pull_requests_as_draft], empty_values: [])
      |> cast_embed(:webhooks, with: &Webhooks.changeset/2)
      |> update_change(:enterprise_hosts, &Schema.normalize_domain_list/1)
      |> validate_number(:failed_run_log_max_bytes, greater_than: 0)
    end
  end

  defmodule RepoAgent do
    @moduledoc false
    # A repository's `repositories[].agent` block: run profile settings that take precedence over
    # the `agent` section for issues routed to that repository.
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema
    alias SymphonyElixir.Config.Schema.Agent
    alias SymphonyElixir.RunKind

    @primary_key false

    embedded_schema do
      field(:model, :string)
      field(:effort, :string)
      field(:provider, :string)
      field(:run_profiles, :map, default: %{})
    end

    @type t :: %__MODULE__{}
    @type sections :: %{agent: Agent.t(), review_agent: map(), auto_review: map(), worker: map()}

    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:model, :effort, :provider, :run_profiles], empty_values: [])
      |> Agent.validate_run_profile_settings()
    end

    @doc """
    Parses a repository's agent block against the operator sections it overrides. Each error is
    a message that starts with `path`, the block's config key (`repositories[<key>].agent`).
    """
    @spec parse(map(), sections(), String.t()) :: {:ok, t()} | {:error, [String.t()]}
    def parse(attrs, sections, path) do
      case %__MODULE__{} |> changeset(attrs) |> apply_action(:validate) do
        {:ok, repo_agent} ->
          case openrouter_errors(repo_agent, sections, path) ++ command_flag_errors(repo_agent, sections, path) do
            [] -> {:ok, repo_agent}
            errors -> {:error, errors}
          end

        {:error, changeset} ->
          {:error, field_errors(changeset, path)}
      end
    end

    @doc """
    The model, effort and provider a run of `kind` resolves to, field by field:
    `repositories[].agent.run_profiles.<kind>`, `repositories[].agent`, `agent.run_profiles.<kind>`,
    `agent`, then nil (or `"anthropic"` for the provider).
    """
    @spec resolve(t() | nil, Agent.t(), String.t()) :: %{
            model: String.t() | nil,
            effort: String.t() | nil,
            provider: RunKind.provider()
          }
    def resolve(repo_agent, agent, kind) do
      layers = [profile(repo_agent, kind), fields(repo_agent), profile(agent, kind), fields(agent)]

      %{
        model: Enum.find_value(layers, & &1["model"]),
        effort: Enum.find_value(layers, & &1["effort"]),
        provider: Enum.find_value(layers, & &1["provider"]) || "anthropic"
      }
    end

    defp profile(nil, _kind), do: %{}
    defp profile(%{run_profiles: profiles}, kind), do: Map.get(profiles, kind, %{})

    defp fields(nil), do: %{}
    defp fields(%{model: model, effort: effort, provider: provider}), do: %{"model" => model, "effort" => effort, "provider" => provider}

    defp field_errors(changeset, path) do
      changeset
      |> traverse_errors(fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end)
      end)
      |> Enum.flat_map(fn {key, messages} -> Enum.map(messages, &"#{path}.#{key} #{&1}") end)
      |> Enum.sort()
    end

    # Only the runs this block points at OpenRouter are checked here; the `agent` section checks
    # its own. Each error names the key that picked OpenRouter.
    defp openrouter_errors(repo_agent, %{agent: agent, worker: worker}, path) do
      RunKind.names()
      |> Enum.filter(&(resolve(repo_agent, agent, &1).provider == "openrouter"))
      |> Enum.group_by(&openrouter_key(repo_agent, &1))
      |> Map.delete(nil)
      |> Enum.sort()
      |> Enum.flat_map(fn {key, kinds} ->
        missing = Enum.filter(kinds, &is_nil(resolve(repo_agent, agent, &1).model))

        openrouter_runtime_errors(agent, path, key) ++
          openrouter_worker_errors(worker, path, key) ++ openrouter_model_errors(path, key, missing)
      end)
    end

    defp openrouter_key(repo_agent, kind) do
      cond do
        Map.has_key?(profile(repo_agent, kind), "provider") -> "run_profiles.#{kind}.provider"
        repo_agent.provider == "openrouter" -> "provider"
        true -> nil
      end
    end

    defp openrouter_runtime_errors(%{kind: "claude"}, _path, _key), do: []
    defp openrouter_runtime_errors(_agent, path, key), do: ["#{path}.#{key} openrouter is only supported with agent.runtime: claude"]

    defp openrouter_worker_errors(%{ssh_hosts: [_ | _]}, path, key) do
      ["#{path}.#{key} openrouter is not supported with workers.ssh_hosts; OpenRouter runs start on the local host only"]
    end

    defp openrouter_worker_errors(_worker, _path, _key), do: []

    defp openrouter_model_errors(_path, _key, []), do: []

    defp openrouter_model_errors(path, "provider", kinds) do
      [
        "#{path}.provider openrouter needs an OpenRouter model id; set #{path}.model, #{path}.run_profiles.<kind>.model or agent.model (missing for: #{Enum.join(kinds, ", ")})"
      ]
    end

    defp openrouter_model_errors(path, key, [kind]) do
      ["#{path}.#{key} openrouter needs an OpenRouter model id; set #{path}.run_profiles.#{kind}.model, #{path}.model or agent.model"]
    end

    # The resolved model and effort are passed as flags, so a command that already passes one
    # would give it twice. `agent.command` serves every run kind; the reviewer and QA commands
    # only their own.
    defp command_flag_errors(repo_agent, sections, path) do
      [
        {"agent.command", sections.agent.command, Schema.profile_settings?(repo_agent, nil)},
        {"pre_push_review.command", sections.review_agent.command, Schema.profile_settings?(repo_agent, "pre_push_review")},
        {"auto_review.command", sections.auto_review.command, Schema.profile_settings?(repo_agent, "qa")}
      ]
      |> Enum.filter(fn {_key, _command, settings?} -> settings? end)
      |> Enum.flat_map(fn {key, command, _settings?} ->
        Enum.map(Agent.profile_flags_in(command), &"#{key} must not pass #{&1} when #{path} sets a model, effort or run_profiles; remove it from #{key}")
      end)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema
    alias SymphonyElixir.RunKind

    @efforts ["low", "medium", "high", "xhigh", "max"]
    @providers ["anthropic", "openrouter"]
    @run_profile_keys ["model", "effort", "provider"]
    @run_profile_error_keys Map.new(
                              for kind <- RunKind.names(), suffix <- ["", ".model", ".effort", ".provider"] do
                                {kind <> suffix, :"run_profiles.#{kind}#{suffix}"}
                              end
                            )

    @default_max_tokens_per_issue 500_000
    @default_max_tokens_per_day 5_000_000
    # Codex first-turn prompts larger than this (bytes) are replaced by a compact
    # bootstrap prompt. The cap exists because, under the SRT sandbox, very large
    # echoed `userMessage` events can wedge the app-server stdout stream. Raised
    # from the original 12_000; SRT users who still hit stdout transport failures
    # can lower it. See docs/configuration.md.
    @default_codex_stdio_prompt_soft_limit 65_536
    @codex_default_approval_policy %{
      "reject" => %{
        "sandbox_approval" => true,
        "rules" => true,
        "mcp_elicitations" => true
      }
    }

    @doc false
    @spec codex_default_approval_policy() :: map()
    def codex_default_approval_policy, do: @codex_default_approval_policy

    defmodule NetworkAccess do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false
      @modes ["allowlist", "open", "block"]

      embedded_schema do
        field(:mode, :string, default: "allowlist")
        field(:allowed_domains, {:array, :string}, default: [])
        field(:denied_domains, {:array, :string}, default: [])
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:mode, :allowed_domains, :denied_domains], empty_values: [])
        |> validate_required([:mode])
        |> validate_inclusion(:mode, @modes)
      end
    end

    defmodule SandboxRuntime do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false
      @kinds ["none", "srt"]

      embedded_schema do
        field(:kind, :string, default: "none")
        field(:command, :string, default: "srt")
        field(:enable_weaker_network_isolation, :boolean, default: false)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:kind, :command, :enable_weaker_network_isolation], empty_values: [])
        |> validate_required([:kind])
        |> validate_inclusion(:kind, @kinds)
        |> validate_command_when_enabled()
      end

      defp validate_command_when_enabled(changeset) do
        case get_field(changeset, :kind) do
          "srt" -> validate_required(changeset, [:command])
          _kind -> changeset
        end
      end
    end

    defmodule UsageLimit do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false

      embedded_schema do
        field(:auto_pause, :boolean, default: true)
        field(:resume_margin_seconds, :integer, default: 120)
        field(:unknown_reset_retry_seconds, :integer, default: 900)
        field(:headroom_utilization, :float)
      end

      @fields [:auto_pause, :resume_margin_seconds, :unknown_reset_retry_seconds, :headroom_utilization]

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, @fields, empty_values: [])
        |> validate_required([:auto_pause, :resume_margin_seconds, :unknown_reset_retry_seconds])
        |> validate_number(:resume_margin_seconds, greater_than_or_equal_to: 0)
        |> validate_number(:unknown_reset_retry_seconds, greater_than_or_equal_to: 60)
        |> validate_number(:headroom_utilization, greater_than: 0, less_than_or_equal_to: 1)
      end
    end

    defmodule Mcp do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false
      @inherit_modes ["none", "allowlist", "all"]
      @reserved_server_names ["symphony"]

      defmodule Server do
        @moduledoc false
        use Ecto.Schema
        import Ecto.Changeset

        @type t :: %__MODULE__{}

        @primary_key false
        @transports ["stdio", "http", "sse"]
        @runtimes ["claude", "codex"]

        embedded_schema do
          field(:name, :string)
          field(:transport, :string, default: "stdio")
          field(:command, :string)
          field(:args, {:array, :string}, default: [])
          field(:env, :map, default: %{})
          field(:url, :string)
          field(:headers, :map, default: %{})
          field(:runtimes, {:array, :string}, default: @runtimes)
        end

        @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
        def changeset(schema, attrs) do
          schema
          |> cast(attrs, [:name, :transport, :command, :args, :env, :url, :headers, :runtimes], empty_values: [])
          |> validate_required([:name, :transport])
          |> validate_inclusion(:transport, @transports)
          |> normalize_string_list(:args)
          |> normalize_string_list(:runtimes)
          |> normalize_optional_map(:env)
          |> normalize_optional_map(:headers)
          |> validate_runtime_values()
          |> validate_transport_requirements()
          |> validate_transport_runtimes()
        end

        defp normalize_string_list(changeset, field) do
          update_change(changeset, field, fn values ->
            values
            |> Enum.filter(&is_binary/1)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
          end)
        end

        defp normalize_optional_map(changeset, field) do
          update_change(changeset, field, fn value ->
            value
            |> Enum.map(fn {key, map_value} -> {to_string(key), resolve_env_reference(map_value)} end)
            |> Enum.reject(fn {_key, map_value} -> is_nil(map_value) end)
            |> Map.new()
          end)
        end

        defp resolve_env_reference("$" <> env_name = value) do
          if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
            case System.get_env(env_name) do
              nil -> value
              "" -> nil
              env_value -> env_value
            end
          else
            value
          end
        end

        defp resolve_env_reference(value), do: value

        defp validate_runtime_values(changeset) do
          validate_change(changeset, :runtimes, fn :runtimes, runtimes ->
            invalid = Enum.reject(runtimes, &(&1 in @runtimes))

            case invalid do
              [] -> []
              _invalid -> [runtimes: "contains unsupported runtime"]
            end
          end)
        end

        defp validate_transport_requirements(changeset) do
          case get_field(changeset, :transport) do
            "stdio" -> validate_required(changeset, [:command])
            transport when transport in ["http", "sse"] -> validate_required(changeset, [:url])
            _transport -> changeset
          end
        end

        defp validate_transport_runtimes(changeset) do
          transport = get_field(changeset, :transport)
          runtimes = get_field(changeset, :runtimes) || []

          if transport in ["http", "sse"] and "codex" in runtimes do
            add_error(
              changeset,
              :runtimes,
              ~s(transport=#{inspect(transport)} is not supported for Codex; Codex MCP servers must use transport="stdio")
            )
          else
            changeset
          end
        end
      end

      embedded_schema do
        field(:inherit, :string, default: "none")
        field(:allowed_servers, {:array, :string}, default: [])
        field(:servers, :map, default: %{})
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:inherit, :allowed_servers, :servers], empty_values: [])
        |> validate_required([:inherit])
        |> validate_inclusion(:inherit, @inherit_modes)
        |> normalize_string_list(:allowed_servers)
        |> validate_allowlist_servers()
        |> cast_servers()
      end

      defp normalize_string_list(changeset, field) do
        update_change(changeset, field, fn values ->
          values
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
        end)
      end

      defp validate_allowlist_servers(changeset) do
        inherit = get_field(changeset, :inherit)
        allowed_servers = get_field(changeset, :allowed_servers) || []

        cond do
          inherit == "allowlist" and allowed_servers == [] ->
            add_error(changeset, :allowed_servers, "must not be empty when agent.mcp.inherit is allowlist")

          inherit in ["none", "all"] and allowed_servers != [] ->
            add_error(changeset, :allowed_servers, "must be empty unless agent.mcp.inherit is allowlist")

          true ->
            changeset
        end
      end

      defp cast_servers(changeset) do
        raw_servers = get_field(changeset, :servers) || %{}

        with :ok <- validate_servers_map(raw_servers),
             :ok <- validate_reserved_server_names(raw_servers) do
          put_cast_servers(changeset, raw_servers)
        else
          {:error, message} -> add_error(changeset, :servers, message)
        end
      end

      defp validate_servers_map(raw_servers) do
        if is_map(raw_servers), do: :ok, else: {:error, "must be a map"}
      end

      defp validate_reserved_server_names(raw_servers) do
        reserved? =
          raw_servers
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Enum.any?(&(&1 in @reserved_server_names))

        if reserved?, do: {:error, "must not declare reserved MCP server names"}, else: :ok
      end

      defp put_cast_servers(changeset, raw_servers) do
        {updated_changeset, servers} =
          Enum.reduce(raw_servers, {changeset, %{}}, fn {name, attrs}, acc ->
            cast_server_entry(acc, name, attrs)
          end)

        put_change(updated_changeset, :servers, servers)
      end

      defp cast_server_entry({changeset, servers}, name, attrs) do
        attrs = if is_map(attrs), do: attrs, else: %{}
        name = to_string(name)

        case Server.changeset(%Server{}, Map.put(attrs, "name", name)) |> apply_action(:insert) do
          {:ok, server} ->
            {changeset, Map.put(servers, name, server)}

          {:error, server_changeset} ->
            message = "#{name} is invalid: #{inspect(server_changeset.errors)}"
            {add_error(changeset, :servers, message), servers}
        end
      end
    end

    @primary_key false
    embedded_schema do
      field(:kind, :string)
      field(:max_concurrent_agents, :integer, default: 10)
      field(:epic_lanes, :integer)
      field(:finishing_max, :integer, default: 2)
      field(:force_label, :string, default: "expedite")
      field(:forced_max, :integer, default: 1)
      field(:forced_stale_after_hours, :integer, default: 72)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      field(:max_tokens_per_issue, :integer, default: @default_max_tokens_per_issue)
      field(:max_tokens_per_day, :integer, default: @default_max_tokens_per_day)
      field(:max_consecutive_identical_tool_failures, :integer, default: 5)
      field(:command, :string)
      field(:model, :string)
      field(:effort, :string)
      field(:provider, :string)
      field(:run_profiles, :map, default: %{})

      field(:approval_policy, StringOrMap)
      field(:include_project_guides, :boolean, default: true)
      field(:project_guide_files, {:array, :string})

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      embeds_one(:mcp, Mcp, on_replace: :update, defaults_to_struct: true)
      embeds_one(:network_access, NetworkAccess, on_replace: :update, defaults_to_struct: true)
      embeds_one(:sandbox_runtime, SandboxRuntime, on_replace: :update, defaults_to_struct: true)
      embeds_one(:usage_limit, UsageLimit, on_replace: :update, defaults_to_struct: true)
      # The routed repository's `repositories[].agent` block; `Config` sets it per repository.
      embeds_one(:repository, Schema.RepoAgent, on_replace: :update)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 30_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      field(:command_timeout_ms, :integer, default: 600_000)
      field(:codex_stdio_prompt_soft_limit, :integer, default: @default_codex_stdio_prompt_soft_limit)
    end

    @type t :: %__MODULE__{}

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :max_concurrent_agents,
          :epic_lanes,
          :finishing_max,
          :force_label,
          :forced_max,
          :forced_stale_after_hours,
          :max_turns,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state,
          :max_tokens_per_issue,
          :max_tokens_per_day,
          :max_consecutive_identical_tool_failures,
          :command,
          :model,
          :effort,
          :provider,
          :run_profiles,
          :approval_policy,
          :include_project_guides,
          :project_guide_files,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms,
          :command_timeout_ms,
          :codex_stdio_prompt_soft_limit
        ],
        empty_values: []
      )
      |> validate_required([:kind, :command, :force_label])
      |> validate_inclusion(:kind, ["codex", "claude"])
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_epic_lanes()
      |> validate_number(:finishing_max, greater_than: 0)
      |> validate_number(:forced_max, greater_than: 0)
      |> validate_number(:forced_stale_after_hours, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:max_tokens_per_issue, greater_than: 0)
      |> validate_number(:max_tokens_per_day, greater_than: 0)
      |> validate_number(:max_consecutive_identical_tool_failures, greater_than_or_equal_to: 0)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:command_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:codex_stdio_prompt_soft_limit, greater_than: 0)
      |> validate_project_guide_files()
      |> validate_run_profile_settings()
      |> validate_openrouter_profiles()
      |> validate_command_run_profile_flags()
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
      |> cast_embed(:mcp, with: &Mcp.changeset/2)
      |> cast_embed(:network_access, with: &NetworkAccess.changeset/2)
      |> cast_embed(:sandbox_runtime, with: &SandboxRuntime.changeset/2)
      |> cast_embed(:usage_limit, with: &UsageLimit.changeset/2)
      |> cast_embed(:repository, with: &Schema.RepoAgent.changeset/2)
    end

    # Lanes come out of `max_total`, so there can be at most that many; unset means every slot can be a lane.
    defp validate_epic_lanes(changeset) do
      case get_field(changeset, :max_concurrent_agents) do
        max_total when is_integer(max_total) and max_total > 0 ->
          validate_number(changeset, :epic_lanes,
            greater_than_or_equal_to: 0,
            less_than_or_equal_to: max_total,
            message: "must be between 0 and agent.concurrency.max_total (#{max_total})"
          )

        _max_total ->
          validate_number(changeset, :epic_lanes, greater_than_or_equal_to: 0)
      end
    end

    @doc false
    @spec validate_profile_fields(Ecto.Changeset.t()) :: Ecto.Changeset.t()
    def validate_profile_fields(changeset) do
      changeset
      |> validate_setting(:model, &check_model/1)
      |> validate_setting(:effort, &check_effort/1)
    end

    @doc false
    @spec validate_run_profile_settings(Ecto.Changeset.t()) :: Ecto.Changeset.t()
    def validate_run_profile_settings(changeset) do
      changeset
      |> validate_profile_fields()
      |> validate_setting(:provider, &check_provider/1)
      |> validate_run_profiles()
    end

    @doc false
    @spec profile_flags_in(String.t() | nil) :: [String.t()]
    def profile_flags_in(command) when is_binary(command) do
      Enum.filter(["--model", "--effort"], &Regex.match?(~r/(^|\s)#{&1}(=|\s|$)/, command))
    end

    def profile_flags_in(_command), do: []

    defp validate_setting(changeset, field, check) do
      case Map.fetch(changeset.changes, field) do
        {:ok, value} ->
          case check.(value) do
            {:ok, value} -> put_change(changeset, field, value)
            {:error, message} -> add_error(changeset, field, message)
          end

        :error ->
          changeset
      end
    end

    defp check_model(model) when is_binary(model) do
      case String.trim(model) do
        "" -> {:error, "must not be blank"}
        trimmed -> {:ok, trimmed}
      end
    end

    defp check_model(_model), do: {:error, "must be a string"}

    defp check_effort(effort) when effort in @efforts, do: {:ok, effort}
    defp check_effort(_effort), do: {:error, "must be one of: #{Enum.join(@efforts, ", ")}"}

    defp check_provider(provider) when provider in @providers, do: {:ok, provider}
    defp check_provider(_provider), do: {:error, "must be one of: #{Enum.join(@providers, ", ")}"}

    defp validate_run_profiles(changeset) do
      case Map.fetch(changeset.changes, :run_profiles) do
        {:ok, profiles} ->
          {changeset, normalized} = Enum.reduce(profiles, {changeset, %{}}, &cast_run_profile/2)
          put_change(changeset, :run_profiles, normalized)

        :error ->
          changeset
      end
    end

    defp cast_run_profile({kind, profile}, {changeset, normalized}) do
      kind = to_string(kind)

      cond do
        not Map.has_key?(@run_profile_error_keys, kind) ->
          message = "has unknown run kind `#{kind}`; expected one of: #{Enum.join(RunKind.names(), ", ")}"
          {add_error(changeset, :run_profiles, message), normalized}

        not is_map(profile) ->
          {add_error(changeset, @run_profile_error_keys[kind], "must be an object with model, effort and/or provider"), normalized}

        true ->
          cast_run_profile_fields(changeset, normalized, kind, Map.new(profile, fn {key, value} -> {to_string(key), value} end))
      end
    end

    defp cast_run_profile_fields(changeset, normalized, kind, profile) do
      case Map.keys(profile) -- @run_profile_keys do
        [] ->
          {changeset, normalized_profile} = Enum.reduce(profile, {changeset, %{}}, &cast_run_profile_field(&1, &2, kind))
          {changeset, Map.put(normalized, kind, normalized_profile)}

        [unknown | _rest] ->
          {add_error(changeset, @run_profile_error_keys[kind], "has unknown key `#{unknown}`; expected model, effort or provider"), normalized}
      end
    end

    defp cast_run_profile_field({key, value}, {changeset, fields}, kind) do
      case check_run_profile_field(key, value) do
        {:ok, value} -> {changeset, Map.put(fields, key, value)}
        {:error, message} -> {add_error(changeset, @run_profile_error_keys["#{kind}.#{key}"], message), fields}
      end
    end

    defp check_run_profile_field("model", model), do: check_model(model)
    defp check_run_profile_field("effort", effort), do: check_effort(effort)
    defp check_run_profile_field("provider", provider), do: check_provider(provider)

    # OpenRouter serves the model a run names, so every run it serves needs a resolved model,
    # and only the Claude runtime can be pointed at it. Each error names the key that picked
    # OpenRouter: the profile's `provider`, else `agent.provider`.
    defp validate_openrouter_profiles(changeset) do
      provider = get_field(changeset, :provider)
      model = get_field(changeset, :model)
      profiles = get_field(changeset, :run_profiles)

      RunKind.names()
      |> Enum.map(&{&1, Map.get(profiles, &1, %{})})
      |> Enum.filter(fn {_kind, profile} -> Map.get(profile, "provider", provider) == "openrouter" end)
      |> Enum.group_by(&openrouter_error_key/1, fn {kind, profile} -> {kind, Map.get(profile, "model", model)} end)
      |> Enum.reduce(changeset, fn {key, resolved}, acc ->
        acc
        |> add_openrouter_runtime_error(key)
        |> add_openrouter_model_error(key, for({kind, nil} <- resolved, do: kind))
      end)
    end

    defp openrouter_error_key({kind, %{"provider" => _provider}}), do: @run_profile_error_keys["#{kind}.provider"]
    defp openrouter_error_key({_kind, _profile}), do: :provider

    defp add_openrouter_runtime_error(changeset, key) do
      case get_field(changeset, :kind) do
        "claude" -> changeset
        _runtime -> add_error(changeset, key, "openrouter is only supported with agent.runtime: claude")
      end
    end

    defp add_openrouter_model_error(changeset, _key, []), do: changeset

    defp add_openrouter_model_error(changeset, :provider, kinds) do
      add_error(
        changeset,
        :provider,
        "openrouter needs an OpenRouter model id; set agent.model or agent.run_profiles.<kind>.model (missing for: #{Enum.join(kinds, ", ")})"
      )
    end

    defp add_openrouter_model_error(changeset, key, [kind]) do
      add_error(changeset, key, "openrouter needs an OpenRouter model id; set agent.run_profiles.#{kind}.model or agent.model")
    end

    # The resolved model and effort are passed as flags, so the same flag in `agent.command`
    # would be given twice.
    defp validate_command_run_profile_flags(changeset) do
      command = get_field(changeset, :command)

      if run_profile_settings?(changeset) do
        command
        |> profile_flags_in()
        |> Enum.reduce(changeset, fn flag, acc ->
          add_error(acc, :command, "must not pass #{flag} when agent.model, agent.effort or agent.run_profiles is set; remove it from agent.command")
        end)
      else
        changeset
      end
    end

    defp run_profile_settings?(changeset) do
      not is_nil(get_field(changeset, :model)) or not is_nil(get_field(changeset, :effort)) or
        get_field(changeset, :run_profiles) not in [nil, %{}]
    end

    defp validate_project_guide_files(changeset) do
      validate_change(changeset, :project_guide_files, fn :project_guide_files, files ->
        files
        |> Enum.flat_map(&project_guide_file_errors/1)
        |> Enum.map(&{:project_guide_files, &1})
      end)
    end

    defp project_guide_file_errors(file) when is_binary(file) do
      trimmed = String.trim(file)

      cond do
        trimmed == "" ->
          ["must not contain blank entries"]

        Path.type(trimmed) != :relative ->
          ["must contain relative paths only"]

        String.starts_with?(trimmed, "~") ->
          ["must contain relative paths only"]

        String.contains?(trimmed, ["\n", "\r", <<0>>]) ->
          ["must not contain control characters"]

        ".." in Path.split(trimmed) ->
          ["must not contain parent directory segments"]

        true ->
          []
      end
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @type t :: %__MODULE__{}

    @fields [:after_create, :before_run, :after_run, :before_remove, :timeout_ms, :after_create_timeout_ms]
    # `after_create` usually installs dependencies, which a cold cache or a loaded
    # machine can stretch well past the other hooks' minute.
    @default_after_create_timeout_ms 600_000

    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
      field(:after_create_timeout_ms, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
      |> validate_number(:after_create_timeout_ms, greater_than: 0)
    end

    @doc """
    How long `after_create` may run: `after_create_timeout_ms` when set, else the
    larger of `timeout_ms` and 10 minutes.
    """
    @spec after_create_timeout_ms(t()) :: pos_integer()
    def after_create_timeout_ms(%__MODULE__{after_create_timeout_ms: timeout_ms}) when is_integer(timeout_ms), do: timeout_ms
    def after_create_timeout_ms(%__MODULE__{timeout_ms: timeout_ms}), do: max(timeout_ms, @default_after_create_timeout_ms)
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
      field(:snapshot_publish_ms, :integer, default: 500)
      field(:transcript_buffer_size, :integer, default: 200)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      fields = [:dashboard_enabled, :refresh_ms, :render_interval_ms, :snapshot_publish_ms, :transcript_buffer_size]

      schema
      |> cast(attrs, fields, empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
      |> validate_number(:snapshot_publish_ms, greater_than: 0)
      |> validate_number(:transcript_buffer_size, greater_than_or_equal_to: 0)
    end
  end

  defmodule PrReview do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @modes ["tracker", "polling"]
    @default_cooldown_minutes 10
    @default_stale_days 7

    embedded_schema do
      field(:mode, :string, default: "tracker")
      field(:poll_interval_ms, :integer)
      field(:cooldown_minutes, :integer)
      field(:stale_days, :integer)
      field(:ignored_users, {:array, :string}, default: [])
      field(:auto_reply, :boolean, default: false)
      field(:auto_request_review, :boolean, default: false)
      field(:auto_merge, :boolean, default: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        polling_attrs(attrs),
        [
          :mode,
          :poll_interval_ms,
          :cooldown_minutes,
          :stale_days,
          :ignored_users,
          :auto_reply,
          :auto_request_review,
          :auto_merge
        ],
        empty_values: []
      )
      |> put_polling_defaults()
      |> normalize_ignored_users()
      |> validate_required([:mode])
      |> validate_inclusion(:mode, @modes)
      |> validate_polling_options()
    end

    defp polling_attrs(attrs) when is_map(attrs) do
      case attrs |> Map.get("mode", Map.get(attrs, :mode, "tracker")) |> to_string() do
        "polling" ->
          attrs

        _mode ->
          Map.drop(attrs, [
            "cooldown_minutes",
            :cooldown_minutes,
            "poll_interval_ms",
            :poll_interval_ms,
            "stale_days",
            :stale_days,
            "ignored_users",
            :ignored_users,
            "auto_reply",
            :auto_reply,
            "auto_request_review",
            :auto_request_review
          ])
      end
    end

    defp put_polling_defaults(changeset) do
      if get_field(changeset, :mode) == "polling" do
        changeset
        |> put_default(:cooldown_minutes, @default_cooldown_minutes)
        |> put_default(:stale_days, @default_stale_days)
        |> put_default(:ignored_users, [])
        |> put_default(:auto_reply, false)
        |> put_default(:auto_request_review, false)
      else
        changeset
      end
    end

    defp normalize_ignored_users(changeset) do
      update_change(changeset, :ignored_users, fn
        values when is_list(values) ->
          values
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
      end)
    end

    defp put_default(changeset, field, default) do
      if is_nil(get_field(changeset, field)) do
        put_change(changeset, field, default)
      else
        changeset
      end
    end

    defp validate_polling_options(changeset) do
      if get_field(changeset, :mode) == "polling" do
        changeset
        |> validate_required([:cooldown_minutes, :stale_days])
        |> validate_number(:poll_interval_ms, greater_than: 0)
        |> validate_number(:cooldown_minutes, greater_than: 0)
        |> validate_number(:stale_days, greater_than: 0)
      else
        changeset
      end
    end
  end

  defmodule Ci do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @default_log_excerpt_lines 200
    @default_max_retries 3
    @default_merging_wait_timeout_ms 1_800_000

    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:poll_interval_ms, :integer)
      field(:log_excerpt_lines, :integer, default: @default_log_excerpt_lines)
      field(:flaky_retry, :boolean, default: true)
      field(:max_retries, :integer, default: @default_max_retries)
      field(:escalation_state, :string, default: "In Review")
      field(:merging_wait_timeout_ms, :integer, default: @default_merging_wait_timeout_ms)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :poll_interval_ms,
          :log_excerpt_lines,
          :flaky_retry,
          :max_retries,
          :escalation_state,
          :merging_wait_timeout_ms
        ],
        empty_values: []
      )
      |> normalize_escalation_state()
      |> validate_number(:poll_interval_ms, greater_than: 0)
      |> validate_number(:log_excerpt_lines, greater_than: 0)
      |> validate_number(:max_retries, greater_than_or_equal_to: 1)
      |> validate_number(:merging_wait_timeout_ms, greater_than: 0)
    end

    defp normalize_escalation_state(changeset) do
      update_change(changeset, :escalation_state, fn
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> "In Review"
            trimmed -> trimmed
          end

        _value ->
          "In Review"
      end)
    end
  end

  defmodule Verification do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    defmodule PortAllocation do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false
      embedded_schema do
        field(:range, {:array, :integer}, default: [4000, 4099])
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:range], empty_values: [])
        |> validate_required([:range])
        |> validate_range()
      end

      defp validate_range(changeset) do
        validate_change(changeset, :range, fn :range, range ->
          case range do
            [first, last]
            when is_integer(first) and is_integer(last) and first in 1..65_535 and last in 1..65_535 and
                   first <= last ->
              []

            [_first, _last] ->
              [range: "must contain two port integers between 1 and 65535 with start <= end"]

            _ ->
              [range: "must contain exactly two port integers"]
          end
        end)
      end
    end

    defmodule DevServer do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false
      @stop_signals ["TERM", "INT", "QUIT", "HUP", "KILL"]

      embedded_schema do
        field(:start_cmd, :string)
        field(:health_check_url, :string)
        field(:health_timeout_ms, :integer, default: 30_000)
        field(:stop_signal, :string, default: "TERM")
        field(:stop_timeout_ms, :integer, default: 10_000)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(
          attrs,
          [:start_cmd, :health_check_url, :health_timeout_ms, :stop_signal, :stop_timeout_ms],
          empty_values: []
        )
        |> normalize_optional_string(:start_cmd)
        |> normalize_optional_string(:health_check_url)
        |> normalize_stop_signal()
        |> validate_number(:health_timeout_ms, greater_than: 0)
        |> validate_number(:stop_timeout_ms, greater_than_or_equal_to: 0)
        |> validate_inclusion(:stop_signal, @stop_signals)
        |> validate_health_check_url_when_start_cmd_set()
      end

      defp normalize_optional_string(changeset, field) do
        update_change(changeset, field, fn value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end
        end)
      end

      defp normalize_stop_signal(changeset) do
        update_change(changeset, :stop_signal, fn
          value when is_binary(value) ->
            value
            |> String.trim()
            |> String.upcase()
            |> String.replace_prefix("SIG", "")

          value ->
            value
        end)
      end

      defp validate_health_check_url_when_start_cmd_set(changeset) do
        if present?(get_field(changeset, :start_cmd)) and not present?(get_field(changeset, :health_check_url)) do
          add_error(changeset, :health_check_url, "is required when verification.dev_server.start_cmd is set")
        else
          changeset
        end
      end

      defp present?(value) when is_binary(value), do: String.trim(value) != ""
      defp present?(_value), do: false
    end

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      embeds_one(:port_allocation, PortAllocation, on_replace: :update, defaults_to_struct: true)
      embeds_one(:dev_server, DevServer, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled], empty_values: [])
      |> cast_embed(:port_allocation, with: &PortAllocation.changeset/2)
      |> cast_embed(:dev_server, with: &DevServer.changeset/2)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule QualityGate do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @providers ["anthropic", "openai"]
    @on_error_modes ["pass", "skip"]
    @fields [
      :enabled,
      :provider,
      :model,
      :min_score,
      :pass_threshold,
      :clarification_floor,
      :max_clarification_rounds,
      :on_error
    ]

    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:provider, :string, default: "anthropic")
      field(:model, :string, default: "claude-haiku-4-5-20251001")
      field(:min_score, :integer, default: 6)
      field(:pass_threshold, :integer)
      field(:clarification_floor, :integer)
      field(:max_clarification_rounds, :integer, default: 2)
      field(:on_error, :string, default: "pass")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      provider_configured? = field_configured?(attrs, :provider)
      model_configured? = field_configured?(attrs, :model)

      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_inclusion(:provider, @providers, message: "must be one of: #{Enum.join(@providers, ", ")}")
      |> validate_inclusion(:on_error, @on_error_modes, message: "must be one of: #{Enum.join(@on_error_modes, ", ")}")
      |> validate_number(:min_score, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
      |> validate_number(:pass_threshold, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
      |> validate_number(:clarification_floor, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
      |> validate_number(:max_clarification_rounds, greater_than_or_equal_to: 1)
      |> validate_clarification_band()
      |> validate_model_when_provider_configured(provider_configured?, model_configured?)
      |> validate_required_when_enabled()
    end

    defp field_configured?(attrs, field) when is_map(attrs) do
      Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field))
    end

    defp validate_clarification_band(changeset) do
      floor = get_field(changeset, :clarification_floor)
      threshold = get_field(changeset, :pass_threshold) || get_field(changeset, :min_score)

      cond do
        is_nil(floor) or is_nil(threshold) ->
          changeset

        floor < threshold ->
          changeset

        true ->
          add_error(changeset, :clarification_floor, "must be less than pass_threshold")
      end
    end

    defp validate_model_when_provider_configured(changeset, true, false) do
      if get_field(changeset, :enabled) do
        add_error(changeset, :model, "is required when quality_gate.provider is set")
      else
        changeset
      end
    end

    defp validate_model_when_provider_configured(changeset, _provider_configured?, _model_configured?), do: changeset

    defp validate_required_when_enabled(changeset) do
      if get_field(changeset, :enabled) do
        changeset
        |> validate_required([:provider, :model],
          message: "is required when quality_gate.enabled is true"
        )
      else
        changeset
      end
    end
  end

  defmodule Learnings do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @providers ["anthropic", "openai"]
    @fields [:enabled, :provider, :model, :max_total_per_repo, :max_per_run]

    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:provider, :string, default: "anthropic")
      field(:model, :string, default: "claude-haiku-4-5-20251001")
      field(:max_total_per_repo, :integer, default: 500)
      field(:max_per_run, :integer, default: 3)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_inclusion(:provider, @providers, message: "must be one of: #{Enum.join(@providers, ", ")}")
      |> validate_number(:max_total_per_repo, greater_than: 0)
      |> validate_number(:max_per_run, greater_than_or_equal_to: 0, less_than_or_equal_to: 3)
      |> validate_required_when_enabled()
    end

    defp validate_required_when_enabled(changeset) do
      if get_field(changeset, :enabled) do
        validate_required(changeset, [:provider, :model, :max_total_per_repo, :max_per_run], message: "is required when learnings.enabled is true")
      else
        changeset
      end
    end
  end

  defmodule ReviewAgent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @fields [:enabled, :kind, :command, :model, :effort, :max_iterations, :run_on]

    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:kind, :string)
      field(:command, :string)
      field(:model, :string)
      field(:effort, :string)
      field(:max_iterations, :integer, default: 1)
      field(:run_on, :string, default: "always")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_inclusion(:kind, ["codex", "claude"])
      |> validate_inclusion(:run_on, ["always", "first_push"])
      |> validate_number(:max_iterations, greater_than: 0)
      |> Agent.validate_profile_fields()
      |> validate_required_when_enabled()
    end

    defp validate_required_when_enabled(changeset) do
      if get_field(changeset, :enabled) do
        validate_required(changeset, [:kind, :command, :max_iterations], message: "is required when review_agent.enabled is true")
      else
        changeset
      end
    end
  end

  defmodule AutoReview do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @fields [
      :enabled,
      :state,
      :kind,
      :command,
      :model,
      :effort,
      :max_turns,
      :timeout_ms,
      :max_concurrent,
      :max_fix_attempts,
      :run_on,
      :skip_globs,
      :playbooks,
      :worker_host
    ]

    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:state, :string, default: "Auto Review")
      field(:kind, :string)
      field(:command, :string)
      field(:model, :string)
      field(:effort, :string)
      field(:max_turns, :integer, default: 20)
      field(:timeout_ms, :integer, default: 1_800_000)
      field(:max_concurrent, :integer, default: 1)
      field(:max_fix_attempts, :integer, default: 2)
      field(:run_on, :string, default: "every_push")
      field(:skip_globs, {:array, :string}, default: [])
      field(:playbooks, :map, default: %{})
      field(:worker_host, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_required([:state])
      |> validate_format(:worker_host, ~r/\A[^\s-]\S*\z/, message: "must be an SSH host such as qa@qa-vm.local or qa-vm:2222")
      |> validate_inclusion(:kind, ["codex", "claude"])
      |> validate_inclusion(:run_on, ["every_push", "first_pass"])
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:timeout_ms, greater_than: 0)
      |> validate_number(:max_concurrent, greater_than: 0)
      |> validate_number(:max_fix_attempts, greater_than_or_equal_to: 0)
      |> Agent.validate_profile_fields()
    end
  end

  defmodule Dependencies do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @fields [:allow_registries, :allow_git_sources, :allow_path_sources]

    embedded_schema do
      field(:allow_registries, {:array, :string}, default: [])
      field(:allow_git_sources, {:array, :string}, default: [])
      field(:allow_path_sources, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> normalize_string_list(:allow_registries)
      |> normalize_string_list(:allow_git_sources)
      |> normalize_string_list(:allow_path_sources)
    end

    defp normalize_string_list(changeset, field) do
      update_change(changeset, field, fn
        values when is_list(values) ->
          values
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        nil ->
          []
      end)
    end
  end

  defmodule Notifications do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    defmodule Channel do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset
      import Bitwise

      @primary_key false
      @derive {Inspect, except: [:webhook_url, :url, :headers]}
      @kinds ["slack", "webhook"]
      @events [
        "pr_opened",
        "awaiting_review",
        "run_failed",
        "run_stuck",
        "issue_completed",
        "budget_exceeded",
        "dependency_pending_approval",
        "reviewer_commented",
        "rework_pushed",
        "ci_failed",
        "ci_escalated",
        "qa_passed",
        "qa_failed",
        "usage_limit_paused",
        "usage_limit_headroom",
        "usage_limit_resumed"
      ]

      embedded_schema do
        field(:kind, :string)
        field(:webhook_url, :string)
        field(:url, :string)
        field(:allow_private, :boolean, default: false)
        field(:events, {:array, :string})
        field(:headers, :map, default: %{})
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:kind, :webhook_url, :url, :allow_private, :events, :headers], empty_values: [])
        |> update_change(:kind, &normalize_string/1)
        |> update_change(:events, &normalize_events/1)
        |> update_change(:headers, &normalize_headers/1)
        |> validate_required([:kind])
        |> validate_inclusion(:kind, @kinds)
        |> validate_event_names()
        |> validate_webhook_url_field(:webhook_url)
        |> validate_webhook_url_field(:url)
      end

      @doc false
      @spec validate_webhook_url(String.t() | nil, boolean()) :: :ok | {:error, String.t()}
      def validate_webhook_url(value, allow_private), do: validate_webhook_url(value, allow_private, [])

      @spec validate_webhook_url(String.t() | nil, boolean(), keyword()) :: :ok | {:error, String.t()}
      def validate_webhook_url(nil, _allow_private, _opts), do: :ok

      def validate_webhook_url(value, _allow_private, _opts) when not is_binary(value) do
        {:error, "must be a string URL"}
      end

      def validate_webhook_url(value, allow_private, opts) do
        value = String.trim(value)

        cond do
          value == "" ->
            :ok

          Keyword.get(opts, :allow_env_references, true) and env_reference?(value) ->
            :ok

          true ->
            validate_parsed_webhook_url(value, allow_private)
        end
      end

      defp normalize_events(events) when is_list(events) do
        events
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
      end

      defp normalize_headers(headers) when is_map(headers) do
        Enum.reduce(headers, %{}, fn {key, value}, acc ->
          Map.put(acc, to_string(key), value)
        end)
      end

      defp normalize_string(value) when is_binary(value) do
        value
        |> String.trim()
        |> String.downcase()
      end

      defp validate_webhook_url_field(changeset, field) do
        validate_change(changeset, field, fn ^field, value ->
          case validate_webhook_url(value, get_field(changeset, :allow_private) == true) do
            :ok -> []
            {:error, message} -> [{field, message}]
          end
        end)
      end

      defp validate_parsed_webhook_url(value, allow_private) do
        uri = URI.parse(value)
        scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme)

        cond do
          scheme != "https" ->
            {:error, "must use https://"}

          not is_binary(uri.host) or String.trim(uri.host) == "" ->
            {:error, "must include a valid host"}

          not allow_private and blocked_webhook_host?(uri.host) ->
            {:error, "must not target localhost, loopback, private, or link-local hosts unless allow_private is true"}

          true ->
            :ok
        end
      end

      defp env_reference?("$" <> env_name), do: String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
      defp env_reference?(_value), do: false

      defp blocked_webhook_host?(host) do
        host = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")

        host == "localhost" or blocked_ip_literal?(host)
      end

      defp blocked_ip_literal?(host) do
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, address} -> blocked_ip_address?(address)
          {:error, _reason} -> false
        end
      end

      defp blocked_ip_address?({127, _b, _c, _d}), do: true
      defp blocked_ip_address?({10, _b, _c, _d}), do: true
      defp blocked_ip_address?({172, b, _c, _d}) when b in 16..31, do: true
      defp blocked_ip_address?({192, 168, _c, _d}), do: true
      defp blocked_ip_address?({169, 254, _c, _d}), do: true
      defp blocked_ip_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
      defp blocked_ip_address?({0, 0, 0, 0, 0, 65_535, high, low}), do: blocked_ipv4_mapped_ipv6?(high, low)
      defp blocked_ip_address?({first, _b, _c, _d, _e, _f, _g, _h}) when (first &&& 0xFFC0) == 0xFE80, do: true
      defp blocked_ip_address?({first, _b, _c, _d, _e, _f, _g, _h}) when (first &&& 0xFE00) == 0xFC00, do: true
      defp blocked_ip_address?(_address), do: false

      defp blocked_ipv4_mapped_ipv6?(high, low) do
        blocked_ip_address?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
      end

      defp validate_event_names(changeset) do
        validate_change(changeset, :events, fn :events, events ->
          invalid_events = Enum.reject(events || [], &(&1 in @events))

          case invalid_events do
            [] -> []
            _ -> [events: "must include only supported notification events: #{Enum.join(@events, ", ")}"]
          end
        end)
      end
    end

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:redact_titles, :boolean, default: false)
      embeds_many(:channels, Channel, on_replace: :delete)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :redact_titles], empty_values: [])
      |> cast_embed(:channels, with: &Channel.changeset/2)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:poller, Poller, on_replace: :update, defaults_to_struct: true)
    embeds_one(:watchdog, Watchdog, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:github, GitHub, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pr_review, PrReview, on_replace: :update, defaults_to_struct: true)
    embeds_one(:ci, Ci, on_replace: :update, defaults_to_struct: true)
    embeds_one(:verification, Verification, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:quality_gate, QualityGate, on_replace: :update, defaults_to_struct: true)
    embeds_one(:learnings, Learnings, on_replace: :update, defaults_to_struct: true)
    embeds_one(:review_agent, ReviewAgent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:auto_review, AutoReview, on_replace: :update, defaults_to_struct: true)
    embeds_one(:dependencies, Dependencies, on_replace: :update, defaults_to_struct: true)
    embeds_one(:notifications, Notifications, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    normalized = normalize_keys(config)

    with :ok <- reject_removed_keys(normalized),
         {:ok, settings} <- apply_schema_changes(drop_nil_values(normalized)),
         :ok <- validate_finalized_settings(settings) do
      {:ok, settings}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}

      {:error, message} when is_binary(message) ->
        {:error, {:invalid_workflow_config, message}}

      {:error, {:invalid_workflow_config, _message}} = error ->
        error
    end
  end

  defp apply_schema_changes(config) do
    config
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} -> {:ok, finalize_settings(settings)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp reject_removed_keys(config) do
    if Map.has_key?(config, "self_review") do
      {:error, {:invalid_workflow_config, "`self_review` has been removed; use `pre_push_review` in symphony.yml instead"}}
    else
      :ok
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    policy =
      case settings.agent.turn_sandbox_policy do
        %{} = policy ->
          policy

        _ ->
          workspace
          |> default_workspace_root(settings.workspace.root)
          |> expand_local_workspace_root()
          |> default_turn_sandbox_policy()
      end

    apply_codex_network_access(policy, codex_network_access(settings.agent.network_access))
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    policy_result =
      case settings.agent.turn_sandbox_policy do
        %{} = policy ->
          resolve_explicit_runtime_turn_sandbox_policy(policy, workspace, settings.workspace.root, opts)

        _ ->
          workspace
          |> default_workspace_root(settings.workspace.root)
          |> default_runtime_turn_sandbox_policy(opts)
      end

    with {:ok, policy} <- policy_result do
      {:ok,
       policy
       |> ensure_workspace_write_roots(settings, workspace, opts)
       |> apply_codex_network_access(codex_network_access(settings.agent.network_access))}
    end
  end

  @doc false
  @spec codex_built_in_network_allowed_domains() :: [String.t()]
  def codex_built_in_network_allowed_domains do
    @codex_built_in_network_allowed_domains
  end

  @doc false
  @spec claude_built_in_network_allowed_domains() :: [String.t()]
  def claude_built_in_network_allowed_domains do
    @claude_built_in_network_allowed_domains
  end

  @doc false
  @spec codex_effective_network_allowed_domains(%__MODULE__{}) :: [String.t()]
  def codex_effective_network_allowed_domains(%__MODULE__{} = settings) do
    network_access = codex_network_access(settings.agent.network_access)
    denied_domains = network_access.denied_domains |> normalize_domain_list() |> MapSet.new()

    (@codex_built_in_network_allowed_domains ++ normalize_domain_list(network_access.allowed_domains))
    |> normalize_domain_list()
    |> Enum.reject(&MapSet.member?(denied_domains, &1))
  end

  @doc false
  @spec resolve_codex_thread_config(%__MODULE__{}) :: map() | nil
  def resolve_codex_thread_config(%__MODULE__{} = settings) do
    case codex_network_access(settings.agent.network_access).mode do
      "allowlist" ->
        domains =
          settings
          |> codex_effective_network_allowed_domains()
          |> Map.new(&{&1, "allow"})

        %{
          "experimental_network" => %{
            "enabled" => true,
            "domains" => domains,
            "managedAllowedDomainsOnly" => true
          }
        }

      _mode ->
        nil
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:poller, with: &Poller.changeset/2)
    |> cast_embed(:watchdog, with: &Watchdog.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:github, with: &GitHub.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:pr_review, with: &PrReview.changeset/2)
    |> cast_embed(:ci, with: &Ci.changeset/2)
    |> cast_embed(:verification, with: &Verification.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:quality_gate, with: &QualityGate.changeset/2)
    |> cast_embed(:learnings, with: &Learnings.changeset/2)
    |> cast_embed(:review_agent, with: &ReviewAgent.changeset/2)
    |> cast_embed(:auto_review, with: &AutoReview.changeset/2)
    |> cast_embed(:dependencies, with: &Dependencies.changeset/2)
    |> cast_embed(:notifications, with: &Notifications.changeset/2)
    |> validate_profile_command_flags()
  end

  @doc """
  Rejects `--model` / `--effort` in the pre-push reviewer and QA agent commands when a model or
  effort resolves for that run kind, since the resolved values are passed as those flags.

  The QA agent falls back to `agent.command`; that command is only checked here when the QA
  agent's own `model` / `effort` is what makes the flag conflict, because the `agent` section
  already rejects it otherwise.
  """
  @spec validate_profile_command_flags(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_profile_command_flags(changeset) do
    agent = get_field(changeset, :agent)
    review_agent = get_field(changeset, :review_agent)
    auto_review = get_field(changeset, :auto_review)
    agent_settings? = profile_settings?(agent, nil)

    changeset
    |> reject_profile_flags(:review_agent, review_agent.command, &"must not pass #{&1} when a model or effort is set for the pre-push reviewer; remove it from the command", fn ->
      own_profile_settings?(review_agent) or profile_settings?(agent, "pre_push_review")
    end)
    |> reject_qa_profile_flags(auto_review, agent, agent_settings?)
  end

  defp reject_qa_profile_flags(changeset, %{command: command} = auto_review, agent, _agent_settings?) when is_binary(command) do
    reject_profile_flags(changeset, :auto_review, command, &"must not pass #{&1} when a model or effort is set for the QA agent; remove it from the command", fn ->
      own_profile_settings?(auto_review) or profile_settings?(agent, "qa")
    end)
  end

  defp reject_qa_profile_flags(changeset, auto_review, agent, false = _agent_settings?) do
    message = &"is not set, and agent.command passes #{&1} while auto_review.model or auto_review.effort is set; set auto_review.command without #{&1}"
    reject_profile_flags(changeset, :auto_review, agent.command, message, fn -> own_profile_settings?(auto_review) end)
  end

  defp reject_qa_profile_flags(changeset, _auto_review, _agent, true = _agent_settings?), do: changeset

  defp reject_profile_flags(changeset, section, command, message, settings?) do
    case Agent.profile_flags_in(command) do
      [] ->
        changeset

      flags ->
        if settings?.() do
          section_changeset =
            Enum.reduce(flags, Map.get(changeset.changes, section) || change(get_field(changeset, section)), &add_error(&2, :command, message.(&1)))

          %{changeset | changes: Map.put(changeset.changes, section, section_changeset), valid?: false}
        else
          changeset
        end
    end
  end

  defp own_profile_settings?(%{model: model, effort: effort}), do: not is_nil(model) or not is_nil(effort)

  @doc false
  @spec profile_settings?(Agent.t() | RepoAgent.t(), String.t() | nil) :: boolean()
  def profile_settings?(agent, nil), do: own_profile_settings?(agent) or agent.run_profiles not in [nil, %{}]
  def profile_settings?(agent, kind), do: own_profile_settings?(agent) or Map.has_key?(agent.run_profiles || %{}, kind)

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key:
          settings.tracker.api_key
          |> resolve_secret_setting(System.get_env("LINEAR_API_KEY"))
          |> Secret.wrap(),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces")),
        repo: resolve_path_value(settings.workspace.repo, nil)
    }

    agent = %{
      settings.agent
      | approval_policy:
          settings.agent
          |> default_agent_approval_policy()
          |> normalize_keys(),
        turn_sandbox_policy: normalize_optional_map(settings.agent.turn_sandbox_policy),
        network_access: normalize_network_access(settings.agent.network_access)
    }

    notifications = normalize_notifications(settings.notifications)
    webhooks = settings.github.webhooks
    github = %{settings.github | webhooks: %{webhooks | secret: webhooks.secret |> resolve_secret_setting(nil) |> Secret.wrap()}}

    %{settings | tracker: tracker, workspace: workspace, agent: agent, notifications: notifications, github: github}
  end

  defp validate_finalized_settings(settings) do
    with :ok <- validate_agent_approval_policy(settings.agent),
         :ok <- validate_agent_sandbox_runtime(settings.agent),
         :ok <- validate_agent_mcp(settings.agent),
         :ok <- validate_openrouter_workers(settings) do
      validate_finalized_notification_urls(settings.notifications)
    end
  end

  # The OpenRouter key reaches `claude` through the local subprocess env only, so an OpenRouter
  # run cannot start on an SSH worker. The error names the key that picked OpenRouter.
  defp validate_openrouter_workers(%__MODULE__{worker: %Worker{ssh_hosts: [_ | _]}, agent: agent}) do
    case openrouter_provider_keys(agent) do
      [] -> :ok
      [key | _rest] -> {:error, "#{key} openrouter is not supported with workers.ssh_hosts; OpenRouter runs start on the local host only"}
    end
  end

  defp validate_openrouter_workers(_settings), do: :ok

  defp openrouter_provider_keys(%Agent{provider: provider, run_profiles: profiles}) do
    Enum.flat_map(RunKind.names(), fn kind ->
      case Map.get(profiles, kind, %{}) do
        %{"provider" => "openrouter"} -> ["agent.run_profiles.#{kind}.provider"]
        %{"provider" => _provider} -> []
        _profile when provider == "openrouter" -> ["agent.provider"]
        _profile -> []
      end
    end)
  end

  defp validate_agent_approval_policy(%Agent{kind: "codex", approval_policy: "never"}) do
    {:error, ~s(agent.permissions.approval_policy="never" is no longer supported for Codex; use "auto_approve_all" for unattended auto-approval.)}
  end

  defp validate_agent_approval_policy(_agent), do: :ok

  defp validate_agent_sandbox_runtime(%Agent{
         kind: "codex",
         sandbox_runtime: %Agent.SandboxRuntime{kind: "srt"},
         network_access: %Agent.NetworkAccess{mode: "open"}
       }) do
    {:error, "agent.permissions.outer_sandbox.runtime=\"srt\" does not support agent.permissions.network.mode=\"open\""}
  end

  defp validate_agent_sandbox_runtime(%Agent{kind: "codex"}), do: :ok

  defp validate_agent_sandbox_runtime(%Agent{sandbox_runtime: %Agent.SandboxRuntime{kind: kind}})
       when kind in [nil, "none"],
       do: :ok

  defp validate_agent_sandbox_runtime(%Agent{sandbox_runtime: %Agent.SandboxRuntime{kind: kind}}) do
    {:error, "agent.permissions.outer_sandbox.runtime=#{inspect(kind)} is only supported for agent.runtime=codex"}
  end

  defp validate_agent_sandbox_runtime(_agent), do: :ok

  defp validate_agent_mcp(%Agent{kind: "claude", mcp: %Agent.Mcp{inherit: "all"}}) do
    {:error, ~s(agent.mcp.inherit="all" is not supported for agent.runtime=claude; declare MCP servers explicitly.)}
  end

  defp validate_agent_mcp(%Agent{kind: "codex", mcp: %Agent.Mcp{servers: servers}}) when is_map(servers) do
    case Enum.find(servers, fn {_name, server} -> codex_targeted_non_stdio_mcp_server?(server) end) do
      {name, server} ->
        {:error, "agent.mcp.servers.#{name}.transport=#{inspect(server.transport)} is not supported for Codex; Codex MCP servers must use transport=\"stdio\"."}

      nil ->
        :ok
    end
  end

  defp validate_agent_mcp(_agent), do: :ok

  defp codex_targeted_non_stdio_mcp_server?(%Agent.Mcp.Server{transport: transport, runtimes: runtimes})
       when transport in ["http", "sse"] and is_list(runtimes) do
    "codex" in runtimes
  end

  defp codex_targeted_non_stdio_mcp_server?(_server), do: false

  defp normalize_notifications(%Notifications{} = notifications) do
    %{notifications | channels: Enum.map(notifications.channels || [], &normalize_notification_channel/1)}
  end

  defp validate_finalized_notification_urls(%Notifications{channels: channels}) do
    channels
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {channel, index}, :ok ->
      case validate_finalized_notification_channel_url(channel, index, :webhook_url) do
        :ok -> validate_finalized_notification_channel_url(channel, index, :url)
        {:error, _message} = error -> error
      end
      |> case do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp validate_finalized_notification_channel_url(channel, index, field) do
    value = Map.get(channel, field)
    allow_private = Map.get(channel, :allow_private) == true

    case Notifications.Channel.validate_webhook_url(Secret.unwrap(value), allow_private, allow_env_references: false) do
      :ok -> :ok
      {:error, message} -> {:error, "notifications.channels[#{index}].#{field} #{message}"}
    end
  end

  defp normalize_notification_channel(%Notifications.Channel{} = channel) do
    %{
      channel
      | webhook_url: resolve_notification_value(channel.webhook_url),
        url: resolve_notification_value(channel.url),
        headers: resolve_notification_headers(channel.headers),
        events: normalize_notification_events(channel.events)
    }
  end

  defp resolve_notification_value(value) when is_binary(value) do
    value
    |> resolve_env_value(nil)
    |> normalize_notification_string()
    |> Secret.wrap()
  end

  defp resolve_notification_value(_value), do: nil

  defp resolve_notification_headers(headers) when is_map(headers) do
    headers
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case normalize_notification_header_value(value) do
        nil -> acc
        normalized -> Map.put(acc, to_string(key), normalized)
      end
    end)
  end

  defp normalize_notification_header_value(value) when is_binary(value) do
    value
    |> resolve_env_value(nil)
    |> normalize_notification_string()
    |> Secret.wrap()
  end

  defp normalize_notification_header_value(value) when is_integer(value) or is_boolean(value), do: value |> to_string() |> Secret.wrap()
  defp normalize_notification_header_value(_value), do: nil

  defp normalize_notification_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_notification_string(_value), do: nil

  defp normalize_notification_events(events) when is_list(events), do: Enum.map(events, &to_string/1)
  defp normalize_notification_events(_events), do: nil

  defp normalize_network_access(%Agent.NetworkAccess{} = network_access) do
    %{
      network_access
      | allowed_domains: normalize_domain_list(network_access.allowed_domains),
        denied_domains: normalize_domain_list(network_access.denied_domains)
    }
  end

  defp codex_network_access(%Agent.NetworkAccess{} = network_access), do: network_access
  defp codex_network_access(nil), do: %Agent.NetworkAccess{}

  defp default_agent_approval_policy(%Agent{approval_policy: nil, kind: "claude"}), do: "never"

  defp default_agent_approval_policy(%Agent{approval_policy: nil}), do: Agent.codex_default_approval_policy()

  defp default_agent_approval_policy(%Agent{approval_policy: approval_policy}), do: approval_policy

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  @doc false
  @spec normalize_domain_list(term()) :: [String.t()]
  def normalize_domain_list(domains) when is_list(domains) do
    domains
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_domain_list(_domains), do: []

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value), do: drop_nil_values(value, [])

  defp drop_nil_values(value, path) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      child_path = path ++ [key]
      put_non_nil_or_preserved_value(acc, key, child_path, drop_nil_values(nested, child_path))
    end)
  end

  defp drop_nil_values(value, path) when is_list(value), do: Enum.map(value, &drop_nil_values(&1, path))
  defp drop_nil_values(value, _path), do: value

  defp put_non_nil_or_preserved_value(acc, key, path, nil) do
    if preserve_explicit_nil_path?(path), do: Map.put(acc, key, nil), else: acc
  end

  defp put_non_nil_or_preserved_value(acc, key, _path, value), do: Map.put(acc, key, value)

  defp preserve_explicit_nil_path?(["agent", key]) when key in ["max_tokens_per_issue", "max_tokens_per_day"],
    do: true

  defp preserve_explicit_nil_path?(["tracker", "waiting_on_sub_issues_state"]), do: true
  defp preserve_explicit_nil_path?(_path), do: false

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => true,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp apply_codex_network_access(policy, %Agent.NetworkAccess{mode: "allowlist"}) do
    put_known_network_access(policy, true)
  end

  defp apply_codex_network_access(policy, %Agent.NetworkAccess{mode: "open"}) do
    put_known_network_access(policy, true)
  end

  defp apply_codex_network_access(policy, %Agent.NetworkAccess{mode: "block"}) do
    put_known_network_access(policy, false)
  end

  defp put_known_network_access(%{"type" => type} = policy, enabled)
       when type in ["workspaceWrite", "readOnly"] do
    Map.put(policy, "networkAccess", enabled)
  end

  defp put_known_network_access(policy, _enabled), do: policy

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp resolve_explicit_runtime_turn_sandbox_policy(policy, workspace, fallback_workspace, opts) do
    case default_runtime_policy_override?(policy) do
      true ->
        workspace
        |> default_workspace_root(fallback_workspace)
        |> merge_default_runtime_turn_sandbox_policy(policy, opts)

      false ->
        {:ok, policy}
    end
  end

  defp merge_default_runtime_turn_sandbox_policy(workspace_root, policy, opts) do
    with {:ok, default_policy} <- default_runtime_turn_sandbox_policy(workspace_root, opts) do
      {:ok, Map.merge(default_policy, policy)}
    end
  end

  defp default_runtime_policy_override?(policy) when is_map(policy) do
    not Map.has_key?(policy, "writableRoots") and Map.get(policy, "type", "workspaceWrite") == "workspaceWrite"
  end

  defp ensure_workspace_write_roots(%{"type" => "workspaceWrite"} = policy, settings, workspace, opts) do
    prepend_roots = runtime_workspace_write_roots(settings, workspace, opts)

    writable_roots =
      policy
      |> Map.get("writableRoots", [])
      |> normalize_writable_roots(opts)

    Map.put(policy, "writableRoots", Enum.uniq(prepend_roots ++ writable_roots))
  end

  defp ensure_workspace_write_roots(policy, _settings, _workspace, _opts), do: policy

  @doc false
  @spec runtime_workspace_write_roots(t(), Path.t() | nil) :: [Path.t()]
  def runtime_workspace_write_roots(settings, workspace), do: runtime_workspace_write_roots(settings, workspace, [])

  @doc false
  @spec runtime_workspace_write_roots(t(), Path.t() | nil, keyword()) :: [Path.t()]
  def runtime_workspace_write_roots(settings, workspace, opts) when is_binary(workspace) and workspace != "" do
    discovered_git_metadata_roots = discovered_workspace_git_metadata_roots(workspace, opts)

    fallback_git_metadata_roots =
      if discovered_git_metadata_roots == [] do
        configured_worktree_git_metadata_roots(settings, opts)
      else
        []
      end

    ([runtime_writable_root(workspace, opts)] ++
       workspace_git_pointer_roots(workspace, opts) ++
       discovered_git_metadata_roots ++
       fallback_git_metadata_roots)
    |> Enum.reject(&is_nil/1)
  end

  def runtime_workspace_write_roots(_settings, _workspace, _opts), do: []

  # In a linked worktree, workspace/.git is a regular file (a gitdir pointer), not a directory.
  # Including it here ensures the pointer file itself is writable.
  defp workspace_git_pointer_roots(workspace, opts) when is_binary(workspace) and workspace != "" do
    [runtime_writable_root(Path.join(workspace, ".git"), opts)]
  end

  defp discovered_workspace_git_metadata_roots(workspace, opts) do
    if Keyword.get(opts, :remote, false) do
      []
    else
      discover_local_workspace_git_metadata_roots(workspace, opts)
    end
  end

  defp discover_local_workspace_git_metadata_roots(workspace, opts) when is_binary(workspace) do
    with git when is_binary(git) <- System.find_executable("git"),
         true <- File.dir?(workspace) do
      git_metadata_roots(git, workspace, ["rev-parse", "--git-dir", "--git-common-dir"], opts)
    else
      _result -> []
    end
  end

  defp git_metadata_roots(git, workspace, args, opts) do
    case SymphonyElixir.Workspace.safe_git(git, ["-C", workspace | args]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&expand_git_metadata_root(&1, workspace))
        |> Enum.map(&runtime_writable_root(&1, opts))
        |> Enum.reject(&is_nil/1)

      _result ->
        []
    end
  end

  defp expand_git_metadata_root(root, workspace) do
    case Path.type(root) do
      :relative -> Path.expand(root, workspace)
      _type -> root
    end
  end

  defp configured_worktree_git_metadata_roots(
         %__MODULE__{workspace: %Workspace{strategy: "worktree", repo: repo}},
         opts
       )
       when is_binary(repo) and repo != "" do
    [runtime_writable_root(Path.join(repo, ".git"), opts)]
  end

  defp configured_worktree_git_metadata_roots(_settings, _opts), do: []

  defp runtime_writable_root(path, opts) when is_binary(path) do
    if Keyword.get(opts, :remote, false) do
      path
    else
      expanded_path = expand_local_workspace_root(path)

      case PathSafety.canonicalize(expanded_path) do
        {:ok, canonical_path} ->
          canonical_path

        {:error, reason} ->
          Logger.warning("Failed to canonicalize writable root, skipping: path=#{expanded_path} reason=#{inspect(reason)}")
          nil
      end
    end
  end

  defp normalize_writable_roots(roots, opts) when is_list(roots) do
    roots
    |> Enum.map(&normalize_writable_root(&1, opts))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_writable_roots(_roots, _opts), do: []

  defp normalize_writable_root(root, opts) when is_binary(root) do
    cond do
      Keyword.get(opts, :remote, false) -> root
      Path.type(root) == :relative -> root
      true -> runtime_writable_root(root, opts)
    end
  end

  defp normalize_writable_root(root, _opts) do
    Logger.warning("Ignoring non-string writableRoots entry: #{inspect(root)}")
    nil
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.flat_map(errors, fn
      error when is_binary(error) -> [prefix <> " " <> error]
      nested -> flatten_errors(nested, prefix)
    end)
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
