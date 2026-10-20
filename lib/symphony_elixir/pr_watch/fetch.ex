defmodule SymphonyElixir.PrWatch.Fetch do
  @moduledoc """
  The PR and CI watcher's GitHub read, and the facts it builds from it.

  `read/2` reads one pull request in one GraphQL query: its state, draft flag, base and the
  repository's default branch, head and whether its branch still exists, mergeability, merge state,
  auto-merge request and the head's check rollup. An open PR whose branch was deleted reads as
  closed. Its base is compared with the repo's `base_branch` when the caller names one, else with
  the repository's default branch. Run through `gh api --include`, so the response's
  `X-RateLimit-Remaining` and `X-RateLimit-Reset` headers come back with it. Three more reads happen
  only when needed: the checks the base branch requires (unless the caller already knows them;
  `SymphonyElixir.PrWatch.Repo` keeps them 10 minutes per base); for a head with no check at all,
  whether the base branch has workflow files (kept the same way): without them the head has no CI
  (`ci: :none`, D2), with them it waits for its first check (`awaiting_checks`); and, for a red
  head that is neither cancelled nor only a person's to clear, the base branch's latest workflow
  runs, to tell a check that is also red on the base: the job of the same name failed in its
  workflow's latest finished run there and, when the head's failed log names failing tests, every one
  of them failed in the base's job too (`base_red` names the base run, its commit and whether the
  tests or only the names were compared). A read GitHub's rate limit refused is
  `{:error, {:rate_limited, reset_at}}`.

  `failure/3` reads the red head's failure the same-failure streak compares: its failed check and the
  first line of its failed log, once per head.

  `facts/2` turns a read and what Symphony knows of the ticket into
  `SymphonyElixir.PrDecision.Facts`. It is pure. The counts of fix runs, the rerun flag and the
  merge wait come from the ticket, as `SymphonyElixir.PrWatch.Attempts` keeps them, and so do the
  review comments still to address, which the PR review poller reads
  (`SymphonyElixir.PrReviewPoller`). The read also carries what acting on the PR needs (its node
  id, title and body, the failed checks' runs), for `SymphonyElixir.PrDecision.Apply`. Nothing here
  writes to GitHub.
  """

  require Logger

  alias SymphonyElixir.{CiPoller, PrDecision.Facts, PrWatch}
  alias SymphonyElixir.GitHub.{FailedLog, PullRequest}

  @base_runs_limit 30
  @log_lines 20

  @query """
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      defaultBranchRef { name }
      pullRequest(number: $number) {
        id number url title body state isDraft merged baseRefName baseRefOid headRefName headRefOid mergeable mergeStateStatus
        headRef { name }
        autoMergeRequest { enabledAt }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                contexts(first: 100) {
                  nodes {
                    __typename
                    ... on CheckRun {
                      name status conclusion detailsUrl completedAt
                      checkSuite { workflowRun { workflow { name } } }
                    }
                    ... on StatusContext { context state targetUrl createdAt }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @typedoc "What GitHub said of its rate limit on the read: requests left of the window's limit, and when it resets."
  @type rate_limit :: %{
          remaining: non_neg_integer() | nil,
          limit: non_neg_integer() | nil,
          reset_at: DateTime.t() | nil
        }

  @typedoc """
  One pull request as the watcher reads it, normalised. `failure/3` adds the red head's failure, and
  the failed log when it read it.
  """
  @type read :: %{
          optional(:failure) => Facts.failure() | nil,
          optional(:protected_paths) => [String.t()],
          optional(:failed_log) => FailedLog.log(),
          pr_url: String.t(),
          pr_number: pos_integer() | nil,
          pr: :open | :draft | :closed | :merged | :missing,
          base: :ok | :changed,
          base_ref: String.t() | nil,
          base_branch: String.t() | nil,
          head_sha: String.t() | nil,
          auto_merge: :off | :armed,
          mergeable: :clean | :behind | :dirty | :unstable | :blocked | :unknown,
          ci: :pending | :green | :none | :red | :required_missing,
          no_ci: :not_configured | :not_reported,
          awaiting_checks: boolean(),
          missing_checks: [String.t()],
          red_kind: :failure | :cancelled | :human_only | :also_red_on_base,
          base_red: Facts.base_red() | nil,
          failing_check: String.t() | nil,
          failed_checks: [check()],
          check_names: [String.t()],
          run_ids: [String.t()],
          pr_node_id: String.t() | nil,
          pr_title: String.t() | nil,
          pr_description: String.t() | nil,
          head_ref: String.t() | nil,
          base_sha: String.t() | nil,
          rate_limit: rate_limit(),
          required: {String.t(), [String.t()]} | nil,
          workflows: {String.t(), boolean()} | nil,
          comparisons: %{comparison_key() => Facts.base_basis() | :different}
        }

  @typedoc "A comparison of failed logs: the head check's job (its details URL) and the base job's id."
  @type comparison_key :: {String.t() | nil, String.t() | nil}

  @typedoc "A failed check of the head: its name, the workflow run it belongs to and how it ended."
  @type check :: %{
          name: String.t() | nil,
          run_id: String.t() | nil,
          workflow_name: String.t() | nil,
          conclusion: String.t() | nil
        }

  @typedoc """
  What Symphony knows of the ticket, beside its PR: its phase, holds and run, the landing order's
  `ahead` and the open PRs `competing` with it (`SymphonyElixir.PrWatch.Competitors`, `[]` when
  absent), whether review comments wait to be addressed (`review_comments`, `:none` when absent),
  and the counts `SymphonyElixir.PrWatch.Attempts` keeps (`red_attempts`,
  `conflict_attempts`, `rerun_done`, `fix_failures`, `landing_timed_out`), which keep their
  defaults when absent.
  """
  @type ticket :: %{
          required(:phase) => Facts.phase(),
          required(:origin) => Facts.phase() | nil,
          required(:hold) => :none | :needs_decision | :blocked,
          required(:run) => :none | :active,
          required(:max_red_attempts) => pos_integer(),
          required(:ahead) => [Facts.competitor()],
          optional(atom()) => term()
        }

  @doc """
  Reads the pull request at `pr_url` (see the moduledoc). `opts`: `:required_checks`, the checks
  already known per base branch (`%{base => names}`): a base not in it is read, and the read carries
  them as `required: {base, names}` for the caller to keep; `:base_workflows`, whether each base
  branch has workflow files (`%{base => boolean}`), read and carried as `workflows: {base, boolean}`
  the same way; `:base_comparisons`, the comparisons of a red head's failed logs with the base's
  already made (`%{comparison_key => basis}`), not read again, while the ones made now are carried as
  `comparisons`; `:base_branch`, the branch the repo's PRs merge into (else the repository's default
  branch); `:gh_runner` and `:cwd`, passed to `gh`.
  """
  @spec read(String.t(), keyword()) :: {:ok, read()} | {:error, term()}
  def read(pr_url, opts) when is_binary(pr_url) and is_list(opts) do
    with {:ok, %{host: host, owner: owner, repo: repo, number: number}} <- parse(pr_url, opts),
         {:ok, rate_limit, body} <- query(host, owner, repo, number, opts),
         {:ok, repository} <- repository(body, rate_limit) do
      case repository["pullRequest"] do
        %{} = pull -> {:ok, normalize(pr_url, pull, repository, rate_limit, {host, owner, repo}, opts)}
        _missing -> {:ok, missing(pr_url, number, rate_limit)}
      end
    end
  end

  @doc """
  The facts `SymphonyElixir.PrDecision.decide/1` reads, from what Symphony knows of the ticket and
  the read of its PR (nil when the ticket has none).
  """
  @spec facts(ticket(), read() | nil) :: Facts.t()
  def facts(ticket, read) do
    pr_facts =
      case read do
        nil -> %{pr: :missing}
        read -> Map.take(read, [:pr, :pr_number, :base, :base_ref, :auto_merge, :ci, :no_ci, :missing_checks, :red_kind, :base_red, :failing_check, :mergeable])
      end

    ticket
    |> Map.take([:phase, :hold, :run, :max_red_attempts, :ahead, :competing, :review_comments | PrWatch.Attempts.fact_keys()])
    |> Map.put(:origin, if(ticket.phase == :ci_fix, do: ticket.origin))
    |> Map.merge(pr_facts)
    |> Facts.new()
  end

  @doc """
  Whether `reason` (a failed `gh` read) is GitHub's rate limit: `{:rate_limited, reset_at}` with the
  reset time its headers gave, else nil.
  """
  @spec rate_limited(term()) :: {:rate_limited, DateTime.t() | nil} | nil
  def rate_limited({:rate_limited, _reset_at} = limited), do: limited

  def rate_limited({:gh_failed, _args, _status, output}) when is_binary(output) do
    {headers, _body} = split_response(output)

    if output =~ ~r/API rate limit exceeded|secondary rate limit/i or Map.get(headers, "x-ratelimit-remaining") == "0",
      do: {:rate_limited, rate_limit(headers).reset_at}
  end

  def rate_limited(_reason), do: nil

  defp parse(pr_url, opts) do
    case PullRequest.parse_url(pr_url, opts) do
      {:ok, parts} -> {:ok, parts}
      :error -> {:error, :invalid_pr_url}
    end
  end

  defp query(host, owner, repo, number, opts) do
    args = api_args(host) ++ ["-f", "query=#{@query}", "-f", "owner=#{owner}", "-f", "name=#{repo}", "-F", "number=#{number}"]

    case PullRequest.run_gh(args, opts) do
      {:ok, output} ->
        {headers, body} = split_response(output)
        {:ok, rate_limit(headers), body}

      {:error, reason} ->
        case rate_limited(reason) do
          nil -> failed_response(reason)
          limited -> {:error, limited}
        end
    end
  end

  # `gh api graphql` exits non-zero when the response carries GraphQL errors, and appends its own
  # `gh:` line to the output; the body still says what went wrong (a PR that doesn't exist, say).
  defp failed_response({:gh_failed, _args, _status, output} = reason) when is_binary(output) do
    {headers, body} = split_response(output)
    body = String.replace(body, ~r/\n?gh: [^\n]*\s*\z/, "")

    case Jason.decode(body) do
      {:ok, %{"errors" => [_ | _]}} -> {:ok, rate_limit(headers), body}
      _other -> {:error, reason}
    end
  end

  defp failed_response(reason), do: {:error, reason}

  defp api_args("github.com"), do: ["api", "--include", "graphql"]
  defp api_args(host), do: ["api", "--include", "--hostname", host, "graphql"]

  defp repository(body, rate_limit) do
    case Jason.decode(body) do
      {:ok, %{"errors" => [_ | _] = errors} = response} ->
        cond do
          Enum.any?(errors, &(error_type(&1) == "RATE_LIMITED")) -> {:error, {:rate_limited, rate_limit.reset_at}}
          Enum.all?(errors, &(error_type(&1) == "NOT_FOUND")) and is_map(get_in(response, ["data", "repository"])) -> {:ok, response["data"]["repository"]}
          true -> {:error, {:graphql_errors, Enum.map(errors, &error_message/1)}}
        end

      {:ok, %{"data" => %{"repository" => %{} = repository}}} ->
        {:ok, repository}

      {:ok, _other} ->
        {:error, :invalid_pr_payload}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_pr_payload, Exception.message(error)}}
    end
  end

  defp error_type(%{"type" => type}), do: type
  defp error_type(_error), do: nil

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)

  # `gh api --include` prints the status line and headers, a blank line, then the body.
  defp split_response(output) do
    case String.split(output, ~r/\r?\n\r?\n/, parts: 2) do
      [head, body] -> if String.starts_with?(head, "HTTP/"), do: {headers(head), body}, else: {%{}, output}
      [_only] -> {%{}, output}
    end
  end

  defp headers(head) do
    for line <- String.split(head, ~r/\r?\n/), [name, value] <- [String.split(line, ":", parts: 2)], into: %{} do
      {name |> String.trim() |> String.downcase(), String.trim(value)}
    end
  end

  defp rate_limit(headers) do
    %{
      remaining: integer(headers["x-ratelimit-remaining"]),
      limit: integer(headers["x-ratelimit-limit"]),
      reset_at: reset_at(integer(headers["x-ratelimit-reset"]))
    }
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp integer(_value), do: nil

  defp reset_at(seconds) when is_integer(seconds), do: DateTime.from_unix!(seconds)
  defp reset_at(nil), do: nil

  defp missing(pr_url, number, rate_limit) do
    %{
      pr_url: pr_url,
      pr_number: number,
      pr: :missing,
      base: :ok,
      base_ref: nil,
      base_branch: nil,
      head_sha: nil,
      auto_merge: :off,
      mergeable: :unknown,
      ci: :pending,
      no_ci: :not_configured,
      awaiting_checks: false,
      missing_checks: [],
      red_kind: :failure,
      base_red: nil,
      failing_check: nil,
      failed_checks: [],
      check_names: [],
      run_ids: [],
      pr_node_id: nil,
      pr_title: nil,
      pr_description: nil,
      head_ref: nil,
      base_sha: nil,
      rate_limit: rate_limit,
      required: nil,
      workflows: nil,
      comparisons: %{}
    }
  end

  defp normalize(pr_url, pull, repository, rate_limit, repo, opts) do
    base_ref = pull["baseRefName"]
    base_branch = Keyword.get(opts, :base_branch) || get_in(repository, ["defaultBranchRef", "name"])
    head_sha = pull["headRefOid"]
    checks = checks(pr_url, head_sha, pull)
    {names, required} = required(pr_url, base_ref, checks, opts)
    {workflows?, workflows} = workflows(pr_url, base_ref, checks, names, opts)
    ci = ci(checks, names, workflows?)
    failing = Enum.filter(checks, &(PullRequest.check_result(&1) == :failed))
    {red_kind, base_red, comparisons} = red(elem(ci, 0), failing, base_ref, repo, opts)

    %{
      pr_url: pr_url,
      pr_number: pull["number"],
      pr: pr_state(pull),
      base: base(base_ref, base_branch),
      base_ref: base_ref,
      base_branch: base_branch,
      head_sha: head_sha,
      auto_merge: if(is_map(pull["autoMergeRequest"]), do: :armed, else: :off),
      mergeable: mergeable(pull["mergeable"], pull["mergeStateStatus"]),
      ci: elem(ci, 0),
      no_ci: :not_configured,
      awaiting_checks: checks == [] and elem(ci, 0) == :pending,
      missing_checks: elem(ci, 1),
      red_kind: red_kind,
      base_red: base_red,
      failing_check: failing |> Enum.map(& &1.name) |> List.first(),
      failed_checks: Enum.map(failing, &Map.take(&1, [:name, :run_id, :workflow_name, :conclusion])),
      check_names: checks |> Enum.map(& &1.name) |> Enum.uniq(),
      run_ids: run_ids(checks),
      pr_node_id: pull["id"],
      pr_title: pull["title"],
      pr_description: pull["body"],
      head_ref: pull["headRefName"],
      base_sha: pull["baseRefOid"],
      rate_limit: rate_limit,
      required: required,
      workflows: workflows,
      comparisons: comparisons
    }
  end

  defp pr_state(%{"merged" => true}), do: :merged
  defp pr_state(%{"state" => "MERGED"}), do: :merged
  defp pr_state(%{"state" => "CLOSED"}), do: :closed
  # Deleting an open PR's branch leaves nothing to merge: it reads as closed.
  defp pr_state(%{"state" => "OPEN", "headRef" => nil}), do: :closed
  defp pr_state(%{"isDraft" => true}), do: :draft
  defp pr_state(_pull), do: :open

  defp base(base_ref, default) when is_binary(base_ref) and is_binary(default) and base_ref != default, do: :changed
  defp base(_base_ref, _default), do: :ok

  defp mergeable("CONFLICTING", _merge_state), do: :dirty
  defp mergeable(_mergeable, "DIRTY"), do: :dirty
  defp mergeable(_mergeable, "BEHIND"), do: :behind
  defp mergeable(_mergeable, state) when state in ["CLEAN", "HAS_HOOKS"], do: :clean
  defp mergeable(_mergeable, "UNSTABLE"), do: :unstable
  defp mergeable(_mergeable, state) when state in ["BLOCKED", "DRAFT"], do: :blocked
  defp mergeable(_mergeable, _state), do: :unknown

  # The rollup's nodes, in the shape `gh pr view --json statusCheckRollup` gives, normalised and
  # without the checks of superseded runs.
  defp checks(pr_url, head_sha, pull) do
    rollup =
      for node <- List.wrap(get_in(pull, ["commits", "nodes"])),
          context <- List.wrap(get_in(node, ["commit", "statusCheckRollup", "contexts", "nodes"])),
          is_map(context),
          do: Map.put(context, "workflowName", get_in(context, ["checkSuite", "workflowRun", "workflow", "name"]))

    %{pr_url: pr_url, commit_sha: head_sha, checks: PullRequest.normalize_checks(rollup)}
    |> PullRequest.drop_superseded()
    |> Map.fetch!(:checks)
  end

  # The required checks matter only once nothing failed and nothing runs: then a required check
  # that never reported is what keeps the head from green. `{names, read}`: `read` is
  # `{base, names}` when they were read now rather than known.
  defp required(pr_url, base_ref, checks, opts) when is_binary(base_ref) do
    known = Keyword.get(opts, :required_checks, %{})

    cond do
      not Enum.all?(checks, &(PullRequest.check_result(&1) == :passed)) -> {[], nil}
      Map.has_key?(known, base_ref) -> {Map.fetch!(known, base_ref), nil}
      true -> read_required(pr_url, base_ref, opts)
    end
  end

  defp required(_pr_url, _base_ref, _checks, _opts), do: {[], nil}

  defp read_required(pr_url, base_ref, opts) do
    case PullRequest.required_checks(pr_url, base_ref, opts) do
      {:ok, names} ->
        {names, {base_ref, names}}

      {:error, reason} ->
        Logger.warning("PR watch could not read the checks #{base_ref} requires pr_url=#{pr_url} reason=#{inspect(reason)}")
        {[], nil}
    end
  end

  # A head with no check at all and nothing required: whether the base has workflow files tells no
  # CI from CI that hasn't started yet. `{workflows?, read}`, as `required/4`. A base that can't be
  # read counts as having workflows, so the head waits rather than skipping CI it has.
  defp workflows(pr_url, base_ref, [], [], opts) when is_binary(base_ref) do
    case Map.fetch(Keyword.get(opts, :base_workflows, %{}), base_ref) do
      {:ok, workflows?} -> {workflows?, nil}
      :error -> read_workflows(pr_url, base_ref, opts)
    end
  end

  defp workflows(_pr_url, _base_ref, _checks, _required, _opts), do: {true, nil}

  defp read_workflows(pr_url, base_ref, opts) do
    case PullRequest.workflow_files?(pr_url, base_ref, opts) do
      {:ok, workflows?} ->
        {workflows?, {base_ref, workflows?}}

      {:error, reason} ->
        Logger.warning("PR watch could not read the workflows of #{base_ref} pr_url=#{pr_url} reason=#{inspect(reason)}")
        {true, nil}
    end
  end

  defp ci(checks, required, workflows?) do
    results = Enum.map(checks, &PullRequest.check_result/1)
    missing = required -- Enum.map(checks, & &1.name)

    cond do
      :failed in results -> {:red, []}
      :pending in results -> {:pending, []}
      missing != [] -> {:required_missing, missing}
      checks == [] and workflows? -> {:pending, []}
      checks == [] -> {:none, []}
      true -> {:green, []}
    end
  end

  defp run_ids(checks), do: checks |> Enum.map(&Map.get(&1, :run_id)) |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

  @doc """
  The read with the red head's failure (`failure`): its first failed check and the first error line
  of the failed log (`SymphonyElixir.GitHub.FailedLog`), the signature the same-failure streak
  compares, for a red head that is a plain failure. `known` is the failure already read for a head:
  when it is this head's, the log isn't read again. A log read now is carried too (`failed_log`),
  so a CI Fix sent on this read doesn't read it a second time. Any other read, or a log that can't
  be read, has no failure. `opts`: `:line_limit` (the excerpt's lines), `:github` and `:gh_runner`.
  """
  @spec failure(read(), Facts.failure() | nil, keyword()) :: read()
  def failure(%{ci: :red, red_kind: :failure, head_sha: head} = read, known, opts) when is_binary(head) do
    case known do
      %{head_sha: ^head} -> Map.put(read, :failure, known)
      _other -> read_failure(read, head, opts)
    end
  end

  def failure(read, _known, _opts), do: Map.put(read, :failure, nil)

  defp read_failure(read, head, opts) do
    run_ids = run_ids(Map.get(read, :failed_checks, []))
    log_opts = Keyword.take(opts, [:github, :gh_runner]) ++ repo_opts(read.pr_url, opts)

    case FailedLog.read(run_ids, Keyword.get(opts, :line_limit, @log_lines), log_opts) do
      {:ok, log} ->
        read
        |> Map.put(:failure, %{check: read.failing_check || "a check", error: log.error, head_sha: head})
        |> Map.put(:failed_log, log)

      {:error, reason} ->
        Logger.warning("PR watch could not read the failed log of #{head} pr_url=#{read.pr_url} reason=#{inspect(reason)}")
        Map.put(read, :failure, nil)
    end
  end

  @doc """
  The `repo:` option `gh run` needs for the repository of `pr_url` when it doesn't run in a clone of
  it (`owner/repo`, or `host/owner/repo` on GitHub Enterprise); none for a URL that isn't a PR's.
  """
  @spec repo_opts(String.t() | nil, keyword()) :: keyword()
  def repo_opts(pr_url, opts \\ []) do
    case PullRequest.parse_url(pr_url, opts) do
      {:ok, %{host: "github.com", owner: owner, repo: repo}} -> [repo: "#{owner}/#{repo}"]
      {:ok, %{host: host, owner: owner, repo: repo}} -> [repo: "#{host}/#{owner}/#{repo}"]
      :error -> []
    end
  end

  # The kind of a red head, what it was compared with on the base when it is red there too, and the
  # comparisons of failed logs read now: `{red_kind, base_red, comparisons}`.
  defp red(:red, failing, base_ref, repo, opts) do
    cond do
      Enum.all?(failing, &CiPoller.human_only_check?/1) -> {:human_only, nil, %{}}
      Enum.all?(failing, &(&1.conclusion == "CANCELLED")) -> {:cancelled, nil, %{}}
      true -> red_on_base(failing, base_ref, repo, opts)
    end
  end

  defp red(_ci, _failing, _base_ref, _repo, _opts), do: {:failure, nil, %{}}

  # Each failing check is red on the base too: the job of the same name failed in its workflow's
  # latest finished run on the base and, when the head's failed log names failing tests, failed every
  # one of them there too. A head log that names none, or a log that can't be read, leaves the
  # comparison by name only. The base red names the first check's base run and commit.
  defp red_on_base(failing, base_ref, {host, owner, name}, opts) when is_binary(base_ref) do
    repo = if host == "github.com", do: "#{owner}/#{name}", else: "#{host}/#{owner}/#{name}"
    opts = Keyword.put(opts, :repo, repo)

    with false <- Enum.any?(failing, &is_nil(&1.workflow_name)),
         {:ok, runs} <- PullRequest.list_branch_runs(repo, base_ref, Keyword.put(opts, :limit, @base_runs_limit)) do
      latest = runs |> Enum.filter(&(&1.status == "COMPLETED")) |> Enum.uniq_by(& &1.workflow_name) |> Map.new(&{&1.workflow_name, &1})
      {base_red, _jobs, compared} = Enum.reduce(failing, {nil, %{}, %{}}, &on_base(&1, latest, &2, opts))
      if base_red, do: {:also_red_on_base, base_red, compared}, else: {:failure, nil, compared}
    else
      _unknown -> {:failure, nil, %{}}
    end
  end

  defp red_on_base(_failing, _base_ref, _repo, _opts), do: {:failure, nil, %{}}

  # One failing check against the base, after the checks before it: `{base_red, jobs, compared}`,
  # with each base run's jobs read once (`jobs`). The base red is `false` once a check isn't red on
  # the base.
  defp on_base(_check, _latest, {false, _jobs, _compared} = acc, _opts), do: acc

  defp on_base(check, latest, {base_red, jobs, compared}, opts) do
    case Map.get(latest, check.workflow_name) do
      %{conclusion: "FAILURE", id: run_id} when is_binary(run_id) ->
        {jobs, read} = base_jobs(jobs, run_id, opts)
        {base_red, compared} = same_job(check, run_id, read, base_red, compared, opts)
        {base_red, jobs, compared}

      _green_or_none ->
        {false, jobs, compared}
    end
  end

  defp same_job(check, run_id, {:ok, %{head_sha: sha, jobs: jobs}}, base_red, compared, opts) do
    case Enum.find(jobs, &(&1.name == check.name and &1.conclusion == "FAILURE")) do
      nil ->
        {false, compared}

      job ->
        {basis, compared} = basis(check, run_id, job, compared, opts)
        {with_basis(base_red, basis, %{check: check.name, sha: sha, run_id: run_id}), compared}
    end
  end

  defp same_job(_check, _run_id, {:error, _reason}, _base_red, compared, _opts), do: {false, compared}

  defp base_jobs(jobs, run_id, opts) do
    case Map.fetch(jobs, run_id) do
      {:ok, read} ->
        {jobs, read}

      :error ->
        read = PullRequest.run_jobs(run_id, opts)
        {Map.put(jobs, run_id, read), read}
    end
  end

  # The first check names the base red; one compared by name only makes the whole comparison so.
  defp with_basis(_base_red, :different, _compared), do: false
  defp with_basis(nil, basis, compared), do: Map.put(compared, :basis, basis)
  defp with_basis(base_red, :name, _compared), do: %{base_red | basis: :name}
  defp with_basis(base_red, :tests, _compared), do: base_red

  # Whether the head's check failed the same tests as the base's job of its name: `:tests` when the
  # base job failed every test the head's failed log names, `:different` when it didn't, `:name` when
  # the head's log names none or a log can't be read. A comparison already made for the same head
  # job and base job (`:base_comparisons`) isn't read again; one made from both logs now joins
  # `compared`, for the caller to keep.
  defp basis(check, run_id, job, compared, opts) do
    key = {check.details_url, job.id}

    case Map.fetch(Keyword.get(opts, :base_comparisons, %{}), key) do
      {:ok, basis} ->
        {basis, compared}

      :error ->
        case compare_tests(check, run_id, Keyword.take(opts, [:gh_runner, :cwd, :repo])) do
          {:read, basis} -> {basis, Map.put(compared, key, basis)}
          :unread -> {:name, compared}
        end
    end
  end

  defp compare_tests(check, run_id, opts) do
    with {:ok, head_log} <- PullRequest.fetch_failed_log(check.run_id, opts),
         [_ | _] = head <- FailedLog.failed_tests(head_log, check.name),
         {:ok, base_log} <- PullRequest.fetch_failed_log(run_id, opts) do
      {:read, if(head -- FailedLog.failed_tests(base_log, check.name) == [], do: :tests, else: :different)}
    else
      [] -> {:read, :name}
      {:error, _reason} -> :unread
    end
  end
end
