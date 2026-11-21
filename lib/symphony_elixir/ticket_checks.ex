defmodule SymphonyElixir.TicketChecks do
  @moduledoc """
  The checks of a groomed ticket's plan (`SymphonyElixir.TicketPlan`) and where each stands.

  The checks are the newest plan's: a check a newer version dropped is no longer listed, and one it
  kept, by its `id` and with the same `statement`, keeps what was recorded for it. A check whose
  statement a version changed, or that a version put (back) on the plan, starts unproved there:
  only the proofs and waivers recorded after that version count for it. An id is never given to a
  second check (`SymphonyElixir.TicketPlan.write/4`), so a new check never inherits an old one's
  proof. A check is `:proved` once such a `check.proved` names it, on any head: a proof recorded
  before the branch's last change still counts. It is `:waived` when no proof names it and a
  `check.waived` does, and `:open` otherwise.

  `prove/4` and `waive/5` record those events, and refuse an id the plan does not hold
  (`{:unknown_check, id}`), so nothing is ever proved that the plan does not ask for. An `outcome`
  check binds: `waive/5` refuses it (`:outcome_binds`) unless the person decided it. A proof is
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
  def list(ticket), do: for({check, _since, proof, waiver} <- standing(events(ticket)), do: check(check, proof, waiver))

  # Each check of the current plan with the plan version that last changed it (its statement, or
  # put it on the plan) and the newest proof and waiver recorded since that version.
  defp standing(events) do
    plans = events |> Enum.filter(&(&1.type == "plan.written")) |> Enum.reverse()

    case TicketPlan.current(events) do
      nil ->
        []

      plan ->
        for check <- plan.checks do
          since = changed_in(plans, check)
          later = events |> Enum.drop_while(&(&1.id != since.id)) |> Enum.drop(1)
          {check, field(since.payload, :version), newest(later, "check.proved", check.id), newest(later, "check.waived", check.id)}
        end
    end
  end

  # The oldest of the newest versions in a row that hold the check as it reads now.
  defp changed_in(plans, check) do
    plans |> Enum.take_while(&holds?(&1, check)) |> List.last()
  end

  defp holds?(%Event{payload: payload}, check) do
    Enum.any?(field(payload, :checks), &(field(&1, :id) == check.id and same?(field(&1, :statement), check.statement)))
  end

  defp same?(statement, other), do: String.trim(to_string(statement)) == String.trim(to_string(other))

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
    with {:ok, check_id, since} <- known(issue_id, Map.get(proof, :check_id, Map.get(proof, "check_id"))),
         opts = Keyword.put_new(opts, :idempotency, proof_key(check_id, since, Keyword.get(opts, :head_sha))),
         {:ok, event} <- TicketEvents.record(repo_key, issue_id, "check.proved", proof, opts) do
      TicketProjection.changed(repo_key, issue_id)
      {:ok, event}
    end
  end

  @doc """
  Records that nobody has to prove the check `check_id` of `repo_key`'s ticket `issue_id` any more,
  and why. An id the plan does not hold is refused (`{:unknown_check, id}`). So is an `outcome`
  check (`:outcome_binds`): the outcomes are what the person asked for, so only the person's own
  decision waives one (`by: :person`), never a turn or a rule.
  """
  @spec waive(String.t() | nil, String.t(), String.t(), String.t(), by: :person | :machine) ::
          {:ok, Event.t()} | {:error, term()}
  def waive(repo_key, issue_id, check_id, reason, opts \\ []) when is_binary(issue_id) do
    with {:ok, check_id, _since} <- known(issue_id, check_id),
         :ok <- waivable(issue_id, check_id, Keyword.get(opts, :by, :machine)),
         {:ok, event} <- TicketEvents.record(repo_key, issue_id, "check.waived", %{check_id: check_id, reason: reason}) do
      TicketProjection.changed(repo_key, issue_id)
      {:ok, event}
    end
  end

  defp waivable(_issue_id, _check_id, :person), do: :ok

  defp waivable(issue_id, check_id, _machine) do
    if Enum.any?(list(issue_id), &(&1.id == check_id and &1.kind == "outcome")), do: {:error, :outcome_binds}, else: :ok
  end

  # The check's id and the plan version that last changed it.
  defp known(issue_id, check_id) do
    case Enum.find(standing(events(issue_id)), fn {check, _since, _proof, _waiver} -> check.id == check_id end) do
      {_check, since, _proof, _waiver} -> {:ok, check_id, since}
      nil -> {:error, {:unknown_check, check_id}}
    end
  end

  # One proof per check, head and wording of the check: a check whose statement a later version
  # changed is proved again, on the same head too.
  defp proof_key(check_id, 1, head) when is_binary(head) and head != "", do: "check.proved:#{check_id}:#{head}"
  defp proof_key(check_id, since, head) when is_binary(head) and head != "", do: "check.proved:#{check_id}:v#{since}:#{head}"
  defp proof_key(_check_id, _since, _head), do: nil

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
