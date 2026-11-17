defmodule SymphonyElixir.AgentProvidersTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentProviders

  test "names each provider for a person" do
    assert AgentProviders.display_name("anthropic") == "Anthropic"
    assert AgentProviders.display_name("openai") == "OpenAI"
    assert AgentProviders.display_name("openrouter") == "OpenRouter"
    assert AgentProviders.display_name("opencode-go") == "OpenCode Go"
    assert AgentProviders.display_name("bedrock") == "bedrock"
  end

  test "the key env names the provider that needs one" do
    assert AgentProviders.api_key_env("openrouter") == "OPENROUTER_API_KEY"
    assert AgentProviders.api_key_env("opencode-go") == "OPENCODE_API_KEY"
    assert AgentProviders.api_key_env("anthropic") == nil
    assert AgentProviders.api_key_env("openai") == nil
  end

  test "claude reaches a provider other than its own through a base URL" do
    assert AgentProviders.claude_base_url("anthropic") == nil
    assert AgentProviders.claude_base_url("opencode-go") == "https://opencode.ai/inference/go/anthropic"
    assert AgentProviders.claude_base_url("openrouter") == SymphonyElixir.OpenRouter.base_url()
  end

  test "codex reaches OpenCode Go through config overrides that define and select the provider" do
    assert AgentProviders.codex_config_overrides("opencode-go", "kimi-k3") == [
             "model_provider=opencode-go",
             ~s(model_providers.opencode-go.name="OpenCode Go"),
             ~s(model_providers.opencode-go.base_url="https://opencode.ai/inference/go/openai/v1"),
             ~s(model_providers.opencode-go.env_key="OPENCODE_API_KEY"),
             ~s(model_providers.opencode-go.wire_api="responses"),
             ~s(model="kimi-k3")
           ]

    assert AgentProviders.codex_config_overrides("opencode-go", nil) |> length() == 5
  end

  test "codex on its own provider only takes the model" do
    assert AgentProviders.codex_config_overrides("openai", "gpt-5.5") == [~s(model="gpt-5.5")]
    assert AgentProviders.codex_config_overrides("openai", nil) == []
  end
end
