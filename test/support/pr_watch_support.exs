defmodule SymphonyElixir.PrWatchSupport do
  @moduledoc """
  Writes the PR and CI watcher's record of a ticket (`TicketState.pr_watch`) the way
  `SymphonyElixir.PrWatch.Repo` leaves it, for tests of what reads it: the orchestrator's dispatch
  gates read the decision, a CI Fix run's prompt reads the fix context, an agent's prompt reads the
  landing files.
  """

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.Attempts
  alias SymphonyElixir.{RunStore, TicketState}

  @doc """
  Writes the record of `issue_id` in `repo_key`. `attrs`: `:phase` (default `:code_review`),
  `:facts` (overrides), `:decision` (a kind such as `:dispatch` or `:wait`, or a full decision map),
  `:ci_failure`, `:pr_conflict`, `:attempts`, `:landing`, `:pr_url`, `:head_sha` and
  `:identifier`.
  """
  def put_watch!(repo_key, issue_id, attrs \\ []) do
    phase = Keyword.get(attrs, :phase, :code_review)
    head = Keyword.get(attrs, :head_sha, "sha-head")
    facts = Facts.new(Map.merge(%{phase: phase, pr: :open, pr_number: 1, ci: :green, mergeable: :clean}, Map.new(Keyword.get(attrs, :facts, %{}))))

    watch = %{
      facts: facts,
      pr_url: Keyword.get(attrs, :pr_url, "https://github.com/acme/app/pull/1"),
      head_sha: head,
      source: :poll,
      read_at: ~U[2026-10-16 12:00:00Z],
      github: :ok,
      rate_limit: nil,
      landing: Keyword.get(attrs, :landing),
      decision: decision(Keyword.get(attrs, :decision, :dispatch), head),
      applied: [],
      attempts: Keyword.get(attrs, :attempts, Attempts.new()),
      fix: %{ci_failure: Keyword.get(attrs, :ci_failure), pr_conflict: Keyword.get(attrs, :pr_conflict)},
      links: []
    }

    :ok = RunStore.put_ticket_pr_watch(repo_key, issue_id, Keyword.get(attrs, :identifier), watch)
  end

  @doc """
  Sets one part of the fix context (`:ci_failure` or `:pr_conflict`) on the record of `issue_id`,
  keeping the rest; a ticket with no record gets one with `attrs`.
  """
  def put_fix!(repo_key, issue_id, kind, fix, attrs \\ []) when kind in [:ci_failure, :pr_conflict] do
    case repo_key |> RunStore.get_ticket_state(issue_id) |> TicketState.pr_watch() do
      nil ->
        put_watch!(repo_key, issue_id, Keyword.put(attrs, kind, fix))

      watch ->
        :ok = RunStore.put_ticket_pr_watch(repo_key, issue_id, Keyword.get(attrs, :identifier), %{watch | fix: Map.put(watch.fix, kind, fix)})
    end
  end

  @doc "Changes the record of `issue_id` with `fun`, which gets and returns the watch map."
  def update_watch!(repo_key, issue_id, fun) do
    watch = repo_key |> RunStore.get_ticket_state(issue_id) |> TicketState.pr_watch()
    :ok = RunStore.put_ticket_pr_watch(repo_key, issue_id, nil, fun.(watch))
  end

  defp decision(nil, _head), do: nil
  defp decision(%{} = decision, _head), do: decision

  defp decision(kind, head) when is_atom(kind) do
    %{rule: "R0", kind: kind, reason: "test decision #{kind}", owner: nil, clears_when: nil, args: %{}, waits_on: nil, head_sha: head, outcome: :recorded, error: nil}
  end
end
