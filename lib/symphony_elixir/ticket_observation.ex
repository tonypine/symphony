defmodule SymphonyElixir.TicketObservation do
  @moduledoc """
  Writes what Symphony reads of a ticket in Linear into its record (`SymphonyElixir.TicketState`),
  so the record learns from every poll: the ticket's state as the record's `phase`, its title,
  labels, priority, assignee, open blockers, URL and Linear's `updatedAt`.

  `observe/3` reads the record (a new one when the ticket has none), applies
  `SymphonyElixir.TicketState.observe/3` and writes the observed fields back through
  `SymphonyElixir.RunStore.update_ticket_state/3` only when one changed, so an identical poll writes
  nothing and a write never touches the record's holds, verdicts or other fields. A fact older than
  the record's `linear_updated_at` is dropped. Nothing reads the observed fields yet, and an
  observation records no ledger event.

  What each observation did is counted in a public ETS table owned by this server, for the state
  payload: the counts are diagnostic and start again from zero when Symphony restarts. Without the
  server (some tests), counting is a no-op and the summary is all zeros.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, RunStore, TicketState}
  alias SymphonyElixir.Linear.Issue

  @table __MODULE__
  @outcomes [:updated, :unchanged, :stale]

  @type outcome :: :updated | :unchanged | :stale

  @type summary :: %{
          updated: non_neg_integer(),
          unchanged: non_neg_integer(),
          stale: non_neg_integer(),
          errors: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Observes one `issue` of `repo_key`. `opts`:

  - `:now` — the observation time, defaulting to now
  - `:terminal_states` — the states whose blockers no longer block, defaulting to the repo's
    `tracker.terminal_states`

  Returns `{:ok, :updated}` when the record changed and was written, `{:ok, :unchanged}` when it
  already held what the issue says, `{:ok, :stale}` when the issue is older than the record (it is
  dropped), and `{:error, reason}` when the store refused the read or the write.
  """
  @spec observe(String.t(), Issue.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def observe(repo_key, %Issue{id: issue_id} = issue, opts \\ []) when is_binary(issue_id) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    issue = %{issue | blocked_by: open_blockers(issue, repo_key, opts)}

    result =
      with {:ok, stored} <- read(repo_key, issue_id) do
        record = stored || TicketState.new(repo_key, issue_id)

        case TicketState.observe(record, issue, now) do
          {_record, :stale} -> {:ok, :stale}
          {_record, :unchanged} -> {:ok, :unchanged}
          {observed, :changed} -> write(stored, observed)
        end
      end

    count(result)
    result
  end

  @doc """
  Observes every issue of `issues` for `repo_key` (see `observe/3`), and returns how many had each
  outcome. A store error is logged with the issue it was for and counted under `errors`; it never
  stops the others.
  """
  @spec observe_all(String.t(), [Issue.t()], keyword()) :: summary()
  def observe_all(repo_key, issues, opts \\ []) when is_list(issues) do
    opts = Keyword.put_new_lazy(opts, :terminal_states, fn -> terminal_states(repo_key) end)

    Enum.reduce(issues, empty_summary(), fn issue, acc ->
      case observe_issue(repo_key, issue, opts) do
        {:ok, outcome} ->
          Map.update!(acc, outcome, &(&1 + 1))

        {:error, reason} ->
          Logger.warning("Ticket observation failed for issue_id=#{issue_id(issue)} issue_identifier=#{identifier(issue)} repo_key=#{repo_key}: #{inspect(reason)}")
          Map.update!(acc, :errors, &(&1 + 1))
      end
    end)
  end

  @doc "How many observations had each outcome since Symphony started."
  @spec summary() :: summary()
  def summary do
    Enum.reduce([:errors | @outcomes], empty_summary(), fn outcome, acc ->
      case :ets.lookup(@table, outcome) do
        [{^outcome, count}] -> Map.put(acc, outcome, count)
        [] -> acc
      end
    end)
  rescue
    ArgumentError -> empty_summary()
  end

  @doc "Forgets every count."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp observe_issue(repo_key, %Issue{id: issue_id} = issue, opts) when is_binary(issue_id), do: observe(repo_key, issue, opts)

  defp observe_issue(_repo_key, _issue, _opts) do
    bump(:errors)
    {:error, :invalid_issue}
  end

  defp read(repo_key, issue_id) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      {:error, reason} -> {:error, reason}
      stored -> {:ok, stored}
    end
  end

  defp write(nil, observed) do
    with :ok <- RunStore.put_ticket_state(observed), do: {:ok, :updated}
  end

  defp write(_stored, observed) do
    with :ok <- RunStore.update_ticket_state(observed.repo_key, observed.issue_id, TicketState.observation(observed)),
         do: {:ok, :updated}
  end

  defp open_blockers(%Issue{blocked_by: :unknown}, _repo_key, _opts), do: :unknown

  defp open_blockers(issue, repo_key, opts) do
    terminal_states = Keyword.get_lazy(opts, :terminal_states, fn -> terminal_states(repo_key) end)
    Issue.open_blockers(issue, terminal_states)
  end

  defp terminal_states(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings.tracker.terminal_states
      {:error, _reason} -> []
    end
  end

  defp count({:ok, outcome}), do: bump(outcome)
  defp count({:error, _reason}), do: bump(:errors)

  defp bump(key) do
    :ets.update_counter(@table, key, 1, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp empty_summary, do: %{updated: 0, unchanged: 0, stale: 0, errors: 0}

  defp issue_id(%Issue{id: id}), do: id
  defp issue_id(_issue), do: nil

  defp identifier(%Issue{identifier: identifier}), do: identifier
  defp identifier(_issue), do: nil
end
