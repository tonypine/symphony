defmodule SymphonyElixir.TicketObservation do
  @moduledoc """
  Writes what Symphony reads of a ticket in Linear into its record (`SymphonyElixir.TicketState`),
  so the record learns from every poll: the ticket's state as the record's `phase`, its title,
  labels, priority, assignee, open blockers, URL and Linear's `updatedAt`.

  `observe/3` reads the record (a new one when the ticket has none), applies
  `SymphonyElixir.TicketState.observe/4` and writes the observed fields back through
  `SymphonyElixir.RunStore.update_ticket_state/3` only when one changed, so an identical poll writes
  nothing and a write never touches the record's holds, verdicts or other fields. A fact older than
  the record's `linear_updated_at` is dropped. The record keeps which read brought its last change
  (`observed_from`: the poll, a by-id read, the PR and CI watcher or a webhook delivery). Nothing
  reads the observed fields yet, and an observation records no ledger event.

  `observe_delivery/2` observes what a Linear webhook delivery says (`SymphonyElixir.Linear.Webhook.parse/1`)
  the same way, under the repo the ticket routes to, or marks the record removed.

  Every read other than a webhook delivery is compared with the webhook: a read that changes a field
  the webhook carries (state, identifier, title, labels, priority, assignee, URL) of an existing
  record, while `linear.webhooks.enabled` is on, counts as "poll first", and the last ten keep the
  ticket and the fields; a read that changes none of them while the record's last change came from a
  webhook counts as "webhook first", once for each change the webhook brought.

  What each observation did is counted in a public ETS table owned by this server, for the state
  payload: the counts are diagnostic and start again from zero when Symphony restarts. Without the
  server (some tests), counting is a no-op and the summary is all zeros.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, RunStore, TicketState}
  alias SymphonyElixir.Linear.{Issue, Webhook}
  alias SymphonyElixir.Routing.Resolver

  @table __MODULE__
  @outcomes [:updated, :unchanged, :stale]
  @recent_limit 10
  # Well under Linear's 5 s delivery timeout, which also covers the signature check and the relay.
  @delivery_timeout_ms 2_000
  # The record's fields an `Issue` webhook delivery carries, which a later read should find unchanged.
  @webhook_fields [:issue_identifier, :phase, :title, :labels, :priority, :assignee, :url]

  @type outcome :: :updated | :unchanged | :stale

  @typedoc """
  What `observe_delivery/2` did with a delivery: an observation's outcome, `:unrouted` (no repo
  takes the ticket), `:removed` (a record marked removed), `:no_record` (a removal of a ticket with
  no record) or `:error` (the store refused it, or the observation crashed or timed out).
  """
  @type delivery_outcome :: outcome() | :unrouted | :removed | :no_record | :error

  @typedoc "How many observations had each outcome."
  @type counts :: %{
          updated: non_neg_integer(),
          unchanged: non_neg_integer(),
          stale: non_neg_integer(),
          errors: non_neg_integer()
        }

  @typedoc "A read that changed fields a webhook should have brought first."
  @type poll_first :: %{
          identifier: String.t() | nil,
          fields: [atom()],
          source: TicketState.observation_source(),
          at: DateTime.t()
        }

  @type compare :: %{webhook_first: non_neg_integer(), poll_first: non_neg_integer(), poll_first_recent: [poll_first()]}

  @type summary :: %{
          updated: non_neg_integer(),
          unchanged: non_neg_integer(),
          stale: non_neg_integer(),
          errors: non_neg_integer(),
          compare: compare()
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
  - `:source` — the read it came from (`t:SymphonyElixir.TicketState.observation_source/0`),
    defaulting to `:poll`
  - `:terminal_states` — the states whose blockers no longer block, defaulting to the repo's
    `tracker.terminal_states`
  - `:compare` — whether a read that changes a webhook field counts as "poll first", defaulting to
    `linear.webhooks.enabled`

  Returns `{:ok, :updated}` when the record changed and was written, `{:ok, :unchanged}` when it
  already held what the issue says, `{:ok, :stale}` when the issue is older than the record (it is
  dropped), and `{:error, reason}` when the store refused the read or the write.
  """
  @spec observe(String.t(), Issue.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def observe(repo_key, %Issue{id: issue_id} = issue, opts \\ []) when is_binary(issue_id) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    source = Keyword.get(opts, :source, :poll)
    issue = %{issue | blocked_by: open_blockers(issue, repo_key, opts)}

    result =
      with {:ok, stored} <- read(repo_key, issue_id) do
        record = stored || TicketState.new(repo_key, issue_id)

        case TicketState.observe(record, issue, now, source) do
          {_record, :stale} ->
            {:ok, :stale}

          {_record, :unchanged} ->
            compare(source, stored, stored, now, opts)
            {:ok, :unchanged}

          {observed, :changed} ->
            write_and_compare(stored, observed, source, now, opts)
        end
      end

    count(result)
    result
  end

  @doc """
  Observes what a verified Linear webhook delivery says (`SymphonyElixir.Linear.Webhook.parse/1`):
  an `Issue` create or update goes through `observe/3` with `source: :webhook`, under the repo the
  ticket routes to (as `observe_routed/2` routes), and an `Issue` remove marks the ticket's record
  in every configured repo removed. Any other delivery is not observed, and gives nil.

  The work runs in a task bounded by `:timeout_ms` (default two seconds, well under the five Linear
  waits for an answer), so a crash or a hang is logged and returned as `:error`, never raised.
  `opts`: `:repos`, `:timeout_ms`, and those of `observe/3`.
  """
  @spec observe_delivery(Webhook.parsed(), keyword()) :: delivery_outcome() | nil
  def observe_delivery(parsed, opts \\ []) do
    if observed_delivery?(parsed), do: bounded(parsed, opts)
  end

  @doc """
  Observes every issue of `issues` for `repo_key` (see `observe/3`), and returns how many had each
  outcome. A store error is logged with the issue it was for and counted under `errors`; it never
  stops the others.
  """
  @spec observe_all(String.t(), [Issue.t()], keyword()) :: counts()
  def observe_all(repo_key, issues, opts \\ []) when is_list(issues) do
    opts = Keyword.put_new_lazy(opts, :terminal_states, fn -> terminal_states(repo_key) end)

    Enum.reduce(issues, empty_summary(), fn issue, acc ->
      case observe_issue(repo_key, issue, opts) do
        {:ok, outcome} ->
          Map.update!(acc, outcome, &(&1 + 1))

        {:error, reason} ->
          log_failure(repo_key, issue, reason)
          Map.update!(acc, :errors, &(&1 + 1))
      end
    end)
  end

  @doc """
  Observes `issues` that may belong to several repos, such as a by-id read, which carries no repo
  key. Each issue goes to the repo it routes to (`SymphonyElixir.Routing.Resolver.with_repo_key/2`;
  an issue that already has a key keeps it), and an issue no repo takes is skipped. `opts`: `:repos`,
  defaulting to the configured repos, and those of `observe/3`. Returns the outcomes across repos.
  """
  @spec observe_routed([Issue.t()], keyword()) :: counts()
  def observe_routed(issues, opts \\ []) when is_list(issues) do
    {repos, opts} = Keyword.pop_lazy(opts, :repos, &configured_repos/0)

    issues
    |> Enum.flat_map(&route(&1, repos))
    |> Enum.group_by(fn {repo_key, _issue} -> repo_key end, fn {_repo_key, issue} -> issue end)
    |> Enum.reduce(empty_summary(), fn {repo_key, repo_issues}, acc ->
      Map.merge(acc, observe_all(repo_key, repo_issues, opts), fn _outcome, left, right -> left + right end)
    end)
  end

  @doc """
  How many observations had each outcome since Symphony started, and the comparison with the
  webhook: how many reads found the webhook first, how many the poll first, and the last ten poll
  first, newest first.
  """
  @spec summary() :: summary()
  def summary do
    entries = :ets.tab2list(@table)
    poll_first = lookup(entries, :poll_first, 0)

    counts = Map.new([:errors | @outcomes], &{&1, lookup(entries, &1, 0)})

    Map.put(counts, :compare, %{
      webhook_first: lookup(entries, :webhook_first, 0),
      poll_first: poll_first,
      poll_first_recent: for(n <- poll_first..max(poll_first - @recent_limit + 1, 1)//-1, {_key, entry} <- [List.keyfind(entries, {:poll_first, n}, 0)], do: entry)
    })
  rescue
    ArgumentError -> Map.put(empty_summary(), :compare, %{webhook_first: 0, poll_first: 0, poll_first_recent: []})
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

  defp observed_delivery?({:issue, _action, %Issue{}, _updated_at}), do: true
  defp observed_delivery?({:issue_removed, issue_id, _identifier}), do: is_binary(issue_id)
  defp observed_delivery?(_parsed), do: false

  defp write_and_compare(stored, observed, source, now, opts) do
    with {:ok, :updated} = written <- write(stored, observed) do
      compare(source, stored, observed, now, opts)
      written
    end
  end

  # A read compares with the webhook only when it isn't one, and only for a ticket that had a record.
  defp compare(:webhook, _stored, _observed, _now, _opts), do: :ok
  defp compare(_source, nil, _observed, _now, _opts), do: :ok

  defp compare(source, stored, observed, now, opts) do
    stored = TicketState.normalize(stored)
    changed = Enum.reject(@webhook_fields, &(Map.get(stored, &1) == Map.get(observed, &1)))

    cond do
      changed != [] -> if(compare?(opts), do: poll_first(observed, changed, source, now), else: :ok)
      stored.observed_from == :webhook -> webhook_first(stored)
      true -> :ok
    end
  end

  defp compare?(opts), do: Keyword.get_lazy(opts, :compare, fn -> Webhook.settings().enabled end)

  defp poll_first(observed, fields, source, now) do
    seq = :ets.update_counter(@table, :poll_first, 1, {:poll_first, 0})
    :ets.insert(@table, {{:poll_first, seq}, %{identifier: observed.issue_identifier, fields: fields, source: source, at: now}})
    :ets.delete(@table, {:poll_first, seq - @recent_limit})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Once for each change a webhook brought: the record's `observed_at` names that change.
  defp webhook_first(stored) do
    key = {:confirmed, stored.repo_key, stored.issue_id}

    if :ets.lookup(@table, key) != [{key, stored.observed_at}] do
      :ets.insert(@table, {key, stored.observed_at})
      bump(:webhook_first)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp bounded(parsed, opts) do
    {observe_fun, opts} = Keyword.pop(opts, :observe_fun, &observe_parsed/2)
    {timeout_ms, opts} = Keyword.pop(opts, :timeout_ms, @delivery_timeout_ms)
    task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> observe_fun.(parsed, opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        delivery_failed(parsed, {:exit, reason})

      nil ->
        delivery_failed(parsed, :timeout)
    end
  end

  defp delivery_failed(parsed, reason) do
    Logger.warning("Linear webhook observation failed for issue_id=#{parsed_issue_id(parsed)}: #{inspect(reason)}")
    bump(:errors)
    :error
  end

  defp parsed_issue_id({:issue, _action, %Issue{id: id}, _updated_at}), do: id
  defp parsed_issue_id({:issue_removed, id, _identifier}), do: id

  defp observe_parsed({:issue, _action, issue, _updated_at}, opts) do
    {repos, opts} = Keyword.pop_lazy(opts, :repos, &configured_repos/0)

    case route(issue, repos) do
      [{repo_key, routed}] -> observed_outcome(repo_key, routed, observe(repo_key, routed, Keyword.put(opts, :source, :webhook)))
      [] -> :unrouted
    end
  end

  defp observe_parsed({:issue_removed, issue_id, _identifier}, opts) do
    {repos, opts} = Keyword.pop_lazy(opts, :repos, &configured_repos/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    outcomes = for %{name: repo_key} when is_binary(repo_key) <- repos, do: mark_removed(repo_key, issue_id, now)

    cond do
      :error in outcomes -> :error
      :removed in outcomes -> :removed
      true -> :no_record
    end
  end

  defp observed_outcome(_repo_key, _issue, {:ok, outcome}), do: outcome

  defp observed_outcome(repo_key, issue, {:error, reason}) do
    log_failure(repo_key, issue, reason)
    :error
  end

  defp mark_removed(repo_key, issue_id, now) do
    with {:ok, stored} when not is_nil(stored) <- read(repo_key, issue_id),
         removed = TicketState.mark_removed(stored, now),
         :ok <- RunStore.update_ticket_state(repo_key, issue_id, Map.take(removed, [:removed_at, :updated_at])) do
      :removed
    else
      {:ok, nil} -> :no_record
      {:error, reason} -> removal_failed(repo_key, issue_id, reason)
    end
  end

  defp removal_failed(repo_key, issue_id, reason) do
    Logger.warning("Ticket removal failed for issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(reason)}")
    bump(:errors)
    :error
  end

  defp log_failure(repo_key, issue, reason) do
    Logger.warning("Ticket observation failed for issue_id=#{issue_id(issue)} issue_identifier=#{identifier(issue)} repo_key=#{repo_key}: #{inspect(reason)}")
  end

  defp lookup(entries, key, default) do
    case List.keyfind(entries, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  defp route(%Issue{} = issue, repos) do
    case Resolver.with_repo_key(issue, repos) do
      %Issue{repo_key: repo_key} = routed when is_binary(repo_key) and repo_key != "" -> [{repo_key, routed}]
      _unrouted -> []
    end
  end

  defp route(_issue, _repos), do: []

  defp configured_repos do
    case Config.repos() do
      {:ok, repos} -> repos
      {:error, _reason} -> []
    end
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
