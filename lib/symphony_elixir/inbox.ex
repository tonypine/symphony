defmodule SymphonyElixir.Inbox do
  @moduledoc """
  Everything that waits on the Director, for the Mac app's Inbox (`GET /api/v1/inbox`) and the
  state API's `waiting_on_you`.

  The rows are built on each read from the tickets' records (`SymphonyElixir.RunStore`) and the
  orchestrator snapshot (`SymphonyElixir.Inbox.FromRecord`): a plan in `Plan Review` with its
  captured brief, each open Question, each pause the Director may release, and the quality gate's
  holds and skips; then each open Question on Symphony itself or on a configured repository
  (`SymphonyElixir.Questions.open_on_subjects/0`), a row with no ticket. Nothing is polled or cached, and no read is sent to Linear: an answer, an Unblock
  or a Stop shows on the very next read, and the Inbox answers while Linear is unreachable.

  `SymphonyElixir.Inbox.References` then adds what each row's text mentions (`references`) and where
  its ticket sits (`context`), from the same records; it reads GitHub for the pull requests a row
  names only when the row changed since it last read them.

  The second argument of `items/2` and `rows/1` names the Inbox: a name (the default, this module)
  reads the run store, and a keyword list may give `:records` (a function returning the records),
  `:subject_questions` (a function returning the open Questions on subjects that are not tickets),
  `:name` and the options `SymphonyElixir.Inbox.References.resolve/3` takes.
  """

  alias SymphonyElixir.{Config, Questions, RunStore}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Inbox.{FromRecord, Item, References}

  @typedoc "An Inbox: a name, or options (see the moduledoc)."
  @type inbox :: GenServer.name() | keyword()

  @doc """
  Whether the Inbox serves these settings' tracker from `source`: a Linear tracker (`:linear`, the
  default), or a memory tracker that has an issues file (`:memory`).
  """
  @spec enabled?(Schema.t()) :: boolean()
  def enabled?(settings), do: enabled?(settings, :linear)

  @spec enabled?(Schema.t(), :linear | :memory) :: boolean()
  def enabled?(%Schema{tracker: %{kind: "linear"}}, :linear), do: true
  def enabled?(%Schema{tracker: %{kind: "memory", memory_issues_file: path}}, :memory) when is_binary(path), do: true
  def enabled?(_settings, _source), do: false

  @doc """
  What waits on the Director now (`SymphonyElixir.Inbox.FromRecord.items/3` over the records and
  `snapshot`), each row with its references and context, oldest first.
  """
  @spec items(map(), inbox()) :: [Item.t()]
  def items(snapshot, inbox \\ __MODULE__) when is_map(snapshot) do
    {records, opts} = read(inbox)
    running_ids = snapshot |> Map.get(:running, []) |> MapSet.new(& &1.issue_id)

    items =
      records
      |> FromRecord.items(snapshot, Keyword.take(opts, [:settings_fun, :subject_questions]))
      |> References.resolve(records, opts)

    live = %{running: running_ids, you: MapSet.new(items, & &1.issue_id)}
    Enum.map(items, &References.live(&1, live))
  end

  @doc """
  The rows of the records alone, without the snapshot, references or context: what names a
  request's comment and its Question (`review.comment_id`, `review.question_id`) for a caller that
  replies under it. Makes no GitHub or Linear read.
  """
  @spec rows(inbox()) :: [Item.t()]
  def rows(inbox \\ __MODULE__) do
    {records, opts} = read(inbox)
    FromRecord.items(records, %{}, Keyword.take(opts, [:settings_fun, :subject_questions]))
  end

  # The records and the options to read them with: each repository's settings are read once per
  # read, and a record of a repository the configuration no longer names is left out, having no
  # settings to build its row with.
  defp read(inbox) do
    opts = options(inbox)

    records =
      case Keyword.get(opts, :records, &RunStore.list_all_ticket_states/0).() do
        records when is_list(records) -> records
        {:error, _reason} -> []
      end

    settings_fun = Keyword.get(opts, :settings_fun, &Config.settings_for_repo/1)
    settings = records |> Enum.map(&Map.get(&1, :repo_key)) |> Enum.uniq() |> Enum.flat_map(&repo_settings(&1, settings_fun)) |> Map.new()

    subject_questions = opts |> Keyword.get(:subject_questions, &Questions.open_on_subjects/0) |> then(& &1.()) |> Enum.filter(&configured_subject?(&1, settings_fun))

    opts = opts |> Keyword.put(:settings_fun, &Map.fetch!(settings, &1)) |> Keyword.put(:subject_questions, subject_questions)
    {Enum.filter(records, &Map.has_key?(settings, Map.get(&1, :repo_key))), opts}
  end

  # A question on a repository the configuration no longer names is left out, as its tickets are.
  defp configured_subject?({{:repository, repo_key}, _question}, settings_fun), do: repo_settings(repo_key, settings_fun) != []
  defp configured_subject?({:symphony, _question}, _settings_fun), do: true

  defp repo_settings(repo_key, settings_fun) when is_binary(repo_key) do
    case settings_fun.(repo_key) do
      {:ok, settings} -> [{repo_key, settings}]
      %Schema{} = settings -> [{repo_key, settings}]
      {:error, _reason} -> []
    end
  end

  defp repo_settings(_repo_key, _settings_fun), do: []

  defp options(opts) when is_list(opts), do: Keyword.put_new(opts, :name, __MODULE__)
  defp options(name), do: [name: name]
end
