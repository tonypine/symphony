defmodule SymphonyElixir.GitHub.WebhookSetup do
  @moduledoc """
  Instant GitHub updates, set up by Symphony itself: the steps that get GitHub's webhook
  deliveries to this Mac, their health, and the actions the app's Setup takes
  (`GET /api/v1/setup` → `github_updates`, `POST /api/v1/setup/github_updates/:action`).

  ## Steps

  | Step | Checks | Runs |
  | --- | --- | --- |
  | `relay` | the relay is usable: the GitHub CLI's webhook extension for `gh_webhook_forward`, the public URL for the others | installs the extension, or keeps the URL it is given |
  | `gh_ready` | `gh` is signed in with a token that can manage webhooks (`admin:repo_hook`) | checks again: signing in is the person's |
  | `secret` | a webhook secret is set | makes one, hands it to the app (`SymphonyElixir.GitHub.WebhookSecret`) and writes `secret: $SYMPHONY_GITHUB_WEBHOOK_SECRET` |
  | `port` | `dashboard.port` is pinned to the port Symphony listens on | pins it in `symphony.yml` |
  | `repo:<key>` | the repository's relay runs (`gh_webhook_forward`), or the hook Symphony created exists | checks admin access, then starts the relay or creates the hook with `gh api repos/:repo/hooks` |
  | `test:<key>` | a delivery from the repository reached Symphony and verified after the test started | starts the relay again (a new forwarding hook is pinged) or pings the hook |

  A failure says what is wrong and what fixes it, in plain words (`detail`, `fix`), and names the
  app's button for a fix only the person can make (`action`): `grant_permission` (`gh auth refresh`
  with the webhook scope), `sign_in` (`gh auth login`) or `restart_symphony` (the pinned port isn't
  the one Symphony listens on). A repository whose step fails stays on polling; the others connect,
  and `leave_on_polling` takes a connected one back to polling.

  ## Mode

  `off` while `github.webhooks.enabled` is false. `needs_setup` while it is on but this Mac was
  never set up (a `symphony.yml` brought from another Mac: J6); the steps already done show done.
  `setting_up` until every step is done and each connected repository's test verified. Then `on`,
  or `degraded` (D12) while a relay can't restart or stopped more than twice in ten minutes and
  hasn't run ten minutes since, or a repository heard nothing for
  `github.webhooks.silence_alert_minutes` since a read found a change no delivery reported. Each
  repository says why (`degraded_reason`) and the interval its watcher polls at now
  (`poll_interval_ms`).

  What this Mac's setup did is kept in the run store (`{:setup, :webhooks}`): when it was turned
  on, a URL relay's public URL, the hooks Symphony created (so turning off deletes only those), each
  step's last result and each test. No secret is kept there, in `symphony.yml` or in the section.

  Polling never depends on any of it: turning updates on or off only changes how soon the watcher
  hears of a change.
  """

  require Logger

  alias SymphonyElixir.{Config, HttpServer, PrWatch, Secret, Workflow}
  alias SymphonyElixir.Config.{Cache, LineEditor}
  alias SymphonyElixir.GitHub.{PullRequest, RelaySupervisor, WebhookSecret}
  alias SymphonyElixir.PrWatch.Health
  alias SymphonyElixir.Repo.Status, as: RepoStatus

  @store_key {:setup, :webhooks}
  @test_timeout_s 30
  @relays ["gh_webhook_forward", "smee", "cloudflare_tunnel", "tailscale_funnel"]
  @webhook_path "/api/v1/github/webhook"
  @extension "cli/gh-webhook"
  @hook_scopes ["admin:repo_hook", "write:repo_hook", "repo"]
  @relay_labels %{
    "gh_webhook_forward" => "GitHub CLI forwarding",
    "smee" => "smee.io",
    "cloudflare_tunnel" => "Cloudflare Tunnel",
    "tailscale_funnel" => "Tailscale Funnel"
  }
  @actions ~w(turn_on run_step test leave_on_polling restart_relay recreate_secret change_relay turn_off)

  @type failure :: %{required(:detail) => String.t(), required(:fix) => String.t(), optional(:action) => String.t()}
  @type result :: :ok | {:pending, String.t()} | {:error, failure()}
  @type action_error :: {:not_found | :unprocessable | :conflict | :config, String.t()}

  @doc "The actions `POST /api/v1/setup/github_updates/:action` takes."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "The relays instant updates can use, the first the default (D1)."
  @spec relays() :: [String.t()]
  def relays, do: @relays

  @doc """
  Runs `action` with the request's `params` and returns the section as it leaves it. `opts` (for
  tests): `:gh` (or `:gh_runner`), `:hand_off`, `:secret`, `:run_store`, `:relays`, `:now`, `:symphony_file`,
  `:repos`, `:port`, `:settings`.
  """
  @spec action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, action_error()}
  def action(action, params, opts) when action in @actions and is_map(params) do
    ctx = context(opts)

    with :ok <- apply_action(action, params, ctx), do: {:ok, section(ctx)}
  end

  def action(action, _params, _opts), do: {:error, {:not_found, "There is no GitHub updates action named #{inspect(action)}."}}

  @doc "The `github_updates` section of `GET /api/v1/setup`."
  @spec section() :: map()
  def section, do: section([])

  @spec section(keyword() | map()) :: map()
  def section(opts) when is_list(opts), do: section(context(opts))

  def section(%{} = ctx) do
    ctx = read_once(ctx)
    record = load(ctx)
    webhooks = ctx.settings.().github.webhooks
    steps = Enum.map(step_ids(ctx), &step_entry(&1, record, ctx))
    repos = Enum.map(ctx.repos.(), &repo_entry(&1, record, webhooks, ctx))

    %{
      mode: mode(record, webhooks, steps, repos),
      enabled: webhooks.enabled,
      relay: relay_entry(webhooks, record, ctx),
      secret: %{present: ctx.secret.() != nil, item: WebhookSecret.item(), env: WebhookSecret.env()},
      events: webhooks.events,
      turned_on_at: record.turned_on_at,
      steps: steps,
      repos: repos,
      poll: %{
        interval_ms: poll_interval_ms(ctx),
        fallback_interval_ms: webhooks.fallback_poll_interval_ms,
        silence_alert_minutes: webhooks.silence_alert_minutes
      },
      rate_limit: PrWatch.rate_limit(run_store: ctx.store)
    }
  end

  @doc """
  The section for `/api/v1/state`'s `setup`, so the app's Setup card and its Overview row follow the
  state poll. Nil when it can't be read (a configuration that doesn't load, a run store that isn't
  up), so the state payload never fails on it.
  """
  @spec state_section(keyword()) :: map() | nil
  def state_section(opts \\ []) do
    section(opts)
  rescue
    error -> section_unavailable(Exception.message(error))
  catch
    kind, reason -> section_unavailable(Exception.format_banner(kind, reason))
  end

  # Every step, repository and relay entry asks for the settings and the repositories again, and
  # each read parses symphony.yml and WORKFLOW.md: the section reads them, the port and the secret
  # once. It rides on every `/api/v1/state` poll, which a dev server's health check gives 250 ms.
  defp read_once(ctx) do
    settings = ctx.settings.()
    repos = ctx.repos.()
    port = ctx.port.()
    secret = ctx.secret.()
    %{ctx | settings: fn -> settings end, repos: fn -> repos end, port: fn -> port end, secret: fn -> secret end}
  end

  defp section_unavailable(reason) do
    Logger.debug("Instant GitHub updates left out of the state: #{String.slice(reason, 0, 300)}")
    nil
  end

  @doc """
  A delivery that verified, about the repository at `repo_url`: it completes that repository's
  running test. Called by the webhook controller for every verified delivery.

  It is best effort: the delivery reaches the PR watcher whatever happens here. With no test
  waiting for the repository it reads the record once and takes no lock; an error is logged and
  answered `:ok`.
  """
  @spec delivered(String.t() | nil, keyword()) :: :ok

  def delivered(repo_url, opts) when is_binary(repo_url) do
    ctx = context(opts)

    if waiting_tests(load(ctx), repo_url) != [] do
      update(ctx, fn record ->
        now = ctx.now.()
        %{record | tests: Enum.reduce(waiting_tests(record, repo_url), record.tests, &put_in(&2, [&1, :verified_at], now))}
      end)
    end

    :ok
  rescue
    error -> delivery_not_recorded(Exception.message(error))
  catch
    kind, reason -> delivery_not_recorded(Exception.format_banner(kind, reason))
  end

  def delivered(_repo_url, _opts), do: :ok

  defp waiting_tests(record, repo_url) do
    for {key, %{sent_at: %DateTime{}, verified_at: nil, github: github}} <- record.tests, same_repo?(repo_url, github), do: key
  end

  defp delivery_not_recorded(reason) do
    Logger.warning("Instant GitHub updates couldn't record a test delivery: #{String.slice(reason, 0, 300)}")
    :ok
  end

  @doc """
  At start: starts the relay of every repository instant updates connected through
  `gh_webhook_forward` on this Mac, when they are on and the secret is set.
  """
  @spec resume(keyword()) :: :ok
  def resume(opts \\ []) do
    ctx = context(opts)
    record = load(ctx)
    webhooks = ctx.settings.().github.webhooks

    if webhooks.enabled and webhooks.relay == "gh_webhook_forward" and record.turned_on_at != nil and ctx.secret.() != nil do
      for repo <- connected(record, ctx), do: start_relay(repo, ctx)
    end

    :ok
  rescue
    error ->
      Logger.warning("Instant GitHub updates didn't resume their relays: #{Exception.message(error)}")
      :ok
  end

  ## Steps

  @doc "Checks one step (`relay`, `gh_ready`, `secret`, `port`, `repo:<key>`, `test:<key>`)."
  @spec check(String.t(), keyword() | map()) :: result()
  def check(step, opts) when is_list(opts), do: check(step, context(opts))

  def check("relay", ctx) do
    case relay_kind(ctx) do
      "gh_webhook_forward" -> check_extension(ctx)
      kind -> if load(ctx).relay_url, do: :ok, else: failure(:relay_url, kind)
    end
  end

  def check("gh_ready", ctx) do
    case ctx.gh.(["auth", "status"]) do
      {:ok, output} -> if hook_scope?(output), do: :ok, else: failure(:scope)
      {:error, {:gh_unavailable, _message}} -> failure(:no_gh)
      {:error, _reason} -> failure(:signed_out)
    end
  end

  def check("secret", ctx), do: if(ctx.secret.(), do: :ok, else: failure(:no_secret))

  def check("port", ctx) do
    pinned = ctx.settings.().server.port

    cond do
      not (is_integer(pinned) and pinned > 0) -> failure(:port, ctx.port.())
      ctx.port.() not in [nil, pinned] -> failure(:port_moved, pinned)
      true -> :ok
    end
  end

  def check("repo:" <> key, ctx) do
    with {:ok, repo} <- find_repo(key, ctx) do
      record = load(ctx)

      case relay_kind(ctx) do
        "gh_webhook_forward" -> check_relay(repo, ctx)
        _url_relay -> check_hook(repo, record, ctx)
      end
    end
  end

  def check("test:" <> key, ctx) do
    with {:ok, _repo} <- find_repo(key, ctx) do
      case Map.get(load(ctx).tests, key) do
        %{verified_at: %DateTime{}} -> :ok
        %{sent_at: %DateTime{} = sent_at} -> waiting(sent_at, ctx)
        nil -> failure(:no_test)
      end
    end
  end

  def check(step, _ctx), do: {:error, %{detail: "There is no setup step named #{inspect(step)}.", fix: "Use one of the steps the section lists."}}

  @doc "Runs one step; `params` carries a URL relay's `url` for `relay`."
  @spec run(String.t(), map(), keyword() | map()) :: result()
  def run(step, params, opts) when is_list(opts), do: run(step, params, context(opts))

  def run("relay", params, ctx) do
    case relay_kind(ctx) do
      "gh_webhook_forward" ->
        with {:error, _failure} <- check_extension(ctx),
             {:ok, _output} <- ctx.gh.(["extension", "install", @extension]) |> gh_failure(:extension_install) do
          check_extension(ctx)
        end

      kind ->
        keep_relay_url(Map.get(params, "url"), kind, ctx)
    end
  end

  def run("gh_ready", _params, ctx), do: check("gh_ready", ctx)

  # A secret already set stays, since hooks and running relays sign with it; `recreate_secret`
  # makes a new one.
  def run("secret", _params, ctx) do
    if check("secret", ctx) == :ok, do: write_secret_setting(ctx), else: make_secret(ctx)
  end

  def run("port", _params, ctx) do
    case ctx.port.() do
      port when is_integer(port) and port > 0 -> write_config(ctx, [{["dashboard", "port"], Integer.to_string(port)}])
      _none -> {:error, %{detail: "Symphony's web server isn't listening yet, so there is no port to pin.", fix: "Start Symphony, then run this step again."}}
    end
  end

  def run("repo:" <> key, _params, ctx) do
    with {:ok, repo} <- find_repo(key, ctx),
         :ok <- ready_for_repo(ctx),
         :ok <- check_admin(repo, ctx) do
      case relay_kind(ctx) do
        "gh_webhook_forward" -> start_relay(repo, ctx)
        _url_relay -> ensure_hook(repo, ctx)
      end
    end
  end

  def run("test:" <> key, _params, ctx) do
    with {:ok, repo} <- find_repo(key, ctx),
         :ok <- connected?(repo, ctx) do
      sent_at = ctx.now.()
      update(ctx, &%{&1 | tests: Map.delete(&1.tests, key)})

      with :ok <- send_test(repo, ctx) do
        update(ctx, &put_in(&1, [:tests, key], %{sent_at: sent_at, verified_at: nil, github: repo.github}))
        check("test:" <> key, ctx)
      end
    end
  end

  def run(step, _params, ctx), do: check(step, ctx)

  defp keep_relay_url(nil, _kind, ctx), do: check("relay", ctx)

  defp keep_relay_url(url, kind, ctx) do
    with {:ok, url} <- relay_url(url, kind), do: update(ctx, &%{&1 | relay_url: url})
  end

  ## Actions

  defp apply_action("turn_on", params, ctx) do
    old_relay = relay_kind(ctx)

    # symphony.yml changes first, so an edit that fails leaves the setup as it was.
    with {:ok, relay} <- relay_param(params),
         {:ok, url} <- optional_url(params, relay),
         :ok <- config_result(ctx, [{["github", "webhooks", "enabled"], "true"}, {["github", "webhooks", "relay"], relay}]) do
      # Another relay than before: what the old one connected goes, as with change_relay.
      if relay != old_relay, do: switch_relay(ctx)
      update(ctx, &%{&1 | turned_on_at: &1.turned_on_at || ctx.now.(), relay_url: url || kept_url(&1, relay)})
      check_all(ctx)
    end
  end

  defp apply_action("run_step", params, ctx) do
    with :ok <- enabled(ctx),
         {:ok, step} <- step_param(params, ctx) do
      # A step that fails is part of the answer: the section shows its detail and fix.
      _result = record_step(ctx, step, run(step, params, ctx))
      :ok
    end
  end

  defp apply_action("test", params, ctx) do
    with :ok <- enabled(ctx),
         {:ok, repos} <- test_repos(params, ctx) do
      Enum.each(repos, fn repo -> record_step(ctx, "test:" <> repo.key, run("test:" <> repo.key, params, ctx)) end)
    end
  end

  # One repository back to polling: its relay stops, the hook Symphony created goes, and its steps
  # and test are forgotten, so the setup can finish without it.
  defp apply_action("leave_on_polling", params, ctx) do
    with :ok <- enabled(ctx),
         {:ok, repo} <- repo_param(params, ctx) do
      RelaySupervisor.stop(ctx.relays, repo.key)

      deleted =
        case Map.get(load(ctx).hooks, repo.key) do
          nil -> false
          hook -> delete_hook(hook, ctx) == :ok
        end

      update(ctx, fn record ->
        %{
          record
          | steps: Map.drop(record.steps, ["repo:" <> repo.key, "test:" <> repo.key]),
            tests: Map.delete(record.tests, repo.key),
            hooks: if(deleted, do: Map.delete(record.hooks, repo.key), else: record.hooks)
        }
      end)
    end
  end

  defp apply_action("restart_relay", params, ctx) do
    with :ok <- enabled(ctx),
         :ok <- runs_relay(ctx),
         {:ok, repos} <- test_repos(params, ctx) do
      Enum.each(repos, fn repo -> record_step(ctx, "repo:" <> repo.key, start_relay(repo, ctx)) end)
    end
  end

  defp apply_action("recreate_secret", _params, ctx) do
    with :ok <- enabled(ctx),
         :ok <- step_ok(record_step(ctx, "secret", make_secret(ctx))) do
      Enum.each(connected(load(ctx), ctx), &reconnect(&1, ctx))
    end
  end

  defp apply_action("change_relay", params, ctx) do
    with :ok <- enabled(ctx),
         {:ok, relay} <- relay_param(params),
         {:ok, url} <- optional_url(params, relay),
         :ok <- config_result(ctx, [{["github", "webhooks", "relay"], relay}]) do
      switch_relay(ctx)
      update(ctx, &%{&1 | relay_url: url})
      record_step(ctx, "relay", check("relay", ctx))
      :ok
    end
  end

  defp apply_action("turn_off", _params, ctx) do
    with :ok <- config_result(ctx, [{["github", "webhooks", "enabled"], "false"}]) do
      disconnect(ctx)
      update(ctx, &%{&1 | turned_on_at: nil, steps: Map.take(&1.steps, ["relay", "gh_ready", "secret", "port"]), tests: %{}})
    end
  end

  defp kept_url(_record, "gh_webhook_forward"), do: nil
  defp kept_url(record, _relay), do: record.relay_url

  # The steps that belong to the relay start over; the ones that don't (gh, secret, port) stay.
  defp switch_relay(ctx) do
    disconnect(ctx)
    update(ctx, &%{&1 | relay_url: nil, steps: Map.take(&1.steps, ["gh_ready", "secret", "port"]), tests: %{}})
  end

  # Stops the relays and deletes the hooks Symphony created; a hook it couldn't delete stays
  # listed, so turning off again tries it again.
  defp disconnect(ctx) do
    for key <- RelaySupervisor.repo_keys(ctx.relays), do: RelaySupervisor.stop(ctx.relays, key)

    # GitHub is asked outside the record's lock; only the hooks it deleted leave the record.
    deleted = Enum.filter(load(ctx).hooks, fn {_key, hook} -> delete_hook(hook, ctx) == :ok end)
    update(ctx, &%{&1 | hooks: Map.reject(&1.hooks, fn entry -> entry in deleted end)})
  end

  defp reconnect(repo, ctx) do
    case relay_kind(ctx) do
      "gh_webhook_forward" -> record_step(ctx, "repo:" <> repo.key, start_relay(repo, ctx))
      _url_relay -> record_step(ctx, "repo:" <> repo.key, update_hook_secret(repo, ctx))
    end
  end

  defp check_all(ctx) do
    Enum.each(step_ids(ctx), fn
      "test:" <> _key ->
        :ok

      step ->
        result = check(step, ctx)
        # A repository whose step hasn't run yet stays pending rather than failed.
        if not_run?(step, result, ctx), do: forget_step(ctx, step), else: record_step(ctx, step, result)
    end)
  end

  defp not_run?("repo:" <> key, result, ctx) do
    case find_repo(key, ctx) do
      {:ok, repo} -> result == failure(:not_connected, repo)
      _missing -> false
    end
  end

  defp not_run?(_step, _result, _ctx), do: false

  defp forget_step(ctx, step), do: update(ctx, &%{&1 | steps: Map.delete(&1.steps, step)})

  defp record_step(ctx, step, result) do
    entry =
      case result do
        :ok -> %{status: "done", detail: nil, fix: nil}
        {:pending, detail} -> %{status: "waiting", detail: detail, fix: nil}
        {:error, failure} -> %{status: "failed", detail: failure.detail, fix: failure.fix, action: Map.get(failure, :action)}
      end

    update(ctx, &put_in(&1, [:steps, step], Map.put(entry, :checked_at, ctx.now.())))
    result
  end

  defp step_ok({:error, failure}), do: {:error, {:conflict, failure.detail}}
  defp step_ok(_result), do: :ok

  ## Relay and hooks

  defp check_extension(ctx) do
    case ctx.gh.(["extension", "list"]) do
      {:ok, output} -> if String.contains?(output, @extension), do: :ok, else: failure(:extension)
      {:error, {:gh_unavailable, _message}} -> failure(:no_gh)
      {:error, reason} -> {:error, %{detail: "Symphony couldn't list the GitHub CLI's extensions (#{format_reason(reason)}).", fix: "Run gh extension list in Terminal to see what is wrong."}}
    end
  end

  defp check_relay(repo, ctx) do
    # A relay that isn't running is waiting to start again after an error.
    case RelaySupervisor.status(ctx.relays, repo.key) do
      %{state: :running} -> :ok
      %{last_error: error} -> {:error, relay_failure(repo, error)}
      nil -> failure(:not_connected, repo)
    end
  end

  defp relay_failure(repo, error) do
    if String.contains?(String.downcase(error), "already exists") do
      %{
        detail: "Someone is already forwarding #{repo.github}'s webhooks: GitHub lets one person forward a repository at a time.",
        fix: "Stop the other gh webhook forward for #{repo.github}, or choose a relay with a public URL."
      }
    else
      %{detail: "The relay for #{repo.github} stopped: #{error}", fix: "Symphony starts it again by itself; restart the relay to try now."}
    end
  end

  defp start_relay(repo, ctx) do
    with {:ok, secret} <- secret!(ctx),
         {:ok, port} <- port!(ctx) do
      spec = %{repo_key: repo.key, repo: repo.github, events: ctx.settings.().github.webhooks.events, url: local_url(port), secret: secret}

      case RelaySupervisor.start(ctx.relays, spec) do
        :ok -> check_relay(repo, ctx)
        {:error, _reason} -> {:error, %{detail: "Symphony couldn't start the relay for #{repo.github}.", fix: "Restart Symphony, then run this step again."}}
      end
    end
  end

  defp check_hook(repo, record, ctx) do
    case Map.get(record.hooks, repo.key) do
      %{id: id} ->
        case ctx.gh.(api_args(repo, "hooks/#{id}")) do
          {:ok, _output} -> :ok
          {:error, _reason} -> failure(:hook_gone, repo)
        end

      nil ->
        failure(:not_connected, repo)
    end
  end

  defp ensure_hook(repo, ctx) do
    record = load(ctx)

    with {:error, _failure} <- check_hook(repo, record, ctx),
         {:ok, payload_url} <- payload_url(record.relay_url, relay_kind(ctx)) |> url_failure(ctx),
         # The repository step runs once the secret is there (`ready_for_repo/1`).
         body = hook_body(payload_url, ctx.secret.(), ctx),
         create = api_args(repo, "hooks") ++ ["--method", "POST"],
         {:ok, output} <- ctx |> gh_with_input(create, body) |> gh_failure({:hook_create, repo}),
         {:ok, %{"id" => id}} <- decode(output) do
      update(ctx, &put_in(&1, [:hooks, repo.key], %{id: id, github: repo.github}))
      :ok
    else
      {:ok, _other} -> {:error, %{detail: "GitHub didn't say which hook it created on #{repo.github}.", fix: "Run this step again."}}
      {:error, _failure} = error -> error
      :ok -> :ok
    end
  end

  defp url_failure({:ok, _url} = ok, _ctx), do: ok
  defp url_failure({:error, :no_url}, ctx), do: failure(:relay_url, relay_kind(ctx))

  defp make_secret(ctx) do
    case ctx.hand_off.(WebhookSecret.generate()) do
      :ok ->
        write_secret_setting(ctx)

      {:error, reason} ->
        {:error, %{detail: "Symphony couldn't save the webhook secret (#{format_reason(reason)}).", fix: "Check that Symphony's state folder can be written, then run this step again."}}
    end
  end

  defp write_secret_setting(ctx), do: write_config(ctx, [{["github", "webhooks", "secret"], WebhookSecret.setting()}])

  defp update_hook_secret(repo, ctx) do
    record = load(ctx)

    # Called right after a new secret was handed off.
    # GitHub replaces the whole config on PATCH, so the hook's URL goes with the new secret.
    with %{id: id} <- Map.get(record.hooks, repo.key) || failure(:not_connected, repo),
         {:ok, payload_url} <- payload_url(record.relay_url, relay_kind(ctx)) |> url_failure(ctx),
         %{config: config} = hook_body(payload_url, ctx.secret.(), ctx),
         {:ok, _output} <-
           gh_with_input(ctx, api_args(repo, "hooks/#{id}") ++ ["--method", "PATCH"], %{config: config}) |> gh_failure({:hook_create, repo}) do
      :ok
    end
  end

  defp delete_hook(%{id: id, github: github}, ctx) do
    case ctx.gh.(api_args(%{github: github}, "hooks/#{id}") ++ ["--method", "DELETE"]) do
      {:ok, _output} ->
        :ok

      {:error, {:gh_failed, _args, _status, output}} = error ->
        if String.contains?(output, "Not Found"), do: :ok, else: log_delete(error, github, id)

      error ->
        log_delete(error, github, id)
    end
  end

  defp log_delete(error, github, id) do
    Logger.warning("Instant GitHub updates couldn't delete hook=#{id} github=#{github}: #{format_reason(elem(error, 1))}")
    error
  end

  defp send_test(repo, ctx) do
    case relay_kind(ctx) do
      "gh_webhook_forward" ->
        case RelaySupervisor.restart(ctx.relays, repo.key) do
          :ok -> check_relay(repo, ctx)
          {:error, :not_running} -> start_relay(repo, ctx)
        end

      _url_relay ->
        with %{id: id} <- Map.get(load(ctx).hooks, repo.key) || failure(:not_connected, repo),
             {:ok, _output} <- ctx.gh.(api_args(repo, "hooks/#{id}/pings") ++ ["--method", "POST"]) |> gh_failure({:ping, repo}) do
          :ok
        end
    end
  end

  defp hook_body(payload_url, secret, ctx) do
    %{
      name: "web",
      active: true,
      events: ctx.settings.().github.webhooks.events,
      config: %{url: payload_url, content_type: "json", insecure_ssl: "0", secret: Secret.unwrap(secret)}
    }
  end

  # The body goes through a file only the user can read, so the secret is never an argument. The
  # file is created exclusively: a path someone else made first, or a symlink at it, fails.
  defp gh_with_input(ctx, args, body) do
    file = Path.join(System.tmp_dir!(), "symphony-github-hook-#{System.unique_integer([:positive])}.json")

    with {:ok, device} <- File.open(file, [:write, :exclusive]) do
      try do
        with :ok <- File.chmod(file, 0o600),
             :ok <- IO.binwrite(device, Jason.encode!(body)) do
          File.close(device)
          ctx.gh.(args ++ ["--input", file])
        end
      after
        File.rm(file)
      end
    end
  end

  defp check_admin(repo, ctx) do
    case ctx.gh.(api_args(repo, "") ++ ["--jq", ".permissions.admin"]) do
      {:ok, output} -> if String.trim(output) == "true", do: :ok, else: failure(:admin, repo)
      {:error, _reason} -> failure(:admin, repo)
    end
  end

  defp api_args(%{github: github}, path) do
    {host, repo} = split_host(github)
    suffix = if path == "", do: "", else: "/" <> path
    ["api"] ++ if(host, do: ["--hostname", host], else: []) ++ ["repos/#{repo}#{suffix}"]
  end

  defp split_host(github) do
    case String.split(github, "/") do
      [host, owner, name] -> {host, "#{owner}/#{name}"}
      _owner_name -> {nil, github}
    end
  end

  defp ready_for_repo(ctx) do
    cond do
      ctx.secret.() == nil -> {:error, %{detail: "There is no webhook secret yet.", fix: "Run the secret step first."}}
      relay_kind(ctx) == "gh_webhook_forward" and not is_integer(ctx.port.()) -> failure(:port, nil)
      true -> :ok
    end
  end

  defp secret!(ctx) do
    case ctx.secret.() do
      nil -> failure(:no_secret)
      secret -> {:ok, secret}
    end
  end

  defp port!(ctx) do
    case ctx.port.() do
      port when is_integer(port) and port > 0 -> {:ok, port}
      _none -> failure(:port, nil)
    end
  end

  defp connected?(repo, ctx) do
    if repo in connected(load(ctx), ctx), do: :ok, else: failure(:not_connected, repo)
  end

  # The repositories whose `repo:<key>` step is done on this Mac.
  defp connected(record, ctx) do
    Enum.filter(ctx.repos.(), fn repo -> match?(%{status: "done"}, Map.get(record.steps, "repo:" <> repo.key)) end)
  end

  ## The section

  defp step_ids(ctx) do
    repos = ctx.repos.()
    ["relay", "gh_ready", "secret", "port"] ++ Enum.map(repos, &("repo:" <> &1.key)) ++ Enum.map(repos, &("test:" <> &1.key))
  end

  defp step_entry(step, record, ctx) do
    {kind, key} = step_kind(step)
    repo = key && Enum.find(ctx.repos.(), &(&1.key == key))
    stored = Map.get(record.steps, step)

    status = step_status(kind, step, stored, Map.has_key?(record.tests, key), ctx)

    %{
      id: step,
      kind: kind,
      repo: key,
      title: title(kind, repo, ctx),
      status: status.status,
      detail: Map.get(status, :detail) || done_detail(kind, status.status, ctx),
      fix: Map.get(status, :fix),
      action: Map.get(status, :action),
      checked_at: stored && stored.checked_at
    }
  end

  # Local steps and a running test are checked as the section is read; a connected relay is asked
  # how it runs; the steps that call GitHub show their last result.
  defp step_status("test", _step, stored, false, _ctx), do: stored || pending()
  defp step_status(kind, step, _stored, _tested, ctx) when kind in ["secret", "port", "test"], do: entry_of(check(step, ctx))
  defp step_status("repo", step, %{status: "done"} = stored, _tested, ctx), do: if(forward?(ctx), do: entry_of(check(step, ctx)), else: stored)
  defp step_status(_kind, _step, nil, _tested, _ctx), do: pending()
  defp step_status(_kind, _step, stored, _tested, _ctx), do: stored

  defp pending, do: %{status: "pending", detail: nil, fix: nil}
  defp forward?(ctx), do: relay_kind(ctx) == "gh_webhook_forward"

  defp entry_of(:ok), do: %{status: "done"}
  defp entry_of({:pending, detail}), do: %{status: "waiting", detail: detail}
  defp entry_of({:error, failure}), do: %{status: "failed", detail: failure.detail, fix: failure.fix, action: Map.get(failure, :action)}

  defp step_kind("repo:" <> key), do: {"repo", key}
  defp step_kind("test:" <> key), do: {"test", key}
  defp step_kind(step), do: {step, nil}

  defp title("relay", _repo, _ctx), do: "Choose how GitHub's updates reach this Mac"
  defp title("gh_ready", _repo, _ctx), do: "GitHub CLI signed in, with access to webhooks"
  defp title("secret", _repo, _ctx), do: "Webhook secret saved"
  defp title("port", _repo, _ctx), do: "Symphony's port pinned"
  defp title("repo", repo, _ctx), do: "Webhook on #{github_name(repo)}"
  defp title("test", repo, _ctx), do: "Test delivery from #{github_name(repo)}"

  defp github_name(%{github: github}) when is_binary(github), do: github
  defp github_name(%{key: key}), do: key

  defp done_detail("relay", "done", ctx), do: "Through #{Map.fetch!(@relay_labels, relay_kind(ctx))}"
  defp done_detail("test", "done", _ctx), do: "received and verified"
  defp done_detail(_kind, _status, _ctx), do: nil

  defp repo_entry(repo, record, webhooks, ctx) do
    health = Health.load(ctx.store, repo.key)
    now = ctx.now.()
    connected? = match?(%{status: "done"}, Map.get(record.steps, "repo:" <> repo.key))
    relay = RelaySupervisor.status(ctx.relays, repo.key)
    test = Map.get(record.tests, repo.key)
    degraded_reason = if connected?, do: degraded_reason(health, relay, webhooks, now)

    %{
      key: repo.key,
      github: repo.github,
      connection: if(webhooks.enabled and connected?, do: "webhook", else: "polling"),
      hook: hook_entry(Map.get(record.hooks, repo.key)),
      relay: relay && Map.update!(relay, :state, &Atom.to_string/1),
      test: test && %{sent_at: test.sent_at, verified_at: test.verified_at},
      healthy: Health.healthy?(health, webhooks),
      silent: Health.silent?(health, webhooks, now),
      last_delivery_at: health.last_delivery_at,
      deliveries: health.deliveries,
      signature_failures_24h: Health.signature_failures(health, now),
      missed_at: health.missed_at,
      relay_restarts: (relay && relay.restarts) || 0,
      degraded: degraded_reason != nil,
      degraded_reason: degraded_reason,
      poll_interval_ms: Health.interval_ms(health, webhooks, poll_interval_ms(ctx), relay)
    }
  end

  defp hook_entry(%{id: id}), do: %{id: id, created_by_symphony: true}
  defp hook_entry(nil), do: nil

  # D12: a relay that can't restart or keeps stopping, or nothing heard for the alert's minutes
  # since a read found a change no delivery reported. Why, in plain words; nil while it isn't.
  defp degraded_reason(_health, %{state: :restarting, failures: failures} = relay, _webhooks, _now) when failures >= 2 do
    "The relay can't start again: #{relay.last_error}"
  end

  defp degraded_reason(_health, %{stable: false} = relay, _webhooks, _now) do
    "The relay stopped more than twice in ten minutes (#{relay.last_error}). Symphony polls at the normal interval until it runs ten minutes without a stop."
  end

  defp degraded_reason(health, _relay, webhooks, now) do
    missed = health.missed_at != nil and (health.last_delivery_at == nil or DateTime.after?(health.missed_at, health.last_delivery_at))

    if missed and Health.silent?(health, webhooks, now) do
      "No delivery for #{webhooks.silence_alert_minutes} minutes after a read found a change none reported."
    end
  end

  defp relay_entry(webhooks, record, ctx) do
    kind = webhooks.relay
    port = ctx.port.()

    %{
      kind: kind,
      label: Map.get(@relay_labels, kind, kind),
      runs_in_symphony: kind == "gh_webhook_forward",
      url: if(kind == "gh_webhook_forward", do: nil, else: record.relay_url),
      payload_url: payload_url(record.relay_url, kind) |> ok_or_nil(),
      local_url: if(is_integer(port), do: local_url(port))
    }
  end

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_error), do: nil

  defp mode(_record, %{enabled: false}, _steps, _repos), do: "off"
  defp mode(%{turned_on_at: nil}, _webhooks, _steps, _repos), do: "needs_setup"

  defp mode(_record, _webhooks, steps, repos) do
    connected = Enum.filter(repos, &(&1.connection == "webhook"))

    cond do
      not set_up?(steps, Enum.map(connected, & &1.key)) -> "setting_up"
      Enum.any?(connected, & &1.degraded) -> "degraded"
      true -> "on"
    end
  end

  # Every step this Mac needs is done, and at least one repository connected and verified.
  defp set_up?(_steps, []), do: false
  defp set_up?(steps, connected), do: Enum.all?(steps, &(&1.status == "done" or not needed?(&1, connected)))

  defp needed?(%{kind: "test", repo: key}, connected), do: key in connected
  defp needed?(%{kind: kind}, _connected), do: kind in ["relay", "gh_ready", "secret", "port"]

  ## Failures

  defp failure(:extension), do: {:error, %{detail: "The GitHub CLI's webhook extension isn't installed.", fix: "Run this step: Symphony installs it with gh extension install #{@extension}."}}
  defp failure(:no_gh), do: {:error, %{detail: "The GitHub CLI (gh) isn't installed.", fix: "Install it with brew install gh, sign in with gh auth login, then run this step again."}}
  defp failure(:signed_out), do: {:error, %{detail: "The GitHub CLI isn't signed in.", fix: "Run gh auth login in Terminal, then run this step again.", action: "sign_in"}}

  defp failure(:scope) do
    {:error,
     %{
       detail: "The GitHub CLI is signed in, but can't add webhooks to repositories (it lacks the admin:repo_hook scope).",
       fix: "Run gh auth refresh -h github.com -s admin:repo_hook in Terminal, then run this step again.",
       action: "grant_permission"
     }}
  end

  defp failure(:no_secret), do: {:error, %{detail: "Symphony has no webhook secret on this Mac.", fix: "Run the secret step: Symphony makes one and the app keeps it as #{WebhookSecret.item()}."}}
  defp failure(:no_test), do: {:error, %{detail: "Symphony hasn't sent a test delivery yet.", fix: "Send a test."}}

  defp failure(:relay_url, kind) do
    {:error, %{detail: "Symphony needs the public URL of your #{Map.get(@relay_labels, kind, kind)} relay.", fix: "Run this step with the relay's https URL."}}
  end

  defp failure(:port, port) do
    fix = if is_integer(port), do: "Run this step: Symphony pins dashboard.port to #{port} in symphony.yml.", else: "Start Symphony, then run this step again."
    {:error, %{detail: "Symphony's port changes each time it starts, so the relay would lose it.", fix: fix}}
  end

  defp failure(:port_moved, pinned) do
    {:error, %{detail: "symphony.yml pins dashboard.port to #{pinned}, but Symphony listens on another port.", fix: "Restart Symphony so it listens on #{pinned}.", action: "restart_symphony"}}
  end

  defp failure(:admin, repo) do
    {:error, %{detail: "You need admin access to #{repo.github} to add a webhook.", fix: "Ask an owner of #{repo.github} for admin access, or leave #{repo.key} on polling."}}
  end

  defp failure(:not_connected, repo), do: {:error, %{detail: "#{repo.github} isn't connected yet.", fix: "Run the webhook step for #{repo.key}."}}
  defp failure(:hook_gone, repo), do: {:error, %{detail: "The webhook Symphony added to #{repo.github} is gone.", fix: "Run the webhook step for #{repo.key} again: Symphony adds a new one."}}

  defp waiting(sent_at, ctx) do
    if DateTime.diff(ctx.now.(), sent_at, :second) < @test_timeout_s do
      {:pending, "Waiting for the test delivery."}
    else
      {:error, %{detail: "No test delivery reached Symphony within #{@test_timeout_s} seconds.", fix: "Check that the relay is running and reaches this Mac, then send another test."}}
    end
  end

  defp gh_failure({:ok, _output} = ok, _what), do: ok

  defp gh_failure({:error, reason}, :extension_install) do
    {:error, %{detail: "The GitHub CLI couldn't install its webhook extension (#{format_reason(reason)}).", fix: "Run gh extension install #{@extension} in Terminal."}}
  end

  defp gh_failure({:error, reason}, {:hook_create, repo}) do
    {:error, %{detail: "GitHub refused the webhook on #{repo.github} (#{format_reason(reason)}).", fix: "Check your admin access to #{repo.github}, then run this step again."}}
  end

  defp gh_failure({:error, reason}, {:ping, repo}) do
    {:error, %{detail: "GitHub didn't send the test delivery to #{repo.github} (#{format_reason(reason)}).", fix: "Run the webhook step for #{repo.key}, then send another test."}}
  end

  # A `gh` error names GitHub's last line, never the arguments (an argument file may hold the secret).
  defp format_reason({:gh_failed, _args, status, output}), do: (output |> String.split("\n", trim: true) |> List.last() || "gh exited with #{status}") |> String.slice(0, 200)
  defp format_reason({:gh_unavailable, _message}), do: "the GitHub CLI isn't installed"
  defp format_reason({:not_a_block, key}), do: "#{key}: in symphony.yml is an inline value, not an indented block"
  defp format_reason({:unreadable, _reason}), do: "it doesn't parse as YAML"
  defp format_reason(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  defp format_reason(reason), do: inspect(reason)

  ## Params

  defp relay_param(params) do
    relay = Map.get(params, "relay", "gh_webhook_forward")
    if relay in @relays, do: {:ok, relay}, else: {:error, {:unprocessable, "relay must be one of #{Enum.join(@relays, ", ")}."}}
  end

  defp optional_url(params, relay) do
    case {Map.get(params, "url"), relay} do
      {nil, _relay} -> {:ok, nil}
      {_url, "gh_webhook_forward"} -> {:ok, nil}
      {url, relay} -> with({:error, failure} <- relay_url(url, relay), do: {:error, {:unprocessable, failure.detail}})
    end
  end

  defp relay_url(url, relay) when is_binary(url) do
    url = url |> String.trim() |> String.trim_trailing("/")

    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> {:ok, url}
      _other -> {:error, %{detail: "The #{Map.get(@relay_labels, relay, relay)} URL must be an https:// address, got #{inspect(url)}.", fix: "Copy the relay's public URL again."}}
    end
  end

  defp relay_url(url, relay), do: relay_url(to_string(url), relay)

  # smee's channel URL is where GitHub delivers; a tunnel's public host serves Symphony's own path.
  defp payload_url(nil, _kind), do: {:error, :no_url}
  defp payload_url(url, "smee"), do: {:ok, url}

  defp payload_url(url, _kind) do
    if String.ends_with?(url, @webhook_path), do: {:ok, url}, else: {:ok, url <> @webhook_path}
  end

  defp step_param(%{"step" => step}, ctx) when is_binary(step) do
    if step in step_ids(ctx), do: {:ok, step}, else: {:error, {:not_found, "There is no setup step named #{inspect(step)}."}}
  end

  defp step_param(_params, _ctx), do: {:error, {:unprocessable, "Name the step to run in step."}}

  defp test_repos(params, ctx) do
    connected = connected(load(ctx), ctx)

    case Map.get(params, "repo") do
      nil when connected == [] -> {:error, {:conflict, "No repository is connected yet: run the webhook steps first."}}
      nil -> {:ok, connected}
      key -> connected |> Enum.filter(&(&1.key == key)) |> one_repo(key)
    end
  end

  defp repo_param(%{"repo" => key}, ctx) when is_binary(key) do
    case Enum.find(ctx.repos.(), &(&1.key == key)) do
      nil -> {:error, {:not_found, "There is no repository named #{inspect(key)}."}}
      repo -> {:ok, repo}
    end
  end

  defp repo_param(_params, _ctx), do: {:error, {:unprocessable, "Name the repository in repo."}}

  defp one_repo([], key), do: {:error, {:not_found, "#{inspect(key)} isn't a connected repository."}}
  defp one_repo(repos, _key), do: {:ok, repos}

  defp enabled(ctx) do
    if ctx.settings.().github.webhooks.enabled, do: :ok, else: {:error, {:conflict, "Instant GitHub updates are off. Turn them on first."}}
  end

  defp runs_relay(ctx) do
    if relay_kind(ctx) == "gh_webhook_forward",
      do: :ok,
      else: {:error, {:conflict, "Symphony doesn't run the #{Map.get(@relay_labels, relay_kind(ctx))} relay; restart it where it runs."}}
  end

  ## Config and the record

  defp write_config(ctx, changes) do
    case LineEditor.write(ctx.file, changes) do
      # A same-second edit of the same length keeps the file's stamp, so the cache is told.
      :ok ->
        _ = Cache.invalidate(ctx.file)
        :ok

      {:error, reason} ->
        {:error,
         %{
           detail: "Symphony couldn't change symphony.yml (#{format_reason(reason)}).",
           fix: "Edit #{Enum.map_join(changes, ", ", fn {path, _value} -> Enum.join(path, ".") end)} in symphony.yml by hand."
         }}
    end
  end

  defp config_result(ctx, changes) do
    case write_config(ctx, changes) do
      :ok -> :ok
      {:error, failure} -> {:error, {:config, failure.detail <> " " <> failure.fix}}
    end
  end

  defp relay_kind(ctx), do: ctx.settings.().github.webhooks.relay

  defp find_repo(key, ctx) do
    case Enum.find(ctx.repos.(), &(&1.key == key)) do
      %{github: github} = repo when is_binary(github) -> {:ok, repo}
      %{} -> {:error, %{detail: "Symphony can't tell which GitHub repository #{key} is.", fix: "Give #{key}'s checkout an origin remote on GitHub, or a workspace.source."}}
      nil -> {:error, %{detail: "There is no repository named #{key}.", fix: "Use one of the repositories the section lists."}}
    end
  end

  defp same_repo?(repo_url, github) do
    {_host, repo} = split_host(github)
    repo_url |> String.trim_trailing("/") |> String.downcase() |> String.ends_with?("/" <> String.downcase(repo))
  end

  defp local_url(port), do: "http://127.0.0.1:#{port}#{@webhook_path}"

  defp hook_scope?(output) do
    case Regex.run(~r/Token scopes:\s*(.*)/, output) do
      [_line, scopes] -> Enum.any?(@hook_scopes, &String.contains?(scopes, "'#{&1}'"))
      # A token gh can't list scopes for (fine-grained, or GH_TOKEN): the webhook step finds out.
      nil -> true
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp empty, do: %{turned_on_at: nil, relay_url: nil, hooks: %{}, steps: %{}, tests: %{}}

  defp load(ctx) do
    case ctx.store.get_github_updates(@store_key) do
      %{} = record -> Map.merge(empty(), Map.take(record, Map.keys(empty())))
      _none -> empty()
    end
  end

  defp save(ctx, record) do
    case ctx.store.put_github_updates(@store_key, record) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Instant GitHub updates couldn't keep their setup record: #{inspect(reason)}")
    end
  end

  # Setup actions and webhook deliveries change the record from different processes; the lock
  # keeps one from overwriting what another just stored.
  defp update(ctx, fun) do
    :global.trans(
      {__MODULE__, self()},
      fn ->
        record = load(ctx)
        changed = fun.(record)
        if changed != record, do: save(ctx, changed)
      end,
      [node()]
    )

    :ok
  end

  defp poll_interval_ms(ctx) do
    settings = ctx.settings.()
    settings.pr_review.poll_interval_ms || settings.polling.interval_ms
  end

  defp context(opts) do
    gh_opts = Keyword.take(opts, [:gh_runner])

    %{
      gh: Keyword.get(opts, :gh, fn args -> PullRequest.run_gh(args, gh_opts) end),
      hand_off: Keyword.get(opts, :hand_off, &WebhookSecret.hand_off/1),
      secret: Keyword.get(opts, :secret, &WebhookSecret.current/0),
      store: Keyword.get(opts, :run_store, SymphonyElixir.RunStore),
      relays: Keyword.get(opts, :relays, RelaySupervisor),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      file: Keyword.get_lazy(opts, :symphony_file, &Workflow.symphony_file_path/0),
      repos: Keyword.get(opts, :repos, &configured_repos/0),
      port: Keyword.get(opts, :port, &listening_port/0),
      settings: Keyword.get(opts, :settings, &Config.settings!/0)
    }
  end

  # A configuration that can't be read has no repository to show.
  defp configured_repos, do: for({:ok, repos} <- [Config.repos()], repo <- repos, do: %{key: repo.name, github: RepoStatus.github_repo(repo)})

  defp listening_port, do: HttpServer.bound_port() || Config.settings!().server.port
end
