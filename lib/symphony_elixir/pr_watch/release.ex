defmodule SymphonyElixir.PrWatch.Release do
  @moduledoc """
  The newest published release of the repository the macOS app updates from
  (`tonypine/symphony`), kept as a repo fact in the run store: its tag and when it was published.

  Two paths write it, to the same result. A `release` delivery whose action is `published`
  (`record_published/2`) writes it at once. The safety-net tick of one watcher (`poll/1`) reads
  GitHub's `releases/latest` through authenticated `gh`, one conditional request per tick: it sends
  the ETag of the last answer as `If-None-Match`, so an unchanged release is a `304`, which GitHub
  doesn't count against the rate limit. So the fact stays current with deliveries off. Drafts and
  prereleases are never the newest release, as `releases/latest` reads it.
  """

  require Logger

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.RunStore

  @app_repo "tonypine/symphony"

  @type t :: %{
          repo: String.t(),
          tag: String.t(),
          published_at: DateTime.t() | nil,
          etag: String.t() | nil,
          source: :webhook | :poll,
          recorded_at: DateTime.t()
        }

  @doc "The repository the app updates from, as `owner/name`."
  @spec app_repo() :: String.t()
  def app_repo, do: @app_repo

  @doc "The app repository's newest release Symphony knows, or nil. `opts`: `:run_store`."
  @spec latest(keyword()) :: t() | nil
  def latest(opts \\ []) do
    case store(opts).get_github_updates({:release, @app_repo}) do
      %{tag: tag} = release when is_binary(tag) -> release
      _none -> nil
    end
  end

  @doc """
  Records a `published` release delivery when it is the app repository's and newer than the one
  known; anything else is left alone. `opts`: `:run_store`, `:now`.
  """
  @spec record_published(map(), keyword()) :: :recorded | :ignored
  def record_published(%{repo: repo, tag: tag, published_at: published_at, prerelease: false}, opts) do
    known = latest(opts)

    if app_repo?(repo) and newer?(tag, published_at, known) do
      put(%{tag: tag, published_at: published_at, etag: known && known.etag, source: :webhook}, opts)
    else
      :ignored
    end
  end

  def record_published(_release, _opts), do: :ignored

  defp newer?(_tag, _published_at, nil), do: true
  defp newer?(tag, %DateTime{} = at, %{published_at: %DateTime{} = known_at, tag: known}), do: tag != known and DateTime.after?(at, known_at)
  defp newer?(tag, _published_at, %{tag: known}), do: tag != known

  @doc """
  Reads the app repository's newest release, conditionally on the last answer's ETag, and records
  it. `opts`: `:run_store`, `:now`, `:gh_runner`.
  """
  @spec poll(keyword()) :: :recorded | :not_modified | {:error, term()}
  def poll(opts) do
    known = latest(opts)
    conditional = if known && known.etag, do: ["-H", "If-None-Match: #{known.etag}"], else: []
    args = ["api", "--include"] ++ conditional ++ ["repos/#{@app_repo}/releases/latest"]

    case PullRequest.run_gh(args, Keyword.take(opts, [:gh_runner])) do
      {:ok, output} -> answer(output, opts)
      {:error, {:gh_failed, _args, _status, output} = reason} when is_binary(output) -> unless_unchanged(output, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  # `gh api` exits non-zero on a `304`, which only says the release is the one known.
  defp unless_unchanged(output, reason), do: if(status(output) == 304, do: :not_modified, else: {:error, reason})

  defp answer(output, opts) do
    {status, headers, body} = response(output)

    with 200 <- status,
         {:ok, %{"tag_name" => tag} = release} when is_binary(tag) and tag != "" <- Jason.decode(body) do
      put(%{tag: tag, published_at: datetime(Map.get(release, "published_at")), etag: Map.get(headers, "etag"), source: :poll}, opts)
    else
      304 -> :not_modified
      _other -> {:error, {:unexpected_release_answer, status}}
    end
  end

  defp put(release, opts) do
    record = Map.merge(release, %{repo: @app_repo, recorded_at: Keyword.get(opts, :now, &DateTime.utc_now/0).()})

    case store(opts).put_github_updates({:release, @app_repo}, record) do
      :ok ->
        :recorded

      {:error, reason} ->
        Logger.warning("Could not record the newest release of #{@app_repo} tag=#{release.tag} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp response(output) do
    case String.split(output, ~r/\r?\n\r?\n/, parts: 2) do
      [head, body] -> {status(head), headers(head), body}
      [head] -> {status(head), headers(head), ""}
    end
  end

  defp status(output) do
    case Regex.run(~r/\AHTTP\/[\d.]+ (\d{3})/, output) do
      [_line, code] -> String.to_integer(code)
      nil -> nil
    end
  end

  defp headers(head) do
    for line <- String.split(head, ~r/\r?\n/), [name, value] <- [String.split(line, ":", parts: 2)], into: %{} do
      {name |> String.trim() |> String.downcase(), String.trim(value)}
    end
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp datetime(_value), do: nil

  defp app_repo?(repo) when is_binary(repo), do: String.downcase(repo) == @app_repo
  defp app_repo?(_repo), do: false

  defp store(opts), do: Keyword.get(opts, :run_store, RunStore)
end
