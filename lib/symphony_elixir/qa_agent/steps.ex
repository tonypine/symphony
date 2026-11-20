defmodule SymphonyElixir.QaAgent.Steps do
  @moduledoc """
  A stepped QA pass: with `phases.qa.stepped` on, a pass that runs one playbook with a step list
  (`phases.qa.playbooks.<kind>.steps`, else the playbook's default,
  `SymphonyElixir.Config.Schema.Phases.qa_steps/2`) walks that list instead of handing the agent the
  whole playbook in one session (`list/2`, `run/6`). With the switch off, in an epic review, on a
  pass that runs two playbooks other than `cli`, or for a playbook with no list, the pass is one agent session
  as before (`SymphonyElixir.QaAgent`).

  The `cli` playbook may run beside the playbook whose list the pass walks. The plan is then told
  (`priv/qa_steps/cli/plan.md`) to give each brief a `surface`: `app`, or `cli` for a step commands
  alone can walk. A `cli` brief's walk turn reads `priv/qa_steps/cli/walk.md` and the `cli`
  playbook's rules in place of the app's prompt and the launched app, and runs whether or not the
  app launched.

  Every step is recorded on the ticket's record under the pass's `run_id` (`step.started`,
  `step.completed`, `SymphonyElixir.PhaseSteps`), so the Director's timeline shows the pass as it
  runs.

  **Machine steps** run without a model (`PhaseSteps.run_machine_step/3`), with the QA pass's own
  commands (`Phases.qa_commands/0`) run here, through the QA driver the pass holds:

  - `symphony:qa_pre_checks`: the pre-checks' results (`SymphonyElixir.QaPreCheck`), which ran
    before the pass started: the steps a named test proves;
  - `symphony:qa_build`: `qa_build`, the app Symphony built for the commit; a build that failed
    fails the step;
  - `symphony:qa_launch`: `qa_launch_app` on the default fixtures, then `qa_check_app` once the app
    had a moment to start; an app that is not healthy fails the step, and the agent steps between it
    and the quit step are skipped. It always runs: a pass with nothing on screen to judge rests on
    the app building, starting and checking healthy (`QaDriver.app_check/1`). When the plan answered
    `needs_app: false` and no walkthrough step is walked, the agent steps between the launch and the
    quit (the design check and the wide pass) are skipped, saying the plan found nothing on screen to
    judge, and the review's `pass` is a pass with `scope: none`, which `SymphonyElixir.QaVerification`
    accepts on the app check;
  - `symphony:qa_quit`: `qa_quit_app` for every app the pass launched;
  - `symphony:qa_attach`: the evidence files the steps named and wrote under `qa-evidence/`, with
    any named but missing; the pass keeps them with its other files when it ends, as before.

  A failed machine step goes to its `on_fail` step; one with none ends the pass `blocked` with its
  output.

  **Agent steps** are turns of the QA agent, with the `:qa` tool scope, each ending with an answer
  file checked against the step's `answer` (`PhaseSteps.check_answer/2`); a turn that misses it is
  asked once more, then the step ends `failed` and the pass goes on to its `on_fail` step, else to
  the next one, so the review sees it. A step's turn runs with its `model` (`small` is the run's
  small model) and `effort`, on the run's harness and provider; a run on a fallback provider keeps
  its own model, and the step's `step.started` says so (`model_ignored`). Steps with the same
  `session` continue one conversation (resumed by its id, which Claude supports; another harness
  starts a new one), `fresh` starts one for the step alone, and no `session` is the pass's one
  session. A step with `repeat: walkthrough` runs once per walkthrough step this pass walks (the
  steps no named test proves), as `<id>_<n>`, each with that step's text and the plan's brief for it.
  Every agent step reads the Conductor's newest instructions
  (`SymphonyElixir.Conductor.prompt_section/2`), as the one session's prompt does, so a pass the
  Conductor sent back to QA reads what it must do differently.

  Three steps are read by their id:

  - `plan`: its `walk` must hold a brief (`step`: the walkthrough step's number) for every
    walkthrough step the pass walks, else it is refused and asked again. Its answer is recorded on its `step.completed` (`plan`,
    `SymphonyElixir.QaAgent.StepPayload`), and gives the walk steps their briefs, the design check its gallery entries, and the
    launch its `needs_app`;
  - `review` (required in every QA playbook's list): the verdict. It records it with `qa_verdict`
    in today's contract (`SymphonyElixir.QaAgent.Verdict`), or writes it to its answer file, or asks
    for a recheck there (`{"recheck": [brief, ...]}`, at most #{3}): each brief runs as a fresh turn
    of the list's `repeat` step, between the launch and the quit and attach steps run again, and the
    review runs once more. Past two rounds of recheck the pass is `inconclusive`;
  - the `repeat: walkthrough` step, whose prompt and model the rechecks take.

  The mechanical rules stay `SymphonyElixir.QaAgent`'s and `SymphonyElixir.QaVerification`'s: the
  wide pass audit, the QA host and tunnel checks, each turn's timeout, the per-issue token limit
  (counted across every turn of the pass), and the cleanup of the worktree and its processes.
  """

  require Logger

  alias SymphonyElixir.{AgentTelemetry, AgentTmpDir, Messages, PhaseSteps, PromptSafety, QaAgent, QaDriver}
  alias SymphonyElixir.Conductor.Steer
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.Config.Schema.Phases.Step
  alias SymphonyElixir.PhaseSteps.Transcript
  alias SymphonyElixir.QaAgent.{StepPayload, StepPrompts, Verdict}
  alias SymphonyElixir.QaPreCheck
  alias SymphonyElixir.Walkthrough

  @plan "plan"
  @review "review"
  @launch "symphony:qa_launch"
  @quit "symphony:qa_quit"
  @attach "symphony:qa_attach"
  @statuses ~w(pass fail blocked plan_mismatch)
  @max_rechecks 3
  @max_recheck_rounds 2
  @small_model "small"
  # The playbooks a walk turn can run without the app, from a shell in the worktree. A pass that
  # selects one beside the playbook whose list it walks stays stepped: the plan says, brief by brief,
  # which steps are walked on the command line (`surface: "cli"`).
  @command_line_kinds ~w(cli)
  @command_line "cli"
  @run_session "run"
  @fact_bytes 12_000
  @answer_bytes 4_000
  @launch_settle_ms 3_000
  @app_key {__MODULE__, :app}
  @nothing_on_screen "the plan found nothing on screen to judge: it needs no app and no walkthrough step is walked"
  @output_key {__MODULE__, :output}
  @evidence_dir "qa-evidence"
  @judged_rule "A step's answer `status` is `pass` only when every check in its brief was actually seen and judged. When any part could not be reached, seen or judged (the wrong fixture, an empty state, a screenshot not viewed), the status is `blocked` and `actual` says what blocked it: never `pass`, never `fail`."

  @typedoc "What a stepped pass gives back: `QaAgent.run_result/0`'s, with the review's session (`session_id`)."
  @type run_result :: %{result: QaAgent.result(), tokens: map(), session_id: String.t() | nil}

  @doc """
  The step list `job`'s pass walks, or `[]` for a pass that is one agent session: the list of its
  one playbook, beside `cli` or alone, when `phases.qa.stepped` is on (`opts[:qa_system]`, default `Config.system/0`).
  `opts[:qa_step_list]` gives the list outright.
  """
  @spec list(QaAgent.job(), keyword()) :: [Step.t()]
  def list(job, opts) do
    case Keyword.fetch(opts, :qa_step_list) do
      {:ok, steps} -> steps
      :error -> configured(job, Keyword.get_lazy(opts, :qa_system, &SymphonyElixir.Config.system/0))
    end
  end

  defp configured(%{epic_review: true}, _system), do: []

  defp configured(%{playbooks: [_ | _] = playbooks}, {:ok, %{phases: %Phases{} = phases}}) do
    with true <- Phases.qa_stepped?(phases),
         [kind] <- Enum.map(playbooks, &Map.get(&1, :kind)) -- @command_line_kinds,
         true <- is_binary(kind) do
      Phases.qa_steps(phases, kind)
    else
      _one_session -> []
    end
  end

  defp configured(_job, _system), do: []

  @doc """
  Walks `steps` for `job`'s pass in `worktree` with the QA agent `agent_module` and the QA session
  settings `qa_settings`, and returns what a pass that is one session returns
  (`QaAgent.run_result/0`): the review's verdict, `inconclusive` past the recheck rounds, `blocked`
  on a machine step that failed with nowhere to go, or `{:error, reason, tokens}` when a turn could
  not run, the token limit stopped it, or the pass ended with no verdict.

  `opts`: `:qa_tmp_dir` (the pass's temp folder, required), `:qa_driver` and
  `:qa_android_driver`, `:qa_parent` (the parent issue), `:on_message` (each agent message, as the
  pass forwards them), `:qa_driver_module` (default `SymphonyElixir.QaDriver`) and
  `:qa_launch_settle_ms`.
  """
  @spec run(module(), QaAgent.job(), Path.t(), Schema.t(), [Step.t()], keyword()) :: {:ok, run_result()} | {:error, term(), map()}
  def run(agent_module, job, worktree, %Schema{} = qa_settings, [_ | _] = steps, opts) do
    state = new_state(agent_module, job, worktree, qa_settings, steps, opts)
    Process.delete(@app_key)
    drain_verdicts(nil)

    try do
      state |> walk(List.first(state.steps)) |> finish()
    after
      Process.delete(@app_key)
      drain_verdicts(nil)
    end
  end

  defp new_state(agent_module, job, worktree, qa_settings, steps, opts) do
    tmp_dir = Keyword.fetch!(opts, :qa_tmp_dir)
    targets = walked_steps(job)
    {expanded, walk_targets} = expand(steps, targets)

    context =
      %{
        repo_key: Map.get(job, :repo_key) || Map.get(job.issue, :repo_key) || "default",
        issue_id: job.issue.id,
        identifier: job.issue.identifier,
        phase: job.issue.state,
        run_id: Map.get(job, :run_id),
        workspace: worktree,
        worker_host: nil,
        steps: expanded,
        answer_dir: tmp_dir
      }
      |> maybe_put(:runner, Keyword.get(opts, :qa_step_runner))

    %{
      agent_module: agent_module,
      job: job,
      worktree: worktree,
      opts: opts,
      settings: AgentTmpDir.allow_write(qa_settings, tmp_dir),
      tmp_dir: tmp_dir,
      steps: expanded,
      listed: steps,
      template: Enum.find(steps, &(&1.repeat == "walkthrough")),
      targets: targets,
      walk_targets: walk_targets,
      briefs: %{},
      app_steps: app_steps(expanded),
      context: Map.put(context, :changes, PhaseSteps.changes(context)),
      results: [],
      answers: [],
      plan: nil,
      launch: nil,
      sessions: %{},
      offsets: %{},
      tokens: QaAgent.empty_tokens(),
      session_id: nil,
      rounds: 0,
      verdict: nil,
      ended: nil,
      error: nil
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The walkthrough steps this pass walks: those no named test proves (the pre-checks confirmed those).
  defp walked_steps(job) do
    job |> Map.get(:journey, %{}) |> Map.get(:steps, []) |> Enum.reject(&Walkthrough.named_test?/1)
  end

  defp expand(steps, targets) do
    Enum.reduce(steps, {[], %{}}, fn
      %Step{repeat: "walkthrough"} = step, {list, walk_targets} ->
        repeated = for target <- targets, do: {repeated(step, "#{step.id}_#{target.number}", "#{step.title} #{target.number}"), target}
        {list ++ Enum.map(repeated, &elem(&1, 0)), Map.merge(walk_targets, Map.new(repeated, fn {step, target} -> {step.id, target} end))}

      step, {list, walk_targets} ->
        {list ++ [step], walk_targets}
    end)
  end

  defp repeated(%Step{} = step, id, title), do: %Step{step | id: id, title: title, repeat: nil}

  # The agent steps that drive the app Symphony launched: those after the launch, up to the quit.
  defp app_steps(steps) do
    steps
    |> Enum.drop_while(&(not runs?(&1, @launch)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not runs?(&1, @quit)))
    |> Enum.reject(&PhaseSteps.machine?/1)
    |> MapSet.new(& &1.id)
  end

  defp runs?(%Step{command: commands}, command), do: Enum.any?(commands, &(&1.run == command))

  # -- the walk -----------------------------------------------------------------

  defp walk(state, nil), do: state
  defp walk(%{verdict: verdict} = state, _step) when not is_nil(verdict), do: state
  defp walk(%{error: error} = state, _step) when not is_nil(error), do: state

  defp walk(state, step) do
    case run_step(state, step) do
      {state, {:recheck, briefs}} -> state |> recheck_round(briefs) |> walk(step)
      {state, outcome} -> walk(state, next_step(state, step, outcome))
    end
  end

  defp next_step(state, step, outcome) do
    case PhaseSteps.next(state.steps, step, outcome) do
      {:ok, next} -> next
      :end -> nil
    end
  end

  defp run_step(state, %Step{mode: "machine"} = step), do: machine(state, step, 1)
  defp run_step(state, step), do: agent(state, step)

  # -- machine steps -------------------------------------------------------------

  defp machine(state, step, attempt) do
    step |> PhaseSteps.run_machine_step(machine_context(state), attempt) |> after_machine(state, step, attempt)
  end

  defp after_machine(:passed, state, step, _attempt), do: {state |> machine_passed(step) |> add_result(step, "passed", Process.delete(@output_key)), :passed}
  defp after_machine(:skipped, state, step, _attempt), do: {add_result(state, step, "skipped", nil), :passed}
  defp after_machine({:again, _output}, state, step, attempt), do: machine(state, step, attempt + 1)

  defp after_machine({:failed, output}, state, step, _attempt) do
    state = if runs?(step, @launch), do: %{state | launch: {:failed, tail(output)}}, else: state
    state = add_result(state, step, "failed", tail(output))

    if is_binary(step.on_fail),
      do: {state, :failed},
      else: {%{state | ended: "the #{step.title} step failed: #{tail(output)}"}, :failed}
  end

  defp after_machine({:paused, question_id}, state, step, _attempt) do
    reason = "the #{step.title} step gave no result #{step.no_result_limit} times, so Symphony asked a person about it (question #{question_id})"
    {%{add_result(state, step, "paused", reason) | ended: reason}, :failed}
  end

  defp machine_passed(state, step) do
    cond do
      runs?(step, @launch) -> %{state | launch: {:launched, Process.get(@app_key)}}
      runs?(step, @quit) -> forget_app(state)
      true -> state
    end
  end

  defp forget_app(state) do
    Process.delete(@app_key)
    state
  end

  # Nothing on screen to judge: the plan needs no app and no walkthrough step is walked. The launch
  # still runs, since such a pass rests on the app building, starting and checking healthy.
  defp nothing_on_screen?(%{plan: %{"needs_app" => false}, targets: []}), do: true
  defp nothing_on_screen?(_state), do: false

  defp machine_context(state) do
    Process.delete(@output_key)
    Map.put(state.context, :builtins, Map.new(builtins(state), fn {command, run} -> {command, kept(run)} end))
  end

  # What the pass's own commands print reaches the review with the step's end.
  defp kept(run) do
    fn context ->
      {:ok, {output, _status}} = result = run.(context)
      Process.put(@output_key, String.trim(output))
      result
    end
  end

  defp builtins(state) do
    %{
      "symphony:qa_pre_checks" => fn _context -> pre_checks(state) end,
      "symphony:qa_build" => fn _context -> build(state) end,
      @launch => fn _context -> launch(state) end,
      @quit => fn _context -> quit(state) end,
      @attach => fn _context -> attach(state) end
    }
  end

  defp pre_checks(state) do
    case state.job |> Map.get(:proofs, []) |> QaPreCheck.report_checks() do
      [] -> {:ok, {"No walkthrough step names a test that a check of this repo runs: QA walks every step.\n", 0}}
      checks -> {:ok, {Enum.map_join(checks, "", &"#{&1.name}: #{&1.status}: #{&1.detail}\n"), 0}}
    end
  end

  defp build(state) do
    case tool(state, "qa_build", %{}) do
      {:ok, %{"exit_status" => status} = result} -> {:ok, {Map.get(result, "output", "") <> "\n", status}}
      {:ok, result} -> {:ok, {Jason.encode!(result) <> "\n", 0}}
      {:error, error} -> {:ok, {tool_error(error), 1}}
    end
  end

  # The app the walk's steps drive, on the default fixtures, checked once it had a moment to start.
  defp launch(state) do
    with {:ok, %{"pid" => pid} = launched} <- tool(state, "qa_launch_app", %{}),
         :ok <- Process.sleep(Keyword.get(state.opts, :qa_launch_settle_ms, @launch_settle_ms)),
         {:ok, health} <- tool(state, "qa_check_app", %{"pid" => pid, "page" => "launch"}) do
      Process.put(@app_key, Map.take(launched, ["pid", "root", "environment"]))
      output = "Launched: #{Jason.encode!(launched)}\nqa_check_app: #{Jason.encode!(health)}\n"
      {:ok, {output, if(health["healthy"] == true, do: 0, else: 1)}}
    else
      {:error, error} -> {:ok, {tool_error(error), 1}}
    end
  end

  defp quit(state) do
    output =
      for pid <- driver_module(state).launched_pids(Keyword.get(state.opts, :qa_driver)), into: "" do
        case tool(state, "qa_quit_app", %{"pid" => pid}) do
          {:ok, result} -> "Quit #{pid}: #{result |> Map.get("output", "") |> String.slice(-2_000, 2_000)}\n"
          {:error, error} -> "Quit #{pid}: #{tool_error(error)}"
        end
      end

    {:ok, {if(output == "", do: "No app was running.\n", else: output), 0}}
  end

  # The files the steps named as evidence and wrote under `qa-evidence/`; the pass keeps them with
  # its other files when it ends (`SymphonyElixir.QaAgent`).
  defp attach(state) do
    written = evidence_files(state.worktree)

    named =
      for {_step, answer} <- state.answers, entry <- List.wrap(Map.get(answer, "evidence")), is_binary(entry), uniq: true, do: String.replace_prefix(entry, "./", "")

    missing = Enum.reject(named, &(&1 in written or String.starts_with?(&1, "http")))

    output =
      "Evidence under #{@evidence_dir}/ (#{length(written)} files):\n" <>
        Enum.map_join(written, "", &"- #{&1}\n") <>
        if(missing == [], do: "", else: "Named as evidence but not written:\n" <> Enum.map_join(missing, "", &"- #{&1}\n"))

    {:ok, {output, 0}}
  end

  defp evidence_files(worktree) do
    root = Path.join(worktree, @evidence_dir)

    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.join(@evidence_dir, Path.relative_to(&1, root)))
    |> Enum.sort()
  end

  defp tool(state, name, args), do: driver_module(state).call_tool(Keyword.get(state.opts, :qa_driver), name, args)

  defp driver_module(state), do: Keyword.get(state.opts, :qa_driver_module, QaDriver)

  defp tool_error({:qa_tool, code, message}), do: "#{code}: #{message}\n"
  defp tool_error(other), do: "#{inspect(other)}\n"

  # -- agent steps ---------------------------------------------------------------

  defp agent(state, step) do
    case agent_skip(state, step) do
      nil ->
        start_agent_step(state, step)

      reason ->
        PhaseSteps.record_turn_completed(step, state.context, %{outcome: "skipped", reason: reason}, 0)
        {add_result(state, step, "skipped", reason), :passed}
    end
  end

  # The steps that drive the app run only on an app that launched, and the listed ones only when
  # there is something on screen to judge; a recheck the review asked for runs whatever the plan said.
  defp agent_skip(state, step) do
    cond do
      not MapSet.member?(state.app_steps, step.id) -> nil
      command_line?(state, walk_brief(state, step)) -> nil
      not match?({:launched, _app}, state.launch) -> "the app did not launch"
      state.rounds == 0 and nothing_on_screen?(state) -> @nothing_on_screen
      true -> nil
    end
  end

  defp start_agent_step(state, step) do
    {profile, fields} = turn_profile(state, step)
    PhaseSteps.record_turn_started(step, state.context, Map.merge(fields, prompt_ref(state, step)))
    started = %{at: DateTime.utc_now(), ms: System.monotonic_time(:millisecond)}
    session = session_name(step)
    turn(state, step, %{profile: profile, started: started, resume: session && Map.get(state.sessions, session), lines: []}, notes(state, step, %{}), 1)
  end

  defp turn(state, step, run, notes, attempt) do
    # Only an answer written in this turn counts.
    _removed = File.rm(answer_path(state, step))

    # The Conductor's steers waiting for the pass open its next step's prompt (`SymphonyElixir.Conductor.Steer`).
    # The person's messages no run was given yet, written before the pass started, open each step's
    # prompt: every step is a turn of the same pass, so each is given the same ones and their read is
    # recorded once, for the pass. A message written while the pass works waits for the next run.
    run_id = Map.get(state.job, :run_id)

    prompt =
      run_id
      |> Steer.turn_prompt(false, fn -> prompt(state, step, notes) end)
      |> Messages.prepend_unread(Map.get(state.job, :repo_key), Map.get(state.job.issue, :id), run_id)

    case run_turn(state, step, run.profile, prompt, run.resume) do
      {:ok, state, session_id, lines} ->
        run = %{run | resume: session_id || run.resume, lines: run.lines ++ lines}
        state = remember_session(state, step, session_id)
        step |> read_outcome(state, run.started.at) |> after_turn(state, step, run, notes, attempt)

      {:error, state, reason} ->
        turn_failed(state, step, run, reason)
    end
  end

  # A verdict the review recorded with `qa_verdict` before its turn failed (the token limit stopped
  # it) still stands.
  defp turn_failed(state, step, run, reason) do
    case verdict_before_failure(step) do
      %{} = result ->
        give_verdict(state, step, run, result)

      nil ->
        PhaseSteps.record_turn_completed(step, step_context(state, run), %{outcome: "failed", returns_to: "end"}, duration(run))
        {%{state | error: reason}, :failed}
    end
  end

  defp verdict_before_failure(%Step{id: @review}), do: drain_verdicts(nil)
  defp verdict_before_failure(_step), do: nil

  defp after_turn({:ok, answer}, state, step, run, _notes, _attempt), do: passed(state, step, run, answer)
  defp after_turn({:verdict, result}, state, step, run, _notes, _attempt), do: give_verdict(state, step, run, result)
  defp after_turn({:recheck, briefs}, state, step, run, _notes, _attempt), do: asked_recheck(state, step, run, briefs)

  defp after_turn({:error, why}, state, step, run, notes, 1) do
    Logger.info("QA step #{step.id} of #{state.job.issue.identifier} answered nothing Symphony takes (#{why}); asking once more")
    turn(state, step, run, retry_notes(step, notes, why), 2)
  end

  defp after_turn({:error, why}, state, step, run, _notes, _attempt), do: failed(state, step, run, why)

  defp retry_notes(%Step{mode: "delegated"}, notes, _why), do: Map.put(notes, :reminder, true)
  defp retry_notes(_step, notes, why), do: Map.put(notes, :answer_error, why)

  defp passed(state, step, run, answer) do
    state = %{state | answers: state.answers ++ [{step, answer}]}
    state = if step.id == @plan, do: %{state | plan: answer}, else: state
    PhaseSteps.record_turn_completed(step, step_context(state, run), answer_fields(state, step, answer), duration(run))
    {add_result(state, step, "passed", nil), :passed}
  end

  # The step's answer rides on its own `step.completed` (`SymphonyElixir.QaAgent.StepPayload`), where
  # the Director reads it as fields, never as a note.
  defp answer_fields(state, %Step{id: @plan}, answer), do: %{outcome: "passed", plan: StepPayload.plan(answer, plan_skips(state))}

  defp answer_fields(_state, _step, answer) do
    case StepPayload.result(answer) do
      nil -> %{outcome: "passed"}
      result -> %{outcome: "passed", result: result}
    end
  end

  # The steps a plan that finds nothing on screen leaves unrun.
  defp plan_skips(state) do
    if nothing_on_screen?(state),
      do: for(step <- state.steps, MapSet.member?(state.app_steps, step.id), do: %{title: step.title, why: @nothing_on_screen}),
      else: []
  end

  # A step whose agent gave nothing Symphony takes ends `failed`, and the pass goes on to its
  # `on_fail` step, else to the next one, so the review sees what is missing.
  defp failed(state, step, run, why) do
    target = Enum.find(state.steps, &(&1.id == step.on_fail)) || next_step(state, step, :passed)
    returns_to = if target, do: target.id, else: "end"
    fields = %{outcome: "failed", returns_to: returns_to, reason: StepPayload.reason("gave no answer Symphony takes: #{why}")}
    PhaseSteps.record_turn_completed(step, step_context(state, run), fields, duration(run))
    {add_result(state, step, "failed", why), if(step.on_fail, do: :failed, else: :passed)}
  end

  defp give_verdict(state, step, run, result) do
    fields =
      case StepPayload.verdict_summary(Map.get(result, :summary)) do
        nil -> %{outcome: "passed"}
        summary -> %{outcome: "passed", verdict_summary: summary}
      end

    PhaseSteps.record_turn_completed(step, step_context(state, run), fields, duration(run))
    {%{add_result(state, step, "passed", nil) | verdict: result, session_id: run.resume}, :passed}
  end

  defp asked_recheck(state, step, run, briefs) do
    fields = %{outcome: "passed", recheck: StepPayload.recheck(briefs)}
    PhaseSteps.record_turn_completed(step, step_context(state, run), fields, duration(run))
    state = %{state | session_id: run.resume}

    if state.rounds >= @max_recheck_rounds,
      do: {%{state | verdict: inconclusive()}, :passed},
      else: {state, {:recheck, briefs}}
  end

  defp inconclusive do
    %{
      verdict: :inconclusive,
      summary: "",
      steps: [],
      findings: [],
      reason: "the QA review asked for a recheck after its #{@max_recheck_rounds} rounds of recheck and gave no verdict"
    }
  end

  # One round of recheck: the launch again, a fresh turn of the list's `repeat` step per brief, the
  # quit and the evidence, then the review again (`walk/2`).
  defp recheck_round(state, briefs) do
    round = state.rounds + 1

    checks =
      for {_brief, index} <- Enum.with_index(briefs, 1),
          do: %Step{repeated(state.template, "recheck_#{round}_#{index}", "Recheck #{round}.#{index}") | session: Step.fresh_session(), on_fail: nil}

    recheck_targets = for {brief, check} <- Enum.zip(briefs, checks), target = brief_target(state, brief), into: %{}, do: {check.id, target}
    launches = Enum.filter(state.listed, &runs?(&1, @launch))
    after_checks = Enum.filter(state.listed, &(runs?(&1, @quit) or runs?(&1, @attach)))
    app_steps = if launches == [], do: state.app_steps, else: Enum.reduce(checks, state.app_steps, &MapSet.put(&2, &1.id))

    state = %{
      state
      | rounds: round,
        steps: state.steps ++ checks,
        context: %{state.context | steps: state.steps ++ checks},
        briefs: Map.merge(state.briefs, Map.new(Enum.zip(checks, briefs), fn {check, brief} -> {check.id, brief} end)),
        walk_targets: Map.merge(state.walk_targets, recheck_targets),
        app_steps: app_steps
    }

    Enum.reduce(launches ++ checks ++ after_checks, state, fn step, state -> state |> run_step(step) |> elem(0) end)
  end

  defp brief_target(state, brief), do: Enum.find(state.targets, &(&1.number == brief_number(brief)))

  # -- reading a turn -------------------------------------------------------------

  defp read_outcome(%Step{mode: "delegated"} = step, state, since) do
    case PhaseSteps.agent_outcome(step, state.context, since) do
      {outcome, _reason} when outcome in [:passed, :skipped] -> {:ok, %{}}
      :none -> {:error, "the turn ended without recording `step.completed` for the step"}
      other -> {:error, "the agent ended the step #{inspect(other)}"}
    end
  end

  defp read_outcome(%Step{id: @review} = step, state, _since) do
    case drain_verdicts(nil) do
      %{} = result -> {:verdict, result}
      nil -> review_answer(state, step)
    end
  end

  defp read_outcome(step, state, _since) do
    path = answer_path(state, step)

    with {:ok, text} <- read_answer(path),
         {:ok, answer} <- PhaseSteps.check_answer(step, text) do
      check(state, step, answer)
    end
  end

  defp read_answer(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> {:error, "no answer was written to #{path}"}
    end
  end

  defp review_answer(state, step) do
    path = answer_path(state, step)

    with {:ok, text} <- read_answer(path),
         {:ok, %{} = decoded} <- decode(text) do
      case decoded do
        %{"recheck" => briefs} -> check_recheck(state, briefs)
        verdict -> verdict |> Verdict.from_map() |> verdict_answer()
      end
    else
      {:error, why} -> {:error, "no verdict was recorded with `qa_verdict`, and #{why}"}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, "the answer file does not hold a JSON object"}
    end
  end

  defp verdict_answer({:ok, result}), do: {:verdict, result}
  defp verdict_answer({:error, reason}), do: {:error, "the verdict in the answer file was refused: #{Verdict.describe_error(reason)}"}

  defp check_recheck(%{template: nil}, _briefs), do: {:error, "this pass's list has no `repeat: walkthrough` step to recheck with: give the verdict"}

  defp check_recheck(_state, briefs) do
    if is_list(briefs) and briefs != [] and length(briefs) <= @max_rechecks and Enum.all?(briefs, &is_map/1),
      do: {:recheck, briefs},
      else: {:error, "`recheck` must be a list of one to #{@max_rechecks} briefs, each an object"}
  end

  # The plan must brief every walkthrough step the pass walks; a judged step names its status.
  defp check(state, %Step{id: @plan}, answer) do
    briefed = for brief <- List.wrap(answer["walk"]), number = brief_number(brief), into: MapSet.new(), do: number

    case Enum.reject(state.targets, &MapSet.member?(briefed, &1.number)) do
      [] -> {:ok, answer}
      missing -> {:error, "the plan's `walk` has no brief for walkthrough step #{Enum.map_join(missing, ", ", & &1.number)}, which QA walks"}
    end
  end

  defp check(_state, _step, %{"status" => status} = answer) do
    if status in @statuses,
      do: {:ok, answer},
      else: {:error, "`status` must be one of #{Enum.join(@statuses, ", ")}"}
  end

  defp check(_state, _step, answer), do: {:ok, answer}

  defp brief_number(%{"step" => number}) when is_integer(number), do: number

  defp brief_number(%{"step" => number}) when is_binary(number) do
    case Integer.parse(String.trim(number)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp brief_number(_brief), do: nil

  # -- one turn ---------------------------------------------------------------------

  defp run_turn(state, step, profile, prompt, resume) do
    agent_module = state.agent_module
    {:ok, tracker} = Agent.start_link(fn -> %{tokens: QaAgent.empty_tokens(), session_id: nil} end)

    session_opts = session_opts(state, step, profile)

    try do
      result =
        case agent_module.start_session(state.worktree, session_opts) do
          {:ok, session} -> run_started(state, session, {tracker, session_opts}, prompt, resume)
          {:error, reason} -> {:error, {:qa_agent_failed, reason}}
        end

      %{tokens: tokens, session_id: session_id} = Agent.get(tracker, & &1)
      state = %{state | tokens: add_tokens(state.tokens, tokens)}
      session_id = session_id || turn_session_id(result)
      {lines, offsets} = Transcript.read_session(state.worktree, session_id, state.offsets)
      state = %{state | offsets: offsets}

      case result do
        {:ok, _turn} -> {:ok, state, session_id, lines}
        {:error, reason} -> {:error, state, reason}
      end
    after
      Agent.stop(tracker)
    end
  end

  defp run_started(%{agent_module: agent_module, job: job} = state, session, {tracker, session_opts}, prompt, resume) do
    on_message = on_message(tracker, Map.get(job, :token_limit), state.tokens.total_tokens, self(), Keyword.get(state.opts, :on_message))
    turn_opts = session_opts |> Keyword.put(:on_message, on_message) |> resume_opts(resume)

    case agent_module.run_turn(session, prompt, job.issue, turn_opts) do
      {:ok, turn} -> {:ok, turn}
      {:error, reason} -> {:error, {:qa_agent_failed, reason}}
    end
  catch
    :throw, {:qa_token_limit, total, limit} -> {:error, {:qa_token_limit, total, limit}}
  after
    agent_module.stop_session(session)
  end

  defp session_opts(state, step, profile) do
    %{job: job} = state

    [
      worker_host: nil,
      settings: state.settings,
      issue: job.issue,
      repo_key: Map.get(job, :repo_key),
      run_id: Map.get(job, :run_id),
      run_profile: profile,
      tool_scope: :qa,
      qa_driver: Keyword.get(state.opts, :qa_driver),
      qa_android_driver: Keyword.get(state.opts, :qa_android_driver),
      qa_verdict_sink: if(match?(%Step{id: @review}, step), do: self()),
      agent_tmp_dir: state.tmp_dir,
      extra_env: Map.merge(AgentTmpDir.env(state.settings.execution.harness, state.tmp_dir), host_ports_env(Map.get(job, :host_ports, [])))
    ]
  end

  defp host_ports_env([]), do: %{}
  defp host_ports_env(ports), do: %{"QA_HOST_PORTS" => Enum.join(ports, ",")}

  defp resume_opts(opts, nil), do: opts
  defp resume_opts(opts, session_id), do: Keyword.put(opts, :resume_session_id, session_id)

  defp turn_session_id({:ok, %{session_id: session_id}}) when is_binary(session_id), do: session_id
  defp turn_session_id(_result), do: nil

  defp run_profile(state), do: Map.get(state.job, :run_profile) || state.settings.execution.run

  # The run's profile with the step's `model` and `effort`; a run on a fallback provider keeps its
  # own model, and the step's start says so.
  defp turn_profile(state, step) do
    profile = run_profile(state)
    fields = %{session: step.session || @run_session}

    case {profile, step.model} do
      {nil, _model} ->
        {nil, fields}

      {%{fallback: fallback} = profile, model} when is_binary(model) and not is_nil(fallback) ->
        profile = with_effort(profile, step.effort)
        {profile, Map.merge(fields, %{model: profile.model, effort: profile.effort, model_ignored: model, model_ignored_reason: "the run started on a fallback provider"})}

      {profile, model} ->
        profile = profile |> with_model(model) |> with_effort(step.effort)
        {profile, Map.merge(fields, %{model: profile.model, effort: profile.effort})}
    end
  end

  defp with_model(profile, nil), do: profile
  defp with_model(profile, @small_model), do: %{profile | model: Map.get(profile, :small_model) || profile.model}
  defp with_model(profile, model), do: %{profile | model: model}

  defp with_effort(profile, nil), do: profile
  defp with_effort(profile, effort), do: %{profile | effort: effort}

  # An orchestrated step's start names where its prompt comes from.
  defp prompt_ref(state, %Step{mode: "orchestrated", id: id}) do
    kind = state.job.playbooks |> List.first(%{}) |> Map.get(:kind)
    %{prompt_ref: "phases.qa.playbooks.#{kind}.steps.#{id}"}
  end

  defp prompt_ref(_state, _step), do: %{}

  defp session_name(%Step{session: "fresh"}), do: nil
  defp session_name(%Step{session: nil}), do: @run_session
  defp session_name(%Step{session: name}), do: name

  defp remember_session(state, _step, nil), do: state

  defp remember_session(state, step, session_id) do
    case session_name(step) do
      nil -> state
      name -> %{state | sessions: Map.put(state.sessions, name, session_id)}
    end
  end

  defp on_message(tracker, token_limit, spent, owner, forward) do
    fn message ->
      usage = AgentTelemetry.extract_token_usage(message)

      tokens =
        Agent.get_and_update(tracker, fn tracked ->
          tokens = QaAgent.merge_usage(tracked.tokens, usage)
          {tokens, %{tracked | tokens: tokens, session_id: started_session(message) || tracked.session_id}}
        end)

      if is_function(forward, 1), do: forward.(message)

      if is_integer(token_limit) and spent + tokens.total_tokens >= token_limit and self() == owner do
        throw({:qa_token_limit, spent + tokens.total_tokens, token_limit})
      end

      :ok
    end
  end

  defp started_session({:session_started, session_id}) when is_binary(session_id), do: session_id
  defp started_session(_message), do: nil

  defp add_tokens(spent, tokens), do: Map.merge(spent, tokens, fn _key, left, right -> left + right end)

  # The last verdict a `qa_verdict` call sent this process, or `last`.
  defp drain_verdicts(last) do
    receive do
      {:qa_verdict, result} -> drain_verdicts(result)
    after
      0 -> last
    end
  end

  defp answer_path(state, step), do: PhaseSteps.answer_path(step, state.context)

  defp step_context(state, run), do: Map.put(state.context, :transcript_lines, run.lines)

  defp duration(run), do: System.monotonic_time(:millisecond) - run.started.ms

  defp add_result(state, step, outcome, detail), do: %{state | results: state.results ++ [%{step: step, outcome: outcome, detail: detail}]}

  # -- prompts ------------------------------------------------------------------------

  defp notes(state, %Step{id: @review} = step, notes) do
    answers = for {answered, answer} <- state.answers, do: {answered, cut_answer(answer)}
    Map.merge(notes, %{answers: answers, answer_path: answer_path(state, step)})
  end

  defp notes(state, step, notes), do: Map.put(notes, :answer_path, answer_path(state, step))

  defp cut_answer(answer) do
    if byte_size(Jason.encode!(answer)) > @answer_bytes, do: %{"answer" => answer |> Jason.encode!() |> String.slice(0, @answer_bytes)}, else: answer
  end

  defp prompt(state, step, notes) do
    [
      QaAgent.prompt_parts(state.job, parent(state), [:intro]),
      general_rules(),
      PhaseSteps.prompt_section(surface_step(state, step), nil, notes),
      context_for(state, step)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp parent(state), do: Keyword.get(state.opts, :qa_parent)

  # A walk turn the plan gave to the command line reads that playbook's walk prompt, not the app's.
  defp surface_step(state, %Step{} = step) do
    with true <- Map.has_key?(state.walk_targets, step.id) or Map.has_key?(state.briefs, step.id),
         true <- command_line?(state, walk_brief(state, step)),
         prompt when is_binary(prompt) <- StepPrompts.prompt(@command_line, "walk") do
      %Step{step | prompt: prompt}
    else
      _the_apps -> step
    end
  end

  defp general_rules do
    """
    This turn is one step of a QA pass Symphony runs as a list of steps; other turns run the rest.
    #{@judged_rule}
    Write every file under `#{@evidence_dir}/` in this worktree or under `$TMPDIR`. Never start an
    emulator, a simulator or a device tool yourself. Ending your turn ends the step: stop every
    process you started, and leave nothing running in the background.\
    """
  end

  defp context_for(state, %Step{id: @plan}) do
    [
      QaAgent.prompt_parts(state.job, parent(state), [:issue, :design, :servers, :unprovable]),
      plan_facts(state),
      command_line_plan(state),
      screen_rules(state)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp context_for(state, %Step{id: @review}) do
    [
      QaAgent.prompt_parts(state.job, parent(state), [:issue, :unprovable]),
      "Symphony's own steps of this pass, and how each step ended:\n" <> Enum.map_join(state.results, "\n", &result_line/1),
      "Write a recheck, or the verdict when `qa_verdict` is not available, to `#{answer_path(state, %Step{id: @review})}`."
    ]
    |> Enum.join("\n\n")
  end

  defp context_for(state, step) do
    if Map.has_key?(state.walk_targets, step.id) or Map.has_key?(state.briefs, step.id),
      do: walk_context(state, step),
      else: check_context(state)
  end

  defp walk_context(state, step) do
    target = Map.get(state.walk_targets, step.id)
    brief = walk_brief(state, step)

    [
      target_text(target),
      if(brief, do: "Your brief, from the lead QA agent:\n" <> json(brief), else: "The plan gave no brief for this step: walk it from its text and the ticket."),
      if(command_line?(state, brief), do: command_line_rules(state), else: app_line(state)),
      QaAgent.prompt_parts(state.job, nil, [:servers, :qa_mode, :conductor])
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp walk_brief(state, step), do: Map.get(state.briefs, step.id) || plan_brief(state, Map.get(state.walk_targets, step.id))

  # A brief the plan gave to the command line, on a pass that selected a command-line playbook.
  defp command_line?(state, %{"surface" => @command_line}), do: command_line_playbook(state) != nil
  defp command_line?(_state, _brief), do: false

  defp command_line_playbook(state), do: Enum.find(state.job.playbooks, &(Map.get(&1, :kind) in @command_line_kinds))

  defp command_line_rules(state) do
    case command_line_playbook(state) do
      %{prompt: prompt} when is_binary(prompt) -> "The playbook's rules for the command line:\n\n" <> prompt
      _none -> ""
    end
  end

  # What the plan is told when the pass also selected a command-line playbook: which steps it may
  # give to a shell, and what such a brief holds.
  defp command_line_plan(state) do
    case command_line_playbook(state) do
      nil -> ""
      %{kind: kind} -> StepPrompts.prompt(kind, @plan) || ""
    end
  end

  defp target_text(nil), do: ""

  defp target_text(target) do
    "The walkthrough step you walk (step #{target.number} of the ticket's `## User walkthrough`):\n" <>
      PromptSafety.linear_block(target.text, "walkthrough_step", @fact_bytes)
  end

  defp plan_brief(%{plan: nil}, _target), do: nil
  defp plan_brief(_state, nil), do: nil
  defp plan_brief(%{plan: plan}, target), do: Enum.find(List.wrap(plan["walk"]), &(brief_number(&1) == target.number))

  defp check_context(state) do
    plan = state.plan || %{}

    [
      app_line(state),
      "The gallery entries the plan names:\n" <> json(Map.get(plan, "gallery", [])),
      "The plan's briefs, for the screens and fixtures to use:\n" <> json(Map.get(plan, "walk", [])),
      QaAgent.prompt_parts(state.job, parent(state), [:design, :servers, :qa_mode, :conductor])
    ]
    |> Enum.join("\n\n")
  end

  defp app_line(%{launch: {:launched, %{"pid" => pid} = app}}),
    do: "The app: Symphony launched it as PID #{pid} (QA root #{Map.get(app, "root", 1)}), on the default fixtures."

  defp app_line(_state), do: "The app: Symphony has not launched it for this step; launch it with `qa_launch_app` when the step needs it."

  defp plan_facts(state) do
    walked =
      case state.targets do
        [] -> "- none: no walkthrough step is QA's to walk (`walk` is then empty)"
        targets -> Enum.map_join(targets, "\n", &"- Step #{&1.number}: #{String.slice(&1.text, 0, 600)}")
      end

    checks = state.job |> Map.get(:proofs, []) |> QaPreCheck.report_checks() |> Enum.map_join("\n", &"- #{&1.name}: #{&1.status}: #{&1.detail}")

    [
      "Facts Symphony has for this pass:",
      "- Playbooks: #{Enum.map_join(state.job.playbooks, ", ", & &1.kind)}",
      "- The PR's diff: `git diff origin/HEAD...HEAD` in this worktree (`origin/HEAD` is the base branch).",
      "Walkthrough steps QA walks (each needs a brief in `walk`):\n" <> walked,
      if(checks == "", do: "No step is proved by a named test.", else: "Steps a named test proves (confirmed before the pass; do not brief them):\n" <> checks),
      gallery_facts(state)
    ]
    |> Enum.join("\n")
  end

  defp gallery_facts(state) do
    case Keyword.get(state.opts, :qa_driver) && tool(state, "qa_gallery", %{}) do
      {:ok, listing} -> "The Component Gallery (`qa_gallery`; `affected` lists the entries the changed files are a reason to judge):\n" <> json(listing)
      {:error, error} -> "The Component Gallery could not be read: #{String.trim(tool_error(error))}"
      _no_driver -> ""
    end
  end

  defp screen_rules(state) do
    case Enum.find(state.job.playbooks, &(Map.get(&1, :kind) == "macos_app")) do
      %{prompt: prompt} when is_binary(prompt) -> "The playbook's rules for screens, fixtures and stand-ins (pass on what applies in each brief):\n\n" <> StepPrompts.screen_rules(prompt)
      _none -> ""
    end
  end

  defp result_line(%{step: step, outcome: outcome, detail: nil}), do: "- `#{step.id}` (#{step.title}): #{outcome}"
  defp result_line(%{step: step, outcome: outcome, detail: detail}), do: "- `#{step.id}` (#{step.title}): #{outcome}: #{String.slice(detail, 0, 1_500)}"

  defp json(value) do
    text = Jason.encode!(value, pretty: true)
    if byte_size(text) > @fact_bytes, do: String.slice(text, 0, @fact_bytes) <> "\n…", else: text
  end

  defp tail(output) when byte_size(output) > 2_000, do: "…" <> String.slice(output, -2_000, 2_000)
  defp tail(output), do: output

  # -- the result -------------------------------------------------------------------

  defp finish(%{verdict: %{verdict: :pass} = verdict} = state) do
    if nothing_on_screen?(state),
      do: {:ok, run_result(state, Map.put(verdict, :scope, :none))},
      else: {:ok, run_result(state, verdict)}
  end

  defp finish(%{verdict: %{} = verdict} = state), do: {:ok, run_result(state, verdict)}
  defp finish(%{error: error} = state) when not is_nil(error), do: {:error, error, state.tokens}

  defp finish(%{ended: reason} = state) when is_binary(reason),
    do: {:ok, run_result(state, %{verdict: :blocked, summary: "", steps: [], findings: [], reason: reason})}

  defp finish(state), do: {:error, {:malformed_qa_response, :no_verdict_object}, state.tokens}

  defp run_result(state, result), do: %{result: result, tokens: state.tokens, session_id: state.session_id}
end
