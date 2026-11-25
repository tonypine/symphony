defmodule SymphonyElixir.QaState do
  @moduledoc """
  Symphony's own check, before a ticket enters QA, that the QA seed and the app's committed fixtures
  on the pull request's head hold the state the plan says each QA check is walked on.

  It reads data only: each QA check QA still walks (`SymphonyElixir.TicketJourney.walked_checks/1`)
  with its `walked_on` entries (a repo-relative `path` and whether it `holds` it already, `present`,
  or the change adds it, `added`) and its `setting`'s `fixture` directory, in the fixed shapes
  `SymphonyElixir.TicketEvents.Types` gives a plan's check. It never reads a check's words. It reads
  the files of the head itself, with git on that sha in the workspace, so what the head holds is
  what the commit holds, never an untracked file. A check's state is missing when:

    * a `walked_on` path, or the `fixture` directory of a `fixture` setting, does not exist on the
      head (`absent`), or is an empty file or a directory whose every file is empty (`empty`);
    * an `added` path is not changed by the pull request against its merge base with the base
      branch (`unchanged`): the plan said this change adds it.

  A QA check with neither (a plan written before them) is not judged (`unjudged`) and never sends
  the ticket back. A ticket with no plan, or no QA check QA still walks, gets no check.

  `gate/4` runs it where a ticket would enter QA (`SymphonyElixir.CodeReview`'s approve, and
  `SymphonyElixir.QaVerification`'s pass as the second guard, for a ticket that reached QA another
  way), only when QA runs. It records the check on the ticket's ledger as a machine step
  (`step.started` and `step.completed`, `step_id` `qa_state`) bound to the head, with the result
  as data (`qa_state`: each check, each path and whether it is held). Missing state ends the step
  `failed` with one `finding.recorded` per check that names the check and each missing path, which
  the rework run reads with the open findings; the caller then moves the ticket to Rework without
  a QA session. A head that cannot be read ends the step `skipped` with why, and the ticket goes on
  to QA. A head the check passed on already is not checked again.
  """

  require Logger

  alias SymphonyElixir.{QaPolicy, RunStore, TicketJourney, TicketSignals, Workspace}

  @step %{step_id: "qa_state", title: "Check the QA seed and fixtures", mode: "machine"}
  @command "symphony qa-state"
  @finding_class "qa_state"

  @typedoc "One path a check is walked on: what the plan said of it, whether the head holds it and, when not, why."
  @type path_result :: %{
          required(:path) => String.t(),
          required(:holds) => String.t(),
          required(:held) => boolean(),
          optional(:why) => String.t()
        }

  @typedoc "One QA check's result: `held`, `missing` or `unjudged` (it names no state)."
  @type check_result :: %{check_id: String.t(), statement: String.t(), status: String.t(), paths: [path_result()]}

  @typedoc "What the caller does: go on to QA, or send the ticket to Rework with the reason."
  @type gate :: :go | {:rework, String.t()}

  @doc """
  The result of each QA check `ticket` still walks, read on `head` in `workspace`. `:none` when the
  ticket has none; `{:error, reason}` when git cannot read the head. `opts[:repo_key]` names the base
  branch an `added` path is compared against; `opts[:git]` overrides the git runner, called as
  `git.(args, cwd)` and returning `{output, status}`.
  """
  @spec judge(TicketJourney.ticket(), Path.t(), String.t(), keyword()) :: :none | {:ok, [check_result()]} | {:error, term()}
  def judge(ticket, workspace, head, opts \\ []) do
    case TicketJourney.walked_checks(ticket) do
      [] -> :none
      checks -> read(checks, workspace, head, opts)
    end
  end

  @doc """
  Runs the check for `issue` on `head` and records it (see the module doc): `:go` when the ticket
  goes on to QA, `{:rework, reason}` when state is missing. `opts[:repo_key]` and `opts[:run_id]`
  place the step on the ticket's ledger, with the run's other steps.
  """
  @spec gate(map(), Path.t(), String.t() | nil, keyword()) :: gate()
  def gate(issue, workspace, head, opts) do
    cond do
      TicketJourney.walked_checks(issue) == [] -> :go
      not is_binary(head) -> record_unread(issue, opts, head, "the head of the pull request could not be read")
      passed_on?(issue.id, head) -> :go
      true -> gate_on(issue, workspace, head, opts)
    end
  end

  defp gate_on(issue, workspace, head, opts) do
    case judge(issue, workspace, head, opts) do
      {:ok, results} -> record_results(issue, opts, head, results)
      {:error, reason} -> record_unread(issue, opts, head, "the head could not be read: #{format_reason(reason)}")
    end
  end

  @doc "Whether the check passed on `head` already: a `qa_state` step ended `passed` bound to it."
  @spec passed_on?(String.t(), String.t()) :: boolean()
  def passed_on?(issue_id, head) do
    events = with {:error, _reason} <- RunStore.list_ticket_events(issue_id, types: ["step.completed"]), do: []
    Enum.any?(events, &(&1.payload.step_id == @step.step_id and &1.payload.outcome == "passed" and &1.head_sha == head))
  end

  @doc "The words of a missing check's finding: the check, each missing path and what the plan said of it."
  @spec finding_text(check_result()) :: String.t()
  def finding_text(%{check_id: id, statement: statement, paths: paths}) do
    missing = for %{held: false} = path <- paths, do: "#{path.path} (#{said(path.holds)}; #{why(path.why)})"

    "QA check #{id} (#{one_line(statement)}) is walked on state the pull request's head does not hold: " <>
      Enum.join(missing, "; ") <> ". Add it to the QA seed or the fixtures in this pull request, or correct the paths the plan names."
  end

  # -- reading the head ---------------------------------------------------------------------

  defp read(checks, workspace, head, opts) do
    git = Keyword.get(opts, :git, &default_git/2)
    entries = Enum.map(checks, &{&1, entries(&1)})

    with {:ok, changed} <- changed(entries, workspace, head, git, opts) do
      Enum.reduce_while(entries, {:ok, []}, fn {check, paths}, {:ok, acc} ->
        case judge_paths(paths, workspace, head, git, changed) do
          {:ok, results} -> {:cont, {:ok, [result(check, results) | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, Enum.reverse(results)}
        error -> error
      end
    end
  end

  # The paths a check names: its `walked_on` entries, then its fixture setting's directory unless an
  # entry already names it.
  defp entries(check) do
    walked = for entry <- List.wrap(Map.get(check, :walked_on)), path = normalize(field(entry, :path)), do: %{path: path, holds: to_string(field(entry, :holds))}

    case fixture(Map.get(check, :setting)) do
      nil -> walked
      path -> if Enum.any?(walked, &(&1.path == path)), do: walked, else: walked ++ [%{path: path, holds: "fixture"}]
    end
  end

  defp fixture(%{} = setting) do
    if to_string(field(setting, :source)) == "fixture", do: normalize(field(setting, :fixture))
  end

  defp fixture(_none), do: nil

  defp normalize(path) when is_binary(path) do
    case path |> String.trim() |> String.trim_trailing("/") do
      "" -> nil
      path -> path
    end
  end

  defp normalize(_path), do: nil

  # The paths the pull request changes, read only when a check names an `added` path.
  defp changed(entries, workspace, head, git, opts) do
    if Enum.any?(entries, fn {_check, paths} -> Enum.any?(paths, &(&1.holds == "added")) end),
      do: QaPolicy.changed_paths(workspace, Keyword.get(opts, :repo_key), head, git: git),
      else: {:ok, []}
  end

  defp judge_paths(paths, workspace, head, git, changed) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case on_head(path.path, workspace, head, git) do
        {:ok, found} -> {:cont, {:ok, [held(path, found, changed) | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp held(path, :absent, _changed), do: Map.merge(path, %{held: false, why: "absent"})
  defp held(path, :empty, _changed), do: Map.merge(path, %{held: false, why: "empty"})

  defp held(%{holds: "added", path: name} = path, :content, changed) do
    if Enum.any?(changed, &(&1 == name or String.starts_with?(&1, name <> "/"))),
      do: Map.put(path, :held, true),
      else: Map.merge(path, %{held: false, why: "unchanged"})
  end

  defp held(path, :content, _changed), do: Map.put(path, :held, true)

  # What the head holds at `path`: nothing, only empty files, or content. The tree's files under it,
  # each with its size (`-` for a submodule, which holds content).
  defp on_head(path, workspace, head, git) do
    case git.(["ls-tree", "-r", "-l", "--full-tree", head, "--", path], workspace) do
      {output, 0} ->
        sizes = for line <- String.split(to_string(output), "\n", trim: true), do: size(line)

        cond do
          sizes == [] -> {:ok, :absent}
          Enum.all?(sizes, &(&1 == "0")) -> {:ok, :empty}
          true -> {:ok, :content}
        end

      {output, status} ->
        {:error, {:git_failed, status, to_string(output)}}
    end
  end

  defp size(line), do: line |> String.split("\t", parts: 2) |> hd() |> String.split() |> List.last()

  defp result(check, []), do: %{check_id: check.id, statement: check.statement, status: "unjudged", paths: []}

  defp result(check, paths) do
    status = if Enum.all?(paths, & &1.held), do: "held", else: "missing"
    %{check_id: check.id, statement: check.statement, status: status, paths: paths}
  end

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  # -- recording ------------------------------------------------------------------------------

  defp record_results(issue, opts, head, results) do
    record(issue, opts, head, "step.started", Map.put(@step, :command, @command))
    payload = Map.put(@step, :qa_state, Enum.map(results, &state_entry/1))

    case Enum.filter(results, &(&1.status == "missing")) do
      [] ->
        record(issue, opts, head, "step.completed", Map.put(payload, :outcome, "passed"))
        :go

      missing ->
        Enum.each(missing, &record_finding(issue, opts, head, &1))
        ids = Enum.map_join(missing, ", ", & &1.check_id)
        reason = String.slice("the QA seed and fixtures on the head do not hold the state QA check(s) #{ids} are walked on", 0, 300)

        record(issue, opts, head, "step.completed", Map.merge(payload, %{outcome: "failed", returns_to: "code", returns_to_title: "Write the code", reason: reason}))
        Logger.info("QA state check for #{label(issue)} head=#{head}: #{reason}; the ticket goes to Rework without a QA session")
        {:rework, reason <> ": " <> Enum.map_join(missing, " ", &finding_text/1)}
    end
  end

  defp record_unread(issue, opts, head, why) do
    record(issue, opts, head, "step.started", Map.put(@step, :command, @command))
    record(issue, opts, head, "step.completed", Map.merge(@step, %{outcome: "skipped", reason: String.slice(why <> "; QA runs", 0, 300)}))
    Logger.warning("QA state check for #{label(issue)} head=#{inspect(head)} did not run: #{why}; QA runs")
    :go
  end

  defp state_entry(%{check_id: id, status: status, paths: paths}) do
    %{check_id: id, status: status, paths: Enum.map(paths, &Map.take(&1, [:path, :holds, :held, :why]))}
  end

  # The finding names no step, so it is never read as QA failing a walked step again.
  defp record_finding(issue, opts, head, result) do
    payload = %{class: @finding_class, severity: "unrated", description: String.slice(finding_text(result), 0, 2_000)}
    record(issue, opts, head, "finding.recorded", payload)
  end

  # Best-effort, like every ledger write: a write the store refuses is logged
  # (`TicketSignals.record_event/5`) and changes neither the result nor the move.
  defp record(issue, opts, head, type, payload) do
    repo_key = Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)
    if is_binary(repo_key), do: TicketSignals.record_event(repo_key, issue.id, type, payload, run_id: Keyword.get(opts, :run_id), head_sha: head)
    :ok
  end

  defp said("present"), do: "the plan says the seed or fixtures hold it already"
  defp said("added"), do: "the plan says this change adds it"
  defp said(_fixture), do: "the check's fixture setting"

  defp why("absent"), do: "the head does not hold it"
  defp why("empty"), do: "it is empty on the head"
  defp why(_unchanged), do: "the pull request does not change it"

  # `on_head/4` and `QaPolicy.changed_paths/4` are the only producers of a reason: a git failure.
  defp format_reason({:git_failed, status, output}),
    do: String.trim_trailing("git exited #{status}: " <> (output |> String.trim() |> String.split("\n") |> hd()), ": ")

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp one_line(text), do: text |> to_string() |> String.split() |> Enum.join(" ")

  defp label(issue), do: Map.get(issue, :identifier) || issue.id
end
