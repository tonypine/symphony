defmodule SymphonyElixir.PrWatch.Health do
  @moduledoc """
  How well GitHub's webhook deliveries reach one repository's PR and CI watcher
  (`SymphonyElixir.PrWatch.Repo`): when the last one arrived, how many came, the signature
  failures of the last 24 hours, and the changes a read found that no delivery reported.

  Deliveries count as healthy (D12) once one arrived after the last change they missed: the
  watcher then ticks every `github.webhooks.fallback_poll_interval_ms` (the safety net, D6).
  Otherwise, as with webhooks off, it ticks every `pull_requests.poll_interval_ms`. A repository
  that heard nothing for `github.webhooks.silence_alert_minutes` is `silent`: a warning for the
  app, not a change of pace, since a quiet repository sends nothing either.

  The record is kept in the run store per repository (`RunStore.put_github_updates/2`), so a
  restart keeps it. Everything here but `load/2` and `save/3` is pure.
  """

  alias SymphonyElixir.Config.Schema.GitHub.Webhooks

  @signature_window_s 24 * 60 * 60
  @settled_ci [:red, :green, :none]

  @type t :: %{
          github_url: String.t() | nil,
          last_delivery_at: DateTime.t() | nil,
          deliveries: non_neg_integer(),
          signature_failures: [DateTime.t()],
          missed: non_neg_integer(),
          missed_at: DateTime.t() | nil,
          last_missed: %{pr_url: String.t() | nil, change: atom()} | nil,
          results_via_webhook: non_neg_integer(),
          results_via_poll: non_neg_integer()
        }

  @doc "A repository nothing was delivered to yet."
  @spec new() :: t()
  def new do
    %{
      github_url: nil,
      last_delivery_at: nil,
      deliveries: 0,
      signature_failures: [],
      missed: 0,
      missed_at: nil,
      last_missed: nil,
      results_via_webhook: 0,
      results_via_poll: 0
    }
  end

  @doc "The record `repo_key` kept in `store`, or a new one when there is none or it can't be read."
  @spec load(module(), String.t()) :: t()
  def load(store, repo_key) do
    case store.get_github_updates({:health, repo_key}) do
      %{} = health -> Map.merge(new(), Map.take(health, Map.keys(new())))
      _none -> new()
    end
  end

  @doc "Keeps `health` for `repo_key` in `store`."
  @spec save(module(), String.t(), t()) :: :ok | {:error, term()}
  def save(store, repo_key, health), do: store.put_github_updates({:health, repo_key}, health)

  @doc "A verified delivery about the repository reached the watcher at `now`."
  @spec delivered(t(), DateTime.t()) :: t()
  def delivered(health, now), do: %{health | last_delivery_at: now, deliveries: health.deliveries + 1}

  @doc "A delivery naming the repository failed its signature check at `now`."
  @spec rejected(t(), DateTime.t()) :: t()
  def rejected(health, now), do: %{health | signature_failures: [now | recent(health.signature_failures, now)]}

  @doc "A read at `now` found a change (`:head`, `:pr` or `:ci`) of `pr_url` that no delivery reported."
  @spec missed(t(), String.t() | nil, atom(), DateTime.t()) :: t()
  def missed(health, pr_url, change, now) do
    %{health | missed: health.missed + 1, missed_at: now, last_missed: %{pr_url: pr_url, change: change}}
  end

  @doc "A read brought a CI result (a head that went red or green), through a delivery or the timed poll."
  @spec result(t(), :webhook | :poll) :: t()
  def result(health, :webhook), do: %{health | results_via_webhook: health.results_via_webhook + 1}
  def result(health, :poll), do: %{health | results_via_poll: health.results_via_poll + 1}

  @doc "Remembers the repository's GitHub URL (`https://github.com/owner/name`), to know its deliveries."
  @spec learn_url(t(), String.t() | nil) :: t()
  def learn_url(health, url) when is_binary(url), do: %{health | github_url: url}
  def learn_url(health, _url), do: health

  @doc "Whether deliveries reach the repository: on, one arrived, and none missed since (D12)."
  @spec healthy?(t(), Webhooks.t()) :: boolean()
  def healthy?(%{last_delivery_at: %DateTime{} = last} = health, %Webhooks{enabled: true}) do
    is_nil(health.missed_at) or DateTime.after?(last, health.missed_at)
  end

  def healthy?(_health, _webhooks), do: false

  @doc "Whether the repository heard nothing for `github.webhooks.silence_alert_minutes`, with webhooks on."
  @spec silent?(t(), Webhooks.t(), DateTime.t()) :: boolean()
  def silent?(_health, %Webhooks{enabled: false}, _now), do: false
  def silent?(%{last_delivery_at: nil}, _webhooks, _now), do: true

  def silent?(%{last_delivery_at: last}, %Webhooks{silence_alert_minutes: minutes}, now) do
    DateTime.diff(now, last, :second) >= minutes * 60
  end

  @doc "How long the watcher waits between ticks: the safety net while healthy, else `poll_interval_ms`."
  @spec interval_ms(t(), Webhooks.t(), pos_integer()) :: pos_integer()
  def interval_ms(health, webhooks, poll_interval_ms) do
    if healthy?(health, webhooks), do: webhooks.fallback_poll_interval_ms, else: poll_interval_ms
  end

  @doc "The signature failures of the 24 hours before `now`."
  @spec signature_failures(t(), DateTime.t()) :: non_neg_integer()
  def signature_failures(health, now), do: health |> Map.fetch!(:signature_failures) |> recent(now) |> length()

  @doc """
  The change between the watcher's record of a PR (`previous`) and the one a read just made
  (`current`) that no delivery reported: `:head` (it moved), `:pr` (it closed, merged or reopened)
  or `:ci` (its head went red or green), or nil. A delivery that named the PR since the earlier
  read reported whatever changed. Mergeability is left out: GitHub computes it after the fact,
  with no delivery of its own.
  """
  @spec unreported_change(map() | nil, map()) :: :head | :pr | :ci | nil
  def unreported_change(%{read_at: %DateTime{} = read_at, github: :ok} = previous, %{github: :ok} = current) do
    if reported_since?(previous, read_at), do: nil, else: change(previous, current)
  end

  def unreported_change(_previous, _current), do: nil

  defp reported_since?(%{delivered_at: %DateTime{} = delivered_at}, read_at), do: not DateTime.before?(delivered_at, read_at)
  defp reported_since?(_previous, _read_at), do: false

  defp change(previous, current) do
    pr = [previous.facts.pr, current.facts.pr]

    cond do
      is_binary(previous.head_sha) and is_binary(current.head_sha) and previous.head_sha != current.head_sha -> :head
      previous.facts.pr != current.facts.pr and Enum.any?(pr, &(&1 in [:closed, :merged])) -> :pr
      new_result?(previous.facts.ci, current.facts.ci) -> :ci
      true -> nil
    end
  end

  @doc "Whether a head's CI went from `before` to a result (red or green) in `read_ci`."
  @spec new_result?(atom() | nil, atom()) :: boolean()
  def new_result?(before, read_ci), do: settled(read_ci) != nil and settled(read_ci) != settled(before)

  defp settled(:none), do: :green
  defp settled(ci) when ci in @settled_ci, do: ci
  defp settled(_ci), do: nil

  @doc "The health as the state API and the dashboard show it."
  @spec status(t(), Webhooks.t(), DateTime.t()) :: map()
  def status(health, webhooks, now) do
    %{
      healthy: healthy?(health, webhooks),
      silent: silent?(health, webhooks, now),
      last_delivery_at: health.last_delivery_at,
      deliveries: health.deliveries,
      signature_failures_24h: signature_failures(health, now),
      missed: health.missed,
      missed_at: health.missed_at,
      last_missed: health.last_missed,
      results_via_webhook: health.results_via_webhook,
      results_via_poll: health.results_via_poll
    }
  end

  defp recent(times, now), do: Enum.filter(times, &(DateTime.diff(now, &1, :second) < @signature_window_s))
end
