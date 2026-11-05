defmodule SymphonyElixir.AgentTools.TicketLedger do
  @moduledoc """
  The agents' tools on the current ticket's event stream (`SymphonyElixir.TicketEvents`):
  `ticket_events` reads it and `ticket_record` appends to it. `ticket_events` gives each finding's
  `finding.recorded` where the finding stands (`SymphonyElixir.TicketEvents.findings/1`).

  The ticket comes from the session context, never from an argument, as
  `SymphonyElixir.AgentTools.Linear` does. Symphony fills what the agent cannot vouch for: the
  event's `seq`, its `actor` (the run and its run kind), its `run_id`, its `phase` (the ticket's)
  and its `head_sha` (the workspace's `HEAD`), and renders its `summary`.

  `ticket_record` takes only the types `SymphonyElixir.TicketEvents.Types.agent_types/1` allows the
  run's kind, and each rejection names its `reason` and returns the type's schema: an unknown type
  (`unknown_type`) or one the run may not record (`not_allowed`, with the types it may), a payload
  the schema refuses (`invalid_payload`, naming the fields), a `finding.resolved` naming no finding
  of the ticket (`unknown_finding`) or one already resolved (`already_resolved`, naming the
  resolution), or carrying no head that fixes it (`no_head`), a `parent` that is no event of the ticket (`unknown_parent`)
  and an artifact that is not a regular file under the workspace or the run's `$TMPDIR`
  (`invalid_artifact`). Every check runs before anything is written: a refused call ingests no file
  and records no event.
  """

  alias SymphonyElixir.{Artifacts, PathSafety, RunStore, TicketEvents, WorkspaceHead}
  alias SymphonyElixir.TicketEvents.{Event, Types}

  @max_limit 200
  @screenshot_exts ~w(.png .jpg .jpeg)
  @log_exts ~w(.log .txt)

  @type context :: %{
          optional(:issue) => map() | nil,
          optional(:issue_id) => String.t() | nil,
          optional(:repo_key) => String.t() | nil,
          optional(:workspace) => Path.t() | nil,
          optional(:run_id) => String.t() | nil,
          optional(:run_kind) => String.t() | nil,
          optional(:agent_tmp_dir) => Path.t() | nil,
          optional(atom()) => term()
        }

  @typedoc ~s|A refusal: `{:ticket_ledger, %{"reason" => …, "message" => …}}`, with the type's `schema` when it has one.|
  @type error :: {:ticket_ledger, map()}

  @doc "The tool's input schemas, as `SymphonyElixir.Codex.DynamicTool` lists them."
  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => "ticket_events",
        "description" =>
          "Read the current ticket's history of events (Symphony's ledger), oldest first: findings, steps, evidence, notes, runs, verdicts and moves. " <>
            "Each event carries its id, seq, time, type, actor, summary, payload, the head it was recorded on and its artifacts (id, kind, label, url). " <>
            "A finding's `finding.recorded` carries `finding`: its `state` (`open`, `resolved_awaiting_qa`, `reopened`, `confirmed`), its `resolution` and the head it was `resolved_on`, the event that `reopened_by` it and the resolution it `superseded`, and the verdict's `confirmed_by`. " <>
            "`open_findings: true` keeps the findings QA has not confirmed fixed (open, resolved awaiting QA, reopened); `types`, `since` (ISO 8601, exclusive), `run_id` and `limit` (at most #{@max_limit}) narrow the read.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "types" => %{"type" => "array", "items" => %{"type" => "string"}},
            "since" => %{"type" => "string", "description" => "An ISO 8601 time: only events after it."},
            "run_id" => %{"type" => "string"},
            "open_findings" => %{"type" => "boolean"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_limit}
          }
        }
      },
      %{
        "name" => "ticket_record",
        "description" =>
          "Record an event on the current ticket's history. A run records `finding.resolved` (an open or reopened finding it fixed, by `finding_id`; Symphony fills the head that fixes it), `step.started`, `step.completed`, `step.skipped`, " <>
            "`evidence` (with an optional `proof`: the walkthrough `step` number and the `test` that proves it), `checklist.answered` and `note`; a QA run also records `finding.recorded`. " <>
            "Verdicts, moves, pauses, questions and runs are Symphony's: ask a question with the question tool. " <>
            "`artifacts` are paths of files in the workspace or your $TMPDIR, kept with the event (a screenshot shows as a thumbnail in the Director); `parent` nests the event under another. " <>
            "Symphony fills the run, phase and head. A refusal returns its reason and the type's schema; nothing is written.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["type", "payload"],
          "properties" => %{
            "type" => %{"type" => "string"},
            "payload" => %{"type" => "object"},
            "artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
            "parent" => %{"type" => "string", "description" => "The id of an event of this ticket to nest this one under."}
          }
        }
      }
    ]
  end

  @doc "The arguments each tool takes."
  @spec tool_arguments() :: %{String.t() => [String.t()]}
  def tool_arguments do
    %{
      "ticket_events" => ["types", "since", "run_id", "open_findings", "limit"],
      "ticket_record" => ["type", "payload", "artifacts", "parent"]
    }
  end

  @doc "`ticket_events`: the current ticket's events `args` keeps (see the moduledoc)."
  @spec events(context(), map()) :: {:ok, map()} | {:error, error() | term()}
  def events(context, args) do
    with {:ok, %{issue_id: issue_id}} <- ticket(context),
         {:ok, opts} <- query_opts(args),
         events when is_list(events) <- TicketEvents.query(issue_id, opts),
         stored when is_list(stored) <- RunStore.list_ticket_events(issue_id, []) do
      findings = stored |> TicketEvents.findings() |> Map.new(&{&1.finding.id, &1})
      {:ok, %{"events" => Enum.map(events, &(&1 |> event_json() |> put_present("finding", finding_json(findings[&1.id]))))}}
    end
  end

  # Where a finding stands, on its `finding.recorded` event.
  defp finding_json(nil), do: nil

  defp finding_json(finding) do
    %{
      "state" => finding_state(finding.state),
      "resolution" => finding.resolution && finding.resolution.id,
      "resolved_on" => finding.resolution && Map.get(finding.resolution.payload, :head),
      "reopened_by" => finding.reopened_by && finding.reopened_by.id,
      "superseded" => finding.superseded && finding.superseded.id,
      "confirmed_by" => finding.confirmation && finding.confirmation.id
    }
  end

  defp finding_state(:resolved), do: "resolved_awaiting_qa"
  defp finding_state(state), do: Atom.to_string(state)

  @doc "`ticket_record`: records `args`' event on the current ticket (see the moduledoc)."
  @spec record(context(), map()) :: {:ok, map()} | {:error, error() | term()}
  def record(context, args) do
    type = Map.get(args, "type")
    run_kind = Map.get(context, :run_kind)

    head = head(context)

    with {:ok, ticket} <- ticket(context),
         :ok <- allowed(type, run_kind),
         {:ok, payload} <- payload(type, Map.get(args, "payload"), run_kind),
         stored when is_list(stored) <- RunStore.list_ticket_events(ticket.issue_id, []),
         :ok <- finding(type, payload, stored, head),
         {:ok, parent} <- parent(type, Map.get(args, "parent"), stored),
         {:ok, sources} <- sources(type, Map.get(args, "artifacts"), context),
         {:ok, artifact_ids} <- ingest(type, sources, ticket, context),
         {:ok, event} <-
           TicketEvents.record(ticket.repo_key, ticket.issue_id, type, payload,
             actor: {:agent, Map.get(context, :run_id), run_kind},
             head_sha: head,
             parent: parent,
             artifacts: artifact_ids
           ) do
      {:ok, %{"event" => event_json(event)}}
    end
  end

  defp ticket(context) do
    issue = Map.get(context, :issue) || %{}
    issue_id = present(Map.get(context, :issue_id)) || present(Map.get(issue, :id))
    repo_key = present(Map.get(context, :repo_key)) || present(Map.get(issue, :repo_key))

    if issue_id && repo_key,
      do: {:ok, %{issue_id: issue_id, repo_key: repo_key}},
      else: refusal("no_ticket", "This session has no current ticket.")
  end

  defp query_opts(args) do
    Enum.reduce_while(args, {:ok, []}, fn {key, value}, {:ok, opts} ->
      case query_opt(key, value) do
        {:ok, opt} -> {:cont, {:ok, opt ++ opts}}
        :error -> {:halt, refusal("invalid_argument", "`#{key}` is not valid: #{inspect(value)}.")}
      end
    end)
  end

  defp query_opt(_key, nil), do: {:ok, []}

  defp query_opt("types", types) when is_list(types) do
    if Enum.all?(types, &is_binary/1), do: {:ok, [types: types]}, else: :error
  end

  defp query_opt("since", since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, at, _offset} -> {:ok, [since: at]}
      {:error, _reason} -> :error
    end
  end

  defp query_opt("run_id", run_id) when is_binary(run_id), do: {:ok, [run_id: run_id]}
  defp query_opt("open_findings", open?) when is_boolean(open?), do: {:ok, [open_findings: open?]}
  defp query_opt("limit", limit) when is_integer(limit) and limit in 1..@max_limit, do: {:ok, [limit: limit]}
  defp query_opt(_key, _value), do: :error

  defp allowed(type, run_kind) do
    may_record = Types.agent_types(run_kind)

    cond do
      type in may_record ->
        :ok

      is_nil(Types.schema(type)) ->
        refusal("unknown_type", "#{inspect(type)} is not an event type. This run may record: #{Enum.join(may_record, ", ")}.", nil, may_record)

      true ->
        refusal("not_allowed", "A #{run_kind} run may not record #{type}. It may record: #{Enum.join(may_record, ", ")}.", type, may_record)
    end
  end

  defp payload(type, payload, run_kind) do
    case Types.validate(type, payload, :agent, run_kind) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, {:invalid_payload, fields}} ->
        fields = Enum.map(fields, &to_string/1)
        refusal("invalid_payload", "The #{type} payload is not valid: #{Enum.join(fields, ", ")}.", type, nil, %{"fields" => fields})
    end
  end

  defp finding("finding.resolved", %{finding_id: id} = payload, stored, head) do
    case TicketEvents.check_resolution(stored, id, Map.get(payload, :head) || head) do
      :ok ->
        :ok

      {:error, {:unknown_finding, _id}} ->
        refusal("unknown_finding", "#{inspect(id)} is not a finding of this ticket.", "finding.resolved")

      {:error, {:finding_already_resolved, _id, resolution}} ->
        refusal("already_resolved", "#{inspect(id)} is already resolved by #{resolution}; only an open or reopened finding can be resolved.", "finding.resolved", nil, %{
          "resolution" => resolution
        })

      {:error, {:no_head, _id}} ->
        refusal("no_head", "The workspace has no readable head: pass the commit that fixes #{inspect(id)} as the payload's `head`.", "finding.resolved")
    end
  end

  defp finding(_type, _payload, _stored, _head), do: :ok

  defp parent(_type, nil, _stored), do: {:ok, nil}

  defp parent(type, parent, stored) do
    if is_binary(parent) and Enum.any?(stored, &(&1.id == parent)),
      do: {:ok, parent},
      else: refusal("unknown_parent", "#{inspect(parent)} is not an event of this ticket.", type)
  end

  # Every path is checked before any is ingested, so a refused call keeps no file.
  defp sources(_type, nil, _context), do: {:ok, []}

  defp sources(type, paths, context) when is_list(paths) do
    roots = roots(context)

    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, sources} ->
      case source(path, Map.get(context, :workspace), roots) do
        {:ok, source} -> {:cont, {:ok, sources ++ [source]}}
        {:error, why} -> {:halt, artifact_refusal(type, path, why)}
      end
    end)
  end

  defp sources(type, paths, _context), do: artifact_refusal(type, paths, "artifacts must be a list of file paths")

  defp source(path, workspace, roots) when is_binary(path) and path != "" do
    expanded = if is_binary(workspace), do: Path.expand(path, workspace), else: Path.expand(path)

    with {:ok, canonical} <- PathSafety.canonicalize(expanded),
         true <- Enum.any?(roots, &under?(canonical, &1)) || {:error, "it is outside the workspace and $TMPDIR"},
         {:ok, %File.Stat{type: :regular}} <- File.lstat(expanded) do
      {:ok, expanded}
    else
      {:ok, %File.Stat{}} -> {:error, "it is not a regular file"}
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, _reason} -> {:error, "it cannot be read"}
    end
  end

  defp source(_path, _workspace, _roots), do: {:error, "it is not a path"}

  defp roots(context) do
    [Map.get(context, :workspace), Map.get(context, :agent_tmp_dir)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.flat_map(fn root ->
      case PathSafety.canonicalize(Path.expand(root)) do
        {:ok, canonical} -> [canonical]
        {:error, _reason} -> []
      end
    end)
  end

  defp under?(path, root), do: String.starts_with?(path, String.trim_trailing(root, "/") <> "/")

  defp ingest(type, sources, ticket, context) do
    meta = %{repo_key: ticket.repo_key, issue_id: ticket.issue_id, run_id: Map.get(context, :run_id)}
    roots = roots(context)

    Enum.reduce_while(sources, {:ok, []}, fn path, {:ok, ids} ->
      case ingest_file(path, Map.merge(meta, %{label: Path.basename(path), kind: kind(path)}), roots) do
        {:ok, id} -> {:cont, {:ok, ids ++ [id]}}
        {:error, reason} -> {:halt, artifact_refusal(type, path, "it could not be kept (#{inspect(reason)})")}
      end
    end)
  end

  # A `.png` or `.jpg` that is neither is kept as a plain `file`.
  defp ingest_file(path, meta, roots) do
    case Artifacts.ingest(path, meta, roots: roots) do
      {:ok, %{id: id}} -> {:ok, id}
      {:error, :unsupported_mime} when meta.kind == "screenshot" -> ingest_file(path, %{meta | kind: "file"}, roots)
      {:error, reason} -> {:error, reason}
    end
  end

  defp kind(path) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      ext in @screenshot_exts -> "screenshot"
      ext in @log_exts -> "log"
      true -> "file"
    end
  end

  defp head(context) do
    case Map.get(context, :workspace) do
      workspace when is_binary(workspace) -> WorkspaceHead.read(workspace, nil)
      _none -> nil
    end
  end

  defp event_json(%Event{} = event) do
    %{
      "id" => event.id,
      "seq" => event.seq,
      "at" => event.at && DateTime.to_iso8601(event.at),
      "type" => event.type,
      "actor" => event.actor,
      "run_id" => event.run_id,
      "head_sha" => event.head_sha,
      "parent" => event.parent,
      "summary" => event.summary,
      "payload" => event.payload,
      "artifacts" => Enum.map(event.artifacts, &artifact_json/1)
    }
  end

  defp artifact_json(id) do
    case Artifacts.get(id) do
      {:ok, artifact} -> %{"id" => id, "kind" => artifact.kind, "label" => artifact.label, "url" => "/api/v1/artifacts/" <> id}
      {:error, :not_found} -> %{"id" => id, "kind" => nil, "label" => nil, "url" => nil}
    end
  end

  defp artifact_refusal(type, path, why), do: refusal("invalid_artifact", "The artifact #{inspect(path)} is refused: #{why}.", type, nil, %{"path" => path})

  defp refusal(reason, message, type \\ nil, allowed \\ nil, extra \\ %{}) do
    error =
      %{"reason" => reason, "message" => message}
      |> put_present("schema", Types.schema(type))
      |> put_present("allowed", allowed)
      |> Map.merge(extra)

    {:error, {:ticket_ledger, error}}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
