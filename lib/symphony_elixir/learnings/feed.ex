defmodule SymphonyElixir.Learnings.Feed do
  @moduledoc """
  Every configured repo's learnings, for `GET /api/v1/learnings` and the Mac app's Learnings tab,
  read from `SymphonyElixir.Learnings.Store`.

  Records come newest first, each with its ticket and its PR. Links are built only from trusted
  coordinates: a PR link on a canonical GitHub host, a ticket link on `linear.app` over HTTPS.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Hosts
  alias SymphonyElixir.Learnings.Store

  @trusted_linear_host "linear.app"
  @repo_path_part_pattern ~r/^[A-Za-z0-9._-]+$/

  @doc """
  The records that match `params`' `repo` (a repo key), `tag` and `q` (text in the rule, the
  evidence, a tag or the ticket's identifier, any case), with every repo and tag the records have,
  for the filters. `opts`: `:repo_keys` (default: the configured repos) and `:list` (a repo key →
  records function, default `Store.list/1`). A repo whose records can't be read is left out.
  """
  @spec payload(map(), keyword()) :: map()
  def payload(params, opts \\ []) when is_map(params) do
    list = Keyword.get(opts, :list, &Store.list(repo_key: &1))
    filters = %{repo: filter(params, "repo"), tag: filter(params, "tag"), q: filter(params, "q")}

    records =
      opts
      |> Keyword.get_lazy(:repo_keys, &repo_keys/0)
      |> Enum.flat_map(&list_or_empty(list.(&1)))
      |> Enum.sort_by(&Map.get(&1, :created_at), {:desc, DateTime})

    %{
      filters: filters,
      repos: records |> Enum.map(& &1.repo_key) |> Enum.uniq() |> Enum.sort(),
      tags: records |> Enum.flat_map(&Map.get(&1, :tags, [])) |> Enum.uniq() |> Enum.sort(),
      records: records |> Enum.filter(&matches?(&1, filters)) |> Enum.map(&entry/1)
    }
  end

  @doc "The record's PR on GitHub, nil unless its coordinates are trusted."
  @spec pr_url(map()) :: String.t() | nil
  def pr_url(%{host: host, owner: owner, repo: repo, evidence_pr_number: number})
      when is_binary(host) and is_binary(owner) and is_binary(repo) and is_integer(number) do
    trusted_pr_url(host, owner, repo, number)
  end

  def pr_url(%{repo: repo, evidence_pr_number: number}) when is_binary(repo) and is_integer(number) do
    case String.split(repo, "/", trim: true) do
      [host, owner, repo] -> trusted_pr_url(host, owner, repo, number)
      _ -> nil
    end
  end

  def pr_url(_record), do: nil

  @doc "The record's ticket on Linear, nil unless it is an HTTPS link on `linear.app`."
  @spec issue_url(map()) :: String.t() | nil
  def issue_url(%{evidence_issue_url: url}) when is_binary(url) and url != "" do
    trimmed = String.trim(url)
    uri = URI.parse(trimmed)

    if uri.scheme == "https" and is_nil(uri.userinfo) and is_binary(uri.host) and String.downcase(uri.host) == @trusted_linear_host do
      trimmed
    end
  end

  def issue_url(_record), do: nil

  @doc "The record's source repository: `host/owner/repo`, or the legacy `repo` value."
  @spec repo_label(map()) :: String.t() | nil
  def repo_label(%{host: host, owner: owner, repo: repo}) when is_binary(host) and is_binary(owner) and is_binary(repo),
    do: "#{host}/#{owner}/#{repo}"

  def repo_label(%{repo: repo}) when is_binary(repo), do: repo
  def repo_label(_record), do: nil

  defp trusted_pr_url(host, owner, repo, number) when number > 0 do
    with {:ok, host} <- Hosts.canonical_github_host(host),
         true <- valid_repo_path_part?(owner),
         true <- valid_repo_path_part?(repo) do
      "https://#{host}/#{owner}/#{repo}/pull/#{number}"
    else
      _ -> nil
    end
  end

  defp trusted_pr_url(_host, _owner, _repo, _number), do: nil

  defp valid_repo_path_part?(value), do: Regex.match?(@repo_path_part_pattern, value)

  defp repo_keys, do: Config.system!().repos |> Enum.map(& &1.name) |> Enum.filter(&is_binary/1)

  defp list_or_empty(records) when is_list(records), do: records
  defp list_or_empty(_error), do: []

  defp filter(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: String.trim(value)
      _ -> nil
    end
  end

  defp matches?(record, filters) do
    (is_nil(filters.repo) or record.repo_key == filters.repo) and
      (is_nil(filters.tag) or filters.tag in Map.get(record, :tags, [])) and
      (is_nil(filters.q) or matches_text?(record, String.downcase(filters.q)))
  end

  defp matches_text?(record, q) do
    [record.rule, Map.get(record, :evidence_quote), Map.get(record, :evidence_issue_identifier) | Map.get(record, :tags, [])]
    |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), q)))
  end

  defp entry(record) do
    %{
      id: record.id,
      repo_key: record.repo_key,
      repo: repo_label(record),
      rule: record.rule,
      tags: Map.get(record, :tags, []),
      evidence_quote: Map.get(record, :evidence_quote),
      issue_identifier: Map.get(record, :evidence_issue_identifier),
      issue_url: issue_url(record),
      pr_number: Map.get(record, :evidence_pr_number),
      pr_url: pr_url(record),
      run_id: Map.get(record, :evidence_run_id),
      created_at: record.created_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end
end
