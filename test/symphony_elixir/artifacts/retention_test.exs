defmodule SymphonyElixir.Artifacts.RetentionTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.{Artifacts, Paths, TicketEvents}
  alias SymphonyElixir.Artifacts.{Retention, Store}

  @endpoint SymphonyElixirWeb.Endpoint
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>
  @day 86_400

  # The tracker the runs ask: the states the test put in the process dictionary, and each request's
  # ids sent back to the test.
  defmodule FakeTracker do
    @moduledoc false

    def fetch_issue_states_by_ids(ids) do
      send(self(), {:fetch_states, ids})

      case Process.get(:retention_states) do
        {:error, reason} -> {:error, reason}
        states -> {:ok, for({id, state} <- states, id in ids, do: %{id: id, identifier: "TP-#{id}", state: state})}
      end
    end
  end

  # The tracker the server asks from its own process: the states a test put in a persistent term.
  defmodule PersistentTracker do
    @moduledoc false

    def fetch_issue_states_by_ids(ids) do
      states = :persistent_term.get({__MODULE__, :states})
      {:ok, for({id, state} <- states, id in ids, do: %{id: id, state: state})}
    end
  end

  # A store that can't be listed, or whose files can't be removed.
  defmodule FailingArtifacts do
    @moduledoc false

    def list(opts), do: Process.get(:retention_list, fn -> Artifacts.list(opts) end).()
    def expire(_id), do: {:error, :eacces}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    File.rm_rf!(Paths.artifacts_dir())

    workspace = Path.join(System.tmp_dir!(), "symphony-retention-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(Paths.artifacts_dir())
    end)

    %{workspace: workspace, now: DateTime.add(DateTime.utc_now(), 15 * @day, :second)}
  end

  describe "the operator's walkthrough" do
    test "a ticket finished 15 days ago loses its screenshots' bytes, keeps their events and metadata; one in progress keeps everything",
         %{workspace: workspace, now: now} do
      done = ingest!(workspace, "done.png", @png, "issue-done")
      active = ingest!(workspace, "active.png", @png <> "active", "issue-active")
      record_run_ended!("issue-done", done.id, now, -15 * @day)
      record_run_ended!("issue-active", active.id, now, -15 * @day)
      Process.put(:retention_states, %{"issue-done" => "Done", "issue-active" => "In Progress"})

      assert %{expired: [done_id], kept: [active_id]} = run(now)
      assert done_id == done.id
      assert active_id == active.id

      refute Store.present?(done.id)
      assert [%{artifacts: [^done_id]}] = TicketEvents.query("default", "issue-done")
      assert {:ok, %{expired: true, expired_at: %DateTime{}, label: "done.png", tickets: [%{issue_id: "issue-done"}]}} = Artifacts.get(done.id)

      start_endpoint!()

      assert %{"id" => ^done_id, "expired" => true, "label" => "done.png", "error" => %{"code" => "artifact_expired"}} =
               json_response(get(build_conn(), "/api/v1/artifacts/#{done.id}"), 410)

      assert Store.present?(active.id)
      assert {:ok, %{expired: false}} = Artifacts.get(active.id)
      assert get(build_conn(), "/api/v1/artifacts/#{active.id}").status == 200
    end
  end

  describe "run/1" do
    test "an active ticket's artifacts are never expired, however old", %{workspace: workspace, now: now} do
      artifact = ingest!(workspace, "old.png", @png, "issue-active")
      Process.put(:retention_states, %{"issue-active" => "In Progress"})

      assert %{expired: [], kept: [id]} = run(DateTime.add(now, 3650 * @day, :second))
      assert id == artifact.id
      assert Store.present?(artifact.id)
    end

    test "a terminal ticket's artifacts expire once N days have passed since its newest event", %{workspace: workspace} do
      write_symphony_ledger!("  artifact_retention_days: 3\n")
      artifact = ingest!(workspace, "shot.png", @png, "issue-done")
      Process.put(:retention_states, %{"issue-done" => " canceled "})

      # Captured 2 days ago: not old enough, so the tracker isn't asked.
      two_days = DateTime.add(DateTime.utc_now(), 2 * @day, :second)
      assert %{expired: [], kept: []} = run(two_days)
      refute_received {:fetch_states, _ids}

      # Old enough, but the ticket recorded an event a day ago: finished for a day at most.
      record_run_ended!("issue-done", artifact.id, two_days, -@day)
      assert %{expired: [], kept: [_id]} = run(DateTime.add(two_days, 2 * @day, :second))
      assert_received {:fetch_states, ["issue-done"]}
      assert Store.present?(artifact.id)

      assert %{expired: [id], kept: []} = run(DateTime.add(two_days, 3 * @day, :second))
      assert id == artifact.id
      refute Store.present?(artifact.id)

      # Expired artifacts aren't looked at again.
      assert %{expired: [], kept: []} = run(DateTime.add(two_days, 30 * @day, :second))
    end

    test "the retention is read on each run, so a change applies without a restart", %{workspace: workspace} do
      artifact = ingest!(workspace, "shot.png", @png, "issue-done")
      Process.put(:retention_states, %{"issue-done" => "Done"})
      eight_days = DateTime.add(DateTime.utc_now(), 8 * @day, :second)

      assert %{expired: [], kept: []} = run(eight_days)

      write_symphony_ledger!("  artifact_retention_days: 7\n")
      assert %{expired: [id]} = run(eight_days)
      assert id == artifact.id
    end

    test "a screenshot shared by a finished ticket and an active one keeps its bytes", %{workspace: workspace, now: now} do
      artifact = ingest!(workspace, "shared.png", @png, "issue-done")
      _same = ingest!(workspace, "again.png", @png, "issue-active")
      Process.put(:retention_states, %{"issue-done" => "Done", "issue-active" => "QA"})

      assert %{expired: [], kept: [id]} = run(now)
      assert id == artifact.id
      assert Store.present?(artifact.id)

      Process.put(:retention_states, %{"issue-done" => "Done", "issue-active" => "Duplicate"})
      assert %{expired: [^id]} = run(now)
    end

    test "a ticket the tracker doesn't return, or whose request failed, keeps its artifacts", %{workspace: workspace, now: now} do
      artifact = ingest!(workspace, "shot.png", @png, "issue-gone")
      Process.put(:retention_states, %{})

      log = capture_log([level: :info], fn -> assert %{expired: [], kept: [_id]} = run(now) end)
      assert log =~ "Artifact retention keeps the artifacts of issue_id=issue-gone: the tracker did not return the ticket"

      Process.put(:retention_states, {:error, :rate_limited})
      log = capture_log(fn -> assert %{expired: [], kept: [_id]} = run(now) end)
      assert log =~ "Artifact retention keeps the artifacts of issue_ids=issue-gone: their states could not be read reason=:rate_limited"
      assert Store.present?(artifact.id)
    end

    test "asks for the states 50 tickets at a time", %{workspace: workspace, now: now} do
      ids = for n <- 1..51, do: "issue-#{n}"
      for id <- ids, do: ingest!(workspace, "#{id}.png", @png <> id, id)
      Process.put(:retention_states, Map.new(ids, &{&1, "Done"}))

      assert %{expired: expired, kept: []} = run(now)
      assert length(expired) == 51
      assert_received {:fetch_states, first}
      assert_received {:fetch_states, [last]}
      assert length(first) == 50
      assert last in ids
    end

    test "an artifact of a repository whose settings can't be read is kept", %{workspace: workspace, now: now} do
      {:ok, artifact} = Artifacts.ingest(write!(workspace, "shot.png", @png), meta("issue-done", "unknown-repo", "shot.png"), roots: [workspace])
      Process.put(:retention_states, %{"issue-done" => "Done"})

      log = capture_log(fn -> assert %{expired: [], kept: [_id]} = run(now) end)
      assert log =~ "Artifact retention keeps the artifacts of repo_key=unknown-repo"
      assert Store.present?(artifact.id)
    end

    test "a store that can't be listed or can't remove a file expires nothing, and logs why", %{workspace: workspace, now: now} do
      ingest!(workspace, "shot.png", @png, "issue-done")
      Process.put(:retention_states, %{"issue-done" => "Done"})

      log = capture_log(fn -> assert %{expired: [], kept: []} = run(now, artifacts: FailingArtifacts) end)
      assert log =~ "Artifact retention could not expire artifact_id="
      assert log =~ "issue_ids=issue-done reason=:eacces"

      Process.put(:retention_list, fn -> {:error, :aborted} end)
      log = capture_log(fn -> assert %{expired: [], kept: []} = run(now, artifacts: FailingArtifacts) end)
      assert log =~ "Artifact retention skipped: the artifacts could not be listed reason=:aborted"
    end
  end

  describe "the server" do
    test "starts with the orchestrator, never in a Symphony process that runs without it" do
      assert Retention in SymphonyElixir.Application.child_specs_for_runtime(%{})
      refute Retention in SymphonyElixir.Application.child_specs_for_runtime(%{"SYMPHONY_DISABLE_ORCHESTRATOR" => "1"})
    end

    test "runs on each message and schedules the next run on the cleanup interval", %{workspace: workspace, now: now} do
      artifact = ingest!(workspace, "shot.png", @png, "issue-done")
      :persistent_term.put({PersistentTracker, :states}, %{"issue-done" => "Done"})
      on_exit(fn -> :persistent_term.erase({PersistentTracker, :states}) end)

      pid = start_supervised!({Retention, name: :retention_test, now: fn -> now end, tracker: PersistentTracker})
      send(pid, :other)
      send(pid, :run)
      :sys.get_state(pid)

      refute Store.present?(artifact.id)
    end

    test "falls back to an hour while symphony.yml can't be read" do
      File.write!(Workflow.symphony_file_path(), "ledger: [unreadable\n")
      Cache.clear()

      assert {:ok, pid} = Retention.start_link(name: :retention_unreadable_test)
      assert %{opts: [name: :retention_unreadable_test]} = :sys.get_state(pid)
      assert Config.artifact_retention_days() == 14
      assert Config.artifact_max_bytes() == 26_214_400
      GenServer.stop(pid)
    end
  end

  defp run(now, opts \\ []), do: Retention.run([now: fn -> now end, tracker: FakeTracker] ++ opts)

  defp ingest!(workspace, name, bytes, issue_id) do
    {:ok, artifact} = Artifacts.ingest(write!(workspace, name, bytes), meta(issue_id, "default", name), roots: [workspace])
    artifact
  end

  defp meta(issue_id, repo_key, label), do: %{repo_key: repo_key, issue_id: issue_id, kind: "screenshot", label: label}

  defp write!(workspace, name, bytes) do
    path = Path.join(workspace, name)
    File.write!(path, bytes)
    path
  end

  defp record_run_ended!(issue_id, artifact_id, now, offset) do
    {:ok, _event} =
      TicketEvents.record("default", issue_id, "run.ended", %{run_id: "run-#{issue_id}-#{offset}", exit: "normal"},
        artifacts: [artifact_id],
        at: DateTime.add(now, offset, :second)
      )
  end

  defp write_symphony_ledger!(lines) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> "ledger:\n" <> lines)
    Cache.clear()
  end

  defp start_endpoint! do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
