defmodule SymphonyElixir.AgentTools.Linear.CommentRegistryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry

  test "start_link/1 with seed_ids pre-populates owned comments" do
    {:ok, pid} = CommentRegistry.start_link(seed_ids: ["c1", "c2"])

    assert CommentRegistry.owned?(pid, "c1")
    assert CommentRegistry.owned?(pid, "c2")
    refute CommentRegistry.owned?(pid, "c3")
  end

  test "start_link/1 with empty or missing seed_ids starts empty" do
    {:ok, pid_empty} = CommentRegistry.start_link(seed_ids: [])
    refute CommentRegistry.owned?(pid_empty, "c1")

    {:ok, pid_default} = CommentRegistry.start_link()
    refute CommentRegistry.owned?(pid_default, "c1")
  end

  test "start_link/1 ignores non-binary entries in seed_ids" do
    {:ok, pid} = CommentRegistry.start_link(seed_ids: ["valid", nil, 123, "also-valid"])

    assert CommentRegistry.owned?(pid, "valid")
    assert CommentRegistry.owned?(pid, "also-valid")
    refute CommentRegistry.owned?(pid, "123")
  end

  test "reserve_subissue/2 claims slots up to the cap and release_subissue/1 gives one back" do
    {:ok, pid} = CommentRegistry.start_link()

    assert :ok = CommentRegistry.reserve_subissue(pid, 2)
    assert :ok = CommentRegistry.reserve_subissue(pid, 2)
    assert {:error, {:subissue_cap_reached, 2}} = CommentRegistry.reserve_subissue(pid, 2)

    assert :ok = CommentRegistry.release_subissue(pid)
    assert :ok = CommentRegistry.reserve_subissue(pid, 2)
  end

  test "reserve_project_update/2 counts separately from sub-issues and release gives a slot back" do
    {:ok, pid} = CommentRegistry.start_link()

    assert :ok = CommentRegistry.reserve_subissue(pid, 1)
    assert :ok = CommentRegistry.reserve_project_update(pid, 1)
    assert {:error, {:project_update_cap_reached, 1}} = CommentRegistry.reserve_project_update(pid, 1)

    assert :ok = CommentRegistry.release_project_update(pid)
    assert :ok = CommentRegistry.reserve_project_update(pid, 1)
    assert {:error, :project_update_registry_unavailable} = CommentRegistry.reserve_project_update(nil, 1)
  end

  test "reserve_document/2 counts its own slots and record_document/2 lists the run's documents" do
    {:ok, pid} = CommentRegistry.start_link()

    assert :ok = CommentRegistry.reserve_document(pid, 1)
    assert {:error, {:document_cap_reached, 1}} = CommentRegistry.reserve_document(pid, 1)
    assert :ok = CommentRegistry.release_document(pid)
    assert :ok = CommentRegistry.reserve_document(pid, 1)
    assert {:error, :document_registry_unavailable} = CommentRegistry.reserve_document(nil, 1)

    assert :ok = CommentRegistry.record_document(pid, "doc-1")
    assert :ok = CommentRegistry.record_document(pid, "doc-1")
    assert CommentRegistry.document_ids(pid) == ["doc-1"]
    assert CommentRegistry.document_ids(nil) == []
  end

  test "reserve_subissue/2 refuses without a registry" do
    assert {:error, :subissue_registry_unavailable} = CommentRegistry.reserve_subissue(nil, 10)
  end
end
