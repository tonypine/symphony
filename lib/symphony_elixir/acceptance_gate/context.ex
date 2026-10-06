defmodule SymphonyElixir.AcceptanceGate.Context do
  @moduledoc """
  Prepares everything the acceptance gate agent reads, so the agent doesn't spend turns
  collecting it. `build/5`:

    * fetches the base branch from `origin` once, checks it out in a throwaway worktree under
      `<workspace.root>/.acceptance-gate/<repo>/`, and merges the PR head into it without
      committing. A conflict returns `{:conflict, files}`: the conflict path owns that case and the
      gate doesn't run. The merge result is kept as a dangling commit (`merged_sha`), and the
      diff is the merge result against the base tip, not against the merge-base. The diff is cut
      at 120 KB, like the reviewer's; the numstat is always whole. The worktree is removed after
      the build, also on error;
    * ranks the busy files: the `escalate.busy_files.top` paths with the most commits on the base
      branch over the last `escalate.busy_files.window_days` days;
    * lists the other open PRs that change the same files. The PRs Symphony tracks come from its
      CI check and PR review records, for issues in Auto Review, In Review and Merging; their
      changed files and hunks are read from the local object database (worktree workspaces share
      it), and a head is fetched only when it is missing. The PRs it doesn't track (a human's)
      come from one GitHub GraphQL query, cached by the base tip and the PR head in
      `SymphonyElixir.AcceptanceGate.OpenPrCache`, which gives only their changed paths;
    * names the functions both PRs change, from the `-U0` hunk headers. A temporary attributes
      file maps `*.ex` and `*.exs` to git's built-in `elixir` diff driver; other files use git's
      default heuristic. An untracked PR's `functions` are always empty;
    * summarises the whole diff for the escalation rules (`diff_summary`): each changed file's
      numstat and added lines, read before the diff is cut, and the content of a changed
      `mix.lock` or `package.json` on the base tip and in the merge result.
  """

  require Logger

  alias SymphonyElixir.AcceptanceGate.{Escalation, OpenPrCache}
  alias SymphonyElixir.{AutoReview, HumanReview, RunStore, Tracker, Workspace}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo.Fetcher

  @worktree_dir ".acceptance-gate"
  @max_diff_bytes 120_000
  @merging_state "Merging"
  @closed_pr_states ["CLOSED", "MERGED"]
  @attributes "*.ex diff=elixir\n*.exs diff=elixir\n"
  @merge_identity ["-c", "user.name=Symphony", "-c", "user.email=symphony@localhost", "-c", "commit.gpgSign=false"]
  @definition ~r/^\s*(defp?|defmacrop?|defguardp?|defdelegate|defmodule|defimpl|defprotocol)\s+([^\s(,]+)/

  @type git_fun :: ([String.t()], Path.t() -> {String.t(), non_neg_integer()})
  @type file_stat :: %{path: String.t(), additions: non_neg_integer(), deletions: non_neg_integer()}
  @type function_ref :: %{path: String.t(), name: String.t()}
  @type overlap :: %{
          pr_url: String.t(),
          issue_identifier: String.t() | nil,
          files: [String.t()],
          functions: [function_ref()]
        }
  @type t :: %{
          base_branch: String.t(),
          base_sha: String.t(),
          merged_sha: String.t(),
          diff: String.t(),
          diff_truncated?: boolean(),
          numstat: [file_stat()],
          diff_summary: Escalation.diff_summary(),
          busy_files: [String.t()],
          overlaps: [overlap()]
        }

  @doc """
  Builds the gate context for `issue`'s PR at head `sha`. `record` is the issue's CI check
  record (`workspace_path`, `repo_key`, `pr_url`).

  Options: `:git` (`(args, cwd) -> {output, status}`), `:run_store`, `:tracker`, `:github` (a
  module with `list_open_pull_requests/2`) and `:cache` (the `OpenPrCache` table).
  """
  @spec build(Issue.t(), map(), String.t(), Schema.t(), keyword()) ::
          {:ok, t()} | {:conflict, [String.t()]} | {:error, term()}
  def build(%Issue{} = issue, record, sha, %Schema{} = settings, opts \\ []) when is_map(record) and is_binary(sha) do
    git = Keyword.get(opts, :git, &default_git/2)
    base = AutoReview.base_branch(Map.get(record, :repo_key))

    with {:ok, workspace} <- workspace(record),
         {:ok, base_sha} <- fetch_base(workspace, base, git),
         :ok <- ensure_commit(workspace, sha, git) do
      worktree = worktree_path(settings, Map.get(record, :repo_key), issue.identifier, sha)
      attributes = worktree <> ".attributes"
      remove_worktree(workspace, worktree, git)
      File.mkdir_p!(Path.dirname(worktree))

      try do
        File.write!(attributes, @attributes)

        job = %{
          issue: issue,
          record: record,
          sha: sha,
          workspace: workspace,
          base_sha: base_sha,
          attributes: attributes
        }

        with {:ok, merge} <- merge_onto_base(job, worktree, git),
             {:ok, busy_files} <- busy_files(job, settings, git),
             {:ok, overlaps} <- overlaps(job, merge, settings, opts, git) do
          {:ok, Map.merge(merge, %{base_branch: base, base_sha: base_sha, busy_files: busy_files, overlaps: overlaps})}
        end
      after
        File.rm(attributes)
        remove_worktree(workspace, worktree, git)
      end
    end
  end

  @doc "The throwaway worktree a gate build for `identifier` at `sha` uses."
  @spec worktree_path(Schema.t(), String.t() | nil, String.t() | nil, String.t()) :: Path.t()
  def worktree_path(%Schema{} = settings, repo_key, identifier, sha) do
    Path.join([
      Path.expand(settings.workspace.root),
      @worktree_dir,
      Workspace.safe_identifier(repo_key || "default"),
      "#{Workspace.safe_identifier(identifier || "issue")}-#{String.slice(sha, 0, 12)}"
    ])
  end

  defp workspace(record) do
    case Map.get(record, :workspace_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _missing -> {:error, :missing_workspace_path}
    end
  end

  defp fetch_base(workspace, base, git) do
    with {:ok, _output} <- run(&fetch(git, &1, &2), ["fetch", "--quiet", "origin", "+refs/heads/#{base}:refs/remotes/origin/#{base}"], workspace),
         {:ok, base_sha} <- run(git, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{base}^{commit}"], workspace) do
      {:ok, String.trim(base_sha)}
    end
  end

  defp ensure_commit(workspace, sha, git) do
    with {_output, status} when status != 0 <- git.(["cat-file", "-e", sha <> "^{commit}"], workspace),
         {output, status} when status != 0 <- fetch(git, ["fetch", "--quiet", "origin", sha], workspace) do
      {:error, {:commit_unavailable, sha, status, String.trim(output)}}
    else
      {_output, 0} -> :ok
    end
  end

  defp merge_onto_base(job, worktree, git) do
    with {:ok, _output} <- run(git, ["worktree", "add", "--detach", worktree, job.base_sha], job.workspace) do
      case git.(@merge_identity ++ ["merge", "--no-commit", "--no-ff", "--quiet", job.sha], worktree) do
        {_output, 0} -> merge_result(job, worktree, git)
        {output, status} -> conflict(worktree, git, {:git_failed, "merge", status, String.trim(output)})
      end
    end
  end

  # A merge that stops without conflicted paths failed for another reason.
  defp conflict(worktree, git, error) do
    with {output, 0} <- git.(["diff", "--name-only", "--diff-filter=U"], worktree),
         [_file | _files] = files <- lines(output) do
      {:conflict, files}
    else
      _none -> {:error, error}
    end
  end

  defp merge_result(job, worktree, git) do
    %{base_sha: base_sha, sha: sha} = job

    with {:ok, tree} <- run(git, ["write-tree"], worktree),
         {:ok, merged} <-
           run(git, @merge_identity ++ ["commit-tree", String.trim(tree), "-p", base_sha, "-p", sha, "-m", "Acceptance gate merge of #{sha}"], worktree),
         merged_sha = String.trim(merged),
         {:ok, diff} <- run(git, ["diff", "--no-color", "--no-renames", base_sha, merged_sha], worktree),
         {:ok, numstat} <- run(git, ["diff", "--numstat", "--no-renames", base_sha, merged_sha], worktree) do
      numstat = parse_numstat(numstat)
      files = diff_summary_files(numstat, added_lines(diff), {base_sha, merged_sha}, worktree, git)
      {diff, truncated?} = cap_diff(diff)
      summary = %{files: files}
      {:ok, %{merged_sha: merged_sha, diff: diff, diff_truncated?: truncated?, numstat: numstat, diff_summary: summary}}
    end
  end

  defp diff_summary_files(numstat, added_lines, {base_sha, merged_sha}, worktree, git) do
    Enum.map(numstat, fn stat ->
      file = Map.put(stat, :added_lines, Map.get(added_lines, stat.path, []))

      if Escalation.manifest?(stat.path),
        do: Map.merge(file, %{base: show(git, base_sha, stat.path, worktree), head: show(git, merged_sha, stat.path, worktree)}),
        else: file
    end)
  end

  # A file the commit doesn't have (added or removed by the PR) is nil.
  defp show(git, revision, path, worktree) do
    case git.(["show", "#{revision}:#{path}"], worktree) do
      {content, 0} -> content
      {_output, _status} -> nil
    end
  end

  # Added lines per path, without the leading `+`. A path comes from the `+++` line between
  # `diff --git` and the file's first hunk; a removed file (`+++ /dev/null`) adds none.
  defp added_lines(diff) do
    {_state, added} = diff |> String.split("\n") |> Enum.reduce({:between, %{}}, &added_line/2)
    Map.new(added, fn {path, lines} -> {path, Enum.reverse(lines)} end)
  end

  defp added_line("diff --git " <> _rest, {_state, acc}), do: {{:header, nil}, acc}
  defp added_line("+++ b/" <> path, {{:header, _old}, acc}), do: {{:header, path}, acc}
  defp added_line("@@" <> _rest, {{:header, path}, acc}) when is_binary(path), do: {{:hunks, path}, acc}
  defp added_line("+" <> line, {{:hunks, path}, acc}), do: {{:hunks, path}, Map.update(acc, path, [line], &[line | &1])}
  defp added_line(_line, state), do: state

  defp cap_diff(diff) when byte_size(diff) <= @max_diff_bytes, do: {diff, false}

  # Cut at the last whole line, so neither a line nor a UTF-8 character is split.
  defp cap_diff(diff) do
    cut = diff |> binary_part(0, @max_diff_bytes) |> String.split("\n") |> Enum.drop(-1) |> Enum.join("\n")
    {cut <> "\n", true}
  end

  defp parse_numstat(output) do
    for line <- lines(output), [additions, deletions, path] <- [String.split(line, "\t", parts: 3)] do
      %{path: path, additions: count(additions), deletions: count(deletions)}
    end
  end

  # A binary file's numstat is `-`.
  defp count("-"), do: 0
  defp count(value), do: String.to_integer(value)

  defp busy_files(job, %Schema{} = settings, git) do
    %{top: top, window_days: days} = settings.auto_review.acceptance_gate.escalate.busy_files

    with {:ok, output} <- run(git, ["log", "--since=#{days}.days.ago", "--no-renames", "--name-only", "--format=", job.base_sha], job.workspace) do
      {:ok,
       output
       |> lines()
       |> Enum.frequencies()
       |> Enum.sort_by(fn {path, commits} -> {-commits, path} end)
       |> Enum.take(top)
       |> Enum.map(&elem(&1, 0))}
    end
  end

  defp overlaps(job, merge, settings, opts, git) do
    own_paths = MapSet.new(merge.numstat, & &1.path)

    with {:ok, own_diff} <- run(git, hunk_args(job, [job.base_sha, merge.merged_sha]), job.workspace),
         {:ok, tracked} <- tracked_prs(job, settings, opts),
         {:ok, untracked} <- untracked_prs(job, tracked, opts) do
      own = %{paths: own_paths, functions: hunk_functions(own_diff)}

      untracked_overlaps =
        for pr <- untracked, files = shared(own_paths, pr.files), files != [] do
          %{pr_url: pr.url, issue_identifier: nil, files: files, functions: []}
        end

      {:ok, Enum.flat_map(tracked, &tracked_overlap(job, own, &1, git)) ++ untracked_overlaps}
    end
  end

  defp tracked_prs(%{issue: issue, record: record, sha: sha}, settings, opts) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = Map.get(record, :repo_key)

    with {:ok, checks} <- listed(run_store.list_ci_checks(repo_key)),
         {:ok, reviews} <- listed(run_store.list_pr_reviews(repo_key)) do
      (checks ++ reviews)
      |> Enum.filter(&is_map/1)
      |> Enum.group_by(&Map.get(&1, :issue_id))
      |> Enum.reject(fn {issue_id, _records} -> not is_binary(issue_id) or issue_id == issue.id end)
      |> Enum.map(fn {issue_id, records} -> tracked_pr(issue_id, records) end)
      |> Enum.filter(&(is_binary(&1.pr_url) and is_binary(&1.head_sha) and not &1.closed? and &1.head_sha != sha))
      |> in_review(settings, Keyword.get(opts, :tracker, Tracker))
    end
  end

  defp listed(records) when is_list(records), do: {:ok, records}
  defp listed({:error, reason}), do: {:error, {:run_store_failed, reason}}

  # CI check records come first, so their head (refreshed on every poll) wins.
  defp tracked_pr(issue_id, records) do
    %{
      issue_id: issue_id,
      issue_identifier: first_present(records, &Map.get(&1, :issue_identifier)),
      pr_url: first_present(records, &Map.get(&1, :pr_url)),
      head_sha: first_present(records, &record_head/1),
      closed?: Enum.any?(records, &(upcase(Map.get(&1, :pr_state)) in @closed_pr_states))
    }
  end

  defp record_head(record) do
    auto_merge_head =
      case Map.get(record, :auto_merge) do
        %{head_sha: head_sha} -> head_sha
        _none -> nil
      end

    Enum.find([Map.get(record, :last_observed_sha), Map.get(record, :commit_sha), Map.get(record, :head_ref_oid), auto_merge_head], &present?/1)
  end

  defp in_review([], _settings, _tracker), do: {:ok, []}

  defp in_review(prs, settings, tracker) do
    states = [AutoReview.state(settings), @merging_state | HumanReview.review_states(settings)]

    case tracker.fetch_issue_states_by_ids(Enum.map(prs, & &1.issue_id)) do
      {:ok, issues} ->
        ids = for %Issue{id: id, state: state} <- issues, state in states, into: MapSet.new(), do: id
        {:ok, Enum.filter(prs, &MapSet.member?(ids, &1.issue_id))}

      {:error, reason} ->
        {:error, {:issue_states_failed, reason}}
    end
  end

  defp tracked_overlap(job, own, pr, git) do
    with :ok <- ensure_commit(job.workspace, pr.head_sha, git),
         range = "#{job.base_sha}...#{pr.head_sha}",
         {:ok, names} <- run(git, ["diff", "--no-renames", "--name-only", range], job.workspace),
         {:ok, diff} <- run(git, hunk_args(job, [range]), job.workspace) do
      overlap(own, pr, lines(names), hunk_functions(diff))
    else
      {:error, reason} ->
        Logger.warning("Acceptance gate context skipped open PR #{pr.pr_url} issue_identifier=#{pr.issue_identifier}: #{inspect(reason)}")
        []
    end
  end

  defp overlap(own, pr, paths, other_functions) do
    case shared(own.paths, paths) do
      [] ->
        []

      files ->
        functions =
          for path <- files,
              name <- shared(Map.get(own.functions, path, []), Map.get(other_functions, path, [])),
              do: %{path: path, name: name}

        [%{pr_url: pr.pr_url, issue_identifier: pr.issue_identifier, files: files, functions: functions}]
    end
  end

  defp untracked_prs(job, tracked, opts) do
    case Map.get(job.record, :pr_url) do
      pr_url when is_binary(pr_url) -> open_pull_requests(job, pr_url, tracked, opts)
      _missing -> {:error, :missing_pr_url}
    end
  end

  # Every open PR but this one and the ones Symphony tracks.
  defp open_pull_requests(job, pr_url, tracked, opts) do
    github = Keyword.get(opts, :github, PullRequest)
    known = MapSet.new([pr_url | Enum.map(tracked, & &1.pr_url)], &normalize_url/1)
    list = fn -> github.list_open_pull_requests(pr_url, cwd: job.workspace) end

    case OpenPrCache.fetch(Keyword.get(opts, :cache, OpenPrCache), {pr_url, job.base_sha, job.sha}, list) do
      {:ok, prs} -> {:ok, Enum.reject(prs, &(not is_binary(&1.url) or MapSet.member?(known, normalize_url(&1.url))))}
      {:error, reason} -> {:error, {:open_pull_requests_failed, reason}}
    end
  end

  defp hunk_args(job, revisions) do
    ["-c", "core.attributesFile=#{job.attributes}", "-c", "core.quotePath=false", "diff", "--no-color", "--no-renames", "-U0" | revisions]
  end

  # Function names per path, from the hunk headers of a `-U0` diff. A file's path comes from
  # its `---`/`+++` lines, read only between `diff --git` and its first hunk.
  defp hunk_functions(diff) do
    {_state, functions} =
      diff
      |> String.split("\n")
      |> Enum.reduce({:between, %{}}, &hunk_line/2)

    functions
  end

  defp hunk_line("diff --git " <> _rest, {_state, acc}), do: {{:header, nil}, acc}
  defp hunk_line("--- a/" <> path, {{:header, _old}, acc}), do: {{:header, path}, acc}
  defp hunk_line("+++ b/" <> path, {{:header, _old}, acc}), do: {{:header, path}, acc}
  defp hunk_line("@@" <> _rest = line, {{:header, path}, acc}) when is_binary(path), do: hunk_line(line, {{:hunks, path}, acc})

  defp hunk_line("@@" <> _rest = line, {{:hunks, path}, acc} = state) do
    case function_name(line) do
      nil -> state
      name -> {{:hunks, path}, Map.update(acc, path, MapSet.new([name]), &MapSet.put(&1, name))}
    end
  end

  defp hunk_line(_line, state), do: state

  defp function_name(header) do
    context = header |> String.split(~r/^@@[^@]*@@/, parts: 2) |> List.last() |> String.trim()

    case Regex.run(@definition, context) do
      [_match, kind, name] -> "#{kind} #{name}"
      nil -> context |> String.split("(", parts: 2) |> hd() |> String.trim() |> blank_to_nil()
    end
  end

  defp shared(left, right), do: left |> MapSet.new() |> MapSet.intersection(MapSet.new(right)) |> Enum.sort()

  # Under the per-repo fetch lock: the remove writes the `.git/worktrees` the
  # workspace shares with the source checkout and every other worktree of it.
  defp remove_worktree(workspace, worktree, git) do
    Fetcher.with_lock(workspace, fn -> git.(["worktree", "remove", "--force", worktree], workspace) end)
    File.rm_rf(worktree)
    :ok
  end

  defp run(git, args, cwd) do
    case git.(args, cwd) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, git_command(args), status, String.trim(output)}}
    end
  end

  # Under the per-repo fetch lock: the workspace shares its `.git` with the
  # source checkout and every other worktree of it.
  defp fetch(git, args, cwd), do: Fetcher.fetch(cwd, fn -> git.(args, cwd) end)

  defp git_command(args), do: Enum.find(args, &(not String.starts_with?(&1, "-") and not String.contains?(&1, "=")))

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  defp lines(output), do: output |> String.split("\n", trim: true) |> Enum.map(&String.trim_trailing(&1, "\r"))

  defp first_present(records, fun), do: records |> Enum.map(fun) |> Enum.find(&present?/1)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp upcase(value) when is_binary(value), do: String.upcase(value)
  defp upcase(_value), do: nil

  defp normalize_url(url), do: url |> String.trim() |> String.trim_trailing("/") |> String.downcase()
end
