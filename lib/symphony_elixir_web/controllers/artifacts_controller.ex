defmodule SymphonyElixirWeb.ArtifactsController do
  @moduledoc """
  The read-only routes to a ticket's artifacts (`SymphonyElixir.Artifacts`), the files its ledger
  events name by id:

      GET /api/v1/artifacts/:id
      GET /api/v1/artifacts/:id/meta

  The first answers the bytes, sent from the file, with the artifact's mime as `Content-Type`
  (`; charset=utf-8` for text), `Cache-Control: public, max-age=31536000, immutable` (the id is the
  bytes' sha256, so they never change), `X-Content-Type-Options: nosniff` and a
  `Content-Disposition` naming the label as file name: `inline`, or `attachment` for
  `application/octet-stream`. The second answers the artifact's metadata as JSON.

  An expired artifact, or one whose file is gone (which the store then marks expired), is 410 on
  both, with the metadata in the body. An id that is not 64 lowercase hex characters is 404 before
  any store or filesystem lookup, so no path can be traversed; an unknown one is 404 too. Like the
  other reads of `/api/v1`, it needs no token.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Artifacts
  alias SymphonyElixir.Artifacts.Store

  # Every mime the store sniffs from text is sniffed only from valid UTF-8.
  @utf8_mimes ["application/x-ndjson"]

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"id" => id}) do
    with_artifact(conn, id, fn artifact, path ->
      conn
      |> put_resp_header("content-type", content_type(artifact.mime))
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", content_disposition(artifact))
      |> send_file(200, path)
    end)
  end

  @spec meta(Conn.t(), map()) :: Conn.t()
  def meta(conn, %{"id" => id}) do
    with_artifact(conn, id, fn artifact, _path -> json(conn, meta_json(artifact)) end)
  end

  # `Artifacts.path/1` checks the file is there and marks the row expired when it is not, so the
  # metadata of an expired artifact is read after it. A store error that is neither raises.
  defp with_artifact(conn, id, fun) do
    with true <- Store.id?(id) || {:error, :not_found},
         {:ok, artifact} <- Artifacts.get(id),
         {:ok, path} <- Artifacts.path(id) do
      fun.(artifact, path)
    else
      {:error, :not_found} -> not_found(conn, id)
      {:error, :expired} -> expired(conn, id)
    end
  end

  defp not_found(conn, id) do
    conn
    |> put_status(404)
    |> json(%{error: %{code: "artifact_not_found", message: "No artifact #{inspect(id)}"}})
  end

  defp expired(conn, id) do
    {:ok, artifact} = Artifacts.get(id)

    conn
    |> put_status(410)
    |> json(Map.put(meta_json(artifact), :error, %{code: "artifact_expired", message: "Artifact #{id} expired"}))
  end

  defp content_type("text/" <> _subtype = mime), do: mime <> "; charset=utf-8"
  defp content_type(mime) when mime in @utf8_mimes, do: mime <> "; charset=utf-8"
  defp content_type(mime), do: mime

  # The quoted `filename` keeps printable ASCII only; a label with anything else also gets the
  # RFC 5987 `filename*`, which browsers prefer.
  defp content_disposition(artifact) do
    type = if artifact.mime == "application/octet-stream", do: "attachment", else: "inline"
    name = artifact.label || artifact.id
    ascii = String.replace(name, ~r/[^\x20-\x7E]|["\\]/u, "_")

    if ascii == name,
      do: ~s(#{type}; filename="#{ascii}"),
      else: ~s(#{type}; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
  end

  defp meta_json(artifact) do
    %{
      id: artifact.id,
      mime: artifact.mime,
      bytes: artifact.bytes,
      label: artifact.label,
      kind: artifact.kind,
      repo_key: artifact.repo_key,
      issue_id: artifact.issue_id,
      run_id: artifact.run_id,
      captured_at: iso8601(artifact.captured_at),
      projections: artifact.projections,
      expired: artifact.expired,
      expired_at: iso8601(artifact.expired_at),
      references: artifact.references
    }
  end

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(nil), do: nil
end
