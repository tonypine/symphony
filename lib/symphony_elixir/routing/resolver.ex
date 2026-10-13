defmodule SymphonyElixir.Routing.Resolver do
  @moduledoc """
  Pure issue-to-repository routing for multi-repo orchestration.

  Repo route entries use the flat `repos:` shape from `symphony.yml`:
  `team`, `projects`, `labels`, and `assignee` are optional filters.
  A single unscoped repo, or an explicit default repo, can rely on the
  tracker-level Linear scope.

  Call `validate_repos!/1` during startup after loading the repo list. The
  resolver functions assume startup structural validation has already rejected
  invalid or ambiguous repo definitions, and only evaluate match semantics.
  """

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Linear.Issue

  @type repo_map :: %{
          optional(:name) => String.t(),
          optional(:team) => String.t(),
          optional(:projects) => [String.t()],
          optional(:labels) => [String.t()],
          optional(:assignee) => String.t(),
          optional(:default) => boolean(),
          optional(String.t()) => term()
        }
  @type repo :: SystemSchema.Repo.t() | repo_map()
  @type validation_error ::
          {:unscoped_repo, repo()}
          | {:identical_match_rules, [repo()]}
          | {:ambiguous_team_catch_all, String.t(), [repo()]}
          | {:multiple_defaults, String.t(), [repo()]}
  @type result :: {:matched, repo()} | {:conflict, [repo()]} | :unmatched

  @spec resolve(Issue.t() | map(), [repo()]) :: result()
  def resolve(issue, repos) when is_list(repos) do
    matches = Enum.filter(repos, &matches?(issue, &1))

    case matches do
      [] -> :unmatched
      [repo] -> {:matched, repo}
      matched -> {:conflict, matched}
    end
  end

  @doc """
  Gives an issue fetched from the tracker, which carries no repo key, the key of the repo it routes
  to, so holds, signals and guard moves read and write it under that repo. An issue that already
  has a key is returned as it is; one no repo or more than one non-default repo matches keeps none.
  """
  @spec with_repo_key(Issue.t(), [repo()]) :: Issue.t()
  def with_repo_key(%Issue{repo_key: repo_key} = issue, _repos) when is_binary(repo_key) and repo_key != "", do: issue

  def with_repo_key(%Issue{} = issue, repos) when is_list(repos) do
    case resolve(issue, repos) do
      {:matched, repo} -> %{issue | repo_key: repo_value(repo, :name)}
      {:conflict, matched} -> routed_past_defaults(issue, matched)
      :unmatched -> issue
    end
  end

  # A default repo catches what its team's scoped repos don't, so a scoped match wins over it.
  defp routed_past_defaults(issue, matched) do
    case Enum.reject(matched, &default?/1) do
      [repo] -> %{issue | repo_key: repo_value(repo, :name)}
      _none_or_many -> issue
    end
  end

  @spec validate_repos([repo()]) :: :ok | {:error, [validation_error()]}
  def validate_repos(repos) when is_list(repos) do
    errors =
      Enum.concat([
        unscoped_repo_errors(repos),
        identical_match_rule_errors(repos),
        ambiguous_team_catch_all_errors(repos),
        multiple_default_errors(repos)
      ])

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @spec validate_repos!([repo()]) :: :ok
  def validate_repos!(repos) when is_list(repos) do
    case validate_repos(repos) do
      :ok -> :ok
      {:error, errors} -> raise ArgumentError, message: "invalid routing repos: #{inspect(errors)}"
    end
  end

  @spec matches?(Issue.t() | map(), repo()) :: boolean()
  def matches?(issue, repo) when is_map(repo) do
    rule = match_rule(repo)

    team_matches?(issue, rule.team) and
      project_matches?(issue, rule.projects) and
      labels_match?(issue, rule.labels) and
      assignee_matches?(issue, rule.assignee)
  end

  def matches?(_issue, _repo), do: false

  defp unscoped_repo_errors([_repo]), do: []

  defp unscoped_repo_errors(repos) do
    repos
    |> Enum.filter(&(unscoped?(&1) and not default?(&1)))
    |> Enum.map(&{:unscoped_repo, &1})
  end

  defp identical_match_rule_errors(repos) do
    repos
    |> Enum.group_by(&match_signature/1)
    |> Enum.reject(fn {signature, grouped_repos} -> signature == :invalid or length(grouped_repos) == 1 end)
    |> Enum.map(fn {_signature, grouped_repos} -> {:identical_match_rules, grouped_repos} end)
  end

  defp ambiguous_team_catch_all_errors(repos) do
    repos
    |> Enum.group_by(&match_rule(&1).team)
    |> Enum.reject(fn {team, _team_repos} -> not present_string?(team) end)
    |> Enum.flat_map(fn {team, team_repos} ->
      catch_all_repos = Enum.filter(team_repos, &team_only?/1)

      cond do
        length(catch_all_repos) > 1 ->
          [{:ambiguous_team_catch_all, team, catch_all_repos}]

        length(team_repos) > 1 and single_non_default_catch_all?(catch_all_repos) ->
          [{:ambiguous_team_catch_all, team, catch_all_repos}]

        true ->
          []
      end
    end)
  end

  defp multiple_default_errors(repos) do
    repos
    |> Enum.filter(&default?/1)
    |> Enum.group_by(&match_rule(&1).team)
    |> Enum.reject(fn {team, default_repos} -> not present_string?(team) or length(default_repos) == 1 end)
    |> Enum.map(fn {team, default_repos} -> {:multiple_defaults, team, default_repos} end)
  end

  defp single_non_default_catch_all?([repo]), do: not default?(repo)
  defp single_non_default_catch_all?(_repos), do: false

  defp match_signature(repo) do
    rule = match_rule(repo)

    if scoped?(rule) do
      {rule.team, rule.projects, rule.labels, rule.assignee}
    else
      :unscoped
    end
  end

  defp match_rule(repo) do
    %{
      team: repo_value(repo, :team) |> normalize_string(),
      projects: repo_value(repo, :projects) |> normalize_string_list(:project),
      labels: repo_value(repo, :labels) |> normalize_string_list(:label),
      assignee: repo_value(repo, :assignee) |> normalize_string()
    }
  end

  defp team_only?(repo) do
    rule = match_rule(repo)

    present_string?(rule.team) and rule.projects == [] and rule.labels == [] and is_nil(rule.assignee)
  end

  defp unscoped?(repo), do: not scoped?(match_rule(repo))

  defp scoped?(rule) do
    present_string?(rule.team) or rule.projects != [] or rule.labels != [] or not is_nil(rule.assignee)
  end

  defp default?(repo), do: repo_value(repo, :default) == true

  defp team_matches?(_issue, nil), do: true

  defp team_matches?(issue, team) do
    issue
    |> candidate_values([:team], [:id, :key, :name])
    |> Enum.member?(team)
  end

  defp project_matches?(_issue, []), do: true

  defp project_matches?(issue, projects) do
    issue
    |> candidate_values([:project], [:id, :key, :name])
    |> has_any?(projects)
  end

  defp labels_match?(_issue, []), do: true

  defp labels_match?(issue, labels) do
    issue_labels =
      issue
      |> value_at(:labels)
      |> normalize_string_list(:label)
      |> MapSet.new()

    Enum.all?(labels, &MapSet.member?(issue_labels, &1))
  end

  defp assignee_matches?(_issue, nil), do: true

  defp assignee_matches?(issue, assignee) do
    [
      candidate_values(issue, [:assignee], [:id, :name, :display_name, :displayName, :email]),
      candidate_values(issue, [], [:assignee_id, :assignee_name, :assignee_email])
    ]
    |> Enum.concat()
    |> Enum.member?(assignee)
  end

  defp has_any?(left, right), do: Enum.any?(left, &(&1 in right))

  defp candidate_values(source, nested_path, keys) do
    nested = value_at_path(source, nested_path)

    cond do
      is_binary(nested) ->
        [normalize_string(nested)]

      is_map(nested) ->
        keys
        |> Enum.map(&value_at(nested, &1))
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)

      true ->
        []
    end
  end

  defp value_at_path(source, []), do: source

  defp value_at_path(source, path) do
    Enum.reduce_while(path, source, fn key, acc ->
      case value_at(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp repo_value(repo, key), do: value_at(repo, key)

  defp value_at(nil, _key), do: nil

  defp value_at(source, key) when is_map(source) do
    Map.get(source, key) || Map.get(source, Atom.to_string(key))
  end

  defp value_at(_source, _key), do: nil

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(value), do: value |> to_string() |> normalize_string()

  defp normalize_string_list(nil, _kind), do: []

  defp normalize_string_list(values, kind) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> normalize_list_values(kind)
  end

  defp normalize_string_list(value, kind), do: normalize_string_list([value], kind)

  defp normalize_list_values(values, :label) do
    values
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_list_values(values, _kind) do
    values
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp present_string?(value) when is_binary(value), do: value != ""
  defp present_string?(_value), do: false
end
