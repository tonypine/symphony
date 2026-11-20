defmodule SymphonyElixir.Conductor.Filing do
  @moduledoc """
  The Conductor's `ticket` route (`SymphonyElixir.Conductor.Answer`): a ticket Symphony files for a
  problem that is not the current ticket's to solve, because it lives in another repo or in
  Symphony's own QA tooling, or because solving it here would add a separate piece of work to
  review and QA.

  The turn names the ticket's content (`title`, `problem`, `wanted`, `acceptance`, `walkthrough`,
  the `evidence` event ids it rests on), the repo it belongs to (`repo`, any repo Symphony
  manages) and how it relates to the current ticket (`relation`):

    * `blocks`: the ticket is linked as blocking the current one, which is held on it until it is
      terminal (`SymphonyElixir.SelfHeal.hold/3`), and then continues from the stage it was held
      in;
    * `follow_up`: the two are linked as related, and the current ticket goes on at once.

  Symphony assembles the description in the house format (Problem, Wanted behaviour, Acceptance
  criteria, User walkthrough, and the evidence from the current ticket's events, naming the ticket
  it came from) and files it through the self-heal lane's filer (`SymphonyElixir.SelfHeal.file_ticket/3`),
  the one way Symphony creates a ticket: in Todo, Urgent, labelled `tech debt`, assigned to the
  owner the target repo polls for, in that repo's project.

  The bounds, read from the ticket's events: `conductor.file_tickets` on; at most
  `conductor.max_filed_tickets` tickets filed per ticket over its whole life (a link to an open
  ticket that already covers the problem is not a filing); and a ticket the Conductor filed
  (`ticket.filed_from`) files none of its own. Before filing, an open ticket the turn names as
  covering the problem (`existing`), an open one it already filed from this ticket in the same repo
  under the same title, or an open ticket already linked as blocking this one under the same title,
  is linked instead of a duplicate.

  What a filing records: a `ticket.filed` on the current ticket (`by: conductor`, the relation as
  its `kind`: `split_off` for `blocks`, `follow_up`), and a `ticket.filed_from` on the new one. A
  route past a bound, naming a repo Symphony does not manage, or missing a section is refused
  (`{:error, why}`), and the turn takes no route.
  """

  require Logger

  alias SymphonyElixir.Conductor.Facts
  alias SymphonyElixir.{Config, SelfHeal, TicketEvents}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TicketEvents.{Event, Summary}

  @label "tech debt"
  @urgent 1
  @relations %{"blocks" => "split_off", "follow_up" => "follow_up"}
  @sections [
    title: "a title",
    problem: "its problem",
    wanted: "its wanted behaviour",
    acceptance: "its acceptance criteria",
    walkthrough: "its walkthrough"
  ]
  @reason_max 600
  @evidence_max 6

  @typedoc "A ticket the route filed or linked: its identifier, URL, relation, title, and whether it existed already."
  @type filed :: %{
          identifier: String.t(),
          url: String.t() | nil,
          relation: String.t(),
          title: String.t(),
          existing: boolean(),
          repo: String.t()
        }

  @doc """
  What the turn's facts say about the route (`filings`): whether it is `open` now and, when it is
  not, why (`closed`); the tickets the Conductor already filed or linked for this ticket (`filed`);
  how many filings remain (`left`); and the repos a ticket may be filed in (`repos`). `opts`:
  `repos` (the managed repo keys, default `Config.repos/0`'s).
  """
  @spec facts([Event.t()], Schema.Conductor.t(), keyword()) :: map()
  def facts(events, %Schema.Conductor{} = settings, opts \\ []) when is_list(events) do
    filed = filed(events)

    %{
      open: closed(events, settings) == nil,
      closed: closed(events, settings),
      filed: Enum.map(filed, &Map.take(&1, [:identifier, :relation, :repo, :title, :existing, :event_id])),
      left: left(events, settings),
      repos: repo_keys(opts)
    }
  end

  @doc """
  Files or links the ticket `route` names for the current ticket (`context`: its `issue`, its
  `repo_key`, the Conductor's `run_id` and the ticket's `events`, oldest first), within the bounds
  of `settings` (the `conductor` section). `{:ok, filed}` once the ticket exists and is linked (and,
  for `blocks`, the current ticket is held on it); `{:error, why}`, in plain words, when the route is
  refused or the filing failed. A ticket created whose hold could not be set is still recorded, and
  `why` names it. `opts`: the injectable `:tracker`, `:fixer`, `:hold` (`SymphonyElixir.SelfHeal.file_ticket/3`'s),
  `:repo` (`(key -> {:ok, repo} | {:error, term})`, default `Config.repo/1`) and `:terminal_states`.
  """
  @spec file(map(), map(), Schema.Conductor.t(), keyword()) :: {:ok, filed()} | {:error, String.t()}
  def file(%{to: "ticket"} = route, %{issue: %Issue{} = issue, events: events} = context, %Schema.Conductor{} = settings, opts \\ []) do
    with nil <- closed(events, settings),
         {:ok, relation} <- relation(route),
         :ok <- managed(route.repo, opts),
         :ok <- sections(route) do
      existing = existing(route, issue, events, opts)
      route |> file_ticket(relation, existing, context, opts) |> filed(route, relation, context)
    else
      why when is_binary(why) -> {:error, why}
    end
  end

  # A ticket that exists is recorded (`ticket.filed`, `ticket.filed_from`) whether or not its hold
  # could be set, so the limit and the dedupe count it and the next turn never files it again.
  defp filed({:ok, ticket}, route, relation, context) do
    {:ok, record_filed(ticket, route, relation, context)}
  end

  defp filed({:error, {:hold_failed, reason}, ticket}, route, relation, context) do
    filed = record_filed(ticket, route, relation, context)
    {:error, "I filed `#{filed.identifier}`, but this ticket could not be held on it: #{inspect(reason)}"}
  end

  defp filed({:error, reason}, _route, _relation, _context), do: {:error, "the ticket could not be filed: #{inspect(reason)}"}

  @doc """
  The sentence the Conductor's update on the current ticket carries about `filed`: the ticket, its
  relation and why it was split off (`reason`, the route's problem).
  """
  @spec message(filed(), String.t() | nil) :: String.t()
  def message(%{identifier: identifier, relation: relation, title: title} = filed, reason) do
    verb = if filed.existing, do: "I linked `#{identifier}`, which was already open,", else: "I filed `#{identifier}`"
    because = if is_binary(reason), do: " " <> fit(reason, 300), else: ""
    title = String.trim_trailing(title, ".")

    case relation do
      "blocks" -> "#{verb} as blocking this ticket: #{title}.#{because} This ticket waits for it to be Done, then continues where it stopped."
      "follow_up" -> "#{verb} as a follow-up: #{title}.#{because} This ticket goes on without it."
    end
  end

  # Why the route is closed on this ticket, or nil when it is open.
  defp closed(events, settings) do
    cond do
      not settings.file_tickets -> "filing tickets is switched off (conductor.file_tickets)"
      from(events) -> "this ticket was itself filed by the Conductor (from #{from(events)}), and a ticket it filed files none of its own"
      left(events, settings) == 0 -> "this ticket already filed #{settings.max_filed_tickets}, its limit (conductor.max_filed_tickets)"
      true -> nil
    end
  end

  defp left(events, settings) do
    filings = events |> filed() |> Enum.count(&(not &1.existing))
    max(settings.max_filed_tickets - filings, 0)
  end

  # The tickets the Conductor filed or linked from this ticket, oldest first.
  defp filed(events) do
    for %Event{type: "ticket.filed"} = event <- events, field(event, :by) == "conductor" do
      %{
        identifier: field(event, :identifier),
        relation: if(field(event, :kind) == "follow_up", do: "follow_up", else: "blocks"),
        repo: field(event, :repo),
        title: field(event, :title),
        existing: field(event, :existing) == true,
        event_id: event.id
      }
    end
  end

  defp from(events) do
    Enum.find_value(events, fn event -> if event.type == "ticket.filed_from", do: field(event, :from) end)
  end

  defp relation(%{relation: relation}) when is_map_key(@relations, relation), do: {:ok, relation}
  defp relation(_route), do: "the ticket route's relation must be blocks or follow_up"

  defp managed(repo, opts) when is_binary(repo) do
    case Keyword.get(opts, :repo, &Config.repo/1).(repo) do
      {:ok, _repo} -> :ok
      {:error, _reason} -> "the ticket route names the repo #{inspect(repo)}, which Symphony does not manage"
    end
  end

  defp managed(_repo, _opts), do: "the ticket route names no repo"

  defp sections(route) do
    case Enum.find(@sections, fn {key, _words} -> Map.get(route, key) in [nil, []] end) do
      nil -> :ok
      {_key, words} -> "the ticket route misses #{words}"
    end
  end

  # The open ticket that already covers the problem: the one the turn named, else one it already
  # filed from this ticket in the same repo under the same title, else an open ticket already linked
  # as blocking this one (by hand, or by the self-heal lane) under the same title. A named ticket that
  # is terminal, unreadable or the current one covers nothing, and a new ticket is filed.
  defp existing(route, issue, events, opts) do
    named = route.existing && open_ticket(route.existing, issue, opts)
    named || already_filed(route, issue, events, opts) || linked_blocker(route, issue, opts)
  end

  defp linked_blocker(route, issue, opts) do
    issue
    |> blockers(opts)
    |> Enum.reject(&(is_binary(&1[:state]) and terminal?(&1.state, opts)))
    |> Enum.find_value(fn %{identifier: id} -> covering(open_issue(id, issue, opts), id, route) end)
  end

  defp covering(%Issue{title: title, url: url}, identifier, route) do
    if same_title?(title, route.title), do: %{identifier: identifier, url: url}
  end

  defp covering(nil, _identifier, _route), do: nil

  # The tickets linked as blocking `issue`: the ones it carries, else the tracker's read of it.
  defp blockers(%Issue{blocked_by: [_ | _] = blockers}, _opts), do: Enum.filter(blockers, &is_binary(&1[:identifier]))

  defp blockers(%Issue{identifier: identifier}, opts) when is_binary(identifier) do
    case tracker(opts).fetch_issue_by_identifier(identifier) do
      {:ok, %Issue{blocked_by: [_ | _] = blockers}} -> Enum.filter(blockers, &is_binary(&1[:identifier]))
      _other -> []
    end
  end

  defp blockers(_issue, _opts), do: []

  defp already_filed(route, issue, events, opts) do
    events
    |> filed()
    |> Enum.find_value(fn ticket ->
      if ticket.repo == route.repo and same_title?(ticket.title, route.title), do: open_ticket(ticket.identifier, issue, opts)
    end)
  end

  defp same_title?(a, b) when is_binary(a) and is_binary(b), do: normalize(a) == normalize(b)
  defp same_title?(_a, _b), do: false

  defp normalize(text), do: text |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp open_ticket(identifier, issue, opts) do
    case open_issue(identifier, issue, opts) do
      %Issue{url: url} ->
        %{identifier: identifier, url: url}

      nil ->
        Logger.info("Conductor cannot link #{identifier} from #{issue.identifier}: it is not an open ticket of its own")
        nil
    end
  end

  # The ticket `identifier` names when it is open and not `issue` itself, else nil.
  defp open_issue(identifier, issue, opts) do
    case tracker(opts).fetch_issue_by_identifier(identifier) do
      {:ok, %Issue{id: id, state: state} = found} when id != issue.id -> if terminal?(state, opts), do: nil, else: found
      _other -> nil
    end
  end

  defp file_ticket(route, relation, existing, %{issue: issue, repo_key: repo_key} = context, opts) do
    ticket = %{
      scope: route.repo,
      relation: relation,
      title: route.title,
      description: description(route, relation, context),
      labels: [@label],
      existing: existing && existing.identifier
    }

    case SelfHeal.file_ticket(issue, ticket, [repo_key: repo_key, priority: @urgent] ++ Keyword.take(opts, [:fixer, :hold])) do
      {:ok, filed} -> {:ok, Map.merge(%{url: existing && existing.url}, filed)}
      {:error, reason, filed} -> {:error, reason, Map.merge(%{url: existing && existing.url}, filed)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The description Symphony writes for the ticket `route` names, filed from `context`'s issue: the
  house format's sections from the route, the ticket it came from and how it relates to it, and the
  evidence the route names, one line per event the ticket holds.
  """
  @spec description(map(), String.t(), map()) :: String.t()
  def description(route, relation, %{issue: issue, events: events}) do
    from = issue.identifier || issue.id

    origin =
      case relation do
        "blocks" -> "The Conductor filed this ticket from #{from}, which waits for it to be Done and then continues."
        "follow_up" -> "The Conductor filed this ticket from #{from} as a follow-up; #{from} goes on without it."
      end

    [
      "## Problem\n\n" <> route.problem <> "\n\n" <> origin,
      "## Wanted behaviour\n\n" <> route.wanted,
      "## Acceptance criteria\n\n" <> Enum.map_join(route.acceptance, "\n", &("- " <> &1)),
      "## User walkthrough\n\n" <> (route.walkthrough |> Enum.with_index(1) |> Enum.map_join("\n", fn {step, n} -> "#{n}. #{step}" end)),
      evidence(route.evidence, events, from)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp evidence(ids, events, from) do
    by_id = Map.new(events, &{&1.id, &1})

    case ids |> Enum.flat_map(&List.wrap(Map.get(by_id, &1))) |> Enum.take(@evidence_max) do
      [] -> nil
      found -> "## Evidence from #{from}\n\n" <> Enum.map_join(found, "\n", &evidence_line/1)
    end
  end

  defp evidence_line(%Event{} = event) do
    %{title: title, detail: detail} = Summary.render(event)
    line = if is_binary(detail), do: "#{title}: #{fit(detail, 300)}", else: title
    "- #{line} (event #{event.id})"
  end

  defp record_filed(ticket, route, relation, %{issue: issue, repo_key: repo_key, run_id: run_id}) do
    filed = %{identifier: ticket.identifier, url: Map.get(ticket, :url), relation: relation, title: route.title, existing: ticket.existing, repo: route.repo}
    kind = Map.fetch!(@relations, relation)

    payload =
      %{identifier: filed.identifier, kind: kind, title: String.slice(filed.title, 0, 300), by: "conductor", repo: filed.repo, url: filed.url, existing: filed.existing}
      |> Map.put(:reason, route.problem && fit(route.problem, @reason_max))

    record(repo_key, issue.id, "ticket.filed", payload, run_id)

    if not filed.existing and is_binary(Map.get(ticket, :id)),
      do: record(filed.repo, ticket.id, "ticket.filed_from", %{from: issue.identifier || issue.id, by: "conductor", kind: kind}, run_id)

    filed
  end

  # Best-effort: a filing already made is never undone because its record could not be written.
  defp record(repo_key, issue_id, type, payload, run_id) do
    result = TicketEvents.record(repo_key, issue_id, type, payload, run_id: run_id, idempotency: "#{type}:#{run_id}")
    with {:error, reason} <- result, do: Logger.warning("Conductor could not record #{type} issue_id=#{issue_id}: #{inspect(reason)}")
  end

  # An unreadable config lists no repos.
  defp repo_keys(opts), do: Keyword.get_lazy(opts, :repos, fn -> for {:ok, repos} <- [Config.repos()], repo <- repos, do: repo.name end)

  defp terminal?(state, opts) do
    terminal = Keyword.get_lazy(opts, :terminal_states, fn -> Config.settings!().tracker.terminal_states end)
    normalize(to_string(state)) in Enum.map(terminal, &normalize/1)
  end

  defp fit(text, max), do: Facts.fit(text, max)

  defp field(%Event{payload: payload}, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp tracker(opts), do: Keyword.get(opts, :tracker, SymphonyElixir.Tracker)
end
