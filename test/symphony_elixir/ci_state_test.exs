defmodule SymphonyElixir.CiStateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.CiState

  @at ~U[2026-10-11 10:00:00Z]

  # A store that reports whatever outcome the caller scripted, and records the write it was given.
  defmodule FakeStore do
    def record_ci_state(repo_key, issue_id, head_sha, status, at) do
      send(self(), {:record_ci_state, repo_key, issue_id, head_sha, status, at})
      Process.get({__MODULE__, :result}, {:ok, :changed})
    end
  end

  defmodule ErrorStore do
    def record_ci_state(_repo_key, _issue_id, _head_sha, _status, _at), do: {:error, :store_down}
  end

  defmodule NoStore do
    def unrelated, do: :ok
  end

  defmodule FakeTracker do
    def set_machine_label(issue_id, label_name) do
      send(self(), {:set_machine_label, issue_id, label_name})
      :ok
    end

    def clear_machine_label(issue_id, label_name) do
      send(self(), {:clear_machine_label, issue_id, label_name})
      :ok
    end
  end

  defmodule ErrorTracker do
    def set_machine_label(_issue_id, _label_name), do: {:error, :label_write_failed}
    def clear_machine_label(_issue_id, _label_name), do: {:error, :label_write_failed}
  end

  defmodule NoTracker do
    def unrelated, do: :ok
  end

  describe "label/1 and status_for_action/1" do
    test "map each CI status to its label and each poll action to a status" do
      assert CiState.label("running") == "CI running"
      assert CiState.label("green") == "CI green"
      assert CiState.label("red") == "CI red"
      assert CiState.label(nil) == nil
      assert CiState.label("other") == nil

      assert CiState.status_for_action(:success) == "green"
      assert CiState.status_for_action(:pending) == "running"
      assert CiState.status_for_action({:failure, [%{}]}) == "red"
      assert CiState.status_for_action(:closed) == nil
      assert CiState.status_for_action(:nonsense) == nil
    end
  end

  describe "record/6" do
    test "a changed write projects exactly one label, setting it and clearing the rest" do
      assert :ok = CiState.record("repo-a", "issue-1", "abc", "green", @at, run_store: FakeStore, tracker: FakeTracker)

      assert_received {:record_ci_state, "repo-a", "issue-1", "abc", "green", @at}
      assert_received {:set_machine_label, "issue-1", "CI green"}
      assert_received {:clear_machine_label, "issue-1", "CI running"}
      assert_received {:clear_machine_label, "issue-1", "CI red"}
    end

    test "an unchanged or stale write records nothing but touches no label" do
      for outcome <- [:unchanged, :stale] do
        Process.put({FakeStore, :result}, {:ok, outcome})

        assert :ok =
                 CiState.record("repo-a", "issue-1", "abc", "green", @at, run_store: FakeStore, tracker: FakeTracker)

        assert_received {:record_ci_state, _, _, _, _, _}
        refute_received {:set_machine_label, _, _}
        refute_received {:clear_machine_label, _, _}
      end
    end

    test "a nil status clears every CI label and writes no attribute" do
      assert :ok = CiState.record("repo-a", "issue-1", nil, nil, @at, run_store: FakeStore, tracker: FakeTracker)

      refute_received {:record_ci_state, _, _, _, _, _}
      assert_received {:clear_machine_label, "issue-1", "CI green"}
      assert_received {:clear_machine_label, "issue-1", "CI running"}
      assert_received {:clear_machine_label, "issue-1", "CI red"}
      refute_received {:set_machine_label, _, _}
    end

    test "a store that carries no CI write skips the attribute and the label" do
      assert :ok = CiState.record("repo-a", "issue-1", "abc", "red", @at, run_store: NoStore, tracker: FakeTracker)
      assert :ok = CiState.record("repo-a", "issue-1", "abc", "red", @at, run_store: NotARealStore, tracker: FakeTracker)
      refute_received {:set_machine_label, _, _}
      refute_received {:clear_machine_label, _, _}
    end

    test "a failed store write is logged and projects no label" do
      log =
        capture_log(fn ->
          assert :ok = CiState.record("repo-a", "issue-1", "abc", "red", @at, run_store: ErrorStore, tracker: FakeTracker)
        end)

      assert log =~ "Failed to record CI state"
      assert log =~ "store_down"
      refute_received {:set_machine_label, _, _}
    end

    test "a tracker without the machine-label functions, or a missing module, is a silent no-op" do
      log =
        capture_log(fn ->
          assert :ok = CiState.record("repo-a", "issue-1", "abc", "red", @at, run_store: FakeStore, tracker: NoTracker)
          assert :ok = CiState.record("repo-a", "issue-1", "abc", "red", @at, run_store: FakeStore, tracker: NotARealTracker)
        end)

      # capture_log sees every process's logs, so another async test's lines can land here.
      refute log =~ "Failed to set_machine_label"
      refute log =~ "Failed to clear_machine_label"
      refute log =~ "Failed to record CI state"
    end

    test "a tracker failure is logged, and the other labels are still cleared" do
      log =
        capture_log(fn ->
          assert :ok = CiState.record("repo-a", "issue-1", "abc", "red", @at, run_store: FakeStore, tracker: ErrorTracker)
        end)

      assert log =~ "Failed to set_machine_label"
      assert log =~ "Failed to clear_machine_label"
      assert log =~ "label_write_failed"
    end

    test "a record without a repo key or issue id is a no-op" do
      assert :ok = CiState.record(nil, "issue-1", "abc", "red", @at, run_store: FakeStore, tracker: FakeTracker)
      assert :ok = CiState.record("repo-a", nil, "abc", "red", @at, run_store: FakeStore, tracker: FakeTracker)

      # The default opts (the real store and tracker) are never reached: the guard returns first.
      assert :ok = CiState.record(nil, "issue-1", "abc", "red", @at)
      assert :ok = CiState.record("repo-a", nil, "abc", "red", @at)

      refute_received {:set_machine_label, _, _}
      refute_received {:clear_machine_label, _, _}
    end
  end
end
