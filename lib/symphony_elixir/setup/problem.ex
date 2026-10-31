defmodule SymphonyElixir.Setup.Problem do
  @moduledoc """
  One setup problem as `GET /api/v1/setup` reports it.

  `id` is stable across runs (the check and its subject, `deprecated_key:auto_review.enabled`), so
  the app can tell a problem it already showed from a new one. `consequence` says in plain words
  what breaks. `repos` are repository keys, `tickets` the Linear issues it touches, `details` the
  label/value lines the app shows under Details, and `fix` how it is fixed:

    * `config_edit` (`path`, `action` `remove` | `set` | `add`, `value`): the app applies the edit
      to `symphony.yml` through its settings writer once the operator confirms it.
    * `linear` (`action`, `team`, `name`, `type`): the service runs it once the operator confirms,
      through `POST /api/v1/setup/fixes` (`SymphonyElixir.Setup.Fixes`). `create_label` creates the
      label `name` in the team `team`. `create_state` (`after`, `position`) creates the workflow
      state `name` of the type `type` in the team `team`, at `position` in its board: just after the
      state `after` (nil when the state goes first of its type).
    * `open` (`target` `settings` | `symphony_yml` | `linear` | `drain_report` | `repos`, `url`): no
      fix is safe, so the app shows the button that goes where the operator fixes it.
  """

  @severities [:error, :warning]
  @categories [:routing, :teams, :labels, :statuses, :keys, :secrets, :runtime]
  @edit_actions [:remove, :set, :add]
  @open_targets [:settings, :symphony_yml, :linear, :drain_report, :repos]

  @type severity :: :error | :warning
  @type category :: :routing | :teams | :labels | :statuses | :keys | :secrets | :runtime
  @type detail :: %{label: String.t(), value: String.t()}
  @type ticket :: %{identifier: String.t(), url: String.t() | nil}
  @type fix :: %{required(:kind) => String.t(), optional(atom()) => term()}

  @type t :: %{
          id: String.t(),
          severity: String.t(),
          category: String.t(),
          title: String.t(),
          consequence: String.t(),
          repos: [String.t()],
          tickets: [ticket()],
          details: [detail()],
          fix: fix() | nil
        }

  @doc """
  Builds a problem. `id`, `severity`, `category`, `title` and `consequence` are required; `repos`,
  `tickets`, `details` (a keyword or `{label, value}` list; a nil value is left out) and `fix` are
  optional. An unknown severity or category raises.
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    %{
      id: Keyword.fetch!(attrs, :id),
      severity: attrs |> Keyword.fetch!(:severity) |> member!(@severities, :severity),
      category: attrs |> Keyword.fetch!(:category) |> member!(@categories, :category),
      title: Keyword.fetch!(attrs, :title),
      consequence: Keyword.fetch!(attrs, :consequence),
      repos: Keyword.get(attrs, :repos, []),
      tickets: Keyword.get(attrs, :tickets, []),
      details: attrs |> Keyword.get(:details, []) |> details(),
      fix: Keyword.get(attrs, :fix)
    }
  end

  @doc "A `symphony.yml` edit the app applies through its settings writer."
  @spec config_edit(String.t(), :remove | :set | :add, term()) :: fix()
  def config_edit(path, action, value \\ nil) when is_binary(path) do
    %{kind: "config_edit", path: path, action: member!(action, @edit_actions, :action), value: value}
  end

  @doc "A Linear change the service runs, such as creating a missing state or label in a team."
  @spec linear(String.t(), String.t(), String.t(), String.t() | nil) :: fix()
  def linear(action, team, name, type \\ nil) when is_binary(action) and is_binary(team) and is_binary(name) do
    %{kind: "linear", action: action, team: team, name: name, type: type}
  end

  @doc """
  Creates the workflow state `name` of `type` in `team`, at `position` (nil: where Linear puts it),
  just after the state `after`.
  """
  @spec create_state(String.t(), String.t(), String.t(), String.t() | nil, number() | nil) :: fix()
  def create_state(team, name, type, after_state, position) when is_binary(type) do
    Map.merge(linear("create_state", team, name, type), %{after: after_state, position: position})
  end

  @doc "No safe fix: the place where the operator fixes it."
  @spec open(atom(), String.t() | nil) :: fix()
  def open(target, url \\ nil) do
    %{kind: "open", target: member!(target, @open_targets, :target), url: url}
  end

  defp details(details) do
    for {label, value} <- details, not is_nil(value), do: %{label: to_string(label), value: to_string(value)}
  end

  defp member!(value, allowed, field) do
    if value in allowed, do: Atom.to_string(value), else: raise(ArgumentError, "unknown setup problem #{field} #{inspect(value)}")
  end
end
