defmodule SymphonyElixir.Pauses.Projector do
  @moduledoc """
  Renders a ticket's pause (`SymphonyElixir.Pauses`) and questions (`SymphonyElixir.Questions`)
  into Linear: its two machine labels and the Decisions section of its description
  (`SymphonyElixir.Decisions`). The record is the truth and Linear only shows it.

  `desired/1` says what Linear should show, from the record alone:

    * `Needs Decision` while a question on the ticket is open;
    * `Blocked` while the pause has a reason that is not a question: a ticket, a person or the
      environment. A `:build` reason, the wait for a Symphony update (`SymphonyElixir.UpdateHold`),
      shows no label, as it showed none before the projector;
    * until the Needs Decision hold is retired, `Needs Decision` also while the record holds it
      (`SymphonyElixir.Hold`). A Blocked hold a record kept from before its retirement shows
      nothing: the pause alone says `Blocked`;
    * the Decisions section's entries (`Decisions.render_from_questions/1`) and their hash;
    * per question a request comment shows in Linear (asked with `request: true`, as
      `SymphonyElixir.DecisionRequest.ask/4` asks it; one asked before questions said, while the
      Needs Decision hold carries it), the `## Decision needed:` comment
      (`Request.render_question/2`, carrying the question's id in its hidden line) and, once it
      ended, the reply under it (`Request.render_reply/1`): the Director's decision for an answer a
      person gave, the `## Action withdrawn` reason for a withdrawal.

  `apply/2` writes only what differs from what it last applied, which the record keeps
  (`projected`: the labels and the section's hash). A record it never projected compares its labels
  with the ones the last observation of the ticket in Linear saw. The section is written into the
  description read right before the write (`Decisions.put/2`), so a person's text since stays, and
  an entry already there is never written twice. A write Linear refuses leaves the record as it is,
  keeps what did land in `projected`, and marks the projection pending (`pending_projection`,
  `:pause`): the reconciler applies it again (`SymphonyElixir.TicketObservation.reconcile_all/3`).
  A second apply of the same record writes nothing.

  Each comment is written once: `projected.comments` keeps, by question id, the request comment's id
  and the stamp of the ending whose reply was written. Linear's comments (`fetch_plan_comments/1`)
  are read only when one is to be written, so a request posted before the projector, or a reply a
  person wrote under it in Linear (which is the answer), is found and not written again. A record
  whose comments were never projected counts the questions that already ended as replied.

  A repair of a ticket whose labels drifted
  (`force: true`) compares with the labels Linear shows instead, the ones the repair just read
  (`labels:`) or else the last observation's, so a label a person added or removed by hand is put
  back as the record says.

  `project_now/2` is called by `Pauses` and `Questions` after each write that changed the record,
  by `Hold` after each hold it sets or clears, and by `Decisions.record/3` once a decision is
  stored.

  The projector owns these writes while the internal flag `:pause_projector` is on (`owns?/0`,
  default on): the holds' own label writes (`SymphonyElixir.Hold`, `SymphonyElixir.NeedsDecisionHold`),
  the decision store's section write, and the request comments and replies `DecisionRequest`,
  `SymphonyElixir.DirectorMoves`, `linear_withdraw_human_action` and
  `SymphonyElixir.Questions.withdraw_lapsed/3` post are skipped then. The holds themselves are still set and
  cleared until they are retired.
  """

  import Kernel, except: [apply: 2]

  require Logger

  alias SymphonyElixir.{DecisionRequest, Decisions, RunStore, TicketSignals, TicketState, Tracker}
  alias SymphonyElixir.HumanActions.Request

  @blocked "Blocked"
  @needs_decision "Needs Decision"
  @labels [@blocked, @needs_decision]
  # Reasons that show no Blocked label: a question shows Needs Decision, an update's wait shows none.
  @unlabelled_kinds [:question, :build]

  @typedoc """
  What Linear should show for one question: its request comment (`Request.render_question/2`) and,
  once it ended, the stamp of how it ended (`answered:` or `withdrawn:` and when) with the reply that
  goes under the request (`Request.render_reply/1`; nil when the answer came from no person, which
  posts no reply).
  """
  @type comment :: %{
          question_id: String.t(),
          title: String.t(),
          comment: String.t(),
          since: DateTime.t() | nil,
          stamp: String.t() | nil,
          reply: String.t() | nil
        }

  @typedoc "What Linear should show for a record: its machine labels, the section's entries and their hash, and the questions' comments."
  @type desired :: %{labels: [String.t()], entries: [Decisions.entry()], section: String.t() | nil, comments: [comment()]}

  @typedoc """
  `tracker:` (default `SymphonyElixir.Tracker`), `store:` (default `SymphonyElixir.RunStore`),
  `force: true`, which compares with the labels Linear shows instead of what was last applied, and
  writes the section again, as a repair of a ticket whose labels drifted does, and `labels:`, the
  labels Linear shows, which the repair just read (default: the ones the last observation saw).
  """
  @type opt :: {:tracker, module()} | {:store, module()} | {:force, boolean()} | {:labels, [String.t()]}

  @doc "Whether the projector owns the labels and the Decisions section: the internal flag `:pause_projector`, default on."
  @spec owns?() :: boolean()
  def owns?, do: Application.get_env(:symphony_elixir, :pause_projector, true) == true

  @doc "The machine labels the projector writes."
  @spec labels() :: [String.t()]
  def labels, do: @labels

  @doc """
  What Linear should show for `record`: its labels, sorted (`Needs Decision` while a question is
  open, `Blocked` while a reason other than a question or an update's wait pauses it), and the
  Decisions section's entries with their hash (nil when there are none), counting the record's
  Needs Decision hold until it is retired. Pure.
  """
  @spec desired(map()) :: desired()
  def desired(record) do
    record = TicketState.normalize(record)
    reasons = (record.pause && record.pause.reasons) || []

    labels =
      [
        {@blocked, Enum.any?(reasons, &(&1.kind not in @unlabelled_kinds))},
        {@needs_decision, Enum.any?(record.questions, &(&1.state == :open)) or TicketState.hold?(record, :needs_decision)}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    entries = Decisions.render_from_questions(record)
    %{labels: labels, entries: entries, section: hash(entries), comments: comments(record)}
  end

  # A question a request comment shows in Linear: one asked with `request: true`; one asked before
  # questions said, while the Needs Decision hold carries it or once its comment was projected.
  defp comments(record) do
    carried = for %{kind: :needs_decision, decision: %{question_id: id}} <- record.holds, do: id
    projected = Map.keys(projected_comments(record) || %{})

    for question <- record.questions, request?(question, carried ++ projected) do
      ended = ended(question)

      %{
        question_id: question.id,
        title: question.title,
        comment: Request.render_question(question, record.phase),
        since: Map.get(question, :reopened_at),
        stamp: ended && elem(ended, 0),
        reply: ended && elem(ended, 1)
      }
    end
  end

  defp request?(question, known) do
    case Map.get(question, :request) do
      nil -> question.id in known
      request -> request == true
    end
  end

  # How the question ended, as a stamp, and the reply it posts: an answer a person gave posts the
  # Director's decision, a withdrawal posts its reason. nil while it is open.
  defp ended(%{state: :answered, answer: %{at: at, by: by}} = question),
    do: {"answered:" <> DateTime.to_iso8601(at), if(Map.get(by, :kind) == :person, do: Request.render_reply(question))}

  defp ended(%{state: :withdrawn, withdrawn: %{at: at}} = question), do: {"withdrawn:" <> DateTime.to_iso8601(at), Request.render_reply(question)}
  defp ended(_open), do: nil

  defp projected_comments(%{projected: %{comments: comments}}), do: comments
  defp projected_comments(_record), do: nil

  @doc """
  Whether the request comment of the question `question_id` on `ticket` is on Linear as far as the
  projector knows: posted or found by it (`projected.comments`).
  """
  @spec commented?({:ticket, String.t(), String.t()}, String.t(), [opt()]) :: boolean()
  def commented?({:ticket, repo_key, issue_id}, question_id, opts \\ []) do
    case Keyword.get(opts, :store, RunStore).get_ticket_state(repo_key, issue_id) do
      %{} = record -> Map.has_key?(projected_comments(TicketState.normalize(record)) || %{}, question_id)
      _none -> false
    end
  end

  @doc """
  Writes what `desired/1` gives for `record` and differs from what was last applied: each label to
  set or clear, and the section when its hash changed. Records what landed in `projected`; a write
  that fails marks the projection pending and is returned.
  """
  @spec apply(map(), [opt()]) :: :ok | {:error, term()}
  def apply(record, opts \\ []) do
    record = TicketState.normalize(record)
    tracker = Keyword.get(opts, :tracker, Tracker)
    desired = desired(record)
    last = last_applied(record, opts)

    {labels, label_errors} = apply_labels(tracker, record.issue_id, last.labels, desired.labels)
    {section, section_errors} = apply_section(tracker, record.issue_id, last.section, desired)
    {comments, comment_errors} = apply_comments(tracker, record.issue_id, last.comments, desired.comments)
    remember(record, %{labels: labels, section: section, comments: comments}, Keyword.get(opts, :store, RunStore))

    case label_errors ++ section_errors ++ comment_errors do
      [] ->
        :ok

      [reason | _rest] ->
        Logger.warning("Failed to project the pause of issue_id=#{record.issue_id}: #{inspect(reason)}")
        TicketSignals.mark_projection(record.repo_key, record.issue_id, :pause, reason)
        {:error, reason}
    end
  end

  @doc """
  Applies the projection of `ticket`'s record as the store holds it now (`apply/2`), when the
  projector owns it (`owns?/0`). A ticket with no record has nothing to project, unless a repair
  read its labels (`labels:`): a machine label on a ticket Symphony keeps no record of is cleared.
  """
  @spec project_now({:ticket, String.t(), String.t()}, [opt()]) :: :ok | {:error, term()}
  def project_now({:ticket, repo_key, issue_id}, opts \\ []) do
    if owns?() do
      case Keyword.get(opts, :store, RunStore).get_ticket_state(repo_key, issue_id) do
        %{} = record -> apply(record, opts)
        nil -> repair_unrecorded(repo_key, issue_id, opts)
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  # A ticket Symphony keeps no record of wants no machine label, which only a repair that read its
  # labels in Linear can clear.
  defp repair_unrecorded(repo_key, issue_id, opts) do
    if is_list(opts[:labels]), do: apply(TicketState.new(repo_key, issue_id), opts), else: :ok
  end

  # Each label that differs, set or cleared; the labels that landed, sorted, and the errors.
  defp apply_labels(tracker, issue_id, last, desired) do
    {applied, errors} = Enum.reduce(@labels, {last, []}, &apply_label(tracker, issue_id, desired, &1, &2))
    {Enum.sort(applied), Enum.reverse(errors)}
  end

  defp apply_label(tracker, id, desired, name, {applied, errors} = acc) do
    case {name in desired, name in applied} do
      {same, same} -> acc
      {true, false} -> label_write(fn -> tracker.set_machine_label(id, name) end, {applied, [name | applied]}, errors)
      {false, true} -> label_write(fn -> tracker.clear_machine_label(id, name) end, {applied, List.delete(applied, name)}, errors)
    end
  end

  # The labels as they were and as they are once the write lands.
  defp label_write(write, {applied, landed}, errors) do
    case call(write) do
      :ok -> {landed, errors}
      {:error, reason} -> {applied, [reason | errors]}
    end
  end

  defp apply_section(_tracker, _issue_id, last, %{section: section}) when section in [nil, last], do: {last, []}

  defp apply_section(tracker, issue_id, last, %{entries: entries, section: section}) do
    with {:ok, description} <- call(fn -> tracker.fetch_issue_description(issue_id) end),
         {:ok, updated} <- Decisions.put(description, entries),
         :ok <- write_description(tracker, issue_id, description || "", updated) do
      {section, []}
    else
      {:error, reason} -> {last, [reason]}
    end
  end

  # The comments to write: a request not on Linear yet, a reply for an ending the projector has not
  # projected. A record whose comments were never projected counts the questions that already ended
  # as projected, since their comments were written before the projector wrote them. Linear's
  # comments are read once, and only when there is one to write.
  defp apply_comments(tracker, issue_id, last, desired) do
    last = last || ended_as_replied(desired)

    case Enum.filter(desired, &to_write?(&1, Map.get(last, &1.question_id))) do
      [] -> {last, []}
      writes -> write_comments(tracker, issue_id, last, writes)
    end
  end

  defp ended_as_replied(desired) do
    for %{stamp: stamp} = comment <- desired, stamp != nil, into: %{} do
      {comment.question_id, %{comment: nil, reply: stamp}}
    end
  end

  defp write_comments(tracker, issue_id, last, writes) do
    case call(fn -> tracker.fetch_plan_comments(issue_id) end) do
      {:ok, %{comments: on_linear}} -> Enum.reduce(writes, {last, []}, &write_comment(tracker, issue_id, on_linear, &1, &2))
      {:error, reason} -> {last, [reason]}
    end
  end

  defp to_write?(%{stamp: nil}, entry), do: entry == nil
  defp to_write?(%{stamp: stamp}, entry), do: entry == nil or entry.reply != stamp

  defp write_comment(tracker, issue_id, on_linear, comment, {written, errors}) do
    entry = Map.get(written, comment.question_id)

    case comment_write(tracker, issue_id, on_linear, comment, entry) do
      {:ok, entry} -> {Map.put(written, comment.question_id, entry), errors}
      {:error, reason} -> {written, errors ++ [reason]}
    end
  end

  # An open question: its request, found on Linear or posted once.
  defp comment_write(tracker, issue_id, on_linear, %{stamp: nil} = comment, _entry) do
    case request_on_linear(on_linear, comment) do
      %{id: id} -> {:ok, %{comment: id, reply: nil}}
      nil -> landed(fn -> tracker.create_comment(issue_id, comment.comment) end, %{comment: nil, reply: nil})
    end
  end

  # An ended question: its reply under the request, unless Linear already shows one since it was asked
  # (a person's reply in Linear is the answer) or the answer posts none. A request the projector never
  # saw on Linear takes no reply; one it posted but Linear no longer lists takes it as a comment.
  defp comment_write(tracker, issue_id, on_linear, comment, entry) do
    case {request_on_linear(on_linear, comment), entry} do
      {%{id: id}, _entry} ->
        reply_once(tracker, issue_id, id, comment, replied?(on_linear, id, comment.since))

      {nil, %{comment: id}} when is_binary(id) ->
        reply_once(tracker, issue_id, id, comment, false)

      {nil, %{}} when is_binary(comment.reply) ->
        landed(fn -> tracker.create_comment(issue_id, comment.reply) end, %{comment: nil, reply: comment.stamp})

      {nil, _entry} ->
        {:ok, %{comment: nil, reply: comment.stamp}}
    end
  end

  defp reply_once(_tracker, _issue_id, id, %{reply: reply} = comment, replied?) when replied? or reply == nil, do: {:ok, %{comment: id, reply: comment.stamp}}
  defp reply_once(tracker, issue_id, id, comment, _replied?), do: landed(fn -> tracker.create_reply(issue_id, id, comment.reply) end, %{comment: id, reply: comment.stamp})

  # The entry once the write landed.
  defp landed(write, entry) do
    with :ok <- call(write), do: {:ok, entry}
  end

  # The request comment of the question: the one whose hidden line names it, else the newest one
  # with its title and no hidden line, as requests posted before questions carried an id.
  defp request_on_linear(on_linear, %{question_id: id, title: title}) do
    top = Enum.filter(on_linear, &(&1.parent_id == nil and is_binary(&1.body)))

    Enum.find(top, &(DecisionRequest.question_id(&1.body) == id)) ||
      top
      |> Enum.filter(&(DecisionRequest.question_id(&1.body) == nil and titled?(&1.body, title)))
      |> List.last()
  end

  defp titled?(body, title) do
    case Request.parse(body) do
      %{title: parsed} -> Request.normalize_title(parsed) == Request.normalize_title(title)
      nil -> false
    end
  end

  # A reply under the request, after the question was reopened when it was.
  defp replied?(on_linear, request_id, since) do
    Enum.any?(on_linear, &(&1.parent_id == request_id and after?(&1.created_at, since)))
  end

  defp after?(%DateTime{} = at, %DateTime{} = since), do: DateTime.compare(at, since) == :gt
  defp after?(_at, _since), do: true

  defp write_description(_tracker, _issue_id, description, description), do: :ok
  defp write_description(tracker, issue_id, _description, updated), do: call(fn -> tracker.update_issue_description(issue_id, updated) end)

  defp remember(%{projected: projected}, projected, _store), do: :ok

  defp remember(record, projected, store) do
    with {:error, reason} <- store.update_ticket_state(record.repo_key, record.issue_id, %{projected: projected}) do
      Logger.warning("Failed to record the pause projection of issue_id=#{record.issue_id}: #{inspect(reason)}")
    end
  end

  defp last_applied(record, opts) do
    case {record.projected, Keyword.get(opts, :force) == true} do
      {%{} = projected, false} -> projected
      _never_projected_or_forced -> %{labels: machine_labels(Keyword.get(opts, :labels, record.labels)), section: nil, comments: projected_comments(record)}
    end
  end

  # The machine labels among the ones Linear shows.
  defp machine_labels(labels) do
    observed = MapSet.new(labels, &String.downcase/1)
    Enum.filter(@labels, &MapSet.member?(observed, String.downcase(&1)))
  end

  defp hash([]), do: nil

  defp hash(entries) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(entries, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # A tracker call that raises is a write that failed.
  defp call(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _value} = ok -> ok
      {:error, _reason} = error -> error
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
