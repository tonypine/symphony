defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an operator `symphony.yml`.
  """

  alias SymphonyElixir.{Config, ControlClient, Paths, ReleaseNode, TerminalDashboard}

  # Retained so existing scripts (Docker, ops runbooks) that still pass the long
  # flag keep parsing — its value is ignored.
  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  # Set by the Burrito wrapper before it execs the BEAM. The `burrito` dep is
  # build-only (`runtime: false`), so `Burrito.Util.Args` is not in the release.
  @burrito_bin_path_env "__BURRITO_BIN_PATH"
  @service_switches [
    {@acknowledgement_switch, :boolean},
    config: :string,
    host: :string,
    logs_root: :string,
    port: :integer,
    state_root: :string
  ]
  @run_switches [
    {@acknowledgement_switch, :boolean},
    config: :string,
    logs_root: :string,
    no_retry: :boolean,
    state_root: :string,
    timeout: :string
  ]
  @check_switches [config: :string]
  @dashboard_switches [url: :string]
  @force_switches [clear: :boolean]
  @default_symphony_file "symphony.yml"

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type one_shot_result ::
          {:ok, map()}
          | {:error, term()}
          | {:config_error, term()}
          | {:timeout, term()}

  @type deps :: %{
          check_config: (-> :ok | {:error, term()}),
          check_findings: (-> %{errors: [String.t()], warnings: [String.t()]}),
          file_regular?: (String.t() -> boolean()),
          init: ([String.t()] -> SymphonyElixir.Init.result()),
          set_symphony_file_path: (String.t() -> :ok | {:error, term()}),
          set_state_root: (String.t() -> :ok | {:error, term()}),
          set_state_root_from_env: (-> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_logs_root_from_env: (-> :ok | {:error, term()}),
          set_server_host_override: (String.t() | nil -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result()),
          run_one_shot: (String.t(), keyword() -> one_shot_result()),
          control_url: (-> String.t()),
          run_dashboard: ((-> String.t()) -> :ok),
          force_issue: (String.t(), boolean() -> ControlClient.control_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok -> wait_for_shutdown()
      result -> halt(result)
    end
  end

  @spec halt({:halt, non_neg_integer()} | {:error, String.t()} | {:error, String.t(), non_neg_integer()}) ::
          no_return()
  defp halt({:halt, code}), do: System.halt(code)

  defp halt({:error, message, code}) do
    IO.puts(:stderr, message)
    System.halt(code)
  end

  defp halt({:error, message}), do: halt({:error, message, 1})

  @spec evaluate([String.t()], deps()) ::
          :ok | {:halt, non_neg_integer()} | {:error, String.t()} | {:error, String.t(), non_neg_integer()}
  def evaluate(args, deps \\ runtime_deps()) do
    case args do
      ["check" | check_args] ->
        evaluate_check(check_args, deps)

      ["dashboard" | dashboard_args] ->
        evaluate_dashboard(dashboard_args, deps)

      ["force" | force_args] ->
        evaluate_force(force_args, deps)

      ["init" | init_args] ->
        evaluate_init(init_args, deps)

      ["pr" | pr_args] ->
        dispatch_pr(pr_args)

      ["run" | run_args] ->
        evaluate_run(run_args, deps)

      ["workflow" | workflow_args] ->
        evaluate_workflow(workflow_args)

      _args ->
        with :ok <- configure(args, deps) do
          start_runtime(deps)
        end
    end
  end

  defp evaluate_init(args, deps) do
    case deps.init.(args) do
      {:ok, message} ->
        IO.puts(message)
        {:halt, 0}

      {:error, message} ->
        {:error, message}
    end
  end

  # Loads symphony.yml and every repo WORKFLOW.md startup would read (the committed
  # ref, see `WorkflowSource.load_for_check/1`) through the same validation the
  # application runs at boot, without starting the supervisor or touching the network.
  defp evaluate_check(args, deps) do
    case OptionParser.parse(args, strict: @check_switches) do
      {opts, [], []} ->
        with :ok <- set_symphony_config(opts, deps) do
          check_config(symphony_config_path(opts), deps)
        end

      _ ->
        {:error, check_usage_message()}
    end
  end

  # Draws the running Symphony's dashboard from its control API; no config needed.
  defp evaluate_dashboard(args, deps) do
    case OptionParser.parse(args, strict: @dashboard_switches) do
      {opts, [], []} ->
        :ok = deps.run_dashboard.(dashboard_url_source(opts, deps))
        {:halt, 0}

      _ ->
        {:error, dashboard_usage_message()}
    end
  end

  # Without --url, the URL is looked up on every poll: a restarted Symphony may listen on a new port.
  defp dashboard_url_source(opts, deps) do
    case opts |> Keyword.get_values(:url) |> List.last() do
      nil -> fn -> String.trim_trailing(deps.control_url.(), "/") end
      url -> fn -> String.trim_trailing(url, "/") end
    end
  end

  # Adds or clears the force label through the running Symphony's control API; no config needed.
  defp evaluate_force(args, deps) do
    with {opts, [identifier], []} <- OptionParser.parse(args, strict: @force_switches),
         identifier when identifier != "" <- String.trim(identifier) do
      identifier
      |> deps.force_issue.(Keyword.get(opts, :clear, false))
      |> force_result(identifier, deps)
    else
      _ -> {:error, force_usage_message()}
    end
  end

  defp force_result({:ok, result}, identifier, _deps) do
    IO.puts(force_message(Map.get(result, :issue_identifier) || identifier, result))
    {:halt, 0}
  end

  defp force_result(:unavailable, _identifier, _deps),
    do: {:error, "Symphony's orchestrator is unavailable; try again once it has started"}

  defp force_result({:error, reason}, identifier, deps), do: {:error, force_error_message(reason, identifier, deps)}

  defp force_message(identifier, %{forced: false}), do: "#{identifier} no longer forced"
  defp force_message(identifier, %{position: nil, state: state}), do: "#{identifier} forced (it is in #{state}; forcing doesn't promote it)"
  defp force_message(identifier, %{position: position, forced_max: forced_max}) when position <= forced_max, do: "#{identifier} forced (slot #{position} of #{forced_max})"
  defp force_message(identifier, %{position: position, holders: holders}), do: "#{identifier} forced (queued ##{position}; #{holders_phrase(holders)})"

  defp holders_phrase([holder]), do: "#{holder} holds the forced slot"

  defp holders_phrase(holders) do
    {others, [last]} = Enum.split(holders, -1)
    "#{Enum.join(others, ", ")} and #{last} hold the forced slots"
  end

  defp force_error_message(:control_token_unavailable, _identifier, _deps),
    do: "No control token: start Symphony first, or set SYMPHONY_CONTROL_TOKEN to the token in <state-root>/control_token"

  defp force_error_message({:unauthorized, _payload}, _identifier, _deps),
    do: "The running Symphony rejected the control token; check SYMPHONY_CONTROL_TOKEN"

  defp force_error_message({:connection_failed, _reason}, _identifier, deps),
    do: "Could not reach Symphony at #{deps.control_url.()}; is it running?"

  defp force_error_message({:invalid_request, %{"error" => %{"message" => message}}}, _identifier, _deps) when is_binary(message),
    do: message

  defp force_error_message({:http_status, _status, %{"error" => %{"message" => message}}}, _identifier, _deps) when is_binary(message),
    do: message

  defp force_error_message(reason, identifier, _deps), do: "Could not force #{identifier}: #{inspect(reason)}"

  defp check_config(path, deps) do
    case deps.check_config.() do
      :ok ->
        %{errors: errors, warnings: warnings} = deps.check_findings.()
        if errors == [], do: IO.puts("Config OK: #{path}")
        Enum.each(warnings, &IO.puts("Warning: #{&1}"))
        check_result(path, errors)

      {:error, reason} ->
        {:error, "Config error in #{path}: #{Config.format_error(reason)}"}
    end
  end

  defp check_result(_path, []), do: {:halt, 0}
  defp check_result(path, errors), do: {:error, "Config error in #{path}: #{Enum.join(errors, "; ")}"}

  defp dispatch_pr(args) do
    case OptionParser.parse(args, strict: [intent: :string]) do
      {opts, [target], []} ->
        pr_opts =
          opts
          |> Keyword.take([:intent])
          |> Enum.reject(fn {_key, value} -> is_nil(value) or String.trim(value) == "" end)

        case SymphonyElixir.ControlClient.dispatch_pr(target, pr_opts) do
          {:ok, result} ->
            IO.puts("Dispatched PR run: #{Map.get(result, :pull_request_url) || target}")
            {:halt, 0}

          :unavailable ->
            {:error, "Orchestrator unavailable"}

          {:error, reason} ->
            {:error, "PR dispatch failed: #{inspect(reason)}"}
        end

      _ ->
        {:error, "Usage: symphony pr <url-or-number> [--intent \"address review comments\"]"}
    end
  end

  defp evaluate_workflow(["preview" | preview_args]), do: dispatch_workflow_preview(preview_args)

  defp evaluate_workflow(_args),
    do: {:error, "Usage: symphony workflow preview [--file WORKFLOW.md] [--agent codex|claude]"}

  defp dispatch_workflow_preview(args) do
    case OptionParser.parse(args, strict: [file: :string, agent: :string]) do
      {opts, [], []} ->
        render_opts =
          []
          |> maybe_put(:file, Keyword.get(opts, :file))
          |> maybe_put(:agent_kind, Keyword.get(opts, :agent))

        case SymphonyElixir.WorkflowPreview.render(render_opts) do
          {:ok, prompt} ->
            IO.puts(prompt)
            {:halt, 0}

          {:error, message} ->
            {:error, message}
        end

      _ ->
        {:error, "Usage: symphony workflow preview [--file WORKFLOW.md] [--agent codex|claude]"}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @spec configure([String.t()], deps()) :: :ok | {:error, String.t()}
  def configure(args, deps \\ runtime_deps()) do
    with :ok <- deps.set_state_root_from_env.(),
         :ok <- deps.set_logs_root_from_env.() do
      parse_and_configure(args, deps)
    end
  end

  @spec maybe_configure_burrito_runtime() :: :ok
  def maybe_configure_burrito_runtime do
    case burrito_args() do
      :not_in_burrito ->
        :ok

      [command | _args] = args when command in ["check", "dashboard", "force"] ->
        args |> evaluate() |> halt()

      args ->
        with {:error, message} <- configure_service(args) do
          halt({:error, message})
        end
    end
  end

  # Only the service takes the node name; `check`, `dashboard` and `force` above run
  # undistributed so they work next to a running Symphony.
  defp configure_service(args) do
    with :ok <- configure(args), do: ReleaseNode.start(ReleaseNode.runtime_deps())
  end

  defp parse_and_configure(args, deps) do
    case OptionParser.parse(args, strict: @service_switches) do
      {opts, [], []} ->
        with :ok <- set_symphony_config(opts, deps),
             :ok <- maybe_set_state_root(opts, deps),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_host(opts, deps) do
          maybe_set_server_port(opts, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp evaluate_run(args, deps) do
    with {:ok, issue_identifier, opts} <- parse_run_args(args),
         :ok <- validate_run_timeout(opts),
         :ok <- configure_run(opts, deps) do
      announce_run_start(issue_identifier)

      issue_identifier
      |> deps.run_one_shot.(run_options(opts))
      |> tap(&announce_run_result(issue_identifier, &1))
      |> one_shot_result()
    end
  end

  defp announce_run_start(issue_identifier) do
    IO.puts(:stderr, "▶ Running #{issue_identifier}  (logs: #{Paths.log_file()})")
  end

  defp announce_run_result(issue_identifier, {:ok, _result}),
    do: IO.puts(:stderr, "✓ #{issue_identifier} completed")

  defp announce_run_result(issue_identifier, {:timeout, _reason}),
    do: IO.puts(:stderr, "✗ #{issue_identifier} timed out")

  defp announce_run_result(_issue_identifier, _other), do: :ok

  defp parse_run_args(args) do
    case OptionParser.parse(args, strict: @run_switches) do
      {opts, [issue_identifier], []} ->
        case String.trim(issue_identifier) do
          "" -> {:error, run_usage_message(), 2}
          issue_identifier -> {:ok, issue_identifier, opts}
        end

      _ ->
        {:error, run_usage_message(), 2}
    end
  end

  defp configure_run(opts, deps) do
    with :ok <- deps.set_state_root_from_env.(),
         :ok <- deps.set_logs_root_from_env.(),
         :ok <- set_symphony_config(opts, deps),
         :ok <- maybe_set_state_root(opts, deps) do
      maybe_set_logs_root(opts, deps)
    else
      {:error, message} -> {:error, message, 2}
    end
  end

  defp run_options(opts) do
    [
      timeout_ms: parse_timeout_ms(Keyword.get(opts, :timeout)),
      no_retry: Keyword.get(opts, :no_retry, false)
    ]
  end

  defp validate_run_timeout(opts) do
    case parse_timeout_ms(Keyword.get(opts, :timeout)) do
      :invalid -> {:error, "Invalid --timeout value. Use an integer optionally followed by ms, s, m, or h.", 2}
      _timeout_ms -> :ok
    end
  end

  defp parse_timeout_ms(nil), do: nil

  defp parse_timeout_ms(raw) when is_binary(raw) do
    raw = String.trim(raw)

    case Regex.run(~r/^(\d+)(ms|s|m|h)?$/, raw) do
      [_, amount, unit] ->
        amount = String.to_integer(amount)

        case unit do
          "ms" -> amount
          "s" -> amount * 1_000
          "m" -> amount * 60_000
          "h" -> amount * 3_600_000
          "" -> amount
        end

      _ ->
        :invalid
    end
  end

  defp parse_timeout_ms(_raw), do: :invalid

  defp one_shot_result({:ok, _result}), do: {:halt, 0}
  defp one_shot_result({:timeout, _reason}), do: {:halt, 124}
  defp one_shot_result({:config_error, reason}), do: {:error, "Configuration error: #{inspect(reason)}", 2}
  defp one_shot_result({:error, reason}), do: {:error, "One-shot run failed: #{inspect(reason)}", 1}
  defp one_shot_result(other), do: {:error, "One-shot run failed: #{inspect(other)}", 1}

  defp start_runtime(deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony: #{inspect(reason)}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony init [--force]\n" <>
      "       symphony check [--config <path-to-symphony.yml>]\n" <>
      "       symphony dashboard [--url <control-url>]\n" <>
      "       symphony force [--clear] <issue-identifier>\n" <>
      "       symphony [--config <path-to-symphony.yml>] [--state-root <path>] [--logs-root <path>] [--host <host>] [--port <port>]\n" <>
      "       symphony pr <url-or-number> [--intent \"address review comments\"]\n" <>
      "       symphony run <issue-identifier> [--config <path-to-symphony.yml>] [--timeout <duration>] [--no-retry] [--state-root <path>] [--logs-root <path>]\n" <>
      "       symphony workflow preview [--file WORKFLOW.md] [--agent codex|claude]"
  end

  defp check_usage_message do
    "Usage: symphony check [--config <path-to-symphony.yml>]"
  end

  defp dashboard_usage_message do
    "Usage: symphony dashboard [--url <control-url>]"
  end

  defp force_usage_message do
    "Usage: symphony force [--clear] <issue-identifier>"
  end

  @spec run_usage_message() :: String.t()
  defp run_usage_message do
    "Usage: symphony run <issue-identifier> [--config <path-to-symphony.yml>] [--timeout <duration>] [--no-retry] [--state-root <path>] [--logs-root <path>]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      check_config: &Config.check_repo_workflows/0,
      check_findings: &Config.check_findings/0,
      file_regular?: &File.regular?/1,
      init: &SymphonyElixir.Init.run/1,
      set_symphony_file_path: &SymphonyElixir.Workflow.set_symphony_file_path/1,
      set_state_root: &set_state_root/1,
      set_state_root_from_env: &Paths.set_state_root_from_env/0,
      set_logs_root: &set_logs_root/1,
      set_logs_root_from_env: &Paths.set_logs_root_from_env/0,
      set_server_host_override: &set_server_host_override/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end,
      run_one_shot: &SymphonyElixir.OneShot.run/2,
      control_url: fn -> ControlClient.control_url() end,
      run_dashboard: &run_dashboard/1,
      force_issue: &ControlClient.force_issue/2
    }
  end

  defp run_dashboard(url_source) do
    TerminalDashboard.run(url_source, TerminalDashboard.runtime_deps(), [])
  end

  defp set_symphony_config(opts, deps) do
    path = symphony_config_path(opts)

    if deps.file_regular?.(path) do
      :ok = deps.set_symphony_file_path.(path)
    else
      {:error, "Symphony config file not found: #{path}"}
    end
  end

  defp symphony_config_path(opts) do
    raw = opts |> Keyword.get_values(:config) |> List.last() || @default_symphony_file
    Path.expand(raw)
  end

  defp maybe_set_state_root(opts, deps),
    do: maybe_set_root(opts, :state_root, deps.set_state_root)

  defp maybe_set_logs_root(opts, deps),
    do: maybe_set_root(opts, :logs_root, deps.set_logs_root)

  defp maybe_set_root(opts, key, setter) do
    with_last_opt(opts, key, fn raw ->
      case String.trim(raw) do
        "" -> {:error, usage_message()}
        root -> :ok = setter.(Path.expand(root))
      end
    end)
  end

  defp set_logs_root(logs_root) do
    Paths.set_logs_root(logs_root)
  end

  defp set_state_root(state_root) do
    Paths.set_state_root(state_root)
  end

  defp maybe_set_server_host(opts, deps) do
    with_last_opt(opts, :host, fn raw ->
      host = String.trim(raw)

      if host == "" do
        {:error, usage_message()}
      else
        :ok = deps.set_server_host_override.(host)
      end
    end)
  end

  defp maybe_set_server_port(opts, deps) do
    with_last_opt(opts, :port, fn port ->
      if is_integer(port) and port >= 0 do
        :ok = deps.set_server_port_override.(port)
      else
        {:error, usage_message()}
      end
    end)
  end

  defp with_last_opt(opts, key, fun) do
    case Keyword.get_values(opts, key) do
      [] -> :ok
      values -> fun.(List.last(values))
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp set_server_host_override(host) when is_binary(host) do
    Application.put_env(:symphony_elixir, :server_host_override, host)
    :ok
  end

  defp burrito_args do
    burrito_args(System.get_env(@burrito_bin_path_env), :init.get_plain_arguments())
  end

  # Same as `Burrito.Util.Args.argv/0`: the wrapper passes its arguments after
  # `-extra`, which the VM exposes as plain arguments.
  @doc false
  @spec burrito_args(String.t() | nil, [charlist() | String.t()]) :: [String.t()] | :not_in_burrito
  def burrito_args(bin_path, _plain_arguments) when bin_path in [nil, ""], do: :not_in_burrito
  def burrito_args(_bin_path, plain_arguments), do: Enum.map(plain_arguments, &to_string/1)

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
