defmodule SymphonyElixir.EpicReview.CiRerun do
  @moduledoc """
  The epic review's one rerun of a red CI on the commit it reviews.

  A failed workflow run on the base branch head is not a gap yet: a flaky test or a race in a step
  fails a run that passes on its next attempt, and filing it as a follow-up costs a whole cycle (an
  implementation run, a review, CI and another epic review). The PR watcher reruns a red PR head
  once before CI Fix (R22); this is the same rule for the default branch. The first review that
  finds the commit's runs finished with a failed one:

    1. reads each failed run's failed jobs (`SymphonyElixir.GitHub.CiLog`) for their job and test
       names, which the rerun's attempt replaces;
    2. records a `ci_rerun` signal bound to the commit, before it reruns anything, so no review
       reruns that commit again; a review that cannot record it does not rerun at all;
    3. reruns each failed run's failed jobs (`gh run rerun <id> --failed`), records a fresh
       `ci_wait_started` (`SymphonyElixir.CiWait`) so the rerun gets a wait of its own, and returns
       `{:wait, runs}`: the review waits for the rerun as for any unfinished run.

  A review that finds the rerun recorded proceeds, whatever the runs say. A run green on its rerun
  is recorded on the epic as a `ci_flake` signal (the commit, the runs, their job and test names),
  once per commit, so repeated flakes on the default branch show in the ticket's ledger; the agent
  then judges a green commit. A run still red is judged by the agent like any red run, and the
  follow-up it files quotes the second failure's log. Either way the review's pre-checks carry a
  `ci_rerun` check naming what the rerun found.
  """

  require Logger

  alias SymphonyElixir.{CiWait, Handoff, RunStore, TicketSignals}
  alias SymphonyElixir.GitHub.{CiLog, PullRequest}

  @rerun_signal "ci_rerun"
  @flake_signal "ci_flake"
  @passing_conclusions ["SUCCESS", "NEUTRAL", "SKIPPED"]
  @test_names_limit 10
  # A failed test's name, as the runners this repo's CI uses print it.
  @test_patterns [
    # ExUnit: `  1) test what it does (MyApp.ModuleTest)`
    ~r/^\s*\d+\) (test .+ \([\w.]+\))\s*$/m,
    # Go: `--- FAIL: TestName (0.30s)`
    ~r/^\s*--- FAIL: (\S+)/m,
    # XCTest: `Test Case '-[Module.ClassTests testName]' failed`
    ~r/Test Case '-\[(.+?)\]' failed/,
    # Swift Testing: `✘ Test name() failed` or `✘ Test name() recorded an issue`
    ~r/✘ Test (.+?) (?:failed|recorded an issue)/u
  ]

  @typedoc "What the review does next: wait for the rerun, or proceed with the check naming what it found."
  @type result :: {:wait, [PullRequest.workflow_run()]} | {:proceed, map() | nil}

  @doc "The signal recorded on the epic when the review reruns a commit's failed CI."
  @spec rerun_signal() :: String.t()
  def rerun_signal, do: @rerun_signal

  @doc "The signal recorded on the epic when a run failed on a commit and passed on its rerun."
  @spec flake_signal() :: String.t()
  def flake_signal, do: @flake_signal

  @doc """
  Decides what the review does with the finished `runs` of commit `sha` on the epic `issue_id`.

  `{:wait, runs}` when it just reran the failed ones; `{:proceed, nil}` when nothing failed and no
  rerun was made; `{:proceed, check}` with the pre-check (`%{name: :ci_rerun, …}`) that names what an
  earlier rerun on `sha` found, or why none could start. Options: `:workspace` (where `gh` runs) and
  `:gh_runner`.
  """
  @spec check(String.t() | nil, String.t() | nil, String.t(), [PullRequest.workflow_run()], keyword()) :: result()
  def check(repo_key, issue_id, sha, runs, opts) when is_binary(sha) and is_list(runs) do
    signals = Handoff.signals(repo_key, issue_id)

    case signal_for(signals, @rerun_signal, sha) do
      nil -> first_red(repo_key, issue_id, sha, Enum.filter(runs, &failed?/1), opts)
      rerun -> {:proceed, after_rerun(repo_key, issue_id, sha, runs, rerun, signals)}
    end
  end

  @doc "The names of the failed tests in a job's log, at most #{@test_names_limit}, in order."
  @spec test_names(String.t()) :: [String.t()]
  def test_names(log) when is_binary(log) do
    @test_patterns
    |> Enum.flat_map(fn pattern -> for [_line, name] <- Regex.scan(pattern, log), do: String.trim(name) end)
    |> Enum.uniq()
    |> Enum.take(@test_names_limit)
  end

  defp first_red(_repo_key, _issue_id, _sha, [], _opts), do: {:proceed, nil}

  defp first_red(repo_key, issue_id, sha, failed, opts) do
    reran = Enum.map(failed, &rerun_entry(&1, opts))

    case RunStore.record_ticket_signal(repo_key, issue_id, @rerun_signal, %{sha: sha, runs: reran}) do
      :ok ->
        rerun(repo_key, issue_id, sha, failed, opts)

      {:error, reason} ->
        Logger.warning("Epic review did not rerun the failed CI on #{short_sha(sha)}: it could not record the rerun: #{inspect(reason)}")
        {:proceed, nil}
    end
  end

  defp rerun(repo_key, issue_id, sha, failed, opts) do
    case Enum.filter(failed, &rerun_started?(&1, sha, opts)) do
      [] ->
        {:proceed, rerun_check("Symphony could not rerun #{runs_text(failed)} on #{short_sha(sha)}; the review judges the red commit")}

      started ->
        TicketSignals.record(repo_key, issue_id, CiWait.start_signal(), %{sha: sha})
        Logger.info("Epic review reran the failed CI on #{short_sha(sha)}: #{runs_text(started)}; waiting for it before filing anything")
        {:wait, started}
    end
  end

  defp rerun_started?(run, sha, opts) do
    case PullRequest.rerun_failed(run.id, gh_opts(run, opts)) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("Epic review could not rerun run #{run.id} on #{short_sha(sha)}: #{inspect(reason)}")
        false
    end
  end

  # What the rerun's attempt will replace: the failed jobs' names and the tests that failed in them.
  defp rerun_entry(run, opts) do
    {jobs, tests} = failed_names(run, opts)
    %{id: run.id, workflow: run.workflow_name, url: run.url, jobs: jobs, tests: tests}
  end

  defp failed_names(run, opts) do
    case CiLog.read(CiLog.repo_from_url(run.url) || "", {:run, run.id}, [failed_only: true] ++ gh_opts(nil, opts)) do
      {:ok, %{jobs: jobs}} ->
        names = for %{name: name} <- jobs, is_binary(name), do: name
        {names, jobs |> Enum.map_join("\n", & &1.log) |> test_names()}

      {:error, reason} ->
        Logger.warning("Epic review could not read the failed jobs of run #{run.id} before rerunning it: #{inspect(reason)}")
        {[], []}
    end
  end

  # The rerun already happened on this commit: never again. The runs green now were a flake.
  defp after_rerun(repo_key, issue_id, sha, runs, rerun, signals) do
    by_id = Map.new(runs, &{&1.id, &1})
    {green, red} = rerun.details |> value(:runs) |> List.wrap() |> Enum.split_with(&passing?(Map.get(by_id, value(&1, :id))))

    if green != [] and is_nil(signal_for(signals, @flake_signal, sha)), do: record_flake(repo_key, issue_id, sha, green)

    texts = Enum.map(green, &flake_text/1) ++ Enum.map(red, &(entry_text(&1) <> " is not green after Symphony's rerun"))
    rerun_check(Enum.join(texts, "; "))
  end

  defp record_flake(repo_key, issue_id, sha, green) do
    jobs = green |> Enum.flat_map(&List.wrap(value(&1, :jobs))) |> Enum.uniq()
    tests = green |> Enum.flat_map(&List.wrap(value(&1, :tests))) |> Enum.uniq()

    Logger.info("Epic review found a flake on #{short_sha(sha)}: #{Enum.map_join(green, ", ", &entry_text/1)} passed on rerun; jobs=#{inspect(jobs)} tests=#{inspect(tests)}")

    TicketSignals.record(repo_key, issue_id, @flake_signal, %{
      sha: sha,
      runs: Enum.map(green, &(value(&1, :url) || value(&1, :id))),
      workflows: green |> Enum.map(&value(&1, :workflow)) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      jobs: jobs,
      tests: tests
    })
  end

  defp flake_text(entry) do
    names = List.wrap(value(entry, :jobs)) ++ List.wrap(value(entry, :tests))
    entry_text(entry) <> " failed and passed on Symphony's rerun, a flake" <> if(names == [], do: "", else: " in #{Enum.join(names, ", ")}")
  end

  defp rerun_check(detail), do: %{name: :ci_rerun, status: :attention, detail: detail}

  defp entry_text(entry), do: "#{value(entry, :workflow) || "run #{value(entry, :id)}"} (#{value(entry, :url) || value(entry, :id)})"

  defp runs_text(runs), do: Enum.map_join(runs, ", ", &"#{&1.workflow_name || "run #{&1.id}"} (#{&1.url || &1.id})")

  defp failed?(run), do: is_binary(run.id) and CiLog.failed?(run.conclusion)

  defp passing?(%{status: "COMPLETED", conclusion: conclusion}), do: conclusion in @passing_conclusions
  defp passing?(_run), do: false

  defp signal_for(signals, name, sha), do: Enum.find(signals, &(&1.name == name and value(&1.details, :sha) == sha))

  defp gh_opts(run, opts) do
    repo = if run, do: [repo: CiLog.repo_from_url(run.url)], else: []
    repo ++ [cwd: Keyword.get(opts, :workspace)] ++ Keyword.take(opts, [:gh_runner])
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp short_sha(sha), do: String.slice(sha, 0, 12)
end
