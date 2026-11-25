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

  - `symphony:qa_pre_checks`: the steps a recorded test proves (`SymphonyElixir.QaPreCheck`),
    proved as recorded, with nothing read from CI;
  - `symphony:qa_build`: `qa_build`, the app Symphony built for the commit; a build that failed
    fails the step;
  - `symphony:qa_launch`: `qa_launch_app` on the default fixtures, in the QA target's appearance,
    and `qa_resize_window` to its window size, then `qa_check_app` once the app had a moment to
    start; an app that is not healthy fails the step, and the agent steps between it
    and the quit step are skipped. It is the pass's health check of the app: each session that
    drives the app gets its own launch (below). It always runs: a pass with nothing on screen to
    judge rests on the app building, starting and checking healthy (`QaDriver.app_check/1`). When the plan answered
    `needs_app: false` and no walkthrough step is walked, the agent steps between the launch and the
    quit (the design check) are skipped, saying the plan found nothing on screen to
    judge, and the review's `pass` is a pass with `scope: none`, which `SymphonyElixir.QaVerification`
    accepts on the app check;
  - `symphony:qa_gallery`: the Component Gallery pictures the change changed
    (`QaDriver.gallery_changes/1`): the gallery of the change's app and the gallery of its base's
    app each draw every entry in one run, at the QA target, and the pictures are compared by their
    pixels. The changed and new ones are copied into `qa-evidence/`, put on the ticket's history as
    one `evidence` event, and handed to the design check's session, named in its prompt; a removed
    one is listed and not judged. A step that could not draw or compare (no build of the base, a
    gallery that failed) fails with its reason, and never hands the design check every entry. When
    no picture changed and the plan names none of the app's screens to judge (`screens`), the
    design check is skipped, saying so, and no session starts for it;
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
  steps no named test proves), as `<id>_<n>`, each with that step's text and the plan's brief for it,
  or once per group of them: the plan's briefs that name the same `group` (and the same `surface`)
  sit on one screen in one app state, and are walked in one session, as `<id>_<n>_<m>…`, with every
  step's text and brief. Such a step answers `results`, one per walkthrough step with its own
  `status`; an answer that misses one is asked once more, and a step still without one is then not
  judged (`blocked`), never passed. The review, the evidence and the step's `step.completed`
  (`results`) read one answer per walkthrough step. The groups are the plan's: Symphony expands the
  walk steps once it takes the plan, and a brief with no `group` is walked alone.
  Every agent step reads the Conductor's newest instructions
  (`SymphonyElixir.Conductor.prompt_section/2`), as the one session's prompt does, so a pass the
  Conductor sent back to QA reads what it must do differently.

  **Each session's app**: before every agent step that drives the app (a walk, a recheck, the
  design check), Symphony quits every app the pass launched and launches one for that session
  alone, so one session's leftovers never reach the next and the three-app limit is never Symphony's
  own doing. A walk step whose plan check has a `setting` (for a group, its first step's: the group
  shares one screen and state) is launched in it: `environment: live`, or `environment: fixture`
  with the fixture as `api_fixtures`; its `appearance`; its `page`, opened at launch when it names a
  page of the window or a ticket (`SymphonyElixir.QaDriver.Pages.place/1`), else said not opened;
  then `qa_resize_window` to its window size. Any other session gets the default launch at the QA
  target, and its prompt says to relaunch with its brief's `launch` when that names another state. Then `qa_check_app`, and the session's prompt names the app's PID only when the driver
  reports it running at that moment (`QaDriver.running_pids/1`), with the setting it is in; a launch
  that failed, or an app that is not running, is said with why, and no PID is given. A session in
  a setting is told that setting's window size alone, never the QA target's
  (`QaAgent.prompt_parts/3`'s `:qa_mode_in_setting`). The step prompts and the text Symphony adds
  around them take their statuses from `statuses/0` and their QA tools from
  `SymphonyElixir.QaDriver.tools/0`, built by `SymphonyElixir.QaAgent.PromptTerms`.

  **Symphony's own check of the plan** (`SymphonyElixir.QaAgent.PlanCheck`): before the plan
  session, a walked step whose plan check's setting is the live server on a pass that does not run
  it, or a fixture directory the worktree lacks, is marked `unprovable` with what it needed; once
  the plan answered, so is a step whose brief `needs` a QA tool the driver does not have, an absent
  fixture, or the live server the pass does not run. A marked step is not briefed, gets no walk
  session (a group that loses every step starts none, and a pass whose steps are all marked walks
  none), and reaches the verdict as Symphony settled it: `unprovable`, with what it needed in its
  `details` and `needs` set, whatever the review wrote for it.

  Four steps are read by their id:

  - `plan`: its `walk` must hold a brief (`step`: the walkthrough step's number) for every
    walkthrough step the pass walks, else it is refused and asked again. Its answer is recorded on its `step.completed` (`plan`,
    `SymphonyElixir.QaAgent.StepPayload`), and gives the walk steps their briefs, the design check the app's `screens` to
    judge, and the launch its `needs_app`;
  - `design_check`: the design check, given the Gallery step's changed pictures, and skipped when
    there are none and the plan names no screen of the app;
  - `review` (required in every QA playbook's list): the verdict. It records it with `qa_verdict`
    in today's contract (`SymphonyElixir.QaAgent.Verdict`), or writes it to its answer file, or asks
    for a recheck there (`{"recheck": [brief, ...]}`, at most #{3} sessions of at most #{12} briefs):
    each brief runs as a fresh turn of the list's `repeat` step, or, for the briefs that share a
    `group`, one fresh turn for them all, between the launch and the quit and attach steps run again,
    and the review runs once more. Past two rounds of recheck the pass is `inconclusive`;
  - the `repeat: walkthrough` step, whose prompt and model the rechecks take.

  The mechanical rules stay `SymphonyElixir.QaAgent`'s and `SymphonyElixir.QaVerification`'s: the
  QA target audit, the QA host and tunnel checks, each turn's timeout, the per-issue token limit
  (counted across every turn of the pass), and the cleanup of the worktree and its processes.
  """

  require Logger

  alias SymphonyElixir.{
    AgentTelemetry,
    AgentTmpDir,
    Artifacts,
    Messages,
    PhaseSteps,
    PromptSafety,
    QaAgent,
    QaDriver,
    RunStore,
    TicketEvents
  }

  alias SymphonyElixir.Conductor.Steer
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.Config.Schema.Phases.Step
  alias SymphonyElixir.PhaseSteps.Transcript
  alias SymphonyElixir.QaAgent.{PlanCheck, PromptTerms, StepPayload, StepPrompts, Verdict}
  alias SymphonyElixir.QaDriver.Pages
  alias SymphonyElixir.QaPreCheck
  alias SymphonyElixir.Walkthrough

  @plan "plan"
  @review "review"
  @launch "symphony:qa_launch"
  @quit "symphony:qa_quit"
  @attach "symphony:qa_attach"
  @gallery "symphony:qa_gallery"
  @design_check "design_check"
  @statuses ~w(pass fail blocked unprovable plan_mismatch)
  @max_rechecks 3
  @max_recheck_briefs 12
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
  @gallery_key {__MODULE__, :gallery}
  @nothing_changed "no Component Gallery picture changed and the plan names none of the app's screens to judge"
  @evidence_dir "qa-evidence"
  # Built from the step statuses and the driver's tools (`PromptTerms`), as the prompts around it are.
  @judged_rule PromptTerms.build!(
                 "lib/symphony_elixir/qa_agent/steps.ex: the judged rule",
                 "A step's answer `status` is {{status:pass}} only when every check in its brief was actually seen and judged. " <>
                   "When any part could not be reached, seen or judged (an empty state, a screenshot not viewed, a harness fault), " <>
                   "the status is {{status:blocked}} and `actual` says what blocked it: never {{status:pass}}, never {{status:fail}}. " <>
                   "When the step needs a QA tool, a fixture page or the live server this pass does not have, the status is " <>
                   "{{status:unprovable}} and `actual` says what it needed (Symphony marks the steps it can see so before any session).",
                 PromptTerms.terms(statuses: @statuses)
               )
  # The single statuses the text around the prompts names, refused at compile time when not in the list.
  @blocked_status PromptTerms.build!("lib/symphony_elixir/qa_agent/steps.ex: a step not judged", "{{status:blocked}}", PromptTerms.terms(statuses: @statuses))
  @unprovable_status PromptTerms.build!(
                       "lib/symphony_elixir/qa_agent/steps.ex: the marked steps",
                       "{{status:unprovable}}",
                       PromptTerms.terms(statuses: @statuses)
                     )

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
  The statuses a walk step's answer may give: `unprovable` (`PlanCheck.status/0`) is a step this
  pass cannot do (a QA tool, a fixture page or the live server it lacks), `blocked` one that could
  not be judged, and `plan_mismatch` the app not being where the brief says.
  """
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  What a pass of ticket `issue_id` asks at each boundary between two steps (`opts[:qa_boundary]`):
  the orchestrator `recipient` answers at once, unless an update holds dispatch for its restart,
  which then comes at this boundary (TP-1590). It answers `:ok` once the next step may begin, or
  `{:error, {:orchestrator_down, reason}}`. Nil, so the pass goes on unasked, with no orchestrator.
  """
  @spec boundary(pid() | nil, String.t() | nil) :: (map() -> :ok | {:error, term()}) | nil
  def boundary(recipient, issue_id) when is_pid(recipient) and is_binary(issue_id) do
    fn step ->
      monitor = Process.monitor(recipient)
      send(recipient, {:run_step, issue_id, {:qa_boundary, self(), step}})

      receive do
        {:run_step_turn, ^issue_id} ->
          Process.demonitor(monitor, [:flush])
          :ok

        {:DOWN, ^monitor, :process, _pid, reason} ->
          {:error, {:orchestrator_down, reason}}
      end
    end
  end

  def boundary(_recipient, _issue_id), do: nil

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
      {state, start} = restore(state)
      result = state |> walk(start) |> finish()
      forget_pass(state)
      result
    after
      Process.delete(@app_key)
      drain_verdicts(nil)
    end
  end

  defp new_state(agent_module, job, worktree, qa_settings, steps, opts) do
    tmp_dir = Keyword.fetch!(opts, :qa_tmp_dir)
    facts = pass_facts(job, worktree, opts)
    {targets, marked} = job |> walked_steps() |> PlanCheck.settings(facts)
    {expanded, checks} = expand(steps, targets, &{:alone, &1.number})

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
      |> Map.merge(for {:qa_step_runner, runner} <- opts, into: %{}, do: {:runner, runner})

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
      marked: marked,
      facts: facts,
      checks: checks,
      app_steps: app_steps(expanded),
      context: Map.put(context, :changes, PhaseSteps.changes(context)),
      results: [],
      answers: [],
      plan: nil,
      gallery: nil,
      launch: nil,
      session: nil,
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

  # The walkthrough steps this pass walks: those no recorded test proves (those are proved as recorded).
  defp walked_steps(job) do
    job |> Map.get(:journey, %{}) |> Map.get(:steps, []) |> Enum.reject(&Walkthrough.named_test?/1)
  end

  # What the pass has, for Symphony's own check of its plan (`PlanCheck`): the QA driver's tools,
  # whether its `macos_app` playbook runs the live server (and why not), and the worktree the
  # fixtures are read from.
  defp pass_facts(job, worktree, opts) do
    app = Enum.find(job.playbooks, &(Map.get(&1, :kind) == "macos_app")) || %{}

    %{
      tools: Keyword.get_lazy(opts, :qa_tools, &QaDriver.tools/0),
      live: Map.get(app, :live) == true,
      live_reason: Map.get(app, :live_reason),
      worktree: worktree
    }
  end

  # The list with its `repeat: walkthrough` step as one walk step per group of walkthrough steps
  # (`key` names each target's group), in the order of each group's first step, and what each walk
  # step checks: `%{step id => [%{target, brief}]}`.
  defp expand(steps, targets, key) do
    Enum.reduce(steps, {[], %{}}, fn
      %Step{repeat: "walkthrough"} = step, {list, checks} ->
        walks = for group <- in_groups(targets, key), do: {walk_step(step, Enum.map(group, & &1.number)), group}
        {list ++ Enum.map(walks, &elem(&1, 0)), Map.merge(checks, Map.new(walks, fn {walk, group} -> {walk.id, Enum.map(group, &%{number: &1.number, target: &1, brief: nil})} end))}

      step, {list, checks} ->
        {list ++ [step], checks}
    end)
  end

  # `items` in groups by `key`, each group in its items' order, the groups in the order of their first item.
  defp in_groups(items, key) do
    by_key = Enum.group_by(items, key)
    items |> Enum.map(key) |> Enum.uniq() |> Enum.map(&Map.fetch!(by_key, &1))
  end

  defp walk_step(step, [number]), do: repeated(step, "#{step.id}_#{number}", "#{step.title} #{number}")
  defp walk_step(step, numbers), do: grouped(repeated(step, "#{step.id}_#{Enum.join(numbers, "_")}", "#{step.title} #{Enum.join(numbers, ", ")}"))

  defp repeated(%Step{} = step, id, title), do: %Step{step | id: id, title: title, repeat: nil}

  # A walk step of several checks answers one result per check (`check_group/3`).
  defp grouped(%Step{} = step), do: %Step{step | answer: %{"results" => "list"}}

  # Once the plan is taken, the walk steps follow its groups: the briefs that share a `group` (and a
  # surface) are walked in one session; a brief with none is walked alone.
  defp regroup(%{template: nil} = state), do: state

  defp regroup(state) do
    {steps, checks} = expand(state.listed, state.targets, &plan_group(state, &1))
    checks = Map.new(checks, fn {id, walked} -> {id, Enum.map(walked, &%{&1 | brief: plan_brief(state, &1.target)})} end)
    %{state | steps: steps, context: %{state.context | steps: steps}, checks: checks, app_steps: app_steps(steps)}
  end

  # The steps whose brief `needs` what the pass lacks (`PlanCheck.briefs/3`) are marked, and leave
  # the walk: a group that loses every step starts no session.
  defp mark_briefs(state) do
    {targets, marked} = PlanCheck.briefs(state.targets, List.wrap(state.plan["walk"]), state.facts)
    %{state | targets: targets, marked: state.marked ++ marked}
  end

  defp plan_group(state, target) do
    brief = plan_brief(state, target)

    case group_name(brief) do
      nil -> {:alone, target.number}
      name -> {:group, command_line?(state, brief), name}
    end
  end

  defp group_name(%{"group" => name}) when is_integer(name), do: Integer.to_string(name)

  defp group_name(%{"group" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      name -> name
    end
  end

  defp group_name(_brief), do: nil

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

  defp walk(state, {:recheck, briefs, review}), do: state |> recheck_round(briefs) |> step_ended(review) |> walk(review)

  defp walk(state, step) do
    case run_step(state, step) do
      {state, {:recheck, briefs}} -> state |> step_ended({:recheck, briefs, step}) |> walk({:recheck, briefs, step})
      {state, outcome} -> state |> step_ended(next_step(state, step, outcome)) |> walk(next_step(state, step, outcome))
    end
  end

  # -- the step boundary ----------------------------------------------------------
  #
  # Between two steps the pass keeps where it stands (`RunStore.put_qa_pass/3`), then asks to begin
  # its next step (`opts[:qa_boundary]`, the orchestrator's answer): while an update waits for its
  # moment, a pass between steps counts as no active run, and once the update holds dispatch its next
  # step waits, so Symphony restarts at that boundary rather than after the rest of the pass
  # (TP-1590). A recheck round (the launch again, the rechecks, the quit and the evidence) is one
  # piece: the boundary comes before it and after it.
  defp step_ended(state, next) do
    if goes_on?(state, next) do
      keep_pass(state, next)
      await_boundary(state, next)
    end

    state
  end

  defp goes_on?(%{verdict: nil, error: nil}, %Step{}), do: true
  defp goes_on?(%{verdict: nil, error: nil}, {:recheck, _briefs, _review}), do: true
  defp goes_on?(_state, _next), do: false

  defp await_boundary(state, next) do
    case Keyword.get(state.opts, :qa_boundary) do
      boundary when is_function(boundary, 1) -> boundary.(boundary_step(next))
      nil -> :ok
    end
  end

  defp boundary_step({:recheck, _briefs, review}), do: boundary_step(review)
  defp boundary_step(%Step{} = step), do: %{id: step.id, title: step.title, mode: step.mode}

  # What a pass that goes on after a restart needs: its list as walked so far (rechecks included),
  # the step it goes on at, and each finished step's result, answer and session.
  defp keep_pass(state, next) do
    {next_id, recheck} =
      case next do
        {:recheck, briefs, review} -> {review.id, briefs}
        %Step{id: id} -> {id, nil}
      end

    pass = %{
      run_id: Map.get(state.job, :run_id),
      sha: Map.get(state.job, :sha),
      listed: Enum.map(state.listed, & &1.id),
      next: next_id,
      recheck: recheck,
      steps: state.steps,
      results: state.results,
      answers: state.answers,
      plan: state.plan,
      gallery: state.gallery,
      targets: state.targets,
      marked: state.marked,
      checks: state.checks,
      app_steps: state.app_steps,
      sessions: state.sessions,
      tokens: state.tokens,
      rounds: state.rounds,
      launched: match?({:launched, _app}, state.launch),
      launch: if(match?({:failed, _output}, state.launch), do: state.launch)
    }

    keep_evidence(state)

    case RunStore.put_qa_pass(state.context.repo_key, state.context.issue_id, pass) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("QA pass of #{state.job.issue.identifier} could not keep where it stands: #{inspect(reason)}")
    end
  end

  defp forget_pass(state) do
    File.rm_rf(kept_evidence_dir(state))
    RunStore.delete_qa_pass(state.context.repo_key, state.context.issue_id)
  end

  # The evidence the finished steps wrote under `qa-evidence/` is kept beside the worktree, which the
  # next pass makes again from scratch, and is put back when the pass goes on after a restart.
  defp kept_evidence_dir(state), do: state.worktree <> ".kept-evidence"

  defp keep_evidence(state) do
    copy_evidence(Path.join(state.worktree, @evidence_dir), kept_evidence_dir(state))
  end

  defp put_back_evidence(state) do
    copy_evidence(kept_evidence_dir(state), Path.join(state.worktree, @evidence_dir))
  end

  defp copy_evidence(from, to) do
    for file <- Path.wildcard(Path.join(from, "**"), match_dot: false), File.regular?(file) do
      target = Path.join(to, Path.relative_to(file, from))

      if not File.exists?(target) or File.stat!(target).size != File.stat!(file).size do
        File.mkdir_p!(Path.dirname(target))
        File.cp!(file, target)
      end
    end

    :ok
  end

  # A pass whose last run Symphony's restart stopped (`RunStore.restart_interrupted?/1`), on the same
  # commit and list, goes on at the step after the last one that ended, with the results of the
  # steps already done; the step the restart stopped mid-step runs again, and no step that ended does.
  # The app the earlier run launched is gone with its QA session, so the build and launch steps run
  # again first when the next step drives the app. Anything else starts the list from the top.
  defp restore(state) do
    with %{} = pass <- RunStore.get_qa_pass(state.context.repo_key, state.context.issue_id),
         true <- pass.sha == Map.get(state.job, :sha) and pass.listed == Enum.map(state.listed, & &1.id),
         true <- restart_interrupted?(state, pass.run_id),
         %Step{} = next <- Enum.find(pass.steps, &(&1.id == pass.next)) do
      Logger.info("QA pass of #{state.job.issue.identifier} goes on at step #{next.id} after Symphony's restart")
      state = restored(state, pass)
      put_back_evidence(state)
      state = if pass.launched and (pass.recheck != nil or MapSet.member?(state.app_steps, next.id) or runs?(next, @gallery)), do: relaunch(state), else: state
      {state, if(pass.recheck, do: {:recheck, pass.recheck, next}, else: next)}
    else
      _none ->
        forget_pass(state)
        {state, List.first(state.steps)}
    end
  end

  defp restart_interrupted?(state, run_id) do
    runs = RunStore.list_issue_runs(state.context.repo_key, state.context.issue_id)
    is_list(runs) and Enum.any?(runs, &(Map.get(&1, :run_id) == run_id and RunStore.restart_interrupted?(&1)))
  end

  defp restored(state, pass) do
    %{
      state
      | steps: pass.steps,
        context: %{state.context | steps: pass.steps},
        results: pass.results,
        answers: pass.answers,
        plan: pass.plan,
        gallery: Map.get(pass, :gallery),
        targets: Map.get(pass, :targets, state.targets),
        marked: Map.get(pass, :marked, state.marked),
        checks: pass.checks,
        app_steps: pass.app_steps,
        sessions: pass.sessions,
        tokens: pass.tokens,
        rounds: pass.rounds,
        launch: pass.launch
    }
  end

  # The app is launched again, on a QA session that may be new: the build and the launch steps run
  # again. That prepares the app; it walks no step.
  defp relaunch(state) do
    state.listed
    |> Enum.filter(&(runs?(&1, "symphony:qa_build") or runs?(&1, @launch)))
    |> Enum.reduce(state, fn step, state -> state |> run_step(step) |> elem(0) end)
  end

  defp next_step(state, step, outcome) do
    case PhaseSteps.next(state.steps, step, outcome) do
      {:ok, next} -> next
      :end -> nil
    end
  end

  # The Gallery step draws nothing for a pass with nothing on screen to judge.
  defp run_step(state, %Step{mode: "machine"} = step) do
    if runs?(step, @gallery) and nothing_on_screen?(state),
      do: skipped(state, step, @nothing_on_screen),
      else: machine(state, step, 1)
  end

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
      runs?(step, @gallery) -> %{state | gallery: Process.delete(@gallery_key)}
      true -> state
    end
  end

  defp forget_app(state) do
    Process.delete(@app_key)
    %{state | session: nil}
  end

  # Nothing on screen to judge: the plan needs no app and no walkthrough step is walked. The launch
  # still runs, since such a pass rests on the app building, starting and checking healthy.
  defp nothing_on_screen?(%{plan: %{"needs_app" => false}, targets: [], marked: []}), do: true
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
      @gallery => fn _context -> gallery(state) end,
      @quit => fn _context -> quit(state) end,
      @attach => fn _context -> attach(state) end
    }
  end

  defp pre_checks(state) do
    case state.job |> Map.get(:proofs, []) |> QaPreCheck.report_checks() do
      [] -> {:ok, {"No walkthrough step is proved by a recorded test: QA walks every step.\n", 0}}
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

  # The app the walk's steps drive, on the default fixtures, in the QA target's appearance (the
  # driver's default) and sized to its window, checked once it had a moment to start.
  defp launch(state) do
    with {:ok, %{"pid" => pid} = launched} <- tool(state, "qa_launch_app", %{}),
         :ok <- Process.sleep(Keyword.get(state.opts, :qa_launch_settle_ms, @launch_settle_ms)),
         {:ok, resized} <- tool(state, "qa_resize_window", %{"pid" => pid}),
         {:ok, health} <- tool(state, "qa_check_app", %{"pid" => pid, "page" => "launch"}) do
      Process.put(@app_key, Map.take(launched, ["pid", "root", "environment"]))
      output = "Launched: #{Jason.encode!(launched)}\nqa_resize_window: #{Jason.encode!(resized)}\nqa_check_app: #{Jason.encode!(health)}\n"
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

  # The Gallery pictures the change changed, drawn and compared by the driver with no agent, and
  # put on the ticket's history; the design check's session gets their paths.
  defp gallery(state) do
    Process.delete(@gallery_key)

    case driver_module(state).gallery_changes(Keyword.get(state.opts, :qa_driver)) do
      {:ok, changes} ->
        Process.put(@gallery_key, changes)
        {:ok, {gallery_output(changes) <> record_pictures(state, changes), 0}}

      {:error, error} ->
        {:ok, {tool_error(error), 1}}
    end
  end

  defp gallery_output(changes) do
    names = fn key -> Map.get(changes, key, []) end

    "Compared the Component Gallery of this change with its base's (commit #{String.slice(to_string(changes["base"]), 0, 12)}), " <>
      "drawn at the QA target (#{changes["appearance"]}, #{changes["width"]} pt): #{length(names.("changed"))} changed, " <>
      "#{length(names.("new"))} new, #{length(names.("removed"))} removed, #{length(names.("same"))} the same.\n" <>
      Enum.map_join(names.("files"), "", &"- #{&1}\n") <>
      if(names.("removed") == [], do: "", else: "Removed, not judged:\n" <> Enum.map_join(names.("removed"), "", &"- #{&1}\n"))
  end

  # One `evidence` event holds the pictures to judge, as a `qa_gallery` call's does.
  defp record_pictures(_state, %{"files" => []}), do: ""

  defp record_pictures(state, %{"files" => files} = changes) do
    context = state.context

    meta =
      &%{
        repo_key: context.repo_key,
        issue_id: context.issue_id,
        run_id: context.run_id,
        kind: "screenshot",
        label: Path.basename(&1)
      }

    ids =
      for path <- files, {:ok, %{id: id}} <- [Artifacts.ingest(Path.join(state.worktree, path), meta.(path), roots: [state.worktree])], do: id

    caption =
      "Gallery pictures the change changed (#{length(changes["changed"])}) or added (#{length(changes["new"])}), " <>
        "drawn by Symphony at the QA target, for the design check"

    case TicketEvents.record(context.repo_key, context.issue_id, "evidence", %{caption: caption}, run_id: context.run_id, artifacts: ids) do
      {:ok, _event} when length(ids) == length(files) -> ""
      {:ok, _event} -> "#{length(files) - length(ids)} of the pictures could not be kept on the ticket's history; they are in #{@evidence_dir}/.\n"
      {:error, reason} -> "The pictures could not be put on the ticket's history (#{inspect(reason)}); they are in #{@evidence_dir}/.\n"
    end
  end

  # -- each session's app ---------------------------------------------------------

  # A session that drives the app gets one of its own, launched in its step's setting; any other
  # session drives none.
  defp session_app(state, step) do
    if MapSet.member?(state.app_steps, step.id) and not command_line?(state, walk_brief(state, step)) do
      quit_apps(state)
      %{state | session: launch_session(state, session_setting(state, step))}
    else
      %{state | session: nil}
    end
  end

  # The step's setting, from its plan check; a group's is its first step's.
  defp session_setting(state, step) do
    case Map.get(state.checks, step.id) do
      [%{target: %{setting: %{} = setting}} | _] -> setting
      _none -> nil
    end
  end

  defp quit_apps(state) do
    for pid <- driver_module(state).launched_pids(Keyword.get(state.opts, :qa_driver)), do: tool(state, "qa_quit_app", %{"pid" => pid})
  end

  defp launch_session(state, setting) do
    {args, page} = launch_args(setting)

    with {:ok, %{"pid" => pid} = launched} <- tool(state, "qa_launch_app", args),
         :ok <- Process.sleep(Keyword.get(state.opts, :qa_launch_settle_ms, @launch_settle_ms)),
         {:ok, _resized} <- tool(state, "qa_resize_window", resize_args(pid, setting)),
         {:ok, health} <- tool(state, "qa_check_app", %{"pid" => pid, "page" => "launch"}),
         :ok <- running(state, pid, health) do
      {:launched, %{pid: pid, root: Map.get(launched, "root", 1), setting: setting, page: page, health: health}}
    else
      {:error, error} -> {:failed, String.trim(tool_error(error))}
    end
  end

  # `qa_launch_app`'s arguments for a setting, and where its page opens the app.
  defp launch_args(nil), do: {%{}, nil}

  defp launch_args(%{} = setting) do
    page = Pages.place(Map.get(setting, :page))

    args =
      case setting do
        %{source: "live"} -> %{"environment" => "live"}
        %{source: "fixture", fixture: fixture} -> %{"environment" => "fixture", "api_fixtures" => fixture}
      end
      |> Map.put("appearance", setting.appearance)
      |> Map.merge(page_args(page))

    {args, page}
  end

  defp page_args({:page, %{name: name}}), do: %{"page" => name}
  defp page_args({:ticket, identifier}), do: %{"ticket" => identifier}
  defp page_args(:unknown), do: %{}

  defp resize_args(pid, %{window: %{width: width, height: height}}), do: %{"pid" => pid, "width" => width, "height" => height}
  defp resize_args(pid, nil), do: %{"pid" => pid}

  # Only an app the driver reports running at this moment is handed to the session.
  defp running(state, pid, health) do
    if pid in driver_module(state).running_pids(Keyword.get(state.opts, :qa_driver)) do
      :ok
    else
      problems = health |> Map.get("problems", []) |> List.wrap() |> Enum.map_join("; ", &to_string/1)
      {:error, {:qa_tool, "qa_app_not_running", "the app it launched (PID #{pid}) is not running#{if problems == "", do: "", else: ": " <> problems}"}}
    end
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
        state |> session_app(step) |> start_agent_step(step)

      reason ->
        skipped(state, step, reason)
    end
  end

  defp skipped(state, step, reason) do
    PhaseSteps.record_turn_completed(step, state.context, %{outcome: "skipped", reason: reason}, 0)
    {add_result(state, step, "skipped", reason), :passed}
  end

  # The steps that drive the app run only on an app that launched, and the listed ones only when
  # there is something on screen to judge; a recheck the review asked for runs whatever the plan said.
  defp agent_skip(state, step) do
    cond do
      not MapSet.member?(state.app_steps, step.id) -> nil
      command_line?(state, walk_brief(state, step)) -> nil
      not match?({:launched, _app}, state.launch) -> "the app did not launch"
      state.rounds == 0 and nothing_on_screen?(state) -> @nothing_on_screen
      step.id == @design_check and nothing_changed?(state) -> @nothing_changed
      true -> nil
    end
  end

  # The Gallery step found no picture to judge, and the plan names no screen of the app.
  defp nothing_changed?(%{gallery: %{"files" => []}, plan: plan}), do: List.wrap(Map.get(plan || %{}, "screens")) == []
  defp nothing_changed?(_state), do: false

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

  # A group's answer that misses a check, or gives one a status Symphony does not take, is asked
  # once more; the second time the others keep their results and that check is not judged (`blocked`).
  defp after_turn({:partial, _answer, why}, state, step, run, notes, 1), do: after_turn({:error, why}, state, step, run, notes, 1)

  defp after_turn({:partial, answer, why}, state, step, run, _notes, _attempt) do
    Logger.info("QA step #{step.id} of #{state.job.issue.identifier} answered its group in part (#{why}); the checks with no result are blocked")
    passed(state, step, run, answer)
  end

  defp after_turn({:error, why}, state, step, run, notes, 1) do
    Logger.info("QA step #{step.id} of #{state.job.issue.identifier} answered nothing Symphony takes (#{why}); asking once more")
    turn(state, step, run, retry_notes(step, notes, why), 2)
  end

  defp after_turn({:error, why}, state, step, run, _notes, _attempt), do: failed(state, step, run, why)

  defp retry_notes(%Step{mode: "delegated"}, notes, _why), do: Map.put(notes, :reminder, true)
  defp retry_notes(_step, notes, why), do: Map.put(notes, :answer_error, why)

  defp passed(state, step, run, answer) do
    state = %{state | answers: state.answers ++ answer_entries(state, step, answer)}
    state = if step.id == @plan, do: state |> Map.put(:plan, answer) |> mark_briefs() |> regroup(), else: state
    PhaseSteps.record_turn_completed(step, step_context(state, run), answer_fields(state, step, answer), duration(run))
    {add_result(state, step, "passed", group_detail(state, step, answer)), :passed}
  end

  # What the review reads of an answer: a group's is one answer per check, named after its step.
  defp answer_entries(state, step, answer) do
    if group?(state, step),
      do: for(result <- answer["results"], do: {%{step | title: "walkthrough step #{result["step"]}"}, result}),
      else: [{step, answer}]
  end

  defp group_detail(state, step, answer) do
    if group?(state, step),
      do: Enum.map_join(answer["results"], "; ", &"walkthrough step #{&1["step"]}: #{&1["status"]}"),
      else: nil
  end

  defp group?(state, step), do: match?([_, _ | _], Map.get(state.checks, step.id))

  # The step's answer rides on its own `step.completed` (`SymphonyElixir.QaAgent.StepPayload`), where
  # the Director reads it as fields, never as a note.
  defp answer_fields(state, %Step{id: @plan}, answer), do: %{outcome: "passed", plan: StepPayload.plan(answer, plan_skips(state))}

  defp answer_fields(state, step, answer) do
    if group?(state, step),
      do: %{outcome: "passed", results: StepPayload.results(answer["results"])},
      else: single_fields(answer)
  end

  defp single_fields(answer) do
    case StepPayload.result(answer) do
      nil -> %{outcome: "passed"}
      result -> %{outcome: "passed", result: result}
    end
  end

  # The steps a plan that finds nothing on screen leaves unrun, and the walked steps Symphony marked.
  defp plan_skips(state) do
    marked = for %{target: target, needs: needs} <- state.marked, do: %{title: PlanCheck.step_name(target), why: PlanCheck.details(needs)}

    if nothing_on_screen?(state),
      do: for(step <- state.steps, MapSet.member?(state.app_steps, step.id), do: %{title: step.title, why: @nothing_on_screen}),
      else: marked
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

  # One round of recheck: the launch again, a fresh turn of the list's `repeat` step per session
  # (the briefs that share a `group`, or one brief alone), the quit and the evidence, then the review
  # again (`walk/2`).
  defp recheck_round(state, briefs) do
    round = state.rounds + 1

    sessions =
      for {group, index} <- state |> recheck_sessions(briefs) |> Enum.with_index(1) do
        check = %Step{repeated(state.template, "recheck_#{round}_#{index}", "Recheck #{round}.#{index}") | session: Step.fresh_session(), on_fail: nil}
        {if(match?([_, _ | _], group), do: grouped(check), else: check), Enum.map(group, &%{number: brief_number(&1), target: brief_target(state, &1), brief: &1})}
      end

    rechecks = Enum.map(sessions, &elem(&1, 0))
    launches = Enum.filter(state.listed, &runs?(&1, @launch))
    after_checks = Enum.filter(state.listed, &(runs?(&1, @quit) or runs?(&1, @attach)))
    app_steps = if launches == [], do: state.app_steps, else: Enum.reduce(rechecks, state.app_steps, &MapSet.put(&2, &1.id))

    state = %{
      state
      | rounds: round,
        steps: state.steps ++ rechecks,
        context: %{state.context | steps: state.steps ++ rechecks},
        checks: Map.merge(state.checks, Map.new(sessions, fn {check, walked} -> {check.id, walked} end)),
        app_steps: app_steps
    }

    Enum.reduce(launches ++ rechecks ++ after_checks, state, fn step, state -> state |> run_step(step) |> elem(0) end)
  end

  # The recheck briefs by session: a brief that names a walkthrough step this pass walks and a
  # `group` is rechecked with the others of its group (on the same surface); any other is rechecked
  # alone.
  defp recheck_sessions(state, briefs) do
    briefs
    |> Enum.with_index()
    |> in_groups(fn {brief, index} ->
      case {brief_number(brief), group_name(brief)} do
        {number, name} when is_binary(name) and is_integer(number) -> recheck_group(state, brief, number, name, index)
        _alone -> {:alone, index}
      end
    end)
    |> Enum.map(fn group -> Enum.map(group, &elem(&1, 0)) end)
  end

  defp recheck_group(state, brief, number, name, index) do
    if Enum.any?(state.targets, &(&1.number == number)),
      do: {:group, command_line?(state, brief), name},
      else: {:alone, index}
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

  # At most `@max_rechecks` sessions: the briefs that share a `group` are one session. A brief
  # whose `step` is one Symphony marked is refused: a marked step gets no session, a recheck's either.
  defp check_recheck(state, briefs) do
    with true <- is_list(briefs) and briefs != [] and length(briefs) <= @max_recheck_briefs and Enum.all?(briefs, &is_map/1),
         true <- length(recheck_sessions(state, briefs)) <= @max_rechecks,
         [] <- marked_briefs(state, briefs) do
      {:recheck, briefs}
    else
      false ->
        {:error, "`recheck` must be a list of one to #{@max_recheck_briefs} briefs, each an object, in at most #{@max_rechecks} sessions (the briefs that share a `group` are one session)"}

      marked ->
        {:error,
         "`recheck` names steps Symphony marked #{@unprovable_status} before any walk session, which get no session: " <>
           Enum.map_join(marked, "; ", &"#{PlanCheck.step_name(&1.target)} (#{PlanCheck.details(&1.needs)})") <>
           ". Leave them out of the recheck; the verdict carries them as Symphony settled them"}
    end
  end

  defp marked_briefs(state, briefs) do
    numbers = briefs |> Enum.map(&brief_number/1) |> MapSet.new()
    Enum.filter(state.marked, &MapSet.member?(numbers, &1.number))
  end

  # The plan must brief every walkthrough step the pass walks; a judged step names its status.
  defp check(state, %Step{id: @plan}, answer) do
    briefed = for brief <- List.wrap(answer["walk"]), number = brief_number(brief), into: MapSet.new(), do: number

    with [] <- Enum.reject(state.targets, &MapSet.member?(briefed, &1.number)),
         :ok <- needs_shapes(answer["walk"]) do
      {:ok, answer}
    else
      [_ | _] = missing -> {:error, "the plan's `walk` has no brief for walkthrough step #{Enum.map_join(missing, ", ", & &1.number)}, which QA walks"}
      {:error, why} -> {:error, why}
    end
  end

  defp check(state, step, answer) do
    case Map.get(state.checks, step.id) do
      [_, _ | _] = walked -> check_group(Enum.map(walked, & &1.number), answer)
      _one -> check_one(answer)
    end
  end

  # Each brief's `needs` in the fixed shape (`PlanCheck.needs_shape/1`), else the plan is asked again.
  defp needs_shapes(walk) do
    Enum.find_value(List.wrap(walk), :ok, fn brief ->
      case is_map(brief) && PlanCheck.needs_shape(brief) do
        {:error, _why} = error -> error
        _ok -> nil
      end
    end)
  end

  defp check_one(%{"status" => status} = answer) do
    if status in @statuses,
      do: {:ok, answer},
      else: {:error, "`status` must be one of #{Enum.join(@statuses, ", ")}"}
  end

  defp check_one(answer), do: {:ok, answer}

  # A group's answer holds one result per check, each with a status Symphony takes. A check with no
  # such result is asked again, then counts as not judged (`blocked`), never as passed.
  defp check_group(numbers, %{"results" => results} = answer) do
    # The first result of each check counts.
    given =
      for %{} = result <- Enum.reverse(results), number = brief_number(result), number in numbers, into: %{} do
        {number, result}
      end

    judged =
      for {number, %{"status" => status} = result} <- given, status in @statuses, into: %{} do
        {number, Map.put(result, "step", number)}
      end

    unjudged = Enum.reject(numbers, &Map.has_key?(judged, &1))
    answer = Map.put(answer, "results", Enum.map(numbers, &Map.get_lazy(judged, &1, fn -> not_judged(&1) end)))

    case unjudged do
      [] ->
        {:ok, answer}

      missing ->
        {:partial, answer,
         "`results` has no result with a `status` of #{Enum.join(@statuses, ", ")} for walkthrough step #{Enum.join(missing, ", ")} of this group: " <>
           "give one result per step, each with its `step`"}
    end
  end

  defp not_judged(number) do
    %{
      "step" => number,
      "status" => "blocked",
      "expected" => "a result for walkthrough step #{number}",
      "actual" => "the walk gave no result Symphony takes for this step, so it was not judged",
      "details" => "",
      "evidence" => []
    }
  end

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
    with true <- Map.has_key?(state.checks, step.id),
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
      QaAgent.prompt_parts(state.job, parent(state), [:issue, :design, :servers, :qa_mode, :unprovable]),
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
      marked_facts(state.marked, :review),
      "Write a recheck, or the verdict when `qa_verdict` is not available, to `#{answer_path(state, %Step{id: @review})}`."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp context_for(state, step) do
    case Map.get(state.checks, step.id) do
      [_, _ | _] = walked -> group_context(state, walked)
      [walked] -> walk_context(state, walked)
      nil -> check_context(state)
    end
  end

  defp walk_context(state, %{target: target, brief: brief}) do
    [
      target_text(target),
      if(brief, do: "Your brief, from the lead QA agent:\n" <> json(brief), else: "The plan gave no brief for this step: walk it from its text and the ticket."),
      surface_lines(state, brief)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # Several checks that share a screen and an app state, walked in one session: each step's text and
  # brief, and the answer that holds one result per check.
  defp group_context(state, walked) do
    numbers = Enum.map_join(walked, ", ", & &1.number)

    [
      "You walk #{length(walked)} walkthrough steps in this one session (steps #{numbers}): the lead QA agent grouped them because they share a " <>
        "screen and an app state. Reach the place once, then judge each step in turn, with its own screenshots and its own `evidence` " <>
        "events, each naming its step.",
      Enum.map_join(walked, "\n\n", &target_text(&1.target)),
      "Your briefs, from the lead QA agent, one per step:\n" <> json(Enum.map(walked, & &1.brief)),
      surface_lines(state, hd(walked).brief),
      "Answer with `results`: one object per step above, each with `step` (its number), `status`, `expected`, `actual`, `details` and " <>
        "`evidence`, judged on its own: one step's failure never changes another's status. Symphony refuses an answer that misses a step or " <>
        "gives one a status other than #{PromptTerms.status_list(@statuses)}, and asks once more; a step still without a result is then not judged " <>
        "(#{@blocked_status}), never passed."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp surface_lines(state, brief) do
    [
      if(command_line?(state, brief), do: command_line_rules(state), else: app_line(state)),
      QaAgent.prompt_parts(state.job, nil, [:servers, qa_mode_part(state), :conductor])
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # A session Symphony launched in its step's setting is told that setting's window size alone (its
  # app line), never the QA target's.
  defp qa_mode_part(%{session: {:launched, %{setting: %{}}}}), do: :qa_mode_in_setting
  defp qa_mode_part(_state), do: :qa_mode

  defp walk_brief(state, step) do
    case Map.get(state.checks, step.id) do
      [%{brief: brief} | _] -> brief
      _none -> nil
    end
  end

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

  defp target_text(%{check_id: check_id} = target) do
    "The check you walk (check #{check_id} of the ticket's plan):\n" <>
      PromptSafety.linear_block(target.text, "walkthrough_step", @fact_bytes)
  end

  defp target_text(target) do
    "The walkthrough step you walk (step #{target.number} of the ticket's `## User walkthrough`):\n" <>
      PromptSafety.linear_block(target.text, "walkthrough_step", @fact_bytes)
  end

  defp plan_brief(%{plan: plan}, target), do: Enum.find(List.wrap(plan["walk"]), &(brief_number(&1) == target.number))

  defp check_context(state) do
    plan = state.plan || %{}

    [
      app_line(state),
      "The app's screens the plan names (windows, sheets, panels and menus to judge in the running app):\n" <> json(Map.get(plan, "screens", [])),
      gallery_pictures(state.gallery),
      "The plan's briefs, for the screens and fixtures to use:\n" <> json(Map.get(plan, "walk", [])),
      QaAgent.prompt_parts(state.job, parent(state), [:design, :servers, :qa_mode, :conductor])
    ]
    |> Enum.join("\n\n")
  end

  defp gallery_pictures(%{"files" => [_ | _] = files} = changes) do
    "The Component Gallery pictures the change changed or added, drawn by Symphony at the QA target from the change's app and " <>
      "compared with its base's (#{length(changes["changed"])} changed, #{length(changes["new"])} new, #{length(changes["same"])} the same): " <>
      "judge each of these files, and no other entry:\n" <> Enum.map_join(files, "\n", &"- #{&1}") <> removed_pictures(changes)
  end

  defp gallery_pictures(%{} = changes) do
    "The Component Gallery: Symphony drew every entry from the change's app and from its base's, at the QA target, and no picture " <>
      "changed (#{length(changes["same"])} the same): there is no Gallery picture to judge." <> removed_pictures(changes)
  end

  defp gallery_pictures(nil), do: "The Component Gallery: this pass's list draws no Gallery pictures for you; judge the app's screens alone."

  defp removed_pictures(%{"removed" => [_ | _] = removed}), do: "\nRemoved by the change, not judged: " <> Enum.join(removed, ", ")
  defp removed_pictures(_changes), do: ""

  defp app_line(%{session: {:launched, %{pid: pid, root: root} = app}}) do
    "The app: Symphony launched it for this session as PID #{pid} (QA root #{root}), running now, #{where_text(app)} " <>
      health_text(app.health) <> relaunch_text(app)
  end

  defp app_line(%{session: {:failed, why}}) do
    "The app: Symphony could not launch it for this session (#{why}), so no app is running for you. Launch it with `qa_launch_app` " <>
      "in the step's setting, with its page as `page`, when the step needs it."
  end

  defp app_line(_state), do: "The app: Symphony has not launched it for this step; launch it with `qa_launch_app` when the step needs it."

  defp where_text(%{setting: nil}) do
    "on the default fixtures, at the QA target: its appearance, with its window sized to the target. The plan gives this step no setting, " <>
      "so Symphony launched it as it launches by default."
  end

  defp where_text(%{setting: %{window: %{width: width, height: height}} = setting, page: page}) do
    "in this step's setting: #{source_text(setting)}, #{page_text(page, setting.page)}, #{setting.appearance} appearance, " <>
      "its window at #{width}×#{height} pt."
  end

  # A session with no setting from the plan reaches its state from its brief, as before; a session
  # in a setting uses the app as it is.
  defp relaunch_text(%{setting: nil}) do
    "When your brief's `launch` (in the design check, the briefs' fixtures and stand-ins) names another state " <>
      "(`api_fixtures`, `environment`, a page, an appearance, a window size or stand-ins), quit it with `qa_quit_app`, call " <>
      "`qa_launch_app` with those arguments and the page as `page`, then `qa_resize_window` (with the brief's size, or no size for the target). " <>
      "Otherwise use it as it is and open the page the step needs."
  end

  defp relaunch_text(_app) do
    "Use it as it is: do not quit and relaunch it to reach this setting. Relaunch only for what the setting does not state " <>
      "(a stand-in port, `fresh_root`, another appearance or size in `also`), and then pass the page to `qa_launch_app` as `page`."
  end

  defp source_text(%{source: "live"}), do: "on the live server (`environment: live`)"
  defp source_text(%{source: "fixture", fixture: fixture}), do: "on the fixture `#{fixture}`"

  defp page_text({:page, %{title: title}}, _page), do: "open on its #{title} page"
  defp page_text({:ticket, identifier}, _page), do: "open on #{identifier}'s page"

  defp page_text(:unknown, page),
    do: "on its first page: the setting's page (#{inspect(page)}) is not one Symphony can open at launch, so navigate there yourself"

  defp health_text(%{"healthy" => true}), do: ""
  defp health_text(health), do: "`qa_check_app` found it unhealthy at launch: #{Jason.encode!(health)}. "

  defp plan_facts(state) do
    walked =
      case state.targets do
        [] -> "- none: no walkthrough step is QA's to walk (`walk` is then empty)"
        targets -> Enum.map_join(targets, "\n", &"- Step #{&1.number}: #{String.slice(&1.text, 0, 600)}\n  #{setting_fact(&1)}")
      end

    checks = state.job |> Map.get(:proofs, []) |> QaPreCheck.report_checks() |> Enum.map_join("\n", &"- #{&1.name}: #{&1.status}: #{&1.detail}")

    [
      "Facts Symphony has for this pass:",
      "- Playbooks: #{Enum.map_join(state.job.playbooks, ", ", & &1.kind)}",
      "- The PR's diff: `git diff origin/HEAD...HEAD` in this worktree (`origin/HEAD` is the base branch).",
      "Walkthrough steps QA walks (each needs a brief in `walk`):\n" <> walked,
      marked_facts(state.marked, :plan),
      pass_tools(state.facts),
      if(checks == "", do: "No step is proved by a named test.", else: "Steps a recorded test proves (proved, do not brief them):\n" <> checks),
      "- The Component Gallery: Symphony draws it from the change's app and from its base's, and hands the design check the pictures that changed. Name no gallery entry."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # The steps Symphony marked before this session: the plan briefs none of them, and the review
  # carries each as given.
  defp marked_facts([], _turn), do: ""

  defp marked_facts(marked, turn) do
    lead =
      case turn do
        :plan ->
          "Steps Symphony marked #{@unprovable_status} before this session, from their setting (no brief, no walk):"

        :review ->
          "Steps Symphony marked #{@unprovable_status} before any walk session (no session walked them); carry each in the verdict " <>
            "as given, name, status and details, write no other step for the same walkthrough step, and ask no recheck of one:"
      end

    lead <> "\n" <> Enum.map_join(marked, "\n", &"- #{PlanCheck.step_name(&1.target)}: #{PlanCheck.details(&1.needs)}")
  end

  # What the plan checks each brief's `needs` against, and what Symphony checks them against itself.
  defp pass_tools(facts) do
    "- The live server: #{if facts.live, do: "this pass runs it", else: "this pass does not run it"}.\n" <>
      "- The QA driver's tools: #{Enum.join(facts.tools, ", ")}."
  end

  # Where the plan walks a step (its check's `setting`, in the fixed shape the Conductor's answer
  # validates), given as facts the plan's briefs use as they are.
  defp setting_fact(%{setting: %{source: _source, page: page, window: %{width: width, height: height}, appearance: appearance} = setting}) do
    "Setting (from the plan; use it as given): " <>
      Enum.join([source_fact(setting), "page: #{page}", "window: #{width}×#{height}", "appearance: #{appearance}"], "; ")
  end

  defp setting_fact(_step), do: "Setting: none in the plan; work out where and how to launch, on fixtures."

  defp source_fact(%{source: "live"}), do: "source: live (the live server, `environment: live`)"
  defp source_fact(%{source: "fixture", fixture: fixture}), do: "source: fixture `#{fixture}` (`environment: fixture`, `api_fixtures: #{fixture}`)"

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

  defp run_result(state, result), do: %{result: with_marked(result, state.marked), tokens: state.tokens, session_id: state.session_id}

  # The steps Symphony marked are in the verdict once, as it settled them: whatever the review wrote
  # for the same walkthrough step, under Symphony's name or its own, is dropped.
  defp with_marked(result, []), do: result

  defp with_marked(result, marked) do
    targets = Enum.map(marked, & &1.target)
    review_steps = Enum.reject(Map.get(result, :steps, []), &marked_name?(Map.get(&1, :name), targets))
    Map.put(result, :steps, review_steps ++ Enum.map(marked, &PlanCheck.verdict_step/1))
  end

  defp marked_name?(name, targets), do: Enum.any?(targets, &PlanCheck.names_step?(name, &1))
end
