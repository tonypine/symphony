defmodule SymphonyElixir.ReleaseBuild do
  @moduledoc """
  The release build of each merge commit the app update hold (`SymphonyElixir.UpdateHold`) waits
  on: the `release` workflow's run on that commit of Symphony's own repository, which publishes the
  update the held tickets need.

  The hold's owner watches the run as the PR watcher's R19 watches a PR's checks
  (`docs/pr-ci-decisions.md`):

    * a run GitHub cancelled before any job started (no machine to run it) is rerun by Symphony, at
      most twice, with no attempt spent; cancelled again, it asks a person on the first held
      ticket through the one decision path (`SymphonyElixir.DecisionRequest`): keep retrying, or
      wait, as R19a asks;
    * a run that failed for a real reason (a build or signing step failed, it ran out of time, or it
      was cancelled once a job had started) puts an `:environment` reason on Symphony's pause with
      the failure (`waits_on: %{condition: "release_build:<repo key>:<sha>"}`) and asks a person:
      rerun the build, or wait for a fix. The reason clears once the build is rerun, a person chose
      to wait, or no held ticket waits on the commit any more.

  Two triggers run the same check (`check/5`): the poll task, after `UpdateHold.resolve/5`, for
  every commit a held ticket waits on (`watch/5`), and a `workflow_run` delivery for a commit
  already watched (`delivered/2`), at once. What each check found is kept in the run store under
  `{:release_build, sha}` (`get/2`), so reruns, questions and answers outlast a restart, and a
  held ticket's line reads the build's state from it (`line/3`): "Waiting for the v0.0.1.750
  build with TP-1238's fix: queued on GitHub for 23 min".
  """

  require Logger

  alias SymphonyElixir.{BuildInfo, DecisionRequest, MergeConfirmation, Pauses, RunStore, TicketState, UpdateHold}
  alias SymphonyElixir.GitHub.{PullRequest, Repo}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrDecision.Apply

  @workflow "release"
  @max_reruns 2
  @condition_prefix "release_build:"
  @setter %{kind: :rule, name: "Release build watch"}
  @keep_retrying "Keep retrying"
  @wait "Wait"
  @rerun_build "Rerun the build"
  @wait_for_fix "Wait for a fix"
  @lack_of_machine "cancelled for lack of a machine"

  @typedoc """
  What the build's run is at: `:not_started` (no run yet), `:queued`, `:running`, `:built`,
  `:cancelled` (cancelled for lack of a machine, its rerun not sent yet), `:asked` (cancelled again
  after its reruns, a person asked), `:waiting` (a person chose to wait) or `:failed`.
  """
  @type state :: :not_started | :queued | :running | :built | :cancelled | :asked | :waiting | :failed

  @typedoc "A held ticket a question may be asked on."
  @type ticket :: %{id: String.t(), identifier: String.t() | nil, state: String.t() | nil}

  @typedoc "A question asked about one attempt of the run: what kind, its title, on which ticket, and how many same-titled answers the ticket held before."
  @type question :: %{
          kind: :cancelled | :failed,
          title: String.t(),
          attempt: pos_integer(),
          issue_id: String.t(),
          prior: non_neg_integer()
        }

  @type t :: %{
          sha: String.t(),
          repo: String.t() | nil,
          repo_key: String.t() | nil,
          tickets: [ticket()],
          state: state(),
          run_id: String.t() | nil,
          number: pos_integer() | nil,
          attempt: pos_integer() | nil,
          conclusion: String.t() | nil,
          since: DateTime.t() | nil,
          since_attempt: pos_integer() | nil,
          reruns: non_neg_integer(),
          rerun_attempt: pos_integer() | nil,
          question: question() | nil,
          answer: %{kind: :cancelled | :failed, attempt: pos_integer()} | nil
        }

  @doc """
  Checks the build of every merge commit a ticket among `issues` waits on (the `UpdateHold` reasons
  on their pauses, their commits from `cache`), except one already published, and clears the Symphony pause reason of each commit of
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
    # A published build is the app update's to finish: its run is not read again.
    for {sha, tickets} <- waits, not match?(%{state: :built}, get(sha, opts)) do
      check(sha, repo, repo_key, Enum.sort_by(tickets, & &1.identifier), opts)
    end

    clear_unwatched(repo_key, Map.keys(waits), opts)
  end

  def watch(_issues, _build, _cache, _repo_key, _opts), do: :ok

  defp ticket(%Issue{} = issue), do: %{id: issue.id, identifier: issue.identifier, state: issue.state}

  def delivered(sha, opts \\ [])

  @doc """
  Checks again, at once, the build of commit `sha` when a held ticket waits on it and its run isn't
  built yet: a `workflow_run` delivery said a run on it finished. The check runs under
  `opts[:supervisor]` (default Symphony's task supervisor); `:ignored` for any other commit.
  """
  @spec delivered(String.t() | nil, keyword()) :: :started | :ignored
  def delivered(sha, opts) when is_binary(sha) do
    case get(String.downcase(sha), opts) do
      %{state: state, repo: repo, tickets: [_ | _] = tickets} = record when state != :built and is_binary(repo) ->
        supervisor = Keyword.get(opts, :supervisor, SymphonyElixir.TaskSupervisor)
        {:ok, _pid} = Task.Supervisor.start_child(supervisor, fn -> check(record.sha, repo, record.repo_key, tickets, opts) end)
        :started

      _not_watched ->
        :ignored
    end
  end

  def delivered(_sha, _opts), do: :ignored

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
        record = record |> take_answer(run, opts) |> step(run)
        stored = put(record, opts)
        sync_pause(stored, opts)
        {:ok, stored}

      {:error, reason} ->
        Logger.debug("Could not read the release build of #{sha} in #{repo}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def check(_sha, _repo, _repo_key, _tickets, _opts), do: {:error, :no_repository}

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
  defp words(%{state: :cancelled}, _now), do: "#{@lack_of_machine}, rerunning it"
  defp words(%{state: :asked} = record, _now), do: "#{@lack_of_machine} #{record.reruns + 1} times; you were asked whether to keep retrying"
  defp words(%{state: :waiting}, _now), do: "#{@lack_of_machine}; you chose to wait"
  defp words(%{state: :failed, answer: %{kind: :failed}}, _now), do: "failed on GitHub; waiting for a fix"
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
      repo_key: nil,
      tickets: [],
      state: :not_started,
      run_id: nil,
      number: nil,
      attempt: nil,
      conclusion: nil,
      since: nil,
      since_attempt: nil,
      reruns: 0,
      rerun_attempt: nil,
      question: nil,
      answer: nil
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
      run.conclusion == "CANCELLED" -> cancelled(record, run)
      true -> failed(record, run)
    end
  end

  defp now_of(record), do: Map.get(record, :now) || DateTime.utc_now()

  # The run's number, attempt and conclusion; a new attempt starts its own time in the queue. A rerun
  # Symphony sent and GitHub hasn't started yet already started its attempt's time.
  defp observe(record, run, now) do
    record = %{record | run_id: run.id, number: run.number, attempt: run.attempt, conclusion: run.conclusion}

    cond do
      run.attempt == record.rerun_attempt -> record
      record.since_attempt == run.attempt and record.since -> record
      run.attempt == 1 -> %{record | since: run.created_at || now, since_attempt: 1}
      true -> %{record | since: now, since_attempt: run.attempt}
    end
  end

  # Cancelled before any job started: no machine took it. Once a job started, it is a failure.
  defp cancelled(record, run) do
    case github(record).run_started?(run.id, gh_opts(record)) do
      {:ok, false} -> starved(record, run)
      {:ok, true} -> failed(record, run)
      {:error, _reason} -> record
    end
  end

  defp starved(record, run) do
    cond do
      answered?(record, :cancelled, run.attempt) -> %{record | state: :waiting}
      record.reruns < @max_reruns -> rerun(record, run, &%{&1 | reruns: &1.reruns + 1})
      asked?(record, :cancelled, run.attempt) -> %{record | state: :asked}
      true -> ask(record, run, :cancelled)
    end
  end

  defp failed(record, run) do
    if asked?(record, :failed, run.attempt) or answered?(record, :failed, run.attempt),
      do: %{record | state: :failed},
      else: ask(record, run, :failed)
  end

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

  defp ask(record, _run, kind), do: %{record | state: if(kind == :failed, do: :failed, else: :cancelled)}

  defp state_after_ask(:cancelled), do: :asked
  defp state_after_ask(:failed), do: :failed

  defp ask_through_decision_request(ticket, request, record) do
    DecisionRequest.ask(ticket, request, Keyword.take(Map.get(record, :opts, []), [:tracker, :store]))
  end

  # The answer to the open question, read from the asked ticket's recorded decisions: the first
  # same-titled one after those it held when asked.
  defp take_answer(record, run, opts) do
    record = Map.merge(record, %{opts: opts, now: now(opts)})

    with %{question: %{title: title, prior: prior, issue_id: issue_id} = question} <- record,
         false <- answered?(record, question.kind, question.attempt),
         %{answer: answer} <- record |> decisions(issue_id) |> Enum.filter(&Apply.same_title?(&1, title)) |> Enum.at(prior) do
      apply_answer(record, question, pick(question.kind, answer), run)
    else
      _unanswered -> record
    end
  end

  defp pick(:cancelled, answer), do: MergeConfirmation.picked_option([@keep_retrying, @wait], List.wrap(answer))
  defp pick(:failed, answer), do: MergeConfirmation.picked_option([@rerun_build, @wait_for_fix], List.wrap(answer))

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
      :error -> stored_decisions(record.repo_key, issue_id)
    end
  end

  defp stored_decisions(repo_key, issue_id) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      %{} = ticket_record -> TicketState.decisions(ticket_record)
      _none -> []
    end
  end

  # Symphony's pause holds a failed build's reason until it is rerun or a person answered.
  defp sync_pause(%{repo_key: repo_key} = record, opts) when is_binary(repo_key) do
    condition = condition(repo_key, record.sha)

    if record.state == :failed and not answered?(record, :failed, record.attempt) do
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
    "The #{build_name(record)} failed on GitHub (#{failure_words(record.conclusion)}); #{waiting_names(record)} #{verb(record, "waits", "wait")} for it"
  end

  defp failure_words("TIMED_OUT"), do: "it ran out of time"
  defp failure_words("STARTUP_FAILURE"), do: "it failed to start"
  defp failure_words("CANCELLED"), do: "it was cancelled while building"
  defp failure_words(_conclusion), do: "a step failed"

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
      question: "GitHub's #{build} failed: #{failure_words(record.conclusion)}. #{names} #{verb(record, "waits", "wait")} for that build. Should Symphony rerun it, or wait for a fix?",
      why:
        "The build itself failed, which is not a shortage of machines. " <>
          "Symphony paused on the failure so the chain doesn't wait without saying why. " <>
          "The run's page on GitHub shows which step failed.",
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
  defp store(opts), do: Keyword.get(opts, :run_store, RunStore)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
