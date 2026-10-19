defmodule SymphonyElixir.Setup.Fixes do
  @moduledoc """
  Runs a `linear` Setup fix the operator confirmed, for `POST /api/v1/setup/fixes`.

  A fix runs only as the latest check proposed it: a descriptor that no problem's `fix` names is
  refused, so nothing is created that the operator wasn't shown. It does exactly what its descriptor
  says:

    * `create_label` creates the label `name` in the team `team`;
    * `create_state` creates the workflow state `name` of the type `type` in the team `team`, at
      `position` (`SymphonyElixir.Setup.Checks.Statuses` works it out from the team's board);
    * `resync_hold` re-syncs the hold label of each ticket it names from the store
      (`SymphonyElixir.Hold.resync/4`): one of the tickets the check listed, or all of them.

  Then the checks run again with the team cache emptied (`SymphonyElixir.Setup.refresh/1`), and the
  new payload is returned. When Linear refuses (permissions, a name already taken), the error says
  so in plain words with what to do, the checks are not re-run, and the problem stays where it was.
  A create (a label or a state) is one Linear write,
  so it lands whole or not at all; a re-sync of several tickets puts right the ones Linear accepts
  and names the rest.
  """

  alias SymphonyElixir.{Hold, Setup, Tracker}
  alias SymphonyElixir.Hold.Drift
  alias SymphonyElixir.Setup.Checks.{HoldDrift, Statuses}

  @doc """
  Runs `descriptor` (a fix as the payload lists it, with string keys). Options: `:server` (the Setup
  server, `SymphonyElixir.Setup` by default) and `:tracker`.

  Returns `{:ok, payload}` after the checks ran again, `{:error, :not_proposed}` for a descriptor
  the latest check didn't propose, or `{:error, {:refused, message}}` when Linear refused it.
  """
  @spec run(map() | term(), keyword()) :: {:ok, Setup.payload()} | {:error, :not_proposed | {:refused, String.t()}}
  def run(descriptor, opts) do
    server = Keyword.get(opts, :server, Setup)

    if is_map(descriptor) and proposed?(descriptor, Setup.payload(server).problems) do
      with :ok <- apply_fix(descriptor, Keyword.get(opts, :tracker, Tracker)), do: {:ok, Setup.refresh(server)}
    else
      {:error, :not_proposed}
    end
  end

  defp proposed?(descriptor, problems) do
    Enum.any?(problems, fn %{fix: fix} -> fix && covers?(stringify(fix), descriptor) end)
  end

  defp covers?(%{"kind" => "linear", "action" => "create_label"} = fix, descriptor) do
    Map.take(fix, ~w(kind action team name)) == Map.take(descriptor, ~w(kind action team name))
  end

  defp covers?(%{"kind" => "linear", "action" => "create_state"} = fix, descriptor) do
    Map.take(fix, ~w(kind action team name type after position)) == Map.take(descriptor, ~w(kind action team name type after position))
  end

  defp covers?(%{"kind" => "linear", "action" => "resync_hold", "repo" => repo, "tickets" => tickets}, descriptor) do
    case descriptor do
      %{"kind" => "linear", "action" => "resync_hold", "repo" => ^repo, "tickets" => [_ | _] = wanted} -> Enum.all?(wanted, &(&1 in tickets))
      _other -> false
    end
  end

  defp covers?(_fix, _descriptor), do: false

  defp stringify(fix), do: Map.new(fix, fn {key, value} -> {to_string(key), value} end)

  defp apply_fix(%{"action" => "create_label", "team" => team, "name" => name}, tracker) do
    case tracker.create_label(name, team) do
      {:ok, _label} -> :ok
      {:error, reason} -> {:error, {:refused, refusal(~s(create the label "#{name}" in team #{team}), reason)}}
    end
  end

  defp apply_fix(%{"action" => "create_state", "team" => team, "name" => name, "type" => type} = fix, tracker) do
    case tracker.create_workflow_state(name, team, Statuses.color(type), type: type, position: fix["position"]) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, {:refused, refusal(~s(create the state "#{name}" in team #{team}), reason)}}
    end
  end

  defp apply_fix(%{"action" => "resync_hold", "repo" => repo, "tickets" => tickets}, tracker) do
    entries = Drift.entries()

    failures =
      for name <- tickets,
          %{} = entry <- [Enum.find(entries, &(&1.repo_key == repo and HoldDrift.ticket_name(&1) == name))],
          {:error, reason} <- [resync(entry, tracker)],
          do: refusal("re-sync the hold label of #{name}", reason)

    case failures do
      [] -> :ok
      failures -> {:error, {:refused, Enum.join(failures, " ")}}
    end
  end

  defp resync(%{drift: {_direction, kind}} = entry, tracker), do: Hold.resync(entry.repo_key, entry.issue_id, kind, tracker: tracker)

  defp refusal(what, reason), do: "Linear refused to #{what}: #{describe(reason)}"

  defp describe({:team_not_found, team}), do: "it has no team #{team}. Check the team the repository is routed to, then check again."

  defp describe(:label_create_failed),
    do: "a label with that name may already exist in the team or the workspace. Rename or remove it in Linear, then check again."

  defp describe(:workflow_state_create_failed),
    do: "a state with that name may already exist in the team. Rename or remove it in Linear, then check again."

  defp describe({:linear_api_status, status, _body}) when status in [401, 403],
    do: "the Linear API key isn't allowed to (HTTP #{status}). Ask an admin of the team to do it, or use a key that may."

  defp describe({:linear_api_status, status, _body}), do: "Linear answered HTTP #{status}. Try again in a minute."

  defp describe({:linear_graphql_errors, errors}) do
    messages = errors |> List.wrap() |> Enum.map_join("; ", &error_message/1)
    "#{messages}. Fix it in Linear, or ask an admin of the team, then check again."
  end

  defp describe(reason), do: "#{inspect(reason)}. Fix it in Linear, then check again."

  defp error_message(%{"extensions" => %{"userPresentableMessage" => message}}) when is_binary(message), do: message
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)
end
