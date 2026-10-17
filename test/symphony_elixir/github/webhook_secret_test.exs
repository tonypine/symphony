defmodule SymphonyElixir.GitHub.WebhookSecretTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.WebhookSecret
  alias SymphonyElixir.{Paths, Secret}

  @env "SYMPHONY_GITHUB_WEBHOOK_SECRET"

  setup do
    root = Path.join(System.tmp_dir!(), "webhook-secret-#{System.unique_integer([:positive])}")
    previous_root = System.get_env("SYMPHONY_STATE_ROOT")
    previous_secret = System.get_env(@env)
    System.put_env("SYMPHONY_STATE_ROOT", root)
    System.delete_env(@env)

    on_exit(fn ->
      restore_env("SYMPHONY_STATE_ROOT", previous_root)
      restore_env(@env, previous_secret)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "names the variable, the setting and the app's item, never a value" do
    assert WebhookSecret.env() == @env
    assert WebhookSecret.setting() == "$" <> @env
    assert WebhookSecret.item() == "symphony-github-webhook"
  end

  test "a new secret is 32 random bytes in hex" do
    first = WebhookSecret.generate()
    assert Secret.unwrap(first) =~ ~r/\A[0-9a-f]{64}\z/
    refute Secret.unwrap(first) == Secret.unwrap(WebhookSecret.generate())
    assert inspect(first) == "#Secret<[FILTERED]>"
  end

  test "the hand-off writes the state root's secret file, readable only by the user, and the service's variable" do
    secret = WebhookSecret.generate()

    assert WebhookSecret.hand_off(secret) == :ok
    file = Paths.github_webhook_secret_file()
    assert File.read!(file) == Secret.unwrap(secret)
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert System.get_env(@env) == Secret.unwrap(secret)
    assert file |> Path.dirname() |> File.ls!() == ["github_webhook_secret"]
  end

  test "the current secret is the variable, else the handed-off file", %{root: root} do
    write_workflow_file!(Workflow.workflow_file_path(), github: %{webhooks: %{enabled: true, secret: "$" <> @env}})
    assert WebhookSecret.current() == nil

    File.mkdir_p!(root)
    File.write!(Paths.github_webhook_secret_file(), "from-file\n")
    assert Secret.unwrap(WebhookSecret.current()) == "from-file"

    System.put_env(@env, "from-env")
    assert Secret.unwrap(WebhookSecret.current()) == "from-env"
  end

  test "a hand-off that can't write leaves no file behind", %{root: root} do
    File.mkdir_p!(Path.dirname(root))
    File.write!(root, "a file where the folder should be")

    assert {:error, _reason} = WebhookSecret.hand_off(WebhookSecret.generate())
    assert System.get_env(@env) == nil
  end
end
