defmodule SymphonyElixir.GitHub.CiLog do
  @moduledoc """
  The failed jobs of a GitHub Actions run, a single job or a pull request's checks, read with `gh`
  the way the PR watcher reads a red head's log, and bounded for an agent's context or a ticket.

  Each job comes with its failed steps, its check annotations (`Process completed with exit code
  1`, a test's `file:line`) and the last lines of its log (`gh run view --job <id> --log-failed`,
  or `--log` for every step), without `gh`'s job, step and timestamp columns. The read is held to
  one repository: a run or job whose URL is not that repository's is refused, and so, when
  `failed_only` is set, is a job that did not fail.

  The scoped tool `github_ci_log` reads it for any agent run (`SymphonyElixir.AgentTools.GitHub`),
  and the epic review quotes it in the follow-up it files for a red CI (`SymphonyElixir.EpicReview`).
  """

  alias SymphonyElixir.GitHub.PullRequest

  @failed_conclusions ~w(FAILURE TIMED_OUT CANCELLED STARTUP_FAILURE ACTION_REQUIRED)
  @default_line_limit 400
  @line_chars 1_000
  @job_limit 10
  @annotation_limit 50
  @run_fields "databaseId,url,workflowName,jobs"
  @gh_prefix ~r/\A[^\t]*\t[^\t]*\t\x{FEFF}?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z ?/u

  @typedoc "What to read: a workflow run, one job, or the checks of a pull request, by number."
  @type target :: {:run, String.t()} | {:job, String.t()} | {:pr, String.t()}

  @typedoc "One job's read: its failed steps, annotations and the last lines of its log."
  @type job :: %{
          job_id: String.t(),
          run_id: String.t() | nil,
          name: String.t() | nil,
          conclusion: String.t() | nil,
          url: String.t() | nil,
          failed_steps: [String.t()],
          annotations: [String.t()],
          log: String.t(),
          log_lines: non_neg_integer(),
          total_lines: non_neg_integer(),
          truncated: boolean()
        }

  @typedoc "The read: the repository, the target, the jobs read and how many more were left out."
  @type read :: %{
          repo: String.t(),
          target: String.t(),
          workflow: String.t() | nil,
          url: String.t() | nil,
          failed_only: boolean(),
          line_limit: pos_integer(),
          jobs: [job()],
          omitted_jobs: non_neg_integer()
        }

  @doc "How many log lines a job keeps by default, its last ones."
  @spec default_line_limit() :: pos_integer()
  def default_line_limit, do: @default_line_limit

  @doc "How many jobs one read returns at most; the rest are counted in `omitted_jobs`."
  @spec job_limit() :: pos_integer()
  def job_limit, do: @job_limit

  @doc "How many characters a log line or annotation keeps at most."
  @spec line_chars() :: pos_integer()
  def line_chars, do: @line_chars

  @doc """
  The target of a tool call's arguments: exactly one of `run_id`, `job_id` and `pr_number`, each a
  positive integer or a string of digits.
  """
  @spec target(map()) :: {:ok, target()} | {:error, term()}
  def target(args) when is_map(args) do
    case Enum.reject([run: args["run_id"], job: args["job_id"], pr: args["pr_number"]], &is_nil(elem(&1, 1))) do
      [{kind, id}] -> with {:ok, id} <- numeric_id(id), do: {:ok, {kind, id}}
      [] -> {:error, :missing_ci_log_target}
      _several -> {:error, :ambiguous_ci_log_target}
    end
  end

  defp numeric_id(id) when is_integer(id) and id > 0, do: {:ok, Integer.to_string(id)}

  defp numeric_id(id) when is_binary(id) do
    if String.match?(id, ~r/\A[1-9]\d*\z/), do: {:ok, id}, else: {:error, :invalid_ci_log_target}
  end

  defp numeric_id(_id), do: {:error, :invalid_ci_log_target}

  @doc """
  The `owner/repo` (or `host/owner/repo` on GitHub Enterprise) of a GitHub run, job or pull request
  URL, or nil for any other URL.
  """
  @spec repo_from_url(term()) :: String.t() | nil
  def repo_from_url(url) when is_binary(url) do
    case Regex.run(~r{\Ahttps?://([^/\s]+)/([^/\s]+)/([^/\s]+)/(?:actions|pull)/}, url) do
      [_full, "github.com", owner, name] -> "#{owner}/#{name}"
      [_full, host, owner, name] -> "#{host}/#{owner}/#{name}"
      nil -> nil
    end
  end

  def repo_from_url(_url), do: nil

  @doc """
  Reads `target` in `repo` (`owner/repo` or `host/owner/repo`).

  Options: `:failed_only` (default true: only failed jobs, and only their failed steps' log),
  `:line_limit` (the last lines kept per job, default #{@default_line_limit}), and `:gh_runner` and
  `:cwd` for `gh`.
  """
  @spec read(String.t(), target(), keyword()) :: {:ok, read()} | {:error, term()}
  def read(repo, target, opts \\ []) when is_binary(repo) and is_list(opts) do
    failed_only = Keyword.get(opts, :failed_only, true)
    line_limit = Keyword.get(opts, :line_limit, @default_line_limit)

    with {:ok, repo_parts} <- parse_repo(repo),
         {:ok, source, jobs, omitted} <- jobs(repo_parts, target, failed_only, opts),
         {:ok, jobs} <- read_jobs(jobs, repo_parts, failed_only, line_limit, opts) do
      {:ok,
       Map.merge(source, %{
         repo: repo,
         target: target_label(target),
         failed_only: failed_only,
         line_limit: line_limit,
         jobs: jobs,
         omitted_jobs: omitted
       })}
    end
  end

  defp parse_repo(repo) do
    parts = String.split(repo, "/")

    case if("" in parts, do: [], else: parts) do
      [owner, name] -> {:ok, %{host: "github.com", owner: owner, name: name, repo: repo}}
      [host, owner, name] -> {:ok, %{host: host, owner: owner, name: name, repo: repo}}
      _other -> {:error, {:invalid_ci_log_repo, repo}}
    end
  end

  defp target_label({kind, id}), do: "#{kind} #{id}"

  # What the target is, the jobs to read for it in the order GitHub lists them (at most
  # `@job_limit`), and how many more were left out.
  defp jobs(repo, {:run, run_id}, failed_only, opts) do
    with {:ok, output} <- PullRequest.run_gh(["run", "view", run_id, "-R", repo.repo, "--json", @run_fields], opts),
         {:ok, %{} = run} <- decode(output, :invalid_ci_run_payload),
         :ok <- in_repo(run["url"], repo, {:run_not_in_repo, run_id, repo.repo}) do
      jobs = for job <- List.wrap(run["jobs"]), is_map(job), do: normalize_job(job, run_id)

      case select(jobs, failed_only) do
        [] -> {:error, {:no_failed_jobs, run_id}}
        selected -> {:ok, %{workflow: run["workflowName"], url: run["url"]}, Enum.take(selected, @job_limit), omitted(selected)}
      end
    end
  end

  defp jobs(repo, {:job, job_id}, failed_only, opts) do
    with {:ok, job} <- api_job(repo, job_id, opts),
         :ok <- failed_if_required(job, failed_only) do
      {:ok, %{workflow: nil, url: job.url}, [job], 0}
    end
  end

  defp jobs(repo, {:pr, number}, failed_only, opts) do
    pr_url = "https://#{repo.host}/#{repo.owner}/#{repo.name}/pull/#{number}"

    with {:ok, status} <- PullRequest.fetch_ci_status(pr_url, opts) do
      job_ids =
        status
        |> Map.get(:checks, [])
        |> Enum.filter(&(not failed_only or failed?(Map.get(&1, :conclusion))))
        |> Enum.flat_map(&check_job_id(&1, repo))
        |> Enum.uniq()

      case job_ids do
        [] -> {:error, {:no_failed_jobs, {:pr, number}}}
        ids -> api_jobs(repo, ids, pr_url, opts)
      end
    end
  end

  # A pull request's check is read when it is a GitHub Actions job of this repository; a status
  # context or another app's check has no log to read.
  defp check_job_id(%{details_url: url}, repo) when is_binary(url) do
    with :ok <- in_repo(url, repo, :other_repo),
         [_full, job_id] <- Regex.run(~r{/actions/runs/\d+/job/(\d+)}, url) do
      [job_id]
    else
      _other -> []
    end
  end

  defp check_job_id(_check, _repo), do: []

  defp api_jobs(repo, ids, pr_url, opts) do
    ids
    |> Enum.take(@job_limit)
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, jobs} ->
      case api_job(repo, id, opts) do
        {:ok, job} -> {:cont, {:ok, [job | jobs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, %{workflow: nil, url: pr_url}, Enum.reverse(jobs), omitted(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp omitted(jobs), do: max(length(jobs) - @job_limit, 0)

  defp api_job(repo, job_id, opts) do
    with {:ok, output} <- PullRequest.run_gh(api_args(repo, "repos/#{repo.owner}/#{repo.name}/actions/jobs/#{job_id}"), opts),
         {:ok, %{} = job} <- decode(output, :invalid_ci_job_payload),
         :ok <- in_repo(job["html_url"], repo, {:job_not_in_repo, job_id, repo.repo}) do
      {:ok, normalize_job(job, id(job["run_id"]))}
    end
  end

  defp normalize_job(job, run_id) do
    %{
      job_id: id(job["databaseId"] || job["id"]),
      run_id: run_id,
      name: job["name"],
      conclusion: upcase(job["conclusion"]),
      url: job["url"] || job["html_url"],
      failed_steps: for(%{"name" => name} = step <- List.wrap(job["steps"]), failed?(upcase(step["conclusion"])), do: name)
    }
  end

  defp select(jobs, true), do: Enum.filter(jobs, &failed?(&1.conclusion))
  defp select(jobs, false), do: jobs

  defp failed_if_required(_job, false), do: :ok

  defp failed_if_required(job, true) do
    if failed?(job.conclusion), do: :ok, else: {:error, {:job_not_failed, job.job_id, job.conclusion}}
  end

  @doc "Whether a run's, job's or step's conclusion is a failure (`failure`, `timed_out`, `cancelled`, …)."
  @spec failed?(term()) :: boolean()
  def failed?(conclusion), do: is_binary(conclusion) and String.upcase(conclusion) in @failed_conclusions

  # A run or job is this repository's when its URL is under the repository's URL, compared without
  # case as GitHub compares owners and names.
  defp in_repo(url, repo, error) when is_binary(url) do
    prefix = String.downcase("https://#{repo.host}/#{repo.owner}/#{repo.name}/")
    if String.starts_with?(String.downcase(url), prefix), do: :ok, else: {:error, error}
  end

  defp in_repo(_url, _repo, error), do: {:error, error}

  defp read_jobs(jobs, repo, failed_only, line_limit, opts) do
    jobs
    |> Enum.reduce_while({:ok, []}, fn job, {:ok, read} ->
      case read_log(job, repo, failed_only, opts) do
        {:ok, log} ->
          job = job |> Map.merge(tail(log, line_limit)) |> Map.put(:annotations, annotations(job, repo, opts))
          {:cont, {:ok, [job | read]}}

        {:error, reason} ->
          {:halt, {:error, {:ci_log_unavailable, job.job_id, reason}}}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, Enum.reverse(read)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_log(job, repo, failed_only, opts) do
    PullRequest.run_gh(["run", "view", "--job", job.job_id, if(failed_only, do: "--log-failed", else: "--log"), "-R", repo.repo], opts)
  end

  # The job's check annotations, the lines GitHub shows on the run's summary. An unreadable list
  # leaves them out: the log is what the read is for.
  defp annotations(job, repo, opts) do
    with {:ok, output} <- PullRequest.run_gh(api_args(repo, "repos/#{repo.owner}/#{repo.name}/check-runs/#{job.job_id}/annotations"), opts),
         {:ok, list} when is_list(list) <- Jason.decode(output) do
      for(%{} = annotation <- list, do: annotation_line(annotation))
      |> Enum.take(@annotation_limit)
    else
      _unreadable -> []
    end
  end

  defp annotation_line(annotation) do
    place = Enum.reject([annotation["path"], annotation["start_line"]], &(&1 in [nil, ""])) |> Enum.join(":")
    text = Enum.reject([annotation["title"], annotation["message"]], &(&1 in [nil, ""])) |> Enum.join(": ")

    [annotation["annotation_level"], place, text]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> String.replace(~r/\s*\n\s*/, " ")
    |> clip()
  end

  # The last `line_limit` lines of the log, without `gh`'s job, step and timestamp columns, each
  # clipped to `@line_chars`.
  defp tail(log, line_limit) do
    lines = log |> String.replace_invalid("?") |> String.trim_trailing() |> String.split("\n")
    lines = if lines == [""], do: [], else: lines
    kept = Enum.take(lines, -line_limit)

    %{
      log: Enum.map_join(kept, "\n", &(&1 |> String.replace(@gh_prefix, "") |> String.trim_trailing() |> clip())),
      log_lines: length(kept),
      total_lines: length(lines),
      truncated: length(lines) > line_limit
    }
  end

  defp clip(line), do: if(String.length(line) > @line_chars, do: String.slice(line, 0, @line_chars - 1) <> "…", else: line)

  defp api_args(%{host: "github.com"}, endpoint), do: ["api", endpoint]
  defp api_args(%{host: host}, endpoint), do: ["api", "--hostname", host, endpoint]

  defp decode(output, error) do
    case Jason.decode(output) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, error}
    end
  end

  defp id(value) when is_integer(value), do: Integer.to_string(value)
  defp id(value) when is_binary(value), do: value
  defp id(_value), do: nil

  defp upcase(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp upcase(_value), do: nil
end
