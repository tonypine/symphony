defmodule SymphonyElixir.DirectorLabels do
  @moduledoc """
  The Director's label toggles, from a ticket's page in the Mac app (TP-1356): `set/4` adds or
  removes one of the labels a person adds for Symphony to read on a tracked ticket, and `labels/2`
  reads them as toggles, as the ticket's record holds its labels.

  The labels, each with the one-line effect the app shows (`toggles/1`):

    * `plan` (or `breakdown`, its older name: one toggle, on when either is there, and turning it
      off removes both): the ticket is a plan parent (`SymphonyElixir.Linear.Issue.breakdown?/1`);
    * `type:bug` and `type:feature`: the prompt's per-type steps and readiness check;
    * `qa:skip`: QA is skipped (`SymphonyElixir.QaAgent.Selection`);
    * `skip-update-hold`: the ticket does not wait for the app update with its fix
      (`SymphonyElixir.UpdateHold`);
    * `qa:live` and `qa:fixture`: a person's override of QA's environment (`SymphonyElixir.QaPolicy`);
    * each of the repository's `escalate.labels` (`SymphonyElixir.EscalationRules`), read from its
      settings, so a configured one counts: Code Review asks a person before approving.

  The machine labels (`SymphonyElixir.MachineLabels`) and the force label
  (`agent.force_label`, which Force sets) are never one of them, even when
  `escalate.labels` names one. The ticket is one Symphony tracks: it has a record
  (`SymphonyElixir.TicketState`) that is not removed, found by identifier or id in every configured
  repository's records. A change is refused (`{:error, {:conflict, message}}`, the reason the app
  shows) when the label is not one of the ticket's toggles, when Symphony doesn't track the ticket,
  or when the label is already on (or already off).

  A change writes the tracker first (`SymphonyElixir.Tracker.add_issue_label/2` and
  `remove_issue_label/2`, the `:tracker`: Linear, or the memory tracker of a QA or local server); a
  write it refuses is `{:error, {:linear, message}}`, the message saying why in the app's words, and
  changes nothing. Then, at once and without waiting for the next read of Linear:

    * the record's `labels` change and the change is announced
      (`SymphonyElixirWeb.ObservabilityPubSub.broadcast_ticket_record_changed/3`);
    * the ticket's events get a `person.action` (`add_label` or `remove_label`, with the `label`)
      by the Director, the audit log a `director_move`, and the orchestrator is asked to poll the
      ticket's repository.
  """

  require Logger

  alias SymphonyElixir.{
    AuditLog,
    Config,
    MachineLabels,
    Orchestrator,
    RunStore,
    TicketMoves,
    TicketSignals,
    TicketState
  }

  alias SymphonyElixir.Config.Escalate
  alias SymphonyElixirWeb.ObservabilityPubSub

  @director {:person, "the Director"}

  # The labels Symphony reads, in the order the card shows them: {label, its older names, title, effect}.
  @known [
    {"plan", ["breakdown"], "Plan", "Groom into sub-tickets before any work starts"},
    {"type:bug", [], "Bug", "The bug steps, and back to Backlog without its sections"},
    {"type:feature", [], "Feature", "The feature steps, and back to Backlog without its sections"},
    {"qa:skip", [], "Skip QA", "Once approved, it goes on without a QA pass"},
    {"skip-update-hold", [], "Skip the app update wait", "Doesn't wait for an app update with its blocker's fix"},
    {"qa:live", [], "QA on the live server", "QA runs Symphony's own server, whatever Symphony picks"},
    {"qa:fixture", [], "QA on fixtures", "QA reads the committed fixtures only, whatever Symphony picks"}
  ]

  @escalate_effect "Code Review asks you before approving"

  @type error :: {:conflict, String.t()} | {:linear, String.t()}
  @type action :: :add | :remove

  @doc """
  The toggles for a repository's settings (`:escalate_labels` and `:force_label` from them when not
  given): each `%{label, aliases, title, effect}`, the labels Symphony reads first, then each
  `escalate.labels` entry they don't name. A machine label or the force label is never one.
  """
  @spec toggles(keyword()) :: [map()]
  def toggles(opts \\ []) do
    known = Enum.map(@known, fn {label, aliases, title, effect} -> %{label: label, aliases: aliases, title: title, effect: effect} end)
    named = known |> Enum.flat_map(&[&1.label | &1.aliases]) |> MapSet.new(&normalize/1)

    escalate =
      opts
      |> Keyword.get(:escalate_labels, [])
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map(&String.trim/1)
      |> Enum.uniq_by(&normalize/1)
      |> Enum.reject(&MapSet.member?(named, normalize(&1)))
      |> Enum.map(&%{label: &1, aliases: [], title: &1, effect: @escalate_effect})

    force = normalize(Keyword.get(opts, :force_label))
    Enum.reject(known ++ escalate, &(MachineLabels.owned?(&1.label) or normalize(&1.label) == force))
  end

  @doc """
  Adds (`:add`) or removes (`:remove`) the label `label` on the ticket `identifier` (identifier or
  id), as the moduledoc says. Answers the ticket's toggles after the change.

  Options: `:tracker` (default `SymphonyElixir.Tracker`), `:orchestrator` (asked to poll again,
  default `SymphonyElixir.Orchestrator`), `:audit_log` (the audit log's options), `:records` (the
  tracked records, default every record in the run store), `:escalate_labels` and `:force_label`
  (default the ticket's repository's settings, read with `:settings_for_repo`, default
  `SymphonyElixir.Config.settings_for_repo/1`).
  """
  @spec set(String.t(), String.t(), action(), keyword()) :: {:ok, map()} | {:error, error()}
  def set(identifier, label, action, opts \\ []) when is_binary(identifier) and is_binary(label) and action in [:add, :remove] do
    with {:ok, ticket} <- find(records(opts), identifier),
         settings = settings_opts(ticket, opts),
         toggles = toggles(settings),
         {:ok, toggle} <- toggle(toggles, ticket, label, settings[:force_label]),
         {:ok, names} <- changes(ticket, toggle, action),
         :ok <- write_tracker(ticket, toggle, names, action, opts) do
      record = write_record(ticket, toggle, names, action)
      record_action(ticket, toggle, action, opts)
      Orchestrator.request_refresh(Keyword.get(opts, :orchestrator, Orchestrator), record.repo_key, due: :now)
      Logger.info("Director #{move(action)} issue_identifier=#{record.issue_identifier} label=#{toggle.label}")

      {:ok, Map.put(json(record, toggles), :action, move(action))}
    end
  end

  @doc """
  The toggles of the ticket `identifier` (identifier or id), each `on` when the ticket's record
  holds the label. `{:error, {:conflict, message}}` for a ticket Symphony doesn't track. Options as
  for `set/4`.
  """
  @spec labels(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def labels(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, ticket} <- find(records(opts), identifier), do: {:ok, json(ticket, toggles(settings_opts(ticket, opts)))}
  end

  defp records(opts) do
    opts
    |> Keyword.get_lazy(:records, fn -> List.wrap(with({:error, _reason} <- RunStore.list_all_ticket_states(), do: [])) end)
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.filter(&(is_binary(&1.issue_id) and is_binary(&1.repo_key) and is_nil(&1.removed_at)))
  end

  defp find(records, name) do
    name = String.trim(name)

    case Enum.find(records, &(&1.issue_id == name or same_identifier?(&1.issue_identifier, name))) do
      nil -> {:error, {:conflict, TicketMoves.untracked_reason(:labels, name)}}
      record -> {:ok, record}
    end
  end

  defp same_identifier?(identifier, name) when is_binary(identifier), do: String.upcase(identifier) == String.upcase(name)
  defp same_identifier?(_identifier, _name), do: false

  # The repository's escalate labels and force label, unless the caller gave them; without its
  # settings, the built-in escalate labels and `expedite`.
  defp settings_opts(ticket, opts) do
    if Keyword.has_key?(opts, :escalate_labels) and Keyword.has_key?(opts, :force_label) do
      opts
    else
      settings =
        case Keyword.get(opts, :settings_for_repo, &Config.settings_for_repo/1).(ticket.repo_key) do
          {:ok, settings} -> settings
          {:error, _reason} -> nil
        end

      opts
      |> Keyword.put_new_lazy(:escalate_labels, fn -> escalate_labels(settings) end)
      |> Keyword.put_new_lazy(:force_label, fn -> force_label(settings) end)
    end
  end

  defp escalate_labels(%{auto_review: %{acceptance_gate: %{escalate: %{labels: labels}}}}) when is_list(labels), do: labels
  defp escalate_labels(_settings), do: Escalate.built_in().labels

  defp force_label(%{agent: %{force_label: label}}) when is_binary(label), do: label
  defp force_label(_settings), do: "expedite"

  defp toggle(toggles, ticket, label, force_label) do
    wanted = normalize(label)

    case Enum.find(toggles, &(wanted in Enum.map([&1.label | &1.aliases], fn name -> normalize(name) end))) do
      nil -> {:error, {:conflict, refusal(ticket, String.trim(label), force_label)}}
      toggle -> {:ok, toggle}
    end
  end

  defp refusal(ticket, label, force_label) do
    cond do
      MachineLabels.owned?(label) ->
        "#{label} is Symphony's own label: it sets and clears it itself, so it can't be changed on #{ticket.issue_identifier}."

      normalize(label) == normalize(force_label) ->
        "#{label} is the force label: Force (or Stop Forcing) on #{ticket.issue_identifier} sets it."

      true ->
        "#{inspect(label)} isn't a label Symphony reads, so it can't be changed on #{ticket.issue_identifier} from here."
    end
  end

  # The names to write: the label to add, or every name of the toggle the ticket carries to remove.
  defp changes(ticket, toggle, action) do
    carried = Enum.filter(ticket.labels, &(normalize(&1) in names(toggle)))

    case {action, carried} do
      {:add, []} -> {:ok, [toggle.label]}
      {:add, _carried} -> {:error, {:conflict, "#{ticket.issue_identifier} already has #{toggle.title} on."}}
      {:remove, []} -> {:error, {:conflict, "#{ticket.issue_identifier} doesn't have #{toggle.title} on."}}
      {:remove, carried} -> {:ok, carried}
    end
  end

  defp names(toggle), do: Enum.map([toggle.label | toggle.aliases], &normalize/1)

  defp write_tracker(ticket, toggle, names, action, opts) do
    tracker = Keyword.get(opts, :tracker, SymphonyElixir.Tracker)

    Enum.reduce_while(names, :ok, fn name, :ok ->
      case write(tracker, action, ticket.issue_id, name) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning("Failed to write a label issue_id=#{ticket.issue_id} label=#{name} action=#{action}: #{inspect(reason)}")
          {:halt, {:error, {:linear, write_failure(ticket, toggle, action, reason)}}}
      end
    end)
  end

  defp write(tracker, :add, issue_id, name), do: tracker.add_issue_label(issue_id, name)
  defp write(tracker, :remove, issue_id, name), do: tracker.remove_issue_label(issue_id, name)

  # The reason a write failed, in the words the app shows; the raw reason goes to the log.
  defp write_failure(ticket, toggle, action, reason) do
    change = if action == :add, do: "turn on #{toggle.title} on #{ticket.issue_identifier}", else: "turn off #{toggle.title} on #{ticket.issue_identifier}"

    cond do
      missing_key?(reason) -> "Symphony has no Linear API key, so it couldn't #{change} in Linear."
      match?({:label_not_found, _name}, reason) -> "Linear has no #{toggle.label} label, so Symphony couldn't #{change}. Create the label in Linear, then try again."
      true -> "Linear didn't #{change}, so nothing changed. Try again in a moment."
    end
  end

  defp missing_key?(:missing_linear_api_token), do: true
  defp missing_key?({_kind, :missing_linear_api_token}), do: true
  defp missing_key?(_reason), do: false

  defp write_record(ticket, toggle, names, action) do
    labels =
      case action do
        :add -> ticket.labels ++ names
        :remove -> Enum.reject(ticket.labels, &(normalize(&1) in names(toggle)))
      end

    case RunStore.update_ticket_state(ticket.issue_id, %{labels: labels, updated_at: DateTime.utc_now()}) do
      :ok -> :ok = ObservabilityPubSub.broadcast_ticket_record_changed(ticket.repo_key, ticket.issue_id, [:labels])
      error -> Logger.warning("Failed to write the labels of issue_id=#{ticket.issue_id}: #{inspect(error)}")
    end

    %{ticket | labels: labels}
  end

  defp record_action(ticket, toggle, action, opts) do
    %{
      event_type: "director_move",
      move: move(action),
      repo_key: ticket.repo_key,
      issue_id: ticket.issue_id,
      issue_identifier: ticket.issue_identifier,
      label: toggle.label,
      label_title: toggle.title
    }
    |> AuditLog.record(Keyword.get(opts, :audit_log, []))
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record director_move audit event: issue_id=#{ticket.issue_id} reason=#{inspect(reason)}")
    end

    payload = %{action: move(action), label: toggle.label}
    TicketSignals.record_event(ticket.repo_key, ticket.issue_id, "person.action", payload, actor: @director)
  end

  defp move(:add), do: "add_label"
  defp move(:remove), do: "remove_label"

  defp json(record, toggles) do
    carried = MapSet.new(record.labels, &normalize/1)

    %{
      issue_identifier: record.issue_identifier,
      labels:
        Enum.map(toggles, fn toggle ->
          %{label: toggle.label, title: toggle.title, effect: toggle.effect, on: Enum.any?(names(toggle), &MapSet.member?(carried, &1))}
        end)
    }
  end

  defp normalize(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize(_name), do: ""
end
