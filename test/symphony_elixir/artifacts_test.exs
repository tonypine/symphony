defmodule SymphonyElixir.ArtifactsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Artifacts, Paths}
  alias SymphonyElixir.Artifacts.Store

  @table :symphony_run_store_artifacts
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1>>
  @meta %{repo_key: "repo-a", issue_id: "issue-1", run_id: "run-1", label: "Home screen", kind: "screenshot"}

  setup do
    :ok = RunStore.clear()
    File.rm_rf!(Paths.artifacts_dir())

    base = Path.join(System.tmp_dir!(), "symphony-artifacts-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    outside = Path.join(base, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)

    on_exit(fn ->
      File.rm_rf(base)
      File.rm_rf(Paths.artifacts_dir())
    end)

    %{workspace: workspace, outside: outside, roots: [workspace]}
  end

  describe "the operator's walkthrough" do
    test "ingesting the same screenshot twice leaves one file, referenced twice", %{workspace: workspace, roots: roots} do
      first = write!(workspace, "qa-evidence/home.png", @png)
      second = write!(workspace, "qa-evidence/again/home-copy.png", @png)

      assert {:ok, %{id: id, references: 1}} = Artifacts.ingest(first, @meta, roots: roots)
      assert {:ok, %{id: ^id, references: 2}} = Artifacts.ingest(second, %{@meta | label: "Again"}, roots: roots)

      assert stored_files() == [Store.path(id)]
      assert File.read!(Store.path(id)) == @png
      size = byte_size(@png)
      assert {:ok, %{references: 2, label: "Home screen", mime: "image/png", bytes: ^size}} = Artifacts.get(id)
    end

    test "a file removed by hand reads back as expired, its metadata kept", %{workspace: workspace, roots: roots} do
      {:ok, artifact} = Artifacts.ingest(write!(workspace, "home.png", @png), @meta, roots: roots)
      assert {:ok, path} = Artifacts.path(artifact.id)
      File.rm!(path)

      assert {:error, :expired} = Artifacts.path(artifact.id)
      assert {:ok, %{expired: true, expired_at: %DateTime{}} = expired} = Artifacts.get(artifact.id)
      assert Map.drop(expired, [:expired, :expired_at]) == Map.drop(artifact, [:expired, :expired_at])
      assert {:error, :expired} = Artifacts.path(artifact.id)
    end

    test "a link inside the workspace pointing at a file outside it is refused, and nothing is stored", %{
      workspace: workspace,
      outside: outside,
      roots: roots
    } do
      target = write!(outside, "secret.png", @png)
      link = Path.join(workspace, "qa-evidence/home.png")
      File.mkdir_p!(Path.dirname(link))
      File.ln_s!(target, link)

      assert {:error, :outside_roots} = Artifacts.ingest(link, @meta, roots: roots)
      assert stored_files() == []
      assert Artifacts.list() == []
    end
  end

  describe "content addressing" do
    test "the same bytes from another ticket are one row that lists both tickets", %{workspace: workspace, roots: roots} do
      path = write!(workspace, "home.png", @png)

      assert {:ok, %{id: id}} = Artifacts.ingest(path, @meta, roots: roots)
      assert {:ok, _artifact} = Artifacts.ingest(path, %{@meta | issue_id: "issue-2", run_id: "run-2"}, roots: roots)
      assert {:ok, artifact} = Artifacts.ingest(path, %{@meta | issue_id: "issue-2"}, roots: roots)

      assert %{repo_key: "repo-a", issue_id: "issue-1", run_id: "run-1", references: 3} = artifact
      assert artifact.tickets == [%{repo_key: "repo-a", issue_id: "issue-1"}, %{repo_key: "repo-a", issue_id: "issue-2"}]
      assert id == Store.id(@png) and byte_size(id) == 64
      assert [{@table, ^id, "repo-a", "issue-1", ^artifact}] = :mnesia.dirty_read(@table, id)
    end

    test "two concurrent ingests of the same bytes give one row referenced twice", %{workspace: workspace, roots: roots} do
      paths = [write!(workspace, "a.png", @png), write!(workspace, "b.png", @png)]

      results =
        paths
        |> Enum.map(fn path -> Task.async(fn -> Artifacts.ingest(path, @meta, roots: roots) end) end)
        |> Task.await_many()

      assert results |> Enum.map(fn {:ok, artifact} -> artifact.references end) |> Enum.sort() == [1, 2]
      assert [%{references: 2}] = Artifacts.list()
      assert length(stored_files()) == 1
    end

    test "the row is the artifact table's: a set keyed by id, indexed by repo" do
      assert :mnesia.table_info(@table, :type) == :set
      assert :mnesia.table_info(@table, :attributes) == [:key, :repo_key, :issue_id, :record]
      assert :mnesia.table_info(@table, :index) == [3]
    end

    test "rows survive a run store restart and bytes stay on disk", %{workspace: workspace, roots: roots} do
      {:ok, artifact} = Artifacts.ingest(write!(workspace, "run.jsonl", ~s({"type":"user"}\n)), %{@meta | kind: "transcript"}, roots: roots)

      restart_run_store()

      assert {:ok, ^artifact} = Artifacts.get(artifact.id)
      assert {:ok, path} = Artifacts.path(artifact.id)
      assert File.read!(path) == ~s({"type":"user"}\n)
    end
  end

  describe "the source" do
    test "a path outside the roots is refused", %{outside: outside, roots: roots} do
      assert {:error, :outside_roots} = Artifacts.ingest(write!(outside, "home.png", @png), @meta, roots: roots)
      assert {:error, :outside_roots} = Artifacts.ingest(write!(outside, "home.png", @png), @meta, roots: [])
    end

    test "a path through a symlinked folder that leaves the roots is refused", %{workspace: workspace, outside: outside, roots: roots} do
      write!(outside, "shots/home.png", @png)
      File.ln_s!(Path.join(outside, "shots"), Path.join(workspace, "shots"))

      assert {:error, :outside_roots} = Artifacts.ingest(Path.join(workspace, "shots/home.png"), @meta, roots: roots)
      assert stored_files() == []
    end

    test "a path through a symlinked folder that stays in the roots is read", %{workspace: workspace, roots: roots} do
      write!(workspace, "real/home.png", @png)
      File.ln_s!(Path.join(workspace, "real"), Path.join(workspace, "shots"))

      assert {:ok, %{id: id}} = Artifacts.ingest(Path.join(workspace, "shots/home.png"), @meta, roots: roots)
      assert stored_files() == [Store.path(id)]
    end

    test "a sibling folder sharing the root's name prefix is outside it", %{workspace: workspace, roots: roots} do
      assert {:error, :outside_roots} = Artifacts.ingest(write!(workspace <> "-other", "home.png", @png), @meta, roots: roots)
    end

    test "a symlink to a file inside the roots, a folder and a missing file are refused", %{workspace: workspace, roots: roots} do
      target = write!(workspace, "home.png", @png)
      File.ln_s!(target, Path.join(workspace, "link.png"))

      assert {:error, :not_a_file} = Artifacts.ingest(Path.join(workspace, "link.png"), @meta, roots: roots)
      assert {:error, :not_a_file} = Artifacts.ingest(workspace, @meta, roots: [Path.dirname(workspace)])
      assert {:error, :enoent} = Artifacts.ingest(Path.join(workspace, "missing.png"), @meta, roots: roots)
      assert stored_files() == []
    end

    test "a root that can't be resolved holds nothing", %{workspace: workspace, roots: roots} do
      file = write!(workspace, "home.png", @png)

      assert {:error, :outside_roots} = Artifacts.ingest(file, @meta, roots: [Path.join(file, "sub")])
      assert {:ok, _artifact} = Artifacts.ingest(file, @meta, roots: [Path.join(file, "sub") | roots])
    end

    test "by default the roots are the repo's workspace root and the temp folders" do
      repo_key = Config.repo_key!()
      workspace_root = Config.settings!().workspace.root
      on_exit(fn -> File.rm_rf(workspace_root) end)
      meta = %{@meta | repo_key: repo_key}

      assert {:ok, _artifact} = Artifacts.ingest(write!(workspace_root, "TP-1/home.png", @png), meta)
      assert {:ok, _artifact} = Artifacts.ingest(write!(System.tmp_dir!(), "symphony-artifacts-#{System.unique_integer([:positive])}.png", @jpeg), meta)
      assert {:error, :outside_roots} = Artifacts.ingest(Path.expand("mix.exs"), %{meta | kind: "file"})
    end

    test "a repo with no settings still has the temp folders" do
      path = write!(System.tmp_dir!(), "symphony-artifacts-#{System.unique_integer([:positive])}.png", @png)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{repo_key: "no-such-repo"}} = Artifacts.ingest(path, %{@meta | repo_key: "no-such-repo"})
    end
  end

  describe "the size cap" do
    test "a file one byte over max_bytes is refused and nothing is written", %{workspace: workspace, roots: roots} do
      path = write!(workspace, "big.log", :binary.copy("x", 11))

      assert {:error, :too_large} = Artifacts.ingest(path, %{@meta | kind: "log"}, roots: roots, max_bytes: 10)
      assert stored_files() == []
      assert Artifacts.list() == []
      assert {:ok, %{bytes: 11}} = Artifacts.ingest(path, %{@meta | kind: "log"}, roots: roots, max_bytes: 11)
    end

    test "without max_bytes the cap is ledger.artifact_max_bytes, read on each ingest", %{workspace: workspace, roots: roots} do
      write_workflow_file!(Workflow.workflow_file_path())
      path = write!(workspace, "big.log", :binary.copy("x", 11))
      symphony_yml = Workflow.symphony_file_path()

      File.write!(symphony_yml, File.read!(symphony_yml) <> "ledger:\n  artifact_max_bytes: 10\n")
      Cache.clear()
      assert {:error, :too_large} = Artifacts.ingest(path, %{@meta | kind: "log"}, roots: roots)

      File.write!(symphony_yml, String.replace(File.read!(symphony_yml), "artifact_max_bytes: 10", "artifact_max_bytes: 11"))
      Cache.clear()
      assert {:ok, %{bytes: 11}} = Artifacts.ingest(path, %{@meta | kind: "log"}, roots: roots)
    end
  end

  describe "the mime" do
    test "each mime is sniffed from its fixture", %{workspace: workspace, roots: roots} do
      fixtures = [
        {"shot.png", @png, "screenshot", "image/png"},
        {"shot.jpg", @jpeg, "screenshot", "image/jpeg"},
        {"run.jsonl", ~s({"type":"user"}\n{"type":"assistant"}\n), "transcript", "application/x-ndjson"},
        {"qa-report.md", "# QA report\n", "report", "text/markdown"},
        {"notes.txt", "notes\n", "file", "text/plain"},
        {"agent.log", "started\n", "log", "text/plain"},
        {"change.diff", "diff --git a/x b/x\n", "diff", "application/octet-stream"}
      ]

      for {name, bytes, kind, mime} <- fixtures do
        assert {:ok, %{mime: ^mime, kind: ^kind}} = Artifacts.ingest(write!(workspace, name, bytes), %{@meta | kind: kind}, roots: roots)
      end
    end

    test "a screenshot that isn't PNG or JPEG, or a transcript that isn't JSON lines, is refused", %{workspace: workspace, roots: roots} do
      assert {:error, :unsupported_mime} = Artifacts.ingest(write!(workspace, "shot.txt", "not an image"), @meta, roots: roots)

      assert {:error, :unsupported_mime} =
               Artifacts.ingest(write!(workspace, "run.jsonl", "[1]\n"), %{@meta | kind: "transcript"}, roots: roots)

      assert {:error, :unsupported_mime} = Artifacts.ingest(write!(workspace, "run.png", @png), %{@meta | kind: "transcript"}, roots: roots)
      assert stored_files() == []
    end
  end

  describe "meta" do
    test "an ingest without a ticket, with an unknown kind or with a non-text label is refused", %{workspace: workspace, roots: roots} do
      path = write!(workspace, "home.png", @png)

      for meta <- [
            Map.delete(@meta, :issue_id),
            %{@meta | issue_id: ""},
            %{@meta | repo_key: "  "},
            %{@meta | kind: "video"},
            %{@meta | label: 7},
            %{@meta | run_id: :run},
            nil
          ] do
        assert {:error, :invalid_meta} = Artifacts.ingest(path, meta, roots: roots)
      end

      assert {:ok, %{run_id: nil, label: nil}} = Artifacts.ingest(path, Map.drop(@meta, [:run_id, :label]), roots: roots)
    end
  end

  describe "expire/1" do
    test "removes the bytes and keeps the row; ingesting the same bytes again restores them", %{workspace: workspace, roots: roots} do
      path = write!(workspace, "home.png", @png)
      {:ok, artifact} = Artifacts.ingest(path, @meta, roots: roots)

      assert {:ok, %{expired: true, expired_at: %DateTime{} = expired_at, references: 1}} = Artifacts.expire(artifact.id)
      assert stored_files() == []
      assert {:error, :expired} = Artifacts.path(artifact.id)
      assert {:ok, %{expired_at: ^expired_at}} = Artifacts.expire(artifact.id)

      assert {:ok, %{expired: false, expired_at: nil, references: 2}} = Artifacts.ingest(path, @meta, roots: roots)
      assert {:ok, stored} = Artifacts.path(artifact.id)
      assert File.read!(stored) == @png
    end

    test "an unknown or malformed id is not found" do
      assert {:error, :not_found} = Artifacts.expire(Store.id("never ingested"))
      assert {:error, :not_found} = Artifacts.expire("../../etc/passwd")
    end
  end

  describe "get/1, path/1 and put_projection/3" do
    test "an unknown or malformed id is not found" do
      for id <- [Store.id("never ingested"), "../../etc/passwd", nil] do
        assert {:error, :not_found} = Artifacts.get(id)
        assert {:error, :not_found} = Artifacts.path(id)
      end

      assert {:error, :not_found} = Artifacts.put_projection(Store.id("never ingested"), :linear_url, "https://linear.app/x")
      assert {:error, :not_found} = Artifacts.put_projection("x", :linear_url, "https://linear.app/x")
    end

    test "put_projection records the artifact's Linear upload", %{workspace: workspace, roots: roots} do
      {:ok, artifact} = Artifacts.ingest(write!(workspace, "home.png", @png), @meta, roots: roots)

      assert {:ok, %{projections: %{linear_url: "https://uploads.linear.app/a"}}} =
               Artifacts.put_projection(artifact.id, :linear_url, "https://uploads.linear.app/a")

      assert {:ok, %{projections: %{linear_url: "https://uploads.linear.app/a"}}} = Artifacts.get(artifact.id)
    end
  end

  describe "list/1" do
    test "keeps the artifacts a ticket ingested, and the expired or live ones", %{workspace: workspace, roots: roots} do
      {:ok, a} = Artifacts.ingest(write!(workspace, "a.png", @png), @meta, roots: roots)
      {:ok, b} = Artifacts.ingest(write!(workspace, "b.log", "b\n"), %{@meta | kind: "log", repo_key: "repo-b"}, roots: roots)
      {:ok, _a} = Artifacts.ingest(write!(workspace, "a.png", @png), %{@meta | issue_id: "issue-2"}, roots: roots)
      {:ok, b} = Artifacts.expire(b.id)
      {:ok, a} = Artifacts.get(a.id)

      assert Artifacts.list() == [a, b]
      assert Artifacts.list(repo_key: "repo-a") == [a]
      assert Artifacts.list(repo_key: "repo-b", issue_id: "issue-1") == [b]
      assert Artifacts.list(repo_key: "repo-b", issue_id: "issue-2") == []
      assert Artifacts.list(issue_id: "issue-2") == [a]
      assert Artifacts.list(expired: true) == [b]
      assert Artifacts.list(expired: false, issue_id: "issue-1") == [a]
      assert Artifacts.list(limit: 1) == [a, b]
    end
  end

  describe "the run store's artifact rows" do
    test "put_artifact writes a row keyed by id and refuses one without an id, a ticket or a repo" do
      artifact = %{id: Store.id("x"), repo_key: " repo-a ", issue_id: "issue-1", captured_at: DateTime.utc_now(), tickets: []}

      assert :ok = RunStore.put_artifact(artifact)
      assert RunStore.get_artifact(artifact.id) == %{artifact | repo_key: "repo-a"}
      assert RunStore.list_artifacts([]) == [%{artifact | repo_key: "repo-a"}]
      assert RunStore.list_artifacts(issue_id: "issue-1") == []
      assert RunStore.get_artifact(Store.id("y")) == nil

      assert {:error, :invalid_artifact} = RunStore.put_artifact(%{id: "x"})
      assert {:error, :invalid_repo_key} = RunStore.put_artifact(%{artifact | repo_key: " "})
    end

    test "update_artifact writes nothing when the update fails or names no repo" do
      id = Store.id("x")

      row = fn repo_key -> fn nil -> {:ok, %{issue_id: "issue-1", repo_key: repo_key}} end end

      assert {:error, :nope} = RunStore.update_artifact(id, fn nil -> {:error, :nope} end)
      assert {:error, :invalid_repo_key} = RunStore.update_artifact(id, row.(""))
      assert {:ok, %{id: ^id, repo_key: "repo-a"}} = RunStore.update_artifact(id, row.("repo-a"))
      assert RunStore.get_artifact(id) == %{id: id, issue_id: "issue-1", repo_key: "repo-a"}
    end
  end

  defp write!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  defp stored_files do
    Path.join(Paths.artifacts_dir(), "*/*") |> Path.wildcard(match_dot: true) |> Enum.sort()
  end

  defp restart_run_store do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, RunStore) do
      :ok ->
        {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, RunStore)
        :ok

      {:error, :not_found} ->
        if pid = Process.whereis(RunStore), do: GenServer.stop(pid)
        {:ok, _pid} = GenServer.start(RunStore, [], name: RunStore)
        :ok
    end
  end
end
