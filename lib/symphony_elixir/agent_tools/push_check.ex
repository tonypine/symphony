defmodule SymphonyElixir.AgentTools.PushCheck do
  @moduledoc """
  Holds a `github_push_branch` push to the repo's push check (`push_check` in WORKFLOW.md).

  The tool pushes with repo hooks disabled, and Symphony runs outside the agent sandbox, so it
  never runs workspace code. The agent runs the configured `command` in its own sandbox; the
  command checks what the branch would push and writes `<sha> pass` or `<sha> fail` (then the
  failures, one per line) to `result_file`. Here Symphony only reads that file and plain git
  history: a push whose range changes none of `paths` goes through without a result.
  """

  alias SymphonyElixir.Config.Schema

  @base_refs ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master"]
  @max_result_bytes 16_384
  @max_output_bytes 4_096

  @type git_runner :: ([String.t()] -> {:ok, String.t()} | {:error, term()})
  @type details :: %{required(String.t()) => String.t()}

  @doc """
  Returns `:ok` when the push may go ahead, else why the push check holds it.
  """
  @spec verify(Path.t(), String.t(), Schema.PushCheck.t(), git_runner()) ::
          :ok
          | {:error, {:push_check_required, :missing | :stale | :invalid, details()}}
          | {:error, {:push_check_failed, details()}}
          | {:error, term()}
  def verify(workspace, branch, %Schema.PushCheck{command: command} = config, run_git) when is_binary(command) do
    with {:ok, head} <- commit_sha(run_git, "refs/heads/#{branch}") do
      if checked_change?(branch, head, config.paths, run_git) do
        verify_result(workspace, head, config)
      else
        :ok
      end
    end
  end

  def verify(_workspace, _branch, _config, _run_git), do: :ok

  # The range the push sends: from the branch's remote-tracking ref when this clone has one,
  # else from the merge-base with the default branch. Without either, assume it changes everything.
  defp checked_change?(branch, head, paths, run_git) do
    case push_base(branch, head, run_git) do
      {:ok, base} ->
        case run_git.(["diff", "--name-only", base, head, "--" | paths]) do
          {:ok, output} -> String.trim(output) != ""
          {:error, _reason} -> true
        end

      :none ->
        true
    end
  end

  defp push_base(branch, head, run_git) do
    case commit_sha(run_git, "refs/remotes/origin/#{branch}") do
      {:ok, base} -> {:ok, base}
      {:error, _reason} -> merge_base(head, @base_refs, run_git)
    end
  end

  defp merge_base(_head, [], _run_git), do: :none

  defp merge_base(head, [ref | refs], run_git) do
    case run_git.(["merge-base", head, ref]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _reason} -> merge_base(head, refs, run_git)
    end
  end

  defp commit_sha(run_git, ref) do
    with {:ok, output} <- run_git.(["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
      {:ok, String.trim(output)}
    end
  end

  defp verify_result(workspace, head, config) do
    details = %{"command" => config.command, "result_file" => config.result_file, "head" => head}

    case read_result(Path.join(workspace, config.result_file)) do
      {:ok, content} -> check_result(content, head, details)
      {:error, :enoent} -> {:error, {:push_check_required, :missing, details}}
      {:error, _reason} -> {:error, {:push_check_required, :invalid, details}}
    end
  end

  # Only a small regular file is read; a symlink or a directory planted at the path is not followed.
  defp read_result(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_result_bytes -> File.read(path)
      {:ok, _stat} -> {:error, :not_a_result_file}
      {:error, reason} -> {:error, reason}
    end
  end

  # The recorded failures are echoed back only once the first line names this exact commit, so
  # the path never turns into a way to read some other file.
  defp check_result(content, head, details) do
    [first_line | rest] = String.split(content, "\n", parts: 2)

    case String.split(first_line) do
      [^head, "pass"] ->
        :ok

      [^head, "fail"] ->
        {:error, {:push_check_failed, Map.put(details, "output", failure_output(rest))}}

      [sha, status] when status in ["pass", "fail"] ->
        if String.match?(sha, ~r/\A[0-9a-f]{40,64}\z/) do
          {:error, {:push_check_required, :stale, Map.put(details, "recorded_head", sha)}}
        else
          {:error, {:push_check_required, :invalid, details}}
        end

      _other ->
        {:error, {:push_check_required, :invalid, details}}
    end
  end

  defp failure_output([rest]) do
    rest
    |> String.trim()
    |> clamp(@max_output_bytes)
  end

  defp failure_output([]), do: ""

  defp clamp(text, max_bytes) when byte_size(text) <= max_bytes, do: valid_prefix(text, byte_size(text))
  defp clamp(text, max_bytes), do: valid_prefix(text, max_bytes) <> "\n... (truncated)"

  defp valid_prefix(text, bytes) do
    prefix = binary_part(text, 0, bytes)
    if String.valid?(prefix), do: prefix, else: valid_prefix(text, bytes - 1)
  end
end
