defmodule SymphonyElixir.ChecksHold do
  @moduledoc """
  The bound on a groomed ticket whose handoff keeps being refused for open checks.

  A groomed ticket is not handed off while a check of its plan that a test or an attachment proves
  is open (`SymphonyElixir.TicketJourney.unproved/1`): the step list's `symphony:checks` step fails,
  and so does the handoff itself. A check nobody can prove that way would send the ticket around
  for good, unless the Conductor waives it. So each refusal is recorded (`refused/4`, a note under
  `checks_unproved:<run>:…`, which also tells the next run which checks it owes), and when the
  ticket's two newest coding runs were both refused and nothing changed in between (no plan
  version, no waiver), the person is asked (`question/3`): waive the checks and hand the ticket
  off, send it back for them, or cancel it. "Waive them and hand off" carries the waivers on its
  move (`SymphonyElixir.DecisionMove`), so picking it records each `check.waived` and moves the
  ticket.
  """

  alias SymphonyElixir.Conductor.Facts
  alias SymphonyElixir.{TicketChecks, TicketEvents, TicketJourney}
  alias SymphonyElixir.TicketEvents.Event

  @key "checks_unproved:"
  @coding_kinds ["implementation", "rework"]
  @changes ["plan.written", "check.waived"]
  @waived_by_person "The person waived it: two runs in a row could not prove it."

  @typedoc "What a refusal is recorded with: the run it was refused in, and that run's head when known."
  @type run :: %{optional(:run_id) => String.t() | nil, optional(:head) => String.t() | nil}

  @doc """
  Records that the handoff of `repo_key`'s ticket `issue_id` was refused for the open `checks` in
  `run`, once per run, head and set of checks, and answers what follows: `:ask` when the ticket's
  two newest coding runs were both refused and no plan version or waiver came in between, so the
  person decides (`question/3`); else `:retry`, and the run goes on to prove them.
  """
  @spec refused(String.t() | nil, String.t(), [TicketChecks.check()], run()) :: :retry | :ask
  def refused(repo_key, issue_id, checks, run) when is_binary(issue_id) do
    run_id = Map.get(run, :run_id)
    ids = Enum.map_join(checks, ",", & &1.id)
    note = %{text: String.slice(TicketJourney.unproved_message(checks), 0, 4_000)}
    _ = TicketEvents.record(repo_key, issue_id, "note", note, run_id: run_id, idempotency: "#{@key}#{run_id}:#{Map.get(run, :head)}:#{ids}")
    if looping?(Facts.events(issue_id)), do: :ask, else: :retry
  end

  @doc """
  Whether the ticket whose `events` these are (oldest first) goes around on its open checks: its
  two newest coding runs were both refused the handoff, and since the first of those refusals no
  plan version was written and no check waived.
  """
  @spec looping?([Event.t()]) :: boolean()
  def looping?(events) when is_list(events) do
    coding = for %Event{type: "run.started", payload: %{run_kind: kind}} = run <- events, kind in @coding_kinds, do: run.run_id
    refusals = Enum.filter(events, &refusal?/1)

    with [earlier, _newest] = last_two <- Enum.take(coding, -2),
         true <- Enum.all?(last_two, fn run_id -> Enum.any?(refusals, &(&1.run_id == run_id)) end),
         %Event{seq: first} <- Enum.find(refusals, &(&1.run_id == earlier)) do
      not Enum.any?(events, &(&1.type in @changes and &1.seq > first))
    else
      _not_twice -> false
    end
  end

  defp refusal?(%Event{type: "note", idempotency: @key <> _rest}), do: true
  defp refusal?(_event), do: false

  @doc """
  The question to the person about the ticket `name`, held on the open `checks`: waive them and
  move it to `to` (the state a handoff moves to), send it back for the checks, or cancel it.
  """
  @spec question(String.t(), [TicketChecks.check()], String.t()) :: map()
  def question(name, checks, to) do
    listed = Enum.map_join(checks, "; ", &"[#{&1.id}] #{one_line(&1.statement)} (proof: #{&1.proof})")
    waivers = Enum.map(checks, &%{check_id: &1.id, reason: @waived_by_person})

    %{
      title: String.slice("#{name}: checks of its plan are still not proved", 0, 120),
      question: "Two runs in a row could not pass #{name} on to review, because these checks of its plan are still not proved: #{Facts.fit(listed, 1_500)}. What should happen?",
      why: "A check that a test or an attached file proves must be proved, or waived, before #{name} goes to review. The runs did not prove these, and nobody waived them.",
      if_unanswered: "#{name} stays paused and nobody works on it.",
      recommendation_reason: "The checks are part of the plan. Waive them only when you know they cannot be proved this way.",
      options: [
        %{label: "Send it back for the checks", effect: "A run tries once more to prove them.", recommended: true},
        %{label: "Waive them and pass it on", effect: "Symphony records each check as waived and moves #{name} to #{to}.", recommended: false, move: %{to: to, waive: waivers}},
        %{label: "Cancel the ticket", effect: "#{name} is cancelled.", recommended: false, move: %{to: "Canceled"}}
      ]
    }
  end

  defp one_line(text), do: text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()
end
