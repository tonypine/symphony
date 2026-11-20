defmodule SymphonyElixir.PhaseSteps.WindowTests do
  @moduledoc """
  The Window tests step of an implementation or rework run (TP-1554): Symphony's own machine step
  command (`SymphonyElixir.Config.Schema.Phases.window_tests_command/0`) that runs, in the QA VM, the
  tests that drive an app's window, which no run can launch on Symphony's host.

  Which tests exist, and which paths each covers, is declared in one place: the manifest beside the
  scripts (`manifest_path/0`), never inferred from file names. Each entry names its `script`, what
  it tests in plain words (`title`, which the Inbox shows), the shell line that runs it from `macos/` (`run`, as the Mac CI build runs it), the paths it covers
  (`covers`, globs where `**` spans folders) and, optionally, why it is `off` in the QA VM: an entry
  that does not pass on main there is never run. The step runs (`selected/1`) every entry whose
  script or covered path the change touches, every entry when the manifest itself changed, and is
  skipped with the reason when no entry covers the change (`skip_reason/1`). An entry that is off
  and covers the change (its script or a covered path) is never skipped quietly: the step ends could not run, naming it
  (`off_covering/1`). `SymphonyElixir.PhaseSteps.changes/1`
  reads the manifest with the changed files.

  A run of the step (`run/2`):

  1. builds the workspace's `HEAD` with the QA build (`SymphonyElixir.QaBuild.fetch/4`: the host
     command a QA pass's build uses, cached by tree, so the QA pass of the same head reuses it);
  2. takes the QA VM (`SymphonyElixir.QaDriver.DevServerLease`, key `{worker_host, :desktop}`, which
     every `macos_app` QA pass holds for its whole pass), waiting while a QA pass holds it and
     saying so on the ticket's timeline, with the ticket that holds it;
  3. copies `HEAD` into a run directory of its own on the QA VM (`SymphonyElixir.QaDriver.SafeHost`
     checks the host first) and runs each selected script there, from `macos/`, with the Mac CI
     build's environment: the pinned Xcode as `DEVELOPER_DIR` (the VM's selected Xcode, said in the
     output, when it lacks it) and the built app's path as `SYMPHONY_QA_APP`.

  Every script's output is the step's output. All passing passes the step. A failing script is run
  again on the change's merge-base with the base branch: when one of the failing scripts passes
  there, the change broke it, and the step fails back to its `on_fail` (`code`) with the output, as a
  failing `swift test` does. When every failing script fails on the base too, the fault is the VM's
  or the base's, not the change's, which is how the step rechecks that a script passes on main in
  the VM before it ever blames a change for it.

  The step never passes by default. When it could not run (no QA VM is set up, the VM is unreachable
  or refused, the build could not run there, a tool is missing, or the scripts fail on the base
  too), it answers `{:ask, output, question}`: the step ends `paused` on a Question the Director's
  Inbox shows, naming the VM problem, and the run stops before Hand off, so nothing is pushed. The
  answer runs it again, or sends the person's words back to the code step. A build that failed
  (`:failed`, the change's) fails the step back to the code step with the build's output.
  """

  require Logger

  alias SymphonyElixir.HumanActions.PlainWords
  alias SymphonyElixir.QaAgent.Selection
  alias SymphonyElixir.{QaBuild, TicketEvents, Workspace}
  alias SymphonyElixir.QaDriver.{Checks, DevServerLease, Remote, SafeHost}

  @manifest_path "macos/Tests/window-tests.json"
  @output_limit 400_000
  @use "window tests"
  @title "Window tests"
  @run_again "Run it again"
  @why_chars 600

  # Runs one test in the commit unpacked in `$1`: from its `macos/` folder, with the pinned Xcode as
  # the Mac CI build has it, and says how the test ended. A QA VM that can't run it says why.
  @run_script """
  cd "$1/macos" 2>/dev/null || { printf 'symphony-qa-window-setup:the commit has no macos folder\\n'; exit 0; }
  if dev=$(sh ../scripts/ci/xcode-developer-dir.sh 2>&1); then
    export DEVELOPER_DIR="$dev"
  else
    printf '(the QA VM lacks the pinned Xcode, so the test runs with its selected Xcode: %s)\\n' "$dev"
  fi
  for tool in python3 swiftc; do
    command -v "$tool" > /dev/null 2>&1 || { printf 'symphony-qa-window-setup:the QA VM has no %s\\n' "$tool"; exit 0; }
  done
  /bin/sh -c "$2" 2>&1
  printf '\\nsymphony-qa-window-exit:%s\\n' "$?"
  """

  @typedoc """
  One declared window test: the script, what it tests in plain words, the shell line that runs it from `macos/`, the globs of the
  paths it covers and, when set, why it is off in the QA VM.
  """
  @type entry :: %{script: String.t(), title: String.t(), run: String.t(), covers: [String.t()], off: String.t() | nil}

  @typedoc "A workspace's manifest, read (`parse/1`): its entries, or why it can't be read."
  @type manifest :: {:ok, [entry()]} | {:error, String.t()}

  @typedoc "What `run/2` answers the step runner, as a command's result or a Question to pause on."
  @type result :: {:ok, {String.t(), integer()}} | {:timeout, String.t()} | {:ask, String.t(), map()}

  @doc "Where a workspace declares its window tests."
  @spec manifest_path() :: String.t()
  def manifest_path, do: @manifest_path

  @doc """
  Reads the manifest's text: a JSON object whose `tests` list holds one object per test, with
  `script`, `title`, `run` and `covers` (a list), and an optional `off`.
  """
  @spec parse(String.t()) :: manifest()
  def parse(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"tests" => tests}} when is_list(tests) -> entries(tests, [])
      {:ok, _other} -> {:error, "#{@manifest_path} has no `tests` list"}
      {:error, _reason} -> {:error, "#{@manifest_path} is not JSON"}
    end
  end

  defp entries([], acc), do: {:ok, Enum.reverse(acc)}

  defp entries([%{"script" => script, "title" => title, "run" => run, "covers" => covers} = test | rest], acc)
       when is_binary(script) and is_binary(title) and is_binary(run) and is_list(covers) do
    off = Map.get(test, "off")

    if Enum.all?(covers, &is_binary/1) and (is_nil(off) or is_binary(off)),
      do: entries(rest, [%{script: script, title: title, run: run, covers: covers, off: off} | acc]),
      else: {:error, "#{@manifest_path}: the test #{script} has a `covers` that is not a list of paths, or an `off` that is not a text"}
  end

  defp entries([_test | _rest], _acc), do: {:error, "#{@manifest_path}: every test needs a `script`, a `title`, a `run` and a `covers` list"}

  @doc """
  The tests `changes` selects: those on in the QA VM whose script, or a path they cover, changed,
  and every one on when the manifest itself changed. None without a readable manifest.
  """
  @spec selected(map()) :: [entry()]
  def selected(%{window_tests: {:ok, entries}, changed: changed}) do
    Enum.filter(entries, &(is_nil(&1.off) and (@manifest_path in changed or covers?(&1, changed))))
  end

  def selected(_changes), do: []

  defp covers?(entry, changed), do: Enum.any?(changed, fn path -> path == entry.script or Enum.any?(entry.covers, &Selection.glob_match?(path, &1)) end)

  @doc """
  The tests that are off in the QA VM and cover `changes` (their script or a path they cover). The
  step never skips them: it can't run them, so it stops and says so. A change to the manifest alone
  is not one of them, so a change that turns one test on runs it without stopping for those still off.
  """
  @spec off_covering(map()) :: [entry()]
  def off_covering(%{window_tests: {:ok, entries}, changed: changed}) do
    Enum.filter(entries, &(is_binary(&1.off) and covers?(&1, changed)))
  end

  def off_covering(_changes), do: []

  @doc """
  Why the step is skipped for `changes`, else nil: the workspace declares no window tests, or
  nothing a test covers changed. A change a test that is off in the QA VM covers is not a skip: the
  step can't run that test, so it ends could not run (`run/2`), and the run never hands off with a
  window test unrun. A manifest that can't be read is not a skip either: the step runs and fails,
  naming why.
  """
  @spec skip_reason(map()) :: String.t() | nil
  def skip_reason(%{window_tests: {:error, _why}}), do: nil

  def skip_reason(%{window_tests: {:ok, _entries}} = changes) do
    if selected(changes) == [] and off_covering(changes) == [], do: "nothing a window test covers changed"
  end

  def skip_reason(_changes), do: "the workspace declares no window tests (#{@manifest_path})"

  @doc """
  Runs the selected tests of `context` (a step runner context with `changes`) in the QA VM, within
  `timeout_ms` (see the moduledoc). `context.window_tests_opts` overrides what it works through:
  `:plan` (`repo_key -> {:ok, plan} | :none`, default `SymphonyElixir.QaBuild.plan/1`), `:fetch`
  (`SymphonyElixir.QaBuild.fetch/4`), `:lease` (the lease manager, default `DevServerLease`), `:host`
  (`worker_host -> host`, default `SymphonyElixir.QaDriver.Remote.host/1`), `:local_uuid` (as
  `SafeHost.open/3`) and `:git` (`fn args, cwd -> {output, status}`).
  """
  @spec run(map(), pos_integer()) :: result()
  def run(%{changes: %{window_tests: {:error, why}}}, _timeout_ms), do: {:ok, {"The window tests could not be read: #{why}.\n", 1}}

  def run(context, timeout_ms) do
    opts = Map.get(context, :window_tests_opts, [])
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    tests = selected(context.changes)
    off = off_covering(context.changes)
    result = if tests == [], do: {:done, "", 0}, else: run_tests(context, tests, opts, deadline)

    case {result, off} do
      {{:done, output, 0}, [_ | _]} -> {:ask, could_not_run_output(output, off_why(off)), question(context, off_why(off))}
      {{:done, output, status}, _off} -> {:ok, {output, status}}
      {{:timeout, output}, _off} -> {:timeout, output}
      {{:could_not_run, why, output}, _off} -> {:ask, could_not_run_output(output, why), question(context, why)}
    end
  end

  # The tests the change needs that the QA VM can't run yet: the run stops rather than hand off
  # with them unrun.
  defp off_why(off) do
    names = Enum.map_join(off, "; ", &"the #{&1.title} (#{&1.off})")
    "the change touches what a window test covers that is off in the QA VM until it passes on main there: #{names}"
  end

  defp run_tests(context, tests, opts, deadline) do
    git = Keyword.get(opts, :git, &default_git/2)

    with {:ok, plan} <- plan(context, opts),
         {:ok, head} <- rev(context.workspace, ["rev-parse", "HEAD"], git, "read the commit to test"),
         {:ok, app} <- build(context, head, opts, "this change"),
         job = %{sha: head, app: app, tests: tests, deadline: deadline},
         {:ok, results, output} <- on_vm(plan, context, opts, fn -> scripts(plan, context, job, opts) end) do
      header = "Window tests in the QA VM, on #{short(head)} (the app: #{app})\n"
      judge(context, plan, results, header <> output, opts, deadline)
    end
  end

  defp plan(context, opts) do
    case Keyword.get(opts, :plan, &QaBuild.plan/1).(context.repo_key) do
      {:ok, plan} -> {:ok, plan}
      :none -> {:could_not_run, "no QA VM that builds the app is set up for this repository", ""}
    end
  end

  # The base is the merge-base with `origin/<base_branch>`, as the changed files read it.
  defp base(context, git) do
    rev(context.workspace, ["merge-base", "HEAD", "origin/" <> (Map.get(context, :base_branch) || "main")], git, "read the base branch's commit")
  end

  defp rev(workspace, args, git, doing) do
    case git.(args, workspace) do
      {output, 0} -> {:ok, String.trim(to_string(output))}
      {output, status} -> {:could_not_run, "Symphony could not #{doing} (git exited #{status}: #{String.slice(String.trim(to_string(output)), 0, 200)})", ""}
    end
  end

  # The QA build of `sha`: its app on the QA VM. A build the change broke fails the step back to the
  # code; one the VM could not run, or a builder that is not running, could not run.
  defp build(context, sha, opts, what) do
    ticket = %{identifier: Map.get(context, :identifier) || context.issue_id, issue_id: context.issue_id}

    case Keyword.get(opts, :fetch, &QaBuild.fetch/4).(context.repo_key, sha, ticket, []) do
      %{status: :ready, app: app} ->
        {:ok, app}

      %{status: :failed} = record ->
        {:done, "The QA build of #{what} (#{short(sha)}) failed: `#{record[:command]}` exited #{record[:exit_status]}.\n#{record[:output]}\n", 1}

      %{status: :unavailable, reason: reason} ->
        {:could_not_run, "the QA build of #{what} could not run in the QA VM: #{reason}", ""}

      _none ->
        {:could_not_run, "Symphony's QA builder is not running, so #{what} was not built in the QA VM", ""}
    end
  end

  # Holds the QA VM while `fun` runs, waiting while a QA pass holds it, and says on the ticket's
  # timeline whom it waits for.
  defp on_vm(plan, context, opts, fun) do
    server = Keyword.get(opts, :lease, DevServerLease)
    key = {plan.worker_host, :desktop}
    me = self()

    case DevServerLease.holder(server, key) do
      %{pid: pid} = holder when pid != me ->
        waits = "Window tests wait for the QA VM: #{holder.ticket || "another ticket"}'s #{DevServerLease.use_of(holder)} is using it."
        Logger.info("#{waits} issue_id=#{context.issue_id} issue_identifier=#{Map.get(context, :identifier)}")
        note(context, waits)

      _free ->
        :ok
    end

    :ok = DevServerLease.acquire(server, key, %{pid: me, issue_id: context.issue_id, ticket: Map.get(context, :identifier), use: @use}, heartbeat_ms: 30_000)

    try do
      fun.()
    after
      DevServerLease.release(server, me)
    end
  end

  defp note(context, text) do
    _ = TicketEvents.record(context.repo_key, context.issue_id, "note", %{text: text, status: true}, run_id: Map.get(context, :run_id))
    :ok
  end

  # Runs the job's `tests` on its commit `sha` in a run directory of their own on the QA VM, one
  # after the other, with the app built for it (`app`), until `deadline`.
  defp scripts(plan, context, job, opts) do
    host = Keyword.get(opts, :host, &Remote.host/1).(plan.worker_host)
    scratch = Checks.private_dir("window-tests")

    try do
      case SafeHost.open(host, plan.worker_host, [scratch_dir: scratch, user: @title] ++ Keyword.take(opts, [:local_uuid])) do
        {:ok, dir} -> in_dir(host, Map.merge(job, %{dir: dir, scratch: scratch}), context, opts)
        {:error, {code, message}} -> {:could_not_run, "the QA VM could not be used (#{code}): #{message}", ""}
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp in_dir(host, job, context, opts) do
    src = Path.join(job.dir, "src")
    tar = Path.join(job.scratch, "src.tar")

    with :ok <- archive(context.workspace, job.sha, tar, Keyword.get(opts, :git, &default_git/2)),
         :ok <- ship(host, tar, src) do
      run_each(host, %{job | dir: src}, job.tests, [], "")
    end
  after
    host.cleanup.(job.dir)
  end

  defp archive(workspace, sha, tar, git) do
    case git.(["archive", "--format=tar", "-o", tar, sha], workspace) do
      {_output, 0} -> :ok
      {output, status} -> {:could_not_run, "git archive of #{short(sha)} failed (exit #{status}): #{String.slice(to_string(output), 0, 200)}", ""}
    end
  end

  defp ship(host, tar, src) do
    case host.ship.(tar, src) do
      :ok -> :ok
      {:error, reason} -> {:could_not_run, "the commit could not be copied to the QA VM: #{reason}", ""}
    end
  end

  # `job.dir` is the commit's folder on the QA VM.
  defp run_each(_host, _job, [], results, output), do: {:ok, Enum.reverse(results), output}

  defp run_each(host, job, [test | rest], results, output) do
    remaining = max(job.deadline - System.monotonic_time(:millisecond), 1)
    args = ["-c", @run_script, "sh", job.dir, test.run]
    # Not a `$ ` line: the step's reason names the step's own command and the summary line.
    output = output <> "\n== #{test.script} (in macos/: #{test.run})\n"

    case host.cmd.("/bin/sh", args, timeout_ms: remaining, output_limit: @output_limit, remote_env: [{"SYMPHONY_QA_APP", job.app}]) do
      {:ok, {text, 0}} ->
        case ended(text) do
          {:exit, status, printed} ->
            run_each(host, job, rest, [{test, status} | results], output <> printed <> status_line(status))

          {:setup, why} ->
            {:could_not_run, why, output <> text}

          :unsaid ->
            {:could_not_run, "the QA VM ended the #{test.title} without saying how", output <> text}
        end

      {:ok, {text, status}} ->
        {:could_not_run, "the QA VM could not be reached or could not run the #{test.title} (exit #{status})", output <> text}

      {:error, :timeout} ->
        {:timeout, output <> "(#{test.script} gave no result before the step's timeout)\n"}

      {:error, reason} ->
        {:could_not_run, "the QA VM could not run the #{test.title}: #{inspect(reason)}", output}
    end
  end

  # The exit line comes after a newline of its own, which is not the test's.
  defp ended(text) do
    cond do
      match = Regex.run(~r/^symphony-qa-window-setup:(.+)$/m, text) ->
        {:setup, Enum.at(match, 1)}

      match = Regex.run(~r/\nsymphony-qa-window-exit:(\d+)\n?\z/, text, return: :index) ->
        [{start, _length}, {at, length}] = match
        {:exit, text |> binary_part(at, length) |> String.to_integer(), text |> binary_part(0, start) |> line_ended()}

      true ->
        :unsaid
    end
  end

  defp line_ended(text), do: if(text == "" or String.ends_with?(text, "\n"), do: text, else: text <> "\n")

  defp status_line(0), do: "(passed)\n"
  defp status_line(status), do: "(failed: exit status #{status})\n"

  # Every test passed: the step passes. A failing test is run again on the base: one that passes
  # there was broken by the change (back to the code); all failing there too is the VM's or the
  # base's fault, so the step could not run.
  defp judge(context, plan, results, output, opts, deadline) do
    case for({test, status} <- results, status != 0, do: test) do
      [] ->
        {:done, output, 0}

      failing ->
        on_base(context, plan, failing, output, opts, deadline)
    end
  end

  defp on_base(context, plan, failing, output, opts, deadline) do
    git = Keyword.get(opts, :git, &default_git/2)

    with {:ok, base} <- base(context, git),
         {:ok, app} <- base_build(context, base, opts),
         job = %{sha: base, app: app, tests: failing, deadline: deadline},
         {:ok, base_results, base_output} <- on_vm(plan, context, opts, fn -> scripts(plan, context, job, opts) end) do
      verdict(failing, base_results, output <> "\n-- The failing tests again, on the base branch (#{short(base)}):\n" <> base_output)
    else
      {:could_not_run, why, more} -> {:could_not_run, why, output <> more}
      {:timeout, more} -> {:timeout, output <> "\n-- The failing tests again, on the base branch:\n" <> more}
    end
  end

  defp verdict(failing, base_results, output) do
    case for({test, 0} <- base_results, do: test.script) do
      [] ->
        titles = Enum.map_join(failing, ", ", & &1.title)
        {:could_not_run, "the #{titles} also fails in the QA VM on the base branch, so the fault is the VM's or the base's, not this change's", output}

      passing ->
        names = Enum.map_join(failing, ", ", & &1.script)
        {:done, output <> "\nFailed: #{names}. Broken by this change: #{Enum.join(passing, ", ")} passes on the base branch.\n", 1}
    end
  end

  # The base branch that does not build in the QA VM can't tell whose fault the failure is.
  defp base_build(context, base, opts) do
    case build(context, base, opts, "the base branch") do
      {:done, text, _status} -> {:could_not_run, "the base branch (#{short(base)}) does not build in the QA VM", text}
      other -> other
    end
  end

  defp could_not_run_output(output, why), do: output <> "\n(could not run: #{why})\n"

  @doc """
  The Question the step pauses on when it could not run: what is wrong with the QA VM, in plain
  words, and the ways forward: run it again (once the VM is back), or send the person's words to the
  code step. Neither passes the step.
  """
  @spec question(map(), String.t()) :: map()
  def question(context, why) do
    name = Map.get(context, :identifier) || "this ticket"
    problem = why |> PlainWords.scrub() |> String.slice(0, @why_chars)

    %{
      title: String.slice("#{name}: the window tests could not run in the QA VM", 0, 120),
      question: "The window tests of #{name} could not run in the QA VM, so the run stopped before it pushed anything. Should Symphony run them again?",
      why:
        "The change touches tests that drive an app window, and those run only in the QA VM. They could not run there: #{problem}. " <>
          "Symphony never counts them as passed without running them, so nothing was pushed.",
      if_unanswered: "#{name} stays paused before its hand off, and nothing is pushed.",
      recommendation_reason: "Once the QA VM works again, running the tests again lets the run hand off with them passed.",
      options: [
        %{
          label: @run_again,
          effect: "Symphony runs the window tests of #{name} again in the QA VM.",
          recommended: true,
          tradeoffs: [%{kind: "risk", text: "It stops here again while the QA VM still has the problem."}]
        },
        %{
          label: SymphonyElixir.PhaseSteps.back_to_code(),
          effect: "Symphony sends your answer to the run's code step, which works on #{name} again before the tests run.",
          recommended: false,
          tradeoffs: [%{kind: "cost", text: "The run goes back to writing the code, and the window tests run again after it."}]
        }
      ]
    }
  end

  defp short(sha), do: String.slice(sha, 0, 8)

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)
end
