defmodule SymphonyElixir.AgentTools.TicketLedger do
  @moduledoc """
  The agents' tools on the current ticket's event stream (`SymphonyElixir.TicketEvents`):
  `ticket_events` reads it and `ticket_record` appends to it. `ticket_events` gives each finding's
  `finding.recorded` where the finding stands (`SymphonyElixir.TicketEvents.findings/1`).
  `ticket_plan` reads what a groomed ticket works from (`SymphonyElixir.TicketPlan`,
  `SymphonyElixir.TicketChecks`): every ask, the current plan, its checks with where each stands,
  and the tagged notes of the ticket and of its parent. A ticket that is not groomed has no plan
  and no checks.

  The ticket comes from the session context, never from an argument, as
  `SymphonyElixir.AgentTools.Linear` does. Symphony fills what the agent cannot vouch for: the
  event's `seq`, its `actor` (the run and its run kind), its `run_id`, its `phase` (the ticket's)
  and its `head_sha` (the workspace's `HEAD`), and renders its `summary`.

  `ticket_record` takes only the types `SymphonyElixir.TicketEvents.Types.agent_types/1` allows the
  run's kind, and each rejection names its `reason` and returns the type's schema: an unknown type
  (`unknown_type`) or one the run may not record (`not_allowed`, with the types it may), a payload
  the schema refuses (`invalid_payload`, naming the fields), a `finding.resolved` naming no finding
  of the ticket (`unknown_finding`) or one already resolved (`already_resolved`, naming the
  resolution), or carrying no head that fixes it (`no_head`), a `check.proved` naming no check of the
  current plan (`unknown_check`, with the ids it `known`s), a proof naming a test the run's checkout
  lacks (`test_not_found`, a `check.proved` with `by: test` or an `evidence` whose `proof` has a
  `test`, looked up by `SymphonyElixir.QaPreCheck.missing_test/3`), a `parent` that is no event of the ticket (`unknown_parent`)
  and an artifact that is not a regular file under the workspace or the run's `$TMPDIR`
  (`invalid_artifact`). Every check runs before anything is written: a refused call ingests no file
  and records no event.

  Nothing is accepted and then dropped: every payload field is stored on the event, every file of
  `artifacts` is kept as one of its artifacts, and anything else is refused, an argument the tool
  does not take by `SymphonyElixir.Codex.DynamicTool`. A payload naming `artifacts` or `parent`, the
  tool's own arguments, is refused with where they go. A refusal carries the type's `schema`
  (`SymphonyElixir.TicketEvents.Types.schema/1`) and its one-line `shape`
  (`SymphonyElixir.TicketEvents.Types.shape/1`), and the tool's description lists the shape of every
  type a run may record (`record_shapes/0`), generated from the type catalog, so a run knows it
  before its first call.
  """

  alias SymphonyElixir.{
    Artifacts,
    PathSafety,
    PhaseSteps,
    PromptSafety,
    QaPreCheck,
    RunStore,
    TicketChecks,
    TicketEvents,
    TicketPlan,
    Workpad,
    WorkspaceHead
  }

  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.TicketEvents.{Event, Types}
  alias SymphonyElixir.Workpad.Projection

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
          "Record an event on the current ticket's history. A run records `finding.resolved` (an open or reopened finding it fixed, by `finding_id`; Symphony fills the head that fixes it), " <>
            "a delegated step's `step.started` and `step.completed` (`outcome` `passed`, `failed` with the step it `returns_to`, `paused` with the `question_id` it waits on, or `skipped` with a `reason`; Symphony records machine and orchestrated steps), " <>
            "`evidence` (with an optional `proof`: the walkthrough `step` number and the `test` that proves it; its measured values as `measures`, each a `measure`; " <>
            "and for a QA step the `step` it walked with its answer as `result`, a `step_answer`), " <>
            "`tests.ran` (a run that ran tests: how many `passed` and `failed`, as numbers it states, never pasted output), `checklist.answered`, " <>
            "`check.proved` (a check of the plan, by its `check_id`, and how: `by` `test` with the `test` that proves it, `qa`, `design`, `attached`, or `ci` for a `proof: ci` check the pull request's own CI run proves, with `details` naming the checks and the head) and `note` " <>
            "(with an optional `tag`: `discovery` for something found that is not this ticket's to solve, `base_fault` for a fault of the base branch); " <>
            "a QA run also records `finding.recorded`, and an implementation, rework or review-feedback run `brief.written` " <>
            "(the ticket's brief: `text`, what it does and why in a person's words, under 1,200 characters, and `walkthrough`, the steps a person takes, both with no backtick). " <>
            "Verdicts, moves, pauses, questions and runs are Symphony's: ask a question with the question tool. " <>
            "`artifacts` are paths of files in the workspace or your $TMPDIR, kept with the event (a screenshot shows as a thumbnail in the Director); `parent` nests the event under another. " <>
            "Files never go in `payload`: a payload naming a field its type lacks, or a value out of shape, is refused. " <>
            "Symphony fills the run, phase and head. A refusal returns its reason, the type's schema and its shape; nothing is written.\n\n" <>
            record_shapes(),
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["type", "payload"],
          "properties" => %{
            "type" => %{"type" => "string", "description" => "One of the types the description lists."},
            "payload" => %{"type" => "object", "description" => "The event's fields, in the shape the description lists for its `type`."},
            "artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
            "parent" => %{"type" => "string", "description" => "The id of an event of this ticket to nest this one under."}
          }
        }
      },
      %{
        "name" => "ticket_plan",
        "description" =>
          "Read what the current ticket works from: `ask` (what a person asked for, word for word, oldest first), `plan` (the current plan: its version, summary, text, shape, layers and size; null when the ticket has none), " <>
            "`checks` (the plan's checks, each with its id, kind, statement, how it is proved and its `state`: `open`, `proved` or `waived`) and `notes` (the tagged notes of this ticket and of its parent). " <>
            "It takes no argument.",
        "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
      }
    ]
  end

  @doc """
  The types some agent run may record with `ticket_record`, sorted: every run kind's
  `SymphonyElixir.TicketEvents.Types.agent_types/1`. Each run kind's own list is still enforced
  when it records.
  """
  @spec recordable_types() :: [String.t()]
  def recordable_types, do: Types.agent_run_kinds() |> Enum.flat_map(&Types.agent_types/1) |> Enum.uniq() |> Enum.sort()

  @doc """
  The payload shape of each type `recordable_types/0` lists, as `ticket_record`'s description
  carries it: generated from the type catalog (`SymphonyElixir.TicketEvents.Types.shape/1`), never
  written by hand, with the run kinds a type is restricted to and the named shapes it uses.
  """
  @spec record_shapes() :: String.t()
  def record_shapes do
    types =
      for type <- recordable_types() do
        "- `#{type}`#{run_kinds_note(type)}: #{Types.shape(type)}"
      end

    named = for {name, shape} <- Types.named_shapes(), do: "- `#{name}`: #{shape}"

    Enum.join(
      ["Payload shapes, from Symphony's type catalog (`?` marks a field that may be left out; string(N) holds at most N characters; a|b is one of the values):" | types] ++
        ["Named shapes:" | named],
      "\n"
    )
  end

  defp run_kinds_note(type) do
    case Types.catalog()[type].run_kinds do
      :any -> ""
      kinds -> " (#{Enum.join(kinds, ", ")} runs)"
    end
  end

  @doc "The arguments each tool takes."
  @spec tool_arguments() :: %{String.t() => [String.t()]}
  def tool_arguments do
    %{
      "ticket_events" => ["types", "since", "run_id", "open_findings", "limit"],
      "ticket_record" => ["type", "payload", "artifacts", "parent"],
      "ticket_plan" => []
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

  @doc """
  `ticket_plan`: what the current ticket works from (see the moduledoc). The plan is given without
  its checks, which `checks` lists with where each stands; a note says whether it is the ticket's
  own or its parent's (`on`). Each ask's `text`, the plan's `text` and each sub-ticket's `ask` come
  wrapped as untrusted text (`<linear_ticket_plan>`), as the prompts carry them.
  """
  @spec plan(context()) :: {:ok, map()} | {:error, error() | term()}
  def plan(context) do
    with {:ok, %{issue_id: issue_id}} <- ticket(context),
         events when is_list(events) <- RunStore.list_ticket_events(issue_id, []) do
      plan = TicketPlan.current(events)

      {:ok,
       %{
         "ask" => Enum.map(TicketPlan.ask(events), &untrusted(&1, :text)),
         "plan" => plan && plan |> Map.delete(:checks) |> untrusted(:text) |> untrusted_asks(),
         "checks" => TicketChecks.list(events),
         "notes" => notes(events, "ticket") ++ parent_notes(TicketPlan.parent_id(issue_id))
       }}
    end
  end

  # What a person wrote, and what a turn wrote from it, is data for the run that reads it: wrapped
  # as a prompt wraps a groomed ticket's ask and plan (`PromptSafety.ticket_plan_body/1`).
  defp untrusted(map, key), do: Map.update!(map, key, &PromptSafety.ticket_plan_body/1)

  defp untrusted_asks(plan) do
    if is_map_key(plan, :sub_tickets), do: Map.update!(plan, :sub_tickets, fn entries -> Enum.map(entries, &untrusted(&1, :ask)) end), else: plan
  end

  defp parent_notes(nil), do: []
  defp parent_notes(parent_id), do: notes(parent_id, "parent")

  defp notes(ticket, on), do: ticket |> TicketPlan.notes() |> Enum.map(&Map.put(&1, :on, on))

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

  @doc """
  `ticket_record`: records `args`' event on the current ticket (see the moduledoc). A step event
  projects the workpad (`SymphonyElixir.Workpad.Projection`) with `opts`' `:linear_client` and
  `:settings`.
  """
  @spec record(context(), map(), keyword()) :: {:ok, map()} | {:error, error() | term()}
  def record(context, args, opts \\ []) do
    type = Map.get(args, "type")
    run_kind = Map.get(context, :run_kind)

    head = head(context)

    with {:ok, ticket} <- ticket(context),
         :ok <- allowed(type, run_kind),
         {:ok, payload} <- payload(type, Map.get(args, "payload"), run_kind),
         stored when is_list(stored) <- RunStore.list_ticket_events(ticket.issue_id, []),
         :ok <- finding(type, payload, stored, head),
         :ok <- check(type, payload, stored),
         :ok <- proof_test(type, payload, context),
         {:ok, parent} <- parent(type, Map.get(args, "parent"), stored),
         {:ok, sources} <- sources(type, Map.get(args, "artifacts"), context),
         {:ok, artifact_ids} <- ingest(type, sources, ticket, context),
         {:ok, event} <-
           write(ticket, type, payload,
             actor: {:agent, Map.get(context, :run_id), run_kind},
             head_sha: head,
             parent: parent,
             artifacts: artifact_ids
           ) do
      project(type, ticket, run_kind, Keyword.take(opts, [:linear_client, :settings]))
      {:ok, %{"event" => event_json(event)}}
    end
  end

  # A proof is recorded once per check and head (`SymphonyElixir.TicketChecks.prove/4`).
  defp write(ticket, "check.proved", payload, opts), do: TicketChecks.prove(ticket.repo_key, ticket.issue_id, payload, opts)
  defp write(ticket, type, payload, opts), do: TicketEvents.record(ticket.repo_key, ticket.issue_id, type, payload, opts)

  # A delegated step's event changes the workpad's Plan, rendered in the run's step-list order
  # (`SymphonyElixir.Workpad.Projection`), as the step runner's own step events do.
  defp project(type, ticket, run_kind, opts) when type in ["step.started", "step.completed"],
    do: Projection.project_later({:ticket, ticket.repo_key, ticket.issue_id}, [steps: PhaseSteps.steps(Phases.kind(run_kind))] ++ opts)

  defp project(_type, _ticket, _run_kind, _opts), do: :ok

  @doc """
  Writes the agent's comment `body` with `write` (`linear_update_comment`). A workpad body of the
  current ticket is written under the workpad projection's lock, with Symphony's Plan and
  Validation put in (`SymphonyElixir.Workpad.Projection.write_agent_body/4`), so a projection
  started by a step event never writes the agent's newer Notes back to older ones. Any other body
  is written as it is.
  """
  @spec write_comment(context(), term(), (term() -> result), keyword()) :: result when result: term()
  def write_comment(context, body, write, opts \\ []) when is_function(write, 1) do
    with true <- Workpad.workpad_body?(body),
         {:ok, ticket} <- ticket(context) do
      steps = PhaseSteps.steps(Phases.kind(Map.get(context, :run_kind)))
      Projection.write_agent_body(ticket.issue_id, body, write, [steps: steps] ++ Keyword.take(opts, [:linear_client, :settings]))
    else
      _not_a_workpad_or_no_ticket -> write.(body)
    end
  end

  @doc """
  The ticket the session `context` names (`issue_id` and `repo_key`, else its issue's), or the
  `no_ticket` refusal. The qa_* picture tools check it before they take a picture
  (`SymphonyElixir.AgentTools.QaPictures`).
  """
  @spec current_ticket(context()) :: {:ok, %{issue_id: String.t(), repo_key: String.t()}} | {:error, error()}
  def current_ticket(context), do: ticket(context)

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
        message = "The #{type} payload is not valid: #{Enum.join(fields, ", ")}.#{argument_hint(fields)} Its shape: #{Types.shape(type)}"
        refusal("invalid_payload", message, type, nil, %{"fields" => fields})

      # A value only Symphony records, such as a machine step's mode.
      {:error, {:not_allowed, why}} ->
        refusal("not_allowed", why <> ".", type)
    end
  end

  # A tool argument given inside the payload, where it would be lost, is named as the argument it is.
  defp argument_hint(fields) do
    if Enum.any?(["artifacts", "parent"], &(&1 in fields)),
      do: " `artifacts` and `parent` are arguments of ticket_record beside `type` and `payload`, never payload fields: files go in `artifacts`.",
      else: ""
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

  # A proof names a check of the current plan: a ticket with no plan has none.
  defp check("check.proved", %{check_id: id}, stored) do
    known = stored |> TicketChecks.list() |> Enum.map(& &1.id)

    cond do
      id in known ->
        :ok

      known == [] ->
        refusal("unknown_check", "This ticket has no plan, so it has no check to prove.", "check.proved", nil, %{"known" => known})

      true ->
        refusal("unknown_check", "#{inspect(id)} is not a check of this ticket's plan. Its checks are: #{Enum.join(known, ", ")}.", "check.proved", nil, %{"known" => known})
    end
  end

  defp check(_type, _payload, _stored), do: :ok

  defp proof_test("check.proved" = type, %{by: "test", test: test}, context), do: find_test(context, test, type)
  defp proof_test("evidence" = type, %{proof: %{test: test}}, context), do: find_test(context, test, type)
  defp proof_test(_type, _payload, _context), do: :ok

  @doc """
  Whether the test a proof names is in the run's checkout (the session's workspace)
  (`SymphonyElixir.QaPreCheck.missing_test/3`): a proof accepted when it is recorded is complete,
  and nothing later looks for its test again. A refusal (`test_not_found`) says what is missing and the forms
  of test name the lookup takes. A session with no checkout (no workspace, or one that is not a git
  checkout) has nothing to search, and its proof is taken as it is. `opts[:git]` runs git.
  """
  @spec find_test(context(), String.t(), String.t() | nil, keyword()) :: :ok | {:error, error()}
  def find_test(context, test, type \\ nil, opts \\ []) do
    workspace = Map.get(context, :workspace)

    with true <- is_binary(workspace) and File.exists?(Path.join(workspace, ".git")),
         missing when is_binary(missing) <- QaPreCheck.missing_test(test, workspace, opts) do
      refusal(
        "test_not_found",
        "The test this proof names is not in the checkout: #{missing}. Name it so QA finds it: #{QaPreCheck.test_name_forms()}.",
        type,
        nil,
        %{"test" => test}
      )
    else
      _found_or_no_checkout -> :ok
    end
  end

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
      |> put_present("shape", Types.shape(type))
      |> put_present("allowed", allowed)
      |> Map.merge(extra)

    {:error, {:ticket_ledger, error}}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
