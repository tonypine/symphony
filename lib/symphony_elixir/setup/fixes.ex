defmodule SymphonyElixir.Setup.Fixes do
  @moduledoc """
  Runs a `linear` Setup fix the operator confirmed, for `POST /api/v1/setup/fixes`.

  A fix runs only as the latest check proposed it: a descriptor that no problem's `fix` names is
  refused, so nothing is created that the operator wasn't shown, and what runs is the proposed fix:

    * `create_label` creates the label `name` in the team `team`;
    * `create_state` creates the workflow state `name` of the type `type` in the team `team`, at the
      `position` the check worked out from the team's board (`SymphonyElixir.Setup.Checks.Statuses`).
      The request names the state and its type; it needn't repeat the place, as the app's doesn't,
      but a place it names (`after`, `position`) must be the proposed one;
  Then the checks run again with the team cache emptied (`SymphonyElixir.Setup.refresh/1`), and the
  new payload is returned. When Linear refuses (permissions, a name already taken), the error says
  so in plain words with what to do, the checks are not re-run, and the problem stays where it was.
  A create (a label or a state) is one Linear write,
  so it lands whole or not at all.
  """

  alias SymphonyElixir.{Setup, Tracker}
  alias SymphonyElixir.Setup.Checks.Statuses

  @typedoc "Why a fix didn't run, or ran without the checks after it."
  @type error :: :not_proposed | :not_running | {:refused, String.t()}

  @doc """
  Runs `descriptor` (a fix as the payload lists it, with string keys). Options: `:server` (the Setup
  server, `SymphonyElixir.Setup` by default) and `:tracker`.

  Returns `{:ok, payload}` after the checks ran again, `{:error, :not_proposed}` for a descriptor
  the latest check didn't propose, `{:error, {:refused, message}}` when Linear refused it, or
  `{:error, :not_running}` without a running Setup server.
  """
  @spec run(map() | term(), keyword()) :: {:ok, Setup.payload()} | {:error, error()}
  def run(descriptor, opts) do
    server = Keyword.get(opts, :server, Setup)

    with %{problems: problems} <- Setup.payload(server),
         {:ok, fix} <- proposed(descriptor, problems),
         :ok <- apply_fix(fix, Keyword.get(opts, :tracker, Tracker)) do
      refreshed(Setup.refresh(server))
    end
  end

  defp proposed(descriptor, problems) do
    case is_map(descriptor) && to_run(descriptor, problems) do
      %{} = fix -> {:ok, fix}
      _not_proposed -> {:error, :not_proposed}
    end
  end

  defp refreshed({:error, :not_running} = error), do: error
  defp refreshed(payload), do: {:ok, payload}

  # The fix `descriptor` asks for, as the latest check proposed it; nil when none did.
  defp to_run(descriptor, problems) do
    Enum.find_value(problems, fn %{fix: fix} -> fix && covers(stringify(fix), descriptor) end)
  end

  defp covers(%{"kind" => "linear", "action" => "create_label"} = fix, descriptor) do
    if same?(fix, descriptor, ~w(kind action team name)), do: fix
  end

  # The place is the check's: the request may leave it out, and one it names must be the proposed one.
  defp covers(%{"kind" => "linear", "action" => "create_state"} = fix, descriptor) do
    if same?(fix, descriptor, ~w(kind action team name type) ++ Enum.filter(~w(after position), &Map.has_key?(descriptor, &1))), do: fix
  end

  defp covers(_fix, _descriptor), do: nil

  defp same?(fix, descriptor, keys), do: Map.take(fix, keys) == Map.take(descriptor, keys)

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
