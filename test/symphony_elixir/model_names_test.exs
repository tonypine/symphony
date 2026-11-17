defmodule SymphonyElixir.ModelNamesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ModelNames

  test "a model id reads as the model's name" do
    assert ModelNames.display_name("claude-opus-5-5") == "Claude Opus 5.5"
    assert ModelNames.display_name("claude-sonnet-5-5") == "Claude Sonnet 5.5"
    assert ModelNames.display_name("claude-fable-5-2") == "Claude Fable 5.2"
    assert ModelNames.display_name("claude-opus-4-1") == "Claude Opus 4.1"
    assert ModelNames.display_name("gpt-5.1-codex") == "GPT 5.1 Codex"
    assert ModelNames.display_name("glm-4-6") == "GLM 4.6"
  end

  test "a release date and a provider's prefix are left out" do
    assert ModelNames.display_name("claude-haiku-4-5-20251001") == "Claude Haiku 4.5"
    assert ModelNames.display_name("anthropic/claude-opus-5-5") == "Claude Opus 5.5"
    assert ModelNames.display_name(" openrouter/deepseek/deepseek-v3 ") == "Deepseek V3"
  end

  test "an eight-letter word at the end is no date" do
    assert ModelNames.display_name("model-nightowl") == "Model Nightowl"
  end

  test "nothing to name reads nil" do
    assert ModelNames.display_name(nil) == nil
    assert ModelNames.display_name("  ") == nil
    assert ModelNames.display_name("anthropic/") == nil
    assert ModelNames.display_name("--") == ""
  end
end
