defmodule SymphonyElixir.Linear.WebhookTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.Linear.Webhooks
  alias SymphonyElixir.Linear.Webhook
  alias SymphonyElixir.Secret

  @secret "lin_wh_test_secret"
  @now ~U[2026-10-29 06:00:00.000Z]

  defp body(timestamp_ms), do: Jason.encode!(%{"action" => "update", "type" => "Issue", "webhookTimestamp" => timestamp_ms})
  defp now_ms, do: DateTime.to_unix(@now, :millisecond)
  defp sign(body, secret \\ @secret), do: :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)

  defp verify(body, headers, opts \\ []), do: Webhook.verify(body, headers, Keyword.merge([secret: Secret.wrap(@secret), now: @now], opts))

  describe "verify/3" do
    test "accepts a body signed with the secret and stamped within sixty seconds, either side of now" do
      for offset <- [0, -60_000, 60_000, -1] do
        body = body(now_ms() + offset)
        assert verify(body, [{"linear-signature", sign(body)}]) == :ok
      end

      body = body(now_ms())
      assert verify(body, %{"Linear-Signature" => " " <> String.upcase(sign(body)) <> "\n"}) == :ok
    end

    test "refuses a wrong signature: another secret, another body, or not hex" do
      body = body(now_ms())

      assert verify(body, [{"linear-signature", sign(body, "other")}]) == {:error, :bad_signature}
      assert verify(body, [{"linear-signature", sign(body(now_ms() - 1))}]) == {:error, :bad_signature}
      assert verify(body, [{"linear-signature", "sha256=" <> sign(body)}]) == {:error, :bad_signature}
    end

    test "refuses a delivery without the header, or with an empty one" do
      body = body(now_ms())

      assert verify(body, []) == {:error, :missing_signature}
      assert verify(body, [{"x-hub-signature-256", "sha256=" <> sign(body)}]) == {:error, :missing_signature}
      assert verify(body, %{"linear-signature" => "  "}) == {:error, :missing_signature}
    end

    test "refuses a timestamp older or newer than sixty seconds, and a body without a readable one" do
      for body <- [body(now_ms() - 60_001), body(now_ms() + 60_001), body("#{now_ms()}"), ~s({"action":"update"}), "not json", "[]"] do
        assert verify(body, [{"linear-signature", sign(body)}]) == {:error, :stale_timestamp}
      end
    end

    test "refuses every delivery while no secret is set, before reading the signature" do
      body = body(now_ms())

      assert verify(body, [{"linear-signature", sign(body)}], secret: nil) == {:error, :missing_secret}
      assert verify(body, [], secret: nil) == {:error, :missing_secret}
    end

    test "uses the configured secret and the current time by default" do
      previous = System.get_env("SYMPHONY_LINEAR_WEBHOOK_SECRET")
      on_exit(fn -> restore_env("SYMPHONY_LINEAR_WEBHOOK_SECRET", previous) end)

      write_workflow_file!(Workflow.workflow_file_path())
      body = body(System.system_time(:millisecond))
      assert Webhook.verify(body, [{"linear-signature", sign(body)}]) == {:error, :missing_secret}

      path = Workflow.symphony_file_path()
      File.write!(path, File.read!(path) <> "linear:\n  webhooks:\n    enabled: true\n    secret: $SYMPHONY_LINEAR_WEBHOOK_SECRET\n")
      System.put_env("SYMPHONY_LINEAR_WEBHOOK_SECRET", @secret)
      Cache.clear()

      assert Webhook.verify(body, [{"linear-signature", sign(body)}]) == :ok
      assert Webhook.verify(body, [{"linear-signature", sign(body, "other")}]) == {:error, :bad_signature}
    end
  end

  test "settings/0 reads linear.webhooks, and secret/1 is nil until the secret resolves" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert Webhook.settings() == %Webhooks{}
    assert Webhook.secret(%Webhooks{}) == nil
    assert Webhook.secret(%Webhooks{secret: Secret.wrap(@secret)}) |> Secret.unwrap() == @secret
    assert Webhook.secret(%Webhooks{secret: @secret}) |> Secret.unwrap() == @secret
  end
end
