defmodule SymphonyElixir.TicketPullRequest do
  @moduledoc """
  Symphony's own record of each ticket's pull request, the source of a ticket's PR.

  The record lives in `SymphonyElixir.RunStore`, one per repo key and issue id, so it survives a
  restart. `SymphonyElixir.AgentTools.GitHub.create_pull_request/5` writes it `open` when the agent
  opens the PR, replacing whatever PR the ticket held before. The places that already see a PR
  close or merge (the GitHub `pull_request` webhook, the CI poller's and the PR review poller's PR
  reads) mark it `closed` or `merged`. A closed or merged PR is not the ticket's in-flight PR.
  `SymphonyElixir.TicketPullRequest.Backfill` seeds a record at startup for the tickets in flight
  from the PR URLs Symphony already stores, and `SymphonyElixir.TicketPullRequest.Lookup` finds a PR
  Symphony did not open on GitHub, by the ticket's branch, each poll.

  Consumers read the ticket's PR with `current_url/1` (or `current_urls/1`, or `recorded_urls/2` for
  a reader that asks what a finished ticket shipped). Until ticket reads stop
  carrying Linear attachments, a ticket with no record falls back to the attachment-derived
  `pull_request_url` / `pr_urls` of the issue.

  Writes are side effects next to an action already taken: a store failure is logged and swallowed,
  so it never fails the tool call or the poll that made it.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RunStore, URLUtils}

  @open "open"
  @finished_states ["closed", "merged"]
  @sources ["created", "backfill", "github_lookup"]

  @type state :: String.t()
  @type source :: String.t()
  @type t :: %{
          repo_key: String.t(),
          issue_id: String.t(),
          pr_url: String.t(),
          branch: String.t() | nil,
          state: state(),
          source: source(),
          recorded_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Writes the ticket's record for the PR at `pr_url` on `branch`, `open`, replacing the record the
  ticket held. `source` says how Symphony learned of it: `created` (it opened the PR), `backfill` or
  `github_lookup`.
  """
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(repo_key, issue_id, attrs) do
    with {:ok, record} <- open_record(repo_key, issue_id, attrs), do: RunStore.put_ticket_pull_request(record)
  end

  @doc """
  `put/3` only for a ticket that has no record yet: `{:ok, :exists}` leaves the record it holds,
  whatever its PR or state, as it is.
  """
  @spec put_new(String.t(), String.t(), map()) :: {:ok, :inserted | :exists} | {:error, term()}
  def put_new(repo_key, issue_id, attrs) do
    with {:ok, record} <- open_record(repo_key, issue_id, attrs), do: RunStore.insert_ticket_pull_request(record)
  end

  defp open_record(repo_key, issue_id, attrs) when is_binary(repo_key) and is_binary(issue_id) and is_map(attrs) do
    source = Map.get(attrs, :source, "created")

    with {:ok, pr_url} <- require_url(Map.get(attrs, :pr_url)),
         :ok <- require_source(source) do
      now = DateTime.utc_now()

      {:ok,
       %{
         repo_key: repo_key,
         issue_id: issue_id,
         pr_url: pr_url,
         branch: URLUtils.present_url(Map.get(attrs, :branch)),
         state: @open,
         source: source,
         recorded_at: now,
         updated_at: now
       }}
    end
  end

  defp open_record(_repo_key, _issue_id, _attrs), do: {:error, :invalid_ticket_pull_request_record}

  @doc """
  Records the PR Symphony just opened for the ticket (`source: created`). No-ops for a tool call
  made outside a configured repo; a store failure is logged and swallowed.
  """
  @spec record_created(String.t() | nil, String.t() | nil, String.t(), String.t() | nil) :: :ok
  def record_created(repo_key, issue_id, pr_url, branch) when is_binary(repo_key) and is_binary(issue_id) do
    repo_key
    |> put(issue_id, %{pr_url: pr_url, branch: branch, source: "created"})
    |> log_error("record the pull request #{inspect(pr_url)} of issue_id=#{issue_id}")
  end

  def record_created(_repo_key, _issue_id, _pr_url, _branch), do: :ok

  @spec get(String.t(), String.t()) :: t() | nil | {:error, term()}
  def get(repo_key, issue_id), do: RunStore.get_ticket_pull_request(repo_key, issue_id)

  @doc "Every ticket's PR record in `repo_key`, newest change first."
  @spec list(String.t()) :: [t()] | {:error, term()}
  def list(repo_key), do: RunStore.list_ticket_pull_requests(repo_key)

  @doc """
  Marks the records of `repo_key` holding the PR at `pr_url` `closed` or `merged`, once Symphony
  sees that PR finished. A ticket whose record holds another PR is left alone. Best effort: a store
  failure is logged and swallowed.
  """
  @spec mark_finished(String.t() | nil, String.t() | nil, state()) :: :ok
  def mark_finished(repo_key, pr_url, state) when is_binary(repo_key) and state in @finished_states do
    case URLUtils.present_url(pr_url) do
      nil ->
        :ok

      url ->
        repo_key
        |> RunStore.finish_ticket_pull_request(url, state, DateTime.utc_now())
        |> log_finished(url, state)
    end
  end

  def mark_finished(_repo_key, _pr_url, _state), do: :ok

  @doc """
  The URL of the ticket's in-flight PR: its `open` record's, and `nil` once that PR closed or
  merged. A PR run's issue (`run_kind: :pr`) answers its own PR. A ticket with no record (or a
  store that cannot be read) falls back to the issue's attachment-derived PR.
  """
  @spec current_url(Issue.t()) :: String.t() | nil
  def current_url(%Issue{} = issue) do
    case current(issue) do
      {:record, url} -> url
      :fallback -> URLUtils.pull_request_url(issue)
    end
  end

  @doc """
  `current_url/1` for a lane that serves `repo_key`: an issue read without its repo (a single-repo
  read, a ticket read by id) is looked up under the lane's repo.
  """
  @spec current_url(Issue.t(), String.t() | nil) :: String.t() | nil
  def current_url(%Issue{} = issue, repo_key), do: issue |> with_repo_key(repo_key) |> current_url()

  @doc "`current_url/1` as a list, for the readers that walk every PR of a ticket."
  @spec current_urls(Issue.t()) :: [String.t()]
  def current_urls(%Issue{} = issue) do
    case current(issue) do
      {:record, nil} -> []
      {:record, url} -> [url]
      :fallback -> attachment_urls(issue)
    end
  end

  @doc """
  The ticket's recorded PR whatever its state, as a list: for a reader that asks what a finished
  ticket shipped (the update hold looks for a blocker's merged PR), where `current_urls/1` answers
  none once the PR merged. Falls back to the attachments like `current_urls/1`, under the lane's
  `repo_key` when the issue was read without its repo.
  """
  @spec recorded_urls(Issue.t(), String.t() | nil) :: [String.t()]
  def recorded_urls(%Issue{} = issue, repo_key) do
    issue = with_repo_key(issue, repo_key)

    case record(issue) do
      %{pr_url: url} when is_binary(url) -> [url]
      _no_record -> current_urls(issue)
    end
  end

  defp current(%Issue{run_kind: run_kind, pull_request_url: url}) when run_kind in [:pr, "pr"],
    do: {:record, URLUtils.present_url(url)}

  defp current(%Issue{} = issue) do
    case record(issue) do
      %{state: @open, pr_url: url} -> {:record, url}
      %{state: state} when state in @finished_states -> {:record, nil}
      _no_record -> :fallback
    end
  end

  defp record(%Issue{run_kind: run_kind}) when run_kind in [:pr, "pr"], do: nil
  defp record(%Issue{repo_key: repo_key, id: issue_id}) when is_binary(repo_key) and is_binary(issue_id), do: get(repo_key, issue_id)
  defp record(_issue), do: nil

  defp with_repo_key(%Issue{repo_key: key} = issue, repo_key) when key in [nil, ""] and is_binary(repo_key),
    do: %{issue | repo_key: repo_key}

  defp with_repo_key(issue, _repo_key), do: issue

  defp attachment_urls(%Issue{pr_urls: [_ | _] = urls}), do: urls |> Enum.map(&URLUtils.present_url/1) |> Enum.reject(&is_nil/1)
  defp attachment_urls(%Issue{} = issue), do: issue |> URLUtils.pull_request_url() |> List.wrap()

  defp require_url(url) do
    case URLUtils.present_url(url) do
      nil -> {:error, :invalid_pr_url}
      url -> {:ok, url}
    end
  end

  defp require_source(source) when source in @sources, do: :ok
  defp require_source(_source), do: {:error, :invalid_source}

  defp log_finished({:ok, _changed}, _url, _state), do: :ok
  defp log_finished(error, url, state), do: log_error(error, "mark the pull request #{url} #{state}")

  defp log_error(:ok, _action), do: :ok

  defp log_error({:error, reason}, action) do
    Logger.warning("Failed to #{action}: #{inspect(reason)}")
    :ok
  end
end
