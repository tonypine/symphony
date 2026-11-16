defmodule SymphonyElixir.PrWatch.StalledRun do
  @moduledoc """
  No silent state for a decision that needs a run. The PR and CI watcher's decisions that a run
  carries out (`dispatch`: the reviewer, QA, a rework run; `ci_fix`: a CI Fix run; `land_agent`: the
  landing run) are the orchestrator's to start. A record the watcher announces is a dispatch cycle at
  once (`SymphonyElixir.PrWatch.Repo`), so a run due on a ticket starts within seconds while a slot is
  free and nothing pauses dispatch.

  When it still has not started once the silent-wait detector lists the ticket
  (`SymphonyElixir.PrWatch.SilentWait`: two poll cycles with no run), and a dispatch pass found the
  ticket neither started nor waiting for a slot nor passed over for a reason of its own, no run can
  start it: `hold/3` pauses it with a reason the Director may release (`:environment`, releasable),
  which says which run and why, and which the Inbox lists among the tickets to unblock
  (`SymphonyElixir.Inbox.Item.from_pause/2`). The Director's Unblock releases it and the run starts.
  A new head on the PR lifts it too (`settle/3`): the decision it was set for no longer stands.
  """

  require Logger

  alias SymphonyElixir.Pauses
  alias SymphonyElixir.PrWatch.SilentWait

  @run_kinds [:dispatch, :ci_fix, :land_agent]
  @condition "run_not_started"
  @setter %{kind: :rule, name: "Run-not-started pause"}

  @doc "The watcher's decision kinds a run carries out, which the orchestrator starts."
  @spec run_kinds() :: [atom()]
  def run_kinds, do: @run_kinds

  @doc """
  Pauses `ticket` when the watcher's record of it (`watch`) holds a decision that needs a run and the
  silent-wait detector lists it: `:held` once the pause has its reason, `:none` when nothing is to
  hold. The caller has checked that no run, slot wait or skip of its own explains the ticket.
  `opts`: `:at`.
  """
  @spec hold(Pauses.subject(), map() | nil, keyword()) :: :held | :none
  def hold(ticket, watch, opts \\ []), do: do_hold(ticket, watch, opts)

  defp do_hold(ticket, %{decision: %{kind: kind} = decision} = watch, opts) when kind in @run_kinds do
    if SilentWait.listed?(Map.get(watch, :silent)) do
      text = "No run started: #{decision.rule} decided #{run_words(decision)}, and no run started on it for two poll cycles"
      waits_on = Map.reject(%{condition: @condition, head: Map.get(watch, :head_sha)}, fn {_field, value} -> is_nil(value) end)
      reason = %{kind: :environment, waits_on: waits_on, text: String.slice(text, 0, 300), releasable: true}

      case Pauses.set(ticket, reason, [set_by: @setter] ++ Keyword.take(opts, [:at])) do
        {:ok, _pause} ->
          Logger.warning("pr_watch.run_not_started ticket=#{inspect(ticket)} rule=#{decision.rule} action=#{kind} reason=#{inspect(decision.reason)}")
          :held

        {:error, reason} ->
          Logger.warning("Failed to pause a ticket whose run never started ticket=#{inspect(ticket)}: #{inspect(reason)}")
          :none
      end
    else
      :none
    end
  end

  defp do_hold(_ticket, _watch, _opts), do: :none

  @doc """
  Lifts the pause `hold/3` set on `ticket` once the watcher's newest record (`watch`) has another
  head than the one it was set on: `:lifted`, or `:kept` when there is nothing to lift. `record` is
  the ticket's state record, whose pause is read.
  """
  @spec settle(Pauses.subject(), map() | nil, map() | nil) :: :lifted | :kept
  def settle(ticket, %{pause: %{reasons: reasons}}, %{head_sha: head}) when is_binary(head) do
    if Enum.any?(reasons, &moved_on?(&1, head)) do
      _ = Pauses.clear_reasons(ticket, &reason?/1, by: @setter)
      :lifted
    else
      :kept
    end
  end

  def settle(_ticket, _record, _watch), do: :kept

  @doc "Whether a pause reason is the one `hold/3` sets."
  @spec reason?(map()) :: boolean()
  def reason?(%{kind: :environment, waits_on: %{condition: @condition}}), do: true
  def reason?(_reason), do: false

  defp moved_on?(%{waits_on: %{head: held_on}} = reason, head), do: reason?(reason) and held_on != head
  defp moved_on?(_reason, _head), do: false

  defp run_words(%{kind: :ci_fix, args: %{cause: :conflict}, reason: reason}), do: "a conflict fix run (#{reason})"
  defp run_words(%{kind: :ci_fix, reason: reason}), do: "a CI Fix run (#{reason})"
  defp run_words(%{kind: :land_agent, reason: reason}), do: "the landing run (#{reason})"
  defp run_words(%{reason: reason}), do: "a run (#{reason})"
end
