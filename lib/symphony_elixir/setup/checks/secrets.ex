defmodule SymphonyElixir.Setup.Checks.Secrets do
  @moduledoc """
  The secrets the config names but the service can't read (H3). It only asks whether each one is
  set and never reads a value into a problem: a problem names the variable and the key that names
  it. The operator adds a secret in Settings › Secrets, so every fix opens Settings.

    * The Linear API key (`issues.linear.api_key`, else `LINEAR_API_KEY`). Without it Setup also
      lists the Linear-side checks under `not_checked` (`linear_api_key?/0`).
    * `OPENROUTER_API_KEY`, when a run kind's profile resolves to `openrouter`. The model checks
      stay in `symphony check`.
    * Each whole-value `$NAME` reference in `symphony.yml` whose variable is unset or empty: an MCP server's
      `env` and `headers`, a notification channel's `url`, `webhook_url` and `headers`, and
      `github.webhooks.secret` (only while no handed-off secret file stands in for it). An MCP
      server still gets the literal `$NAME`; this problem is the signal.
    * The GitHub CLI signed in (`gh auth status`), when a repo is a `workspace.source` repo
      Symphony clones and works on through `gh`.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.{Config, Paths, Secret}
  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Setup.Problem

  @env_reference ~r/\A\$([A-Za-z_][A-Za-z0-9_]*)\z/
  @linear_api_key_env "LINEAR_API_KEY"

  @impl true
  def id, do: "secret"

  @impl true
  def title, do: "Secrets the config names"

  @impl true
  def needs_linear?, do: false

  @doc """
  Whether Symphony has what it needs to read Linear: an API key, or the memory tracker, which
  stands in for Linear in tests and needs none. False when the config does not load.
  """
  @spec linear_api_key?() :: boolean()
  def linear_api_key?, do: linear_key() in [:not_needed, :set]

  @impl true
  def run(%{system: nil}), do: []

  def run(context) do
    raw = raw_symphony(context.symphony_path)
    linear_problems(raw) ++ openrouter_problems(context.system) ++ reference_problems(raw) ++ github_problems(context.system)
  end

  defp linear_key do
    case Config.settings() do
      {:ok, %{tracker: %{kind: "memory"}}} -> :not_needed
      {:ok, %{tracker: %{api_key: key}}} -> if Secret.present?(key), do: :set, else: :missing
      {:error, _reason} -> :unknown
    end
  end

  defp linear_problems(raw) do
    if linear_key() == :missing do
      variables = Enum.uniq(List.wrap(env_reference(get_in(raw, ["issues", "linear", "api_key"]))) ++ [@linear_api_key_env])

      [
        Problem.new(
          id: "#{id()}:#{@linear_api_key_env}",
          severity: :error,
          category: :secrets,
          title: "Symphony can't read Linear: no ticket is picked up",
          consequence: "Without a Linear API key Symphony reads no tickets, so nothing runs, and Setup can't check the Linear teams, states and labels.",
          details: [Key: "issues.linear.api_key", Variable: Enum.join(variables, " or ")],
          fix: Problem.open(:settings)
        )
      ]
    else
      []
    end
  end

  defp openrouter_problems(system) do
    uses =
      for repo <- system.repos, {:ok, settings} <- [Config.settings_for_repo(repo.name)], kind <- Config.openrouter_run_kinds(settings), do: {repo.name, kind}

    if uses == [] or not is_nil(Config.openrouter_api_key()) do
      []
    else
      env = Config.openrouter_api_key_env()
      kinds = uses |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.join(", ")

      [
        Problem.new(
          id: "#{id()}:#{env}",
          severity: :error,
          category: :secrets,
          title: "#{env} is not set",
          consequence: "Runs that use OpenRouter fail to start: #{kinds}.",
          repos: uses |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          details: [Variable: env, "Run kinds": kinds],
          fix: Problem.open(:settings)
        )
      ]
    end
  end

  defp reference_problems(raw) do
    references = mcp_references(raw) ++ notification_references(raw) ++ webhook_references(raw)

    for {path, name, consequence} <- references, unset?(name) do
      Problem.new(
        id: "#{id()}:#{path}",
        severity: :error,
        category: :secrets,
        title: "#{path} names $#{name}, which isn't set",
        consequence: consequence,
        details: [Key: path, Variable: name],
        fix: Problem.open(:settings)
      )
    end
  end

  defp mcp_references(raw) do
    for {server, declaration} <- sorted_map(get_in(raw, ["agent", "mcp", "servers"])),
        {field, what} <- [{"env", "#{server} MCP server starts"}, {"headers", "#{server} MCP server is called"}],
        {key, value} <- sorted_map(declaration[field]),
        name = env_reference(value),
        name != nil do
      {"agent.mcp.servers.#{server}.#{field}.#{key}", name, "The #{what} without a value for #{key}, so its calls may fail."}
    end
  end

  defp notification_references(raw) do
    channels = get_in(raw, ["notifications", "channels"]) || []
    for {channel, index} <- Enum.with_index(channels), reference <- channel_references(channel, index), do: reference
  end

  defp channel_references(channel, index) do
    prefix = "notifications.channels[#{index}]"
    name = "the #{channel["kind"] || "notification"} channel #{prefix}"

    urls =
      for field <- ["url", "webhook_url"], reference = env_reference(channel[field]), reference != nil, do: {"#{prefix}.#{field}", reference, "Notifications to #{name} never send."}

    headers =
      for {key, value} <- sorted_map(channel["headers"]),
          reference = env_reference(value),
          reference != nil,
          do: {"#{prefix}.headers.#{key}", reference, "Notifications to #{name} are sent without their #{key} header."}

    urls ++ headers
  end

  # A handed-off secret file stands in for an unset variable (`SymphonyElixir.GitHub.Webhook.secret/1`).
  defp webhook_references(raw) do
    case env_reference(get_in(raw, ["github", "webhooks", "secret"])) do
      nil ->
        []

      name ->
        if File.exists?(Paths.github_webhook_secret_file()),
          do: [],
          else: [{"github.webhooks.secret", name, "Symphony can't check GitHub's webhook deliveries, so it refuses them and learns of pull request changes only when it polls."}]
    end
  end

  defp github_problems(system) do
    case for(%{name: name, workspace: %{github: github}} <- system.repos, is_binary(github), do: name) do
      [] -> []
      repos -> gh_problems(repos)
    end
  end

  defp gh_problems(repos) do
    case PullRequest.run_gh(["auth", "status"], gh_runner: Application.get_env(:symphony_elixir, :setup_gh_runner)) do
      {:ok, _output} ->
        []

      {:error, reason} ->
        [
          Problem.new(
            id: "#{id()}:github_auth",
            severity: :error,
            category: :secrets,
            title: gh_title(reason),
            consequence: "Symphony works on #{Enum.join(repos, ", ")} through the GitHub CLI, so it can't open, update or merge their pull requests.",
            repos: repos,
            fix: Problem.open(:settings)
          )
        ]
    end
  end

  defp gh_title({:gh_unavailable, _message}), do: "The GitHub CLI (gh) isn't installed"
  defp gh_title(_reason), do: "The GitHub CLI isn't signed in to GitHub"

  defp raw_symphony(path) do
    case Cache.get_symphony(path) do
      {:error, _reason} -> nil
      result -> elem(result, 1)
    end
  end

  defp env_reference(value) when is_binary(value) do
    case Regex.run(@env_reference, value) do
      [_reference, name] -> name
      nil -> nil
    end
  end

  defp env_reference(_value), do: nil

  # An empty variable resolves to nothing, as an unset one does.
  defp unset?(name), do: String.trim(System.get_env(name) || "") == ""

  defp sorted_map(map) when is_map(map), do: map |> Enum.map(fn {key, value} -> {to_string(key), value} end) |> Enum.sort()
  defp sorted_map(_map), do: []
end
