defmodule SymphonyElixirWeb.PullRequestPayload do
  @moduledoc """
  The `pull_request` of the ticket read (`docs/control-api.md`): the PR the watcher last read of the
  ticket (`SymphonyElixir.PrWatch.Snapshot`), its checks by workflow, with what the ticket's record
  says of it beside the read: the review state and rounds from its verdicts, and the kind of a red
  head and the next action from the watcher's record while it watches the ticket. It makes no GitHub
  read. A PR Symphony saw close or merge after the last read says so
  (`SymphonyElixir.TicketPullRequest`).
  """

  alias SymphonyElixir.Inbox.References
  alias SymphonyElixir.{TicketPullRequest, TicketState}
  alias SymphonyElixirWeb.WatchPayload

  @head_short 7
  @finished ["closed", "merged"]
  @review_outcomes ["approve", "request_changes", "block"]
  @fields [:number, :url, :title, :draft, :head_sha, :base, :mergeable, :files_changed, :additions, :deletions]

  @doc "The ticket's pull request, or nil before the watcher has read one for it."
  @spec read(TicketState.t() | nil) :: map() | nil
  def read(%{pull_request: %{} = pull_request} = record) do
    state = state(record, pull_request)
    verdicts = record |> TicketState.verdicts() |> Enum.filter(&(&1.kind == "code_review"))
    watch = record.pr_watch

    pull_request
    |> Map.take(@fields)
    |> Map.merge(%{
      state: state,
      head_short: head_short(pull_request.head_sha),
      behind_base: pull_request.mergeable == "behind",
      review_state: References.review_state(%{state: String.upcase(state), review_decision: pull_request.review_decision}, verdicts),
      review_rounds: References.rounds(verdicts, @review_outcomes),
      checks: by_workflow(pull_request.checks),
      red_kind: red_kind(watch),
      next_action: WatchPayload.next_action(watch),
      read_at: iso8601(Map.get(pull_request, :read_at))
    })
  end

  def read(_record), do: nil

  defp state(record, %{url: url, state: state}) do
    case TicketPullRequest.get(record.repo_key, record.issue_id) do
      %{pr_url: ^url, state: finished} when finished in @finished -> finished
      _other -> state
    end
  end

  defp head_short(sha) when is_binary(sha), do: String.slice(sha, 0, @head_short)
  defp head_short(_sha), do: nil

  # The workflows in the order GitHub lists their first check.
  defp by_workflow(checks) do
    checks
    |> Enum.map(& &1.workflow)
    |> Enum.uniq()
    |> Enum.map(fn workflow ->
      %{workflow: workflow, checks: for(%{workflow: ^workflow} = check <- checks, do: check_payload(check))}
    end)
  end

  defp check_payload(check) do
    check
    |> Map.take([:name, :state, :duration_ms, :url, :required])
    |> Map.put(:started_at, iso8601(check.started_at))
  end

  defp red_kind(%{facts: %{ci: :red, red_kind: kind}}), do: Atom.to_string(kind)
  defp red_kind(_watch), do: nil

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_at), do: nil
end
