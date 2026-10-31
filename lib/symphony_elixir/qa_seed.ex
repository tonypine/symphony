defmodule SymphonyElixir.QaSeed do
  @moduledoc """
  Loads a QA seed into a Symphony that runs over the memory tracker, so the Director under QA has
  real state behind its buttons (`scripts/qa-server-start.sh`, TP-1311).

  A seed is a directory (`priv/qa_seed/symphony/` is Symphony's own): `issues.json`, the tracker's
  issues (`issues.memory.issues_file` reads a copy of it), and `seed.json`, what Symphony itself
  holds about them. `load/2` writes `seed.json` through the same calls Symphony's own moves use:

  - `repository`: the configured repository key the seed's tickets belong to;
  - each tracker issue's state becomes its record's phase (`SymphonyElixir.TicketSignals.record_phase/3`),
    and the issue is observed into its record as the poll observes it
    (`SymphonyElixir.TicketObservation.observe/3`), so the Inbox, read from the records, names it;
  - `pauses.symphony` and `pauses.repository`: the Director's Symphony-wide pause and the
    repository's pause, with their reasons (`SymphonyElixir.Pauses.set/3`);
  - `holds`: a ticket on a Blocked hold for access (`reason`, `clearing_condition`), which only a
    person's Unblock lifts (`SymphonyElixir.Hold.set/5`), with the environment reason its pause
    waits on, as self-heal's access hold sets it (`SymphonyElixir.SelfHeal.environment_reason/1`);
  - `questions`: a decision request on a ticket, which opens its Question and sets its Needs Decision
    hold (`SymphonyElixir.DecisionRequest.ask/4`, in its words: `title`, `question`, `why`,
    `if_unanswered`, `recommendation_reason`, `options`);
  - `runs`: finished runs (`issue`, `status`, `minutes_ago`, `runtime_seconds`, `total_tokens`), each
    with its transcript, a JSONL file of agent events (`transcript`, relative to the seed);
  - `pull_requests`: a ticket's open PR (`number`) and what the PR watcher read of its checks (`ci`:
    `green`, `red` with its `failing_check`, or `pending`).

  It runs as a child of the application between the run store and the orchestrator, when the
  service was started with `--qa-seed <dir>`, so the orchestrator starts with the seeded runs and
  pauses. A seed that does not load stops the start with the reason: a QA server without its seed
  would answer its health check with nothing to drive.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{DecisionRequest, Hold, Pauses, RunStore, SelfHeal, TicketObservation}
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.{TicketPullRequest, TicketSignals, Tracker}

  @director %{kind: :person, name: "Director"}
  @ci %{"green" => :green, "red" => :red, "pending" => :pending}
  @phases %{"In Progress" => :in_progress, "Code Review" => :code_review, "QA" => :qa, "Rework" => :rework, "CI Fix" => :ci_fix, "Merging" => :merging}
  @request_keys ~w(title question why if_unanswered recommendation_reason options)
  @option_keys ~w(label effect recommended tradeoffs unlocks)
  @tradeoff_keys ~w(kind text)

  @doc "The seed directory the service was started with (`--qa-seed`), or nil."
  @spec configured_dir() :: Path.t() | nil
  def configured_dir, do: Application.get_env(:symphony_elixir, :qa_seed_dir)

  @doc "Starts nothing: loads the seed in `opts[:dir]` and returns `:ignore`, or stops the start."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    case load(Keyword.fetch!(opts, :dir), opts) do
      :ok -> :ignore
      {:error, reason} -> {:stop, {:qa_seed_failed, reason}}
    end
  end

  @doc """
  Loads the seed in `dir`. `opts[:now]` is the time the seed's ages count back from (default now);
  `opts[:tracker]` the tracker its issues are read from (default `SymphonyElixir.Tracker`).
  """
  @spec load(Path.t(), keyword()) :: :ok | {:error, term()}
  def load(dir, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    tracker = Keyword.get(opts, :tracker, Tracker)

    with {:ok, seed} <- read_json(Path.join(dir, "seed.json")),
         {:ok, issues} <- read_json(Path.join(dir, "issues.json")),
         {:ok, repo_key} <- repository(seed),
         :ok <- each(issues, &phase(repo_key, &1)),
         :ok <- pauses(repo_key, Map.get(seed, "pauses", %{})),
         :ok <- each(issues, &observe(repo_key, tracker, now, &1)),
         :ok <- each(Map.get(seed, "holds", []), &hold(repo_key, tracker, &1)),
         :ok <- each(Map.get(seed, "questions", []), &question(repo_key, tracker, &1)),
         :ok <- each(Map.get(seed, "runs", []), &run(dir, repo_key, tracker, now, &1)),
         :ok <- each(Map.get(seed, "pull_requests", []), &pull_request(repo_key, tracker, now, &1)) do
      Logger.info("QA seed loaded dir=#{dir} repo_key=#{repo_key} issues=#{length(issues)}")
    else
      {:error, reason} = error ->
        Logger.error("QA seed failed dir=#{dir} reason=#{inspect(reason)}")
        error
    end
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp repository(%{"repository" => repo_key}) when is_binary(repo_key), do: {:ok, repo_key}
  defp repository(_seed), do: {:error, :no_repository}

  defp each(entries, fun) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case fun.(entry) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp phase(repo_key, %{"id" => id, "state" => state}), do: TicketSignals.record_phase(repo_key, id, state)
  # A project or a team of the tracker's file, not an issue.
  defp phase(_repo_key, _entry), do: :ok

  defp observe(repo_key, tracker, now, %{"identifier" => identifier, "state" => _state}) do
    with {:ok, issue} <- issue(tracker, identifier) do
      case TicketObservation.observe(repo_key, issue, now: now) do
        {:ok, _outcome} -> :ok
        {:error, reason} -> {:error, {{:observe, identifier}, reason}}
      end
    end
  end

  defp observe(_repo_key, _tracker, _now, _entry), do: :ok

  defp pauses(repo_key, pauses) do
    with :ok <- pause(:symphony, Pauses.dispatch_reason(Map.get(pauses, "symphony")), Map.has_key?(pauses, "symphony")) do
      pause({:repository, repo_key}, Pauses.repository_reason(Map.get(pauses, "repository")), Map.has_key?(pauses, "repository"))
    end
  end

  defp pause(_subject, _reason, false), do: :ok

  defp pause(subject, reason, true) do
    case Pauses.set(subject, reason, set_by: @director) do
      {:ok, _pause} -> :ok
      {:error, reason} -> {:error, {:pause, subject, reason}}
    end
  end

  defp hold(repo_key, tracker, %{"issue" => identifier} = entry) do
    with {:ok, issue} <- issue(tracker, identifier) do
      attrs = %{reason: entry["reason"], clearing_condition: entry["clearing_condition"], waits_on: %{type: "access", keys: []}}
      reason = Map.put(SelfHeal.environment_reason("access"), :text, entry["reason"])

      # The pause is the one writer's already: nothing for the backfill from the holds to convert.
      with :ok <- Hold.set(repo_key, issue.id, :blocked, attrs),
           {:ok, _pause} <- Pauses.set({:ticket, repo_key, issue.id}, reason),
           :ok <- RunStore.update_ticket_state(repo_key, issue.id, %{pause_backfilled_at: DateTime.utc_now()}) do
        :ok
      else
        {:error, reason} -> {:error, {{:hold, identifier}, reason}}
      end
    end
  end

  defp question(repo_key, tracker, %{"issue" => identifier} = entry) do
    with {:ok, issue} <- issue(tracker, identifier),
         request = request(entry),
         result when result == :ok or elem(result, 0) == :ok <- DecisionRequest.ask(Map.put(issue, :repo_key, repo_key), request, repo_key: repo_key) do
      :ok
    else
      {:error, reason} -> {:error, {:question, identifier, reason}}
    end
  end

  defp request(entry) do
    request = atomize(entry, @request_keys)
    options = Enum.map(Map.get(request, :options, []), &option/1)
    Map.put(request, :options, options)
  end

  defp option(option) do
    option = atomize(option, @option_keys)
    Map.put(option, :tradeoffs, Enum.map(Map.get(option, :tradeoffs, []), &atomize(&1, @tradeoff_keys)))
  end

  defp atomize(map, keys), do: for({key, value} <- map, key in keys, into: %{}, do: {String.to_existing_atom(key), value})

  defp run(dir, repo_key, tracker, now, %{"issue" => identifier} = entry) do
    with {:ok, issue} <- issue(tracker, identifier) do
      ended_at = DateTime.add(now, -Map.get(entry, "minutes_ago", 0) * 60, :second)
      runtime = Map.get(entry, "runtime_seconds", 0)
      total = Map.get(entry, "total_tokens", 0)

      record = %{
        run_id: "qa-seed-#{identifier}",
        repo_key: repo_key,
        issue_id: issue.id,
        issue_identifier: identifier,
        title: issue.title,
        state: issue.state,
        status: Map.get(entry, "status", "success"),
        attempt: 1,
        started_at: DateTime.add(ended_at, -runtime, :second),
        ended_at: ended_at,
        error: Map.get(entry, "error"),
        session_id: "qa-seed-session-#{identifier}",
        transcript_path: entry |> Map.get("transcript") |> transcript_path(dir),
        turn_count: Map.get(entry, "turn_count", 1),
        tokens: tokens(total),
        transcript_buffer: [],
        transcript_buffer_size: 0,
        runtime_seconds: runtime,
        last_event_at: ended_at,
        pull_request_url: entry |> Map.get("pull_request") |> pr_url(),
        updated_at: ended_at
      }

      tagged(RunStore.put_run(record), {:run, identifier})
    end
  end

  # A seed names a run's total; nine tenths of it is input, most of that cached.
  defp tokens(total) do
    %{
      input_tokens: div(total * 9, 10),
      uncached_input_tokens: div(total, 10),
      cached_input_tokens: div(total * 8, 10),
      output_tokens: div(total, 10),
      total_tokens: total
    }
  end

  defp transcript_path(nil, _dir), do: nil
  defp transcript_path(file, dir), do: Path.expand(file, dir)

  defp pull_request(repo_key, tracker, now, %{"issue" => identifier, "number" => number} = entry) do
    with {:ok, ci} <- ci(identifier, Map.get(entry, "ci", "pending")),
         {:ok, issue} <- issue(tracker, identifier),
         url = pr_url(number),
         :ok <- tagged(TicketPullRequest.put(repo_key, issue.id, %{pr_url: url, branch: "qa-seed/#{identifier}", source: "created"}), {:pull_request, identifier}) do
      facts = %Facts{phase: Map.get(@phases, issue.state, :in_progress), pr_number: number, ci: ci, failing_check: Map.get(entry, "failing_check")}
      watch = %{facts: facts, pr_url: url, head_sha: head_sha(identifier), source: :poll, read_at: now, read_ci: ci}
      tagged(RunStore.put_ticket_pr_watch(repo_key, issue.id, identifier, watch), {:pr_watch, identifier})
    end
  end

  defp ci(identifier, value) do
    case Map.fetch(@ci, value) do
      {:ok, ci} -> {:ok, ci}
      :error -> {:error, {{:pull_request, identifier}, {:unknown_ci, value}}}
    end
  end

  # The seed's PRs live in no repository: nothing Symphony runs on GitHub reaches them.
  defp pr_url(nil), do: nil
  defp pr_url(number), do: "https://github.com/symphony-qa/seed/pull/#{number}"

  defp head_sha(identifier), do: :sha |> :crypto.hash(identifier) |> Base.encode16(case: :lower)

  defp issue(tracker, identifier) do
    case tracker.fetch_issue_by_identifier(identifier) do
      {:ok, issue} -> {:ok, issue}
      {:error, reason} -> {:error, {:issue, identifier, reason}}
    end
  end

  defp tagged(:ok, _what), do: :ok
  defp tagged({:error, reason}, what), do: {:error, {what, reason}}
end
