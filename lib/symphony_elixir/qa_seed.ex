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
  - `holds`: a ticket paused for access (`reason`), which only a person's Unblock lifts: the
    environment reason its pause waits on, as self-heal sets it for a block only a person can clear
    (`SymphonyElixir.SelfHeal.environment_reason/1`);
  - `usage_limits`: a provider's usage-limit hold, as the orchestrator keeps it
    (`SymphonyElixir.RunStore.put_usage_limits/1`) and restores it at its start: its `provider`, the
    `window` it limits, `resets_in_minutes` from the seed's now, and the ticket whose run found it
    (`issue`). With a `reserve` (and the `utilization` seen) it is a hold at the reserve, as Anthropic's
    rate-limit events set it (`SymphonyElixir.UsageLimit.put_headroom/3`); without one, the limit the
    provider's own message reported (`SymphonyElixir.UsageLimit.put/3`). The QA server's runs are on
    another provider, so the holds start no wait of theirs;
  - `questions`: a decision request on a ticket, which opens its Question and sets its Needs Decision
    hold (`SymphonyElixir.DecisionRequest.ask/4`, in its words: `title`, `question`, `why`,
    `if_unanswered`, `recommendation_reason`, `options`). With `asked_by: "Conductor"` it is the
    Conductor's, asked by the run `qa-seed-conductor-<issue>` in the ticket's phase on its seeded
    PR's head: each option names its `action` (and a `rework` one its `finding`), and carries the
    move that action makes once picked, as the Conductor builds it
    (`SymphonyElixir.Conductor.actioned_options/5`), so Decide acts on it;
  - `runs`: finished runs (`issue`, `status`, `minutes_ago`, `runtime_seconds`, `total_tokens`), each
    with its transcript, a JSONL file of agent events (`transcript`, relative to the seed);
  - `merged_waits`: the tickets whose PR's merge put them in `Waiting on sub-tickets`
    (`SymphonyElixir.RunStore.put_merged_wait/1`, as `SymphonyElixir.SubIssueWait.wait_on_merge/3`
    records it), so Symphony closes each one once its last sub-ticket ends; a tracker issue's
    `"parentId"` makes it a sub-ticket;
  - `dependencies`: a ticket's stored dependency on another (`issue`, `on`, and `kind`, `done` by
    default or `released`), as a split or the Director stores it (`SymphonyElixir.RunStore.add_dependency/3`):
    the tracker's file holds no blocker link, since Symphony reads none;
  - `pull_requests`: a ticket's open PR (`number`) and what the PR watcher read of its checks (`ci`:
    `green`, `red` with its `failing_check`, or `pending`);
  - `events`: a ticket's ledger history (`SymphonyElixir.TicketEvents.record/5`), oldest first: each
    with its `issue`, `type`, `payload`, `minutes_ago`, the `run_id` it belongs to and, for an agent's
    event, `actor: "agent"` (of the run's `run_kind`, default implementation). An `output` names a
    file relative to the seed (`file`, with its `label`), kept as the event's `step_output` artifact
    (`SymphonyElixir.Artifacts.ingest/3`); `gone: true` removes its bytes from the store afterwards,
    so the Director reads it as unavailable. A `picture` names a PNG or JPEG the same way (`file`,
    `label`), kept as the event's `screenshot` artifact, as a picture a QA tool took is kept on its
    `evidence` (`SymphonyElixir.AgentTools.QaPictures`). A `transcript` names a step's lines the same
    way (`file`, `label`), one JSON object a line (`SymphonyElixir.PhaseSteps.Transcript`), kept as
    the `transcript` artifact a step's `step.completed` carries, so the Director unfolds the step
    into what the agent said and did. Its lines' times (`at`) move so the last one falls at the
    event's own time, and the facts the run recorded in the step fall among them. On a `run.ended`
    it names the run's whole session instead, a Claude session JSONL file, which the Director reads
    as lines (`GET /api/v1/artifacts/:id/lines`) for a run that walks no steps.

  It runs as a child of the application between the run store and the orchestrator, when the
  service was started with `--qa-seed <dir>`, so the orchestrator starts with the seeded runs and
  pauses. A seed that does not load stops the start with the reason: a QA server without its seed
  would answer its health check with nothing to drive.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{
    Artifacts,
    Conductor,
    Config,
    DecisionRequest,
    Pauses,
    RunStore,
    SelfHeal,
    TicketEvents,
    TicketObservation,
    UsageLimit
  }

  alias SymphonyElixir.Artifacts.Store
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.{TicketPullRequest, TicketSignals, Tracker}

  @director %{kind: :person, name: "Director"}
  @ci %{"green" => :green, "red" => :red, "pending" => :pending}
  @phases %{"In Progress" => :in_progress, "Code Review" => :code_review, "QA" => :qa, "Rework" => :rework, "CI Fix" => :ci_fix, "Merging" => :merging}
  @request_keys ~w(title question why if_unanswered recommendation_reason options)
  @option_keys ~w(label effect recommended tradeoffs unlocks action finding)
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
         :ok <- usage_limits(Map.get(seed, "usage_limits", []), now),
         :ok <- each(Map.get(seed, "questions", []), &question(repo_key, tracker, &1)),
         :ok <- each(Map.get(seed, "runs", []), &run(dir, repo_key, tracker, now, &1)),
         :ok <- each(Map.get(seed, "merged_waits", []), &merged_wait(tracker, &1)),
         :ok <- each(Map.get(seed, "dependencies", []), &dependency(tracker, &1)),
         :ok <- each(Map.get(seed, "pull_requests", []), &pull_request(repo_key, tracker, now, &1)),
         :ok <- each(Map.get(seed, "events", []), &event(dir, repo_key, tracker, now, &1)) do
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
      reason = Map.put(SelfHeal.environment_reason("access"), :text, entry["reason"])

      # The pause is the one writer's already: nothing for the backfill from the holds to convert.
      with {:ok, _pause} <- Pauses.set({:ticket, repo_key, issue.id}, reason),
           :ok <- RunStore.update_ticket_state(issue.id, %{pause_backfilled_at: DateTime.utc_now()}) do
        :ok
      else
        {:error, reason} -> {:error, {{:hold, identifier}, reason}}
      end
    end
  end

  # The holds go in as the orchestrator keeps them, so it restores them at its start.
  defp usage_limits([], _now), do: :ok

  defp usage_limits(entries, now) do
    config = Config.settings!().execution.usage_limit
    holds = Map.new(entries, &usage_limit(&1, now, config))

    holds |> RunStore.put_usage_limits() |> tagged(:usage_limits)
  end

  defp usage_limit(%{"provider" => provider, "resets_in_minutes" => minutes} = entry, now, config) do
    window = entry["window"]

    info = %{
      provider: provider,
      scope: UsageLimit.scope_for_window(window),
      window: window,
      resets_at: DateTime.add(now, minutes * 60),
      utilization: entry["utilization"]
    }

    opts = [now: now, config: config, issue_identifier: entry["issue"]]

    hold =
      case entry["reserve"] do
        nil -> UsageLimit.put(nil, Map.put(info, :source, :result_text), opts)
        reserve -> UsageLimit.put_headroom(nil, Map.merge(info, %{source: :rate_limit_event, reserve: reserve / 1}), opts)
      end

    {UsageLimit.key(info), hold}
  end

  defp question(repo_key, tracker, %{"issue" => identifier} = entry) do
    with {:ok, issue} <- issue(tracker, identifier),
         {:ok, request, opts} <- request(repo_key, issue, identifier, entry),
         result when result == :ok or elem(result, 0) == :ok <- DecisionRequest.ask(Map.put(issue, :repo_key, repo_key), request, [repo_key: repo_key] ++ opts) do
      :ok
    else
      {:error, reason} -> {:error, {:question, identifier, reason}}
    end
  end

  defp request(repo_key, issue, identifier, %{"asked_by" => "Conductor"} = entry) do
    run_id = "qa-seed-conductor-#{identifier}"
    request = plain_request(entry)

    case Conductor.actioned_options(request.options, Config.settings_for_repo!(repo_key), issue.state, head_sha(identifier), run_id) do
      {:ok, options} -> {:ok, %{request | options: options}, asked_by: %{kind: :run, name: "Conductor", run_id: run_id}}
      {:error, why} -> {:error, {:conductor_options, why}}
    end
  end

  defp request(_repo_key, _issue, _identifier, entry), do: {:ok, plain_request(entry), []}

  defp plain_request(entry) do
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

  defp merged_wait(tracker, identifier) do
    with {:ok, issue} <- issue(tracker, identifier) do
      tagged(RunStore.put_merged_wait(issue.id), {:merged_wait, identifier})
    end
  end

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

  defp event(dir, repo_key, tracker, now, %{"issue" => identifier, "type" => type} = entry) do
    at = DateTime.add(now, -Map.get(entry, "minutes_ago", 0) * 60, :second)

    with {:ok, issue} <- issue(tracker, identifier),
         {:ok, artifacts} <- output(dir, repo_key, issue.id, Map.put(entry, "at", at)) do
      run_id = Map.get(entry, "run_id")
      opts = [run_id: run_id, at: at, artifacts: artifacts, actor: actor(entry, run_id)]

      case TicketEvents.record(repo_key, issue.id, type, Map.get(entry, "payload", %{}), opts) do
        {:ok, _event} -> :ok
        {:error, reason} -> {:error, {{:event, identifier, type}, reason}}
      end
    end
  end

  defp actor(%{"actor" => "agent"} = entry, run_id), do: {:agent, run_id, Map.get(entry, "run_kind", "implementation")}
  defp actor(_entry, _run_id), do: :machine

  defp output(dir, repo_key, issue_id, %{"output" => %{"file" => _file} = output} = entry), do: keep(dir, repo_key, issue_id, entry, output, "step_output")
  defp output(dir, repo_key, issue_id, %{"picture" => %{"file" => _file} = picture} = entry), do: keep(dir, repo_key, issue_id, entry, picture, "screenshot")
  defp output(dir, repo_key, issue_id, %{"transcript" => %{"file" => _file} = lines} = entry), do: keep(dir, repo_key, issue_id, entry, lines, "transcript")
  defp output(_dir, _repo_key, _issue_id, _entry), do: {:ok, []}

  defp keep(dir, repo_key, issue_id, %{"issue" => identifier} = entry, %{"file" => file} = output, kind) do
    meta = %{repo_key: repo_key, issue_id: issue_id, run_id: Map.get(entry, "run_id"), label: Map.get(output, "label"), kind: kind}

    case ingest(Path.expand(file, dir), dir, meta, entry["at"]) do
      {:ok, artifact} ->
        if Map.get(output, "gone") == true, do: gone(artifact.id)
        {:ok, [artifact.id]}

      {:error, reason} ->
        {:error, {{:output, identifier, file}, reason}}
    end
  end

  # A step's lines carry the times they were written at, while the seed's events count back from
  # now: the lines move so the last one falls at the time of the event that keeps them, and a fact
  # the run recorded in that step falls among them as it did when the seed was written.
  defp ingest(path, dir, %{kind: "transcript"} = meta, %DateTime{} = at) do
    with {:ok, bytes} <- File.read(path),
         {:ok, moved} <- moved_lines(bytes, at) do
      tmp = Path.join(System.tmp_dir!(), "qa-seed-#{System.unique_integer([:positive])}-#{Path.basename(path)}")
      File.write!(tmp, moved)

      try do
        Artifacts.ingest(tmp, meta, roots: [System.tmp_dir!()])
      after
        File.rm(tmp)
      end
    else
      _unmoved -> Artifacts.ingest(path, meta, roots: [dir])
    end
  end

  defp ingest(path, dir, meta, _at), do: Artifacts.ingest(path, meta, roots: [dir])

  defp moved_lines(bytes, at) do
    lines = Enum.map(String.split(bytes, "\n"), &{&1, line_at(&1)})

    case lines |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> List.last() do
      nil ->
        :unmoved

      {_map, last} ->
        shift = at |> DateTime.truncate(:second) |> DateTime.diff(last, :second)
        {:ok, Enum.map_join(lines, "\n", &move(&1, shift))}
    end
  end

  defp line_at(line) do
    with {:ok, %{"at" => text} = map} <- Jason.decode(line),
         {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      {map, at}
    else
      _no_time -> nil
    end
  end

  defp move({line, nil}, _shift), do: line
  defp move({_line, {map, at}}, shift), do: Jason.encode!(Map.put(map, "at", at |> DateTime.add(shift, :second) |> DateTime.to_iso8601()))

  # The store no longer holds the bytes; the next read of its path marks the artifact expired.
  defp gone(id) do
    File.rm(Store.path(id))
    Artifacts.path(id)
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

  defp dependency(tracker, %{"issue" => identifier, "on" => on} = entry) do
    kind = if entry["kind"] == "released", do: :released, else: :done

    with {:ok, issue} <- issue(tracker, identifier),
         {:ok, on_issue} <- issue(tracker, on) do
      tagged(RunStore.add_dependency(issue.id, on_issue.id, kind), {:dependency, identifier})
    end
  end

  defp issue(tracker, identifier) do
    case tracker.fetch_issue_by_identifier(identifier) do
      {:ok, issue} -> {:ok, issue}
      {:error, reason} -> {:error, {:issue, identifier, reason}}
    end
  end

  defp tagged(:ok, _what), do: :ok
  defp tagged({:error, reason}, what), do: {:error, {what, reason}}
end
