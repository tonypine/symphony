defmodule SymphonyElixir.SubIssueWait do
  @moduledoc """
  The state a `breakdown` parent waits in while its sub-issues are worked
  (`issues.states.waiting_on_sub_issues`, default `Waiting on sub-tickets`).

  A human approving the breakdown plan moves the parent there, and on every poll Symphony
  moves a `breakdown` parent it finds `In Progress` with approved sub-issues open there too,
  so `In Progress` only holds issues an agent is working. A parent whose open sub-issues are
  all still in `Backlog` was never approved, so it is not moved: it gets a breakdown run that
  picks the plan up where it stopped (see `Issue.unapproved_plan?/2`). The poll's candidates
  can be stale, so the parent's state is read again just before the move. The state is active but
  held: an issue in it is dispatched only to close its epic, once it is a `breakdown` parent whose
  sub-issues are all terminal — the epic review (`SymphonyElixir.EpicReview`), which moves the
  parent to `Epic Review` and reviews it.

  Any other issue whose pull request merges with a sub-issue still open outside `Backlog` waits there
  too, instead of closing (`wait_on_merge?/3`), and Symphony moves it to `Done` itself, with no run,
  once every sub-issue outside `Backlog` is terminal (`close?/3`), on every poll whether or not a
  dispatch pass runs. A blocked-by link to it no longer blocks (`merged_blocker?/1`). Its `Backlog` sub-issues wait for a person to promote them and never hold it: with only
  those open, the merge closes it as if it had none. A sub-issue filed or canceled meanwhile just
  counts in that check. The RunStore records each issue the merge put there,
  so one a person moved there, with its pull request still open, waits for a human as before.

  At startup Symphony checks that the Linear team has the state. When it is
  missing, the state is turned off for the life of the process and a warning is
  logged, so parents keep waiting `In Progress` as before. Setup lists it as a problem too
  (`disabled_teams/1`).
  """

  require Logger

  alias SymphonyElixir.Conductor.Tree
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RunStore, TicketPlan, TicketPullRequest}
  alias SymphonyElixir.{TicketSignals, TicketState, Tracker, TransitionGuard}

  @parked_from_state "In Progress"
  @backlog_state "Backlog"
  @done_state "Done"
  @merged_pr_state "merged"

  @doc "The configured waiting state name, or nil when it is turned off in config."
  @spec state(Schema.t() | term()) :: String.t() | nil
  def state(%Schema{tracker: %{waiting_on_sub_issues_state: state}}) when is_binary(state), do: state
  def state(_settings), do: nil

  @doc "Whether the waiting state is configured and the startup check did not turn it off."
  @spec enabled?(Schema.t() | term()) :: boolean()
  def enabled?(settings) do
    case state(settings) do
      nil -> false
      state -> is_nil(:persistent_term.get(disabled_key(state), nil))
    end
  end

  @doc """
  The teams the startup check found without the waiting state `state` when it turned the state off
  (empty when it looked in every team), for the Setup check that lists it; nil while it is on.
  """
  @spec disabled_teams(String.t() | nil) :: [String.t()] | nil
  def disabled_teams(state) when is_binary(state), do: :persistent_term.get(disabled_key(state), nil)
  def disabled_teams(nil), do: nil

  @doc """
  Checks that the given Linear teams have the waiting state. With no teams, any
  team in the workspace having it is enough.

  Returns `:ok` when the state exists, `:disabled` when it is missing (parents
  then stay `In Progress` until restart), `:skipped` when no state is configured,
  and `{:error, reason}` when the tracker could not be asked (the state stays on).
  """
  @spec check_tracker_state(Schema.t(), [String.t()], keyword()) :: :ok | :disabled | :skipped | {:error, term()}
  def check_tracker_state(settings, teams, opts \\ []) do
    case state(settings) do
      nil -> :skipped
      state -> check_tracker_state_exists(state, teams, Keyword.get(opts, :tracker, Tracker))
    end
  end

  defp check_tracker_state_exists(state, teams, tracker) do
    case tracker.workflow_state_exists?(state, teams) do
      {:ok, true} ->
        :persistent_term.erase(disabled_key(state))
        :ok

      {:ok, false} ->
        Logger.warning(
          "Waiting on sub-issues state disabled: Linear state #{inspect(state)} is missing#{teams_suffix(teams)}; " <>
            "breakdown parents stay #{@parked_from_state}. Add it as a started state after In Progress, then restart Symphony"
        )

        :persistent_term.put(disabled_key(state), teams)
        :disabled

      {:error, reason} ->
        Logger.warning("Could not check the Linear state #{inspect(state)} for breakdown parents; leaving it on: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "True when `issue` sits in the waiting state."
  @spec in_state?(Issue.t() | term(), Schema.t() | term()) :: boolean()
  def in_state?(%Issue{state: issue_state}, settings) when is_binary(issue_state) do
    case state(settings) do
      nil -> false
      state -> normalize(issue_state) == normalize(state)
    end
  end

  def in_state?(_issue, _settings), do: false

  @doc """
  True when a `breakdown` parent is ready for its epic's close, the epic review: its sub-issues are
  all terminal (`Issue.close_out_ready?/2`), or it sits in the waiting state with none left, as when
  every child was re-parented to another epic or deleted. A parent with no sub-issues anywhere else
  (`Todo`, `In Progress`) has no plan yet: it gets a plan run, not the close. A groomed ticket
  (`SymphonyElixir.TicketPlan`) is never ready for it, even when its `plan` label survived: its
  close is the Conductor's final check.
  """
  @spec close_out_ready?(Issue.t() | term(), Enumerable.t(String.t()), Schema.t() | term()) :: boolean()
  def close_out_ready?(%Issue{} = issue, terminal_states, settings) do
    (Issue.close_out_ready?(issue, terminal_states) or
       (Issue.breakdown?(issue) and issue.sub_issues == [] and in_state?(issue, settings))) and not groomed?(issue)
  end

  def close_out_ready?(_issue, _terminal_states, _settings), do: false

  @doc "Whether `issue` is groomed: its record holds a plan (`SymphonyElixir.TicketPlan.groomed?/1`)."
  @spec groomed?(Issue.t() | term()) :: boolean()
  def groomed?(%Issue{id: issue_id}) when is_binary(issue_id), do: TicketPlan.groomed?(issue_id)
  def groomed?(_issue), do: false

  @doc """
  True when an issue in the waiting state must not run: anything but a `breakdown`
  parent ready for its close (`close_out_ready?/3`). The run it is released for is the epic's
  close, the epic review (`SymphonyElixir.RunKind` classifies it `:epic_review`).
  """
  @spec held?(Issue.t() | term(), Enumerable.t(String.t()), Schema.t() | term()) :: boolean()
  def held?(issue, terminal_states, settings) do
    in_state?(issue, settings) and not close_out_ready?(issue, terminal_states, settings)
  end

  @doc """
  True when Symphony should move `issue` from `In Progress` to the waiting state: a `breakdown`
  parent whose approved sub-issues are open (see `Issue.waiting_on_sub_issues?/2`).
  """
  @spec park?(Issue.t() | term(), Enumerable.t(String.t()), Schema.t() | term()) :: boolean()
  def park?(%Issue{} = issue, terminal_states, settings) do
    enabled?(settings) and parked_from?(issue) and Issue.waiting_on_sub_issues?(issue, terminal_states)
  end

  def park?(_issue, _terminal_states, _settings), do: false

  @doc """
  True when `issue` sits in the state Symphony parks parents from (`In Progress`). Symphony checks
  it again on a fresh read just before parking: a parent in `Plan Review` waits there for a human's
  review of its plan, and moving it on would read as that approval.
  """
  @spec parked_from?(Issue.t() | term()) :: boolean()
  def parked_from?(%Issue{state: issue_state}) when is_binary(issue_state), do: normalize(issue_state) == normalize(@parked_from_state)
  def parked_from?(_issue), do: false

  @doc """
  True when `issue`, whose pull request merged, waits in the waiting state instead of closing: the
  state is on, the issue is not a `breakdown` parent (those wait from their plan's approval) and it
  has a sub-issue outside `terminal_states` and outside `Backlog`. A `Backlog` sub-issue waits for a
  person to promote it, so it does not hold the issue open.

  A groomed ticket (`groomed?/1`) waits on every sub-ticket it has: one in `Backlog` holds it too,
  and with all of them ended it still waits there, for the Conductor's final check of the whole
  ticket (`SymphonyElixir.Conductor.Tree`), which closes it.
  """
  @spec wait_on_merge?(Issue.t() | term(), Enumerable.t(String.t()), Schema.t() | term()) :: boolean()
  def wait_on_merge?(%Issue{} = issue, terminal_states, settings) do
    enabled?(settings) and holding_sub_issues(issue, terminal_states) != []
  end

  def wait_on_merge?(_issue, _terminal_states, _settings), do: false

  @doc """
  Moves `issue`, whose pull request merged with sub-issues open outside `Backlog`, to the waiting
  state and comments on it. Its sub-issues are left as they are: promoting `Backlog` ones is a
  person's call (or a plan's approval). It first records the merge in the RunStore, which `close?/3`
  requires. It can run again: an issue already waiting is not moved or commented on again.
  """
  @spec wait_on_merge(Issue.t(), Schema.t(), module()) :: :ok | {:error, term()}
  def wait_on_merge(%Issue{} = issue, %Schema{} = settings, tracker) do
    waiting_state = state(settings)

    with :ok <- RunStore.put_merged_wait(issue.id) do
      if in_state?(issue, settings) do
        :ok
      else
        move_to_waiting(issue, waiting_state, settings.tracker.terminal_states, settings, tracker)
      end
    end
  end

  @doc """
  True when Symphony closes `issue` itself: it sits in the waiting state, is not a `breakdown` parent
  (its epic review closes it), every one of its sub-issues is in `terminal_states` or `Backlog` (or
  it has none left: each was re-parented away or deleted), and its pull request merged: its merge put
  it there (`wait_on_merge/3`), or the ticket's pull request record says `merged`. The record covers a
  ticket whose mark an earlier close deleted without moving the record, which the drift check then
  moved back (MOT-93, TP-1565). One a person moved there with its pull request open waits for them.
  Sub-issues a read did not carry (`:unknown`) never close it.

  A groomed ticket (`groomed?/1`) follows its own rule (`SymphonyElixir.Conductor.Tree.due/3`):
  its pull request merged or it never had one, no sub-ticket is left outside `terminal_states` (one
  in `Backlog` holds it), and the Conductor's final check is not owed: that check closes the
  ticket itself, and Symphony closes it here only when the check is off or could not be made.
  """
  @spec close?(Issue.t() | term(), Enumerable.t(String.t()), Schema.t() | term()) :: boolean()
  def close?(%Issue{sub_issues: sub_issues} = issue, terminal_states, settings) when is_list(sub_issues) do
    in_state?(issue, settings) and closes?(issue, terminal_states)
  end

  def close?(_issue, _terminal_states, _settings), do: false

  defp closes?(issue, terminal_states) do
    if groomed?(issue) do
      Tree.due(issue, terminal_states) == :close
    else
      not Issue.breakdown?(issue) and started_sub_issues(issue, terminal_states) == [] and merged?(issue)
    end
  end

  @doc "Whether Symphony's record of the ticket `issue_id` says its pull request merged (`pull_request/1`)."
  @spec pr_merged?(String.t() | term()) :: boolean()
  def pr_merged?(issue_id), do: pull_request(issue_id) == :merged

  @doc """
  What Symphony's record of the ticket `issue_id` says of its pull request: `:merged`, `:unmerged`
  (it has one, open or closed) or `:none` (it never had one, or Symphony holds no record of the
  ticket). The ticket's pull request record comes first (`SymphonyElixir.TicketPullRequest`), then
  the PR and CI watcher's last read of it (`pull_request`, kept once the watch ends, and
  `pr_watch`'s facts).
  """
  @spec pull_request(String.t() | term()) :: :merged | :unmerged | :none
  def pull_request(issue_id) when is_binary(issue_id) do
    case RunStore.get_ticket_state(issue_id) do
      %{} = record -> record |> TicketState.normalize() |> recorded_pull_request()
      _none -> :none
    end
  end

  def pull_request(_issue_id), do: :none

  defp recorded_pull_request(record) do
    case TicketPullRequest.get(record.repo_key, record.issue_id) do
      %{state: "merged"} -> :merged
      %{state: "open"} -> :unmerged
      own -> watched_pull_request(record, is_map(own))
    end
  end

  defp watched_pull_request(%{pull_request: %{state: "merged"}}, _recorded?), do: :merged
  defp watched_pull_request(%{pr_watch: %{facts: %{pr: :merged}}}, _recorded?), do: :merged
  defp watched_pull_request(%{pull_request: pull_request}, recorded?), do: if(recorded? or is_map(pull_request), do: :unmerged, else: :none)

  @doc """
  True when `blocker` (a blocked-by link's `%{id, state}`) no longer blocks although it is not
  terminal: it sits in the waiting state because its pull request merged (`wait_on_merge/3`
  recorded it), so its code is on the default branch. A sub-ticket blocked by its own parent would
  otherwise wait on the parent while the parent waits on it (MOT-85 and MOT-100). A plan parent in
  the waiting state still blocks: its work is its sub-tickets, and nothing recorded a merge for it.

  A groomed blocker (`groomed?/1`) no longer blocks once its record says its pull request merged
  (`pr_merged?/1`), whatever state it is in: merged is not Done, and a ticket that builds on its
  code waits on the merge only.
  """
  @spec merged_blocker?(map() | term()) :: boolean()
  def merged_blocker?(%{id: blocker_id, state: blocker_state}) when is_binary(blocker_id) and is_binary(blocker_state) do
    # Whether it is groomed comes first: one read rules out every blocker with no plan, which then
    # costs no read of its pull request.
    merged_waiting?(blocker_id, blocker_state) or (TicketPlan.groomed?(blocker_id) and pr_merged?(blocker_id))
  end

  def merged_blocker?(_blocker), do: false

  defp merged_waiting?(blocker_id, blocker_state) do
    # The store read comes first: it rules out nearly every blocker for less than a config read.
    with true <- RunStore.merged_wait?(blocker_id),
         {:ok, settings} <- Config.settings(),
         state when is_binary(state) <- state(settings) do
      normalize(blocker_state) == normalize(state)
    else
      _not_waiting -> false
    end
  end

  @doc """
  Moves `issue` to `Done`, Symphony's record first and then Linear, and comments how each of its
  sub-issues ended or waits. The merge's mark (`wait_on_merge/3`) is deleted only once the move went
  through and the record holds `Done`. An issue with no repo key has no record to move, so it is not
  moved at all and comes back `{:error, :no_repo_key}` with its mark kept: a move of Linear alone
  would be drift, which the drift check moves back (MOT-93, TP-1565).
  """
  @spec close(Issue.t(), module()) :: :ok | {:error, term()}
  def close(%Issue{id: issue_id, repo_key: repo_key} = issue, tracker) when is_binary(repo_key) and repo_key != "" do
    ctx = %{repo_key: repo_key, issue_identifier: issue.identifier}

    with :ok <- TransitionGuard.perform(issue_id, :sub_issues_done, ctx, tracker: tracker) do
      Logger.info("Moved issue to #{@done_state}: every sub-issue is finished #{issue_fields(issue)}")
      forget_merge(repo_key, issue_id)
      comment(issue, close_comment(issue), tracker)
    end
  end

  def close(%Issue{}, _tracker), do: {:error, :no_repo_key}

  defp forget_merge(repo_key, issue_id) do
    if TicketSignals.recorded_phase(repo_key, issue_id) == {:ok, @done_state}, do: RunStore.delete_merged_wait(issue_id)
  end

  @doc false
  @spec reset_for_test(String.t()) :: :ok
  def reset_for_test(state) when is_binary(state) do
    :persistent_term.erase(disabled_key(state))
    :ok
  end

  defp move_to_waiting(%Issue{id: issue_id} = issue, waiting_state, terminal_states, settings, tracker) do
    ctx = %{settings: settings, repo_key: issue.repo_key}

    with :ok <- TransitionGuard.perform(issue_id, :wait_on_merge, ctx, tracker: tracker) do
      TicketSignals.record(issue.repo_key, issue_id, "merge settled", %{to: waiting_state})
      Logger.info("Moved issue to #{waiting_state} after its PR merged with sub-issues open: #{issue_fields(issue)}")
      comment(issue, wait_comment(issue, waiting_state, terminal_states), tracker)
    end
  end

  # The sub-issues that keep a merged issue from closing: a groomed ticket's, every one; any other
  # issue's, the open ones a person or a plan's approval started, and none for a `breakdown` parent.
  defp holding_sub_issues(%Issue{sub_issues: sub_issues} = issue, terminal_states) do
    cond do
      groomed?(issue) -> List.wrap(if(is_list(sub_issues), do: sub_issues))
      Issue.breakdown?(issue) -> []
      true -> started_sub_issues(issue, terminal_states)
    end
  end

  defp merged?(%Issue{id: issue_id} = issue), do: RunStore.merged_wait?(issue_id) == true or merged_pull_request?(issue)

  defp merged_pull_request?(%Issue{id: issue_id, repo_key: repo_key}) when is_binary(issue_id) and is_binary(repo_key),
    do: match?(%{state: @merged_pr_state}, TicketPullRequest.get(repo_key, issue_id))

  defp merged_pull_request?(_issue), do: false

  # Open sub-issues a person or a plan's approval started: outside `terminal_states` and `Backlog`.
  defp started_sub_issues(issue, terminal_states), do: issue |> Issue.open_sub_issues(terminal_states) |> Enum.reject(&backlog_sub_issue?/1)

  defp backlog_sub_issue?(%{state: state}) when is_binary(state), do: normalize(state) == normalize(@backlog_state)
  defp backlog_sub_issue?(_sub_issue), do: false

  defp wait_comment(issue, waiting_state, terminal_states) do
    if groomed?(issue),
      do: groomed_wait_comment(issue, waiting_state, terminal_states),
      else: started_wait_comment(issue, waiting_state, terminal_states)
  end

  defp groomed_wait_comment(issue, waiting_state, terminal_states) do
    check = "the Conductor checks the whole ticket against its plan, and it moves to #{@done_state}"

    case issue |> Issue.open_sub_issues(terminal_states) |> Enum.map_join(", ", &sub_issue_label/1) do
      "" ->
        "#{waiting_state}: the PR merged and every sub-ticket has ended. Next, #{check}."

      open ->
        "#{waiting_state}: the PR merged with sub-tickets still open (#{open}). Once each one is #{@done_state} or " <>
          "canceled, one in #{@backlog_state} included, #{check}."
    end
  end

  defp started_wait_comment(issue, waiting_state, terminal_states) do
    open = issue |> started_sub_issues(terminal_states) |> Enum.map_join(", ", &sub_issue_label/1)

    "#{waiting_state}: the PR merged with sub-tickets still open (#{open}), so this ticket moves to " <>
      "#{@done_state} once every sub-ticket is finished. Canceling one counts as finishing it, and one " <>
      "in #{@backlog_state} does not hold it."
  end

  defp close_comment(%Issue{sub_issues: []}), do: "No sub-ticket is left under this ticket, so it is #{@done_state}."

  defp close_comment(%Issue{sub_issues: sub_issues}) do
    outcomes = Enum.map_join(sub_issues, "\n", &"- #{sub_issue_label(&1)}: #{Map.get(&1, :state) || "unknown"}")
    "Every sub-ticket is finished, so this ticket is #{@done_state}:\n\n" <> outcomes <> backlog_note(sub_issues)
  end

  defp backlog_note(sub_issues) do
    if Enum.any?(sub_issues, &backlog_sub_issue?/1),
      do: "\n\nSub-tickets in #{@backlog_state} stay there until a person moves them to Todo with Move to… in the Director.",
      else: ""
  end

  defp comment(%Issue{id: issue_id} = issue, body, tracker) do
    case tracker.create_comment(issue_id, body) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to comment on an issue waiting on its sub-issues: #{issue_fields(issue)} reason=#{inspect(reason)}")
    end

    :ok
  end

  defp sub_issue_label(sub_issue), do: Map.get(sub_issue, :identifier) || Map.get(sub_issue, :id)

  defp issue_fields(%Issue{id: issue_id, identifier: identifier}), do: "issue_id=#{issue_id} issue_identifier=#{identifier}"

  defp normalize(state), do: state |> String.trim() |> String.downcase()

  defp disabled_key(state), do: {__MODULE__, :disabled, state}

  defp teams_suffix([]), do: ""
  defp teams_suffix(teams), do: " for team(s) #{Enum.join(teams, ", ")}"
end
