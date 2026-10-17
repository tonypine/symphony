defmodule SymphonyElixir.PrWatch.Fetch do
  @moduledoc """
  The PR and CI watcher's GitHub read, and the facts it builds from it.

  `read/2` reads one pull request in one GraphQL query: its state, draft flag, base and the
  repository's default branch, head, mergeability, merge state, auto-merge request, review decision,
  review threads and the head's check rollup. Run through `gh api --include`, so the response's
  `X-RateLimit-Remaining` and `X-RateLimit-Reset` headers come back with it. Two more reads happen
  only when needed: the checks the base branch requires (unless the caller already knows them;
  `SymphonyElixir.PrWatch.Repo` keeps them 10 minutes per base), and, for a red
  head that is neither cancelled nor only a person's to clear, the base branch's latest workflow
  runs, to tell a check that is also red on the base. A read GitHub's rate limit refused is
  `{:error, {:rate_limited, reset_at}}`.

  `facts/2` turns a read and what Symphony knows of the ticket into
  `SymphonyElixir.PrDecision.Facts`. It is pure. The counts of fix runs, the rerun flag and the
  merge wait come from the ticket, as `SymphonyElixir.PrWatch.Attempts` keeps them. The read also
  carries what acting on the PR needs (its node id, title and body, the failed checks' runs), for
  `SymphonyElixir.PrDecision.Apply`. Nothing here writes to GitHub.
  """

  require Logger

  alias SymphonyElixir.{CiPoller, PrDecision.Facts, PrWatch}
  alias SymphonyElixir.GitHub.PullRequest

  @base_runs_limit 30

  @query """
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      defaultBranchRef { name }
      pullRequest(number: $number) {
        id number url title body state isDraft merged baseRefName baseRefOid headRefName headRefOid mergeable mergeStateStatus reviewDecision
        autoMergeRequest { enabledAt }
        reviewThreads(first: 100) { nodes { isResolved isOutdated } }
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

  @typedoc "What GitHub said of its rate limit on the read: requests left and when the window resets."
  @type rate_limit :: %{remaining: non_neg_integer() | nil, reset_at: DateTime.t() | nil}

  @typedoc "One pull request as the watcher reads it, normalised."
  @type read :: %{
          pr_url: String.t(),
          pr_number: pos_integer() | nil,
          pr: :open | :draft | :closed | :merged | :missing,
          base: :ok | :changed,
          base_ref: String.t() | nil,
          head_sha: String.t() | nil,
          auto_merge: :off | :armed,
          review_comments: :none | :unaddressed,
          mergeable: :clean | :behind | :dirty | :unstable | :blocked | :unknown,
          ci: :pending | :green | :none | :red | :required_missing,
          missing_checks: [String.t()],
          red_kind: :failure | :cancelled | :human_only | :also_red_on_base,
          failing_check: String.t() | nil,
          failed_checks: [check()],
          check_names: [String.t()],
          pr_node_id: String.t() | nil,
          pr_title: String.t() | nil,
          pr_description: String.t() | nil,
          head_ref: String.t() | nil,
          base_sha: String.t() | nil,
          rate_limit: rate_limit(),
          required: {String.t(), [String.t()]} | nil
        }

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
  absent), and the counts `SymphonyElixir.PrWatch.Attempts` keeps (`red_attempts`,
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
  them as `required: {base, names}` for the caller to keep; `:gh_runner` and `:cwd`, passed to `gh`.
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
        read -> Map.take(read, [:pr, :pr_number, :base, :auto_merge, :review_comments, :ci, :missing_checks, :red_kind, :failing_check, :mergeable])
      end

    ticket
    |> Map.take([:phase, :hold, :run, :max_red_attempts, :ahead, :competing | PrWatch.Attempts.fact_keys()])
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
    %{remaining: integer(headers["x-ratelimit-remaining"]), reset_at: reset_at(integer(headers["x-ratelimit-reset"]))}
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
      head_sha: nil,
      auto_merge: :off,
      review_comments: :none,
      mergeable: :unknown,
      ci: :pending,
      missing_checks: [],
      red_kind: :failure,
      failing_check: nil,
      failed_checks: [],
      check_names: [],
      pr_node_id: nil,
      pr_title: nil,
      pr_description: nil,
      head_ref: nil,
      base_sha: nil,
      rate_limit: rate_limit,
      required: nil
    }
  end

  defp normalize(pr_url, pull, repository, rate_limit, repo, opts) do
    base_ref = pull["baseRefName"]
    head_sha = pull["headRefOid"]
    checks = checks(pr_url, head_sha, pull)
    {names, required} = required(pr_url, base_ref, checks, opts)
    ci = ci(checks, names)
    failing = Enum.filter(checks, &(PullRequest.check_result(&1) == :failed))

    %{
      pr_url: pr_url,
      pr_number: pull["number"],
      pr: pr_state(pull),
      base: base(base_ref, get_in(repository, ["defaultBranchRef", "name"])),
      base_ref: base_ref,
      head_sha: head_sha,
      auto_merge: if(is_map(pull["autoMergeRequest"]), do: :armed, else: :off),
      review_comments: review_comments(pull),
      mergeable: mergeable(pull["mergeable"], pull["mergeStateStatus"]),
      ci: elem(ci, 0),
      missing_checks: elem(ci, 1),
      red_kind: red_kind(elem(ci, 0), failing, base_ref, repo, opts),
      failing_check: failing |> Enum.map(& &1.name) |> List.first(),
      failed_checks: Enum.map(failing, &Map.take(&1, [:name, :run_id, :workflow_name, :conclusion])),
      check_names: checks |> Enum.map(& &1.name) |> Enum.uniq(),
      pr_node_id: pull["id"],
      pr_title: pull["title"],
      pr_description: pull["body"],
      head_ref: pull["headRefName"],
      base_sha: pull["baseRefOid"],
      rate_limit: rate_limit,
      required: required
    }
  end

  defp pr_state(%{"merged" => true}), do: :merged
  defp pr_state(%{"state" => "MERGED"}), do: :merged
  defp pr_state(%{"state" => "CLOSED"}), do: :closed
  defp pr_state(%{"isDraft" => true}), do: :draft
  defp pr_state(_pull), do: :open

  defp base(base_ref, default) when is_binary(base_ref) and is_binary(default) and base_ref != default, do: :changed
  defp base(_base_ref, _default), do: :ok

  defp review_comments(pull) do
    unresolved? =
      pull
      |> get_in(["reviewThreads", "nodes"])
      |> List.wrap()
      |> Enum.any?(&(is_map(&1) and &1["isResolved"] == false and &1["isOutdated"] != true))

    if unresolved? or pull["reviewDecision"] == "CHANGES_REQUESTED", do: :unaddressed, else: :none
  end

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

  defp ci(checks, required) do
    results = Enum.map(checks, &PullRequest.check_result/1)
    missing = required -- Enum.map(checks, & &1.name)

    cond do
      :failed in results -> {:red, []}
      :pending in results -> {:pending, []}
      missing != [] -> {:required_missing, missing}
      checks == [] -> {:none, []}
      true -> {:green, []}
    end
  end

  defp red_kind(:red, failing, base_ref, repo, opts) do
    cond do
      Enum.all?(failing, &CiPoller.human_only_check?/1) -> :human_only
      Enum.all?(failing, &(&1.conclusion == "CANCELLED")) -> :cancelled
      red_on_base?(failing, base_ref, repo, opts) -> :also_red_on_base
      true -> :failure
    end
  end

  defp red_kind(_ci, _failing, _base_ref, _repo, _opts), do: :failure

  # Each failing check's workflow also failed its latest finished run on the base branch.
  defp red_on_base?(failing, base_ref, {host, owner, name}, opts) when is_binary(base_ref) do
    workflows = failing |> Enum.map(& &1.workflow_name) |> Enum.uniq()
    repo = if host == "github.com", do: "#{owner}/#{name}", else: "#{host}/#{owner}/#{name}"

    with false <- nil in workflows,
         {:ok, runs} <- PullRequest.list_branch_runs(repo, base_ref, Keyword.put(opts, :limit, @base_runs_limit)) do
      latest = runs |> Enum.filter(&(&1.status == "COMPLETED")) |> Enum.uniq_by(& &1.workflow_name) |> Map.new(&{&1.workflow_name, &1.conclusion})
      Enum.all?(workflows, &(Map.get(latest, &1) == "FAILURE"))
    else
      _unknown -> false
    end
  end

  defp red_on_base?(_failing, _base_ref, _repo, _opts), do: false
end
