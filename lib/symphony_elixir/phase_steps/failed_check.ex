defmodule SymphonyElixir.PhaseSteps.FailedCheck do
  @moduledoc """
  The failed-check step of a CI Fix run (TP-1555): Symphony's own machine step command
  (`SymphonyElixir.Config.Schema.Phases.failed_check_command/0`) that runs again, on the run's new
  commit, what failed on GitHub, so no run pushes a CI fix it has not seen pass.

  What failed is read from each failed check's own result, as the CI log tool reads it
  (`SymphonyElixir.GitHub.CiLog`: the job's failed steps, its annotations and its log), for the
  checks the PR watcher found red on the head the run was sent for (the run's `ci_failure`), never
  from the agent's reading of them. For each failed check the step plans (`plan/3`):

  - a check, or a step of one, that only CI can prove (`Phases.ci_only_checks/0`): not run, and the
    output says so with the check's name and why; it does not hold the push back;
  - the test files a red test job names (`test/..._test.exs` in its failure annotations, else in
    its log): one
    `mix test` of all of them that are still in the workspace;
  - the modules a red coverage report names below 100% (its `Coverage` failure annotations):
    `mix cover.changed --file <lib file>` for each;
  - else each failed step the step knows how to run outside GitHub (`@step_commands`, the shell
    line from the workspace's root), or, for a test that drives an app's window, the test of the
    window tests manifest (`SymphonyElixir.PhaseSteps.WindowTests`) it is, run in the QA VM
    (`WindowTests.run_entries/4`), never on Symphony's host;
  - anything else is a check the step has no way to run.

  It runs the shell lines first, in the workspace through the step's runner, then the window
  tests. A command that fails ends the step failed, back to the fix step, with the output. A step
  with nothing failing and a check it has no way to run, or a window test it could not run, asks
  (`{:ask, output, question}`): it pauses on a Question in the Director's Inbox, so the run stops
  before Hand off and nothing is pushed. Only the declared checks are left to CI without one.

  A CI Fix run sent for a merge conflict (its `pr_conflict`) and no failed check: the step is
  skipped (`skip_reason/1`). Any other run with no failed check it knows of stops on the question
  before the push: the step never passes without running what failed.
  """

  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.GitHub.CiLog
  alias SymphonyElixir.HumanActions.PlainWords
  alias SymphonyElixir.PhaseSteps.WindowTests

  @why_chars 600
  @test_file ~r{(?<![\w/.-])test/[\w./-]*_test\.exs}
  @coverage_annotation ~r{\Afailure (lib/[^\s:]+\.ex):\d+ Coverage }

  # What a failed step of a check runs outside GitHub, from the workspace's root: the check's name
  # as `normalize/1` reads it and the step's name as GitHub shows it. A step that changes the machine
  # it runs on (its keychain, the apps it runs, what it installs) is never listed: it is CI's
  # (`Phases.ci_only_checks/0`) or has no way to run here.
  @step_commands %{
    {"format", "Check formatting"} => "mix format --check-formatted",
    {"lint", "Run lint"} => "mix lint",
    {"build", "Build escript"} => "mix escript.build",
    {"audit", "Audit dependencies"} => "mix hex.audit",
    {"release launcher", "Test the release launcher's argument contract"} => "scripts/release/launcher_test.sh",
    {"coverage", "Test the apt install retry"} => "sh scripts/ci/apt-install-test.sh",
    {"mac checks", "Test the Xcode selection script"} => "sh scripts/ci/xcode-developer-dir-test.sh",
    {"mac checks", "Test the shared test helpers"} => "make support-test",
    {"mac checks", "Test the build store"} => "bash scripts/ci/build-store-test.sh",
    {"mac checks", "Build app"} => "cd macos && make app",
    {"mac checks", "Run tests"} => "cd macos && swift test",
    {"mac checks", "Build the gallery"} => "cd macos && make build-gallery && build/SymphonyGallery --check"
  }

  # The failed steps that drive an app's window: the script of the window tests manifest each runs.
  @window_steps %{
    {"mac checks", "Test the QA appearance library"} => "macos/Tests/qa-appearance-test.sh",
    {"mac checks", "Test the QA driver's scrolling"} => "macos/Tests/qa-scroll-test.py",
    {"mac checks", "Test the QA driver's key shortcuts"} => "macos/Tests/qa-key-test.py"
  }

  @typedoc "One thing the step does for a failed check."
  @type item ::
          {:ci_only, String.t(), String.t()}
          | {:tests, [String.t()]}
          | {:coverage, [String.t()]}
          | {:shell, String.t()}
          | {:window, String.t()}
          | {:unknown, String.t()}

  @typedoc "What the step answers the step runner, as a command's result or a Question to pause on."
  @type result :: {:ok, {String.t(), integer()}} | {:timeout, String.t()} | {:ask, String.t(), map()}

  @typedoc "Runs a shell line in the workspace within a time, as the step runner's runner does."
  @type shell ::
          (String.t(), pos_integer() -> {:ok, {String.t(), integer()}} | {:timeout, String.t()} | {:error, term()})

  @doc "The shell lines the step runs for a failed step of a check outside GitHub, by check and step."
  @spec step_commands() :: %{{String.t(), String.t()} => String.t()}
  def step_commands, do: @step_commands

  @doc """
  Why the step is skipped for `context`: the run was sent for a merge conflict (its `pr_conflict`)
  and for no failed check. Else nil: a CI Fix run with no failed check it knows of and no conflict
  runs the step, which stops it on a question before the push (`run/3`).
  """
  @spec skip_reason(map()) :: String.t() | nil
  def skip_reason(context) do
    if is_map(Map.get(context, :pr_conflict)) and failed_checks(context) == [],
      do: "the run was sent for a merge conflict, and no check failed on GitHub for it"
  end

  @doc """
  The checks the run was sent for, from its `ci_failure` (the PR watcher's read of the red head):
  each one's `name` and, when GitHub has one, its `job_id`.
  """
  @spec failed_checks(map()) :: [%{name: String.t(), job_id: String.t() | nil}]
  def failed_checks(context) do
    case Map.get(context, :ci_failure) do
      %{} = failure ->
        for check <- List.wrap(field(failure, :failed_checks)), is_map(check), is_binary(field(check, :name)) do
          %{name: field(check, :name), job_id: id(field(check, :job_id))}
        end

      _none ->
        []
    end
  end

  @doc """
  A check's name as the step compares it: the job's own name (after a reusable workflow's
  `caller / `), without a matrix's `(...)`, in lower case. `coverage (2/4)` is `coverage`.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(name) do
    name |> String.split(" / ") |> List.last() |> String.replace(~r/\s*\([^)]*\)\z/, "") |> String.trim() |> String.downcase()
  end

  @doc "The declared only-CI entry for `check` (its name) and `step` (nil for the whole check), if any."
  @spec ci_only(String.t(), String.t() | nil) :: %{check: String.t(), step: String.t() | nil, why: String.t()} | nil
  def ci_only(check, step \\ nil) do
    name = normalize(check)
    Enum.find(Phases.ci_only_checks(), &(String.downcase(&1.check) == name and &1.step == step))
  end

  @doc """
  What the step does for the failed check `check` (a map with its `name`), from `read` (its job as the CI
  log tool read it, or why it could not be read) and `changes` (the workspace's files, for which
  test files are still there). See the moduledoc.
  """
  @spec plan(%{required(:name) => String.t(), optional(atom()) => term()}, {:ok, map()} | {:error, term()}, map()) :: [item()]
  def plan(%{name: name} = _check, read, changes) do
    case {ci_only(name), read} do
      {%{why: why}, _read} -> [{:ci_only, name, why}]
      {nil, {:error, reason}} -> [{:unknown, "Symphony could not read the result of #{name} on GitHub (#{inspect(reason)})"}]
      {nil, {:ok, job}} -> plan_job(name, job, changes)
    end
  end

  defp plan_job(name, job, changes) do
    # The failure annotations name only the failed tests; the log, read when they name none, may
    # name others in passing.
    named =
      case test_files(Enum.join(List.wrap(job[:annotations]), "\n")) do
        [] -> test_files(job[:log] || "")
        files -> files
      end

    coverage = for line <- List.wrap(job[:annotations]), [_line, file] <- [Regex.run(@coverage_annotation, line)], uniq: true, do: file

    cond do
      named != [] -> plan_tests(name, named, changes)
      coverage != [] -> [{:coverage, coverage}]
      true -> plan_steps(name, List.wrap(job[:failed_steps]), changes)
    end
  end

  defp plan_tests(name, named, changes) do
    present = MapSet.new(Map.get(changes, :tests, []) ++ Map.get(changes, :existing, []))

    case Enum.filter(named, &MapSet.member?(present, &1)) do
      [] -> [{:unknown, "the test files #{name} failed are no longer in the workspace: #{Enum.join(named, ", ")}"}]
      files -> [{:tests, files}]
    end
  end

  defp test_files(text), do: @test_file |> Regex.scan(text) |> List.flatten() |> Enum.uniq()

  defp plan_steps(name, [], _changes), do: [{:unknown, "GitHub names no failed step of #{name}"}]

  defp plan_steps(name, steps, changes) do
    key = normalize(name)
    declared = manifest_scripts(changes)

    Enum.map(steps, fn step ->
      script = Map.get(@window_steps, {key, step})

      cond do
        entry = ci_only(name, step) -> {:ci_only, "#{name} › #{step}", entry.why}
        command = Map.get(@step_commands, {key, step}) -> {:shell, command}
        script && script in declared -> {:window, script}
        script -> {:unknown, "the window tests manifest declares no #{script}, which the step #{step} of #{name} runs"}
        true -> {:unknown, "Symphony has no way to run the step #{step} of #{name} outside GitHub"}
      end
    end)
  end

  # A plain list: Dialyzer reads a MapSet built in one clause and empty in the other as a
  # mismatch of its opaque type.
  defp manifest_scripts(%{window_tests: {:ok, entries}}), do: Enum.map(entries, & &1.script)
  defp manifest_scripts(_changes), do: []

  @doc """
  Runs the step for `context` (a step runner context with `changes`, `ci_failure` and `pr_url`)
  within `timeout_ms`, running shell lines through `shell` (see the moduledoc).
  `context.failed_check_opts` overrides `:read` (`repo, target, opts -> CiLog.read/3`'s result)
  and `:window_tests` (`WindowTests.run_entries/4`).
  """
  @spec run(map(), pos_integer(), shell()) :: result()
  def run(context, timeout_ms, shell) do
    case failed_checks(context) do
      [] -> could_not_run(context, [], "", "Symphony does not know which check failed on GitHub for this run")
      checks -> run_checks(context, checks, timeout_ms, shell)
    end
  end

  defp run_checks(context, checks, timeout_ms, shell) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    planned = Enum.map(checks, &{&1, plan(&1, read(context, &1), context.changes)})
    items = Enum.flat_map(planned, &elem(&1, 1))
    header = header(context, planned)

    with {:done, output} <- run_shells(commands(items), shell, deadline, header),
         {:done, output} <- run_windows(context, items, deadline, output) do
      finish(context, checks, items, output)
    else
      {:failed, output} -> {:ok, {output, 1}}
      {:timeout, output} -> {:timeout, output}
      {:ask, output, question} -> {:ask, output, question}
    end
  end

  defp finish(context, checks, items, output) do
    case for({:unknown, why} <- items, do: why) do
      [] -> {:ok, {output <> passed_line(items), 0}}
      unknown -> could_not_run(context, checks, output, Enum.join(unknown, "; "))
    end
  end

  defp could_not_run(context, checks, output, why), do: {:ask, output <> "\n(could not run: #{why})\n", question(context, Enum.map(checks, & &1.name), why)}

  defp read(context, %{name: name, job_id: job_id}) do
    read = Keyword.get(Map.get(context, :failed_check_opts, []), :read, &CiLog.read/3)

    cond do
      ci_only(name) -> {:error, :ci_only}
      is_nil(job_id) -> {:error, :no_job}
      repo = CiLog.repo_from_url(Map.get(context, :pr_url)) -> job(read.(repo, {:job, job_id}, failed_only: true, cwd: context.workspace))
      true -> {:error, :no_pull_request}
    end
  end

  defp job({:ok, %{jobs: [job | _rest]}}), do: {:ok, job}
  defp job({:ok, _read}), do: {:error, :no_job}
  defp job({:error, reason}), do: {:error, reason}

  defp header(context, planned) do
    head = context.ci_failure |> field(:commit_sha) |> short()
    lines = Enum.map_join(planned, fn {check, items} -> "- #{check.name}: #{Enum.map_join(items, "; ", &item_text/1)}\n" end)
    "What failed on GitHub#{if head, do: " on #{head}"}, run again on this run's commit:\n" <> lines <> "\n"
  end

  defp item_text({:ci_only, _name, why}), do: "can only be proved by CI (#{why})"
  defp item_text({:tests, files}), do: "its failed test files, #{Enum.join(files, ", ")}"
  defp item_text({:coverage, files}), do: "the modules below 100% coverage, in #{Enum.join(files, ", ")}"
  defp item_text({:shell, command}), do: "its failed step, `#{command}`"
  defp item_text({:window, script}), do: "its failed window test, #{script}, in the QA VM"
  defp item_text({:unknown, why}), do: "no way to run it: #{why}"

  # One `mix test` of every failed test file, one `mix cover.changed` of every module below 100%,
  # then each failed step's line, each once.
  defp commands(items) do
    tests = items |> Enum.flat_map(&match_list(&1, :tests)) |> Enum.uniq()
    coverage = items |> Enum.flat_map(&match_list(&1, :coverage)) |> Enum.uniq()

    [
      if(tests != [], do: "mix test " <> Enum.join(tests, " ")),
      if(coverage != [], do: "mix cover.changed " <> Enum.map_join(coverage, " ", &"--file #{&1}"))
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(for {:shell, command} <- items, do: command)
    |> Enum.uniq()
  end

  defp match_list({kind, files}, kind), do: files
  defp match_list(_item, _kind), do: []

  defp run_shells([], _shell, _deadline, output), do: {:done, output}

  defp run_shells([command | rest], shell, deadline, output) do
    output = output <> "$ " <> command <> "\n"

    case shell.(command, remaining(deadline)) do
      {:ok, {text, 0}} -> run_shells(rest, shell, deadline, output <> line_ended(text))
      {:ok, {text, status}} -> {:failed, output <> line_ended(text) <> "(exit status #{status})\n"}
      {:timeout, text} -> {:timeout, output <> line_ended(text)}
      {:error, reason} -> {:failed, output <> "(could not run: #{inspect(reason)})\n"}
    end
  end

  # The window tests the failed steps are, as the workspace's manifest declares them, in the QA VM:
  # those off there end it could not run, naming them.
  defp run_windows(context, items, deadline, output) do
    case for({:window, script} <- items, uniq: true, do: script) do
      [] ->
        {:done, output}

      scripts ->
        {:ok, entries} = context.changes.window_tests
        {off, on} = entries |> Enum.filter(&(&1.script in scripts)) |> Enum.split_with(&is_binary(&1.off))

        run_entries = Keyword.get(Map.get(context, :failed_check_opts, []), :window_tests, &WindowTests.run_entries/4)

        case run_entries.(context, on, off, remaining(deadline)) do
          {:ok, {text, 0}} -> {:done, output <> line_ended(text)}
          {:ok, {text, _status}} -> {:failed, output <> line_ended(text)}
          {:timeout, text} -> {:timeout, output <> line_ended(text)}
          {:ask, text, question} -> {:ask, output <> text, question}
        end
    end
  end

  defp passed_line(items) do
    case for({:ci_only, name, _why} <- items, do: name) do
      [] -> "(every failed check passed on this run's commit)\n"
      names -> "(every failed check Symphony can run passed; #{Enum.join(names, ", ")} can only be proved by CI, so the push goes ahead and CI proves it)\n"
    end
  end

  @doc """
  The Question the step pauses on when nothing it ran failed but a failed check had no way to run
  here (`why`). Going on pushes the fix and leaves the check to CI; that is the person's call, never
  the run's.
  """
  @spec question(map(), [String.t()], String.t()) :: map()
  def question(context, checks, why) do
    name = Map.get(context, :identifier) || "this ticket"
    checks = checks |> Enum.join(", ") |> PlainWords.scrub()
    problem = why |> PlainWords.scrub() |> String.slice(0, @why_chars)

    %{
      title: String.slice("#{name}: a failed check cannot be run again before the push", 0, 120),
      question:
        "The CI Fix run of #{name} fixed what failed on GitHub#{if checks != "", do: " (#{checks})"}, but Symphony has no way to run one of those checks again outside GitHub, so the run stopped before it pushed the fix. Should Symphony push the fix and let CI prove it?",
      why:
        "Symphony runs again what failed on GitHub before it pushes a CI fix, so the fix is seen passing first. It could not here: #{problem}. " <>
          "Only the checks Settings › Phases lists as proved by CI alone are pushed without that.",
      if_unanswered: "#{name} stays paused before its push, and nothing is pushed.",
      recommendation_reason: "Everything else the run checked passed, and CI runs the check again on the push.",
      options: [
        %{
          label: SymphonyElixir.PhaseSteps.go_on_past(),
          effect: "Symphony pushes the fix of #{name} and leaves the check to CI, which runs it again on the push.",
          recommended: true,
          tradeoffs: [%{kind: "risk", text: "If the fix is not enough, CI fails again and the ticket comes back to CI Fix."}]
        },
        %{
          label: SymphonyElixir.PhaseSteps.run_again(),
          effect: "Symphony runs the failed check of #{name} again.",
          recommended: false,
          tradeoffs: [%{kind: "risk", text: "It stops here again while Symphony still has no way to run the check."}]
        },
        %{
          label: SymphonyElixir.PhaseSteps.back_to_code(),
          effect: "Symphony sends your answer to the run's fix step, which works on #{name} again before the checks run.",
          recommended: false,
          tradeoffs: [%{kind: "cost", text: "The run goes back to fixing, and the checks run again after it."}]
        }
      ]
    }
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)

  defp line_ended(text), do: if(text == "" or String.ends_with?(text, "\n"), do: text, else: text <> "\n")

  defp field(%{} = map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp id(value) when is_integer(value), do: Integer.to_string(value)
  defp id(value) when is_binary(value) and value != "", do: value
  defp id(_value), do: nil

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 8)
  defp short(_sha), do: nil
end
