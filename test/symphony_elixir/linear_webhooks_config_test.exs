defmodule SymphonyElixir.LinearWebhooksConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Secret

  @env "SYMPHONY_LINEAR_WEBHOOK_SECRET"
  @base %{
    "issues" => %{"provider" => "memory"},
    "repositories" => [%{"key" => "web"}],
    "agent" => %{"runtime" => "codex", "command" => "codex app-server"}
  }

  setup do
    previous = System.get_env(@env)
    System.delete_env(@env)
    on_exit(fn -> restore_env(@env, previous) end)
    :ok
  end

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  test "a symphony.yml without the section loads with the webhook off and no secret" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert %Schema.Linear.Webhooks{enabled: false, secret: nil} = Config.linear_webhook_settings()
    assert %Schema.Linear.Webhooks{enabled: false, secret: nil} = Config.system!().linear.webhooks
    assert Config.linear_webhook_settings(Config.settings!()) == Config.linear_webhook_settings()
  end

  test "resolves a $ENV secret like github.webhooks.secret, and keeps a literal as it is" do
    write_workflow_file!(Workflow.workflow_file_path())
    append_symphony_yml!("linear:\n  webhooks:\n    enabled: true\n    secret: $#{@env}\n")

    assert %Schema.Linear.Webhooks{enabled: true, secret: nil} = Config.linear_webhook_settings()

    System.put_env(@env, "from-env")
    Cache.clear()
    assert %Schema.Linear.Webhooks{enabled: true, secret: %Secret{} = secret} = Config.linear_webhook_settings()
    assert Secret.unwrap(secret) == "from-env"
    refute inspect(Config.linear_webhook_settings()) =~ "from-env"

    write_workflow_file!(Workflow.workflow_file_path())
    append_symphony_yml!("linear:\n  webhooks:\n    secret: literal-secret\n")
    assert %Schema.Linear.Webhooks{enabled: false, secret: secret} = Config.linear_webhook_settings()
    assert Secret.unwrap(secret) == "literal-secret"
  end

  test "refuses the webhook turned on without a secret, naming the key" do
    for webhooks <- [%{"enabled" => true}, %{"enabled" => true, "secret" => ""}, %{"enabled" => true, "secret" => "  "}] do
      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(@base, "linear", %{"webhooks" => webhooks}))
      assert message == "linear.webhooks.secret is required when linear.webhooks.enabled is true"
    end

    assert {:ok, %{linear: %{webhooks: %{enabled: false}}}} = SystemSchema.parse(Map.put(@base, "linear", %{"webhooks" => %{"enabled" => false}}))
  end

  test "falls back to the defaults while the config can't be read" do
    File.write!(Workflow.symphony_file_path(), "issues: [\n")
    Cache.clear()

    assert Config.linear_webhook_settings() == %Schema.Linear.Webhooks{}
  end

  test "its keys are symphony.yml settings" do
    keys = SystemSchema.operator_key_paths()

    assert "linear.webhooks.enabled" in keys
    assert "linear.webhooks.secret" in keys
  end
end
