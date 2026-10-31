defmodule SymphonyElixir.PlanBrief do
  @moduledoc """
  A plan's brief on the ticket's record (`plan_brief`, `SymphonyElixir.TicketState`), read once when
  the plan enters `Plan Review` instead of on every read of the Inbox.

  `capture/2` reads the ticket once from Linear (its comments, sub-issues, labels and state moves,
  the fields the Inbox reads) and builds what the Inbox shows of a plan with the same code
  (`SymphonyElixir.Inbox.Item.plan_from_node/2`): the `## Review brief` comment parsed
  (`SymphonyElixir.Inbox.ReviewBrief`), the sub-tickets in landing order with their state, and the
  open choices the plan run asked, each with the id of its Question. It stores them with when they
  were read (`read_at`) and clears `plan_brief_error`; a capture that fails stores `plan_brief: nil`
  and the reason in `plan_brief_error`, which the reconciler reads to try again (`retry_failed/2`).

  The record is the truth of the ticket's phase: Symphony writes `Plan Review` on the record before
  Linear is asked, so the read may still show the state the plan left. The capture reads the ticket
  as the phase its record holds.

  Three things capture it, each in a task of its own bounded in time (`capture_async/2`): a move of
  Symphony's into `Plan Review` (`SymphonyElixir.TicketSignals.record_phase/3`), which a plan
  revision makes again; a Linear `Comment` delivery that creates or edits a review brief on a ticket
  whose record sits in `Plan Review` (`observe_delivery/2`), so an edit reaches the record without a
  poll; and the reconciler, for a capture that failed. The capture runs only where the application
  env's `:plan_brief_capture` is not false (tests turn it off) and over a Linear tracker. The
  application env's `:plan_brief_opts` gives every entry point its default options (a test's Linear
  client and settings); the options a caller passes win.
  """

  require Logger

  alias SymphonyElixir.{Config, PlanReview, RunStore}
  alias SymphonyElixir.HumanActions.Collector
  alias SymphonyElixir.Inbox.{Item, ReviewBrief}
  alias SymphonyElixir.Linear.{Client, Usage, Webhook}
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixirWeb.ObservabilityPubSub

  @timeout_ms 15_000
  @comment_last 30
  @history_first 50
  @children_first 50
  @attachments_first 10

  @query """
  query SymphonyPlanBrief($id: String!, $commentLast: Int!, $historyFirst: Int!, $childrenFirst: Int!, $attachmentsFirst: Int!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      url
      state { name }
      labels { nodes { name } }
      attachments(first: $attachmentsFirst) { nodes { url } }
      children(first: $childrenFirst) { nodes { identifier title url createdAt state { name } } }
      comments(last: $commentLast, orderBy: createdAt) {
        nodes { id body createdAt parent { id } }
        pageInfo { hasPreviousPage startCursor }
      }
      history(first: $historyFirst) {
        nodes { createdAt fromState { name } toState { name } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @typedoc "A sub-ticket of the plan as the read saw it."
  @type sub_ticket :: %{
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          state: String.t() | nil
        }

  @typedoc """
  The plan's brief: the review brief parsed (`ReviewBrief.parse/1`, nil when the plan has none), its
  sub-tickets in landing order, its open choices as the Inbox shows a request (each with its
  `question_id`) and when they were read.
  """
  @type t :: %{
          brief: ReviewBrief.parsed() | ReviewBrief.raw() | nil,
          sub_tickets: [sub_ticket()],
          choices: [map()],
          read_at: DateTime.t() | nil
        }

  @typedoc "The ticket a capture is for: its repo key and Linear issue id."
  @type ticket :: {String.t(), String.t()}

  @doc """
  Reads the plan of `ticket` from Linear and stores it on the record (see the moduledoc). Returns the
  brief stored, `:skipped` when the repo's tracker is neither Linear nor a memory tracker with an
  issues file, which is read in Linear's place (nothing is written), or the
  reason the capture failed, which the record keeps in `plan_brief_error`.

  `opts`: `:linear_client` (`(query, variables, opts) -> {:ok, body} | {:error, reason}`, default
  `SymphonyElixir.Linear.Client.graphql/3`), `:settings` (the repo's, default
  `Config.settings_for_repo/1`) and `:now`.
  """
  @spec capture(ticket(), keyword()) :: {:ok, t()} | :skipped | {:error, term()}
  def capture({repo_key, issue_id}, opts \\ []) when is_binary(repo_key) and is_binary(issue_id) do
    opts = defaults(opts)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case settings(repo_key, opts) do
      {:ok, %{tracker: %{kind: "linear"}} = settings} ->
        result =
          with {:ok, node} <- read(issue_id, opts),
               do: plan(node, settings, now)

        store(repo_key, issue_id, result)

      # A memory tracker's issues file is a fake Linear (a QA server's seed): its issue is read there.
      {:ok, %{tracker: %{kind: "memory", memory_issues_file: path}} = settings} when is_binary(path) ->
        result =
          with {:ok, node} <- memory_node(repo_key, issue_id),
               do: plan(node, settings, now)

        store(repo_key, issue_id, result)

      {:ok, _settings} ->
        :skipped

      {:error, reason} ->
        store(repo_key, issue_id, {:error, {:settings, reason}})
    end
  end

  @doc """
  Runs `capture/2` in a task under `:task_supervisor` (default `SymphonyElixir.TaskSupervisor`),
  bounded by `:timeout_ms` (default 15 seconds): a capture that takes longer, or crashes, is stored as
  failed for the reconciler to try again. Returns the task's pid, or `:off` when the application env
  turns the capture off; a task that can't start is logged and returns `:error`. `opts` are also
  those of `capture/2`.
  """
  @spec capture_async(ticket(), keyword()) :: {:ok, pid()} | :off | :error
  def capture_async({repo_key, issue_id} = ticket, opts \\ []) when is_binary(repo_key) and is_binary(issue_id) do
    if enabled?() do
      opts = defaults(opts)
      supervisor = Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)
      {:ok, _pid} = Task.Supervisor.start_child(supervisor, fn -> bounded(ticket, supervisor, opts) end)
    else
      :off
    end
  catch
    kind, reason ->
      Logger.warning("Plan brief: the capture did not start issue_id=#{issue_id}: #{inspect({kind, reason})}")
      :error
  end

  @doc """
  Starts a capture (`capture_async/2`) when `phase`, the phase a move of Symphony's just wrote on
  `repo_key`'s `issue_id`, is the repo's `Plan Review` state; anything else is `:ok` and nothing runs.
  """
  @spec entered(String.t(), String.t(), String.t() | nil, keyword()) :: :ok
  def entered(repo_key, issue_id, phase, opts \\ []) do
    opts = defaults(opts)

    if plan_review?(repo_key, phase, opts), do: capture_async({repo_key, issue_id}, opts)
    :ok
  end

  @doc """
  Starts a capture for a verified Linear delivery (`SymphonyElixir.Linear.Webhook.parse/1`) that
  created or edited a review brief comment (`ReviewBrief.brief?/1`) on a ticket whose record, in any
  configured repo, sits in that repo's `Plan Review`. Any other delivery starts nothing. Returns the
  repo keys a capture started for. `opts`: `:repos` (repo keys, default the configured repos), and
  those of `capture_async/2`.
  """
  @spec observe_delivery(Webhook.parsed() | term(), keyword()) :: [String.t()]
  def observe_delivery(parsed, opts \\ []), do: observe(parsed, defaults(opts))

  defp observe({:comment, action, issue_id, %{body: body}}, opts) when action in [:create, :update] do
    if ReviewBrief.brief?(body) do
      for repo_key <- repo_keys(opts), in_plan_review?(repo_key, issue_id, opts) do
        capture_async({repo_key, issue_id}, opts)
        repo_key
      end
    else
      []
    end
  end

  defp observe(_parsed, _opts), do: []

  @doc """
  Captures again, one after the other, each of `records` (the repo's normalized records) whose last
  capture failed (`plan_brief_error`) and which still sits in `repo_key`'s `Plan Review`. Returns how
  many it tried. `opts` are those of `capture/2`.
  """
  @spec retry_failed(String.t(), [map()], keyword()) :: non_neg_integer()
  def retry_failed(repo_key, records, opts) do
    opts = defaults(opts)

    if enabled?() do
      for %{plan_brief_error: error, issue_id: issue_id, phase: phase} <- records,
          is_binary(error),
          plan_review?(repo_key, phase, opts),
          reduce: 0 do
        tried ->
          capture({repo_key, issue_id}, opts)
          tried + 1
      end
    else
      0
    end
  end

  @doc "The plan's brief a record holds (`TicketState`'s `plan_brief`), nil when it holds none."
  @spec from_record(map() | nil) :: t() | nil
  def from_record(%{plan_brief: brief}), do: normalize(brief)
  def from_record(_record), do: nil

  @doc "A stored brief in the shape `t:t/0` gives, so a record read from the store reads the same; nil for anything else."
  @spec normalize(term()) :: t() | nil
  def normalize(%{} = brief) do
    %{
      brief: map_or_nil(Map.get(brief, :brief)),
      sub_tickets: brief |> Map.get(:sub_tickets) |> list_of_maps(),
      choices: brief |> Map.get(:choices) |> list_of_maps(),
      read_at: datetime(Map.get(brief, :read_at))
    }
  end

  def normalize(_brief), do: nil

  defp enabled?, do: Application.get_env(:symphony_elixir, :plan_brief_capture, true) != false

  defp defaults(opts), do: Keyword.merge(Application.get_env(:symphony_elixir, :plan_brief_opts, []), opts)

  defp bounded({repo_key, issue_id} = ticket, supervisor, opts) do
    Usage.put_caller(:plan_brief)
    task = Task.Supervisor.async_nolink(supervisor, fn -> capture(ticket, opts) end)

    case Task.yield(task, Keyword.get(opts, :timeout_ms, @timeout_ms)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> store(repo_key, issue_id, {:error, {:exit, reason}})
      nil -> store(repo_key, issue_id, {:error, :timeout})
    end
  end

  defp read(issue_id, opts) do
    client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    variables = %{
      id: issue_id,
      commentLast: @comment_last,
      historyFirst: @history_first,
      childrenFirst: @children_first,
      attachmentsFirst: @attachments_first
    }

    case client.(@query, variables, []) do
      {:ok, %{"data" => %{"issue" => %{} = node}}} -> read_more(node, client)
      {:ok, %{"data" => %{"issue" => nil}}} -> {:error, :issue_not_found}
      {:ok, body} -> {:error, {:unexpected_response, body}}
      {:error, _reason} = error -> error
    end
  end

  defp memory_node(repo_key, issue_id) do
    case Enum.find(Memory.issue_nodes(%{name: repo_key}), &(&1["id"] == issue_id)) do
      %{} = node -> {:ok, node}
      nil -> {:error, :issue_not_found}
    end
  end

  defp read_more(node, client) do
    with {:ok, [node]} <- Collector.read_more_pages([node], client), do: {:ok, node}
  end

  # The node is read as the phase the record holds: the move into `Plan Review` is written on the
  # record first, and Linear's may not have landed yet.
  defp plan(node, settings, now) do
    node = Map.put(node, "state", %{"name" => PlanReview.state(settings)})

    case Item.plan_from_node(node, settings) do
      %{} = plan -> {:ok, %{brief: plan.brief, sub_tickets: plan.sub_tickets, choices: plan.decisions, read_at: now}}
      nil -> {:error, :not_a_plan}
    end
  end

  defp store(repo_key, issue_id, {:ok, brief}) do
    case write(repo_key, issue_id, %{plan_brief: brief, plan_brief_error: nil}) do
      :ok -> {:ok, brief}
      error -> error
    end
  end

  defp store(repo_key, issue_id, {:error, reason} = error) do
    Logger.warning("Plan brief: the capture failed issue_id=#{issue_id}: #{inspect(reason)}")
    with :ok <- write(repo_key, issue_id, %{plan_brief: nil, plan_brief_error: inspect(reason)}), do: error
  end

  defp write(repo_key, issue_id, attrs) do
    case RunStore.update_ticket_state(repo_key, issue_id, attrs) do
      :ok ->
        ObservabilityPubSub.broadcast_ticket_record_changed(repo_key, issue_id, [:plan_brief])

      {:error, reason} ->
        Logger.warning("Plan brief: the record could not be written issue_id=#{issue_id}: #{inspect(reason)}")
        {:error, {:store, reason}}
    end
  end

  defp in_plan_review?(repo_key, issue_id, opts) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      %{phase: phase} -> plan_review?(repo_key, phase, opts)
      _none_or_error -> false
    end
  end

  defp plan_review?(repo_key, phase, opts) when is_binary(phase) do
    case settings(repo_key, opts) do
      {:ok, settings} -> PlanReview.in_state?(phase, settings)
      {:error, _reason} -> false
    end
  end

  defp plan_review?(_repo_key, _phase, _opts), do: false

  defp settings(repo_key, opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} -> {:ok, settings}
      :error -> Config.settings_for_repo(repo_key)
    end
  end

  # The configured repos' keys; none when the config can't be read.
  defp repo_keys(opts), do: Keyword.get_lazy(opts, :repos, fn -> for {:ok, repos} <- [Config.repos()], repo <- repos, do: repo.name end)

  defp map_or_nil(%{} = map), do: map
  defp map_or_nil(_value), do: nil

  defp list_of_maps(list) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp list_of_maps(_list), do: []

  defp datetime(%DateTime{} = at), do: at
  defp datetime(_at), do: nil
end
