defmodule SymphonyElixir.PhaseSteps do
  @moduledoc """
  The step runner: walks a run's step list (`phases.<kind>.steps`,
  `SymphonyElixir.Config.Schema.Phases`) and runs its **machine** steps itself, between agent turns.

  A machine step runs each of its commands whose `when` holds, in order, in the ticket's workspace
  through the workspace command runner (`SymphonyElixir.Workspace.run_step_command/5`): a login
  shell with the step's `timeout_ms` for the whole step and the environment an agent child gets
  (`SymphonyElixir.AgentEnv`'s allow-list), plus the changed files of the workspace
  (`SYMPHONY_CHANGED_ELIXIR_FILES`, `SYMPHONY_CHANGED_TEST_FILES`,
  `SYMPHONY_CHANGED_SWIFT_TEST_FILTER`). It records `step.started` and `step.completed` on the
  ticket's ledger (`SymphonyElixir.TicketEvents`), the output kept as a `step_output` artifact.

  The outcome picks the next step (`run_machine_steps/3`):

  - `passed`: the next step in the list;
  - `failed` (a command exited non-zero): the step its `on_fail` names, the output carried to the
    next agent turn's prompt (`prompt_section/2`); a step with no `on_fail` ends the run;
  - no result (the timeout stopped it): the step runs again, up to its `no_result_limit` in a row
    (decision 3 of TP-1085: two); the last one ends the step `paused` on a Question
    (`SymphonyElixir.Questions.ask/3`) carrying the output's last lines and the ways forward: go on
    past the step, run it again, or the person's own words. The Question pauses the ticket, and its
    answer is what lets it run again;
  - a step whose `when`, or every command's, does not match the changed files is `skipped`, with
    the reason.

  A delegated or orchestrated step is an agent turn the agent runner starts
  (`SymphonyElixir.AgentRunner`): this module says which step comes next (`next/3`) and records the
  delegated step's start and end Symphony drives (`record_turn_started/2`, `record_turn_passed/3`).
  """

  require Logger

  alias SymphonyElixir.{Artifacts, Questions, TicketEvents, Workspace}
  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.Config.Schema.Phases.Step
  alias SymphonyElixir.HumanActions.PlainWords

  @output_max_bytes 512 * 1024
  @prompt_output_bytes 12_000
  @question_lines 6
  @question_chars 400
  @command_max 2_000
  @ended "end"
  @ended_title "the end of the run"
  @asker_name "Symphony"
  @skip_reasons %{"macos_changed" => "nothing in the Mac app changed", "elixir_changed" => "no Elixir changed"}
  # What the changed-files script prints: one `<status>\t<path>` line a change (`D` a deletion),
  # then `T\t<path>` for each test file the workspace tracks.
  @changes_script """
  base=$(git merge-base HEAD "origin/$SYMPHONY_BASE_BRANCH" 2>/dev/null || git rev-parse HEAD 2>/dev/null)
  if [ -n "$base" ]; then git diff --name-status --no-renames "$base" 2>/dev/null; fi
  git ls-files --others --exclude-standard 2>/dev/null | sed 's/^/A\t/'
  git ls-files 'test/*_test.exs' 2>/dev/null | sed 's/^/T\t/'
  """

  @typedoc "The files a workspace changed against its base branch, and its tracked test files."
  @type changes :: %{changed: [String.t()], existing: [String.t()], tests: [String.t()]}

  @typedoc "A step run's notice to its owner: a machine step starting (with its deadline) and ending."
  @type notice :: {:started, Step.t(), DateTime.t()} | {:finished, Step.t()}

  @typedoc """
  What a machine step runs for: the ticket (`repo_key`, `issue_id`, `identifier`, `phase`), the run
  (`run_id`), the workspace and its host, the changed files (`changes/1`), the command runner
  (`runner`, default the workspace's), the options its output is kept with (`artifact_opts`) and who
  hears the step start and end (`on_step`).
  """
  @type context :: %{
          required(:repo_key) => String.t(),
          required(:issue_id) => String.t(),
          required(:workspace) => Path.t(),
          optional(:identifier) => String.t() | nil,
          optional(:phase) => String.t() | nil,
          optional(:run_id) => String.t() | nil,
          optional(:worker_host) => String.t() | nil,
          optional(:base_branch) => String.t() | nil,
          optional(:changes) => changes(),
          optional(:runner) => (String.t(), map(), pos_integer() -> runner_result()),
          optional(:artifact_opts) => [Artifacts.ingest_opt()],
          optional(:on_step) => (notice() -> term())
        }

  @type runner_result :: {:ok, {String.t(), integer()}} | {:timeout, String.t()} | {:error, term()}

  @typedoc "A machine step's failure the next agent turn reads: the step and its output."
  @type carry :: %{step: Step.t(), output: String.t()} | nil

  @typedoc """
  Where `run_machine_steps/3` leaves the run: at an agent `{:turn, step, carry}`, `{:paused, step,
  question_id}` on a Question, or `{:end, carry}` past the last step (or a failure that ends it).
  """
  @type walk :: {:turn, Step.t(), carry()} | {:paused, Step.t(), String.t()} | {:end, carry()}

  @doc """
  The steps a run of `kind` follows (`Phases.steps/2`): `symphony.yml`'s `phases.<kind>.steps`
  (`system`, default `Config.system/0`), else the kind's default list, also when there is no
  `symphony.yml`. A kind `phases` doesn't take, or a file Symphony can't read, has none.
  """
  @spec steps(atom(), {:ok, map()} | {:error, term()}) :: [Step.t()]
  def steps(kind, system \\ SymphonyElixir.Config.system()) when is_atom(kind) do
    case {Phases.kind(kind), system} do
      {nil, _system} -> []
      {kind, {:ok, %{phases: %Phases{} = phases}}} -> Phases.steps(phases, kind)
      {kind, {:error, {:missing_symphony_file, _path, _reason}}} -> Phases.default_steps(kind)
      {_kind, _unreadable} -> []
    end
  end

  @doc "Whether a run walks `steps`: it does when one of them is a machine step; else it is one agent session."
  @spec walk?([Step.t()]) :: boolean()
  def walk?(steps) when is_list(steps), do: Enum.any?(steps, &machine?/1)

  @doc "Whether `step` is a machine step."
  @spec machine?(Step.t() | term()) :: boolean()
  def machine?(%Step{mode: "machine"}), do: true
  def machine?(_step), do: false

  @doc """
  The step after `step` in `steps` once it ended with `outcome`: `:passed` goes to the next one,
  `:failed` to the one its `on_fail` names; `:end` when there is none.
  """
  @spec next([Step.t()], Step.t(), :passed | :failed) :: {:ok, Step.t()} | :end
  def next(steps, %Step{on_fail: on_fail}, :failed) do
    case Enum.find(steps, &(&1.id == on_fail)) do
      %Step{} = step -> {:ok, step}
      nil -> :end
    end
  end

  def next(steps, %Step{id: id}, :passed) do
    case steps |> Enum.drop_while(&(&1.id != id)) |> Enum.drop(1) do
      [step | _rest] -> {:ok, step}
      [] -> :end
    end
  end

  @doc """
  The changed files of `context`'s workspace: what changed against the merge-base with
  `origin/<base_branch>` (else `HEAD`), committed or not, and the files nobody tracks yet, with the
  test files the workspace tracks. A workspace git can't read changed nothing.
  """
  @spec changes(context()) :: changes()
  def changes(context) do
    env = %{"SYMPHONY_BASE_BRANCH" => Map.get(context, :base_branch) || "main"}

    case runner(context).(@changes_script, env, 60_000) do
      {:ok, {output, 0}} ->
        parse_changes(output)

      other ->
        Logger.warning("Step runner could not read the changed files of #{context.workspace}: #{inspect(other)}")
        parse_changes("")
    end
  end

  defp parse_changes(output) do
    lines = for line <- String.split(output, "\n", trim: true), [status, path] <- [String.split(line, "\t", parts: 2)], do: {status, path}
    changed = for {status, path} <- lines, status != "T", uniq: true, do: path
    existing = for {status, path} <- lines, status not in ["T", "D"], uniq: true, do: path
    %{changed: changed, existing: existing, tests: for({"T", path} <- lines, do: path)}
  end

  @doc "Whether `condition` (a step's or a command's `when`) holds for `changes`."
  @spec holds?(String.t(), changes()) :: boolean()
  def holds?("always", _changes), do: true
  def holds?("macos_changed", %{changed: changed}), do: Enum.any?(changed, &String.starts_with?(&1, "macos/"))
  def holds?("elixir_changed", %{changed: changed}), do: Enum.any?(changed, &elixir_file?/1)

  defp elixir_file?(path), do: Path.extname(path) in [".ex", ".exs"] or path == "mix.lock"

  @doc """
  The environment a machine step gets on top of the agent allow-list, from `changes`: the Elixir
  files that changed and still exist, the test files to run (the changed ones and those of the
  changed `lib/` files), and the Swift test filter (the test targets of what changed under `macos/`,
  `.` for all of them).
  """
  @spec step_env(changes()) :: %{String.t() => String.t()}
  def step_env(%{existing: existing, tests: tests}) do
    elixir = Enum.filter(existing, &elixir_file?/1)
    tracked = MapSet.new(tests)

    module_tests =
      elixir
      |> Enum.flat_map(fn
        "lib/" <> rest -> if Path.extname(rest) == ".ex", do: ["test/" <> Path.rootname(rest) <> "_test.exs"], else: []
        _other -> []
      end)
      |> Enum.filter(&MapSet.member?(tracked, &1))

    test_files = Enum.uniq(Enum.filter(existing, &(String.starts_with?(&1, "test/") and String.ends_with?(&1, "_test.exs"))) ++ module_tests)

    %{
      "SYMPHONY_CHANGED_ELIXIR_FILES" => Enum.join(elixir, " "),
      "SYMPHONY_CHANGED_TEST_FILES" => Enum.join(test_files, " "),
      "SYMPHONY_CHANGED_SWIFT_TEST_FILTER" => swift_filter(existing)
    }
  end

  defp swift_filter(existing) do
    targets =
      existing
      |> Enum.flat_map(fn
        "macos/Sources/" <> rest -> [(rest |> Path.split() |> hd()) <> "Tests"]
        "macos/Tests/" <> rest -> [rest |> Path.split() |> hd()]
        _other -> []
      end)
      |> Enum.uniq()

    if targets == [], do: ".", else: Enum.join(targets, "|")
  end

  @doc """
  Whether a machine step from `step` on (up to the next agent step) would run a command for
  `changes`, rather than be skipped: only then does the agent's session end for it.
  """
  @spec runs_anything?([Step.t()], Step.t(), changes()) :: boolean()
  def runs_anything?(steps, %Step{id: id}, changes) do
    steps
    |> Enum.drop_while(&(&1.id != id))
    |> Enum.take_while(&machine?/1)
    |> Enum.any?(&(skip_reason(&1, changes) == nil))
  end

  @doc """
  Runs the machine steps of `steps` from `step` on (see the moduledoc) and returns where the run
  goes next. `context` needs `changes` (`changes/1`).
  """
  @spec run_machine_steps([Step.t()], Step.t(), context()) :: walk()
  def run_machine_steps(steps, %Step{} = step, context), do: walk(steps, step, Map.put(context, :steps, steps), nil, 1)

  defp walk(steps, %Step{} = step, context, carry, attempt) do
    if machine?(step) do
      step |> run_machine(context, attempt) |> after_machine(steps, step, context, attempt)
    else
      {:turn, step, carry}
    end
  end

  defp after_machine(:passed, steps, step, context, _attempt), do: go_on(steps, step, :passed, context, nil)
  defp after_machine(:skipped, steps, step, context, _attempt), do: go_on(steps, step, :passed, context, nil)
  defp after_machine({:failed, output}, steps, step, context, _attempt), do: go_on(steps, step, :failed, context, %{step: step, output: output})
  defp after_machine({:again, _output}, steps, step, context, attempt), do: walk(steps, step, context, nil, attempt + 1)
  defp after_machine({:paused, question_id}, _steps, step, _context, _attempt), do: {:paused, step, question_id}

  defp go_on(steps, step, outcome, context, carry) do
    case next(steps, step, outcome) do
      {:ok, next_step} -> walk(steps, next_step, context, carry, 1)
      :end -> {:end, carry}
    end
  end

  # One attempt of a machine step: `:passed`, `:skipped`, `{:failed, output}`, `{:again, output}`
  # (no result, under the cap) or `{:paused, question_id}` (no result at the cap).
  defp run_machine(%Step{} = step, context, attempt) do
    case skip_reason(step, context.changes) do
      nil ->
        execute(step, context, attempt)

      reason ->
        record(context, "step.completed", Map.merge(step_payload(step), %{outcome: "skipped", reason: reason}), [])
        :skipped
    end
  end

  defp skip_reason(%Step{when: condition} = step, changes) do
    cond do
      not holds?(condition, changes) -> Map.fetch!(@skip_reasons, condition)
      commands(step, changes) == [] -> step.command |> Enum.map(&Map.get(@skip_reasons, &1.when)) |> Enum.uniq() |> Enum.join(" and ")
      true -> nil
    end
  end

  defp commands(%Step{command: commands}, changes), do: for(command <- commands, holds?(command.when, changes), do: command.run)

  defp execute(step, context, attempt) do
    commands = commands(step, context.changes)
    started_ms = System.monotonic_time(:millisecond)
    deadline = DateTime.add(DateTime.utc_now(), step.timeout_ms, :millisecond)

    record(context, "step.started", Map.put(step_payload(step), :command, String.slice(Enum.join(commands, " && "), 0, @command_max)), [])
    notify(context, {:started, step, deadline})

    result = run_commands(commands, context, step_env(context.changes), started_ms + step.timeout_ms, [])
    notify(context, {:finished, step})

    duration_ms = System.monotonic_time(:millisecond) - started_ms
    complete(result, step, context, attempt, duration_ms)
  end

  defp run_commands([], _context, _env, _deadline_ms, output), do: {:passed, output}

  defp run_commands([command | rest], context, env, deadline_ms, output) do
    output = [output, "$ ", command, "\n"]
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 1)

    case runner(context).(command, env, remaining_ms) do
      {:ok, {text, 0}} -> run_commands(rest, context, env, deadline_ms, [output, text])
      {:ok, {text, status}} -> {:failed, [output, text, "\n(exit status #{status})\n"]}
      {:timeout, text} -> {:no_result, [output, text, "\n(stopped: no result before the step's timeout)\n"]}
      {:error, reason} -> {:failed, [output, "(could not run: #{inspect(reason)})\n"]}
    end
  end

  defp complete({outcome, output}, step, context, attempt, duration_ms) do
    output = output |> IO.iodata_to_binary() |> String.replace_invalid() |> tail(@output_max_bytes)
    artifacts = output_artifact(output, step, context)
    timed = Map.put(step_payload(step), :duration_ms, duration_ms)

    case outcome do
      :passed ->
        record(context, "step.completed", Map.put(timed, :outcome, "passed"), artifacts)
        :passed

      :failed ->
        record(context, "step.completed", Map.merge(timed, failed_to(context, step)), artifacts)
        {:failed, output}

      :no_result when attempt < step.no_result_limit ->
        record(context, "step.completed", Map.merge(timed, %{outcome: "failed", returns_to: step.id, returns_to_title: step.title}), artifacts)
        {:again, output}

      :no_result ->
        pause(step, context, output, timed, artifacts)
    end
  end

  defp failed_to(context, %Step{on_fail: on_fail}) do
    case Enum.find(Map.get(context, :steps, []), &(&1.id == on_fail)) do
      %Step{id: id, title: title} -> %{outcome: "failed", returns_to: id, returns_to_title: title}
      nil -> %{outcome: "failed", returns_to: @ended, returns_to_title: @ended_title}
    end
  end

  # At the no-result cap the step asks the person; a Question the store refuses fails the step to
  # its `on_fail` instead, so the run never runs it a third time on its own.
  defp pause(step, context, output, timed, artifacts) do
    ticket = {:ticket, context.repo_key, context.issue_id}

    case Questions.ask(ticket, question(step, context, output),
           asked_by: %{kind: :symphony, name: @asker_name, run_id: Map.get(context, :run_id)},
           step: step.id,
           asked_in: Map.get(context, :phase)
         ) do
      {:ok, %{id: question_id}} ->
        record(context, "step.completed", Map.merge(timed, %{outcome: "paused", question_id: question_id}), artifacts)
        {:paused, question_id}

      {:error, reason} ->
        Logger.warning("Step runner could not ask about step #{step.id} of #{ticket_name(context)}: #{inspect(reason)}")
        record(context, "step.completed", Map.merge(timed, failed_to(context, step)), artifacts)
        {:failed, output}
    end
  end

  @doc """
  The Question a machine step asks once it ended with no result `no_result_limit` times in a row:
  the last lines of its output, and the ways forward (go on past the step, run it again; the Inbox
  takes the person's own words too).
  """
  @spec question(Step.t(), context(), String.t()) :: map()
  def question(%Step{} = step, context, output) do
    name = ticket_name(context)
    title = PlainWords.scrub(step.title)
    times = step.no_result_limit

    %{
      title: String.slice("#{name}: #{title} gave no result #{times} times", 0, 120),
      question: "#{title} on #{name} stopped at its time limit #{times} times in a row. Should Symphony go on past it, or run it again?",
      why:
        "Symphony ran #{title} on #{name} #{times} times and each time it ran out of time before it finished, so it does not run it a third time on its own. " <>
          "The last lines it printed: #{output_excerpt(output)}. The full output is on the ticket's timeline.",
      if_unanswered: "#{name} stays paused on this step and Symphony starts nothing on it.",
      recommendation_reason: "A step that hangs twice is likely to hang again, so the run is better off moving on and leaving the check to review.",
      options: [
        %{
          label: "Go on past it",
          effect: "Symphony counts #{title} as done on #{name} and runs the next step.",
          recommended: true,
          tradeoffs: [%{kind: "risk", text: "What this step checks is not checked on this run."}]
        },
        %{
          label: "Run it again",
          effect: "Symphony runs #{title} on #{name} again, with the same time limit.",
          recommended: false,
          tradeoffs: [%{kind: "cost", text: "It may run out of time again."}]
        }
      ]
    }
  end

  defp output_excerpt(output) do
    excerpt =
      output
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.take(-@question_lines)
      |> Enum.join("; ")
      |> PlainWords.scrub()

    case excerpt do
      "" -> "nothing"
      text -> String.slice(text, -@question_chars, @question_chars)
    end
  end

  defp ticket_name(context), do: Map.get(context, :identifier) || "this ticket"

  @doc """
  The section a turn's prompt carries for the step it is on: the step, and when a machine step
  failed before it, which one and its output (the last #{@prompt_output_bytes} bytes).
  """
  @spec prompt_section(Step.t(), carry()) :: String.t()
  def prompt_section(%Step{} = step, carry) do
    [
      "Step runner:",
      "",
      "- This turn is the `#{step.id}` step (#{step.title}) of the run's step list. Symphony runs the list's machine steps (a build, checks, tests) itself " <>
        "between turns, with this session closed, and a machine step that fails brings the run back to the step it names, with its output."
    ]
    |> Kernel.++(step_prompt(step))
    |> Kernel.++(failure(carry))
    |> Enum.join("\n")
  end

  defp step_prompt(%Step{mode: "orchestrated", prompt: prompt}) when is_binary(prompt), do: ["", prompt]
  defp step_prompt(_step), do: []

  defp failure(nil), do: []

  defp failure(%{step: %Step{} = step, output: output}) do
    [
      "- The `#{step.id}` step (#{step.title}) failed. Fix what its output shows; Symphony runs it again after this turn.",
      "",
      SymphonyElixir.PromptSafety.linear_block(tail(output, @prompt_output_bytes), "step_output", @prompt_output_bytes * 8)
    ]
  end

  @doc "Records a delegated or orchestrated step's start, as the turn for it starts."
  @spec record_turn_started(Step.t(), context()) :: :ok
  def record_turn_started(%Step{} = step, context), do: record(context, "step.started", step_payload(step), [])

  @doc "Records a delegated or orchestrated step `passed` after `duration_ms`, as its turn ended."
  @spec record_turn_passed(Step.t(), context(), non_neg_integer()) :: :ok
  def record_turn_passed(%Step{} = step, context, duration_ms),
    do: record(context, "step.completed", Map.merge(step_payload(step), %{outcome: "passed", duration_ms: duration_ms}), [])

  defp step_payload(%Step{id: id, title: title, mode: mode}), do: %{step_id: id, title: title, mode: mode}

  defp record(context, type, payload, artifacts) do
    case TicketEvents.record(context.repo_key, context.issue_id, type, payload, run_id: Map.get(context, :run_id), artifacts: artifacts) do
      {:ok, _event} -> :ok
      {:error, reason} -> Logger.warning("Step runner could not record #{type} for #{ticket_name(context)}: #{inspect(reason)}")
    end

    :ok
  end

  defp output_artifact(output, step, context) do
    path = Path.join(System.tmp_dir!(), "symphony-step-#{step.id}-#{System.unique_integer([:positive])}.log")
    meta = %{repo_key: context.repo_key, issue_id: context.issue_id, run_id: Map.get(context, :run_id), kind: "step_output", label: "#{step.title} output"}

    try do
      File.write!(path, output)

      case Artifacts.ingest(path, meta, Map.get(context, :artifact_opts, [])) do
        {:ok, %{id: id}} ->
          [id]

        {:error, reason} ->
          Logger.warning("Step runner could not keep the output of #{step.id} for #{ticket_name(context)}: #{inspect(reason)}")
          []
      end
    after
      File.rm(path)
    end
  end

  # The last `max` bytes of `text`, from the first whole character on.
  defp tail(text, max) when byte_size(text) <= max, do: text
  defp tail(text, max), do: text |> binary_part(byte_size(text) - max, max) |> whole()

  defp whole(text), do: if(String.valid?(text), do: text, else: text |> binary_part(1, byte_size(text) - 1) |> whole())

  defp notify(context, notice) do
    case Map.get(context, :on_step) do
      on_step when is_function(on_step, 1) -> on_step.(notice)
      nil -> :ok
    end
  end

  defp runner(context) do
    case Map.get(context, :runner) do
      runner when is_function(runner, 3) -> runner
      nil -> &Workspace.run_step_command(&1, context.workspace, Map.get(context, :worker_host), &2, &3)
    end
  end
end
