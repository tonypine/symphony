defmodule SymphonyElixir.QaAgent.Design do
  @moduledoc """
  The design files a QA pass judges a UI against: the HTML screens and images attached to the
  ticket and to its parent. A plan run attaches its `screens.html` to the parent, so a QA pass on
  a sub-ticket would otherwise not see it. They are downloaded into the pass's private folder
  before the agent starts, so the agent opens them as local files without a Linear key, and
  `SymphonyElixir.QaAgent.prompt/2` names their paths.

  Only files on `uploads.linear.app` are downloaded, and the Linear key is sent to that host
  alone. When an issue has several attachments with the same title (a revised `screens.html`
  attached again), only the newest is kept. A failed read or download is logged and skipped: the
  pass runs with what came through.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.Secret

  @attachment_first 50
  @max_files_per_issue 20
  @max_file_bytes 20 * 1024 * 1024
  @upload_host "uploads.linear.app"
  @extensions ~w(.html .htm .png .jpg .jpeg .gif .webp .svg)
  @folder "design"

  @attachments_query """
  query SymphonyQaDesignAttachments($id: String!, $first: Int!) {
    issue(id: $id) {
      identifier
      attachments(first: $first) {
        nodes { title url createdAt }
      }
      parent {
        identifier
        attachments(first: $first) {
          nodes { title url createdAt }
        }
      }
    }
  }
  """

  @type file :: %{issue: String.t(), title: String.t(), path: Path.t()}

  @doc """
  Downloads the design files attached to `issue` and its parent into `<dir>/#{@folder}/` and
  returns them, the ticket's first. Returns `[]` on a tracker other than Linear.

  Options: `:linear_client` (as `SymphonyElixir.Linear.Client.graphql/3`) and `:download_client`
  (as `Req.get/2`).
  """
  @spec fetch(Issue.t(), Path.t(), Schema.t(), keyword()) :: [file()]
  def fetch(%Issue{id: issue_id} = issue, dir, %Schema{tracker: %{kind: "linear"} = tracker}, opts) when is_binary(issue_id) do
    case attachments(issue_id, opts) do
      {:ok, issues} ->
        target = Path.join(dir, @folder)
        api_key = Secret.unwrap(tracker.api_key)

        for {identifier, attachment} <- issues,
            file = download(identifier, attachment, target, api_key, opts),
            do: file

      {:error, reason} ->
        Logger.warning("QA could not read the design attachments for #{issue.identifier}: #{inspect(reason)}")
        []
    end
  end

  def fetch(_issue, _dir, _settings, _opts), do: []

  defp attachments(issue_id, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    case linear_client.(@attachments_query, %{id: issue_id, first: @attachment_first}, []) do
      {:ok, %{"data" => %{"issue" => %{} = issue}}} ->
        {:ok, design_attachments(issue) ++ design_attachments(issue["parent"])}

      {:ok, body} ->
        {:error, {:unexpected_response, body}}

      {:error, _reason} = error ->
        error
    end
  end

  defp design_attachments(%{"identifier" => identifier} = issue) when is_binary(identifier) do
    (get_in(issue, ["attachments", "nodes"]) || [])
    |> Enum.filter(&design_attachment?/1)
    |> Enum.sort_by(&(&1["createdAt"] || ""), :desc)
    |> Enum.uniq_by(& &1["title"])
    |> Enum.take(@max_files_per_issue)
    |> Enum.map(&{identifier, &1})
  end

  defp design_attachments(_issue), do: []

  defp design_attachment?(%{"title" => title, "url" => url}) when is_binary(title) and is_binary(url) do
    upload_url?(url) and extension(title, url) != nil
  end

  defp design_attachment?(_attachment), do: false

  defp upload_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: @upload_host} -> true
      _uri -> false
    end
  end

  # The title is the file's name when `linear_attach_file` attached it; the URL path may carry it too.
  defp extension(title, url) do
    [title, URI.parse(url).path || ""]
    |> Enum.map(&String.downcase(Path.extname(&1)))
    |> Enum.find(&(&1 in @extensions))
  end

  defp download(identifier, %{"title" => title, "url" => url}, target, api_key, opts) do
    download_client = Keyword.get(opts, :download_client, &Req.get/2)
    path = Path.join(target, file_name(identifier, title, url))
    headers = if is_binary(api_key), do: [{"authorization", api_key}], else: []

    case download_client.(url, headers: headers, decode_body: false, retry: false, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= @max_file_bytes ->
        File.mkdir_p!(target)
        File.write!(path, body)
        %{issue: identifier, title: title, path: path}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        skip(identifier, title, {:too_large, byte_size(body)})

      {:ok, %{status: status}} ->
        skip(identifier, title, {:http_status, status})

      {:error, reason} ->
        skip(identifier, title, reason)
    end
  end

  defp skip(identifier, title, reason) do
    Logger.warning("QA could not download the design file #{inspect(title)} of #{identifier}: #{inspect(reason)}")
    nil
  end

  defp file_name(identifier, title, url) do
    base = title |> Path.basename() |> Path.rootname() |> safe_name()
    "#{safe_name(identifier)}-#{if base == "", do: "file", else: base}#{extension(title, url)}"
  end

  defp safe_name(name), do: name |> String.replace(~r/[^A-Za-z0-9._-]+/, "_") |> String.replace(~r/^[_.]+|[_.]+$/, "")
end
