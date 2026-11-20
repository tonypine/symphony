defmodule SymphonyElixir.TicketChecks do
  @moduledoc """
  The checks of a groomed ticket's plan (`SymphonyElixir.TicketPlan`) and where each stands.

  The checks are the newest plan's: a check a newer version dropped is no longer listed, and one it
  kept, by its `id`, keeps what was recorded for it. A check is `:proved` once a `check.proved`
  names it, on any head: a proof recorded before the branch's last change still counts. It is
  `:waived` when no proof names it and a `check.waived` does, and `:open` otherwise.

  `prove/4` and `waive/4` record those events, and refuse an id the plan does not hold
  (`{:unknown_check, id}`), so nothing is ever proved that the plan does not ask for. A proof is
  recorded once per check and head: a second one on the same head returns the first.

  A check that changes state is shown in Linear at once: the ticket's description is projected
  again (`SymphonyElixir.TicketProjection`).

  Every read takes the ticket's issue id or the events a caller already holds, as
  `SymphonyElixir.TicketPlan`'s do.
  """

  alias SymphonyElixir.{RunStore, TicketEvents, TicketPlan, TicketProjection}
  alias SymphonyElixir.TicketEvents.Event

  @types ["plan.written", "check.proved", "check.waived"]

  @typedoc """
  A check of the plan (`id`, `kind`, `statement`, `proof`, and a `qa` check's `state`, `action`,
  `expect`, `size` and `story`, which here sit under the keys the plan gives them but for `state`:
  the app state a `qa` check needs is `needs`), with where it stands (`state`), the newest proof
  (`proved_by`: how, the test, the evidence event, the details, and the proof's event, time, head
  and run) and the waiver (`waived`: the reason, and the waiver's event and time).
  """
  @type check :: %{
          required(:id) => String.t(),
          required(:kind) => String.t(),
          required(:statement) => String.t(),
          required(:proof) => String.t(),
          required(:state) => :open | :proved | :waived,
          required(:proved_by) => map() | nil,
          required(:waived) => map() | nil,
          optional(atom()) => term()
        }

  @doc "The current plan's checks, in the plan's order, each with where it stands. None for a ticket that is not groomed."
  @spec list(TicketPlan.ticket()) :: [check()]
  def list(ticket) do
    events = events(ticket)

    case TicketPlan.current(events) do
      nil -> []
      plan -> Enum.map(plan.checks, &check(&1, newest(events, "check.proved", &1.id), newest(events, "check.waived", &1.id)))
    end
  end

  @doc "The checks that are still open. `opts[:proof]` keeps the ones proved in one of those ways (`test`, `qa`, `design`, `attached`)."
  @spec open(TicketPlan.ticket(), keyword()) :: [check()]
  def open(ticket, opts \\ []) do
    proofs = Keyword.get(opts, :proof)
    for %{state: :open} = check <- list(ticket), is_nil(proofs) or check.proof in List.wrap(proofs), do: check
  end

  @doc """
  Records that a check of the current plan of `repo_key`'s ticket `issue_id` is proved: `proof` is
  the `check.proved` payload (`check_id`, `by`, and optionally `test`, `evidence`, `details`) and
  `opts` are `SymphonyElixir.TicketEvents.record/5`'s. With a `head_sha:` the proof is recorded once
  for that check on that head. An id the plan does not hold is refused and nothing is written.
  """
  @spec prove(String.t() | nil, String.t(), map(), keyword()) ::
          {:ok, Event.t()} | {:error, {:unknown_check, String.t()} | term()}
  def prove(repo_key, issue_id, proof, opts \\ []) when is_binary(issue_id) and is_map(proof) do
    with {:ok, check_id} <- known(issue_id, Map.get(proof, :check_id, Map.get(proof, "check_id"))),
         opts = Keyword.put_new(opts, :idempotency, proof_key(check_id, Keyword.get(opts, :head_sha))),
         {:ok, event} <- TicketEvents.record(repo_key, issue_id, "check.proved", proof, opts) do
      TicketProjection.changed(repo_key, issue_id)
      {:ok, event}
    end
  end

  @doc "Records that nobody has to prove the check `check_id` of `repo_key`'s ticket `issue_id` any more, and why. An id the plan does not hold is refused."
  @spec waive(String.t() | nil, String.t(), String.t(), String.t()) :: {:ok, Event.t()} | {:error, term()}
  def waive(repo_key, issue_id, check_id, reason) when is_binary(issue_id) do
    with {:ok, check_id} <- known(issue_id, check_id),
         {:ok, event} <- TicketEvents.record(repo_key, issue_id, "check.waived", %{check_id: check_id, reason: reason}) do
      TicketProjection.changed(repo_key, issue_id)
      {:ok, event}
    end
  end

  defp known(issue_id, check_id) do
    if Enum.any?(list(issue_id), &(&1.id == check_id)), do: {:ok, check_id}, else: {:error, {:unknown_check, check_id}}
  end

  defp proof_key(check_id, head) when is_binary(head) and head != "", do: "check.proved:#{check_id}:#{head}"
  defp proof_key(_check_id, _head), do: nil

  defp check(check, proof, waiver) do
    check
    |> Map.delete(:state)
    |> Map.merge(%{state: state(proof, waiver), proved_by: proved_by(proof), waived: waived(waiver)})
    |> put_present(:needs, Map.get(check, :state))
  end

  defp state(%Event{}, _waiver), do: :proved
  defp state(nil, %Event{}), do: :waived
  defp state(nil, nil), do: :open

  defp proved_by(nil), do: nil

  defp proved_by(%Event{payload: payload} = event) do
    %{
      by: field(payload, :by),
      test: field(payload, :test),
      evidence: field(payload, :evidence),
      details: field(payload, :details),
      event_id: event.id,
      at: event.at,
      head: event.head_sha,
      run_id: event.run_id
    }
  end

  defp waived(nil), do: nil
  defp waived(%Event{payload: payload} = event), do: %{reason: field(payload, :reason), event_id: event.id, at: event.at}

  defp newest(events, type, check_id) do
    events |> Enum.filter(&(&1.type == type and field(&1.payload, :check_id) == check_id)) |> List.last()
  end

  defp events(issue_id) when is_binary(issue_id), do: issue_id |> RunStore.list_ticket_events(types: @types) |> List.wrap() |> events()
  defp events(events) when is_list(events), do: Enum.filter(events, &match?(%Event{}, &1))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # A payload validated on write has atom keys; a stored record may have kept strings.
  defp field(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
