defmodule SymphonyElixirWeb.LinearWebhookControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 3, json_response: 2]

  alias SymphonyElixir.Linear.Webhook.Deliveries
  alias SymphonyElixir.TicketObservation

  @endpoint SymphonyElixirWeb.Endpoint
  @secret "lin_wh_test_secret"

  # Answers `GET /api/v1/state` with an idle snapshot.
  defmodule IdleOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, %{running: [], retrying: [], rate_limits: nil}, state}
  end

  setup do
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: IdleOrchestrator, start: {IdleOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    Deliveries.reset()
    TicketObservation.reset()

    on_exit(fn ->
      Deliveries.reset()
      TicketObservation.reset()
      Application.delete_env(:symphony_elixir, :linear_webhook_observation_opts)
    end)

    configure_webhooks!(true)
    :ok
  end

  test "answers 404 while Linear webhooks are off, and counts nothing" do
    configure_webhooks!(false)
    body = delivery_body(%{"type" => "Issue", "action" => "update", "data" => %{"identifier" => "TP-7"}})

    conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body)}])
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

    conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", "00"}])
    assert json_response(conn, 404)

    assert %{"enabled" => false, "secret_configured" => true, "total" => 0, "rejected" => 0, "recent" => []} = linear_webhooks_state()
  end

  test "accepts a signed delivery with 200, as Linear requires, and shows it in the state: type, action and the ticket's identifier" do
    assert %{"enabled" => true, "secret_configured" => true, "total" => 0, "last_at" => nil} = linear_webhooks_state()

    body = delivery_body(%{"type" => "Issue", "action" => "update", "data" => %{"identifier" => "TP-7", "title" => "Edited"}})
    conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body)}])

    assert json_response(conn, 200) == %{"status" => "accepted"}

    assert %{
             "total" => 1,
             "rejected" => 0,
             "last_type" => "Issue",
             "last_action" => "update",
             "last_at" => last_at,
             "counts" => [%{"type" => "Issue", "action" => "update", "count" => 1}],
             "recent" => [%{"type" => "Issue", "action" => "update", "identifier" => "TP-7", "received_at" => last_at}]
           } = linear_webhooks_state()

    assert {:ok, _at, 0} = DateTime.from_iso8601(last_at)
  end

  describe "an Issue delivery and the ticket's record" do
    @updated_at "2026-10-29T09:00:00.000Z"

    test "writes the new priority into the record the poll keeps; the next poll finds nothing and counts webhook first" do
      repo_key = Config.repo_key!()
      {:ok, :updated} = TicketObservation.observe(repo_key, polled_issue(priority: 2))

      conn = post_signed(issue_delivery("update", %{"priority" => 1, "updatedAt" => "2026-10-29T09:01:00.000Z"}))

      assert json_response(conn, 200) == %{"status" => "accepted"}
      assert %{priority: 1, phase: "In Progress", observed_from: :webhook, labels: ["backend"]} = RunStore.get_ticket_state(repo_key, "issue-hook")

      assert %{
               "recent" => [%{"type" => "Issue", "action" => "update", "identifier" => "ACME-9", "observation" => "updated"}],
               "observations" => %{"updated" => 1, "unrouted" => 0, "stale" => 0, "error" => 0}
             } = linear_webhooks_state()

      # The poll then reads the same ticket from Linear.
      repolled = polled_issue(priority: 1, updated_at: ~U[2026-10-29 09:01:00.000Z])
      assert {:ok, :unchanged} = TicketObservation.observe(repo_key, repolled, compare: true)
      assert %{"webhook_first" => 1, "poll_first" => 0, "poll_first_recent" => []} = linear_webhooks_state()["compare"]
    end

    test "names in the state each ticket and field a read had to correct before the webhook brought it" do
      repo_key = Config.repo_key!()
      {:ok, :updated} = TicketObservation.observe(repo_key, polled_issue(priority: 2))

      # A by-id read finds a new priority no delivery brought.
      corrected = polled_issue(priority: 3, updated_at: ~U[2026-10-29 09:02:00.000Z])
      assert {:ok, :updated} = TicketObservation.observe(repo_key, corrected, source: :by_id, now: ~U[2026-10-29 09:03:00Z])

      assert %{
               "webhook_first" => 0,
               "poll_first" => 1,
               "poll_first_recent" => [%{"identifier" => "ACME-9", "fields" => ["priority"], "source" => "by_id", "at" => at}]
             } = linear_webhooks_state()["compare"]

      assert {:ok, ~U[2026-10-29 09:03:00Z], 0} = DateTime.from_iso8601(at)
    end

    test "drops an older delivery and counts it stale" do
      repo_key = Config.repo_key!()
      {:ok, :updated} = TicketObservation.observe(repo_key, polled_issue(priority: 1))

      older = issue_delivery("update", %{"priority" => 4, "updatedAt" => "2026-10-29T08:59:00.000Z"})
      assert json_response(post_signed(older), 200) == %{"status" => "accepted"}

      assert RunStore.get_ticket_state(repo_key, "issue-hook").priority == 1
      assert %{"recent" => [%{"observation" => "stale"}], "observations" => %{"stale" => 1}} = linear_webhooks_state()
    end

    test "writes nothing for a ticket the poll has no record of, and counts it unrouted" do
      created = issue_delivery("create", %{})
      other_team = issue_delivery("create", %{"team" => %{"id" => "team-x", "key" => "NOPE", "name" => "Nope"}})

      assert json_response(post_signed(created), 200) == %{"status" => "accepted"}
      assert json_response(post_signed(other_team), 200) == %{"status" => "accepted"}
      assert RunStore.get_ticket_state(Config.repo_key!(), "issue-hook") == nil

      assert %{"recent" => [%{"action" => "create", "observation" => "unrouted"} | _], "observations" => %{"unrouted" => 2, "updated" => 0}} =
               linear_webhooks_state()
    end

    test "marks the record removed for an Issue remove delivery; a comment is only counted" do
      {:ok, :updated} = TicketObservation.observe(Config.repo_key!(), polled_issue([]))

      remove = delivery_body(%{"type" => "Issue", "action" => "remove", "data" => %{"id" => "issue-hook", "identifier" => "ACME-9"}})
      assert json_response(post_signed(remove), 200)
      assert %DateTime{} = RunStore.get_ticket_state(Config.repo_key!(), "issue-hook").removed_at

      comment = delivery_body(%{"type" => "Comment", "action" => "create", "data" => %{"id" => "c1", "body" => "hi", "issueId" => "issue-hook"}})
      assert json_response(post_signed(comment), 200)

      assert %{"recent" => [%{"type" => "Comment", "observation" => nil}, %{"action" => "remove", "observation" => "removed"} | _]} = linear_webhooks_state()
    end

    test "still answers 200 when the record write fails, logged and counted as an error" do
      failing = fn _parsed, _opts -> raise "store down" end
      Application.put_env(:symphony_elixir, :linear_webhook_observation_opts, observe_fun: failing)

      log = capture_log(fn -> assert json_response(post_signed(issue_delivery("update", %{})), 200) == %{"status" => "accepted"} end)

      assert log =~ "Linear webhook observation failed for issue_id=issue-hook"
      assert RunStore.get_ticket_state(Config.repo_key!(), "issue-hook") == nil
      assert %{"recent" => [%{"observation" => "error"}], "observations" => %{"error" => 1}} = linear_webhooks_state()
    end

    test "still answers 200 within the bound when the record write hangs, logged and counted as an error" do
      hang = fn _parsed, _opts -> Process.sleep(:infinity) end
      Application.put_env(:symphony_elixir, :linear_webhook_observation_opts, observe_fun: hang, timeout_ms: 50)

      log = capture_log(fn -> assert json_response(post_signed(issue_delivery("update", %{})), 200) == %{"status" => "accepted"} end)

      assert log =~ "Linear webhook observation failed for issue_id=issue-hook: :timeout"
      assert %{"recent" => [%{"observation" => "error"}], "observations" => %{"error" => 1}} = linear_webhooks_state()
    end
  end

  test "accepts a signed delivery without a type or an action, counted as unknown" do
    body = delivery_body(%{"data" => "not a map"})
    conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body)}])

    assert json_response(conn, 200) == %{"status" => "accepted"}
    assert %{"total" => 1, "recent" => [%{"type" => "unknown", "action" => "unknown", "identifier" => nil}]} = linear_webhooks_state()
  end

  test "rejects a wrong signature with 401, counts it with the reason, and logs neither payload nor secret" do
    body = delivery_body(%{"type" => "Issue", "action" => "update", "data" => %{"title" => "payload-value"}})

    log =
      capture_log(fn ->
        conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body, "wrong")}])
        assert %{"error" => %{"code" => "invalid_signature"}} = json_response(conn, 401)
      end)

    assert log =~ "Rejected Linear webhook delivery reason=bad_signature"
    refute log =~ "payload-value"
    refute log =~ @secret

    assert %{
             "total" => 0,
             "rejected" => 1,
             "last_rejected_reason" => "bad_signature",
             "last_rejected_at" => at,
             "rejected_reasons" => [%{"reason" => "bad_signature", "count" => 1}],
             "recent" => []
           } = linear_webhooks_state()

    assert is_binary(at)
  end

  test "rejects an unsigned delivery, a stale one, and one in a content type it doesn't read" do
    capture_log(fn ->
      body = delivery_body(%{"type" => "Issue"})
      assert json_response(post_webhook(body, [{"content-type", "application/json"}]), 401)

      stale = Jason.encode!(%{"type" => "Issue", "webhookTimestamp" => System.system_time(:millisecond) - 120_000})
      assert json_response(post_webhook(stale, [{"content-type", "application/json"}, {"linear-signature", sign(stale)}]), 401)

      assert json_response(post_webhook(body, [{"content-type", "text/plain"}, {"linear-signature", sign(body)}]), 401)
    end)

    assert %{"total" => 0, "rejected" => 3, "rejected_reasons" => reasons} = linear_webhooks_state()

    assert Enum.sort_by(reasons, & &1["reason"]) == [
             %{"reason" => "bad_signature", "count" => 1},
             %{"reason" => "missing_signature", "count" => 1},
             %{"reason" => "stale_timestamp", "count" => 1}
           ]
  end

  test "shows the secret as not configured while its variable is unset, and refuses every delivery" do
    write_workflow_file!(Workflow.workflow_file_path())
    append_symphony_yml!("linear:\n  webhooks:\n    enabled: true\n    secret: $SYMPHONY_TEST_UNSET_LINEAR_WEBHOOK_SECRET\n")

    body = delivery_body(%{"type" => "Issue"})
    capture_log(fn -> assert json_response(post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body)}]), 401) end)

    assert %{"enabled" => true, "secret_configured" => false, "rejected" => 1, "last_rejected_reason" => "missing_secret"} = linear_webhooks_state()
  end

  test "only takes POST" do
    conn = get(build_conn(), "/api/v1/linear/webhook")

    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(conn, 405)
  end

  defp configure_webhooks!(enabled) do
    write_workflow_file!(Workflow.workflow_file_path())
    append_symphony_yml!("linear:\n  webhooks:\n    enabled: #{enabled}\n    secret: #{@secret}\n")
  end

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  defp linear_webhooks_state, do: build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("linear_webhooks")

  defp delivery_body(fields), do: fields |> Map.put("webhookTimestamp", System.system_time(:millisecond)) |> Jason.encode!()

  defp post_webhook(body, headers) do
    headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value) end)
    |> post("/api/v1/linear/webhook", body)
  end

  defp post_signed(body), do: post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body)}])

  # An Issue delivery for ACME-9 on the test repo's team, with `data` changed by `fields`.
  defp issue_delivery(action, fields) do
    data =
      Map.merge(
        %{
          "id" => "issue-hook",
          "identifier" => "ACME-9",
          "title" => "Hooked",
          "priority" => 2,
          "state" => %{"id" => "state-1", "name" => "In Progress", "type" => "started"},
          "team" => %{"id" => "team-1", "key" => "Test", "name" => "Test"},
          "labels" => [%{"id" => "label-1", "name" => "Backend"}],
          "assignee" => %{"id" => "user-1", "name" => "Ada"},
          "url" => "https://linear.app/acme/issue/ACME-9",
          "updatedAt" => @updated_at
        },
        fields
      )

    delivery_body(%{"type" => "Issue", "action" => action, "data" => data})
  end

  # The same ticket as the regular poll reads it from Linear.
  defp polled_issue(fields) do
    struct!(
      %Issue{
        id: "issue-hook",
        identifier: "ACME-9",
        title: "Hooked",
        state: "In Progress",
        labels: ["backend"],
        priority: 2,
        assignee_id: "user-1",
        blocked_by: [],
        url: "https://linear.app/acme/issue/ACME-9",
        updated_at: ~U[2026-10-29 09:00:00.000Z]
      },
      fields
    )
  end

  defp sign(body, secret \\ @secret), do: :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
end
