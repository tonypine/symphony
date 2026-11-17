defmodule SymphonyElixir.AgentProviders do
  @moduledoc """
  What Symphony knows about each provider that can serve a run's model: its name for a person,
  the env variable that carries its API key, and how each harness points at it.

    * `claude` reaches a provider through `ANTHROPIC_BASE_URL` (`claude_base_url/1`); nil means
      claude's own endpoint.
    * `codex` reaches a provider through the `--config` overrides `codex_config_overrides/2`
      builds, which define the provider's table and select it; none means codex's own defaults.

  Which harness reaches which provider is `SymphonyElixir.Harnesses`'s. A new provider is an
  entry there and its facts here; nothing else names a provider.
  """

  @type provider :: String.t()

  @opencode_go_claude_base_url "https://opencode.ai/inference/go/anthropic"
  @opencode_go_codex_base_url "https://opencode.ai/inference/go/openai/v1"
  @opencode_go_key_env "OPENCODE_API_KEY"

  @doc "The provider's name for a person, in messages: `OpenRouter` rather than its id."
  @spec display_name(provider()) :: String.t()
  def display_name("anthropic"), do: "Anthropic"
  def display_name("openai"), do: "OpenAI"
  def display_name("openrouter"), do: "OpenRouter"
  def display_name("opencode-go"), do: "OpenCode Go"
  def display_name(provider), do: provider

  @doc """
  The env variable that carries `provider`'s API key, or nil when Symphony passes none: the
  harness signs in to its own provider by itself.
  """
  @spec api_key_env(provider()) :: String.t() | nil
  def api_key_env("openrouter"), do: "OPENROUTER_API_KEY"
  def api_key_env("opencode-go"), do: @opencode_go_key_env
  def api_key_env(_provider), do: nil

  @doc """
  The base URL the claude harness points `ANTHROPIC_BASE_URL` at, or nil for claude's own
  endpoint. OpenRouter's comes from `OpenRouter.base_url/1`, which answers the QA stub's URL in
  QA mode.
  """
  @spec claude_base_url(provider()) :: String.t() | nil
  def claude_base_url("openrouter"), do: SymphonyElixir.OpenRouter.base_url()
  def claude_base_url("opencode-go"), do: @opencode_go_claude_base_url
  def claude_base_url(_provider), do: nil

  @doc """
  The config overrides that point the codex harness at `provider` running `model`, or an empty
  list when codex's own defaults serve the run. Each is a `key=value` string with its TOML
  quotes, the form codex's `--config` takes and `Codex.AppServer` splices in before the
  `app-server` subcommand: the provider table's entries and the `model_provider` that selects
  it. Codex appends `/responses` to the Go base URL and reads the key from the `env_key`.
  """
  @spec codex_config_overrides(provider(), String.t() | nil) :: [String.t()]
  def codex_config_overrides("opencode-go", model) do
    [
      "model_provider=opencode-go",
      ~s(model_providers.opencode-go.name="OpenCode Go"),
      ~s(model_providers.opencode-go.base_url="#{@opencode_go_codex_base_url}"),
      ~s(model_providers.opencode-go.env_key="#{@opencode_go_key_env}"),
      ~s(model_providers.opencode-go.wire_api="responses")
    ] ++ model_overrides(model)
  end

  def codex_config_overrides(_provider, model), do: model_overrides(model)

  defp model_overrides(nil), do: []
  defp model_overrides(model), do: [~s(model="#{model}")]
end
