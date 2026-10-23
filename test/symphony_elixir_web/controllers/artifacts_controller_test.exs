defmodule SymphonyElixirWeb.ArtifactsControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias SymphonyElixir.{Artifacts, Paths}
  alias SymphonyElixir.Artifacts.Store

  @endpoint SymphonyElixirWeb.Endpoint
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>
  @transcript ~s({"type":"system","subtype":"init"}\n{"type":"assistant","message":"Hi"}\n)
  @meta %{repo_key: "repo-a", issue_id: "issue-1", run_id: "run-1", label: "Home screen", kind: "screenshot"}
  @immutable "public, max-age=31536000, immutable"

  setup do
    :ok = RunStore.clear()
    File.rm_rf!(Paths.artifacts_dir())

    workspace = Path.join(System.tmp_dir!(), "symphony-artifacts-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(Paths.artifacts_dir())
    end)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    %{workspace: workspace}
  end

  describe "the operator's walkthrough" do
    test "a stored screenshot opens in the browser: its bytes, as an inline PNG", %{workspace: workspace} do
      artifact = ingest!(workspace, "home.png", @png, @meta)

      conn = get(build_conn(), "/api/v1/artifacts/#{artifact.id}")

      assert response(conn, 200) == @png
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "cache-control") == [@immutable]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="Home screen")]
    end

    test "a screenshot whose file is gone from the store is 410 with its metadata, and a made-up id is 404", %{workspace: workspace} do
      artifact = ingest!(workspace, "home.png", @png, @meta)
      File.rm!(Store.path(artifact.id))

      for path <- ["/api/v1/artifacts/#{artifact.id}", "/api/v1/artifacts/#{artifact.id}/meta"] do
        body = json_response(get(build_conn(), path), 410)

        assert %{"id" => id, "expired" => true, "expired_at" => expired_at, "label" => "Home screen", "error" => %{"code" => "artifact_expired"}} = body
        assert id == artifact.id
        assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(expired_at)
      end

      made_up = String.duplicate("ab", 32)

      for path <- ["/api/v1/artifacts/#{made_up}", "/api/v1/artifacts/#{made_up}/meta"] do
        assert %{"error" => %{"code" => "artifact_not_found"}} = json_response(get(build_conn(), path), 404)
      end
    end
  end

  describe "GET /api/v1/artifacts/:id" do
    test "a JSON-lines transcript is its exact bytes, as UTF-8 text", %{workspace: workspace} do
      artifact = ingest!(workspace, "transcript.jsonl", @transcript, %{@meta | kind: "transcript", label: "transcript.jsonl"})

      conn = get(build_conn(), "/api/v1/artifacts/#{artifact.id}")

      assert response(conn, 200) == @transcript
      assert get_resp_header(conn, "content-type") == ["application/x-ndjson; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == [@immutable]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="transcript.jsonl")]
    end

    test "other text is UTF-8, raw bytes are an attachment, and a label beyond plain ASCII is encoded", %{workspace: workspace} do
      log = ingest!(workspace, "run.log", "line one\n", %{@meta | kind: "log", label: nil})
      blob = ingest!(workspace, "blob.bin", <<0, 1, 2, 255>>, %{@meta | kind: "file", label: ~s(Résumé "draft")})

      log_conn = get(build_conn(), "/api/v1/artifacts/#{log.id}")
      assert response(log_conn, 200) == "line one\n"
      assert get_resp_header(log_conn, "content-type") == ["text/plain; charset=utf-8"]
      assert get_resp_header(log_conn, "content-disposition") == [~s(inline; filename="#{log.id}")]

      blob_conn = get(build_conn(), "/api/v1/artifacts/#{blob.id}")
      assert response(blob_conn, 200) == <<0, 1, 2, 255>>
      assert get_resp_header(blob_conn, "content-type") == ["application/octet-stream"]

      assert get_resp_header(blob_conn, "content-disposition") == [
               ~s(attachment; filename="R_sum_ _draft_"; filename*=UTF-8''R%C3%A9sum%C3%A9%20%22draft%22)
             ]
    end

    test "a file removed by hand is 410, and the store marks it expired", %{workspace: workspace} do
      artifact = ingest!(workspace, "home.png", @png, @meta)
      File.rm!(Store.path(artifact.id))

      assert %{"expired" => true, "error" => %{"code" => "artifact_expired"}} = json_response(get(build_conn(), "/api/v1/artifacts/#{artifact.id}"), 410)
      assert {:ok, %{expired: true, expired_at: %DateTime{}}} = Artifacts.get(artifact.id)

      other = ingest!(workspace, "other.png", @png <> "other", @meta)
      File.rm!(Store.path(other.id))

      assert %{"expired" => true} = json_response(get(build_conn(), "/api/v1/artifacts/#{other.id}/meta"), 410)
      assert {:ok, %{expired: true}} = Artifacts.get(other.id)
    end

    test "an id that is not 64 lowercase hex characters is 404, even with a row and a file under that name" do
      id = String.duplicate("ab", 32)
      upper = String.upcase(id)
      short = binary_part(id, 0, 63)
      traversal = "../../etc/passwd"

      for planted <- [upper, short] do
        File.mkdir_p!(Path.dirname(Store.path(planted)))
        File.write!(Store.path(planted), @png)
      end

      for planted <- [upper, short, traversal] do
        :ok = RunStore.put_artifact(Map.merge(row(), %{id: planted}))
      end

      for raw <- [upper, short, "..%2F..%2Fetc%2Fpasswd"], suffix <- ["", "/meta"] do
        conn = get(build_conn(), "/api/v1/artifacts/#{raw}#{suffix}")

        assert %{"error" => %{"code" => "artifact_not_found"}} = json_response(conn, 404)
        assert conn.path_params["id"] in [upper, short, traversal]
      end
    end

    test "any other method is 405 on both routes" do
      id = String.duplicate("ab", 32)

      for path <- ["/api/v1/artifacts/#{id}", "/api/v1/artifacts/#{id}/meta"] do
        assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(post(build_conn(), path, %{}), 405)
        assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(delete(build_conn(), path), 405)
        assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(put(build_conn(), path, %{}), 405)
      end
    end
  end

  describe "GET /api/v1/artifacts/:id/meta" do
    test "answers the artifact's metadata", %{workspace: workspace} do
      artifact = ingest!(workspace, "home.png", @png, @meta)
      {:ok, artifact} = Artifacts.put_projection(artifact.id, :linear_url, "https://uploads.example/home.png")

      body = json_response(get(build_conn(), "/api/v1/artifacts/#{artifact.id}/meta"), 200)

      assert body == %{
               "id" => artifact.id,
               "mime" => "image/png",
               "bytes" => byte_size(@png),
               "label" => "Home screen",
               "kind" => "screenshot",
               "repo_key" => "repo-a",
               "issue_id" => "issue-1",
               "run_id" => "run-1",
               "captured_at" => DateTime.to_iso8601(artifact.captured_at),
               "projections" => %{"linear_url" => "https://uploads.example/home.png"},
               "expired" => false,
               "expired_at" => nil,
               "references" => 1
             }
    end
  end

  defp ingest!(workspace, name, bytes, meta) do
    path = Path.join(workspace, name)
    File.write!(path, bytes)
    {:ok, artifact} = Artifacts.ingest(path, meta, roots: [workspace])
    artifact
  end

  defp row do
    %{
      mime: "image/png",
      bytes: byte_size(@png),
      label: "Planted",
      kind: "screenshot",
      repo_key: "repo-a",
      issue_id: "issue-1",
      run_id: nil,
      captured_at: DateTime.utc_now(),
      projections: %{},
      expired: false,
      expired_at: nil,
      references: 1,
      tickets: [%{repo_key: "repo-a", issue_id: "issue-1"}]
    }
  end
end
