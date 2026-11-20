defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.{AgentProviders, PathSafety, RunKind, Secret}
  alias SymphonyElixir.Config.Runs
  alias SymphonyElixir.Config.Runs.Run
  alias SymphonyElixir.Config.Schema

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
    "sum.golang.org",
    # Images and files attached to Linear issues; the agent fetches them with pre-signed URLs.
    "uploads.linear.app"
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
      field(:code_review_state, :string, default: "Code Review")
      field(:qa_state, :string, default: "QA")
      field(:plan_review_state, :string, default: "Plan Review")
      field(:epic_review_state, :string, default: "Epic Review")
      field(:ci_fix_state, :string, default: "CI Fix")
    end

    # The machine-owned phase states `SymphonyElixir.StateProvisioning` creates at startup. They are
    # inert here: nothing dispatches on, enters or reads them yet.
    @machine_state_fields [:code_review_state, :qa_state, :plan_review_state, :epic_review_state, :ci_fix_state]

    @lifecycle_fields [
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

    @fields @lifecycle_fields ++ @machine_state_fields

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> normalize_optional_string(:project_slug)
      |> normalize_optional_string(:team)
      |> normalize_string_list(:labels)
      |> normalize_optional_string(:waiting_on_sub_issues_state)
      |> put_waiting_on_sub_issues_state_active()
      |> normalize_machine_states()
      |> validate_machine_states_distinct()
    end

    defp normalize_machine_states(changeset) do
      Enum.reduce(@machine_state_fields, changeset, &normalize_optional_string(&2, &1))
    end

    # The phase states are the board's columns: two names for one phase would make provisioning create
    # the same column twice, so a repeated name is rejected before startup can act on it.
    defp validate_machine_states_distinct(changeset) do
      @machine_state_fields
      |> Enum.map(&get_field(changeset, &1))
      |> Enum.filter(&is_binary/1)
      |> Enum.reduce({MapSet.new(), changeset}, fn name, {seen, changeset} ->
        key = String.downcase(name)

        if MapSet.member?(seen, key) do
          {seen, add_error(changeset, :code_review_state, "machine-owned state names must be distinct, but #{name} is used twice")}
        else
          {MapSet.put(seen, key), changeset}
        end
      end)
      |> elem(1)
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

  defmodule Tickets do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    # Linear's priority names, in its own order, and the number each maps to. `none` is Linear's
    # "No priority" (0), which an issue with no priority set reads as too.
    @priorities ~w(none urgent high medium low)
    @priority_numbers %{"none" => 0, "urgent" => 1, "high" => 2, "medium" => 3, "low" => 4}
    @priority_aliases %{
      "no priority" => "none",
      "no_priority" => "none",
      "0" => "none",
      "1" => "urgent",
      "2" => "high",
      "3" => "medium",
      "4" => "low"
    }

    embedded_schema do
      # The Linear priorities allowed to start new work; empty means every priority may.
      field(:priorities, {:array, :string}, default: [])
    end

    @doc "The Linear priority number for a canonical priority name."
    @spec priority_number(String.t()) :: 0..4
    def priority_number(name), do: Map.fetch!(@priority_numbers, name)

    @doc "The canonical priority names Symphony accepts."
    @spec priority_names() :: [String.t()]
    def priority_names, do: @priorities

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:priorities], empty_values: [])
      |> normalize_priorities()
      |> validate_priorities()
    end

    # Names, aliases ("no priority") and Linear's numbers all become the canonical name, so
    # `[1, 2]` and `[urgent, high]` are the same filter. `SystemSchema` stringifies the numbers
    # before this changeset, since Ecto's `{:array, :string}` would reject them.
    defp normalize_priorities(changeset) do
      update_change(changeset, :priorities, fn values when is_list(values) ->
        values |> Enum.map(&canonical_priority/1) |> Enum.uniq()
      end)
    end

    defp canonical_priority(value) do
      key = value |> to_string() |> String.trim() |> String.downcase()
      Map.get(@priority_aliases, key, key)
    end

    defp validate_priorities(changeset) do
      validate_change(changeset, :priorities, fn :priorities, values ->
        case Enum.reject(values, &(&1 in @priorities)) do
          [] -> []
          unknown -> [priorities: "must be Linear priority names or numbers; got: #{Enum.join(unknown, ", ")}"]
        end
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
      # CPU time a process under a workspace or Symphony temp folder may use with no run
      # attached before the dashboard warns about it; `nil` turns the check off.
      field(:stray_process_cpu_minutes, :integer, default: 10)
      # How long one of Symphony's own MCP tool calls must run before the snapshot reports it as pending.
      field(:pending_tool_report_after_ms, :integer, default: 60_000)
      # The dispatch-loop guard (`SymphonyElixir.DispatchLoop`): runs of one kind a ticket may get
      # without progress within each window before it is held instead of dispatched again.
      field(:dispatch_loop_runs, :integer, default: 4)
      field(:dispatch_loop_window_ms, :integer, default: 600_000)
      field(:dispatch_loop_long_runs, :integer, default: 8)
      field(:dispatch_loop_long_window_ms, :integer, default: 3_600_000)
    end

    @fields [
      :enabled,
      :tick_interval_ms,
      :no_progress_threshold_ms,
      :stray_process_cpu_minutes,
      :pending_tool_report_after_ms,
      :dispatch_loop_runs,
      :dispatch_loop_window_ms,
      :dispatch_loop_long_runs,
      :dispatch_loop_long_window_ms
    ]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_number(:tick_interval_ms, greater_than: 0)
      |> validate_number(:no_progress_threshold_ms, greater_than: 0)
      |> validate_number(:stray_process_cpu_minutes, greater_than: 0)
      |> validate_number(:pending_tool_report_after_ms, greater_than: 0)
      # A ticket's record keeps its newest 50 runs (`SymphonyElixir.TicketState`), so a higher limit could never trip.
      |> validate_number(:dispatch_loop_runs, greater_than: 0, less_than_or_equal_to: 50)
      |> validate_number(:dispatch_loop_window_ms, greater_than: 0)
      |> validate_number(:dispatch_loop_long_runs, greater_than: 0, less_than_or_equal_to: 50)
      |> validate_number(:dispatch_loop_long_window_ms, greater_than: 0)
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
      # The wall-clock limit of one git `fetch`, `pull`, `push` or `ls-remote`; unset, it is the
      # `:git_network_timeout_ms` application env, or 5 minutes (see `Config.git_network_timeout_ms/0`).
      field(:git_network_timeout_ms, :integer)
      # `owner/repo` of a repo Symphony clones itself (`repositories[].workspace.source`);
      # `repo` then points at that clone under `clones_root`.
      field(:github, :string)
      field(:clones_root, :string)
      embeds_one(:attachments, Attachments, on_replace: :update, defaults_to_struct: true)
      embeds_one(:sandbox, Sandbox, on_replace: :update, defaults_to_struct: true)
      embeds_one(:lifecycle, Lifecycle, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, ~w(root strategy repo fetch_before_dispatch git_network_timeout_ms github clones_root)a, empty_values: [])
      |> validate_number(:git_network_timeout_ms, greater_than: 0)
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
      # GitHub webhooks delivered through a relay to `POST /api/v1/github/webhook`. They feed the
      # PR and CI watcher the same facts its reads find; polling stays on, every
      # `fallback_poll_interval_ms` while deliveries are healthy, and catches up on anything a relay
      # drops.
      use Ecto.Schema
      import Ecto.Changeset

      @relays ["smee", "cloudflare_tunnel", "gh_webhook_forward", "tailscale_funnel"]
      @events ["check_suite", "check_run", "workflow_run", "pull_request", "push", "release"]
      @fields [:enabled, :relay, :secret, :events, :fallback_poll_interval_ms, :silence_alert_minutes]

      @type t :: %__MODULE__{}

      @derive {Inspect, except: [:secret]}
      @primary_key false
      embedded_schema do
        field(:enabled, :boolean, default: false)
        field(:relay, :string, default: "smee")
        field(:secret, :string)
        field(:events, {:array, :string}, default: @events)
        field(:fallback_poll_interval_ms, :integer, default: 300_000)
        field(:silence_alert_minutes, :integer, default: 10)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, @fields, empty_values: [])
        |> validate_inclusion(:relay, @relays)
        |> validate_subset(:events, @events)
        |> validate_number(:fallback_poll_interval_ms, greater_than: 0)
        |> validate_number(:silence_alert_minutes, greater_than: 0)
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

  defmodule Linear do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    defmodule Webhooks do
      @moduledoc false
      # The workspace webhook Linear signs with `secret` (`SymphonyElixir.Linear.Webhook.verify/3`).
      # Nothing listens for its deliveries yet.
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @derive {Inspect, except: [:secret]}
      @primary_key false
      embedded_schema do
        field(:enabled, :boolean, default: false)
        field(:secret, :string)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:enabled, :secret], empty_values: [])
        |> validate_secret_when_enabled()
      end

      defp validate_secret_when_enabled(changeset) do
        secret = get_field(changeset, :secret)

        if get_field(changeset, :enabled) == true and (not is_binary(secret) or String.trim(secret) == ""),
          do: add_error(changeset, :secret, "is required when linear.webhooks.enabled is true"),
          else: changeset
      end
    end

    @type t :: %__MODULE__{}

    # The repo poll's interval under `dispatch.source: record`, where it only reconciles the record
    # with Linear (`SymphonyElixir.TicketObservation.reconcile_all/3`).
    @min_reconcile_interval_ms 60_000

    @primary_key false
    embedded_schema do
      field(:reconcile_interval_ms, :integer, default: 300_000)
      embeds_one(:webhooks, Webhooks, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:reconcile_interval_ms])
      |> validate_required([:reconcile_interval_ms])
      |> validate_number(:reconcile_interval_ms,
        greater_than_or_equal_to: @min_reconcile_interval_ms,
        message: "must be at least #{@min_reconcile_interval_ms} (one minute)"
      )
      |> cast_embed(:webhooks, with: &Webhooks.changeset/2)
    end
  end

  defmodule PushCheck do
    @moduledoc false
    # Repo-local (WORKFLOW.md). `github_push_branch` pushes with repo hooks disabled, so the agent
    # runs `command` in its own sandbox, which records its result for HEAD in `result_file`.
    # Symphony only reads that file; it never runs the command. Off while `command` is unset.
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @type t :: %__MODULE__{}

    @primary_key false
    embedded_schema do
      field(:command, :string)
      field(:result_file, :string, default: "tmp/push-check")
      field(:paths, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:command, :result_file, :paths], empty_values: [])
      |> Schema.validate_present([:result_file])
      |> validate_change(:result_file, &validate_result_file/2)
      |> validate_change(:paths, fn :paths, paths ->
        if Enum.all?(paths, &(String.trim(&1) != "")), do: [], else: [paths: "must contain only non-empty strings"]
      end)
    end

    defp validate_result_file(:result_file, path) do
      if Path.type(path) == :relative and ".." not in Path.split(path) do
        []
      else
        [result_file: "must be a path inside the workspace, relative and without `..`"]
      end
    end
  end

  defmodule Execution do
    @moduledoc false
    # The `execution:` section: how every run is executed (concurrency, limits, timeouts,
    # prompts, permissions, MCP, usage limits) and each harness's command. What a kind of run
    # starts with (its harness, provider and model) is the `runs:` section's
    # (`SymphonyElixir.Config.Runs`).
    #
    # `harness`, `command` and `run` are nil in the operator's settings. They are set on a
    # run's settings (`SymphonyElixir.Config.for_run/2`), with the defaults that depend on the
    # harness.
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

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

    @doc "The `execution.harnesses` map as `SymphonyElixir.Config.Runs` reads it."
    @spec harnesses(t()) :: SymphonyElixir.Config.Runs.harnesses()
    def harnesses(%{harnesses: harnesses}) do
      Map.new(harnesses || %{}, fn {id, harness} -> {id, %{command: harness["command"], small_model: harness["small_model"] || %{}}} end)
    end

    @doc """
    Where new runs on `provider` stop (`execution.providers.<provider>.reserve`), a share of any of
    its usage windows; nil when it has none.
    """
    @spec reserve(t(), String.t()) :: float() | nil
    def reserve(%{providers: providers}, provider) when is_binary(provider) do
      case Map.get(providers || %{}, provider) do
        %{"reserve" => reserve} when is_number(reserve) -> reserve / 1
        _none -> nil
      end
    end

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
        |> Schema.validate_present([:mode])
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
        |> Schema.validate_present([:kind])
        |> validate_inclusion(:kind, @kinds)
        |> validate_command_when_enabled()
      end

      defp validate_command_when_enabled(changeset) do
        case get_field(changeset, :kind) do
          "srt" -> Schema.validate_present(changeset, [:command])
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
        field(:sign_in_ask_after_seconds, :integer, default: 1800)
      end

      @fields [:auto_pause, :resume_margin_seconds, :unknown_reset_retry_seconds, :sign_in_ask_after_seconds]

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, @fields, empty_values: [])
        |> Schema.validate_present(@fields)
        |> validate_number(:resume_margin_seconds, greater_than_or_equal_to: 0)
        |> validate_number(:unknown_reset_retry_seconds, greater_than_or_equal_to: 60)
        |> validate_number(:sign_in_ask_after_seconds, greater_than_or_equal_to: 60)
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
        @harnesses SymphonyElixir.Harnesses.ids()

        embedded_schema do
          field(:name, :string)
          field(:transport, :string, default: "stdio")
          field(:command, :string)
          field(:args, {:array, :string}, default: [])
          field(:env, :map, default: %{})
          field(:url, :string)
          field(:headers, :map, default: %{})
          field(:harnesses, {:array, :string}, default: @harnesses)
        end

        @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
        def changeset(schema, attrs) do
          schema
          |> cast(attrs, [:name, :transport, :command, :args, :env, :url, :headers, :harnesses], empty_values: [])
          |> Schema.validate_present([:name, :transport])
          |> validate_inclusion(:transport, @transports)
          |> normalize_string_list(:args)
          |> normalize_string_list(:harnesses)
          |> normalize_optional_map(:env)
          |> normalize_optional_map(:headers)
          |> validate_harness_values()
          |> validate_transport_requirements()
          |> validate_transport_harnesses()
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

        defp validate_harness_values(changeset) do
          validate_change(changeset, :harnesses, fn :harnesses, harnesses ->
            invalid = Enum.reject(harnesses, &(&1 in @harnesses))

            case invalid do
              [] -> []
              _invalid -> [runtimes: "contains unsupported runtime"]
            end
          end)
        end

        defp validate_transport_requirements(changeset) do
          case get_field(changeset, :transport) do
            "stdio" -> Schema.validate_present(changeset, [:command])
            transport when transport in ["http", "sse"] -> Schema.validate_present(changeset, [:url])
            _transport -> changeset
          end
        end

        defp validate_transport_harnesses(changeset) do
          transport = get_field(changeset, :transport)
          harnesses = get_field(changeset, :harnesses) || []

          if transport in ["http", "sse"] and "codex" in harnesses do
            add_error(
              changeset,
              :harnesses,
              ~s(transport=#{inspect(transport)} is not supported on the codex harness; its MCP servers must use transport="stdio")
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
        |> Schema.validate_present([:inherit])
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
            add_error(changeset, :allowed_servers, "must not be empty when execution.mcp.inherit is allowlist")

          inherit in ["none", "all"] and allowed_servers != [] ->
            add_error(changeset, :allowed_servers, "must be empty unless execution.mcp.inherit is allowlist")

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
      field(:harness, :string)
      field(:command, :string)
      field(:run, :any, virtual: true)
      # `execution.harnesses`, parsed by `SymphonyElixir.Config.Runs.parse_harnesses/1`.
      field(:harnesses, :map, default: %{})
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
      field(:approval_policy, StringOrMap)
      field(:include_project_guides, :boolean, default: true)
      field(:project_guide_files, {:array, :string})

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      embeds_one(:mcp, Mcp, on_replace: :update, defaults_to_struct: true)
      embeds_one(:network_access, NetworkAccess, on_replace: :update, defaults_to_struct: true)
      embeds_one(:sandbox_runtime, SandboxRuntime, on_replace: :update, defaults_to_struct: true)
      embeds_one(:usage_limit, UsageLimit, on_replace: :update, defaults_to_struct: true)
      # `execution.providers`: each provider's section, by provider, as `SystemSchema` checked it
      # (`%{"anthropic" => %{"reserve" => 0.9}}`); read through `reserve/2`.
      field(:providers, :map, default: %{})
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 30_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      field(:command_timeout_ms, :integer, default: 600_000)
      # How long one call to Symphony's own MCP tools may run; unset, it is the
      # `:mcp_tool_timeout_ms` application env, or 10 minutes (see `Config.mcp_tool_timeout_ms/0`).
      field(:mcp_tool_timeout_ms, :integer)
      field(:codex_stdio_prompt_soft_limit, :integer, default: @default_codex_stdio_prompt_soft_limit)
    end

    @type t :: %__MODULE__{}

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :harnesses,
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
          :approval_policy,
          :include_project_guides,
          :project_guide_files,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms,
          :command_timeout_ms,
          :mcp_tool_timeout_ms,
          :codex_stdio_prompt_soft_limit,
          :providers
        ],
        empty_values: []
      )
      |> Schema.validate_present([:force_label])
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
      |> validate_number(:mcp_tool_timeout_ms, greater_than: 0)
      |> validate_number(:codex_stdio_prompt_soft_limit, greater_than: 0)
      |> validate_project_guide_files()
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
      |> cast_embed(:mcp, with: &Mcp.changeset/2)
      |> cast_embed(:network_access, with: &NetworkAccess.changeset/2)
      |> cast_embed(:sandbox_runtime, with: &SandboxRuntime.changeset/2)
      |> cast_embed(:usage_limit, with: &UsageLimit.changeset/2)
    end

    # Lanes come out of `max_total`, so there can be at most that many; unset means every slot can be a lane.
    defp validate_epic_lanes(changeset) do
      case get_field(changeset, :max_concurrent_agents) do
        max_total when is_integer(max_total) and max_total > 0 ->
          validate_number(changeset, :epic_lanes,
            greater_than_or_equal_to: 0,
            less_than_or_equal_to: max_total,
            message: "must be between 0 and execution.concurrency.max_total (#{max_total})"
          )

        _max_total ->
          validate_number(changeset, :epic_lanes, greater_than_or_equal_to: 0)
      end
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
      |> Schema.validate_present([:mode])
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
        |> Schema.validate_present([:cooldown_minutes, :stale_days])
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
    @default_max_retries 10
    @default_merging_wait_timeout_ms 1_800_000

    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:poll_interval_ms, :integer)
      field(:log_excerpt_lines, :integer, default: @default_log_excerpt_lines)
      field(:flaky_retry, :boolean, default: true)
      field(:max_retries, :integer, default: @default_max_retries)
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
          :merging_wait_timeout_ms
        ],
        empty_values: []
      )
      |> validate_number(:poll_interval_ms, greater_than: 0)
      |> validate_number(:log_excerpt_lines, greater_than: 0)
      |> validate_number(:max_retries, greater_than_or_equal_to: 1)
      |> validate_number(:merging_wait_timeout_ms, greater_than: 0)
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
        field(:range, {:array, :integer}, default: [4100, 4199])
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:range], empty_values: [])
        |> Schema.validate_present([:range])
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
        field(:build_cmd, :string)
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
          [:build_cmd, :start_cmd, :health_check_url, :health_timeout_ms, :stop_signal, :stop_timeout_ms],
          empty_values: []
        )
        |> normalize_optional_string(:build_cmd)
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
        |> Schema.validate_present([:provider, :model],
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
        Schema.validate_present(changeset, [:provider, :model, :max_total_per_repo, :max_per_run], message: "is required when learnings.enabled is true")
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
    @fields [:enabled]

    embedded_schema do
      field(:enabled, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      cast(schema, attrs, @fields, empty_values: [])
    end
  end

  defmodule AutoReview do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.DeprecatedGateSettings
    alias SymphonyElixir.PlaybookSettings

    # Recompile when the deprecated gate block's defaults change (see the note in `SystemSchema`).
    require DeprecatedGateSettings

    @type t :: %__MODULE__{}

    defmodule Android do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false
      @fields [:avd, :sdk_root, :boot_timeout_ms, :idle_timeout_ms]

      # Host settings for the Android emulator; the build command and APK path are per-repository
      # playbook settings.
      embedded_schema do
        field(:avd, :string)
        field(:sdk_root, :string)
        field(:boot_timeout_ms, :integer, default: 180_000)
        field(:idle_timeout_ms, :integer, default: 600_000)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, @fields, empty_values: [], message: fn field, _meta -> cast_message(field) end)
        |> validate_format(:avd, ~r/\A[A-Za-z0-9._-]+\z/, message: "must be an AVD name such as Pixel_3a_API_34")
        |> validate_format(:sdk_root, ~r/\S/, message: "must not be blank")
        |> validate_number(:boot_timeout_ms, greater_than: 0, message: "must be a positive integer")
        |> validate_number(:idle_timeout_ms, greater_than: 0, message: "must be a positive integer")
      end

      defp cast_message(field) when field in [:avd, :sdk_root], do: "must be a string"
      defp cast_message(_field), do: "must be a positive integer"
    end

    @primary_key false
    @fields [
      :enabled,
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
      field(:max_turns, :integer, default: 20)
      field(:timeout_ms, :integer, default: 1_800_000)
      field(:max_concurrent, :integer, default: 1)
      field(:max_fix_attempts, :integer, default: 2)
      field(:run_on, :string, default: "every_push")
      field(:skip_globs, {:array, :string}, default: [])
      field(:playbooks, :map, default: %{})
      field(:worker_host, :string)
      embeds_one(:android, Android, on_replace: :update, defaults_to_struct: true)
      embeds_one(:acceptance_gate, DeprecatedGateSettings, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> cast_embed(:android, with: &Android.changeset/2)
      |> cast_embed(:acceptance_gate, with: &DeprecatedGateSettings.changeset/2)
      |> validate_format(:worker_host, ~r/\A[^\s-]\S*\z/, message: "must be an SSH host such as qa@qa-vm.local or qa-vm:2222")
      |> validate_inclusion(:run_on, ["every_push", "first_pass"])
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:timeout_ms, greater_than: 0)
      |> validate_number(:max_concurrent, greater_than: 0)
      |> validate_number(:max_fix_attempts, greater_than_or_equal_to: 0)
      |> validate_change(:playbooks, &validate_playbooks/2)
    end

    defp validate_playbooks(:playbooks, playbooks) do
      case PlaybookSettings.validate(playbooks) do
        :ok -> []
        {:error, message} -> [playbooks: message]
      end
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

  defmodule HumanActions do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @fields [:enabled, :interval_ms, :min_update_interval_ms]

    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:interval_ms, :integer, default: 300_000)
      field(:min_update_interval_ms, :integer, default: 900_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
      |> validate_number(:min_update_interval_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Ledger do
    @moduledoc """
    `symphony.yml`'s `ledger` section: the largest file `SymphonyElixir.Artifacts.ingest/3` takes
    in (`artifact_max_bytes`), whether agents' prompts carry the summary of the ticket's history
    (`prompt_brief_enabled`, `SymphonyElixir.TicketEvents.Brief`) and the size in tokens over which
    a run asks the Director before its agent starts (`prompt_brief_max_tokens`), a guard and never a
    budget: the summary is always rendered whole.
    """
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @fields [:artifact_max_bytes, :prompt_brief_enabled, :prompt_brief_max_tokens]

    embedded_schema do
      field(:artifact_max_bytes, :integer, default: 26_214_400)
      field(:prompt_brief_enabled, :boolean, default: true)
      field(:prompt_brief_max_tokens, :integer, default: 50_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_number(:artifact_max_bytes, greater_than: 0)
      |> validate_number(:prompt_brief_max_tokens, greater_than: 0)
    end
  end

  defmodule Reports do
    @moduledoc """
    `symphony.yml`'s `reports` section: the model a report run writes with (`model`,
    `SymphonyElixir.Reports`), the cheapest capable model by default; how often a report is written
    on its own (`cadence`: `none`, `hourly`, `six_hours` or `daily`, every six hours by default);
    and which events start one at once (`triggers`, `SymphonyElixir.Reports.Scheduler`). A report
    reads a period's notable events and cites them, which a small model does well.
    """
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @default_model "claude-haiku-5-5"
    @cadences ~w(none hourly six_hours daily)

    defmodule Triggers do
      @moduledoc """
      `reports.triggers`: one switch per event that starts a report at once
      (`SymphonyElixir.Reports.Scheduler.trigger/2`). A ticket shipped and the factory paused by a
      rule are on by default; the others are off.
      """
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false
      @fields [:ticket_shipped, :epic_closed, :ci_fix_loop, :self_heal_filed, :release_installed, :paused_by_rule]

      embedded_schema do
        field(:ticket_shipped, :boolean, default: true)
        field(:epic_closed, :boolean, default: false)
        field(:ci_fix_loop, :boolean, default: false)
        field(:self_heal_filed, :boolean, default: false)
        field(:release_installed, :boolean, default: false)
        field(:paused_by_rule, :boolean, default: true)
      end

      @doc "Every trigger, in the order Settings lists them."
      @spec names() :: [atom()]
      def names, do: @fields

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        cast(schema, attrs, @fields, empty_values: [])
      end
    end

    embedded_schema do
      field(:model, :string, default: @default_model)
      field(:cadence, :string, default: "six_hours")
      embeds_one(:triggers, Triggers, on_replace: :update, defaults_to_struct: true)
    end

    @doc "The model a report run uses when `reports.model` is missing or null."
    @spec default_model() :: String.t()
    def default_model, do: @default_model

    @doc "The cadences `reports.cadence` takes."
    @spec cadences() :: [String.t()]
    def cadences, do: @cadences

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:model, :cadence], empty_values: [])
      |> Schema.validate_present([:model], message: "must name a model")
      |> validate_change(:model, fn :model, model ->
        if String.trim(model) == "", do: [model: "must name a model"], else: []
      end)
      |> Schema.validate_present([:cadence], message: "must be one of #{Enum.join(@cadences, ", ")}")
      |> validate_inclusion(:cadence, @cadences, message: "must be one of #{Enum.join(@cadences, ", ")}")
      |> cast_embed(:triggers, with: &Triggers.changeset/2)
    end
  end

  defmodule Conductor do
    @moduledoc """
    `symphony.yml`'s `conductor` section (`SymphonyElixir.Conductor`): whether Symphony runs the
    Conductor's short turn at a ticket's junctions (`enabled`, off by default), at which junctions
    (`junctions`: `after_coding`, `after_qa_fail`, `after_rework`, `before_merge`; all four by
    default) and how long one turn may take before the next run starts without it (`timeout_ms`,
    three minutes by default), and whether it watches running runs to steer them (`watch`,
    `SymphonyElixir.Conductor.Watch`, off by default). Its model is `runs.conductor`'s.
    """
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @junctions ~w(after_coding after_qa_fail after_rework before_merge)

    defmodule Watch do
      @moduledoc """
      `conductor.watch`: whether the Conductor looks at running runs and may steer them (`enabled`,
      off by default); when a run is looked at past its start besides a failed step or a QA step
      that answered `plan_mismatch` or `blocked` (`run_minutes`, 30; `run_tokens`, 30,000,000); how
      often at most (`min_interval_minutes`, 10, and `max_turns_per_run`, 3); and whether it may
      stop a run, always with a question to the person (`allow_stop`, off by default).
      """
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false
      @fields [:enabled, :run_minutes, :run_tokens, :min_interval_minutes, :max_turns_per_run, :allow_stop]

      embedded_schema do
        field(:enabled, :boolean, default: false)
        field(:run_minutes, :integer, default: 30)
        field(:run_tokens, :integer, default: 30_000_000)
        field(:min_interval_minutes, :integer, default: 10)
        field(:max_turns_per_run, :integer, default: 3)
        field(:allow_stop, :boolean, default: false)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, @fields, empty_values: [])
        |> Schema.validate_present(@fields)
        |> validate_number(:run_minutes, greater_than: 0)
        |> validate_number(:run_tokens, greater_than: 0)
        |> validate_number(:min_interval_minutes, greater_than_or_equal_to: 0)
        |> validate_number(:max_turns_per_run, greater_than: 0)
      end
    end

    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:junctions, {:array, :string}, default: @junctions)
      field(:timeout_ms, :integer, default: 180_000)
      embeds_one(:watch, Watch, on_replace: :update, defaults_to_struct: true)
    end

    @doc "Every junction the Conductor may run at, in the order a ticket meets them."
    @spec junctions() :: [String.t()]
    def junctions, do: @junctions

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :junctions, :timeout_ms], empty_values: [])
      |> Schema.validate_present([:enabled, :junctions, :timeout_ms])
      |> validate_subset(:junctions, @junctions, message: "must name only #{Enum.join(@junctions, ", ")}")
      |> validate_number(:timeout_ms, greater_than: 0)
      |> cast_embed(:watch, with: &Watch.changeset/2)
    end
  end

  defmodule Dispatch do
    @moduledoc """
    `symphony.yml`'s `dispatch` section: where the dispatcher reads its candidates from (`source`:
    `poll`, the poll cache, or `record`, the ticket records) and how many poll cycles the shadow
    report's window covers (`shadow_window`, `SymphonyElixir.Dispatch.Shadow`). `record` is accepted
    and changes nothing yet: dispatch reads the poll cache.
    """
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @sources ~w(poll record)

    embedded_schema do
      field(:source, :string, default: "poll")
      field(:shadow_window, :integer, default: 20)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:source, :shadow_window], empty_values: [])
      |> validate_inclusion(:source, @sources, message: "must be one of: #{Enum.join(@sources, ", ")}")
      |> validate_number(:shadow_window, greater_than: 0)
    end
  end

  defmodule Phases do
    @moduledoc """
    `symphony.yml`'s `phases` section: for a run kind (`phases.<kind>`, a `SymphonyElixir.RunKind`
    name), the list of steps a run of that kind follows (`steps`). A step runs as a `machine` step (a
    shell `command` Symphony runs), an `orchestrated` step (an agent turn Symphony starts from a
    `prompt`) or a `delegated` step (work the agent does in its session and reports itself); the
    step model is `SymphonyElixir.TicketEvents.Types`'s.

    A kind the file doesn't set follows its default list (`default_steps/1`): the five steps of
    decision 2 for `implementation` (`code`, `build`, `checks`, `tests`, `handoff`), the same with
    `findings` before them for `rework`, none for every other kind. A step list is refused at load, naming the step, when a step's `on_fail` names a step
    not in the list, when failures can loop with no delegated step in the loop (the same commands
    would run again with nothing changed), and when a machine step has no command.
    """
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.QaAgent.StepPrompts
    alias SymphonyElixir.RunKind

    @type t :: %__MODULE__{}

    @primary_key false

    @kinds RunKind.phase_kinds()
    @kind_names Map.new(@kinds, &{Atom.to_string(&1), &1})
    @findings_command "symphony:findings"
    @qa_commands ~w(symphony:qa_pre_checks symphony:qa_build symphony:qa_launch symphony:qa_quit symphony:qa_attach)

    defmodule Step do
      @moduledoc """
      One step of a run's list: its `id` (what `on_fail` names), `title`, `mode`, the `command` of a
      machine step or the `prompt` of an orchestrated one, how long it may run (`timeout_ms`), the
      step a failure returns to (`on_fail`; none ends the run), how many times in a row it may end
      with no result before the run pauses on a Question (`no_result_limit`, decision 3), for a
      machine step when it runs at all (`when`), and for an orchestrated step the answer its agent
      gives (`answer`: each field the answer must hold and its type, `string`, `number`, `boolean`,
      `list` or `object`), which Symphony checks before the step passes.

      A machine step's `command` is a shell command, or a list of `{run, when}` entries run in
      order, each only when its condition holds: `build` runs `make build` (`swift build`)
      when `macos/` changed and `mix compile` when Elixir files did.

      An agent step (orchestrated or delegated) may also set what its turn runs with and where:
      `model` (a model id of the run's provider, or `small` for the run's small model) and `effort`
      (one of `SymphonyElixir.Config.Runs.efforts/0`), `session` (steps with the same name continue
      one agent session; `fresh` starts one for that step alone; none is the run's one session) and
      `repeat: walkthrough` (the step runs once per walkthrough step a QA pass walks). None of them
      means anything on a machine step, so setting one there is refused. The QA pass's step walk
      (`SymphonyElixir.QaAgent.Steps`) honours them.
      """
      use Ecto.Schema
      import Ecto.Changeset

      alias SymphonyElixir.Config.Runs

      @type t :: %__MODULE__{}

      @primary_key false
      @modes ~w(machine orchestrated delegated)
      @conditions ~w(always macos_changed elixir_changed)
      @keys ~w(id title mode command prompt answer timeout_ms on_fail no_result_limit when model effort session repeat)
      @agent_keys ~w(model effort session repeat)
      @cast ~w(id title mode prompt answer timeout_ms on_fail no_result_limit when model effort session repeat)a
      @repeats ~w(walkthrough)
      @fresh_session "fresh"
      @answer_types ~w(string number boolean list object)
      @id_format ~r/^[a-z][a-z0-9_]*$/
      # A machine step that sets no timeout gets ten minutes; an agent turn has the agent's own.
      @machine_timeout_ms 600_000

      defmodule Command do
        @moduledoc "One command of a machine step: the shell line it runs (`run`) and when (`when`)."
        use Ecto.Schema
        import Ecto.Changeset

        @type t :: %__MODULE__{}

        @primary_key false
        @keys ~w(run when)

        embedded_schema do
          field(:run, :string)
          field(:when, :string, default: "always")
        end

        @spec changeset(%__MODULE__{}, map(), String.t(), [String.t()]) :: Ecto.Changeset.t()
        def changeset(schema, attrs, step, conditions) do
          schema
          |> cast(attrs, [:run, :when])
          |> Step.reject_unknown_keys(attrs, @keys, step)
          |> validate_required([:run], message: "of step `#{step}` has an entry with no command")
          |> validate_inclusion(:when, conditions, message: "of step `#{step}` must be one of: #{Enum.join(conditions, ", ")}")
        end
      end

      embedded_schema do
        field(:id, :string)
        field(:title, :string)
        field(:mode, :string)
        embeds_many(:command, Command, on_replace: :delete)
        field(:prompt, :string)
        field(:answer, {:map, :string}, default: %{})
        field(:timeout_ms, :integer)
        field(:on_fail, :string)
        field(:no_result_limit, :integer, default: 2)
        field(:when, :string, default: "always")
        field(:model, :string)
        field(:effort, :string)
        field(:session, :string)
        field(:repeat, :string)
      end

      @doc "The modes a step runs in."
      @spec modes() :: [String.t()]
      def modes, do: @modes

      @doc "The conditions a machine step, or one of its commands, runs under (`when`)."
      @spec conditions() :: [String.t()]
      def conditions, do: @conditions

      @doc "The types a field of an orchestrated step's `answer` takes."
      @spec answer_types() :: [String.t()]
      def answer_types, do: @answer_types

      @doc "What an agent step's `repeat` takes."
      @spec repeats() :: [String.t()]
      def repeats, do: @repeats

      @doc "The `session` that starts a new agent session for its step alone."
      @spec fresh_session() :: String.t()
      def fresh_session, do: @fresh_session

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        attrs = command_entries(attrs)
        step = step_name(attrs)

        schema
        |> cast(attrs, @cast)
        |> reject_unknown_keys(attrs, @keys, step)
        |> validate_required([:id], message: "is required for every step")
        |> validate_format(:id, @id_format, message: "`#{step}` must be lowercase letters, digits and underscores, starting with a letter")
        |> validate_required([:mode], message: "is required for step `#{step}`")
        |> validate_inclusion(:mode, @modes, message: "of step `#{step}` must be one of: #{Enum.join(@modes, ", ")}")
        |> validate_inclusion(:when, @conditions, message: "of step `#{step}` must be one of: #{Enum.join(@conditions, ", ")}")
        |> validate_number(:timeout_ms, greater_than: 0, message: "of step `#{step}` must be greater than 0")
        |> validate_number(:no_result_limit, greater_than: 0, message: "of step `#{step}` must be greater than 0")
        |> cast_embed(:command, with: &Command.changeset(&1, &2, step, @conditions))
        |> validate_mode_fields(attrs, step)
        |> validate_agent_fields(attrs, step)
        |> validate_answer(step)
        |> default_title()
        |> default_machine_timeout()
      end

      # A command written as one shell line is a list of one entry that always runs.
      defp command_entries(%{"command" => command} = attrs) when is_binary(command),
        do: Map.put(attrs, "command", [%{"run" => command}])

      defp command_entries(attrs), do: attrs

      defp step_name(%{"id" => id}) when is_binary(id) and id != "", do: id
      defp step_name(_attrs), do: "(no id)"

      @doc false
      @spec reject_unknown_keys(Ecto.Changeset.t(), map(), [String.t()], String.t()) :: Ecto.Changeset.t()
      def reject_unknown_keys(changeset, attrs, keys, step) do
        case Enum.sort(Map.keys(attrs) -- keys) do
          [] -> changeset
          [key | _rest] -> add_error(changeset, :id, "step `#{step}` has an unknown key `#{key}`")
        end
      end

      # A machine step runs a command, an orchestrated one a prompt; neither field, nor `when`, means
      # anything on a step of another mode, so setting it there is refused rather than ignored.
      defp validate_mode_fields(changeset, attrs, step) do
        mode = get_field(changeset, :mode)

        changeset
        |> require_for_mode(mode, "machine", :command, get_field(changeset, :command) != [], step)
        |> require_for_mode(mode, "orchestrated", :prompt, present?(get_field(changeset, :prompt)), step)
        |> refuse_off_mode(mode, "machine", :when, Map.has_key?(attrs, "when"), step)
        |> refuse_off_mode(mode, "orchestrated", :answer, Map.has_key?(attrs, "answer"), step)
      end

      # `model`, `effort`, `session` and `repeat` say how an agent turn runs; a machine step has none.
      defp validate_agent_fields(changeset, attrs, step) do
        changeset =
          if get_field(changeset, :mode) == "machine",
            do: Enum.reduce(@agent_keys, changeset, &refuse_on_machine(&2, &1, Map.has_key?(attrs, &1), step)),
            else: changeset

        changeset
        |> validate_inclusion(:effort, Runs.efforts(), message: "of step `#{step}` must be one of: #{Enum.join(Runs.efforts(), ", ")}")
        |> validate_change(:session, fn :session, session ->
          if session == @fresh_session or session =~ @id_format,
            do: [],
            else: [session: "of step `#{step}` must be `#{@fresh_session}` or a name of lowercase letters, digits and underscores, starting with a letter"]
        end)
        |> validate_inclusion(:repeat, @repeats, message: "of step `#{step}` must be one of: #{Enum.join(@repeats, ", ")}")
      end

      defp refuse_on_machine(changeset, key, true, step),
        do: add_error(changeset, String.to_existing_atom(key), "is only for an agent step; step `#{step}` is machine")

      defp refuse_on_machine(changeset, _key, false, _step), do: changeset

      defp validate_answer(changeset, step) do
        validate_change(changeset, :answer, fn :answer, answer ->
          for {name, _type} <- answer |> Enum.sort() |> Enum.reject(&answer_field?/1) |> Enum.take(1),
              do: {:answer, "field `#{name}` of step `#{step}` must be a lowercase name with a type: #{Enum.join(@answer_types, ", ")}"}
        end)
      end

      defp answer_field?({name, type}), do: name =~ @id_format and type in @answer_types

      defp require_for_mode(changeset, mode, mode, field, false, step),
        do: add_error(changeset, field, "is required for #{mode} step `#{step}`")

      defp require_for_mode(changeset, mode, owner, field, true, step) when mode != owner and mode in @modes,
        do: refuse_off_mode(changeset, mode, owner, field, true, step)

      defp require_for_mode(changeset, _mode, _owner, _field, _set?, _step), do: changeset

      defp refuse_off_mode(changeset, mode, owner, field, true, step) when mode != owner and mode in @modes,
        do: add_error(changeset, field, "is only for #{if owner == "machine", do: "a", else: "an"} #{owner} step; step `#{step}` is #{mode}")

      defp refuse_off_mode(changeset, _mode, _owner, _field, _set?, _step), do: changeset

      defp present?(value), do: is_binary(value) and String.trim(value) != ""

      defp default_title(changeset) do
        if present?(get_field(changeset, :title)),
          do: changeset,
          else: put_change(changeset, :title, get_field(changeset, :id))
      end

      defp default_machine_timeout(changeset) do
        if get_field(changeset, :mode) == "machine" and is_nil(get_field(changeset, :timeout_ms)),
          do: put_change(changeset, :timeout_ms, @machine_timeout_ms),
          else: changeset
      end
    end

    defmodule Phase do
      @moduledoc "One run kind's entry under `phases`: its step list (`steps`), checked as a whole."
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key false

      embedded_schema do
        embeds_many(:steps, Step, on_replace: :delete)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs), do: changeset(schema, attrs, :run_kind)

      @doc """
      Checks a step list: a run kind's (`:run_kind`), which may not run the QA pass's own commands
      (`Phases.qa_commands/0`), or a QA playbook's (`:qa_playbook`), which may.
      """
      @spec changeset(%__MODULE__{}, map(), :run_kind | :qa_playbook) :: Ecto.Changeset.t()
      def changeset(schema, attrs, owner) do
        changeset = schema |> cast(attrs, []) |> cast_embed(:steps, with: &Step.changeset/2)

        if changeset.valid?,
          do: validate_list(changeset, get_field(changeset, :steps), owner),
          else: changeset
      end

      @doc false
      @spec validate_list(Ecto.Changeset.t(), [Step.t()], :run_kind | :qa_playbook) :: Ecto.Changeset.t()
      def validate_list(changeset, steps, owner) do
        ids = Enum.map(steps, & &1.id)

        with nil <- duplicate_id(ids),
             nil <- unknown_on_fail(steps, ids),
             nil <- loop_without_delegated(steps, ids),
             nil <- qa_command_outside(steps, owner) do
          changeset
        else
          message -> add_error(changeset, :steps, message)
        end
      end

      # The QA pass's own commands drive the QA host the pass holds; no other run has one. A QA
      # playbook's list, for its part, ends in the verdict, which its `review` step gives.
      defp qa_command_outside(steps, :qa_playbook) do
        if Enum.any?(steps, &(&1.id == "review" and &1.mode == "orchestrated")),
          do: nil,
          else: "has no orchestrated step `review`, which gives a QA pass's verdict"
      end

      defp qa_command_outside(steps, :run_kind) do
        Enum.find_value(steps, fn %Step{id: id, command: commands} ->
          case Enum.find(commands, &(&1.run in Phases.qa_commands())) do
            nil -> nil
            %{run: run} -> "step `#{id}` runs `#{run}`, which only a QA playbook's list (`phases.qa.playbooks.<kind>.steps`) runs"
          end
        end)
      end

      defp duplicate_id(ids) do
        case ids -- Enum.uniq(ids) do
          [] -> nil
          [id | _rest] -> "has two steps with the id `#{id}`"
        end
      end

      defp unknown_on_fail(steps, ids) do
        Enum.find_value(steps, fn %Step{id: id, on_fail: on_fail} ->
          if is_binary(on_fail) and on_fail not in ids,
            do: "has no step `#{on_fail}`, which step `#{id}` returns to on failure"
        end)
      end

      # A loop is a step that, passing on to the next step or returning to `on_fail`, can come back
      # to itself. One with a delegated step in it lets the agent change something before the
      # commands run again; one without would run the same commands again on the same code. So the
      # check looks for a loop through the steps that are not delegated alone.
      defp loop_without_delegated(steps, ids) do
        undelegated = for %Step{mode: mode, id: id} <- steps, mode != "delegated", into: MapSet.new(), do: id

        edges =
          steps
          |> Enum.with_index(1)
          |> Map.new(fn {%Step{id: id, on_fail: on_fail}, next} ->
            {id, Enum.filter([Enum.at(ids, next), on_fail], &MapSet.member?(undelegated, &1))}
          end)

        Enum.find_value(steps, fn %Step{id: id} ->
          with true <- MapSet.member?(undelegated, id),
               [_ | _] = loop <- walk(edges, id, [id], MapSet.new([id])) do
            "loop #{Enum.map_join(loop, " → ", &"`#{&1}`")} has no delegated step, " <>
              "so a failure would run the same commands again on the same code"
          else
            _no_loop -> nil
          end
        end)
      end

      defp walk(edges, start, [node | _rest] = path, seen) do
        Enum.find_value(Map.fetch!(edges, node), fn
          ^start ->
            Enum.reverse([start | path])

          next ->
            if not MapSet.member?(seen, next), do: walk(edges, start, [next | path], MapSet.put(seen, next))
        end)
      end
    end

    defmodule QaPhase do
      @moduledoc """
      `phases.qa`: the kind's own `steps` (as every kind has), whether a QA pass walks a step list
      (`stepped`, default false) and the list each QA playbook's pass walks
      (`playbooks.<playbook kind>.steps`, checked as a run kind's list is, and refused naming the
      key). A playbook's orchestrated step with no `prompt` takes Symphony's own for its id
      (`SymphonyElixir.QaAgent.StepPrompts`), when there is one.
      """
      use Ecto.Schema
      import Ecto.Changeset

      alias SymphonyElixir.QaAgent.StepPrompts

      @type t :: %__MODULE__{}

      @primary_key false
      @kind_format ~r/^[a-z][a-z0-9_]*$/

      embedded_schema do
        embeds_many(:steps, Step, on_replace: :delete)
        field(:stepped, :boolean, default: false)
        field(:playbooks, :map, default: %{})
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        changeset = schema |> cast(attrs, [:stepped]) |> cast_embed(:steps, with: &Step.changeset/2)
        changeset = if changeset.valid?, do: Phase.validate_list(changeset, get_field(changeset, :steps), :run_kind), else: changeset
        cast_playbooks(changeset, Map.get(attrs, "playbooks") || Map.get(attrs, :playbooks) || %{})
      end

      defp cast_playbooks(changeset, playbooks) when is_map(playbooks) do
        playbooks
        |> Enum.sort()
        |> Enum.reduce(changeset |> put_change(:playbooks, %{}), fn {kind, entry}, changeset -> cast_playbook(changeset, to_string(kind), entry) end)
      end

      defp cast_playbooks(changeset, _playbooks), do: add_error(changeset, :playbooks, "must be an object of playbook kinds")

      defp cast_playbook(changeset, kind, entry) do
        path = "phases.qa.playbooks.#{kind}"

        cond do
          not (kind =~ @kind_format) ->
            add_error(changeset, :playbooks, "#{path} must be named in lowercase letters, digits and underscores, starting with a letter")

          not is_map(entry) or not is_list(Map.get(entry, "steps")) ->
            add_error(changeset, :playbooks, "#{path}.steps must be a list of steps, each an object")

          true ->
            entry = Map.update!(entry, "steps", fn steps -> Enum.map(steps, &own_prompt(&1, kind)) end)
            playbook = Phase.changeset(%Phase{}, entry, :qa_playbook)

            if playbook.valid?,
              do: put_change(changeset, :playbooks, Map.put(get_field(changeset, :playbooks), kind, get_field(playbook, :steps))),
              else: Enum.reduce(errors(playbook, path), changeset, &add_error(&2, :playbooks, &1))
        end
      end

      # An orchestrated step that names no prompt takes Symphony's own for its id, when there is one.
      defp own_prompt(%{"mode" => "orchestrated", "id" => id} = step, kind) when is_binary(id) do
        case {Map.get(step, "prompt"), StepPrompts.prompt(kind, id)} do
          {nil, text} when is_binary(text) -> Map.put(step, "prompt", text)
          _given -> step
        end
      end

      defp own_prompt(step, _kind), do: step

      # The errors of a playbook's list, each naming its key below `path`, as the load error says them.
      defp errors(changeset, path) do
        changeset
        |> traverse_errors(fn {message, opts} -> Enum.reduce(opts, message, &String.replace(&2, "%{#{elem(&1, 0)}}", inspect(elem(&1, 1)))) end)
        |> flatten(path)
      end

      defp flatten(errors, path) when is_map(errors), do: Enum.flat_map(errors, fn {key, value} -> flatten(value, "#{path}.#{key}") end)
      defp flatten(errors, path) when is_list(errors), do: Enum.flat_map(errors, &flatten_entry(&1, path))

      defp flatten_entry(message, path) when is_binary(message), do: ["#{path} #{message}"]
      defp flatten_entry(nested, path), do: flatten(nested, path)
    end

    embedded_schema do
      for kind <- @kinds do
        if kind == :qa,
          do: embeds_one(kind, QaPhase, on_replace: :update),
          else: embeds_one(kind, Phase, on_replace: :update)
      end
    end

    @doc "The run kinds `phases` takes a step list for, as `symphony.yml` names them."
    @spec kinds() :: [String.t()]
    def kinds, do: Enum.map(@kinds, &Atom.to_string/1)

    @doc "The run kind a `phases` key names, or nil for a name that is not one."
    @spec kind(String.t() | atom()) :: RunKind.t() | nil
    def kind(kind) when kind in @kinds, do: kind
    def kind(name) when is_binary(name), do: Map.get(@kind_names, name)
    def kind(_other), do: nil

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      Enum.reduce(@kinds, cast(schema, attrs, []), fn
        :qa, changeset -> cast_embed(changeset, :qa, with: &QaPhase.changeset/2)
        kind, changeset -> cast_embed(changeset, kind, with: &Phase.changeset/2)
      end)
    end

    @doc """
    The machine step command Symphony runs itself rather than in a shell: it reads the open findings
    by class from the ticket's ledger (`SymphonyElixir.PhaseSteps.Findings`).
    """
    @spec findings_command() :: String.t()
    def findings_command, do: @findings_command

    @doc """
    The machine step commands the QA pass runs itself, with the QA host it holds
    (`SymphonyElixir.QaAgent.Steps`): the pre-checks' results, the build, the launch with a health
    check, quitting every app the pass launched, and the evidence the steps recorded. Only a QA
    playbook's list (`phases.qa.playbooks.<kind>.steps`) runs them.
    """
    @spec qa_commands() :: [String.t()]
    def qa_commands, do: @qa_commands

    @doc "Whether a QA pass walks a step list (`phases.qa.stepped`); off, every pass is one agent session."
    @spec qa_stepped?(t()) :: boolean()
    def qa_stepped?(%__MODULE__{qa: %QaPhase{stepped: stepped}}), do: stepped == true
    def qa_stepped?(%__MODULE__{}), do: false

    @doc """
    The steps a QA pass of playbook `kind` walks: `phases.qa.playbooks.<kind>.steps`, else the
    playbook's default list (`default_qa_steps/1`; only `macos_app` has one), else none.
    """
    @spec qa_steps(t(), String.t()) :: [Step.t()]
    def qa_steps(%__MODULE__{qa: %QaPhase{playbooks: %{} = playbooks}}, kind) when is_map_key(playbooks, kind), do: Map.fetch!(playbooks, kind)
    def qa_steps(%__MODULE__{}, kind) when is_binary(kind), do: default_qa_steps(kind)

    @doc """
    The steps a run of `kind` follows: the file's `phases.<kind>.steps`, else the kind's default
    list (`default_steps/1`).
    """
    @spec steps(t(), RunKind.t()) :: [Step.t()]
    def steps(%__MODULE__{} = phases, kind) when kind in @kinds do
      case Map.fetch!(phases, kind) do
        %Phase{steps: steps} -> steps
        %QaPhase{steps: steps} -> steps
        nil -> default_steps(kind)
      end
    end

    @doc """
    A kind's default step list, for a `symphony.yml` that doesn't set `phases.<kind>` (decision 2 of
    TP-1085): `implementation` writes the code (delegated), builds it (`make build` when
    `macos/` changed; `mix compile --warnings-as-errors` when Elixir files did), checks it (format, specs and
    credo on the changed files), tests it (the changed test files and `mix cover.changed`, plus
    `swift test` for the changed targets when `macos/` changed), each returning to `code` on
    failure, then hands off (delegated). `rework` reads the open findings first (`findings`, machine),
    which pauses on a Question when a failure came back, then follows the same steps. Every other
    kind has none: its run is one agent session.

    The changed files come from the environment the step runner gives a machine step:
    `SYMPHONY_CHANGED_ELIXIR_FILES`, `SYMPHONY_CHANGED_TEST_FILES` and
    `SYMPHONY_CHANGED_SWIFT_TEST_FILTER`.
    """
    @spec default_steps(RunKind.t()) :: [Step.t()]
    def default_steps(:implementation), do: default_list(default_implementation_steps())
    def default_steps(:rework), do: default_list([default_findings_step() | default_implementation_steps()])
    def default_steps(kind) when kind in @kinds, do: []

    defp default_list(steps, owner \\ :run_kind) do
      %Phase{}
      |> Phase.changeset(%{"steps" => steps}, owner)
      |> apply_action!(:validate)
      |> Map.fetch!(:steps)
    end

    @doc """
    A QA playbook's default step list, for a stepped pass (`phases.qa.stepped`) whose
    `symphony.yml` doesn't set `phases.qa.playbooks.<kind>`. Only `macos_app` has one: the
    pre-checks, the build (before the plan, since the gallery's listing reads the built app), a plan
    in the lead session on the run's model, the launch, one fresh turn on the small model for each
    walkthrough step QA walks, the design check and the wide pass, quitting the app and keeping the
    evidence, and the review in the lead session, which gives the verdict. Its orchestrated steps'
    prompts are `priv/qa_steps/macos_app/<id>.md` (`SymphonyElixir.QaAgent.StepPrompts`). Every
    other playbook has none: its pass is one agent session.
    """
    @spec default_qa_steps(String.t()) :: [Step.t()]
    def default_qa_steps("macos_app"), do: default_list(default_macos_app_qa_steps(), :qa_playbook)
    def default_qa_steps(kind) when is_binary(kind), do: []

    defp default_macos_app_qa_steps do
      judged = %{"status" => "string", "expected" => "string", "actual" => "string", "details" => "string", "evidence" => "list"}
      prompt = &StepPrompts.prompt("macos_app", &1)

      [
        %{"id" => "pre_checks", "title" => "Pre-checks", "mode" => "machine", "command" => "symphony:qa_pre_checks", "timeout_ms" => 60_000},
        %{"id" => "build", "title" => "Build the app", "mode" => "machine", "command" => "symphony:qa_build", "timeout_ms" => 1_800_000, "on_fail" => "quit"},
        %{
          "id" => "plan",
          "title" => "Plan the pass",
          "mode" => "orchestrated",
          "session" => "lead",
          "effort" => "high",
          "prompt" => prompt.("plan"),
          "answer" => %{"needs_app" => "boolean", "walk" => "list", "gallery" => "list", "notes" => "string"}
        },
        %{"id" => "launch", "title" => "Launch the app", "mode" => "machine", "command" => "symphony:qa_launch", "timeout_ms" => 300_000, "on_fail" => "quit"},
        %{
          "id" => "walk",
          "title" => "Walk a step",
          "mode" => "orchestrated",
          "repeat" => "walkthrough",
          "session" => "fresh",
          "model" => "small",
          "prompt" => prompt.("walk"),
          "answer" => judged
        },
        %{"id" => "design_check", "title" => "Design check", "mode" => "orchestrated", "session" => "fresh", "model" => "small", "prompt" => prompt.("design_check"), "answer" => judged},
        %{"id" => "wide_pass", "title" => "Wide pass", "mode" => "orchestrated", "session" => "fresh", "model" => "small", "prompt" => prompt.("wide_pass"), "answer" => judged},
        %{"id" => "quit", "title" => "Quit the app", "mode" => "machine", "command" => "symphony:qa_quit", "timeout_ms" => 60_000},
        %{"id" => "attach", "title" => "Attach the evidence", "mode" => "machine", "command" => "symphony:qa_attach", "timeout_ms" => 60_000},
        %{"id" => "review", "title" => "Review and verdict", "mode" => "orchestrated", "session" => "lead", "effort" => "high", "prompt" => prompt.("review")}
      ]
    end

    defp default_findings_step do
      %{
        "id" => "findings",
        "title" => "Read the open findings",
        "mode" => "machine",
        "command" => @findings_command,
        "timeout_ms" => 60_000,
        "on_fail" => "code"
      }
    end

    defp default_implementation_steps do
      [
        %{"id" => "code", "title" => "Write the code", "mode" => "delegated"},
        %{
          "id" => "build",
          "title" => "Build",
          "mode" => "machine",
          "command" => [
            %{"run" => "cd macos && make build", "when" => "macos_changed"},
            %{"run" => "mix compile --warnings-as-errors", "when" => "elixir_changed"}
          ],
          "timeout_ms" => 900_000,
          "on_fail" => "code"
        },
        %{
          "id" => "checks",
          "title" => "Format, specs and credo",
          "mode" => "machine",
          "when" => "elixir_changed",
          "command" => "mix format --check-formatted && mix specs.check && mix credo --strict $SYMPHONY_CHANGED_ELIXIR_FILES",
          "timeout_ms" => 600_000,
          "on_fail" => "code"
        },
        %{
          "id" => "tests",
          "title" => "Tests and coverage",
          "mode" => "machine",
          "command" => [
            %{"run" => "mix test $SYMPHONY_CHANGED_TEST_FILES && mix cover.changed", "when" => "elixir_changed"},
            %{"run" => "cd macos && swift test --filter \"$SYMPHONY_CHANGED_SWIFT_TEST_FILTER\"", "when" => "macos_changed"}
          ],
          "timeout_ms" => 1_800_000,
          "on_fail" => "code"
        },
        %{"id" => "handoff", "title" => "Hand off: push and open the pull request", "mode" => "delegated"}
      ]
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
        "usage_limit_resumed",
        "forced_waiting",
        "forced_human_gate",
        "forced_stale",
        "human_action_needed"
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
        |> Schema.validate_present([:kind])
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
    # The repo's manual review setting (`on` or `off`); the per-repo override merges in from
    # `repositories[].manual_review`, and the deprecated acceptance-gate mode derives it when the
    # key is absent (`SymphonyElixir.SystemSchema.manual_review_for_gate_mode/1`). With it `on`, the
    # last step into `Merging` waits for a person's confirmation.
    field(:manual_review, :string, default: "off")
    # The repo's `proof_check` (WORKFLOW.md): the check that runs its automated tests, which a
    # walkthrough step's `Proved by: <test>` names (`SymphonyElixir.Walkthrough`). Nil: no step is
    # proved by a named test.
    field(:proof_check, :string)
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:tickets, Tickets, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:poller, Poller, on_replace: :update, defaults_to_struct: true)
    embeds_one(:watchdog, Watchdog, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:github, GitHub, on_replace: :update, defaults_to_struct: true)
    embeds_one(:linear, Linear, on_replace: :update, defaults_to_struct: true)
    embeds_one(:execution, Execution, on_replace: :update, defaults_to_struct: true)
    # The `runs:` section, parsed by `SymphonyElixir.Config.Runs.parse/2`; `repository_runs` is
    # the routed repository's block with its config key, `%{"path" => ..., "runs" => ...}`.
    field(:runs, :map, default: %{})
    field(:repository_runs, :map)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:push_check, PushCheck, on_replace: :update, defaults_to_struct: true)
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
    embeds_one(:human_actions, HumanActions, on_replace: :update, defaults_to_struct: true)
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
      {:error, {:invalid_workflow_config, "`self_review` has been removed; use `code_review` in symphony.yml instead"}}
    else
      :ok
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    policy =
      case settings.execution.turn_sandbox_policy do
        %{} = policy ->
          policy

        _ ->
          workspace
          |> default_workspace_root(settings.workspace.root)
          |> expand_local_workspace_root()
          |> default_turn_sandbox_policy()
      end

    apply_codex_network_access(policy, codex_network_access(settings.execution.network_access))
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    policy_result =
      case settings.execution.turn_sandbox_policy do
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
       |> apply_codex_network_access(codex_network_access(settings.execution.network_access))}
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
    network_access = codex_network_access(settings.execution.network_access)
    denied_domains = network_access.denied_domains |> normalize_domain_list() |> MapSet.new()

    (@codex_built_in_network_allowed_domains ++ normalize_domain_list(network_access.allowed_domains))
    |> normalize_domain_list()
    |> Enum.reject(&MapSet.member?(denied_domains, &1))
  end

  @doc """
  The hosts a sandboxed verification dev server may reach through its egress proxy: the
  agent's built-in dependency hosts, without the model providers, plus
  `execution.permissions.network.allowed_domains`, less `denied_domains`. None with `mode: block`.
  """
  @spec dev_server_network_allowed_domains(%__MODULE__{}) :: [String.t()]
  def dev_server_network_allowed_domains(%__MODULE__{} = settings) do
    case codex_network_access(settings.execution.network_access) do
      %{mode: "block"} ->
        []

      network_access ->
        denied_domains = network_access.denied_domains |> normalize_domain_list() |> MapSet.new()

        (@shared_built_in_network_allowed_domains ++ normalize_domain_list(network_access.allowed_domains))
        |> normalize_domain_list()
        |> Enum.reject(&MapSet.member?(denied_domains, &1))
    end
  end

  @doc false
  @spec resolve_codex_thread_config(%__MODULE__{}) :: map() | nil
  def resolve_codex_thread_config(%__MODULE__{} = settings) do
    case codex_network_access(settings.execution.network_access).mode do
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

  # Config changesets cast with `empty_values: []` so a blank string reaches the
  # validators as itself. Since Ecto 3.14, `validate_required/3` only counts the
  # changeset's `empty_values` as missing, so it is run with `""` empty here to
  # keep reporting a blank required string as "can't be blank".
  @doc false
  @spec validate_present(Ecto.Changeset.t(), atom() | [atom()], keyword()) :: Ecto.Changeset.t()
  def validate_present(%Ecto.Changeset{empty_values: empty_values} = changeset, fields, opts \\ []) do
    %{changeset | empty_values: [""]}
    |> validate_required(fields, opts)
    |> Map.put(:empty_values, empty_values)
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
    |> cast(attrs, [:manual_review, :proof_check, :runs, :repository_runs], empty_values: [])
    |> validate_inclusion(:manual_review, ["on", "off"])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:tickets, with: &Tickets.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:poller, with: &Poller.changeset/2)
    |> cast_embed(:watchdog, with: &Watchdog.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:github, with: &GitHub.changeset/2)
    |> cast_embed(:linear, with: &Linear.changeset/2)
    |> cast_embed(:execution, with: &Execution.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:push_check, with: &PushCheck.changeset/2)
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
    |> cast_embed(:human_actions, with: &HumanActions.changeset/2)
  end

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

    execution = %{
      settings.execution
      | turn_sandbox_policy: normalize_optional_map(settings.execution.turn_sandbox_policy),
        network_access: normalize_network_access(settings.execution.network_access)
    }

    notifications = normalize_notifications(settings.notifications)
    github = %{settings.github | webhooks: resolve_webhook_secret(settings.github.webhooks)}
    linear = %{settings.linear | webhooks: resolve_webhook_secret(settings.linear.webhooks)}

    %{
      settings
      | tracker: tracker,
        workspace: workspace,
        execution: execution,
        notifications: notifications,
        github: github,
        linear: linear
    }
  end

  # `github.webhooks.secret` and `linear.webhooks.secret`: a literal or an `$ENV` reference.
  defp resolve_webhook_secret(%{secret: secret} = webhooks), do: %{webhooks | secret: secret |> resolve_secret_setting(nil) |> Secret.wrap()}

  defp validate_finalized_settings(settings) do
    with :ok <- validate_plan_review_state_inactive(settings),
         :ok <- validate_runs(settings) do
      validate_finalized_notification_urls(settings.notifications)
    end
  end

  # Plan parents wait for a person in Plan Review, so dispatching from it would take the handoff
  # away from them.
  defp validate_plan_review_state_inactive(%__MODULE__{tracker: %Tracker{plan_review_state: state} = tracker}) when is_binary(state) do
    if Enum.any?(tracker.active_states, &(String.downcase(String.trim(&1)) == String.downcase(state))),
      do: {:error, "tracker.plan_review_state must not be an active state"},
      else: :ok
  end

  defp validate_plan_review_state_inactive(_settings), do: :ok

  # What the `execution` section sets must suit the harness of every run kind that resolves,
  # and a provider whose key reaches the agent through the local subprocess env cannot serve
  # an SSH worker. Loading `symphony.yml` already checked that every run kind resolves.
  defp validate_runs(%__MODULE__{} = settings) do
    repository = with %{"path" => path, "runs" => runs} <- settings.repository_runs, do: {path, runs}
    harnesses = Execution.harnesses(settings.execution)

    runs =
      for kind <- RunKind.names(), {:ok, run} <- [Runs.resolve(repository, settings.runs, harnesses, kind)] do
        {run, Runs.key(repository, settings.runs, kind, "provider")}
      end

    Enum.find_value(runs, :ok, fn {run, provider_key} ->
      with {:ok, _settings} <- for_run(settings, run),
           :ok <- validate_run_worker(settings.worker, run, provider_key) do
        nil
      end
    end)
  end

  defp validate_run_worker(%Worker{ssh_hosts: [_ | _]}, %Run{provider: provider}, provider_key) do
    if AgentProviders.api_key_env(provider) do
      {:error, "#{provider_key} #{provider} is not supported with workers.ssh_hosts; #{AgentProviders.display_name(provider)} runs start on the local host only"}
    else
      :ok
    end
  end

  defp validate_run_worker(_worker, _run, _provider_key), do: :ok

  @doc """
  `settings` for one run: its harness, its command and the run itself on `execution`, with the
  approval policy that harness defaults to. An error when the `execution` section sets
  something the run's harness cannot do, naming the run's entry.
  """
  @spec for_run(t(), Run.t()) :: {:ok, t()} | {:error, String.t()}
  def for_run(%__MODULE__{execution: execution} = settings, %Run{} = run) do
    execution = %{execution | harness: run.harness, command: run.command, run: run}
    execution = %{execution | approval_policy: execution |> default_approval_policy() |> normalize_keys()}

    with :ok <- validate_approval_policy(execution),
         :ok <- validate_outer_sandbox(execution),
         :ok <- validate_mcp(execution) do
      {:ok, %{settings | execution: execution}}
    else
      {:error, message} -> {:error, "#{message} (runs.#{run.kind} runs the #{run.harness} harness)"}
    end
  end

  defp validate_approval_policy(%Execution{harness: "codex", approval_policy: "never"}) do
    {:error, ~s(execution.permissions.approval_policy="never" is not supported on the codex harness; use "auto_approve_all" for unattended auto-approval)}
  end

  defp validate_approval_policy(_execution), do: :ok

  defp validate_outer_sandbox(%Execution{
         harness: "codex",
         sandbox_runtime: %Execution.SandboxRuntime{kind: "srt"},
         network_access: %Execution.NetworkAccess{mode: "open"}
       }) do
    {:error, "execution.permissions.outer_sandbox.kind=\"srt\" does not support execution.permissions.network.mode=\"open\""}
  end

  defp validate_outer_sandbox(%Execution{harness: "codex"}), do: :ok

  defp validate_outer_sandbox(%Execution{sandbox_runtime: %Execution.SandboxRuntime{kind: kind}})
       when kind in [nil, "none"],
       do: :ok

  defp validate_outer_sandbox(%Execution{sandbox_runtime: %Execution.SandboxRuntime{kind: kind}}) do
    {:error, "execution.permissions.outer_sandbox.kind=#{inspect(kind)} is only supported on the codex harness"}
  end

  defp validate_mcp(%Execution{harness: "claude", mcp: %Execution.Mcp{inherit: "all"}}) do
    {:error, ~s(execution.mcp.inherit="all" is not supported on the claude harness; declare MCP servers explicitly)}
  end

  defp validate_mcp(%Execution{harness: "codex", mcp: %Execution.Mcp{servers: servers}}) when is_map(servers) do
    case Enum.find(servers, fn {_name, server} -> codex_targeted_non_stdio_mcp_server?(server) end) do
      {name, server} ->
        {:error, "execution.mcp.servers.#{name}.transport=#{inspect(server.transport)} is not supported on the codex harness; its MCP servers must use transport=\"stdio\""}

      nil ->
        :ok
    end
  end

  defp validate_mcp(_execution), do: :ok

  defp codex_targeted_non_stdio_mcp_server?(%Execution.Mcp.Server{transport: transport, harnesses: harnesses})
       when transport in ["http", "sse"] and is_list(harnesses) do
    "codex" in harnesses
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

  defp normalize_network_access(%Execution.NetworkAccess{} = network_access) do
    %{
      network_access
      | allowed_domains: normalize_domain_list(network_access.allowed_domains),
        denied_domains: normalize_domain_list(network_access.denied_domains)
    }
  end

  defp codex_network_access(%Execution.NetworkAccess{} = network_access), do: network_access
  defp codex_network_access(nil), do: %Execution.NetworkAccess{}

  defp default_approval_policy(%Execution{approval_policy: nil, harness: "codex"}), do: Execution.codex_default_approval_policy()
  defp default_approval_policy(%Execution{approval_policy: nil}), do: "never"
  defp default_approval_policy(%Execution{approval_policy: approval_policy}), do: approval_policy

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

  defp preserve_explicit_nil_path?(["execution", key]) when key in ["max_tokens_per_issue", "max_tokens_per_day"],
    do: true

  defp preserve_explicit_nil_path?(["tracker", "waiting_on_sub_issues_state"]), do: true

  defp preserve_explicit_nil_path?(["tracker", field])
       when field in ["code_review_state", "qa_state", "plan_review_state", "epic_review_state", "ci_fix_state"],
       do: true

  defp preserve_explicit_nil_path?(["watchdog", "stray_process_cpu_minutes"]), do: true
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

  defp apply_codex_network_access(policy, %Execution.NetworkAccess{mode: "allowlist"}) do
    put_known_network_access(policy, true)
  end

  defp apply_codex_network_access(policy, %Execution.NetworkAccess{mode: "open"}) do
    put_known_network_access(policy, true)
  end

  defp apply_codex_network_access(policy, %Execution.NetworkAccess{mode: "block"}) do
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
