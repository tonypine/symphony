defmodule SymphonyElixir.Pauses do
  @moduledoc """
  The one answer to "why is this not moving": a pause on a subject (a ticket, a repository or
  Symphony itself) with one or more reasons, who set it and since when. This module is the only
  writer of a pause.

  A reason says what the subject waits on, structured so the machine can tell when it ends:

    * `:question` - an answer to a question (`waits_on: %{question_id: id}`);
    * `:ticket` - another ticket reaching a terminal state (`waits_on: %{identifier: "TP-12"}`);
    * `:build` - a Symphony build containing a fix (`waits_on: %{version: "1.4.0"}` or
      `%{pull_request: 448}`);
    * `:person` - the Director (`waits_on: %{action: "unblock" | "restart"}`);
    * `:environment` - a named condition (`waits_on: %{condition: name}`).

  Each reason has `text`, one line in plain words (a default per kind, or the writer's), `set_by`
  (`%{kind: :person | :run | :rule | :symphony, name: name}`), `set_at` and `releasable`: whether
  the Director may release it. A `:person` reason always is; a `:ticket` or `:environment` reason is
  when its writer says so; a `:question` or `:build` reason never is.

  A ticket's pause lives on its record (`SymphonyElixir.TicketState`, field `pause`), and each change
  records a ledger event (`SymphonyElixir.TicketEvents`): `pause.set` for the first reason,
  `pause.reason_added` for each further one, `pause.reason_cleared` for a reason cleared while
  others remain and `pause.cleared` when none is left. A repository's or Symphony's pause is kept by
  `SymphonyElixir.RunStore` under its subject and records no event.

  A reason is known by its kind and `waits_on`: setting the same one again changes nothing and
  records nothing. Nothing calls this module yet.
  """

  alias SymphonyElixir.{RunStore, TicketEvents, TicketState}

  @kinds [:question, :ticket, :build, :person, :environment]
  @setter_kinds [:person, :run, :rule, :symphony]
  @person_actions ~w(unblock restart)
  @symphony %{kind: :symphony, name: "Symphony"}

  @typedoc "What a pause holds: a ticket of a repository, a repository, or Symphony itself."
  @type subject :: {:ticket, String.t(), String.t()} | {:repository, String.t()} | :symphony

  @type kind :: :question | :ticket | :build | :person | :environment

  @typedoc "Who set a reason, or cleared one: a person, a run, a rule or Symphony, by name."
  @type set_by :: %{kind: :person | :run | :rule | :symphony, name: String.t()}

  @type reason :: %{
          kind: kind(),
          waits_on: map(),
          text: String.t(),
          set_by: set_by(),
          set_at: DateTime.t() | nil,
          releasable: boolean()
        }

  @typedoc "A pause: its subject, its reasons in the order they were set, who set it and since when."
  @type pause :: %{subject: subject(), reasons: [reason(), ...], set_by: set_by(), since: DateTime.t() | nil}

  @typedoc """
  A reason as a writer gives it: its `kind` and `waits_on`, and optionally its `text` and whether
  the Director may release it (`releasable`).
  """
  @type reason_input :: %{
          required(:kind) => kind(),
          required(:waits_on) => map(),
          optional(:text) => String.t(),
          optional(:releasable) => boolean()
        }

  @typedoc "`set_by:` (or `by:` when clearing; default Symphony) and `at:` (default now)."
  @type opt :: {:set_by, set_by()} | {:by, set_by()} | {:at, DateTime.t()}

  @type result :: {:ok, pause() | nil} | {:error, term()}

  @doc """
  Pauses `subject` on `reason`: a subject that is not paused records `pause.set`; a paused one gains
  the reason, as with `add_reason/3`. Returns the pause.
  """
  @spec set(subject(), reason_input(), [opt()]) :: result()
  def set(subject, reason, opts \\ []) do
    with {:ok, subject} <- subject(subject),
         {:ok, reason} <- new_reason(reason, opts, :set_by),
         {:ok, current} <- read(subject) do
      add(subject, current, reason)
    end
  end

  @doc """
  Adds `reason` to the pause of `subject`, recording `pause.reason_added`; `{:error, :not_paused}`
  when the subject is not paused.
  """
  @spec add_reason(subject(), reason_input(), [opt()]) :: result()
  def add_reason(subject, reason, opts \\ []) do
    with {:ok, subject} <- subject(subject),
         {:ok, reason} <- new_reason(reason, opts, :set_by),
         {:ok, %{} = current} <- paused(read(subject)) do
      add(subject, current, reason)
    end
  end

  @doc """
  Clears the reason of `subject`'s pause with `reason`'s kind and `waits_on`. Others left, the pause
  stays and records `pause.reason_cleared`; none left, the pause clears and records `pause.cleared`.
  A reason the pause doesn't hold changes nothing. Returns the pause, nil once cleared.
  """
  @spec clear_reason(subject(), reason_input(), [opt()]) :: result()
  def clear_reason(subject, reason, opts \\ []) do
    with {:ok, subject} <- subject(subject),
         {:ok, target} <- new_reason(reason, opts, :by),
         {:ok, current} <- read(subject) do
      drop(subject, current, target)
    end
  end

  @doc "Clears `subject`'s pause whatever its reasons, recording `pause.cleared`. A subject not paused is unchanged."
  @spec clear(subject(), [opt()]) :: result()
  def clear(subject, opts \\ []) do
    with {:ok, subject} <- subject(subject),
         {:ok, by} <- setter(opts, :by),
         {:ok, current} <- read(subject) do
      case current do
        nil -> {:ok, nil}
        pause -> write(subject, nil, "pause.cleared", cleared_payload(pause.reasons, by), at(opts))
      end
    end
  end

  @doc "The pause of `subject`, or nil when it is not paused."
  @spec get(subject()) :: result()
  def get(subject) do
    with {:ok, subject} <- subject(subject), do: read(subject)
  end

  @doc "Whether `subject` is paused."
  @spec paused?(subject()) :: boolean()
  def paused?(subject), do: reasons(subject) != []

  @doc "Why `subject` is paused: one line in plain words per reason, in the order they were set."
  @spec why(subject()) :: [String.t()]
  def why(subject), do: subject |> reasons() |> Enum.map(& &1.text)

  @doc "Whether the Director may release `subject`'s pause: any of its reasons is releasable."
  @spec releasable?(subject()) :: boolean()
  def releasable?(subject), do: subject |> reasons() |> Enum.any?(& &1.releasable)

  @doc """
  A pause as stored or given, with its reasons validated (each kind and `waits_on` once, at its
  first place) and its defaults filled; nil for anything that is not a pause with at least one
  valid reason.
  """
  @spec normalize(term()) :: pause() | nil
  def normalize(%{subject: subject, reasons: reasons} = pause) when is_list(reasons) do
    with {:ok, subject} <- subject(subject),
         [first | _rest] = reasons <- reasons |> Enum.flat_map(&normalize_reason/1) |> Enum.uniq_by(&key/1) do
      %{
        subject: subject,
        reasons: reasons,
        set_by: set_by(Map.get(pause, :set_by)) || first.set_by,
        since: datetime(Map.get(pause, :since)) || first.set_at
      }
    else
      _invalid -> nil
    end
  end

  def normalize(_pause), do: nil

  defp reasons(subject) do
    case get(subject) do
      {:ok, %{reasons: reasons}} -> reasons
      _none -> []
    end
  end

  defp add(subject, nil, reason) do
    pause = %{subject: subject, reasons: [reason], set_by: reason.set_by, since: reason.set_at}
    write(subject, pause, "pause.set", reason_payload(reason), reason.set_at)
  end

  defp add(subject, pause, reason) do
    if Enum.any?(pause.reasons, &(key(&1) == key(reason))) do
      {:ok, pause}
    else
      write(subject, %{pause | reasons: pause.reasons ++ [reason]}, "pause.reason_added", reason_payload(reason), reason.set_at)
    end
  end

  defp drop(_subject, nil, _target), do: {:ok, nil}

  defp drop(subject, pause, target) do
    case Enum.split_with(pause.reasons, &(key(&1) == key(target))) do
      {[], _reasons} ->
        {:ok, pause}

      {cleared, []} ->
        write(subject, nil, "pause.cleared", cleared_payload(cleared, target.set_by), target.set_at)

      {[cleared], reasons} ->
        payload = cleared |> cleared_reason() |> Map.put(:by, target.set_by)
        write(subject, %{pause | reasons: reasons}, "pause.reason_cleared", payload, target.set_at)
    end
  end

  # A ticket's pause is written on its record, then its event; any other subject's in the store.
  defp write({:ticket, repo_key, issue_id}, pause, type, payload, at) do
    with :ok <- put_ticket_pause(repo_key, issue_id, pause, at),
         {:ok, _event} <- TicketEvents.record(repo_key, issue_id, type, payload, at: at) do
      {:ok, pause}
    end
  end

  defp write(subject, nil, _type, _payload, _at) do
    with :ok <- RunStore.delete_subject_pause(subject), do: {:ok, nil}
  end

  defp write(subject, pause, _type, _payload, _at) do
    with :ok <- RunStore.put_subject_pause(subject, pause), do: {:ok, pause}
  end

  defp put_ticket_pause(repo_key, issue_id, pause, at) do
    case RunStore.update_ticket_state(repo_key, issue_id, %{pause: pause, updated_at: at}) do
      {:error, :ticket_state_not_found} ->
        repo_key |> TicketState.new(issue_id) |> TicketState.put_pause(pause, at) |> RunStore.put_ticket_state()

      result ->
        result
    end
  end

  defp read({:ticket, repo_key, issue_id}) do
    with record when not is_tuple(record) <- RunStore.get_ticket_state(repo_key, issue_id),
         do: {:ok, TicketState.normalize(record).pause}
  end

  defp read(subject) do
    with pause when not is_tuple(pause) <- RunStore.get_subject_pause(subject), do: {:ok, normalize(pause)}
  end

  defp paused({:ok, nil}), do: {:error, :not_paused}
  defp paused(read), do: read

  defp reason_payload(reason) do
    %{reason: reason.kind, text: reason.text, waits_on: reason.waits_on, set_by: reason.set_by, releasable: reason.releasable}
  end

  defp cleared_payload(reasons, by), do: %{cleared: Enum.map(reasons, &cleared_reason/1), by: by}

  defp cleared_reason(reason), do: %{reason: reason.kind, text: reason.text, waits_on: reason.waits_on}

  defp key(reason), do: {reason.kind, reason.waits_on}

  defp new_reason(reason, opts, setter_key) when is_map(reason) do
    with {:ok, set_by} <- setter(opts, setter_key) do
      case normalize_reason(Map.merge(reason, %{set_by: set_by, set_at: at(opts)})) do
        [reason] -> {:ok, reason}
        [] -> {:error, {:invalid_reason, reason}}
      end
    end
  end

  defp new_reason(reason, _opts, _setter_key), do: {:error, {:invalid_reason, reason}}

  defp at(opts), do: Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)

  defp setter(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, @symphony}
      {:ok, value} -> if set_by = set_by(value), do: {:ok, set_by}, else: {:error, {:invalid_set_by, value}}
    end
  end

  defp normalize_reason(%{kind: kind, waits_on: %{} = waits_on} = reason) when kind in @kinds do
    case waits_on(kind, waits_on) do
      nil ->
        []

      waits_on ->
        [
          %{
            kind: kind,
            waits_on: waits_on,
            text: line(Map.get(reason, :text)) || default_text(kind, waits_on),
            set_by: set_by(Map.get(reason, :set_by)) || @symphony,
            set_at: datetime(Map.get(reason, :set_at)),
            releasable: releasable(kind, Map.get(reason, :releasable))
          }
        ]
    end
  end

  defp normalize_reason(_reason), do: []

  defp waits_on(:question, waits_on), do: one(waits_on, :question_id)
  defp waits_on(:ticket, waits_on), do: one(waits_on, :identifier)
  defp waits_on(:environment, waits_on), do: one(waits_on, :condition)
  defp waits_on(:build, %{pull_request: number}) when is_integer(number) and number > 0, do: %{pull_request: number}
  defp waits_on(:build, waits_on), do: one(waits_on, :version)
  defp waits_on(:person, %{action: action}) when is_atom(action), do: waits_on(:person, %{action: Atom.to_string(action)})
  defp waits_on(:person, %{action: action}) when action in @person_actions, do: %{action: action}
  defp waits_on(:person, _waits_on), do: nil

  defp one(waits_on, field) do
    if value = line(Map.get(waits_on, field)), do: %{field => value}
  end

  defp default_text(:question, _waits_on), do: "Waiting for your answer"
  defp default_text(:ticket, %{identifier: identifier}), do: "Waiting for #{identifier} to finish"
  defp default_text(:build, %{version: version}), do: "Waiting for Symphony version #{version}, which has the fix"
  defp default_text(:build, %{pull_request: number}), do: "Waiting for a Symphony build with the fix from PR ##{number}"
  defp default_text(:person, %{action: action}), do: "Waiting for you to #{action} it"
  defp default_text(:environment, _waits_on), do: "Waiting for the environment to be ready"

  defp releasable(:person, _releasable), do: true
  defp releasable(kind, releasable) when kind in [:ticket, :environment], do: releasable == true
  defp releasable(_kind, _releasable), do: false

  defp set_by(%{kind: kind, name: name}) when kind in @setter_kinds do
    if name = line(name), do: %{kind: kind, name: name}
  end

  defp set_by(_set_by), do: nil

  defp subject({:ticket, repo_key, issue_id} = subject) when is_binary(repo_key) and is_binary(issue_id) do
    if line(repo_key) && line(issue_id), do: {:ok, subject}, else: {:error, {:invalid_subject, subject}}
  end

  defp subject({:repository, repo_key} = subject) when is_binary(repo_key) do
    if line(repo_key), do: {:ok, subject}, else: {:error, {:invalid_subject, subject}}
  end

  defp subject(:symphony), do: {:ok, :symphony}
  defp subject(subject), do: {:error, {:invalid_subject, subject}}

  # One line: whitespace runs collapse to one space; blank is nil.
  defp line(value) when is_binary(value) do
    case value |> String.split() |> Enum.join(" ") do
      "" -> nil
      line -> line
    end
  end

  defp line(_value), do: nil

  defp datetime(%DateTime{} = datetime), do: datetime
  defp datetime(_value), do: nil
end
