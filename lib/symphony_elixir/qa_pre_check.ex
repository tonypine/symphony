defmodule SymphonyElixir.QaPreCheck do
  @moduledoc """
  The `QA` state's deterministic pre-check of the walkthrough steps a named automated test proves
  (ADR 0003, `docs/adr/0003-automated-tests-first-qa-last-resort.md`).

  A green head does not prove a named test ran: a path-filtered workflow such as `macos-e2e` may
  not run on a PR at all, or may still be running. So before the QA agent starts,
  `SymphonyElixir.QaVerification` confirms each step that ends in `Proved by: <test>` (the repo's
  `proof_check` runs it) or `Proved by: <check> › <test>` (`SymphonyElixir.Walkthrough`):

    * the named test is in the checkout: each path part of `<test>` (a file or folder, with or
      without a `:line` suffix) is a tracked file, and each other part (a scenario or test name) is
      found in the tracked files, within the file a path part before it names;
    * the check ran on the PR head and passed: `<check>` names a check run, a workflow, or
      `workflow / job`, read from the head's status checks (`SymphonyElixir.GitHub.PullRequest`).

  Each step gets one verdict:

    * `pass`: the check passed and the test exists. QA links it and does not walk it.
    * `pending`: the check is still running. QA waits for it, boundedly.
    * `fail`: the check failed, did not run on the head (or only reported skipped), or the named
      test is not in the checkout. A step naming a check that is neither the repo's `proof_check`
      nor a check on the head says so and names the `proof_check`, so a check name copied from
      another repo is diagnosed in one line. The ticket's proof is part of its work, so QA fails to `Rework`,
      unless the PR and CI watcher reads the head as red or conflicting: then the pass is blocked on
      CI and the watcher routes the head (`SymphonyElixir.QaVerification`).

  A walkthrough without a named-test step is `:none`: nothing is read, and QA runs as it always did.
  """

  alias SymphonyElixir.GitConfigCommands
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Walkthrough

  @separator ~r/\s*(?:›|\s>\s)\s*/u
  @path_part ~r{^[\w.@+/-]+$}u
  @line_suffix ~r/(?::\d+)+$/
  @passing_conclusions ["SUCCESS", "NEUTRAL"]

  @type status :: :pass | :fail | :pending
  @type result :: %{step: Walkthrough.step(), status: status(), detail: String.t(), url: String.t() | nil}
  @type outcome :: :none | {status(), [result()]} | {:error, term()}

  @doc """
  Confirms every named-test step of `steps` on `head`, the commit QA judges, whose checks are read
  from the pull request at `pr_url`. The overall status is the worst step's: `:fail`, then
  `:pending`, then `:pass`.

  `opts[:proof_check]` is the repo's `proof_check`, `opts[:gh_runner]` runs `gh` and `opts[:git]`
  runs git (`fn args, dir -> {output, status} end`). CI is only read for a step whose test is in
  the checkout or whose check is not the `proof_check`, and not at all when there is none.
  """
  @spec run([Walkthrough.step()], String.t(), String.t(), Path.t(), keyword()) :: outcome()
  def run(steps, pr_url, head, workspace, opts \\ []) when is_list(steps) do
    case Enum.filter(steps, &Walkthrough.named_test?/1) do
      [] -> :none
      named -> confirm(named, pr_url, head, workspace, opts)
    end
  end

  defp confirm(steps, pr_url, head, workspace, opts) do
    git = Keyword.get(opts, :git, &git/2)
    proof_check = Keyword.get(opts, :proof_check)
    files = tracked_files(git, workspace)
    tested = Enum.map(steps, &{&1, missing_test(&1, files, git, workspace)})

    with {:ok, checks} <- head_checks(tested, proof_check, pr_url, head, workspace, opts) do
      results = Enum.map(tested, &result(&1, checks, head, proof_check))
      {overall(results), results}
    end
  end

  # The head's checks, read once, and only when a step still needs them: its test is in the
  # checkout, or it names a check other than the proof check, which may not be on the head.
  defp head_checks(tested, proof_check, pr_url, head, workspace, opts) do
    if Enum.any?(tested, &needs_checks?(&1, proof_check)) do
      case PullRequest.fetch_ci_status(pr_url, [cwd: workspace] ++ Keyword.take(opts, [:gh_runner])) do
        {:ok, %{commit_sha: ^head, checks: checks}} -> {:ok, checks}
        {:ok, %{commit_sha: other}} -> {:error, {:pr_head_moved, other}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  defp needs_checks?({_step, nil}, _proof_check), do: true
  defp needs_checks?({step, _missing}, proof_check), do: foreign_check?(step, proof_check)

  defp result({step, missing}, checks, head, proof_check) when is_binary(missing) do
    detail = "#{code(missing)} is not in the checkout#{unknown_check(step, checks, head, proof_check, ", and ")}"
    %{step: step, status: :fail, detail: detail, url: nil}
  end

  defp result({%{proof: %{check: check}} = step, nil}, checks, head, proof_check) do
    {state, run} = check_state(Enum.filter(checks, &check_named?(&1, check)))
    url = run && Map.get(run, :details_url)
    on = "on #{code(String.slice(head, 0, 12))}"

    case unknown_check(step, checks, head, proof_check, "") do
      "" -> check_result(step, state, url, on)
      unknown -> %{step: step, status: :fail, detail: unknown, url: nil}
    end
  end

  defp check_result(%{proof: %{check: check}} = step, state, url, on) do
    case state do
      :passed -> %{step: step, status: :pass, detail: "#{code(check)} passed #{on}#{test_found(step)}", url: url}
      :pending -> %{step: step, status: :pending, detail: "#{code(check)} is still running #{on}", url: url}
      :failed -> %{step: step, status: :fail, detail: "#{code(check)} failed #{on}", url: url}
      :skipped -> %{step: step, status: :fail, detail: "#{code(check)} was skipped #{on}, so its test did not run", url: url}
      :not_run -> %{step: step, status: :fail, detail: "#{code(check)} did not run #{on}", url: nil}
    end
  end

  # What a step naming a check that is neither the repo's proof check nor a check on the head says,
  # naming the proof check; "" for any other step.
  defp unknown_check(%{proof: %{check: check}} = step, checks, head, proof_check, prefix) do
    if foreign_check?(step, proof_check) and not Enum.any?(checks, &check_named?(&1, check)) do
      "#{prefix}#{code(check)} is not a check run or workflow on #{code(String.slice(head, 0, 12))}: " <>
        "this repo's proof check is #{code(proof_check)} (`proof_check` in WORKFLOW.md)"
    else
      ""
    end
  end

  # A step naming a check other than the repo's proof check (none when the repo has no proof check).
  defp foreign_check?(%{proof: %{check: check}}, proof_check) when is_binary(proof_check), do: normalize(check) != normalize(proof_check)
  defp foreign_check?(_step, _proof_check), do: false

  defp test_found(%{proof: %{test: nil}}), do: ""
  defp test_found(%{proof: %{test: test}}), do: " and #{code(test)} is in the checkout"

  defp overall(results) do
    cond do
      Enum.any?(results, &(&1.status == :fail)) -> :fail
      Enum.any?(results, &(&1.status == :pending)) -> :pending
      true -> :pass
    end
  end

  # The state of the check runs a step names: the failed one, else the one still running, else the
  # one that passed. A check that only reported skipped did not run its test.
  defp check_state([]), do: {:not_run, nil}

  defp check_state(runs) do
    states = Enum.map(runs, &{run_state(&1), &1})

    Enum.find_value([:failed, :pending, :passed, :skipped], fn state ->
      Enum.find(states, &(elem(&1, 0) == state))
    end)
  end

  defp run_state(run) do
    case PullRequest.checks_outcome([run]) do
      "failed" -> :failed
      "pending" -> :pending
      "passed" -> if String.upcase(run.conclusion) in @passing_conclusions, do: :passed, else: :skipped
    end
  end

  defp check_named?(run, check) do
    name = normalize(Map.get(run, :name))
    workflow = normalize(Map.get(run, :workflow_name))
    wanted = normalize(check)

    wanted in [name, workflow] or (is_binary(workflow) and is_binary(name) and wanted == "#{workflow} / #{name}")
  end

  # The first part of the step's `<test>` that is not in the checkout, or nil when every part is
  # (or the step names no test). A path part narrows the search of the name parts after it.
  defp missing_test(%{proof: %{test: nil}}, _files, _git, _workspace), do: nil

  defp missing_test(%{proof: %{test: test}}, files, git, workspace) do
    test
    |> String.split(@separator, trim: true)
    |> Enum.map(&unquote_part/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while(nil, fn part, scope ->
      case find_part(part, scope, files, git, workspace) do
        {:ok, scope} -> {:cont, scope}
        :missing -> {:halt, {:missing, part}}
      end
    end)
    |> case do
      {:missing, part} -> part
      _scope -> nil
    end
  end

  # A path-like part with a `/` must be tracked. A bare file name (`check_test.exs`) is matched as a
  # path first, and otherwise searched for like any name, since `Walkthrough.steps` looks like one
  # too. A name with spaces (`handles a/b input`) is never a path, whatever it holds.
  defp find_part(part, scope, files, git, workspace) do
    path = String.replace(part, @line_suffix, "")
    path? = Regex.match?(@path_part, path)
    matched = if path?, do: Enum.filter(files, &path_match?(&1, path)), else: []

    cond do
      matched != [] -> {:ok, matched}
      path? and String.contains?(path, "/") -> :missing
      grep?(git, workspace, part, scope) -> {:ok, scope}
      true -> :missing
    end
  end

  # The file itself, or a file under the folder, from the checkout's root or below it.
  defp path_match?(file, path) do
    path = String.trim_trailing(path, "/")

    file == path or String.ends_with?(file, "/" <> path) or String.starts_with?(file, path <> "/") or
      String.contains?(file, "/" <> path <> "/")
  end

  defp grep?(git, workspace, text, scope) do
    match?({_output, 0}, git.(["grep", "-q", "-I", "-F", "-e", text, "--" | List.wrap(scope)], workspace))
  end

  defp tracked_files(git, workspace) do
    case git.(["ls-files", "-z"], workspace) do
      {output, 0} -> String.split(output, <<0>>, trim: true)
      _failed -> []
    end
  end

  defp git(args, workspace), do: System.cmd("git", GitConfigCommands.subcommand_args(args), cd: workspace, stderr_to_stdout: true)

  @doc """
  The pre-check's lines in the QA report (`SymphonyElixir.QaAgent.Report`'s `### Pre-checks`), one
  per step: its status, the step, what was found and the check run's link.
  """
  @spec report_checks([result()]) :: [%{name: String.t(), status: status(), detail: String.t()}]
  def report_checks(results) do
    Enum.map(results, fn result ->
      %{name: "step #{result.step.number} (#{Walkthrough.proof_line(result.step)})", status: result.status, detail: linked(result)}
    end)
  end

  @doc "One finding per step that failed the pre-check, naming the step and what is missing."
  @spec findings([result()]) :: [String.t()]
  def findings(results) do
    for %{status: :fail} = result <- results do
      "Step #{result.step.number} (#{Walkthrough.proof_line(result.step)}): #{linked(result)}. " <>
        "The ticket's proof is part of its work: make the named test run and pass on the PR head, or correct the step's `Proved by:` line."
    end
  end

  @doc "The detail of a result, with the check run's link when there is one."
  @spec linked(result()) :: String.t()
  def linked(%{detail: detail, url: url}) when is_binary(url), do: "#{detail} (#{url})"
  def linked(%{detail: detail}), do: detail

  defp unquote_part(part) do
    part
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("“")
    |> String.trim_trailing("”")
    |> String.trim()
  end

  defp code(text), do: "`#{text}`"

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: nil
end
