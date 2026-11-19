defmodule SymphonyElixir.ConductorConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Runs, Schema, SystemSchema}

  @base %{
    "issues" => %{"provider" => "memory"},
    "repositories" => [%{"key" => "web"}],
    "execution" => %{"harnesses" => %{"codex" => %{"command" => "codex app-server"}, "claude" => %{"command" => "claude", "small_model" => %{"anthropic" => "haiku"}}}},
    "runs" => %{"default" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-test"}}
  }

  test "is off, at every junction, for three minutes, when the section is missing" do
    assert {:ok, %{conductor: conductor}} = SystemSchema.parse(@base)
    assert conductor == %Schema.Conductor{enabled: false, junctions: ~w(after_coding after_qa_fail after_rework before_merge), timeout_ms: 180_000}
    assert Schema.Conductor.junctions() == ~w(after_coding after_qa_fail after_rework before_merge)
  end

  test "reads the section, and refuses an unknown key, an unknown junction or a timeout of 0" do
    assert {:ok, %{conductor: %{enabled: true, junctions: ["before_merge"], timeout_ms: 60_000}}} =
             SystemSchema.parse(Map.put(@base, "conductor", %{"enabled" => true, "junctions" => ["before_merge"], "timeout_ms" => 60_000}))

    assert {:ok, %{conductor: %{junctions: []}}} = SystemSchema.parse(Map.put(@base, "conductor", %{"junctions" => []}))

    assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `conductor.model`"}} =
             SystemSchema.parse(Map.put(@base, "conductor", %{"model" => "x"}))

    assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(@base, "conductor", %{"junctions" => ["whenever"]}))
    assert message =~ "conductor.junctions must name only after_coding"

    assert {:error, {:invalid_symphony_config, "conductor.timeout_ms must be greater than 0"}} =
             SystemSchema.parse(Map.put(@base, "conductor", %{"timeout_ms" => 0}))
  end

  test "its keys are symphony.yml settings, which the macOS app must edit" do
    keys = SystemSchema.operator_key_paths()

    for key <- ~w(conductor.enabled conductor.junctions conductor.timeout_ms), do: assert(key in keys)
    refute "phases.conductor.steps" in keys
  end

  test "runs.conductor picks the turn's harness, provider and model, else runs.default" do
    harnesses = %{"codex" => %{command: "codex app-server", small_model: %{}}, "claude" => %{command: "claude", small_model: %{"anthropic" => "haiku"}}}

    assert {:ok, %{kind: :conductor, harness: "codex", model: "gpt-test"}} = Runs.resolve(nil, @base["runs"], harnesses, "conductor")

    runs = Map.put(@base["runs"], "conductor", %{"harness" => "claude", "provider" => "anthropic", "model" => "claude-opus-5-5", "effort" => "high"})
    assert {:ok, %{kind: :conductor, harness: "claude", model: "claude-opus-5-5", effort: "high"}} = Runs.resolve(nil, runs, harnesses, "conductor")
    assert {:ok, _system} = SystemSchema.parse(Map.put(@base, "runs", runs))
  end
end
