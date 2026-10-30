defmodule SymphonyElixir.TestEnvConfigTest do
  # The test env's config makes the suite deterministic whatever the shell exports.
  use SymphonyElixir.TestSupport

  alias Elixir.Config.Reader, as: ConfigReader

  @config Path.expand("../../config/config.exs", __DIR__)
  @secrets ~w(LINEAR_API_KEY LINEAR_ASSIGNEE OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY
              GH_TOKEN GITHUB_TOKEN SLACK_WEBHOOK_URL SLACK_BOT_TOKEN WEBHOOK_URL)

  test "clears every secret the developer's shell exports before the app boots, and routes Req through the guard" do
    previous = Map.new(@secrets, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)
    Enum.each(@secrets, &System.put_env(&1, "from-the-shell"))

    config = ConfigReader.read!(@config, env: :test)

    assert Enum.filter(@secrets, &System.get_env/1) == []
    assert config[:req][:default_options] == [adapter: SymphonyElixir.OutboundGuard]
  end

  test "leaves the shell alone outside the test env" do
    previous = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)
    System.put_env("LINEAR_API_KEY", "from-the-shell")

    config = ConfigReader.read!(@config, env: :prod)

    assert System.get_env("LINEAR_API_KEY") == "from-the-shell"
    refute config[:req]
  end
end
