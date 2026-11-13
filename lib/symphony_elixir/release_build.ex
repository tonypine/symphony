defmodule SymphonyElixir.ReleaseBuild do
  @moduledoc """
  The release build of every merge to `main` of Symphony's own repository: the `release` workflow's
  run on that commit, which publishes the update the running app needs, whether or not a ticket
  waits on it (TP-1340). A held ticket (`SymphonyElixir.UpdateHold`) names the commit it waits on;
  with none held, the newest merge is watched all the same, since the app carries every fix merged
  since its build.

  Symphony watches the run as the PR watcher's R19 watches a PR's checks
  (`docs/pr-ci-decisions.md`):

    * a run GitHub cancelled before any job started while a newer `release` run on `main` exists was
      replaced by that run (the workflow's concurrency group cancels an older pending run when a
      newer push queues): it is `:superseded`, never rerun, never asked about;
    * a run GitHub cancelled before any job started (no machine to run it) is rerun by Symphony, at
      most twice, whether GitHub ended it as `cancelled` or as `failure` (TP-1368): whether a job
      ran a step decides it, not the conclusion, with no attempt spent; cancelled again, it asks a person on the first held
      ticket through the one decision path (`SymphonyElixir.DecisionRequest`): keep retrying, or
      wait, as R19a asks;
    * a run that failed for a real reason (a build or signing step failed, it ran out of time, or it
      was cancelled once a job had started) asks a person on the first held ticket, naming the job
      and step that failed when the run says: rerun the build, or wait for a fix. While a held ticket waits on it, it also puts an `:environment` reason on
      Symphony's pause with the failure (`waits_on: %{condition: "release_build:<repo key>:<sha>"}`).
      The reason clears once the build is rerun, a person chose to wait, or no held ticket waits on
      the commit any more.
    * a run whose failed step is in the release gate's job (`SymphonyElixir.ReleaseGate`) asks nobody
      and pauses nothing: Symphony files one Urgent fix ticket with the failure, or adds the failure
      to the fix ticket still open, once per attempt of the run. A pause would hold the very ticket
      that repairs it.
    * with no held ticket to ask, a build cancelled again or failed is logged with its commit and
      run and asked on Symphony itself (TP-1341, `SymphonyElixir.Questions` with subject
      `:symphony`, step `step_name/1`): rerun the build, or wait for a fix. The Inbox lists it with
      no ticket; the Director's Decide answers it and has the build checked again at once
      (`delivered/2`), which reruns it on "Rerun the build". The question is withdrawn once the
      build starts again on GitHub, is published, or a newer merge is the one watched.

  Three triggers run the same check (`check/5`): the poll task, after `UpdateHold.resolve/5`, for
  every commit a held ticket waits on and for the newest `release` run on `main`, at most once a
  minute (`watch/5`); and a `workflow_run` delivery, at once, for a commit already watched or a
  `release` run on `main` of the running build's repository (`delivered/2`). What each check found
  is kept in the run store under `{:release_build, sha}` (`get/2`), so reruns, questions and
  answers outlast a restart, and the newest watched merge under `{:release_build, :latest}`. A held
  ticket's line reads the build's state from it (`line/3`): "Waiting for the v0.0.1.750 build with
  TP-1238's fix: queued on GitHub for 23 min"; with none held, the state payload's `app_update`
  carries the newest merge's (`latest_build/1`): "The v0.0.1.785 build: queued on GitHub for 12 min".

  A check that finds the run finished, built or not, where the last check found it unfinished, lifts
  the CI wait of a ticket paused on the commit (`SymphonyElixir.CiWait.finished/2`), in case its `workflow_run` delivery never came.
  """

  require Logger

  alias SymphonyElixir.{
    BuildInfo,
    CiWait,
    DecisionRequest,
    MergeConfirmation,
    Pauses,
    Questions,
    ReleaseGate,
    RunStore,
    TicketState,
    UpdateHold
  }

  alias SymphonyElixir.GitHub.{PullRequest, Repo}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrDecision.Apply

  @workflow "release"
  @branch "main"
  @latest {:release_build, :latest}
  @latest_every_seconds 60
  @max_reruns 2
  # The conclusions GitHub gives a run whose job it cancelled before a machine took it.
  @starved_conclusions ["CANCELLED", "FAILURE"]
  @condition_prefix "release_build:"
  @setter %{kind: :rule, name: "Release build watch"}
  @keep_retrying "Keep retrying"
  @wait "Wait"
  @rerun_build "Rerun the build"
  @wait_for_fix "Wait for a fix"
  @lack_of_machine "cancelled for lack of a machine"
  # What a build is at before its run finished.
  @unfinished_states [:not_started, :queued, :running]

  @typedoc """
  What the build's run is at: `:not_started` (no run yet), `:queued`, `:running`, `:built`,
  `:cancelled` (cancelled for lack of a machine, its rerun not sent yet), `:superseded` (cancelled
  before it started because a newer `release` run on `main` queued behind it; never rerun), `:asked`
  (cancelled again after its reruns, a person asked), `:waiting` (a person chose to wait) or `:failed`.
  """
  @type state :: :not_started | :queued | :running | :built | :cancelled | :superseded | :asked | :waiting | :failed

  @typedoc "A held ticket a question may be asked on."
  @type ticket :: %{id: String.t(), identifier: String.t() | nil, state: String.t() | nil}

  @typedoc """
  A question asked about one attempt of the run: what kind, its title, and either on which ticket
  and how many same-titled answers the ticket held before, or, with no held ticket, the Question
  asked on Symphony itself (`subject: :symphony` and its `question_id`).
  """
  @type question ::
          %{
            kind: :cancelled | :failed,
            title: String.t(),
            attempt: pos_integer(),
            issue_id: String.t(),
            prior: non_neg_integer()
          }
          | %{
              kind: :cancelled | :failed,
              title: String.t(),
              attempt: pos_integer(),
              subject: :symphony,
              question_id: String.t()
            }

  @typedoc "Where a failed build failed: the job, and the step when GitHub names one."
  @type failure :: %{job: String.t() | nil, step: String.t() | nil}

  @type t :: %{
          sha: String.t(),
          repo: String.t() | nil,
          url: String.t() | nil,
          repo_key: String.t() | nil,
          tickets: [ticket()],
          state: state(),
          run_id: String.t() | nil,
          number: pos_integer() | nil,
          attempt: pos_integer() | nil,
          conclusion: String.t() | nil,
          failure: failure() | nil,
          since: DateTime.t() | nil,
          since_attempt: pos_integer() | nil,
          reruns: non_neg_integer(),
          rerun_attempt: pos_integer() | nil,
          question: question() | nil,
          answer: %{kind: :cancelled | :failed, attempt: pos_integer()} | nil,
          fix: %{identifier: String.t(), attempt: pos_integer()} | nil
        }

  @doc """
  Checks the build of every merge commit a ticket among `issues` waits on (the `UpdateHold` reasons
  on their pauses, their commits from `cache`), except one already published or replaced, then the newest
  `release` run on `main` (`watch_main/4`), and clears the Symphony pause reason of each commit of
  `repo_key` no ticket waits on any more. A running build with no repository watches nothing.
  `opts`: those of `check/5`.
  """
  @spec watch([Issue.t()], BuildInfo.t(), UpdateHold.cache(), String.t(), keyword()) :: :ok
  def watch(issues, %{repo: build_repo}, cache, repo_key, opts) when is_binary(build_repo) and is_binary(repo_key) do
    waits =
      for %Issue{id: issue_id} = issue when is_binary(issue_id) <- issues,
          (reasons = UpdateHold.reasons(issue.repo_key || repo_key, issue_id)) != [],
          %{merge_sha: sha} when is_binary(sha) <- UpdateHold.blockers(issue, reasons, cache),
          reduce: %{} do
        acc -> Map.update(acc, sha, [ticket(issue)], &Enum.uniq([ticket(issue) | &1]))
      end

    repo = Repo.gh_repo_from_url(build_repo)

    for {sha, tickets} <- waits, not settled?(get(sha, opts)) do
      check(sha, repo, repo_key, Enum.sort_by(tickets, & &1.identifier), opts)
    end

    :ok = watch_main(repo, repo_key, Map.keys(waits), opts)
    clear_unwatched(repo_key, Map.keys(waits), opts)
  end

  def watch(_issues, _build, _cache, _repo_key, _opts), do: :ok

  # A published build is the app update's to finish, and a replaced one is the newer run's: neither
  # run is read again.
  defp settled?(record), do: match?(%{state: state} when state in [:built, :superseded], record)

  defp ticket(%Issue{} = issue), do: %{id: issue.id, identifier: issue.identifier, state: issue.state}

  @doc """
  Checks the build of the newest `release` run started by a push to `main` of `repo`, held ticket or
  not, at most once a minute: reads that run's commit and checks it unless it is published or among
  `held` (checked already). The newest watched merge is kept for `latest_build/1`. `opts`: those of
  `check/5`.
  """
  @spec watch_main(String.t() | nil, String.t() | nil, [String.t()], keyword()) :: :ok
  def watch_main(repo, repo_key, held, opts) when is_binary(repo) do
    now = now(opts)

    with false <- recently_read?(now, opts),
         {:ok, %{head_sha: sha} = run} when is_binary(sha) <- newest_main_run(repo, opts) do
      sha = String.downcase(sha)
      :ok = put_latest(%{sha: sha, number: run.number, read_at: now}, opts)
      :ok = withdraw_older(sha, opts)
      if sha not in held and not settled?(get(sha, opts)), do: check(sha, repo, repo_key, [], opts)
      :ok
    else
      {:error, reason} ->
        Logger.debug("Could not read the newest release build on #{@branch} of #{repo}: #{inspect(reason)}")
        :ok

      _read_lately_or_none ->
        :ok
    end
  end

  def watch_main(_repo, _repo_key, _held, _opts), do: :ok

  defp newest_main_run(repo, opts), do: github(opts).branch_workflow_run(repo, @branch, @workflow, gh_opts(opts))

  defp recently_read?(now, opts) do
    case latest_pointer(opts) do
      %{read_at: %DateTime{} = read_at} -> DateTime.diff(now, read_at, :second) < @latest_every_seconds
      _never -> false
    end
  end

  def delivered(event, opts \\ [])

  @doc """
  Checks the build of a commit at once when a `workflow_run` delivery (`event`, a
  `SymphonyElixir.GitHub.Webhook` CI event, or a commit's sha) said a run on it finished: a commit
  already watched whose run isn't built or replaced yet, or the commit of a `release` run on `main` of the
  running build's repository (`opts[:build]`, default `SymphonyElixir.BuildInfo.current/0`), held
  ticket or not, which becomes the newest watched merge when it is newer. The check runs under
  `opts[:supervisor]` (default Symphony's task supervisor); `:ignored` for any other delivery.
  """
  @spec delivered(map() | String.t() | nil, keyword()) :: :started | :ignored
  def delivered(sha, opts) when is_binary(sha), do: delivered(%{head_sha: sha}, opts)

  def delivered(%{head_sha: sha} = event, opts) when is_binary(sha) do
    sha = String.downcase(sha)

    case {get(sha, opts), main_release_repo(event, opts)} do
      {%{state: state, repo: repo} = record, _repo} when state not in [:built, :superseded] and is_binary(repo) ->
        start(opts, fn -> check(sha, repo, record.repo_key, record.tickets, opts) end)

      {_record, repo} when is_binary(repo) ->
        start(opts, fn -> check_main(sha, repo, opts) end)

      _not_watched ->
        :ignored
    end
  end

  def delivered(_event, _opts), do: :ignored

  defp start(opts, fun) do
    supervisor = Keyword.get(opts, :supervisor, SymphonyElixir.TaskSupervisor)
    {:ok, _pid} = Task.Supervisor.start_child(supervisor, fun)
    :started
  end

  # The repository (`owner/name`) of a `release` run on `main` of the running build's repository.
  defp main_release_repo(%{workflow: @workflow, head_branch: @branch, repo: repo}, opts) when is_binary(repo) do
    build_repo = opts |> Keyword.get_lazy(:build, &BuildInfo.current/0) |> Map.get(:repo) |> Repo.gh_repo_from_url()
    if is_binary(build_repo) and String.downcase(build_repo) == String.downcase(repo), do: build_repo
  end

  defp main_release_repo(_event, _opts), do: nil

  defp check_main(sha, repo, opts) do
    with {:ok, record} <- check(sha, repo, nil, [], opts) do
      newer? =
        case latest_pointer(opts) do
          %{sha: ^sha} -> true
          %{number: number} when is_integer(number) and is_integer(record.number) -> record.number >= number
          %{number: number} when is_integer(number) -> false
          _none -> true
        end

      if newer?, do: :ok = put_latest(%{sha: sha, number: record.number, read_at: Map.get(latest_pointer(opts) || %{}, :read_at)}, opts)
      if newer?, do: :ok = withdraw_older(sha, opts)
      {:ok, record}
    end
  end

  @doc """
  The newest watched merge to `main` and what its build is at, for the state payload's `app_update`
  (`SymphonyElixirWeb.WatchPayload.app_update/3`): its commit, version, state, since when it waits
  in GitHub's queue, the reruns Symphony sent, the run's page and its line ("The v0.0.1.785 build:
  queued on GitHub for 12 min", nil once published). Nil until a merge was watched. `opts`:
  `:run_store`, `:now`.
  """
  @spec latest_build(keyword()) :: map() | nil
  def latest_build(opts \\ []) do
    with %{sha: sha} when is_binary(sha) <- latest_pointer(opts),
         %{} = record <- get(sha, opts) do
      %{
        sha: sha,
        version: if(is_integer(record.number), do: BuildInfo.release_version(record.number)),
        state: Atom.to_string(record.state),
        since: record.since,
        reruns: record.reruns,
        url: Map.get(record, :url),
        line: latest_line(record, now(opts))
      }
    end
  end

  defp latest_line(record, now) do
    case words(record, now) do
      words when is_binary(words) -> "The #{build_name(record)}: #{words}"
      nil -> nil
    end
  end

  defp latest_pointer(opts) do
    case store(opts).get_github_updates(@latest) do
      %{sha: sha} = pointer when is_binary(sha) -> pointer
      _none -> nil
    end
  end

  defp put_latest(pointer, opts) do
    case store(opts).put_github_updates(@latest, pointer) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Could not record the newest release build: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Reads the `release` run on commit `sha` of `repo` (`owner/name`), acts on it as the moduledoc
  says, keeps what it found and returns it. `tickets` are the tickets waiting on it, the first of
  them asked when a person must decide. `opts`: `:github` (default `SymphonyElixir.GitHub.PullRequest`),
  `:gh_runner`, `:run_store`, `:now`, `:ask` (`ticket, request -> :ok | {:error, term}`, default
  `SymphonyElixir.DecisionRequest.ask/4`), `:decisions` (`repo_key, issue_id -> [decision]`, the
  ticket's recorded decisions) and `:pauses` (default `SymphonyElixir.Pauses`).
  """
  @spec check(String.t(), String.t() | nil, String.t() | nil, [ticket()], keyword()) :: {:ok, t()} | {:error, term()}
  def check(sha, repo, repo_key, tickets, opts) when is_binary(sha) and is_binary(repo) do
    record = Map.merge(get(sha, opts) || new(sha), %{repo: repo, repo_key: repo_key, tickets: tickets})

    case github(opts).commit_workflow_runs(repo, sha, @workflow, gh_opts(opts)) do
      {:ok, runs} ->
        run = List.first(runs)
        unfinished? = record.state in @unfinished_states
        record = record |> take_answer(run, opts) |> step(run) |> settle_question()
        stored = put(record, opts)
        sync_pause(stored, opts)
        if unfinished?, do: ci_finished(sha, run)
        {:ok, stored}

      {:error, reason} ->
        Logger.debug("Could not read the release build of #{sha} in #{repo}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def check(_sha, _repo, _repo_key, _tickets, _opts), do: {:error, :no_repository}

  # A read that finds the run finished where the last one found it queued or running is CI on the
  # commit completing, as its `workflow_run` delivery would say: a ticket paused waiting for CI on it
  # is lifted (`SymphonyElixir.CiWait`), whichever of the two comes first. A run read as finished
  # before is no completion: a pause set since waits on another run's.
  defp ci_finished(sha, %{status: "COMPLETED"}), do: CiWait.finished(sha)
  defp ci_finished(_sha, _run), do: []

  @doc "What the last check of commit `sha`'s build found, or nil. `opts`: `:run_store`."
  @spec get(String.t(), keyword()) :: t() | nil
  def get(sha, opts \\ []) when is_binary(sha) do
    case store(opts).get_github_updates({:release_build, sha}) do
      %{sha: ^sha} = record -> record
      _none -> nil
    end
  end

  def line(sha, fix, opts \\ [])

  @doc """
  A held ticket's line while commit `sha`'s build isn't published: "Waiting for the v0.0.1.750
  build with TP-1238's fix: queued on GitHub for 23 min", `fix` naming what it carries (nil leaves
  that part out). Nil when no run is known yet or the build is published: the update is what is
  left. `opts`: `:run_store`, `:now`.
  """
  @spec line(String.t() | nil, String.t() | nil, keyword()) :: String.t() | nil
  def line(sha, fix, opts) when is_binary(sha) do
    with %{} = record <- get(sha, opts),
         words when is_binary(words) <- words(record, now(opts)) do
      with_fix = if fix, do: " with #{fix}", else: ""
      "Waiting for the #{build_name(record)}#{with_fix}: #{words}"
    end
  end

  def line(_sha, _fix, _opts), do: nil

  defp words(%{state: :queued} = record, now), do: "queued on GitHub for #{duration(record.since, now)}" <> rerun_note(record)
  defp words(%{state: :running} = record, _now), do: "building on GitHub" <> rerun_note(record)

  defp words(%{state: :cancelled, reruns: @max_reruns, question: nil} = record, _now),
    do: "#{@lack_of_machine} #{record.reruns + 1} times; Symphony stopped rerunning it"

  defp words(%{state: :cancelled}, _now), do: "#{@lack_of_machine}, rerunning it"
  defp words(%{state: :asked, question: %{subject: :symphony}} = record, _now), do: "#{@lack_of_machine} #{record.reruns + 1} times; you were asked whether to rerun it"
  defp words(%{state: :superseded}, _now), do: "replaced by a newer build"
  defp words(%{state: :asked} = record, _now), do: "#{@lack_of_machine} #{record.reruns + 1} times; you were asked whether to keep retrying"
  defp words(%{state: :waiting}, _now), do: "#{@lack_of_machine}; you chose to wait"
  defp words(%{state: :failed, fix: %{identifier: identifier}}, _now), do: "failed its release gate; #{identifier} was opened to fix it"
  defp words(%{state: :failed, answer: %{kind: :failed}}, _now), do: "failed on GitHub; waiting for a fix"
  defp words(%{state: :failed, question: nil}, _now), do: "failed on GitHub"
  defp words(%{state: :failed}, _now), do: "failed on GitHub; you were asked what to do"
  defp words(_record, _now), do: nil

  defp rerun_note(%{reruns: reruns}) when reruns > 0, do: "; #{@lack_of_machine}, rerun #{reruns} of #{@max_reruns}"
  defp rerun_note(_record), do: ""

  defp duration(%DateTime{} = since, now) do
    case max(DateTime.diff(now, since, :minute), 0) do
      0 -> "less than a minute"
      minutes when minutes < 60 -> "#{minutes} min"
      minutes -> "#{div(minutes, 60)} h #{rem(minutes, 60)} min"
    end
  end

  defp duration(_since, _now), do: "a while"

  defp build_name(%{number: number}) when is_integer(number), do: "v#{BuildInfo.release_version(number)} build"
  defp build_name(_record), do: "release build"

  defp new(sha) do
    %{
      sha: sha,
      repo: nil,
      url: nil,
      repo_key: nil,
      tickets: [],
      state: :not_started,
      run_id: nil,
      number: nil,
      attempt: nil,
      conclusion: nil,
      failure: nil,
      since: nil,
      since_attempt: nil,
      reruns: 0,
      rerun_attempt: nil,
      question: nil,
      answer: nil,
      fix: nil
    }
  end

  # What the run is at, and what Symphony does about it.
  defp step(record, nil), do: %{record | state: :not_started}

  defp step(record, run) do
    record = observe(record, run, now_of(record))

    cond do
      run.status != "COMPLETED" -> %{record | state: if(run.status == "IN_PROGRESS", do: :running, else: :queued)}
      run.attempt == record.rerun_attempt -> %{record | state: :queued}
      run.conclusion == "SUCCESS" -> %{record | state: :built}
      true -> unsuccessful(record, run)
    end
  end

  defp now_of(record), do: Map.get(record, :now) || DateTime.utc_now()

  # The run's number, attempt and conclusion; a new attempt starts its own time in the queue. A rerun
  # Symphony sent and GitHub hasn't started yet already started its attempt's time.
  defp observe(record, run, now) do
    record = Map.merge(record, %{run_id: run.id, url: run.url, number: run.number, attempt: run.attempt, conclusion: run.conclusion})

    cond do
      run.attempt == record.rerun_attempt -> record
      record.since_attempt == run.attempt and record.since -> record
      run.attempt == 1 -> %{record | since: run.created_at || now, since_attempt: 1}
      true -> %{record | since: now, since_attempt: run.attempt}
    end
  end

  # Whether a job started decides starvation, not the run's conclusion: GitHub ends a run whose
  # job it cancelled for lack of a machine as `cancelled` or as `failure`. A run whose jobs ran no
  # step was starved; once a job ran a step, whatever the conclusion, it is a failure, kept with the
  # job and step that failed.
  defp unsuccessful(record, run) do
    case github(record).run_steps(run.id, gh_opts(record)) do
      {:ok, jobs} ->
        if run.conclusion in @starved_conclusions and not Enum.any?(jobs, &(&1.steps != [])),
          do: starved(record, run),
          else: failed(Map.put(record, :failure, failure_of(jobs)), run)

      {:error, _reason} ->
        record
    end
  end

  defp failure_of(jobs) do
    Enum.find_value(jobs, fn job ->
      case Enum.find(job.steps, &(&1.conclusion == "FAILURE")) do
        %{name: step} -> %{job: job.name, step: step}
        nil -> nil
      end
    end) || Enum.find_value(jobs, &if(&1.conclusion == "FAILURE", do: %{job: &1.name, step: nil}))
  end

  defp starved(record, run) do
    case superseded?(record, run) do
      false -> starved_alone(record, run)
      true -> %{record | state: :superseded}
      :unknown -> record
    end
  end

  defp starved_alone(record, run) do
    cond do
      answered?(record, :cancelled, run.attempt) -> %{record | state: :waiting}
      record.reruns < @max_reruns -> rerun(record, run, &%{&1 | reruns: &1.reruns + 1})
      asked?(record, :cancelled, run.attempt) -> %{record | state: :asked}
      true -> ask(record, run, :cancelled)
    end
  end

  # A newer `release` run on `main`: with the workflow's concurrency group, GitHub cancels an older
  # run still pending when a newer push queues, before any job of it starts. That run was replaced,
  # not starved of a machine: rerunning it would cancel the newer one in turn and could publish an
  # older build after a newer one.
  defp superseded?(record, run) do
    case github(record).branch_workflow_run(record.repo, @branch, @workflow, gh_opts(record.opts)) do
      {:ok, %{number: newest}} when is_integer(newest) and is_integer(run.number) ->
        newest > run.number

      {:ok, _none_or_unnumbered} ->
        false

      {:error, reason} ->
        Logger.debug("Could not read the newest release build on #{@branch} of #{record.repo}: #{inspect(reason)}")
        :unknown
    end
  end

  defp failed(record, run) do
    cond do
      ReleaseGate.gate_failure?(record) -> gate_failed(record, run)
      asked?(record, :failed, run.attempt) or answered?(record, :failed, run.attempt) -> %{record | state: :failed}
      true -> ask(record, run, :failed)
    end
  end

  # The release gate failed: a fix ticket, never a question. Filed once per attempt of the run; a
  # filing that failed is tried again on the next check.
  defp gate_failed(record, run) do
    attempt = run.attempt

    case Map.get(record, :fix) do
      %{attempt: ^attempt} ->
        %{record | state: :failed}

      _not_filed_for_this_attempt ->
        opts = Map.get(record, :opts, [])

        case Keyword.get(opts, :release_gate, ReleaseGate).failed(Map.drop(record, [:opts, :now]), opts) do
          {filed, identifier} when filed in [:filed, :attached] -> Map.merge(record, %{state: :failed, fix: %{identifier: identifier, attempt: attempt}})
          {:error, _reason} -> %{record | state: :failed}
        end
    end
  end

  defp fix_filed?(record), do: match?(%{identifier: _identifier}, Map.get(record, :fix))

  defp asked?(record, kind, attempt), do: match?(%{question: %{kind: ^kind, attempt: ^attempt}}, record)
  defp answered?(record, kind, attempt), do: match?(%{answer: %{kind: ^kind, attempt: ^attempt}}, record)

  # Reruns every job of the run; GitHub starts its next attempt. Until that attempt shows, the run
  # reads as queued again.
  defp rerun(record, run, counted) do
    case github(record).rerun(run.id, gh_opts(record)) do
      :ok ->
        Logger.info("Reran the release build of #{record.sha}: run_id=#{run.id} attempt=#{run.attempt}")
        next = run.attempt + 1
        counted.(%{record | state: :queued, rerun_attempt: run.attempt, since: now_of(record), since_attempt: next})

      {:error, reason} ->
        Logger.warning("Could not rerun the release build of #{record.sha}: run_id=#{run.id} reason=#{inspect(reason)}")
        %{record | state: :cancelled}
    end
  end

  defp ask(%{tickets: [ticket | _rest]} = record, run, kind) do
    request = request(kind, record)
    prior = record |> decisions(ticket.id) |> Enum.count(&Apply.same_title?(&1, request.title))
    asker = Keyword.get(Map.get(record, :opts, []), :ask, &ask_through_decision_request(&1, &2, record))

    case asker.(%{id: ticket.id, state: ticket.state, repo_key: record.repo_key}, request) do
      result when result == :ok or elem(result, 0) == :ok ->
        question = %{kind: kind, title: request.title, attempt: run.attempt, issue_id: ticket.id, prior: prior}
        %{record | state: state_after_ask(kind), question: question}

      {:error, reason} ->
        Logger.warning("Could not ask about the release build of #{record.sha}: #{inspect(reason)}")
        %{record | state: if(kind == :failed, do: :failed, else: :cancelled)}
    end
  end

  # No held ticket to ask: the question is asked on Symphony itself (TP-1341), through the Question
  # service, which lists it in the Inbox with no ticket; said in the log with the commit and the run.
  defp ask(record, run, kind) do
    request = symphony_request(kind, record)
    asked_by = %{kind: :rule, name: @setter.name}

    Logger.warning("The release build of #{record.sha} #{if kind == :failed, do: "failed", else: "was #{@lack_of_machine} again"} and no held ticket waits on it: run_id=#{run.id} url=#{run.url}")

    case questions(record).ask(:symphony, request, asked_by: asked_by, step: step_name(record.sha)) do
      {:ok, %{id: id}} ->
        question = %{kind: kind, title: request.title, attempt: run.attempt, subject: :symphony, question_id: id}
        %{record | state: state_after_ask(kind), question: question}

      {:error, reason} ->
        Logger.warning("Could not ask Symphony about the release build of #{record.sha}: #{inspect(reason)}")
        %{record | state: if(kind == :failed, do: :failed, else: :cancelled)}
    end
  end

  @doc """
  The `step` a release build's Question on Symphony is asked at: `release_build:<sha>`, which tells
  the Director's Decide whose answer it is (`SymphonyElixir.DirectorMoves.decide_subject/2`).
  """
  @spec step_name(String.t()) :: String.t()
  def step_name(sha) when is_binary(sha), do: "release_build:" <> sha

  # A Question on Symphony nobody needs any more: the build started again (a person reran it on
  # GitHub) or was published. It is withdrawn, so its Inbox row goes.
  defp settle_question(%{question: %{subject: subject, question_id: id}, state: state} = record) when state in [:queued, :running, :built] do
    withdraw(record, subject, id, "The build started again on GitHub, so nobody needs to answer.")
    %{record | question: nil}
  end

  defp settle_question(record), do: record

  defp withdraw(record, subject, id, reason) do
    case questions(record).withdraw(subject, id, reason, cause: "superseded", by: %{kind: :rule, name: @setter.name}) do
      {:ok, _question} -> :ok
      {:error, {:question_not_open, _state}} -> :ok
      {:error, error} -> Logger.warning("Could not withdraw the question #{id} about the release build of #{record.sha}: #{inspect(error)}")
    end
  end

  # Once a newer merge is the one watched, the questions about older builds are moot.
  defp withdraw_older(sha, opts) do
    for %{id: id, step: "release_build:" <> asked_sha} <- questions(opts).open(:symphony), asked_sha != sha do
      withdraw(%{sha: asked_sha, opts: opts}, :symphony, id, "A newer merge's build is the one the app waits for now.")
    end

    :ok
  end

  defp state_after_ask(:cancelled), do: :asked
  defp state_after_ask(:failed), do: :failed

  defp ask_through_decision_request(ticket, request, record) do
    DecisionRequest.ask(ticket, request, Keyword.take(Map.get(record, :opts, []), [:tracker, :store]))
  end

  # The answer to the open question, read from the asked ticket's recorded decisions: the first
  # same-titled one after those it held when asked.
  defp take_answer(%{question: %{subject: subject, question_id: id} = question} = record, run, opts) do
    record = Map.merge(record, %{opts: opts, now: now(opts)})

    case questions(record).find(subject, id) do
      %{state: :answered, answer: %{option: option}} -> apply_answer(record, question, option, run)
      # Withdrawn by anyone else: nobody wants it rerun, so it is not asked again for this attempt.
      %{state: :withdrawn} -> %{record | question: nil, answer: %{kind: question.kind, attempt: question.attempt}}
      _open_or_gone -> record
    end
  end

  defp take_answer(record, run, opts) do
    record = Map.merge(record, %{opts: opts, now: now(opts)})

    with %{question: %{title: title, prior: prior, issue_id: issue_id} = question} <- record,
         false <- answered?(record, question.kind, question.attempt),
         %{answer: _text} = answer <- record |> decisions(issue_id) |> Enum.filter(&Apply.same_title?(&1, title)) |> Enum.at(prior) do
      apply_answer(record, question, pick(question.kind, answer), run)
    else
      _unanswered -> record
    end
  end

  # A recorded answer's pick, else (a reply in Linear) the option its text names.
  defp pick(:cancelled, answer), do: MergeConfirmation.picked_answer([@keep_retrying, @wait], answer)
  defp pick(:failed, answer), do: MergeConfirmation.picked_answer([@rerun_build, @wait_for_fix], answer)

  defp apply_answer(record, %{kind: :cancelled}, 1, _run), do: %{record | reruns: 0, question: nil}

  # A run already running again (a person reran it on GitHub) needs no rerun.
  defp apply_answer(record, %{kind: :failed}, 1, %{status: "COMPLETED"} = run) do
    case rerun(record, run, & &1) do
      %{state: :queued} = rerun -> %{rerun | question: nil}
      _not_rerun -> record
    end
  end

  defp apply_answer(record, %{kind: :failed}, 1, _run), do: %{record | question: nil}

  defp apply_answer(record, question, _pick, _run), do: %{record | answer: %{kind: question.kind, attempt: question.attempt}}

  defp decisions(record, issue_id) do
    case Keyword.fetch(Map.get(record, :opts, []), :decisions) do
      {:ok, read} -> read.(record.repo_key, issue_id)
      :error -> stored_decisions(issue_id)
    end
  end

  defp stored_decisions(issue_id) do
    case RunStore.get_ticket_state(issue_id) do
      %{} = ticket_record -> TicketState.decisions(ticket_record)
      _none -> []
    end
  end

  # Symphony's pause holds a failed build's reason, while a held ticket waits on it, until it is
  # rerun or a person answered. A build no ticket waits on stops no dispatch.
  defp sync_pause(%{repo_key: repo_key} = record, opts) when is_binary(repo_key) do
    condition = condition(repo_key, record.sha)

    if record.state == :failed and record.tickets != [] and not answered?(record, :failed, record.attempt) and not fix_filed?(record) do
      reason = %{kind: :environment, waits_on: %{condition: condition}, text: pause_text(record)}
      _pause = pauses(opts).set(:symphony, reason, set_by: @setter)
    else
      reason = %{kind: :environment, waits_on: %{condition: condition}}
      if held?(condition, opts), do: pauses(opts).clear_reason(:symphony, reason, by: @setter)
    end

    :ok
  end

  defp sync_pause(_record, _opts), do: :ok

  defp clear_unwatched(repo_key, shas, opts) do
    watched = MapSet.new(shas, &condition(repo_key, &1))
    prefix = condition(repo_key, "")

    for %{kind: :environment, waits_on: %{condition: @condition_prefix <> _rest = condition}} = reason <-
          symphony_reasons(opts),
        String.starts_with?(condition, prefix),
        not MapSet.member?(watched, condition) do
      pauses(opts).clear_reason(:symphony, reason, by: @setter)
    end

    :ok
  end

  defp held?(condition, opts), do: Enum.any?(symphony_reasons(opts), &match?(%{waits_on: %{condition: ^condition}}, &1))

  defp symphony_reasons(opts) do
    case pauses(opts).get(:symphony) do
      {:ok, %{reasons: reasons}} -> reasons
      _none -> []
    end
  end

  defp condition(repo_key, sha), do: "#{@condition_prefix}#{repo_key}:#{sha}"

  defp pause_text(record) do
    "The #{build_name(record)} failed on GitHub (#{failure_words(record)}); #{waiting_names(record)} #{verb(record, "waits", "wait")} for it"
  end

  # What failed, as far as the run says: never "a step failed" when no step is known to have.
  defp failure_words(%{conclusion: "TIMED_OUT"}), do: "it ran out of time"
  defp failure_words(%{conclusion: "STARTUP_FAILURE"}), do: "it failed to start"
  defp failure_words(record), do: failure_place(Map.get(record, :failure), record.conclusion)

  defp failure_place(%{job: job, step: step}, _conclusion) when is_binary(step), do: "the step “#{step}” of the job “#{job}” failed"
  defp failure_place(%{job: job}, _conclusion) when is_binary(job), do: "the job “#{job}” failed"
  defp failure_place(_failure, "CANCELLED"), do: "it was cancelled while building"
  defp failure_place(_failure, _conclusion), do: "GitHub doesn't say which step failed"

  defp waiting_names(%{tickets: tickets}) do
    case for(%{identifier: identifier} when is_binary(identifier) <- tickets, do: identifier) do
      [] -> "the held tickets"
      identifiers -> Enum.join(identifiers, ", ")
    end
  end

  defp verb(%{tickets: [_one]}, one, _many), do: one
  defp verb(_record, _one, many), do: many

  defp request(:cancelled, record) do
    build = "Symphony #{build_name(record)}"
    names = waiting_names(record)

    %{
      title: "The #{build} keeps being cancelled",
      question:
        "GitHub cancelled the #{build} #{@max_reruns + 1} times in a row without starting it. " <>
          "#{names} #{verb(record, "waits", "wait")} for that build. Should Symphony keep retrying it, or wait?",
      why:
        "GitHub cancels a build it can't find a machine for, as happens when its macOS machines are busy. " <>
          "Symphony reran the build #{@max_reruns} times, and GitHub cancelled it again each time. " <>
          "Until the build is published, the app can't update to the fix #{names} #{verb(record, "waits", "wait")} for.",
      if_unanswered: "#{names} #{verb(record, "stays", "stay")} in Todo and #{verb(record, "waits", "wait")} for the build.",
      options: [
        %{
          label: @keep_retrying,
          effect: "Symphony reruns the build up to #{@max_reruns} more times while GitHub keeps cancelling it, then asks again",
          recommended: true,
          tradeoffs: [%{kind: "good", text: "nothing to do by hand once GitHub has machines again"}]
        },
        %{
          label: @wait,
          effect: "Symphony stops rerunning the build; #{names} #{verb(record, "waits", "wait")} until a person reruns it on GitHub or a newer build is published",
          tradeoffs: [%{kind: "cost", text: "the chain waits until someone reruns the build"}]
        }
      ],
      recommendation_reason: "A shortage of GitHub machines usually passes within the hour, and a rerun costs nothing."
    }
  end

  defp request(:failed, record) do
    build = "Symphony #{build_name(record)}"
    names = waiting_names(record)

    %{
      title: "The #{build} failed",
      question: "GitHub's #{build} failed: #{failure_words(record)}. #{names} #{verb(record, "waits", "wait")} for that build. Should Symphony rerun it, or wait for a fix?",
      why:
        "The build itself failed, which is not a shortage of machines. " <>
          "Symphony paused on the failure so the chain doesn't wait without saying why. " <>
          "The run's page on GitHub has the failed step's log.",
      if_unanswered: "#{names} #{verb(record, "stays", "stay")} in Todo, and Symphony stays paused on the failed build.",
      options: [
        %{
          label: @rerun_build,
          effect: "Symphony reruns the build once; if it fails again, Symphony asks again",
          recommended: true,
          tradeoffs: [%{kind: "good", text: "clears a failure GitHub or Apple caused for a moment"}]
        },
        %{
          label: @wait_for_fix,
          effect: "Symphony stops waiting on this build; #{names} #{verb(record, "waits", "wait")} until a newer build with a fix is published",
          tradeoffs: [%{kind: "cost", text: "the chain waits until someone fixes the build"}]
        }
      ],
      recommendation_reason: "A rerun costs nothing and clears a passing failure; a second failure asks again."
    }
  end

  # The question asked on Symphony itself when no held ticket waits on the build (TP-1341): the
  # same two ways forward for a build cancelled a third time and a failed one.
  defp symphony_request(kind, record) do
    build = "Symphony #{build_name(record)}"

    {title, what, why} =
      case kind do
        :cancelled ->
          {"The #{build} keeps being cancelled", "GitHub cancelled the #{build} #{@max_reruns + 1} times in a row without starting it.",
           "GitHub cancels a build it can't find a machine for, as happens when its macOS machines are busy. " <>
             "Symphony reran the build #{@max_reruns} times, and GitHub cancelled it again each time."}

        :failed ->
          {"The #{build} failed", "GitHub's #{build} failed: #{failure_words(record)}.",
           "The build itself failed, which is not a shortage of machines. The run's page on GitHub has the failed step's log."}
      end

    %{
      title: title,
      question: "#{what} No ticket waits on it, but the app can't update to the fixes merged since its last build until it is published. Should Symphony rerun it, or wait for a fix?",
      why: why <> " Until a build of the newest merge is published, the app keeps running an older version of Symphony.",
      if_unanswered: "The app stays on its current version, and Symphony doesn't rerun the build.",
      options: [
        %{
          label: @rerun_build,
          effect: rerun_effect(kind),
          recommended: true,
          tradeoffs: [%{kind: "good", text: "clears a failure or a shortage of machines that has passed"}]
        },
        %{
          label: @wait_for_fix,
          effect: "Symphony stops rerunning this build; the app updates once a newer build is published",
          tradeoffs: [%{kind: "cost", text: "the app stays on its current version until the next merge's build is published"}]
        }
      ],
      recommendation_reason: "A rerun costs nothing, and a second failure asks again."
    }
  end

  defp rerun_effect(:cancelled), do: "Symphony reruns the build now, and once more if GitHub cancels it again; then it asks again"
  defp rerun_effect(:failed), do: "Symphony reruns the build once; if it fails again, Symphony asks again"

  defp put(record, opts) do
    stored = Map.drop(record, [:opts, :now])

    case store(opts).put_github_updates({:release_build, record.sha}, stored) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Could not record the release build of #{record.sha}: #{inspect(reason)}")
    end

    stored
  end

  defp gh_opts(%{opts: opts, repo: repo}), do: [repo: repo] ++ gh_opts(opts)
  defp gh_opts(opts) when is_list(opts), do: Keyword.take(opts, [:gh_runner])

  defp github(%{opts: opts}), do: github(opts)
  defp github(opts) when is_list(opts), do: Keyword.get(opts, :github, PullRequest)

  defp pauses(opts), do: Keyword.get(opts, :pauses, Pauses)
  defp questions(%{opts: opts}), do: questions(opts)
  defp questions(opts) when is_list(opts), do: Keyword.get(opts, :questions, Questions)
  defp store(opts), do: Keyword.get(opts, :run_store, RunStore)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
