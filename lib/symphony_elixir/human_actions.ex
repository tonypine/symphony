defmodule SymphonyElixir.HumanActions do
  @moduledoc """
  Posts a Linear project update listing everything only a human can do in a project.

  Every `human_actions.interval_ms`, `SymphonyElixir.HumanActions.Collector` reads the open
  actions in the scope of each repository with `human_actions.enabled`. A project gets a new
  update (`SymphonyElixir.HumanActions.Update`) only when its set of open actions differs from
  the set in the last update Symphony posted to it, and at most once per
  `human_actions.min_update_interval_ms`; a change inside that window is posted once it passes.
  When the last action closes, one short "Nothing needs you" update says so, and nothing more is
  posted until a new action opens. Each new action also goes out as a `human_action_needed`
  notification.

  The last list posted is remembered per project. After a restart it is read back from the list
  id in the project's recent updates the first time the project is seen, so a restart does not
  post the same list again. A project whose every action closed while Symphony was down is not
  seen again until it has a new action, and keeps its last update until then.

  The server tags itself `human_actions` in `SymphonyElixir.Linear.Usage`, so its Linear requests
  show under that caller on the dashboard.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.AgentTools.SecretScanner
  alias SymphonyElixir.{Config, Notifications}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Collector, Update}
  alias SymphonyElixir.Linear.{Client, Usage}

  @initial_delay_ms 60_000
  @refresh_delay_ms 5_000
  @recent_updates 10

  @project_updates_query """
  query SymphonyHumanActionsLastUpdate($id: String!, $first: Int!) {
    project(id: $id) {
      projectUpdates(first: $first) {
        nodes { body createdAt }
      }
    }
  }
  """

  @create_update_mutation """
  mutation SymphonyHumanActionsPostUpdate($input: ProjectUpdateCreateInput!) {
    projectUpdateCreate(input: $input) {
      success
      projectUpdate { id url }
    }
  }
  """

  @typedoc """
  What Symphony last posted to a project: the list id, when, and the action keys (nil when read
  back after a restart).
  """
  @type posted :: %{
          list_id: String.t() | nil,
          posted_at_ms: integer() | nil,
          keys: MapSet.t(String.t()) | nil,
          name: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether human-action updates are on for these settings: a Linear tracker and `human_actions.enabled`."
  @spec enabled?(Schema.t()) :: boolean()
  def enabled?(%Schema{tracker: %{kind: "linear"}, human_actions: %{enabled: true}}), do: true
  def enabled?(_settings), do: false

  @doc "Asks the server to read the actions again in a few seconds, after a new request. A no-op when it is not running."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> send(pid, :refresh)
      nil -> :ok
    end

    :ok
  end

  @impl true
  def init(opts) do
    Usage.put_caller(:human_actions)
    timer = Process.send_after(self(), :tick, Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
    {:ok, %{opts: opts, projects: %{}, timer: timer}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = run_once(state)
    {:noreply, schedule(state, settings(state).human_actions.interval_ms)}
  end

  def handle_info(:refresh, state), do: {:noreply, schedule(state, Keyword.get(state.opts, :refresh_delay_ms, @refresh_delay_ms))}

  defp schedule(state, delay_ms) do
    Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, delay_ms)}
  end

  @doc false
  @spec run_once(map()) :: map()
  def run_once(state) do
    settings = settings(state)
    collect = Keyword.get(state.opts, :collect, &Collector.collect/2)
    collect_opts = Keyword.merge([settings: settings, linear_client: linear_client(state)], Keyword.take(state.opts, [:scope_filter]))

    with {:ok, repos} <- enabled_repos(state),
         {:ok, collected} <- collect.(repos, collect_opts) do
      collected
      |> Map.keys()
      |> Enum.concat(listed_project_ids(state))
      |> Enum.uniq()
      |> Enum.reduce(state, &sync_project(&1, Map.get(collected, &1), settings, &2))
    else
      {:error, reason} ->
        Logger.warning("Human actions: could not read the open actions: #{inspect(reason)}")
        state
    end
  end

  # Projects whose last update listed actions: they need a "Nothing needs you" update once their
  # last action closes, even when no issue of theirs is read anymore.
  defp listed_project_ids(state) do
    empty = Update.list_id([])
    for {project_id, %{list_id: list_id}} <- state.projects, list_id not in [nil, empty], do: project_id
  end

  defp sync_project(project_id, collected, settings, state) do
    actions = if collected, do: collected.actions, else: []

    case last_posted(state, project_id, collected) do
      {:ok, posted} ->
        state = put_in(state.projects[project_id], posted)
        list_id = Update.list_id(actions)

        cond do
          posted.list_id == list_id -> state
          is_nil(posted.list_id) and actions == [] -> state
          rate_limited?(posted, settings, state) -> state
          true -> post(state, project_id, posted, actions, settings)
        end

      {:error, reason} ->
        Logger.warning("Human actions: could not read the last update of project #{project_id}: #{inspect(reason)}")
        state
    end
  end

  defp last_posted(state, project_id, collected) do
    case Map.fetch(state.projects, project_id) do
      {:ok, posted} -> {:ok, %{posted | name: project_name(collected) || posted.name}}
      :error -> recover(state, project_id, project_name(collected))
    end
  end

  defp project_name(%{project: %{name: name}}), do: name
  defp project_name(nil), do: nil

  defp recover(state, project_id, name) do
    with {:ok, body} <- graphql(state, @project_updates_query, %{id: project_id, first: @recent_updates}) do
      latest =
        body
        |> get_in(["data", "project", "projectUpdates", "nodes"])
        |> List.wrap()
        |> Enum.flat_map(&posted_update/1)
        |> Enum.max_by(& &1.posted_at_ms, fn -> %{list_id: nil, posted_at_ms: nil} end)

      {:ok, Map.merge(latest, %{keys: nil, name: name})}
    end
  end

  defp posted_update(%{"body" => body, "createdAt" => created_at}) do
    with list_id when is_binary(list_id) <- Update.list_id_from_body(body),
         {:ok, at, _offset} <- DateTime.from_iso8601(to_string(created_at)) do
      [%{list_id: list_id, posted_at_ms: DateTime.to_unix(at, :millisecond)}]
    else
      _other -> []
    end
  end

  defp posted_update(_node), do: []

  defp rate_limited?(%{posted_at_ms: posted_at_ms}, settings, state) when is_integer(posted_at_ms),
    do: now_ms(state) - posted_at_ms < settings.human_actions.min_update_interval_ms

  defp rate_limited?(_posted, _settings, _state), do: false

  defp post(state, project_id, posted, actions, settings) do
    {body, patterns} = Update.render(actions, settings.human_actions.label)
    SecretScanner.audit_redaction(patterns, %{}, "human_actions", "project_update", Keyword.get(state.opts, :audit_opts, []))
    input = %{"projectId" => project_id, "body" => body, "health" => Update.health(actions)}

    case graphql(state, @create_update_mutation, %{input: input}) do
      {:ok, %{"data" => %{"projectUpdateCreate" => %{"success" => true}}}} ->
        Logger.info("Human actions: posted #{length(actions)} open action(s) to project #{posted.name || project_id}")
        notify_new(state, actions, posted)
        posted = %{posted | list_id: Update.list_id(actions), posted_at_ms: now_ms(state), keys: MapSet.new(actions, & &1.key)}
        put_in(state.projects[project_id], posted)

      other ->
        Logger.warning("Human actions: could not post the update to project #{posted.name || project_id}: #{inspect(other)}")
        state
    end
  end

  # After a restart the previous keys are unknown, so every listed action counts as new.
  defp notify_new(state, actions, posted) do
    notify = Keyword.get(state.opts, :notify, &Notifications.emit_event/2)

    for action <- actions, is_nil(posted.keys) or not MapSet.member?(posted.keys, action.key) do
      {title, _patterns} = SecretScanner.redact(action.title)

      notify.(:human_action_needed, %{
        issue_id: action.issue.id,
        issue_identifier: action.issue.identifier,
        issue_title: action.issue.title,
        issue_url: action.issue.url,
        reason: title,
        metadata: %{"project" => action.project.name, "kind" => Atom.to_string(action.kind)}
      })
    end
  end

  defp enabled_repos(state) do
    case Keyword.fetch(state.opts, :repos) do
      {:ok, repos_fun} -> repos_fun.()
      :error -> configured_enabled_repos()
    end
  end

  defp configured_enabled_repos do
    with {:ok, repos} <- Config.repos() do
      {:ok, Enum.filter(repos, &enabled?(Config.settings_for_repo!(&1.name)))}
    end
  end

  defp settings(state), do: Keyword.get(state.opts, :settings_fun, &Config.settings!/0).()

  defp now_ms(state), do: Keyword.get(state.opts, :now_ms, fn -> System.system_time(:millisecond) end).()

  defp linear_client(state), do: Keyword.get(state.opts, :linear_client, &Client.graphql/3)

  defp graphql(state, query, variables) do
    case linear_client(state).(query, variables, []) do
      {:ok, %{"errors" => [_ | _] = errors}} -> {:error, {:linear_graphql_errors, errors}}
      result -> result
    end
  end
end
