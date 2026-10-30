defmodule SymphonyElixir.PrWatch.Ingest do
  @moduledoc """
  Feeds GitHub's webhook deliveries (`SymphonyElixir.GitHub.Webhook.parse/3`) to the PR and CI
  watcher: each running `SymphonyElixir.PrWatch.Repo` takes the ones about its repository.

  A delivery becomes a fact patch on the records it names (`patch/2`), marked `source: :webhook`,
  and the watcher reads those PRs 3 seconds later, once the burst of deliveries a CI run sends has
  settled (the confirm read). A PR that closed by merging (`merged?/1`) is read at once, so R2
  closes its ticket out as soon as Symphony learns of the merge. Only that read decides and acts, as the timed poll does, so a
  delivery changes how soon the watcher acts, never what it does. A patch never says a head is
  green: one passing check doesn't make the head green, only a full read of its rollup does.

  | Delivery | Records it names | Patch |
  | --- | --- | --- |
  | `check_suite`, `check_run`, `workflow_run` completed | the PR it lists, or its head | a failure on the record's head: `ci: :red`; else none |
  | `pull_request` `synchronize` | the PR | the new head, `ci: :pending`, `mergeable: :unknown` |
  | `pull_request` `reopened` | the PR | `pr: :open`, its head |
  | `pull_request` `closed` | the PR | `pr: :merged` or `pr: :closed`; a merge also moves its base, as a push |
  | `push` to a branch | every open PR on that base | `mergeable: :unknown`, each read 1 second apart; a read that finds it behind updates it (upkeep U1) |
  | `release` `published` | none | the app repository's newest release (`SymphonyElixir.PrWatch.Release`) |
  | `workflow_run` completed on a commit a held ticket waits on | none | its release build is checked at once (`SymphonyElixir.ReleaseBuild.delivered/2`) |
  | `ping` | none | none: every watched PR is read now, catching up on what the relay missed |

  Each delivery also counts for its repository's health (`SymphonyElixir.PrWatch.Health`), and a
  delivery whose signature failed counts as a signature failure.
  """

  alias SymphonyElixir.GitHub.Webhook
  alias SymphonyElixir.PrWatch.{Health, Release, Repo}
  alias SymphonyElixir.ReleaseBuild

  @registry SymphonyElixir.Repo.Registry
  @failure_conclusions ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]

  @doc """
  Hands a verified delivery, and the repository URL its payload names, to every running watcher.
  `:unavailable` when no watcher runs, except for a release, which is recorded either way.
  `opts`: `:watchers` (the servers, else every registered watcher) and those of
  `SymphonyElixir.PrWatch.Release.record_published/2`.
  """
  @spec deliver(Webhook.delivery(), String.t() | nil, keyword()) :: :ok | :unavailable
  def deliver(delivery, repo_url, opts \\ []) do
    released? = match?({:release, _release}, delivery)
    if released?, do: Release.record_published(elem(delivery, 1), opts)
    release_build(delivery, opts)

    case watchers(opts) do
      [] -> if released?, do: :ok, else: :unavailable
      watchers -> Enum.each(watchers, &Repo.ingest(&1, delivery, repo_url))
    end
  end

  # A finished workflow run on a commit a held ticket waits on checks that commit's release build at
  # once (`SymphonyElixir.ReleaseBuild`), whether or not a watcher runs.
  defp release_build({:ci, %{event: "workflow_run", head_sha: sha}}, opts) when is_binary(sha), do: ReleaseBuild.delivered(sha, opts)
  defp release_build(_delivery, _opts), do: :ignored

  @doc "Counts a delivery that failed its signature check against the repository its payload names."
  @spec reject(atom(), String.t() | nil, keyword()) :: :ok | :unavailable
  def reject(reason, repo_url, opts \\ []) do
    case watchers(opts) do
      [] -> :unavailable
      watchers -> Enum.each(watchers, &Repo.reject(&1, reason, repo_url))
    end
  end

  defp watchers(opts) do
    case Keyword.fetch(opts, :watchers) do
      {:ok, watchers} -> Enum.filter(watchers, &GenServer.whereis/1)
      :error -> registered()
    end
  end

  defp registered do
    if Process.whereis(@registry), do: Registry.select(@registry, [{{{:pr_watch, :_}, :"$1", :_}, [], [:"$1"]}]), else: []
  end

  @doc """
  Whether a delivery names the watcher's record of a PR: its URL, or for a check its head, or for a
  push the base it is on (any base while the record hasn't read it).
  """
  @spec names?(Webhook.delivery(), map()) :: boolean()
  def names?({:ci, event}, watch) do
    Enum.any?(event.pr_urls, &same_url?(&1, watch.pr_url)) or
      (event.event != "pull_request" and is_binary(event.head_sha) and event.head_sha == watch.head_sha)
  end

  def names?({:push, %{repo_url: repo_url, ref: ref}}, watch) do
    within?(watch.pr_url, repo_url) and Map.get(watch, :base_ref) in [nil, ref] and watch.facts.pr in [:open, :draft]
  end

  def names?(_delivery, _watch), do: false

  @doc """
  The record a delivery that names it leaves, per the table in the moduledoc, or the record as it
  was when the delivery carries no fact of its own.
  """
  @spec patch(Webhook.delivery(), map()) :: map()
  def patch({:ci, %{event: "pull_request", action: "synchronize", head_sha: head}}, watch) when is_binary(head) and head != watch.head_sha do
    %{watch | head_sha: head, facts: %{watch.facts | ci: :pending, mergeable: :unknown}}
  end

  def patch({:ci, %{event: "pull_request", action: "reopened", head_sha: head}}, watch) do
    %{watch | head_sha: head || watch.head_sha, facts: %{watch.facts | pr: :open}}
  end

  def patch({:ci, %{event: "pull_request", action: "closed", merged: merged}}, watch) do
    %{watch | facts: %{watch.facts | pr: if(merged, do: :merged, else: :closed)}}
  end

  def patch({:ci, %{action: "completed", head_sha: head, conclusion: conclusion}}, %{head_sha: head} = watch) when is_binary(head) do
    if failure?(conclusion), do: %{watch | facts: %{watch.facts | ci: :red}}, else: watch
  end

  def patch({:push, _push}, watch), do: %{watch | facts: %{watch.facts | mergeable: :unknown}}

  def patch(_delivery, watch), do: watch

  defp failure?(conclusion) when is_binary(conclusion), do: String.upcase(conclusion) in @failure_conclusions
  defp failure?(_conclusion), do: false

  @doc "Whether a delivery says a PR closed by merging, which the watcher reads at once."
  @spec merged?(Webhook.delivery()) :: boolean()
  def merged?({:ci, %{event: "pull_request", action: "closed", merged: true}}), do: true
  def merged?(_delivery), do: false

  @doc """
  The push a delivery stands for, when it moved a base branch: a push, or a PR that closed by
  merging (its base), so a hook that leaves `push` out still re-checks the PRs behind it.
  """
  @spec base_moved(Webhook.delivery(), String.t() | nil) :: Webhook.push() | nil
  def base_moved({:push, push}, _repo_url), do: push

  def base_moved({:ci, %{merged: true, base_ref: base, pr_urls: [pr_url | _rest]}}, repo_url) when is_binary(base) do
    %{repo_url: repo_url || repository_of(pr_url), ref: base, head_sha: nil}
  end

  def base_moved(_delivery, _repo_url), do: nil

  @doc "The repository URL (`https://github.com/owner/name`) of a PR URL, or nil."
  @spec repository_of(String.t() | nil) :: String.t() | nil
  def repository_of(pr_url) when is_binary(pr_url) do
    case Regex.run(~r{\A(https?://[^/]+/[^/]+/[^/]+)/pull/\d+}, String.trim(pr_url)) do
      [_url, repo_url] -> repo_url
      nil -> nil
    end
  end

  def repository_of(_pr_url), do: nil

  @doc "Whether `url` is `repo_url` or a page of it."
  @spec within?(String.t() | nil, String.t() | nil) :: boolean()
  def within?(url, repo_url) when is_binary(url) and is_binary(repo_url) do
    url = normalize_url(url)
    repo_url = normalize_url(repo_url)
    url == repo_url or String.starts_with?(url, repo_url <> "/")
  end

  def within?(_url, _repo_url), do: false

  defp same_url?(left, right) when is_binary(left) and is_binary(right), do: normalize_url(left) == normalize_url(right)
  defp same_url?(_left, _right), do: false

  defp normalize_url(url), do: url |> String.trim() |> String.trim_trailing("/") |> String.downcase()

  @doc """
  GitHub's updates as the dashboard shows them, summed over the watched repositories: whether
  webhooks are on and through which relay, the last delivery, how many came and failed their
  signature (24 hours), and how many CI results came through deliveries and how many by polling;
  with each repository's health (`SymphonyElixir.PrWatch.Health.status/3`) and the app
  repository's newest release. `opts`: `:repo_keys`, `:settings`, `:run_store`, `:now`.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    webhooks = Keyword.get_lazy(opts, :settings, &Webhook.settings/0)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()
    store = Keyword.get(opts, :run_store, SymphonyElixir.RunStore)
    repos = for repo_key <- Keyword.get_lazy(opts, :repo_keys, &repo_keys/0), into: %{}, do: {repo_key, Health.status(Health.load(store, repo_key), webhooks, now)}
    statuses = Map.values(repos)

    %{
      enabled: webhooks.enabled,
      relay: webhooks.relay,
      last_event_at: statuses |> Enum.map(& &1.last_delivery_at) |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end),
      events_received: sum(statuses, :deliveries),
      rejected: sum(statuses, :signature_failures_24h),
      results_via_webhook: sum(statuses, :results_via_webhook),
      results_via_poll: sum(statuses, :results_via_poll),
      repos: repos,
      app_release: Release.latest(run_store: store)
    }
  end

  defp sum(statuses, key), do: statuses |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()

  # A configuration that can't be read has no repository to show.
  defp repo_keys, do: for({:ok, repos} <- [SymphonyElixir.Config.repos()], %{name: name} <- repos, is_binary(name) and name != "", do: name)
end
