defmodule SymphonyElixir.PrWatch.HealthTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.GitHub.Webhooks
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.Health

  @now ~U[2026-10-16 12:00:00Z]
  @on %Webhooks{enabled: true}

  defmodule Store do
    def get_github_updates({:health, "kept"}), do: %{deliveries: 4, unknown_key: true}
    def get_github_updates(_key), do: nil
  end

  defp record(attrs \\ []) do
    Map.merge(
      %{
        head_sha: "head-1",
        read_at: ~U[2026-10-16 11:55:00Z],
        github: :ok,
        delivered_at: nil,
        facts: Facts.new(%{phase: :code_review, pr: :open, ci: :pending, mergeable: :clean})
      },
      Map.new(attrs)
    )
  end

  defp with_facts(record, facts), do: %{record | facts: struct(record.facts, facts)}

  test "a new repository is unhealthy and silent with webhooks on, and neither counts with them off" do
    health = Health.new()

    refute Health.healthy?(health, @on)
    assert Health.silent?(health, @on, @now)
    refute Health.silent?(health, %Webhooks{enabled: false}, @now)
    assert Health.interval_ms(health, @on, 30_000, nil) == 30_000
  end

  test "a delivery makes it healthy, at the safety-net pace, until a missed change after it" do
    health = Health.delivered(Health.new(), ~U[2026-10-16 11:59:00Z])

    assert Health.healthy?(health, @on)
    refute Health.healthy?(health, %Webhooks{enabled: false})
    assert Health.interval_ms(health, @on, 30_000, nil) == 300_000

    missed = Health.missed(health, "https://github.com/acme/app/pull/1", :ci, @now)
    refute Health.healthy?(missed, @on)
    assert Health.interval_ms(missed, @on, 30_000, nil) == 30_000
    assert Health.healthy?(Health.delivered(missed, DateTime.add(@now, 1)), @on)
  end

  test "a relay that keeps stopping keeps the poll interval, however healthy the deliveries" do
    health = Health.delivered(Health.new(), ~U[2026-10-16 11:59:00Z])

    assert Health.interval_ms(health, @on, 30_000, %{stable: false}) == 30_000
    assert Health.interval_ms(health, @on, 30_000, %{stable: true}) == 300_000
    assert Health.interval_ms(health, @on, 30_000, nil) == 300_000
  end

  test "silence starts after silence_alert_minutes without a delivery" do
    health = Health.delivered(Health.new(), ~U[2026-10-16 11:50:00Z])

    assert Health.silent?(health, @on, @now)
    refute Health.silent?(health, %Webhooks{enabled: true, silence_alert_minutes: 11}, @now)
  end

  test "signature failures count over the last 24 hours" do
    health = Health.new() |> Health.rejected(~U[2026-10-15 11:00:00Z]) |> Health.rejected(~U[2026-10-15 13:00:00Z])

    assert Health.signature_failures(health, @now) == 1
    assert length(Health.rejected(health, @now).signature_failures) == 2
  end

  test "load/2 keeps the known keys of a stored record, and starts afresh without one" do
    assert %{deliveries: 4, missed: 0} = Health.load(Store, "kept")
    refute Map.has_key?(Health.load(Store, "kept"), :unknown_key)
    assert Health.load(Store, "none") == Health.new()
  end

  test "learn_url/2 keeps a URL and ignores none" do
    assert %{github_url: "https://github.com/acme/app"} = Health.learn_url(Health.new(), "https://github.com/acme/app")
    assert Health.learn_url(Health.new(), nil) == Health.new()
  end

  describe "unreported_change/2" do
    test "a moved head, a closed, merged or reopened PR, or a new CI result no delivery reported" do
      assert Health.unreported_change(record(), record(head_sha: "head-2")) == :head
      assert Health.unreported_change(record(), with_facts(record(), pr: :closed)) == :pr
      assert Health.unreported_change(with_facts(record(), pr: :merged), record()) == :pr
      assert Health.unreported_change(record(), with_facts(record(), ci: :red)) == :ci
      assert Health.unreported_change(record(), with_facts(record(), ci: :none)) == :ci
      assert Health.unreported_change(with_facts(record(), ci: :green), with_facts(record(), ci: :none)) == nil
    end

    test "no change, a draft, mergeability or a pending head is none" do
      assert Health.unreported_change(record(), record()) == nil
      assert Health.unreported_change(record(), with_facts(record(), pr: :draft)) == nil
      assert Health.unreported_change(record(), with_facts(record(), mergeable: :dirty)) == nil
      assert Health.unreported_change(with_facts(record(), ci: :red), record()) == nil
      assert Health.unreported_change(record(head_sha: nil), record(head_sha: "head-2")) == nil
    end

    test "a delivery since the last read reported it; a record never read or rate limited has nothing to compare" do
      assert Health.unreported_change(record(delivered_at: ~U[2026-10-16 11:56:00Z]), record(head_sha: "head-2")) == nil
      assert Health.unreported_change(record(delivered_at: ~U[2026-10-16 11:50:00Z]), record(head_sha: "head-2")) == :head
      assert Health.unreported_change(nil, record()) == nil
      assert Health.unreported_change(record(read_at: nil), record(head_sha: "head-2")) == nil
      assert Health.unreported_change(record(github: {:rate_limited, nil}), record(head_sha: "head-2")) == nil
      assert Health.unreported_change(record(), record(head_sha: "head-2", github: {:rate_limited, nil})) == nil
    end
  end

  test "status/3 is what the state API shows" do
    health =
      Health.new()
      |> Health.delivered(~U[2026-10-16 11:58:00Z])
      |> Health.rejected(@now)
      |> Health.result(:webhook)
      |> Health.result(:poll)
      |> Health.missed("https://github.com/acme/app/pull/1", :head, ~U[2026-10-16 11:57:00Z])

    assert Health.status(health, @on, @now) == %{
             healthy: true,
             silent: false,
             last_delivery_at: ~U[2026-10-16 11:58:00Z],
             deliveries: 1,
             signature_failures_24h: 1,
             missed: 1,
             missed_at: ~U[2026-10-16 11:57:00Z],
             last_missed: %{pr_url: "https://github.com/acme/app/pull/1", change: :head},
             results_via_webhook: 1,
             results_via_poll: 1
           }
  end
end
