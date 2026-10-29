defmodule SymphonyElixir.ObservabilityPubSubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.ObservabilityPubSub

  defmodule FailingPubSubAdapter do
    def broadcast(_adapter_name, _topic, _message, _dispatcher), do: {:error, :forced_failure}
  end

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive {:observability_updated, %{repo_key: "default"}}
  end

  test "subscribe_transcript and broadcast_transcript_event deliver issue events" do
    event = %{event: :notification, payload: %{message: "live"}, timestamp: DateTime.utc_now()}
    expected = Map.merge(event, %{repo_key: "default", issue_id: "issue-123"})

    assert :ok = ObservabilityPubSub.subscribe_transcript()
    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-123", event)
    assert_receive {:transcript_event, ^expected}
    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-123", :not_an_event)
  end

  test "broadcast_transcript_event normalises blank/nil repo_key to default" do
    assert ObservabilityPubSub.transcript_topic() == "observability:transcript"
    assert :ok = ObservabilityPubSub.subscribe_transcript()

    assert :ok =
             ObservabilityPubSub.broadcast_transcript_event(" ", "issue-blank", %{
               event: :notification
             })

    assert_receive {:transcript_event, %{repo_key: "default", issue_id: "issue-blank"}}

    assert :ok =
             ObservabilityPubSub.broadcast_transcript_event(nil, "issue-nil", %{
               event: :notification
             })

    assert_receive {:transcript_event, %{repo_key: "default", issue_id: "issue-nil"}}
    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", 123, %{event: :notification})
  end

  test "repo_key falls back to nil when config cannot resolve a primary repo" do
    # The cache keeps the last good `symphony.yml` when a reload is rejected, and any config read
    # since setup may have cached it; drop it so the rejected file leaves no repo to resolve.
    File.write!(Workflow.symphony_file_path(), "repos: []\n")
    :ok = Cache.invalidate(Workflow.symphony_file_path())

    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive {:observability_updated, %{repo_key: nil}}
  end

  test "subscribe_ticket_records and broadcast_ticket_record_changed deliver record changes" do
    assert :ok = ObservabilityPubSub.subscribe_ticket_records()
    assert :ok = ObservabilityPubSub.broadcast_ticket_record_changed("web", "issue-123")
    assert_receive {:ticket_record, "web", "issue-123", :changed}
  end

  test "broadcast_ticket_record_changed logs adapter errors without failing the caller" do
    {:ok, original_pubsub_meta} = Registry.meta(SymphonyElixir.PubSub, :pubsub)
    on_exit(fn -> :ok = Registry.put_meta(SymphonyElixir.PubSub, :pubsub, original_pubsub_meta) end)
    failing_pubsub_meta = original_pubsub_meta |> put_elem(0, FailingPubSubAdapter) |> put_elem(1, :failing_adapter)
    :ok = Registry.put_meta(SymphonyElixir.PubSub, :pubsub, failing_pubsub_meta)

    log = capture_log(fn -> assert :ok = ObservabilityPubSub.broadcast_ticket_record_changed("web", "issue-123") end)

    assert log =~ "failed to broadcast ticket record change: :forced_failure"
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      restart_pubsub_child(pubsub_child_id)
    end)

    assert is_pid(Process.whereis(SymphonyElixir.PubSub))
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, pubsub_child_id)
    refute Process.whereis(SymphonyElixir.PubSub)

    assert :ok = ObservabilityPubSub.broadcast_update()
    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-123", %{event: :notification})
    assert :ok = ObservabilityPubSub.subscribe_ticket_records()
    assert :ok = ObservabilityPubSub.broadcast_ticket_record_changed("web", "issue-123")
  end

  test "broadcast_transcript_event logs adapter errors without failing the caller" do
    {:ok, original_pubsub_meta} = Registry.meta(SymphonyElixir.PubSub, :pubsub)

    on_exit(fn ->
      :ok = Registry.put_meta(SymphonyElixir.PubSub, :pubsub, original_pubsub_meta)
    end)

    failing_pubsub_meta =
      original_pubsub_meta
      |> put_elem(0, FailingPubSubAdapter)
      |> put_elem(1, :failing_adapter)

    :ok = Registry.put_meta(SymphonyElixir.PubSub, :pubsub, failing_pubsub_meta)

    log =
      capture_log(fn ->
        assert :ok =
                 ObservabilityPubSub.broadcast_transcript_event("default", "issue-123", %{
                   event: :notification
                 })
      end)

    assert log =~ "failed to broadcast transcript event: :forced_failure"
  end

  defp restart_pubsub_child(pubsub_child_id) do
    with supervisor when is_pid(supervisor) <- Process.whereis(SymphonyElixir.Supervisor),
         nil <- Process.whereis(SymphonyElixir.PubSub) do
      case Supervisor.restart_child(supervisor, pubsub_child_id) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, _reason} -> :ok
      end
    else
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
