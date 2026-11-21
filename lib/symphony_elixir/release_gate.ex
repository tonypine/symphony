defmodule SymphonyElixir.ReleaseGate do
  @job "release gate"
  @log_lines 60
  @max_files 40

  @moduledoc """
  The release gate of Symphony's own repository: the job `#{@job}` of the `release` workflow, which
  runs on every merge to `main` before anything is published. It runs what a pull request's checks
  skip to stay short (the clean build, every test that drives the app's window, the update and
  rollback test, the release smoke test), so a break those would have caught is found on `main`,
  after the merge. No release is published from a commit whose gate failed, and the app stays on
  its current version.

  A failed gate is not a question for a person. `SymphonyElixir.ReleaseBuild` reads the `release`
  run on its `workflow_run` delivery and, when the step that failed is in this job, calls
  `failed/2`, which files one Urgent fix ticket through `SymphonyElixir.SelfHeal.Fixer`, in Todo, so
  it is dispatched like any Urgent ticket. The ticket is filed under the configured repo whose GitHub
  repository sent the delivery (the build's `repo`), in that repo's Linear team and project: the gate
  is that repository's, and only its agents can change its code. When no configured repo is that
  repository, nothing is filed and a warning names it; the primary repo never stands in. The ticket
  carries what an agent needs to start without asking: the commit and what it changed, the step
  that failed, the first error line and the end of the step's log, and what done means.

  One fix ticket is open at a time. While it is, the next merge's failed gate adds its evidence to
  that ticket as a comment instead of filing another: the gate stays red until the fix lands, and
  every merge in between fails it again. The open ticket is kept in the run store under
  `{:release_gate_fix, repo_key}` and is forgotten once Linear says it is terminal.

  The fix ticket is the one thing a red gate lets run (TP-1528):

    * it is filed in Todo, Urgent, and Symphony moves it back to Todo itself whenever it finds it
      in Backlog or Triage (`failed/2` right after filing, and `reconcile/3` on every poll), so it is
      dispatched without a person;
    * no update hold waits on it (`fix_ticket?/3`): `SymphonyElixir.UpdateHold` and
      `SymphonyElixir.InstructionsHold` leave it out, since the build they would wait for is the one
      its own fix publishes;
    * while the gate is red and the fix ticket is open, every other ticket of the repo is held at
      dispatch (`hold_reason/3`, the rule `:release_gate`): a merge into a `main` whose builds cannot
      publish would only add to what the next build has to carry;
    * the hold follows the gate, not the fix ticket (TP-1583). It lifts when a `release` run passes
      the gate (`passed/2`): a later build, or a rerun of the run that failed on the same commit
      (a later attempt). A delivery missed or a restart is caught by `reconcile/3` on every poll,
      which reads the builds `SymphonyElixir.ReleaseBuild` keeps (the failed commit's and the newest
      merge's) with no GitHub read. The hold also lifts when the fix ticket goes terminal. Once it
      lifts, a dispatch pass of the repo is asked for at once (`opts[:refresh]`, default
      `SymphonyElixir.Orchestrator.request_refresh/2` with `due: :now`), so held tickets do not wait
      for the next poll;
    * a build that passes the gate while the fix ticket is still open (the check passed with no fix
      merged) adds a comment to it saying so and what it still asks for: a check that fails at
      random is a defect in the check. The fix ticket is neither closed nor moved: it runs on as an
      ordinary ticket, and no update hold waits on it;
    * while the gate is red, `red_bases/2` lists it in the state payload's `red_bases` with the
      tickets it holds.

  A pull request cannot prove a fix for a check its own workflow skips, so while the gate is red on
  `main` the `macos` check runs the whole gate on every pull request (`.github/workflows/macos.yml`,
  the `changes` job). The fix ticket's acceptance says so.

  Every effect is injectable: `opts[:fixer]`, `opts[:tracker]`, `opts[:run_store]`,
  `opts[:github]` with `opts[:gh_runner]`, `opts[:repos]` (`{:ok, repos}`, default
  `SymphonyElixir.Config.repos/0`), `opts[:terminal_states]` and `opts[:refresh]` (`repo_key -> term`).
  """

  require Logger

  alias SymphonyElixir.{BuildInfo, Config, Orchestrator, ReleaseBuild, RunStore}
  alias SymphonyElixir.GitHub.{FailedLog, PullRequest, Repo}
  alias SymphonyElixir.Repo.Status, as: RepoStatus

  # The open fix ticket is kept per repo: a failure is added only to its own repo's ticket.
  @key :release_gate_fix
  @component "release_gate"
  # Linear's priority scale: 1 is Urgent.
  @urgent 1

  @typedoc "A release build's record (`SymphonyElixir.ReleaseBuild.t/0`) whose run failed."
  @type build :: map()

  @backlog_states ["backlog", "triage"]
  @todo_state "Todo"

  @typedoc """
  The fix ticket kept per repo: its identifier, the commit and step that failed, the build's run
  number and attempt, and whether the gate is red (no build passed it since).
  """
  @type fix :: %{
          required(:identifier) => String.t(),
          optional(:sha) => String.t(),
          optional(:step) => String.t() | nil,
          optional(:number) => pos_integer() | nil,
          optional(:attempt) => pos_integer() | nil,
          optional(:red) => boolean()
        }

  @doc "The name of the gate's job in the `release` workflow."
  @spec job() :: String.t()
  def job, do: @job

  @doc "Whether the step that failed `build`'s run is in the gate's job."
  @spec gate_failure?(build() | term()) :: boolean()
  def gate_failure?(%{failure: %{job: @job}}), do: true
  # The gate calls a reusable workflow, whose jobs GitHub names `<calling job> / <job>`.
  def gate_failure?(%{failure: %{job: @job <> " / " <> _called}}), do: true
  def gate_failure?(_build), do: false

  @doc """
  Files the fix ticket for `build`'s failed gate under the configured repo of the build's
  repository, or adds the failure to the one already open: `{:filed, identifier}` or
  `{:attached, identifier}`. `{:error, {:unknown_repo, repo}}`, with nothing filed, when no
  configured repo is the build's repository.
  """
  @spec failed(build(), keyword()) :: {:filed | :attached, String.t()} | {:error, term()}
  def failed(%{sha: sha} = build, opts) when is_binary(sha) do
    case repo_key(Map.get(build, :repo), opts) do
      nil ->
        Logger.warning("The release gate failed on #{sha}, but no configured repo is its repository #{inspect(Map.get(build, :repo))}; filed no fix ticket")

        {:error, {:unknown_repo, Map.get(build, :repo)}}

      repo_key ->
        evidence = evidence(build, opts)

        case open_ticket(repo_key, opts) do
          identifier when is_binary(identifier) -> attach(repo_key, identifier, build, evidence, opts)
          nil -> file(repo_key, build, evidence, opts)
        end
    end
  end

  def failed(_build, _opts), do: {:error, :invalid_build}

  @doc """
  Whether `identifier` is `repo_key`'s release-gate fix ticket, open or not: no update hold waits on
  it. Reads only the run store. `opts`: `:run_store`.
  """
  @spec fix_ticket?(String.t() | nil, String.t() | nil, keyword()) :: boolean()
  def fix_ticket?(repo_key, identifier, opts \\ []) do
    is_binary(repo_key) and is_binary(identifier) and match?(%{identifier: ^identifier}, fix(repo_key, opts))
  end

  @doc """
  Why `repo_key`'s ticket `identifier` is not dispatched while the release gate is red: every
  ticket but the fix ticket waits for it ("Holding while the release gate on main is red: TP-1526
  is fixing it"). Nil when the gate is not red, or `identifier` is the fix ticket. Reads only the
  run store. `opts`: `:run_store`.
  """
  @spec hold_reason(String.t() | nil, String.t() | nil, keyword()) :: String.t() | nil
  def hold_reason(repo_key, identifier, opts \\ []) do
    case is_binary(repo_key) && fix(repo_key, opts) do
      %{identifier: ^identifier} -> nil
      %{identifier: fix, red: true} -> "Holding while the release gate on main is red: #{fix} is fixing it"
      _green_none_or_no_repo -> nil
    end
  end

  @doc """
  A release build of the repository `build.repo` passed the gate (it was published): a red gate
  turns green when the build is not older than the one that failed (`later?/2`): a later build, or
  a later attempt of the run on the commit that failed (a rerun). That lifts `hold_reason/3` and
  asks for a dispatch pass of the repo at once. When the fix ticket is still open, its fix did not
  merge before this build: a comment on it says the gate passed again and what the ticket still
  asks for. `:green` when the gate turned green, `:ok` otherwise. `opts`: those of `failed/2`.
  """
  @spec passed(build(), keyword()) :: :green | :ok
  def passed(%{sha: sha} = build, opts) when is_binary(sha) do
    with repo_key when is_binary(repo_key) <- repo_key(Map.get(build, :repo), opts),
         %{red: true} = fix <- fix(repo_key, opts),
         true <- later?(build, fix) do
      green(repo_key, build, fix, opts)
    else
      _not_red_or_older -> :ok
    end
  end

  def passed(_build, _opts), do: :ok

  defp green(repo_key, %{sha: sha} = build, %{identifier: identifier} = fix, opts) do
    remember(repo_key, %{fix | red: false}, opts)
    Logger.warning("The release gate passed again on #{sha}; it no longer holds the tickets of #{repo_key}")
    tell_passed(identifier, build, fix, opts)
    Keyword.get(opts, :refresh, &Orchestrator.request_refresh(&1, due: :now)).(repo_key)
    :green
  end

  # A pass of the commit that failed is a rerun when its attempt is later than the failed one's (or
  # either is unknown); an older build says nothing about the gate now. A build whose run number is
  # unknown is taken as later: it was found after the failure.
  defp later?(%{sha: sha} = build, %{sha: sha} = fix), do: later_attempt?(Map.get(build, :attempt), Map.get(fix, :attempt))
  defp later?(%{number: number}, %{number: failed}) when is_integer(number) and is_integer(failed), do: number > failed
  defp later?(_build, _fix), do: true

  defp later_attempt?(attempt, failed) when is_integer(attempt) and is_integer(failed), do: attempt > failed
  defp later_attempt?(_attempt, _failed), do: true

  defp tell_passed(identifier, build, fix, opts) do
    with {:ok, %{state: state}} <- tracker(opts).fetch_issue_by_identifier(identifier),
         false <- terminal?(state, opts),
         {:error, reason} <- fixer(opts).attach(identifier, passed_comment(build, fix), opts) do
      Logger.warning("Could not tell #{identifier} that the release gate passed again: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Brings `repo_key`'s red gate in line with the builds and its fix ticket on a poll of the repo's
  `issues` (its active tickets). A build `SymphonyElixir.ReleaseBuild` keeps as published, of the
  commit that failed or of the newest merge to `main`, that is not older than the failure turns the
  gate green as `passed/2` does, in case its delivery was missed. Otherwise a fix ticket among
  `issues` is open and dispatchable, and one not among them is read by identifier: one in Backlog or
  Triage is moved to Todo, and a terminal one lifts the hold (its fix merged, or a person closed it;
  a later failure files a new one). A read that fails changes nothing. `opts`: those of `failed/2`.
  """
  @spec reconcile([map()], String.t() | nil, keyword()) :: :ok
  def reconcile(issues, repo_key, opts \\ []) do
    if is_list(issues) and is_binary(repo_key), do: reconcile_red(issues, repo_key, opts)
    :ok
  end

  defp reconcile_red(issues, repo_key, opts) do
    case fix(repo_key, opts) do
      %{red: true} = fix ->
        case passed_build(repo_key, fix, opts) do
          nil -> reconcile_ticket(issues, repo_key, fix, opts)
          build -> green(repo_key, build, fix, opts)
        end

      _green_or_none ->
        :ok
    end
  end

  # The published build, kept by `ReleaseBuild`, that passed the gate since it failed: a rerun of the
  # failed commit's run, or the newest merge's build. Stored state only, no GitHub read.
  defp passed_build(repo_key, fix, opts) do
    failed_commit = if is_binary(Map.get(fix, :sha)), do: ReleaseBuild.get(fix.sha, opts)

    Enum.find([failed_commit, ReleaseBuild.latest(opts)], fn build ->
      match?(%{state: :built}, build) and repo_key(Map.get(build, :repo), opts) == repo_key and later?(build, fix)
    end)
  end

  defp reconcile_ticket(issues, repo_key, %{identifier: identifier} = fix, opts) do
    with false <- Enum.any?(issues, &match?(%{identifier: ^identifier}, &1)),
         {:ok, %{state: state} = issue} <- tracker(opts).fetch_issue_by_identifier(identifier) do
      if terminal?(state, opts) do
        remember(repo_key, %{fix | red: false}, opts)
        Logger.warning("The release gate's fix ticket #{identifier} is #{state}; the gate no longer holds the tickets of #{repo_key}")
      else
        to_todo(issue, opts)
      end
    end
  end

  @doc """
  A row for each configured repo whose release gate is red, in the shape of
  `SymphonyElixir.PrWatch.red_bases/1`'s, for the state payload's `red_bases`: `base` `main`, `check`
  the gate's job (`job/0`) and `issue_identifiers`, the tickets of `skipped` (the orchestrator
  snapshot's `dispatch_skipped`) held by the rule `:release_gate` in that repo. A row leaves once the
  gate is green. Reads only the run store. `opts`: `:run_store`, `:repos`.
  """
  @spec red_bases([map()], keyword()) :: [map()]
  def red_bases(skipped, opts \\ []) do
    case Keyword.get_lazy(opts, :repos, &Config.repos/0) do
      {:ok, repos} ->
        for %{name: repo_key} when is_binary(repo_key) <- repos, match?(%{red: true}, fix(repo_key, opts)) do
          %{base: "main", check: @job, issue_identifiers: held(skipped, repo_key)}
        end

      _no_repos ->
        []
    end
  end

  # A ticket with no repo key reaches the gate only when one repo is configured, which is its repo.
  defp held(skipped, repo_key) do
    skipped
    |> List.wrap()
    |> Enum.filter(&match?(%{rule: :release_gate}, &1))
    |> Enum.filter(&(Map.get(&1, :repo_key) in [repo_key, nil]))
    |> Enum.map(&(Map.get(&1, :identifier) || Map.get(&1, :issue_id)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fix(repo_key, opts) do
    case store(opts).get_github_updates(key(repo_key)) do
      %{identifier: identifier} = fix when is_binary(identifier) -> fix
      _none -> nil
    end
  end

  # The configured repo whose GitHub repository is `repo` (`owner/name`, from the delivery's
  # `repository.full_name`), or nil.
  defp repo_key(repo, opts) when is_binary(repo) do
    with {:ok, repos} <- Keyword.get_lazy(opts, :repos, &Config.repos/0),
         %{name: name} <- Enum.find(repos, &Repo.same?(RepoStatus.github_repo(&1), repo)) do
      name
    else
      _none -> nil
    end
  end

  defp repo_key(_repo, _opts), do: nil

  defp file(scope, build, evidence, opts) do
    description = description(build, evidence)
    attrs = %{scope: scope, repo_key: scope, component: @component, title: title(build), description: description}

    case fixer(opts).create(attrs, Keyword.put(opts, :priority, @urgent)) do
      {:ok, %{identifier: identifier}} when is_binary(identifier) ->
        remember(scope, red(identifier, build), opts)
        Logger.warning("The release gate failed on #{build.sha} (#{place(build)}); filed #{identifier} to fix it")
        ensure_todo(identifier, opts)
        {:filed, identifier}

      {:error, reason} ->
        Logger.warning("Could not file the fix ticket for the release gate that failed on #{build.sha}: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("Could not file the fix ticket for the release gate that failed on #{build.sha}: #{inspect(other)}")
        {:error, :fix_ticket_not_filed}
    end
  end

  defp attach(scope, identifier, build, evidence, opts) do
    case fixer(opts).attach(identifier, comment(build, evidence), opts) do
      :ok ->
        remember(scope, red(identifier, build), opts)
        Logger.warning("The release gate failed again on #{build.sha} (#{place(build)}); added it to #{identifier}")
        {:attached, identifier}

      {:error, reason} ->
        Logger.warning("Could not add the release gate that failed on #{build.sha} to #{identifier}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The fix ticket still open in Linear, or nil: a terminal one, one Linear no longer has, and one
  # that cannot be read now are all forgotten or left out, so a new failure files a new ticket
  # rather than writing on a closed one.
  defp open_ticket(repo_key, opts) do
    with %{identifier: identifier} when is_binary(identifier) <- store(opts).get_github_updates(key(repo_key)),
         {:ok, %{state: state} = issue} <- tracker(opts).fetch_issue_by_identifier(identifier),
         false <- terminal?(state, opts) do
      to_todo(issue, opts)
      identifier
    else
      _none_terminal_or_unreadable -> nil
    end
  end

  defp red(identifier, build),
    do: %{identifier: identifier, sha: build.sha, step: step(build), number: number(build), attempt: attempt(build), red: true}

  defp number(%{number: number}) when is_integer(number), do: number
  defp number(_build), do: nil

  defp attempt(%{attempt: attempt}) when is_integer(attempt), do: attempt
  defp attempt(_build), do: nil

  # The fix ticket is dispatched only from Todo: one Linear (or anyone) left in Backlog or Triage is
  # moved there. A read or a move that fails is tried again by the next poll (`reconcile/3`).
  defp ensure_todo(identifier, opts) do
    case tracker(opts).fetch_issue_by_identifier(identifier) do
      {:ok, issue} -> to_todo(issue, opts)
      {:error, _reason} -> :ok
    end
  end

  defp to_todo(%{id: id, state: state, identifier: identifier}, opts) when is_binary(id) and is_binary(state) do
    if normalize(state) in @backlog_states do
      case tracker(opts).update_issue_state(id, @todo_state) do
        :ok -> Logger.warning("The release gate's fix ticket #{identifier} was in #{state}; moved it to #{@todo_state} so it is dispatched")
        {:error, reason} -> Logger.warning("Could not move the release gate's fix ticket #{identifier} to #{@todo_state}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp to_todo(_issue, _opts), do: :ok

  defp remember(repo_key, ticket, opts) do
    case store(opts).put_github_updates(key(repo_key), ticket) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Could not record the release gate's fix ticket #{ticket.identifier}: #{inspect(reason)}")
    end

    :ok
  end

  defp key(repo_key), do: {@key, repo_key}

  defp terminal?(state, opts) when is_binary(state) do
    normalized = normalize(state)
    opts |> Keyword.get_lazy(:terminal_states, fn -> Config.settings!().tracker.terminal_states end) |> Enum.any?(&(normalize(&1) == normalized))
  end

  defp terminal?(_state, _opts), do: true

  defp normalize(state), do: state |> String.trim() |> String.downcase()

  # What GitHub says about the failure beyond the job and the step: the end of the failed step's
  # log with its first error line, and the commit's subject and files. Each is left out when it
  # cannot be read: the ticket is filed with what is known.
  defp evidence(build, opts) do
    %{log: log(build, opts), commit: commit(build, opts)}
  end

  defp log(%{run_id: run_id} = build, opts) when is_binary(run_id) do
    case FailedLog.read([run_id], @log_lines, gh_opts(build, opts)) do
      {:ok, %{excerpt: excerpt, error: error}} -> %{excerpt: excerpt, error: error}
      {:error, _reason} -> nil
    end
  end

  defp log(_build, _opts), do: nil

  defp commit(%{sha: sha, repo: repo}, opts) do
    args = ["api", "repos/#{repo}/commits/#{sha}", "--jq", "{message: .commit.message, url: .html_url, files: [.files[].filename]}"]

    with {:ok, output} <- github(opts).run_gh(args, Keyword.take(opts, [:gh_runner])),
         {:ok, %{"message" => message} = commit} when is_binary(message) <- Jason.decode(output) do
      %{
        subject: message |> String.split("\n", parts: 2) |> List.first() |> String.trim(),
        url: commit["url"],
        files: for(file <- List.wrap(commit["files"]), is_binary(file), do: file)
      }
    else
      _unreadable -> nil
    end
  end

  defp title(build), do: "Release gate failed on main: #{place(build)} (#{build_name(build)} not published)"

  defp description(build, evidence) do
    Enum.join(
      [
        "Symphony filed this from GitHub's `workflow_run` delivery. The release gate failed on `main`, so the " <>
          "#{build_name(build)} was not published and the app stays on its current version until a merge passes the gate.",
        "## What failed\n\n" <> what_failed(build, evidence),
        log_section(evidence.log),
        files_section(evidence.commit),
        "## Goal\n\nThe release gate passes on `main` again and a release is published.",
        "## Acceptance\n\n" <>
          "* #{step_words(build)} passes on this ticket's pull request. While the gate is red on `main`, every pull request's " <>
          "`macos` check runs the whole gate, so the pull request proves the fix before the merge.\n" <>
          "* After the merge, the `release` run on `main` is green through the job `#{@job}` and publishes a build.\n" <>
          "* The fix repairs what broke, or the check when the check is wrong for a reason the pull request states. The step is " <>
          "never skipped, loosened or removed to get it green. A check that fails at random is a defect in the check: fix it there.",
        "## Where to look\n\n" <>
          "* The gate's steps are the job `#{@job}` in `.github/workflows/release.yml`. The failed step's `run:` line is the command that reproduces it.\n" <>
          "* A step that drives the app's window cannot run inside an agent's sandbox. Run everything else before pushing, and read that step's result on the pull request's `macos` check.\n" <>
          "* When the commit above did not cause it (the failure is in something it did not touch), say so in the pull request, with the evidence."
      ]
      |> Enum.reject(&is_nil/1),
      "\n\n"
    )
  end

  defp comment(build, evidence) do
    Enum.join(
      ["The release gate failed again on `main`, on a later merge. The #{build_name(build)} was not published either.", what_failed(build, evidence), log_section(evidence.log)]
      |> Enum.reject(&is_nil/1),
      "\n\n"
    )
  end

  defp passed_comment(build, fix) do
    failed_on = if is_binary(Map.get(fix, :sha)), do: " on `#{String.slice(fix.sha, 0, 8)}`", else: ""
    step = if is_binary(Map.get(fix, :step)), do: "The step “#{fix.step}”", else: "The job “#{@job}”"
    passed_how = if Map.get(fix, :sha) == build.sha, do: "passed when the same run was run again", else: "passed here"

    Enum.join(
      [
        "The release gate passed again on `main` with the #{build_name(build)} (commit `#{String.slice(build.sha, 0, 8)}`), " <>
          "and this ticket's fix is not merged. #{step} failed#{failed_on} and #{passed_how} with no change made for it.",
        "This ticket still asks for the fix. A check that fails at random is a defect in the check: find why it fails only " <>
          "some of the time and fix it at that cause, so the gate passes on every merge. If it really was fixed by another " <>
          "merge, say which in the pull request, with the evidence.",
        "Other tickets are no longer held while this one is open: the gate holds them only while it is red."
      ],
      "\n\n"
    )
  end

  defp what_failed(build, evidence) do
    [
      "* Run: #{Map.get(build, :url) || "not known"}#{attempt_words(build)}",
      "* Commit: `#{String.slice(build.sha, 0, 8)}`#{commit_words(evidence.commit)}",
      "* Job “#{@job}”, #{step_place(build)}",
      evidence.log && evidence.log.error not in [nil, ""] && "* First error: `#{String.replace(evidence.log.error, "`", "'")}`"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp attempt_words(%{attempt: attempt}) when is_integer(attempt) and attempt > 1, do: " (attempt #{attempt})"
  defp attempt_words(_build), do: ""

  defp commit_words(%{subject: subject, url: url}) when is_binary(url), do: " #{subject} ([commit](#{url}))"
  defp commit_words(%{subject: subject}), do: " #{subject}"
  defp commit_words(nil), do: ""

  # `gh run view --log-failed` starts every line with the job, the step and a timestamp.
  @line_prefix ~r/^[^\t\n]*\t[^\t\n]*\t\x{FEFF}?\S+Z ?/mu

  defp log_section(%{excerpt: excerpt}) when is_binary(excerpt) and excerpt != "" do
    lines = excerpt |> String.replace(@line_prefix, "") |> String.replace("```", "'''") |> String.trim_trailing()
    "## The end of the failed step's log\n\n```text\n#{lines}\n```"
  end

  defp log_section(_log), do: nil

  defp files_section(%{files: [_file | _rest] = files}) do
    shown = Enum.take(files, @max_files)
    more = length(files) - length(shown)

    "## What the commit changed\n\n" <>
      Enum.map_join(shown, "\n", &"* `#{&1}`") <> if(more > 0, do: "\n* and #{more} more", else: "")
  end

  defp files_section(_commit), do: nil

  defp step(%{failure: %{step: step}}) when is_binary(step), do: step
  defp step(_build), do: nil

  defp place(build), do: step(build) || "the job “#{@job}”"

  defp step_place(build) do
    case step(build) do
      nil -> "GitHub does not say which step"
      step -> "step “#{step}”"
    end
  end

  defp step_words(build) do
    case step(build) do
      nil -> "The job `#{@job}`"
      step -> "The step “#{step}”"
    end
  end

  defp build_name(%{number: number}) when is_integer(number), do: "v#{BuildInfo.release_version(number)} build"
  defp build_name(_build), do: "release build"

  defp gh_opts(%{repo: repo}, opts), do: [repo: repo] ++ Keyword.take(opts, [:github, :gh_runner])

  defp github(opts), do: Keyword.get(opts, :github, PullRequest)
  defp fixer(opts), do: Keyword.get(opts, :fixer, SymphonyElixir.SelfHeal.Fixer)
  defp tracker(opts), do: Keyword.get(opts, :tracker, SymphonyElixir.Tracker)
  defp store(opts), do: Keyword.get(opts, :run_store, RunStore)
end
