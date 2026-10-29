defmodule SymphonyElixir.Linear.Webhook.DeliveriesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Webhook.Deliveries

  @at ~U[2026-10-29 06:00:00Z]

  setup do
    Deliveries.reset()
    on_exit(&Deliveries.reset/0)
    :ok
  end

  test "starts empty" do
    assert Deliveries.summary() == %{
             total: 0,
             rejected: 0,
             last_at: nil,
             last_type: nil,
             last_action: nil,
             last_rejected_at: nil,
             last_rejected_reason: nil,
             counts: [],
             rejected_reasons: [],
             recent: []
           }
  end

  test "counts an accepted delivery by type and action, with the identifier the payload names" do
    assert :ok = Deliveries.accepted(%{"type" => "Issue", "action" => "update", "data" => %{"identifier" => "TP-1", "title" => "x"}}, @at)
    assert :ok = Deliveries.accepted(%{"type" => "Issue", "action" => "update", "data" => %{"identifier" => "TP-2"}}, DateTime.add(@at, 1))
    assert :ok = Deliveries.accepted(%{"type" => "Comment", "action" => "create", "data" => %{"body" => "hi"}}, DateTime.add(@at, 2))

    summary = Deliveries.summary()

    assert summary.total == 3
    assert summary.rejected == 0
    assert summary.last_at == DateTime.add(@at, 2)
    assert {summary.last_type, summary.last_action} == {"Comment", "create"}

    assert summary.counts == [
             %{type: "Issue", action: "update", count: 2},
             %{type: "Comment", action: "create", count: 1}
           ]

    assert summary.recent == [
             %{type: "Comment", action: "create", identifier: nil, received_at: DateTime.add(@at, 2)},
             %{type: "Issue", action: "update", identifier: "TP-2", received_at: DateTime.add(@at, 1)},
             %{type: "Issue", action: "update", identifier: "TP-1", received_at: @at}
           ]
  end

  test "counts a payload without a type, an action or data as unknown" do
    for payload <- [%{}, nil, "not a map", %{"type" => "", "action" => 7, "data" => "x"}, %{"data" => %{"identifier" => 12}}] do
      assert :ok = Deliveries.accepted(payload, @at)
    end

    summary = Deliveries.summary()

    assert summary.total == 5
    assert summary.counts == [%{type: "unknown", action: "unknown", count: 5}]
    assert Enum.all?(summary.recent, &(&1 == %{type: "unknown", action: "unknown", identifier: nil, received_at: @at}))
  end

  test "keeps a long value to its first 64 characters" do
    Deliveries.accepted(%{"type" => String.duplicate("t", 100), "action" => "update"}, @at)

    assert Deliveries.summary().last_type == String.duplicate("t", 64)
  end

  test "keeps the last ten deliveries, newest first, and counts every one" do
    for n <- 1..12, do: Deliveries.accepted(%{"type" => "Issue", "action" => "update", "data" => %{"identifier" => "TP-#{n}"}}, @at)

    summary = Deliveries.summary()

    assert summary.total == 12
    assert Enum.map(summary.recent, & &1.identifier) == Enum.map(12..3//-1, &"TP-#{&1}")
  end

  test "counts a rejected delivery by its reason, apart from the accepted ones" do
    assert :ok = Deliveries.rejected(:bad_signature, @at)
    assert :ok = Deliveries.rejected(:stale_timestamp, DateTime.add(@at, 1))
    assert :ok = Deliveries.rejected(:bad_signature, DateTime.add(@at, 2))

    summary = Deliveries.summary()

    assert summary.total == 0
    assert summary.rejected == 3
    assert summary.last_rejected_at == DateTime.add(@at, 2)
    assert summary.last_rejected_reason == :bad_signature
    assert summary.rejected_reasons == [%{reason: :bad_signature, count: 2}, %{reason: :stale_timestamp, count: 1}]
    assert summary.recent == []
  end

  test "stamps a delivery with the current time by default" do
    before = DateTime.utc_now()
    Deliveries.accepted(%{"type" => "Project", "action" => "remove"})
    Deliveries.rejected(:missing_signature)

    summary = Deliveries.summary()
    assert DateTime.compare(summary.last_at, before) != :lt
    assert DateTime.compare(summary.last_rejected_at, before) != :lt
  end

  test "counts nothing and reads empty while it isn't running; a restart starts from zero" do
    Deliveries.accepted(%{"type" => "Issue", "action" => "update"}, @at)
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Deliveries)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, Deliveries) end)

    assert :ok = Deliveries.accepted(%{"type" => "Issue", "action" => "update"}, @at)
    assert :ok = Deliveries.rejected(:bad_signature, @at)
    assert :ok = Deliveries.reset()
    assert %{total: 0, rejected: 0, recent: []} = Deliveries.summary()

    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, Deliveries)
    assert %{total: 0, rejected: 0, recent: []} = Deliveries.summary()
  end

  test "start_link/1 takes a name" do
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Deliveries)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, Deliveries) end)

    assert {:ok, pid} = Deliveries.start_link(name: Module.concat(__MODULE__, Named))
    assert :ok = GenServer.stop(pid)
  end
end
