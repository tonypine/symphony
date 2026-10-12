defmodule SymphonyElixir.HandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.RunStore

  @repo_key "repo-handoff"
  @issue_id "issue-handoff"

  setup do
    RunStore.delete_ticket_state(@repo_key, @issue_id)
    on_exit(fn -> RunStore.delete_ticket_state(@repo_key, @issue_id) end)
    :ok
  end

  defp settings!(attrs) do
    assert {:ok, settings} = Schema.parse(attrs)
    settings
  end

  defp designed_settings(extra \\ %{}) do
    settings!(Map.merge(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"}, extra))
  end

  defp legacy_settings(extra \\ %{}) do
    settings!(Map.merge(%{"tracker" => %{"kind" => "memory"}}, extra))
  end

  describe "the signal names" do
    test "are stable strings" do
      assert Handoff.signal() == "handoff"
      assert Handoff.missing_signal() == "handoff_missing"
    end
  end

  describe "designed?/1 and target_state/1" do
    test "a designed repo hands off to its configured Code Review state" do
      assert Handoff.designed?(designed_settings())
      assert Handoff.target_state(designed_settings()) == "Code Review"

      configured = designed_settings(%{"tracker" => %{"kind" => "memory", "code_review_state" => "Peer Review"}})
      assert Handoff.target_state(configured) == "Peer Review"
    end

    test "a legacy repo keeps the Auto Review post-PR state" do
      refute Handoff.designed?(legacy_settings())
      assert Handoff.target_state(legacy_settings()) == "In Review"

      auto_review = legacy_settings(%{"auto_review" => %{"enabled" => true, "state" => "QA"}})
      assert Handoff.target_state(auto_review) == "QA"
    end
  end

  describe "origin?/1 and required?/2" do
    test "only In Progress and Rework are origins, case- and space-insensitively" do
      assert Handoff.origin?("In Progress")
      assert Handoff.origin?(" rework ")
      assert Handoff.origin?("REWORK")
      refute Handoff.origin?("Todo")
      refute Handoff.origin?(nil)
      refute Handoff.origin?(5)
    end

    test "the signal is required only for a designed repo's origin states" do
      assert Handoff.required?("In Progress", designed_settings())
      assert Handoff.required?("Rework", designed_settings())
      refute Handoff.required?("Todo", designed_settings())
      refute Handoff.required?("In Progress", legacy_settings())
    end
  end

  describe "emit/3 and emitted?/3" do
    test "records a signal bound to the head it handed off" do
      assert :ok = Handoff.emit(@repo_key, @issue_id, %{head: "abc123", branch: "auto/TP-1"})

      assert Handoff.emitted?(@repo_key, @issue_id, "abc123")
      refute Handoff.emitted?(@repo_key, @issue_id, "def456")
    end

    test "a signal with no recorded head counts for any head" do
      assert :ok = Handoff.emit(@repo_key, @issue_id, %{branch: "auto/TP-1"})

      assert Handoff.emitted?(@repo_key, @issue_id, "anything")
      # A nil head — the runner before it has read one — matches a signal too.
      assert Handoff.emitted?(@repo_key, @issue_id, nil)
    end

    test "only the handoff signal counts, and only for its own head" do
      assert :ok = RunStore.record_ticket_signal(@repo_key, @issue_id, "code_review", %{signal: "approve"})
      refute Handoff.emitted?(@repo_key, @issue_id, "abc123")

      # A recorded head that is not a string never matches.
      assert :ok = RunStore.record_ticket_signal(@repo_key, @issue_id, "handoff", %{head: 5})
      refute Handoff.emitted?(@repo_key, @issue_id, "abc123")
    end

    test "the two-argument emit records an empty handoff" do
      assert :ok = Handoff.emit(@repo_key, @issue_id)

      assert [%{name: "handoff", details: %{}}] = Handoff.signals(@repo_key, @issue_id)
      assert Handoff.emitted?(@repo_key, @issue_id, "abc123")
    end

    test "is false before anything is emitted and for an unconfigured ticket" do
      refute Handoff.emitted?(@repo_key, @issue_id, "abc123")
      refute Handoff.emitted?(@repo_key, "other-issue", "abc123")
      refute Handoff.emitted?(nil, @issue_id, "abc123")
      refute Handoff.emitted?(@repo_key, nil, "abc123")
    end

    test "emit is a no-op without a repo key or issue id" do
      assert :ok = Handoff.emit(nil, @issue_id, %{head: "abc"})
      assert :ok = Handoff.emit(@repo_key, nil, %{head: "abc"})
      assert :ok = Handoff.emit(@repo_key, 5, %{head: "abc"})

      refute Handoff.emitted?(@repo_key, @issue_id, "abc")
    end
  end

  describe "signals/2 and verdicts/3" do
    test "read the ticket's ledger" do
      assert Handoff.signals(@repo_key, @issue_id) == []
      assert Handoff.verdicts(@repo_key, @issue_id, "code_review") == []

      Handoff.emit(@repo_key, @issue_id, %{head: "abc"})
      assert [%{name: "handoff", details: %{head: "abc"}}] = Handoff.signals(@repo_key, @issue_id)

      assert :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "code_review", "abc", "approve")
      assert :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "qa", "abc", "pass")

      assert [%{kind: "code_review", head_sha: "abc", outcome: "approve"}] =
               Handoff.verdicts(@repo_key, @issue_id, "code_review")
    end

    test "a missing or invalid ticket reads as empty" do
      assert Handoff.signals(nil, nil) == []
      assert Handoff.verdicts(@repo_key, "missing-issue", "code_review") == []
    end
  end
end
