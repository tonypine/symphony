defmodule SymphonyElixir.QaBuild do
  @moduledoc """
  The QA pre-build: Symphony builds a PR head's macOS app on the QA host ahead of its QA pass, with
  no agent, so the pass starts from a finished app instead of building from nothing.

  A build is asked for with `request/4`, by the commit: when a ticket enters Code Review with a
  head (`SymphonyElixir.AgentRunner`), when the PR watcher records a new head for a ticket in Code
  Review or QA (`SymphonyElixir.PrWatch.Repo`), and at the QA dispatch gate for a head nobody asked
  for yet (`SymphonyElixir.QaBuildHold`). Asking twice changes nothing. It builds for a repository
  whose `macos_app` playbook has a `build` command and an `app`, on its `auto_review.worker_host`;
  for any other repository a request does nothing.

  A build is keyed by the repository and the commit's tree (`git rev-parse <sha>^{tree}`, read in
  the ticket's workspace, fetching the commit first when the workspace does not hold it), so a head
  whose content was already built is ready at once. Each key has one record in the run store
  (`t:record/0`, read with `get/3` and, by commit, `lookup/3`):

    * `:building` while it is queued or runs;
    * `:ready` with the path of the stored `.app` on the QA host;
    * `:failed` when the build command exited non-zero, with the command, its exit status and the
      end of its output;
    * `:unavailable` when the build could not run (the QA host was refused or unreachable, the
      commit could not be copied, the command timed out), with the reason.

  A record that is not `:building` is final: the same tree is never built again. A commit whose
  tree could not be read is `:unavailable` too, by commit. The `:building` records a previous run
  of Symphony left are asked for again when this one starts.

  The server only keeps the queue: reading a tree and building (`SymphonyElixir.QaBuild.Store`) run
  in `SymphonyElixir.TaskSupervisor` tasks, one build at a time on a QA host, and never two for one
  key. When a build ends, whatever the outcome, the tickets `SymphonyElixir.QaBuildHold` holds for
  it are released, so QA dispatches at once; `await/3` returns then too, for a pass that started
  while its build ran.

  Without the server (it is off in tests), `request/4` does nothing and the reads answer from the
  store.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, QaBuildHold, QaPolicy, RunStore, Workspace}
  alias SymphonyElixir.QaBuild.Store
  alias SymphonyElixir.Repo.Fetcher

  @default_build_timeout_ms 900_000
  @building_index {:qa_build, :building}

  @typedoc "The ticket a build is asked for: its workspace holds the commit. `held: true` when `SymphonyElixir.QaBuildHold` holds it for the build."
  @type ticket :: %{
          required(:identifier) => String.t(),
          optional(:issue_id) => String.t() | nil,
          optional(:held) => boolean()
        }

  @typedoc "Runs git with `args` in a directory and returns its output and exit status."
  @type git :: ([String.t()], Path.t() -> {term(), integer()})

  @typedoc """
  A build's record. Every record has `repo_key`, `tree`, `status`, `sha` (the commit that asked),
  `identifier` (the ticket that asked) and `at`; `:ready` adds `app`, `:failed` adds `command`,
  `exit_status`, `output` and `reworked` (the tickets already sent to Rework for it), and
  `:unavailable` adds `reason`. A commit whose tree could not be read has only `status` and `reason`.
  """
  @type record :: %{required(:status) => :building | :ready | :failed | :unavailable, optional(atom()) => term()}

  @typedoc "What a repository builds: the QA host and the playbook's `build`, `app` and timeout."
  @type plan :: %{worker_host: String.t(), build: String.t(), app: String.t(), build_timeout_ms: pos_integer()}

  defstruct store: RunStore,
            task_supervisor: SymphonyElixir.TaskSupervisor,
            plan_fun: nil,
            workspace_fun: nil,
            tree_fun: nil,
            build_fun: nil,
            release_fun: nil,
            # Trees being read: `{repo_key, sha} => [ticket]`, and their tasks.
            heads: %{},
            reading: %{},
            # Builds queued or running: `{repo_key, tree} => job`, and the running ones' tasks.
            jobs: %{},
            queue: [],
            running: %{}

  @doc """
  Starts the builder. Options: `:name`, `:run_store`, `:task_supervisor`, and the functions it
  works through, each with a production default: `:plan` (`plan/1`), `:workspace` (`repo_key,
  identifier -> {:ok, path} | {:error, term}`), `:tree` (`tree/3` with the default git), `:build`
  (`SymphonyElixir.QaBuild.Store.build/2`) and `:release` (`SymphonyElixir.QaBuildHold.release/3`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Asks for the build of commit `sha` of `repo_key`, for `ticket`, and returns without waiting.
  Nothing happens when the commit's tree already has a record, except that a held ticket is
  released when that record is final. Options: `:server`.
  """
  @spec request(String.t(), String.t(), ticket(), keyword()) :: :ok
  def request(repo_key, sha, %{identifier: identifier} = ticket, opts \\ []) when is_binary(repo_key) and is_binary(sha) and is_binary(identifier) do
    GenServer.cast(server(opts), {:request, repo_key, sha, ticket})
  end

  @doc "Whether the builder runs and `repo_key` has something to build (`plan/1`). Options: `:server`, `:plan`."
  @spec builds?(String.t(), keyword()) :: boolean()
  def builds?(repo_key, opts \\ []) do
    GenServer.whereis(server(opts)) != nil and Keyword.get(opts, :plan, &plan/1).(repo_key) != :none
  end

  @doc """
  What `repo_key` builds ahead of QA: its `macos_app` playbook's `build` command and `app` path, on
  its `auto_review.worker_host`. `:none` when one of them is missing.
  """
  @spec plan(String.t()) :: {:ok, plan()} | :none
  def plan(repo_key) do
    with {:ok, settings} <- Config.settings_for_repo(repo_key),
         worker_host when is_binary(worker_host) <- settings.auto_review.worker_host,
         %{build: build, app: app} = playbook when is_binary(build) and is_binary(app) <-
           Enum.find(QaPolicy.enabled_playbooks(settings), &(&1.kind == "macos_app")) do
      {:ok, %{worker_host: worker_host, build: build, app: app, build_timeout_ms: Map.get(playbook, :build_timeout_ms) || @default_build_timeout_ms}}
    else
      _nothing_to_build -> :none
    end
  end

  @doc "The record of `repo_key`'s build of `tree`, or nil. Options: `:run_store`."
  @spec get(String.t(), String.t(), keyword()) :: record() | nil
  def get(repo_key, tree, opts \\ []), do: read(store(opts), {:qa_build, repo_key, tree})

  @doc """
  The record of the build of commit `sha` of `repo_key`, or nil when none was asked for. Options:
  `:run_store`.
  """
  @spec lookup(String.t(), String.t(), keyword()) :: record() | nil
  def lookup(repo_key, sha, opts \\ []) do
    case read(store(opts), {:qa_build_head, repo_key, sha}) do
      %{tree: tree} -> get(repo_key, tree, opts)
      unread_or_none -> unread_or_none
    end
  end

  @doc """
  The record of `repo_key`'s build of `tree` once it is no longer queued or running: at once when
  it is not. Options: `:server`, `:run_store`.
  """
  @spec await(String.t(), String.t(), keyword()) :: record() | nil
  def await(repo_key, tree, opts \\ []) do
    GenServer.call(server(opts), {:await, {repo_key, tree}}, :infinity)
  catch
    :exit, _not_running -> get(repo_key, tree, opts)
  end

  @doc """
  Marks the failed build of `tree` as the reason `issue_id` goes to Rework: `:ok` the first time,
  `:already` after, and for a build that did not fail, so a ticket is sent back once for a tree.
  Options: `:server`.
  """
  @spec mark_reworked(String.t(), String.t(), String.t(), keyword()) :: :ok | :already
  def mark_reworked(repo_key, tree, issue_id, opts \\ []) do
    GenServer.call(server(opts), {:mark_reworked, {repo_key, tree}, issue_id}, :infinity)
  catch
    :exit, _not_running -> :already
  end

  @doc """
  The tree of commit `sha`, read in `workspace` with `git` (`fn args, cwd -> {output, status}`). A
  commit the workspace does not hold is fetched from `origin` first.
  """
  @spec tree(Path.t(), String.t(), git()) :: {:ok, String.t()} | {:error, String.t()}
  def tree(workspace, sha, git \\ &default_git/2) do
    with {:error, _missing} <- rev_parse_tree(workspace, sha, git),
         {_output, 0} <- Fetcher.fetch(workspace, fn -> git.(["fetch", "--quiet", "origin", sha], workspace) end) do
      rev_parse_tree(workspace, sha, git)
    else
      {:ok, tree} -> {:ok, tree}
      {output, status} -> {:error, "git fetch origin #{sha} failed (exit #{status}): #{String.slice(to_string(output), 0, 300)}"}
    end
  end

  defp rev_parse_tree(workspace, sha, git) do
    case git.(["rev-parse", "--verify", "--quiet", sha <> "^{tree}"], workspace) do
      {output, 0} -> {:ok, String.trim(to_string(output))}
      {_output, status} -> {:error, "git rev-parse #{sha}^{tree} failed (exit #{status})"}
    end
  end

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      store: Keyword.get(opts, :run_store, RunStore),
      task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
      plan_fun: Keyword.get(opts, :plan, &plan/1),
      workspace_fun: Keyword.get(opts, :workspace, &Workspace.local_path_for_issue(&2, &1)),
      tree_fun: Keyword.get(opts, :tree, &tree/2),
      build_fun: Keyword.get(opts, :build, &Store.build/2),
      release_fun: Keyword.get(opts, :release, &QaBuildHold.release/3)
    }

    {:ok, state, {:continue, :resume}}
  end

  # The builds a previous Symphony left queued or running are asked for again; one whose repository
  # no longer builds ends as `:unavailable`.
  @impl true
  def handle_continue(:resume, state) do
    left =
      for {repo_key, tree} <- building(state),
          %{status: :building} = record <- [read(state.store, {:qa_build, repo_key, tree})],
          do: record

    {:noreply, Enum.reduce(left, state, &resume/2)}
  end

  defp resume(record, state) do
    key = {record.repo_key, record.tree}

    case state.plan_fun.(record.repo_key) do
      {:ok, plan} ->
        Logger.info("QA build asked for again after a restart repo_key=#{record.repo_key} tree=#{record.tree} issue_identifier=#{record.identifier}")
        enqueue(state, key, record, plan, nil)

      :none ->
        finish(state, key, record, {:unavailable, "the repository no longer has a macos_app playbook with a build and an app on a QA host"})
    end
  end

  @impl true
  def handle_cast({:request, repo_key, sha, ticket}, state) do
    ticket = Map.put(ticket, :repo_key, repo_key)

    case state.plan_fun.(repo_key) do
      {:ok, plan} ->
        {:noreply, requested(state, {repo_key, sha}, ticket, plan)}

      :none ->
        release(state, [ticket])
        {:noreply, state}
    end
  end

  defp requested(state, {repo_key, sha} = head, ticket, plan) do
    case read(state.store, {:qa_build_head, repo_key, sha}) do
      %{tree: tree} ->
        with_tree(state, {repo_key, tree}, sha, ticket, plan)

      %{status: :unavailable} ->
        release(state, [ticket])
        state

      nil ->
        read_tree(state, head, ticket)
    end
  end

  # One task reads a commit's tree, whoever asks meanwhile.
  defp read_tree(state, head, ticket) when is_map_key(state.heads, head), do: %{state | heads: Map.update!(state.heads, head, &[ticket | &1])}

  defp read_tree(state, {repo_key, sha} = head, ticket) do
    %{workspace_fun: workspace_fun, tree_fun: tree_fun} = state

    read = fn ->
      with {:ok, workspace} <- workspace_fun.(repo_key, ticket.identifier), do: tree_fun.(workspace, sha)
    end

    case start_task(state, read) do
      {:ok, task} ->
        %{state | heads: Map.put(state.heads, head, [ticket]), reading: Map.put(state.reading, task.ref, head)}

      {:error, reason} ->
        tree_unread(%{state | heads: Map.put(state.heads, head, [ticket])}, head, "the task could not start: #{inspect(reason)}")
    end
  end

  defp tree_read(state, {repo_key, sha} = head, tree) do
    {tickets, heads} = Map.pop(state.heads, head)
    write(state, {:qa_build_head, repo_key, sha}, %{tree: tree})

    case state.plan_fun.(repo_key) do
      {:ok, plan} ->
        tickets |> Enum.reverse() |> Enum.reduce(%{state | heads: heads}, &with_tree(&2, {repo_key, tree}, sha, &1, plan))

      :none ->
        release(state, tickets)
        %{state | heads: heads}
    end
  end

  defp tree_unread(state, {repo_key, sha} = head, reason) do
    {tickets, heads} = Map.pop(state.heads, head)
    Logger.warning("QA build unavailable: the tree of the commit could not be read repo_key=#{repo_key} head_sha=#{sha} #{issue_context(tickets)} reason=#{reason}")
    write(state, {:qa_build_head, repo_key, sha}, %{status: :unavailable, reason: "the commit's tree could not be read: #{reason}"})
    release(state, tickets)
    %{state | heads: heads}
  end

  defp with_tree(state, {repo_key, tree} = key, sha, ticket, plan) do
    case read(state.store, {:qa_build, repo_key, tree}) do
      nil ->
        record = %{repo_key: repo_key, tree: tree, status: :building, sha: sha, identifier: ticket.identifier}
        record = Map.put(record, :at, DateTime.utc_now())
        write(state, {:qa_build, repo_key, tree}, record)
        write(state, @building_index, %{keys: Enum.uniq([key | building(state)])})
        Logger.info("QA build queued repo_key=#{repo_key} tree=#{tree} head_sha=#{sha} #{issue_context([ticket])} worker_host=#{plan.worker_host}")
        enqueue(state, key, record, plan, ticket)

      %{status: :building} = record ->
        enqueue(state, key, record, plan, ticket)

      _final ->
        release(state, [ticket])
        state
    end
  end

  # The ticket waits for the build before it may start, so a build that ends at once still
  # releases it.
  defp enqueue(state, key, _record, _plan, ticket) when is_map_key(state.jobs, key), do: wait(state, key, ticket)

  defp enqueue(state, {repo_key, tree} = key, record, plan, ticket) do
    job = %{repo_key: repo_key, tree: tree, sha: record.sha, identifier: record.identifier, plan: plan, record: record, waiters: [], awaiting: []}
    %{state | jobs: Map.put(state.jobs, key, job), queue: state.queue ++ [key]} |> wait(key, ticket) |> start_queued()
  end

  defp wait(state, key, %{held: true, issue_id: issue_id} = ticket) when is_binary(issue_id) do
    update_in(state.jobs[key].waiters, &Enum.uniq([ticket | &1]))
  end

  defp wait(state, _key, _ticket), do: state

  @impl true
  def handle_call({:await, key}, from, state) when is_map_key(state.jobs, key) do
    {:noreply, update_in(state.jobs[key].awaiting, &[from | &1])}
  end

  def handle_call({:await, {repo_key, tree}}, _from, state), do: {:reply, read(state.store, {:qa_build, repo_key, tree}), state}

  def handle_call({:mark_reworked, {repo_key, tree}, issue_id}, _from, state) do
    with %{status: :failed} = record <- read(state.store, {:qa_build, repo_key, tree}),
         false <- issue_id in record.reworked do
      write(state, {:qa_build, repo_key, tree}, %{record | reworked: [issue_id | record.reworked]})
      {:reply, :ok, state}
    else
      _not_failed_or_done -> {:reply, :already, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.reading, ref) do
    Process.demonitor(ref, [:flush])
    {head, reading} = Map.pop(state.reading, ref)
    state = %{state | reading: reading}

    case result do
      {:ok, tree} -> {:noreply, tree_read(state, head, tree)}
      {:error, reason} -> {:noreply, tree_unread(state, head, if(is_binary(reason), do: reason, else: inspect(reason)))}
    end
  end

  def handle_info({ref, outcome}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, ended(state, ref, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.reading, ref) do
    {head, reading} = Map.pop(state.reading, ref)
    {:noreply, tree_unread(%{state | reading: reading}, head, "the task exited: #{inspect(reason)}")}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.running, ref) do
    {:noreply, ended(state, ref, {:unavailable, "the build task exited: #{inspect(reason)}"})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ended(state, ref, outcome) do
    {key, running} = Map.pop(state.running, ref)
    state = %{state | running: running}
    state |> finish(key, state.jobs[key].record, outcome) |> start_queued()
  end

  # Writes the final record, then lets go of everyone waiting for it.
  defp finish(state, {repo_key, tree} = key, record, outcome) do
    {job, jobs} = Map.pop(state.jobs, key, %{waiters: [], awaiting: [], plan: nil})
    record = final(record, outcome, job.plan)
    write(state, {:qa_build, repo_key, tree}, record)
    write(state, @building_index, %{keys: building(state) -- [key]})
    log_final(record)
    release(state, job.waiters)
    Enum.each(job.awaiting, &GenServer.reply(&1, record))
    %{state | jobs: jobs, queue: state.queue -- [key]}
  end

  defp final(record, {:ready, app}, _plan), do: Map.merge(record, %{status: :ready, app: app, at: DateTime.utc_now()})

  defp final(record, {:failed, status, output}, plan),
    do: Map.merge(record, %{status: :failed, command: plan.build, exit_status: status, output: output, reworked: [], at: DateTime.utc_now()})

  defp final(record, {:unavailable, reason}, _plan), do: Map.merge(record, %{status: :unavailable, reason: reason, at: DateTime.utc_now()})

  defp log_final(%{status: :ready} = record),
    do: Logger.info("QA build ready #{context(record)} app=#{record.app}")

  defp log_final(%{status: :failed} = record),
    do: Logger.warning("QA build failed #{context(record)} exit_status=#{record.exit_status}")

  defp log_final(%{status: :unavailable} = record),
    do: Logger.warning("QA build unavailable #{context(record)} reason=#{record.reason}")

  defp context(record), do: "repo_key=#{record.repo_key} tree=#{record.tree} head_sha=#{record.sha} issue_identifier=#{record.identifier}"

  defp issue_context(tickets) do
    tickets |> Enum.map(&"issue_id=#{Map.get(&1, :issue_id)} issue_identifier=#{&1.identifier}") |> Enum.uniq() |> Enum.join(" ")
  end

  # Starts queued builds, oldest first, skipping one whose QA host already builds.
  defp start_queued(state) do
    busy = MapSet.new(Map.values(state.running), &state.jobs[&1].plan.worker_host)

    case Enum.find(state.queue, &(not MapSet.member?(busy, state.jobs[&1].plan.worker_host))) do
      nil -> state
      key -> start_build(%{state | queue: state.queue -- [key]}, key, state.jobs[key])
    end
  end

  defp start_build(state, {repo_key, _tree} = key, job) do
    %{workspace_fun: workspace_fun, build_fun: build_fun} = state

    build = fn ->
      case workspace_fun.(repo_key, job.identifier) do
        {:ok, workspace} -> build_fun.(job |> Map.take([:repo_key, :tree, :sha, :plan]) |> Map.put(:workspace, workspace), [])
        {:error, reason} -> {:unavailable, "the ticket's workspace could not be found: #{inspect(reason)}"}
      end
    end

    case start_task(state, build) do
      {:ok, task} ->
        Logger.info("QA build started #{context(job.record)} worker_host=#{job.plan.worker_host}")
        start_queued(%{state | running: Map.put(state.running, task.ref, key)})

      {:error, reason} ->
        state |> finish(key, job.record, {:unavailable, "the build task could not start: #{inspect(reason)}"}) |> start_queued()
    end
  end

  defp start_task(state, fun) do
    {:ok, Task.Supervisor.async_nolink(state.task_supervisor, fun)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp release(state, tickets) do
    for %{held: true, issue_id: issue_id} = ticket when is_binary(issue_id) <- tickets do
      state.release_fun.(ticket.repo_key, issue_id, ticket.identifier)
    end

    :ok
  end

  defp building(state) do
    case read(state.store, @building_index) do
      %{keys: keys} -> keys
      _none -> []
    end
  end

  defp write(state, key, value) do
    with {:error, reason} <- state.store.put_github_updates(key, value) do
      Logger.warning("QA build could not write its record key=#{inspect(key)} reason=#{inspect(reason)}")
    end
  end

  defp read(store, key) do
    case store.get_github_updates(key) do
      %{} = value -> value
      _none_or_error -> nil
    end
  end

  defp store(opts), do: Keyword.get(opts, :run_store, RunStore)
  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
end
