defmodule SymphonyElixir.GitHub.FailedLog do
  @moduledoc """
  The failed log of a red head's workflow runs, cut down for a CI Fix run's prompt: the last lines
  of each run's `gh run view --log-failed`, starting at the first line that reads like an error, and
  that first error line alone, which the red backstop's fix ticket quotes as evidence.
  """

  alias SymphonyElixir.GitHub.PullRequest

  @no_run_id "No GitHub Actions run id was available for the failed check."
  @error_line ~r/(error|failed|failure|exception|stacktrace|traceback|panic)/i

  @doc """
  The excerpt of the failed logs of `run_ids`, at most `line_limit` lines each, with the first error
  line found. One run gives its excerpt alone; several are each headed by their run id. No run id
  gives a line saying so. `opts[:github]` replaces `SymphonyElixir.GitHub.PullRequest`; the other
  `opts` go to `gh`.
  """
  @spec read([String.t()], pos_integer(), keyword()) :: {:ok, %{excerpt: String.t(), error: String.t()}} | {:error, term()}
  def read(run_ids, line_limit, opts \\ [])

  def read([], _line_limit, _opts), do: {:ok, %{excerpt: @no_run_id, error: @no_run_id}}

  def read(run_ids, line_limit, opts) when is_list(run_ids) do
    github = Keyword.get(opts, :github, PullRequest)
    gh_opts = Keyword.drop(opts, [:github])

    run_ids
    |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, logs} ->
      case github.fetch_failed_log(run_id, gh_opts) do
        {:ok, log} -> {:cont, {:ok, [{run_id, excerpt(log, line_limit)} | logs]}}
        {:error, reason} -> {:halt, {:error, {:failed_log_unavailable, run_id, reason}}}
      end
    end)
    |> case do
      {:ok, logs} -> {:ok, joined(Enum.reverse(logs))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp joined([{_run_id, excerpt}]), do: %{excerpt: excerpt, error: first_error(excerpt)}

  defp joined([{_run_id, first} | _rest] = logs) do
    %{
      excerpt: Enum.map_join(logs, "\n\n", fn {run_id, excerpt} -> "Run #{run_id} failed log:\n#{excerpt}" end),
      error: Enum.find_value(logs, &error_line(elem(&1, 1))) || first_error(first)
    }
  end

  @doc "The last `line_limit` lines of `log`, from the first one that reads like an error."
  @spec excerpt(term(), pos_integer()) :: String.t()
  def excerpt(log, line_limit) when is_binary(log) and is_integer(line_limit) and line_limit > 0 do
    log
    |> sanitize_utf8()
    |> String.split("\n")
    |> Enum.take(-line_limit)
    |> prefer_error_start()
    |> Enum.join("\n")
  end

  def excerpt(_log, _line_limit), do: ""

  @doc "The first line of `excerpt` that reads like an error, trimmed; else its first line."
  @spec first_error(String.t()) :: String.t()
  def first_error(excerpt) when is_binary(excerpt), do: error_line(excerpt) || excerpt |> lines() |> List.first("")

  defp error_line(excerpt), do: excerpt |> lines() |> Enum.find(&String.match?(&1, @error_line))

  defp lines(excerpt), do: excerpt |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp sanitize_utf8(binary) do
    if String.valid?(binary), do: binary, else: replace_invalid_bytes(binary, <<>>)
  end

  defp replace_invalid_bytes(<<>>, acc), do: acc
  defp replace_invalid_bytes(<<char::utf8, rest::binary>>, acc), do: replace_invalid_bytes(rest, <<acc::binary, char::utf8>>)
  defp replace_invalid_bytes(<<_byte, rest::binary>>, acc), do: replace_invalid_bytes(rest, <<acc::binary, ??::utf8>>)

  defp prefer_error_start(lines) do
    case Enum.find_index(lines, &String.match?(&1, @error_line)) do
      nil -> lines
      index -> Enum.drop(lines, index)
    end
  end
end
