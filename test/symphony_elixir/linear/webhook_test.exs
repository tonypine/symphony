defmodule SymphonyElixir.Linear.WebhookTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.Linear.Webhooks
  alias SymphonyElixir.Linear.{Issue, Webhook}
  alias SymphonyElixir.Secret

  @secret "lin_wh_test_secret"
  @now ~U[2026-10-29 06:00:00.000Z]
  @fixtures Path.expand("../../fixtures/linear_webhook", __DIR__)

  defp body(timestamp_ms), do: Jason.encode!(%{"action" => "update", "type" => "Issue", "webhookTimestamp" => timestamp_ms})
  defp delivery(name), do: @fixtures |> Path.join(name) |> File.read!()
  defp now_ms, do: DateTime.to_unix(@now, :millisecond)
  defp sign(body, secret \\ @secret), do: :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)

  # Every key or index path in a decoded delivery, outermost first.
  defp paths(%{} = map), do: Enum.flat_map(map, fn {key, value} -> [[key] | Enum.map(paths(value), &[key | &1])] end)

  defp paths(list) when is_list(list) do
    list |> Enum.with_index() |> Enum.flat_map(fn {value, index} -> [[index] | Enum.map(paths(value), &[index | &1])] end)
  end

  defp paths(_leaf), do: []

  defp put_at(map, [key], value) when is_map(map), do: Map.put(map, key, value)
  defp put_at(map, [key | rest], value) when is_map(map), do: Map.update!(map, key, &put_at(&1, rest, value))
  defp put_at(list, [index], value), do: List.replace_at(list, index, value)
  defp put_at(list, [index | rest], value), do: List.update_at(list, index, &put_at(&1, rest, value))

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

  describe "parse/1" do
    test "reads an issue update as the ticket, in Symphony's own struct, and when it changed" do
      assert {:issue, :update, %Issue{} = issue, ~U[2026-10-29 09:15:02.118Z]} = Webhook.parse(delivery("issue_update.json"))

      assert %Issue{identifier: "TP-1213", state: "In Progress", labels: ["elixir", "reads"], priority: 1} = issue
      assert issue.id == "5a7c1f9e-3b2d-4c8a-9e6f-1d2b3c4d5e6f"
      assert issue.title == "Webhook payloads become Issue facts"
      assert issue.assignee_id == "e4f5a6b7-c8d9-4e0f-9a1b-3c4d5e6f7a8b"
      assert issue.comments == :unknown
      assert issue.sub_issues == :unknown
    end

    test "reads an issue create, and takes a body already decoded" do
      body = delivery("issue_create.json")

      assert {:issue, :create, %Issue{identifier: "TP-1213", state: "Todo", description: nil}, ~U[2026-10-28 14:02:11.204Z]} =
               Webhook.parse(body)

      assert Webhook.parse(Jason.decode!(body)) == Webhook.parse(body)
    end

    test "reads an issue remove as its id and identifier" do
      assert Webhook.parse(delivery("issue_remove.json")) == {:issue_removed, "5a7c1f9e-3b2d-4c8a-9e6f-1d2b3c4d5e6f", "TP-1213"}

      remove = %{"type" => "Issue", "action" => "remove", "data" => %{"id" => "i1"}}
      assert Webhook.parse(remove) == {:issue_removed, "i1", nil}
    end

    test "reads a comment as its action, its issue's id and the comment" do
      assert Webhook.parse(delivery("comment_create.json")) ==
               {:comment, :create, "5a7c1f9e-3b2d-4c8a-9e6f-1d2b3c4d5e6f",
                %{
                  id: "7c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f",
                  author: "Ada Operator",
                  body: "Ship the normaliser first, then the parser.",
                  created_at: ~U[2026-10-29 09:20:41.377Z]
                }}

      nested = %{"type" => "Comment", "action" => "remove", "data" => %{"id" => "c1", "issue" => %{"id" => "i1"}}}
      assert {:comment, :remove, "i1", %{id: "c1", body: ""}} = Webhook.parse(nested)
    end

    test "ignores every other type, and an action it doesn't know" do
      assert Webhook.parse(delivery("project_update.json")) == :ignored
      assert Webhook.parse(%{"type" => "Reaction"}) == :ignored
      assert Webhook.parse(%{"type" => "Issue", "action" => "restore", "data" => %{"id" => "i1"}}) == :ignored
    end

    test "calls a body malformed, without raising, when it isn't JSON or lacks what its type needs" do
      malformed = [
        "",
        "{not json",
        "[1, 2]",
        "null",
        42,
        %{},
        %{"type" => 7, "action" => "update", "data" => %{}},
        %{"type" => "Issue"},
        %{"type" => "Issue", "action" => "update", "data" => "TP-1"},
        %{"type" => "Issue", "action" => "update", "data" => %{"identifier" => "TP-1", "updatedAt" => "2026-10-29T09:00:00Z"}},
        %{"type" => "Issue", "action" => "update", "data" => %{"id" => "i1", "updatedAt" => "2026-10-29T09:00:00Z"}},
        %{"type" => "Issue", "action" => "create", "data" => %{"id" => "i1", "identifier" => "TP-1"}},
        %{"type" => "Issue", "action" => "remove", "data" => %{"identifier" => "TP-1"}},
        %{"type" => "Comment", "action" => "create", "data" => %{"id" => "c1", "body" => "hi"}},
        %{"type" => "Comment", "action" => "create", "data" => %{"issueId" => "i1", "body" => "hi"}},
        %{"type" => "Comment", "action" => "create", "data" => %{"id" => "c1", "issue" => "i1"}},
        %{"type" => "Comment", "action" => "create", "data" => %{"id" => "c1", "issue" => ["i1"]}}
      ]

      for body <- malformed do
        assert Webhook.parse(body) == {:error, :malformed}, "expected #{inspect(body)} to be malformed"
      end
    end

    test "reads a state or a blocker's state of the wrong shape as nothing, without raising" do
      blocker = %{"type" => "blocks", "issue" => %{"id" => "b1", "identifier" => "TP-2", "state" => "Done"}}
      data = %{"id" => "i1", "identifier" => "TP-1", "updatedAt" => "2026-10-29T09:00:00Z", "inverseRelations" => [blocker]}

      for state <- ["Todo", ["Todo"], 7] do
        delivery = %{"type" => "Issue", "action" => "update", "data" => Map.put(data, "state", state)}

        assert {:issue, :update, %Issue{identifier: "TP-1", state: nil, blocked_by: [%{identifier: "TP-2", state: nil}]}, _at} =
                 Webhook.parse(delivery)
      end
    end

    test "never raises, whatever shape any value in a delivery takes" do
      relation = %{"type" => "blocks", "issue" => %{"id" => "b1", "identifier" => "TP-2", "state" => %{"name" => "Done"}}}

      deliveries =
        [
          "issue_update.json" |> delivery() |> Jason.decode!() |> put_in(["data", "inverseRelations"], [relation]),
          "issue_create.json" |> delivery() |> Jason.decode!() |> put_in(["data", "branchName"], "auto/TP-1213")
        ] ++ Enum.map(["issue_remove.json", "comment_create.json", "project_update.json"], &(&1 |> delivery() |> Jason.decode!()))

      odd_values = ["Todo", "", ["Todo"], [%{}], 7, nil, true, %{}, %{"name" => 7, "id" => 7}]

      for delivery <- deliveries, path <- paths(delivery), value <- odd_values do
        odd = put_at(delivery, path, value)
        result = Webhook.parse(odd)

        assert match?({:issue, action, %Issue{}, %DateTime{}} when action in [:create, :update], result) or
                 match?({:issue_removed, id, _identifier} when is_binary(id), result) or
                 match?({:comment, _action, issue_id, %{id: _id}} when is_binary(issue_id), result) or
                 result in [:ignored, {:error, :malformed}],
               "#{inspect(value)} at #{inspect(path)} gave #{inspect(result)}"
      end
    end
  end
end
