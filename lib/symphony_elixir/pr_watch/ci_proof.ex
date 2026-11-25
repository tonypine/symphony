defmodule SymphonyElixir.PrWatch.CiProof do
  @moduledoc """
  The proof of the checks of a groomed ticket's plan that the pull request's own CI run proves
  (`proof: ci`, `SymphonyElixir.TicketJourney.owed_by_ci/1`), read on the PR's head in Merging.

  Such a check can only be proved once the pull request exists, so it never holds the handoff; it
  holds the merge. `fact/2` says where its proof stands on the head, as the decision table reads it
  (`SymphonyElixir.PrDecision.Facts`' `ci_proof`):

    * `:provable` – an open check names a CI check (`ci_check`) that passed on the head:
      `prove/3` records it as proved (`by: ci`) with no run;
    * `:running` – nothing is provable yet and checks still run on the head (or none reported);
    * `:turn` – every check on the head finished and an open check is left that only a run can
      read the results for (it names no CI check, or one the head does not show passed), and no
      landing run had its turn on the head: one run is given it (`SymphonyElixir.PrDecision` R28d);
    * `:spent` – that run had its turn on the head and the check is still open: the ticket goes
      to Rework with the run's reason (`reason/2`), and the turn is not given again on the head.

  Receiving the head's checks is the trigger: no timer reads them again.
  """

  alias SymphonyElixir.{RunStore, TicketChecks, TicketJourney}
  alias SymphonyElixir.TicketEvents.Event

  @typedoc "Where the proof of the plan's CI checks stands on the head."
  @type fact :: :none | :provable | :running | :turn | :spent

  @doc "Where the proof of the open `proof: ci` checks of the ticket `issue_id` stands on `read`'s head (see the moduledoc)."
  @spec fact(String.t(), map() | nil) :: fact()
  def fact(issue_id, read) when is_binary(issue_id) do
    checks = TicketJourney.owed_by_ci(issue_id)

    cond do
      checks == [] -> :none
      provable(checks, read) != [] -> :provable
      not finished?(read) -> :running
      turn_run(issue_id, head(read)) -> :spent
      true -> :turn
    end
  end

  @doc "The checks of `checks` that name a CI check that passed on `read`'s head, with no failed or running check of that name."
  @spec provable([TicketChecks.check()], map() | nil) :: [TicketChecks.check()]
  def provable(checks, read) do
    passed = passed(read)
    for %{ci_check: name} = check <- checks, is_binary(name), name in passed, do: check
  end

  @doc """
  Records each open `proof: ci` check of `repo_key`'s ticket `issue_id` that `read`'s head proves
  (`provable/2`) as proved by CI, naming the CI check and the head, once per check and head. The
  number of checks proved, or the first error.
  """
  @spec prove(String.t() | nil, String.t(), map() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def prove(repo_key, issue_id, read) when is_binary(issue_id) do
    head = head(read)

    results =
      for check <- issue_id |> TicketJourney.owed_by_ci() |> provable(read) do
        TicketChecks.prove(repo_key, issue_id, %{check_id: check.id, by: "ci", details: "The CI check `#{check.ci_check}` passed on #{short(head)}."}, head_sha: head)
      end

    Enum.find(results, {:ok, length(results)}, &match?({:error, _reason}, &1))
  end

  @doc "The id of the landing run that had its turn on `head` of the ticket `issue_id`, or nil."
  @spec turn_run(String.t(), String.t() | nil) :: String.t() | nil
  def turn_run(issue_id, head) when is_binary(head) do
    Enum.find_value(events(issue_id, "run.started"), fn %Event{payload: payload} = event ->
      if field(payload, :run_kind) == "landing" and (field(payload, :head) || event.head_sha) == head,
        do: field(payload, :run_id)
    end)
  end

  def turn_run(_issue_id, _head), do: nil

  @doc """
  Why the ticket `issue_id` goes back to Rework from `head`: the open `proof: ci` checks and the
  newest note the run that had the turn there left, as the rework run's instructions.
  """
  @spec reason(String.t(), String.t() | nil) :: String.t()
  def reason(issue_id, head) do
    listed = issue_id |> TicketJourney.owed_by_ci() |> Enum.map_join("; ", &"[#{&1.id}] #{one_line(&1.statement)}")
    base = "The run that read the pull request's checks on #{short(head)} did not prove these checks of the plan: #{listed}."

    case note(issue_id, turn_run(issue_id, head)) do
      nil -> base
      text -> base <> " The run said: " <> String.slice(one_line(text), 0, 1_500)
    end
  end

  defp note(_issue_id, nil), do: nil

  defp note(issue_id, run_id) do
    issue_id |> events("note") |> Enum.filter(&(&1.run_id == run_id)) |> List.last() |> note_text()
  end

  defp note_text(%Event{payload: payload}), do: field(payload, :text)
  defp note_text(nil), do: nil

  # The names of the checks that passed on the head: reported there, and neither failed nor running.
  defp passed(read) when is_map(read) do
    failed = for %{name: name} <- Map.get(read, :failed_checks, []), do: name
    Map.get(read, :check_names, []) -- (failed ++ Map.get(read, :running_checks, []))
  end

  defp passed(_read), do: []

  # Every check on the head finished: CI is no longer pending and nothing runs.
  defp finished?(read) when is_map(read), do: Map.get(read, :ci) in [:green, :none] and Map.get(read, :running_checks, []) == []
  defp finished?(_read), do: false

  defp head(read) when is_map(read), do: Map.get(read, :head_sha)
  defp head(_read), do: nil

  defp short(head) when is_binary(head), do: "the head #{String.slice(head, 0, 8)}"
  defp short(_head), do: "the head"

  defp events(issue_id, type), do: issue_id |> RunStore.list_ticket_events(types: [type]) |> List.wrap() |> Enum.filter(&match?(%Event{type: ^type}, &1))

  defp one_line(text), do: text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

  # A payload validated on write has atom keys; a stored record may have kept strings.
  defp field(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
