defmodule SymphonyElixir.Artifacts.Store do
  @moduledoc """
  The bytes of `SymphonyElixir.Artifacts` on disk: a content-addressed folder (by default
  `SymphonyElixir.Paths.artifacts_dir/0`) where the file of id `id` (the lowercase hex sha256 of
  its bytes) sits at `<dir>/<id[0,2]>/<id>`.

  A file is written under a temporary name in its own folder and renamed, so a reader never sees a
  partial file and two writers of the same bytes leave one whole file.
  """

  alias SymphonyElixir.Paths

  @png <<0x89, "PNG\r\n", 0x1A, "\n">>
  @jpeg <<0xFF, 0xD8, 0xFF>>

  @doc "The id of `bytes`: the lowercase hex sha256, 64 characters."
  @spec id(binary()) :: String.t()
  def id(bytes) when is_binary(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc "Whether `id` is an artifact id: 64 lowercase hex characters."
  @spec id?(term()) :: boolean()
  def id?(id), do: is_binary(id) and byte_size(id) == 64 and String.match?(id, ~r/\A[0-9a-f]+\z/)

  @doc "Where the file of `id` sits under `dir`."
  @spec path(String.t(), Path.t()) :: Path.t()
  def path(id, dir \\ Paths.artifacts_dir()), do: Path.join([dir, binary_part(id, 0, 2), id])

  @doc "Whether the file of `id` is there, as a regular file."
  @spec present?(String.t(), Path.t()) :: boolean()
  def present?(id, dir \\ Paths.artifacts_dir()) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path(id, dir)))
  end

  @doc "Writes `bytes` as the file of their id under `dir`, atomically. A file already there is kept."
  @spec write(binary(), Path.t()) :: :ok | {:error, term()}
  def write(bytes, dir \\ Paths.artifacts_dir()) when is_binary(bytes) do
    id = id(bytes)
    target = path(id, dir)

    if present?(id, dir), do: :ok, else: write_new(target, bytes)
  end

  defp write_new(target, bytes) do
    tmp = Path.join(Path.dirname(target), ".#{Path.basename(target)}.tmp-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(tmp, bytes, [:exclusive]),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  @doc """
  The mime type of `bytes`, read from the file named `name`: PNG and JPEG by their magic bytes; a
  UTF-8 `.jsonl` file whose first line is a JSON object is `application/x-ndjson`; UTF-8 `.md` is
  `text/markdown`; UTF-8 `.txt` and `.log` are `text/plain`; anything else is
  `application/octet-stream`.
  """
  @spec sniff(binary(), Path.t()) :: String.t()
  def sniff(<<@png, _rest::binary>>, _name), do: "image/png"
  def sniff(<<@jpeg, _rest::binary>>, _name), do: "image/jpeg"

  def sniff(bytes, name) when is_binary(bytes) do
    if String.valid?(bytes), do: sniff_text(bytes, name |> Path.extname() |> String.downcase()), else: "application/octet-stream"
  end

  defp sniff_text(bytes, ".jsonl") do
    case bytes |> String.split("\n", parts: 2) |> hd() |> Jason.decode() do
      {:ok, %{}} -> "application/x-ndjson"
      _other -> "application/octet-stream"
    end
  end

  defp sniff_text(_bytes, ".md"), do: "text/markdown"
  defp sniff_text(_bytes, ext) when ext in [".txt", ".log"], do: "text/plain"
  defp sniff_text(_bytes, _ext), do: "application/octet-stream"
end
