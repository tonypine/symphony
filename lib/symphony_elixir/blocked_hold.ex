defmodule SymphonyElixir.BlockedHold do
  @moduledoc """
  The Blocked hold: a dependency pauses a designed repo's ticket in place and lifts on its own.

  On a repo running the designed machine, a Todo ticket with an open blocked-by blocker gains the
  `Blocked` machine label and a recorded reason (the blockers it waits on) instead of being held
  invisibly. When every blocker goes terminal the hold clears on its own and the ticket dispatches
  — no state move, no person involved. `sync/3` reconciles one issue's store hold against its
  blockers; the poll loop runs `sweep/3` over each polled repo's issues.

  Legacy repos are untouched: `sync/3` is a no-op there, so the invisible Todo hold behaves exactly
  as before. Only a hold a dependency lifts is cleared here — one waiting on an access grant or a
  fix ticket (a self-heal) is lifted by its own signal.
  """

  require Logger

  alias SymphonyElixir.{Config, Hold, StateMachine}
  alias SymphonyElixir.Linear.Issue

  @todo_state "todo"
  @dependency_type "dependency"

  @typedoc "What the dependency state calls for: set the hold, clear it, or leave it as it is."
  @type action :: {:set, map()} | :clear | :none

  @doc """
  The action the issue's blockers call for, given the blocked hold it already has (or nil):
  `{:set, attrs}` when a Todo ticket has an open blocker and no hold yet describes it, `:clear`
  when the hold it has waits on blockers that are now all terminal, else `:none`.
  """
  @spec desired(Issue.t() | term(), Enumerable.t(String.t()), map() | nil) :: action()
  def desired(%Issue{} = issue, terminal_states, current_hold) do
    open = Issue.open_blockers(issue, terminal_states)

    cond do
      dependency_hold?(current_hold) and open == [] ->
        :clear

      todo_with_open_blockers?(issue, open) and not same_dependency?(current_hold, open) ->
        {:set, dependency_attrs(open)}

      true ->
        :none
    end
  end

  def desired(_issue, _terminal_states, _current_hold), do: :none

  @doc """
  Reconciles the Blocked hold of one issue against its blockers. `opts[:settings]` is the repo's
  resolved settings (the poll loop passes it once per repo); without it the issue's repo is
  resolved through `Config.settings_for_repo/1`. Returns `:skipped` on a repo that is not the
  designed machine, else the action taken (`:set`, `:clear` or `:none`).
  """
  @spec sync(Issue.t() | term(), Enumerable.t(String.t()), keyword()) :: :skipped | :set | :clear | :none
  def sync(issue, terminal_states, opts \\ []) do
    with %Issue{} = issue <- issue,
         %{} = settings <- settings(issue, opts),
         true <- StateMachine.designed?(settings) do
      sync_designed(issue, terminal_states, opts)
    else
      _skipped -> :skipped
    end
  end

  @doc """
  Runs `sync/3` over a repo's polled issues and returns how many holds it changed. A hand-added
  `Blocked` label with no store record is reported and cleared, so the board matches the store.
  """
  @spec sweep([Issue.t()] | term(), Enumerable.t(String.t()), keyword()) :: non_neg_integer()
  def sweep(issues, terminal_states, opts \\ []) do
    if is_list(issues), do: Enum.count(issues, &(sync(&1, terminal_states, opts) in [:set, :clear])), else: 0
  end

  defp sync_designed(%Issue{id: issue_id, repo_key: repo_key} = issue, terminal_states, opts) do
    repair_drift(repo_key, issue_id, issue.labels, opts)
    current = Hold.get(repo_key, issue_id, :blocked, opts)

    case desired(issue, terminal_states, current) do
      {:set, attrs} ->
        apply_action(:set, repo_key, issue_id, attrs, opts)

      :clear ->
        apply_action(:clear, repo_key, issue_id, %{}, opts)

      :none ->
        :none
    end
  end

  defp apply_action(:set, repo_key, issue_id, attrs, opts) do
    case Hold.set(repo_key, issue_id, :blocked, attrs, opts) do
      :ok -> :set
      {:error, reason} -> log_failure("set", issue_id, reason)
    end
  end

  defp apply_action(:clear, repo_key, issue_id, _attrs, opts) do
    case Hold.clear(repo_key, issue_id, :blocked, opts) do
      :ok -> :clear
      {:error, reason} -> log_failure("clear", issue_id, reason)
    end
  end

  # The store is the truth for a hold, so the board is repaired to match it in both directions. A
  # `Blocked` label with no store hold is a hand-added label: report it and clear it. A store hold
  # whose `Blocked` label is missing — its label write failed, or a person removed it by hand — is
  # re-projected from the store, so a hold that is pausing dispatch is never silently invisible.
  defp repair_drift(repo_key, issue_id, labels, opts) do
    case Hold.report_drift(repo_key, issue_id, labels, opts) do
      {:stray_label, :blocked} -> clear_label(repo_key, issue_id, opts)
      {:missing_label, :blocked} -> reproject_label(repo_key, issue_id, opts)
      _ok_or_missing -> :ok
    end
  end

  defp clear_label(repo_key, issue_id, opts) do
    _ = Hold.clear(repo_key, issue_id, :blocked, opts)
    :ok
  end

  defp reproject_label(repo_key, issue_id, opts) do
    _ = Hold.reproject(repo_key, issue_id, :blocked, opts)
    :ok
  end

  defp log_failure(action, issue_id, reason) do
    Logger.warning("Failed to #{action} the Blocked hold on issue_id=#{issue_id}: #{inspect(reason)}")
    :none
  end

  defp dependency_hold?(%{waits_on: %{type: @dependency_type}}), do: true
  defp dependency_hold?(_hold), do: false

  defp todo_with_open_blockers?(%Issue{state: state}, open), do: open != [] and normalize(state) == @todo_state

  defp same_dependency?(hold, open) do
    dependency_hold?(hold) and hold.waits_on.keys == blocker_keys(open)
  end

  defp dependency_attrs(open) do
    keys = blocker_keys(open)

    %{
      reason: "waiting on " <> Enum.join(keys, ", "),
      clearing_condition: "when every blocker is terminal",
      waits_on: %{type: @dependency_type, keys: keys}
    }
  end

  defp blocker_keys(open) do
    open
    |> Enum.map(&(&1.identifier || &1.id))
    |> Enum.reject(&is_nil/1)
  end

  # The repo's resolved settings: the caller's once-per-repo value when it passed one, else resolved
  # from the issue's repo key.
  defp settings(%Issue{repo_key: repo_key}, opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} -> settings
      :error -> settings_for_repo(repo_key)
    end
  end

  defp settings_for_repo(nil), do: nil

  defp settings_for_repo(repo_key) when is_binary(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings
      {:error, _reason} -> nil
    end
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
