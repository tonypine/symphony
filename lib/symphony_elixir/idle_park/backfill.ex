defmodule SymphonyElixir.IdlePark.Backfill do
  @moduledoc """
  Brings a ticket an idle run parked before parks asked a question (TP-1326) into the shape a park
  gives today, once per start-up: the orchestrator's boot starts it (`start/2`), in a task, so
  startup never waits on its Git and Linear work.

  A ticket is one to bring up to date when its record (`SymphonyElixir.TicketState`) is in
  `Backlog`, Symphony wrote that phase (`phase_owner: :symphony`), its newest move signal is the
  park's (`SymphonyElixir.IdlePark.parked_from/2`), and its pause holds no open question and no
  reason the Director may release. Such a ticket gets what a park gives it:

    * the workspace's commits that origin lacks pushed to its branch
      (`SymphonyElixir.WorkspaceHead.push_unpushed/3`); a push that fails is logged, and the
      commits stay in the workspace;
    * the park's question with its options (`SymphonyElixir.IdlePark.ask/4`), which the Inbox
      lists, or, when the store refuses it, a reason Unblock releases;
    * one `park.backfilled` ledger event naming what it was given.

  Unblock then resumes it in the phase it was parked from, as for any park. It is idempotent: a
  ticket already in today's shape has its question open or its releasable reason set, so a second
  boot leaves it alone.
  """

  require Logger

  alias SymphonyElixir.{Config, IdlePark, Pauses, Questions, RunStore, TicketEvents, TicketState}
  alias SymphonyElixir.{Workspace, WorkspaceHead}

  @typedoc """
  `run/2`'s and `start/2`'s options: `pusher:` (as `WorkspaceHead.push_unpushed/3`), `workspace:`
  (a function of the repo key and the ticket's identifier giving `{workspace, source_repo}`, or
  nil when the ticket has no local workspace to push), `enabled:` and `supervisor:` (`start/2`'s).
  """
  @type opt ::
          {:pusher, (Path.t() | nil, nil, Path.t() | nil -> {:pushed, String.t()} | :nothing | {:error, term()})}
          | {:workspace, (String.t(), String.t() -> {Path.t(), Path.t() | nil} | nil)}
          | {:enabled, boolean()}
          | {:supervisor, GenServer.server()}

  @typedoc "What one boot changed: the tickets it brought up to date, by identifier."
  @type outcome :: %{backfilled: [String.t()]}

  @doc """
  Starts `run/2` over `repo_keys` in a task of `SymphonyElixir.TaskSupervisor`, unless the
  `:park_backfill` app env (or `enabled:`) turns it off, as the test suite does.
  """
  @spec start([String.t()], [opt()]) :: DynamicSupervisor.on_start_child() | :disabled | {:error, term()}
  def start(repo_keys, opts \\ []) when is_list(repo_keys) do
    if Keyword.get(opts, :enabled, Application.get_env(:symphony_elixir, :park_backfill, true)) do
      Task.Supervisor.start_child(Keyword.get(opts, :supervisor, SymphonyElixir.TaskSupervisor), fn -> run(repo_keys, opts) end)
    else
      :disabled
    end
  catch
    :exit, reason ->
      Logger.warning("Failed to start the backfill of parked tickets: #{inspect(reason)}")
      {:error, reason}
  end

  @doc "Brings every old-shape park of `repo_keys` up to date (see the module doc)."
  @spec run([String.t()], [opt()]) :: outcome()
  def run(repo_keys, opts \\ []) when is_list(repo_keys) do
    backfilled = Enum.flat_map(repo_keys, &run_repo(&1, opts))
    if backfilled != [], do: Logger.info("Brought #{length(backfilled)} parked ticket(s) up to date: #{Enum.join(backfilled, ", ")}")
    %{backfilled: backfilled}
  end

  defp run_repo(repo_key, opts) do
    case RunStore.list_ticket_states(repo_key) do
      records when is_list(records) ->
        for record <- records,
            {:ok, from_state} <- [old_park(repo_key, TicketState.normalize(record))],
            do: backfill(repo_key, record, from_state, opts)

      {:error, reason} ->
        Logger.warning("Failed to read the tickets to backfill their parks repo_key=#{repo_key}: #{inspect(reason)}")
        []
    end
  end

  # `{:ok, from_state}` for a ticket Symphony parked whose pause has neither the park's question nor
  # a reason the Director releases; `:none` for any other.
  defp old_park(repo_key, %{issue_id: issue_id, phase: phase, phase_owner: :symphony} = record) when is_binary(issue_id) do
    ticket = {:ticket, repo_key, issue_id}

    with {:ok, from_state} <- IdlePark.parked_from(phase, TicketState.signals(record)),
         [] <- Questions.open(ticket),
         false <- Pauses.releasable?(ticket) do
      {:ok, from_state}
    else
      _parked_today_or_not_parked -> :none
    end
  end

  defp old_park(_repo_key, _record), do: :none

  defp backfill(repo_key, record, from_state, opts) do
    issue_id = Map.fetch!(record, :issue_id)
    name = Map.get(record, :issue_identifier) || issue_id
    push = push(repo_key, name, opts)

    added =
      case IdlePark.ask({:ticket, repo_key, issue_id}, name, from_state, IdlePark.idle_turns()) do
        {:asked, question_id} -> %{added: ["question"], question_id: question_id}
        :reason_set -> %{added: ["releasable_reason"]}
      end

    payload =
      case push do
        {:pushed, branch} -> %{added | added: added.added ++ ["push"]} |> Map.put(:branch, branch)
        _nothing -> added
      end

    with {:error, reason} <- TicketEvents.record(repo_key, issue_id, "park.backfilled", Map.put(payload, :from, from_state)) do
      Logger.warning("Brought #{name}'s park up to date but couldn't record it: #{inspect(reason)}")
    end

    name
  end

  defp push(repo_key, name, opts) do
    resolve = Keyword.get(opts, :workspace, &workspace/2)
    pusher = Keyword.get(opts, :pusher, &WorkspaceHead.push_unpushed/3)

    with {workspace, source_repo} <- resolve.(repo_key, name),
         {:pushed, branch} <- pusher.(workspace, nil, source_repo) do
      Logger.info("Pushed #{name}'s unpushed commits to origin #{branch} while bringing its park up to date")
      {:pushed, branch}
    else
      {:error, reason} ->
        Logger.warning("Could not push #{name}'s unpushed commits while bringing its park up to date; they stay in its workspace reason=#{inspect(reason)}")
        :nothing

      _nothing ->
        :nothing
    end
  end

  # The ticket's local workspace (`workspaces.root`/repo/identifier, as `SymphonyElixir.Workspace`
  # lays it out) and the source repo its origin must match; nil when the repo's settings can't be read.
  defp workspace(repo_key, identifier) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} ->
        root = Path.expand(settings.workspace.root)
        {Path.join([root, Workspace.safe_identifier(repo_key), Workspace.safe_identifier(identifier)]), settings.workspace.repo}

      {:error, _reason} ->
        nil
    end
  end
end
