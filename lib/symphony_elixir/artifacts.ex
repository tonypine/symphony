defmodule SymphonyElixir.Artifacts do
  @moduledoc """
  The files a ticket's ledger events point at (a QA pass's screenshots, a run's transcript), kept
  where Symphony owns them: a content-addressed folder (`SymphonyElixir.Artifacts.Store`) with one
  metadata row per file in `SymphonyElixir.RunStore`.

  `ingest/3` copies a file in. Its id is the sha256 of its bytes, so the same bytes ingested twice
  are one file and one row: `references` counts the ingests and `tickets` every ticket that ingested
  them. The source must be a regular file whose resolved path is under one of the folders an agent
  may write (`roots:`), checked before a byte is read: an agent writes the folder it ingests from,
  and Symphony runs outside the agent sandbox.

  `expire/1` removes the bytes and keeps the row, marked `expired`; so does `path/1` when it finds
  the file gone. Ingesting the same bytes again writes them back and clears `expired`.
  `SymphonyElixir.Artifacts.Retention` expires a finished ticket's artifacts once
  `ledger.artifact_retention_days` have passed.
  """

  alias SymphonyElixir.{AgentTmpDir, Config, PathSafety, RunStore}
  alias SymphonyElixir.Artifacts.Store

  @kinds ~w(screenshot transcript log report diff file)
  @kind_mimes %{"screenshot" => ["image/png", "image/jpeg"], "transcript" => ["application/x-ndjson"]}

  @typedoc "One of `screenshot`, `transcript`, `log`, `report`, `diff` and `file`."
  @type kind :: String.t()

  @type ticket :: %{repo_key: String.t(), issue_id: String.t()}

  @typedoc """
  An artifact. `repo_key`, `issue_id`, `run_id`, `label`, `kind`, `mime` and `captured_at` are the
  first ingest's; `projections` holds where the file was published (`linear_url`).
  """
  @type artifact :: %{
          id: String.t(),
          mime: String.t(),
          bytes: non_neg_integer(),
          label: String.t() | nil,
          kind: kind(),
          repo_key: String.t(),
          issue_id: String.t(),
          run_id: String.t() | nil,
          captured_at: DateTime.t(),
          projections: %{optional(:linear_url) => String.t()},
          expired: boolean(),
          expired_at: DateTime.t() | nil,
          references: pos_integer(),
          tickets: [ticket()]
        }

  @type meta :: %{
          required(:repo_key) => String.t(),
          required(:issue_id) => String.t(),
          required(:kind) => kind(),
          optional(:run_id) => String.t() | nil,
          optional(:label) => String.t() | nil
        }

  @typedoc """
  `ingest/3`'s options: `roots:` (the folders the source may sit under; default the repo's
  workspace root, `AgentTmpDir.default_bases/0` and `System.tmp_dir!/0`) and `max_bytes:` (default
  `ledger.artifact_max_bytes`, `Config.artifact_max_bytes/0`, read on each ingest).
  """
  @type ingest_opt :: {:roots, [Path.t()]} | {:max_bytes, pos_integer()}

  @type ingest_error :: :too_large | :unsupported_mime | :outside_roots | :not_a_file | :invalid_meta | term()

  @type list_opt :: {:repo_key, String.t()} | {:issue_id, String.t()} | {:expired, boolean()}

  @doc """
  Copies the file at `path` into the store for the ticket and run `meta` names, and returns its
  artifact. Refused, before a byte is read: a path whose resolved location is outside `roots`
  (`:outside_roots`), a symlink or anything else that isn't a regular file (`:not_a_file`), and a
  file over `max_bytes` (`:too_large`). A `screenshot` that isn't PNG or JPEG, or a `transcript`
  that isn't JSON lines, is `:unsupported_mime`.
  """
  @spec ingest(Path.t(), meta(), [ingest_opt()]) :: {:ok, artifact()} | {:error, ingest_error()}
  def ingest(path, meta, opts \\ []) when is_binary(path) and is_list(opts) do
    max_bytes = Keyword.get_lazy(opts, :max_bytes, &Config.artifact_max_bytes/0)

    with {:ok, meta} <- validate_meta(meta),
         {:ok, source} <- PathSafety.canonicalize(path),
         :ok <- under_roots(source, Keyword.get_lazy(opts, :roots, fn -> default_roots(meta.repo_key) end)),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(Path.expand(path)),
         :ok <- within(size, max_bytes),
         {:ok, bytes} <- File.read(source),
         :ok <- within(byte_size(bytes), max_bytes),
         mime = Store.sniff(bytes, path),
         :ok <- accepts(meta.kind, mime) do
      store(bytes, mime, meta)
    else
      {:ok, %File.Stat{}} -> {:error, :not_a_file}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The artifact of `id`."
  @spec get(String.t()) :: {:ok, artifact()} | {:error, :not_found}
  def get(id) do
    with true <- Store.id?(id),
         %{} = artifact <- RunStore.get_artifact(id) do
      {:ok, artifact}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Where the bytes of `id` sit. An artifact whose file is gone (removed by `expire/1` or by hand) is
  `:expired`, and its row is marked expired with its metadata kept.
  """
  @spec path(String.t()) :: {:ok, Path.t()} | {:error, :not_found | :expired | term()}
  def path(id) do
    with {:ok, artifact} <- get(id),
         {:ok, %{expired: false}} <- present_or_expired(artifact) do
      {:ok, Store.path(id)}
    else
      {:ok, %{expired: true}} -> {:error, :expired}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Records where the artifact of `id` was published: `:linear_url`, its upload to Linear."
  @spec put_projection(String.t(), :linear_url, String.t()) :: {:ok, artifact()} | {:error, :not_found | term()}
  def put_projection(id, :linear_url = name, url) when is_binary(url) do
    update(id, &{:ok, put_in(&1, [:projections, name], url)})
  end

  @doc "Removes the bytes of `id` and keeps its row, marked `expired`."
  @spec expire(String.t()) :: {:ok, artifact()} | {:error, :not_found | term()}
  def expire(id) do
    update(id, fn artifact ->
      with :ok <- Store.remove(id), do: {:ok, expired(artifact)}
    end)
  end

  @doc """
  The artifacts, oldest first. `repo_key:` and `issue_id:` keep the ones a ticket of that repo (and
  issue) ingested; `expired:` keeps the expired ones (`true`) or the others (`false`).
  """
  @spec list([list_opt()]) :: [artifact()] | {:error, term()}
  def list(opts \\ []) when is_list(opts) do
    opts |> Keyword.take([:repo_key, :issue_id, :expired]) |> RunStore.list_artifacts()
  end

  defp validate_meta(%{repo_key: repo_key, issue_id: issue_id, kind: kind} = meta)
       when is_binary(repo_key) and is_binary(issue_id) and issue_id != "" and kind in @kinds do
    meta = %{repo_key: String.trim(repo_key), issue_id: issue_id, kind: kind, run_id: Map.get(meta, :run_id), label: Map.get(meta, :label)}

    if meta.repo_key != "" and Enum.all?([meta.run_id, meta.label], &(is_nil(&1) or is_binary(&1))),
      do: {:ok, meta},
      else: {:error, :invalid_meta}
  end

  defp validate_meta(_meta), do: {:error, :invalid_meta}

  defp default_roots(repo_key) do
    workspace_roots =
      case Config.settings_for_repo(repo_key) do
        {:ok, settings} -> [settings.workspace.root]
        {:error, _reason} -> []
      end

    workspace_roots ++ AgentTmpDir.default_bases() ++ [System.tmp_dir!()]
  end

  defp under_roots(path, roots) do
    if Enum.any?(roots, &under_root?(path, &1)), do: :ok, else: {:error, :outside_roots}
  end

  defp under_root?(path, root) do
    case PathSafety.canonicalize(root) do
      {:ok, root} -> String.starts_with?(path, String.trim_trailing(root, "/") <> "/")
      {:error, _reason} -> false
    end
  end

  defp within(size, max_bytes), do: if(size <= max_bytes, do: :ok, else: {:error, :too_large})

  defp accepts(kind, mime) do
    if mime in Map.get(@kind_mimes, kind, [mime]), do: :ok, else: {:error, :unsupported_mime}
  end

  # The file is written inside the row's transaction, so an ingest, an `expire/1` and `path/1`'s
  # check of the same id never interleave. A restarted transaction writes it again, which is a no-op.
  defp store(bytes, mime, meta) do
    ticket = %{repo_key: meta.repo_key, issue_id: meta.issue_id}

    RunStore.update_artifact(Store.id(bytes), fn existing ->
      with :ok <- Store.write(bytes), do: {:ok, ingested(existing, bytes, mime, meta, ticket)}
    end)
  end

  defp ingested(nil, bytes, mime, meta, ticket) do
    %{
      id: Store.id(bytes),
      mime: mime,
      bytes: byte_size(bytes),
      label: meta.label,
      kind: meta.kind,
      repo_key: meta.repo_key,
      issue_id: meta.issue_id,
      run_id: meta.run_id,
      captured_at: DateTime.utc_now(),
      projections: %{},
      expired: false,
      expired_at: nil,
      references: 1,
      tickets: [ticket]
    }
  end

  defp ingested(artifact, _bytes, _mime, _meta, ticket) do
    %{artifact | references: artifact.references + 1, tickets: Enum.uniq(artifact.tickets ++ [ticket]), expired: false, expired_at: nil}
  end

  defp present_or_expired(%{expired: false, id: id} = artifact) do
    if Store.present?(id),
      do: {:ok, artifact},
      else: update(id, &{:ok, if(Store.present?(id), do: &1, else: expired(&1))})
  end

  defp present_or_expired(artifact), do: {:ok, artifact}

  defp expired(artifact), do: %{artifact | expired: true, expired_at: artifact.expired_at || DateTime.utc_now()}

  defp update(id, fun) do
    if Store.id?(id), do: RunStore.update_artifact(id, &update_found(&1, fun)), else: {:error, :not_found}
  end

  defp update_found(nil, _fun), do: {:error, :not_found}
  defp update_found(artifact, fun), do: fun.(artifact)
end
