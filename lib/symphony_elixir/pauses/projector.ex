defmodule SymphonyElixir.Pauses.Projector do
  @moduledoc """
  Renders a ticket's pause (`SymphonyElixir.Pauses`) and questions (`SymphonyElixir.Questions`)
  into Linear: its two machine labels and the Decisions section of its description
  (`SymphonyElixir.Decisions`). The record is the truth and Linear only shows it.

  `desired/1` says what Linear should show, from the record alone:

    * `Needs Decision` while a question on the ticket is open;
    * `Blocked` while the pause has a reason that is not a question: a ticket, a person or the
      environment. A `:build` reason, the wait for a Symphony update (`SymphonyElixir.UpdateHold`),
      shows no label, as it showed none before the projector;
    * the Decisions section's entries (`Decisions.render_from_questions/1`) and their hash.

  `apply/2` writes only what differs from what it last applied, which the record keeps
  (`projected`: the labels and the section's hash). A record it never projected compares its labels
  with the ones the last observation of the ticket in Linear saw. The section is written into the
  description read right before the write (`Decisions.put/2`), so a person's text since stays, and
  an entry already there is never written twice. A write Linear refuses leaves the record as it is,
  keeps what did land in `projected`, and marks the projection pending (`pending_projection`,
  `:pause`): the reconciler applies it again (`SymphonyElixir.TicketObservation.reconcile_all/3`).
  A second apply of the same record writes nothing.

  `project_now/2` is called by `Pauses` and `Questions` after each write that changed the record,
  and by `Decisions.record/3` once a decision is stored.

  The projector owns these writes while the internal flag `:pause_projector` is on (`owns?/0`,
  default on): the holds' own label writes (`SymphonyElixir.Hold`, `SymphonyElixir.NeedsDecisionHold`)
  and the decision store's section write are skipped then. The holds themselves are still set and
  cleared until they are retired.
  """

  import Kernel, except: [apply: 2]

  require Logger

  alias SymphonyElixir.{Decisions, RunStore, TicketSignals, TicketState, Tracker}

  @blocked "Blocked"
  @needs_decision "Needs Decision"
  @labels [@blocked, @needs_decision]
  # Reasons that show no Blocked label: a question shows Needs Decision, an update's wait shows none.
  @unlabelled_kinds [:question, :build]

  @typedoc "What Linear should show for a record: its machine labels, the section's entries and their hash."
  @type desired :: %{labels: [String.t()], entries: [Decisions.entry()], section: String.t() | nil}

  @typedoc """
  `tracker:` (default `SymphonyElixir.Tracker`), `store:` (default `SymphonyElixir.RunStore`) and
  `force: true`, which compares with the labels Linear was last seen with instead of what was last
  applied, and writes the section again, as a repair of a ticket whose labels drifted does.
  """
  @type opt :: {:tracker, module()} | {:store, module()} | {:force, boolean()}

  @doc "Whether the projector owns the labels and the Decisions section: the internal flag `:pause_projector`, default on."
  @spec owns?() :: boolean()
  def owns?, do: Application.get_env(:symphony_elixir, :pause_projector, true) == true

  @doc "The machine labels the projector writes."
  @spec labels() :: [String.t()]
  def labels, do: @labels

  @doc """
  What Linear should show for `record`: its labels, sorted (`Needs Decision` while a question is
  open, `Blocked` while a reason other than a question or an update's wait pauses it), and the
  Decisions section's entries with their hash (nil when there are none). Pure.
  """
  @spec desired(map()) :: desired()
  def desired(record) do
    record = TicketState.normalize(record)
    reasons = (record.pause && record.pause.reasons) || []

    labels =
      [
        {@blocked, Enum.any?(reasons, &(&1.kind not in @unlabelled_kinds))},
        {@needs_decision, Enum.any?(record.questions, &(&1.state == :open))}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    entries = Decisions.render_from_questions(record)
    %{labels: labels, entries: entries, section: hash(entries)}
  end

  @doc """
  Writes what `desired/1` gives for `record` and differs from what was last applied: each label to
  set or clear, and the section when its hash changed. Records what landed in `projected`; a write
  that fails marks the projection pending and is returned.
  """
  @spec apply(map(), [opt()]) :: :ok | {:error, term()}
  def apply(record, opts \\ []) do
    record = TicketState.normalize(record)
    tracker = Keyword.get(opts, :tracker, Tracker)
    desired = desired(record)
    last = last_applied(record, Keyword.get(opts, :force) == true)

    {labels, label_errors} = apply_labels(tracker, record.issue_id, last.labels, desired.labels)
    {section, section_errors} = apply_section(tracker, record.issue_id, last.section, desired)
    remember(record, %{labels: labels, section: section}, Keyword.get(opts, :store, RunStore))

    case label_errors ++ section_errors do
      [] ->
        :ok

      [reason | _rest] ->
        Logger.warning("Failed to project the pause of issue_id=#{record.issue_id}: #{inspect(reason)}")
        TicketSignals.mark_projection(record.repo_key, record.issue_id, :pause, reason)
        {:error, reason}
    end
  end

  @doc """
  Applies the projection of `ticket`'s record as the store holds it now (`apply/2`), when the
  projector owns it (`owns?/0`). A ticket with no record has nothing to project.
  """
  @spec project_now({:ticket, String.t(), String.t()}, [opt()]) :: :ok | {:error, term()}
  def project_now({:ticket, repo_key, issue_id}, opts \\ []) do
    if owns?() do
      case Keyword.get(opts, :store, RunStore).get_ticket_state(repo_key, issue_id) do
        %{} = record -> apply(record, opts)
        nil -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  # Each label that differs, set or cleared; the labels that landed, sorted, and the errors.
  defp apply_labels(tracker, issue_id, last, desired) do
    {applied, errors} = Enum.reduce(@labels, {last, []}, &apply_label(tracker, issue_id, desired, &1, &2))
    {Enum.sort(applied), Enum.reverse(errors)}
  end

  defp apply_label(tracker, id, desired, name, {applied, errors} = acc) do
    case {name in desired, name in applied} do
      {same, same} -> acc
      {true, false} -> label_write(fn -> tracker.set_machine_label(id, name) end, {applied, [name | applied]}, errors)
      {false, true} -> label_write(fn -> tracker.clear_machine_label(id, name) end, {applied, List.delete(applied, name)}, errors)
    end
  end

  # The labels as they were and as they are once the write lands.
  defp label_write(write, {applied, landed}, errors) do
    case call(write) do
      :ok -> {landed, errors}
      {:error, reason} -> {applied, [reason | errors]}
    end
  end

  defp apply_section(_tracker, _issue_id, last, %{section: section}) when section in [nil, last], do: {last, []}

  defp apply_section(tracker, issue_id, last, %{entries: entries, section: section}) do
    with {:ok, description} <- call(fn -> tracker.fetch_issue_description(issue_id) end),
         {:ok, updated} <- Decisions.put(description, entries),
         :ok <- write_description(tracker, issue_id, description || "", updated) do
      {section, []}
    else
      {:error, reason} -> {last, [reason]}
    end
  end

  defp write_description(_tracker, _issue_id, description, description), do: :ok
  defp write_description(tracker, issue_id, _description, updated), do: call(fn -> tracker.update_issue_description(issue_id, updated) end)

  defp remember(%{projected: projected}, projected, _store), do: :ok

  defp remember(record, projected, store) do
    with {:error, reason} <- store.update_ticket_state(record.repo_key, record.issue_id, %{projected: projected}) do
      Logger.warning("Failed to record the pause projection of issue_id=#{record.issue_id}: #{inspect(reason)}")
    end
  end

  defp last_applied(%{projected: %{} = projected}, false = _force?), do: projected
  defp last_applied(record, _force?), do: %{labels: observed_labels(record), section: nil}

  # The machine labels the last observation of the ticket in Linear saw.
  defp observed_labels(record) do
    observed = MapSet.new(record.labels, &String.downcase/1)
    Enum.filter(@labels, &MapSet.member?(observed, String.downcase(&1)))
  end

  defp hash([]), do: nil

  defp hash(entries) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(entries, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # A tracker call that raises is a write that failed.
  defp call(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _value} = ok -> ok
      {:error, _reason} = error -> error
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
