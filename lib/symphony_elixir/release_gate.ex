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
  `failed/2`, which files one Urgent fix ticket in Symphony's own repository through
  `SymphonyElixir.SelfHeal.Fixer`, in Todo, so it is dispatched like any Urgent ticket. The ticket
  carries what an agent needs to start without asking: the commit and what it changed, the step
  that failed, the first error line and the end of the step's log, and what done means.

  One fix ticket is open at a time. While it is, the next merge's failed gate adds its evidence to
  that ticket as a comment instead of filing another: the gate stays red until the fix lands, and
  every merge in between fails it again. The open ticket is kept in the run store under
  `{:release_gate, :fix}` and is forgotten once Linear says it is terminal.

  A pull request cannot prove a fix for a check its own workflow skips, so while the gate is red on
  `main` the `macos` check runs the whole gate on every pull request (`.github/workflows/macos.yml`,
  the `changes` job). The fix ticket's acceptance says so.

  Every effect is injectable: `opts[:fixer]`, `opts[:tracker]`, `opts[:run_store]`,
  `opts[:github]` with `opts[:gh_runner]`, `opts[:symphony_repo_key]` and `opts[:terminal_states]`.
  """

  require Logger

  alias SymphonyElixir.{BuildInfo, Config, RunStore}
  alias SymphonyElixir.GitHub.{FailedLog, PullRequest}

  @key {:release_gate, :fix}
  @component "release_gate"
  # Linear's priority scale: 1 is Urgent.
  @urgent 1

  @typedoc "A release build's record (`SymphonyElixir.ReleaseBuild.t/0`) whose run failed."
  @type build :: map()

  @doc "The name of the gate's job in the `release` workflow."
  @spec job() :: String.t()
  def job, do: @job

  @doc "Whether the step that failed `build`'s run is in the gate's job."
  @spec gate_failure?(build() | term()) :: boolean()
  def gate_failure?(%{failure: %{job: @job}}), do: true
  def gate_failure?(_build), do: false

  @doc """
  Files the fix ticket for `build`'s failed gate, or adds the failure to the one already open:
  `{:filed, identifier}` or `{:attached, identifier}`.
  """
  @spec failed(build(), keyword()) :: {:filed | :attached, String.t()} | {:error, term()}
  def failed(%{sha: sha} = build, opts) when is_binary(sha) do
    evidence = evidence(build, opts)

    case open_ticket(opts) do
      identifier when is_binary(identifier) -> attach(identifier, build, evidence, opts)
      nil -> file(build, evidence, opts)
    end
  end

  def failed(_build, _opts), do: {:error, :invalid_build}

  defp file(build, evidence, opts) do
    scope = Keyword.get_lazy(opts, :symphony_repo_key, fn -> Map.get(build, :repo_key) || Config.repo_key_or_nil() end)
    description = description(build, evidence)
    attrs = %{scope: scope, repo_key: scope, component: @component, title: title(build), description: description}

    case fixer(opts).create(attrs, Keyword.put(opts, :priority, @urgent)) do
      {:ok, %{identifier: identifier}} when is_binary(identifier) ->
        remember(%{identifier: identifier, sha: build.sha, step: step(build)}, opts)
        Logger.warning("The release gate failed on #{build.sha} (#{place(build)}); filed #{identifier} to fix it")
        {:filed, identifier}

      {:error, reason} ->
        Logger.warning("Could not file the fix ticket for the release gate that failed on #{build.sha}: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("Could not file the fix ticket for the release gate that failed on #{build.sha}: #{inspect(other)}")
        {:error, :fix_ticket_not_filed}
    end
  end

  defp attach(identifier, build, evidence, opts) do
    case fixer(opts).attach(identifier, comment(build, evidence), opts) do
      :ok ->
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
  defp open_ticket(opts) do
    with %{identifier: identifier} when is_binary(identifier) <- store(opts).get_github_updates(@key),
         {:ok, %{state: state}} <- tracker(opts).fetch_issue_by_identifier(identifier),
         false <- terminal?(state, opts) do
      identifier
    else
      _none_terminal_or_unreadable -> nil
    end
  end

  defp remember(ticket, opts) do
    case store(opts).put_github_updates(@key, ticket) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Could not record the release gate's fix ticket #{ticket.identifier}: #{inspect(reason)}")
    end

    :ok
  end

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

  defp commit(%{sha: sha, repo: repo}, opts) when is_binary(repo) do
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

  defp commit(_build, _opts), do: nil

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

  defp gh_opts(%{repo: repo}, opts) when is_binary(repo), do: [repo: repo] ++ Keyword.take(opts, [:github, :gh_runner])
  defp gh_opts(_build, opts), do: Keyword.take(opts, [:github, :gh_runner])

  defp github(opts), do: Keyword.get(opts, :github, PullRequest)
  defp fixer(opts), do: Keyword.get(opts, :fixer, SymphonyElixir.SelfHeal.Fixer)
  defp tracker(opts), do: Keyword.get(opts, :tracker, SymphonyElixir.Tracker)
  defp store(opts), do: Keyword.get(opts, :run_store, RunStore)
end
