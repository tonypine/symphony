defmodule SymphonyElixir.PrWatch.Snapshot do
  @moduledoc """
  What the ticket read serves of a pull request, as the PR and CI watcher last read it
  (`SymphonyElixir.PrWatch.Fetch.read/2`): no read of its own, so it changes when the watcher reads,
  on the same triggers. The watcher writes it on the ticket's record (`TicketState.pull_request`),
  which keeps it once the watch ends. `SymphonyElixirWeb.PullRequestPayload` serves it; its shape is
  in `docs/control-api.md`.

  `build/4` takes the checks the watcher decided on, so the checks of superseded runs and earlier
  attempts are already gone (`SymphonyElixir.GitHub.PullRequest.drop_superseded/1`). Every run of a
  workflow cancelled keeps its checks there, so it lists each check of a workflow once, from its
  newest run.

  A check says one of `passed`, `failed`, `running`, `waiting`, `skipped` or `cancelled_no_machine`.
  GitHub says no more than `CANCELLED` of a job that never got a runner, and the watcher counts every
  such check as one (`docs/pr-ci-decisions.md`): it is rerun and never takes a fix run, so it never
  reads as failed.
  """

  alias SymphonyElixir.GitHub.PullRequest

  @typedoc """
  One check: its workflow (nil for a status from outside GitHub Actions), name, state, when it
  started, how long it took once it finished, its log, and whether the base requires it (nil when the
  watcher doesn't know the base's required checks).
  """
  @type check :: %{
          workflow: String.t() | nil,
          name: String.t() | nil,
          state: String.t(),
          started_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          url: String.t() | nil,
          required: boolean() | nil
        }

  @type t :: %{
          optional(:read_at) => DateTime.t() | nil,
          number: pos_integer() | nil,
          url: String.t(),
          title: String.t() | nil,
          state: String.t(),
          draft: boolean(),
          head_sha: String.t() | nil,
          base: String.t() | nil,
          mergeable: String.t(),
          review_decision: String.t() | nil,
          files_changed: non_neg_integer() | nil,
          additions: non_neg_integer() | nil,
          deletions: non_neg_integer() | nil,
          checks: [check()]
        }

  @doc """
  The snapshot of a pull request: `read` is the watcher's read of it, `pull` GitHub's answer, `checks`
  the head's checks as the watcher kept them and `required` the names the base requires, nil when
  they aren't known.
  """
  @spec build(map(), map(), [PullRequest.ci_check()], [String.t()] | nil) :: t()
  def build(read, pull, checks, required) do
    %{
      number: read.pr_number,
      url: read.pr_url,
      title: read.pr_title,
      state: if(read.pr in [:open, :draft], do: "open", else: Atom.to_string(read.pr)),
      draft: read.pr == :draft,
      head_sha: read.head_sha,
      base: read.base_ref,
      mergeable: Atom.to_string(read.mergeable),
      review_decision: pull["reviewDecision"],
      files_changed: pull["changedFiles"],
      additions: pull["additions"],
      deletions: pull["deletions"],
      checks: checks |> newest() |> Enum.map(&check(&1, required))
    }
  end

  # Each check of a workflow once, from its newest run, in the order GitHub lists them.
  defp newest(checks) do
    key = &{&1.workflow_name, &1.name}
    newest = checks |> Enum.group_by(key) |> Map.new(fn {check_key, same} -> {check_key, Enum.max_by(same, &age/1)} end)

    checks |> Enum.map(key) |> Enum.uniq() |> Enum.map(&Map.fetch!(newest, &1))
  end

  # GitHub numbers runs and jobs as it creates them, so a higher number is newer.
  defp age(check), do: {run_number(check.run_id), check.job_id || 0}

  defp run_number(nil), do: 0
  defp run_number(run_id), do: String.to_integer(run_id)

  defp check(check, required) do
    %{
      workflow: check.workflow_name,
      name: check.name,
      state: state(check),
      started_at: check.started_at,
      duration_ms: duration_ms(check),
      url: check.details_url,
      required: if(is_list(required), do: check.name in required)
    }
  end

  defp state(check) do
    case PullRequest.check_result(check) do
      :pending -> if(check.status == "IN_PROGRESS", do: "running", else: "waiting")
      :passed -> if(check.conclusion == "SKIPPED", do: "skipped", else: "passed")
      :failed -> if(check.conclusion == "CANCELLED", do: "cancelled_no_machine", else: "failed")
    end
  end

  defp duration_ms(%{started_at: %DateTime{} = started, completed_at: %DateTime{} = completed}) do
    max(DateTime.diff(completed, started, :millisecond), 0)
  end

  defp duration_ms(_check), do: nil
end
